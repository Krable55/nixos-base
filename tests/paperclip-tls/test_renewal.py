"""Offline regression tests: execute the module's evaluated shell with real OpenSSL.
Run: python3 -m unittest discover -s tests/paperclip-tls -v
Only systemctl is stubbed; no host services or /var/lib paths are touched.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[2] / "modules/pi4-paperclip.nix"


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        systemctl = self.bin / "systemctl"
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                             'if [ "${RESTART_FAILURE:-0}" = 1 ]; then printf failed > "$CONSUMERS"; exit 1; fi\n'
                             'if [ "$1" = restart ] || [ ! -f "$CONSUMERS" ]; then printf active > "$CONSUMERS"; fi\n')
        systemctl.chmod(0o755)
        real_openssl = shutil.which("openssl")
        assert real_openssl is not None
        openssl = self.bin / "openssl"
        openssl.write_text(f'#!/bin/sh\n"{real_openssl}" "$@" || exit $?\n'
                           'if [ "$1" = req ] && [ "${FAIL_GENERATION:-0}" = 1 ]; then exit 1; fi\n'
                           'if [ "$1" = req ] && [ "${CORRUPT_GENERATION:-0}" = 1 ]; then\n'
                           '  while [ "$#" -gt 0 ]; do\n'
                           '    if [ "$1" = -keyout ]; then shift; printf broken > "$1"; break; fi\n'
                           '    shift\n'
                           '  done\n'
                           'fi\n')
        openssl.chmod(0o755)
        expr = f'''let m = import {MODULE} {{
          pkgs = {{ openssl = "{self.root}";
                    systemd = "{self.root}";
                    util-linux = "{Path(shutil.which('flock') or '/usr/bin/flock').parent.parent}"; }};
          lib.mkForce = x: x;
        }}; in {{ provision = m.systemd.services.hermes-paperclip-tls.script;
          renew = (m.systemd.services.hermes-paperclip-tls-renew.script or null);
          timer = (m.systemd.timers.hermes-paperclip-tls-renew or null);
          nginx = m.services.nginx.virtualHosts."hermes-paperclip.internal";
          volumes = m.virtualisation.oci-containers.containers.paperclip.volumes;
        }}'''
        self.scripts = json.loads(subprocess.check_output(
            ["nix", "eval", "--impure", "--json", "--expr", expr], text=True))
        self.env = dict(os.environ, CALLS=str(self.calls), CONSUMERS=str(self.root / "consumers"))

    def seed(self, days=365):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-days", str(days), "-keyout", str(self.state / "server.key"),
                        "-out", str(self.state / "server.crt"),
                        "-subj", "/CN=hermes-paperclip.internal",
                        "-addext", "subjectAltName=IP:10.88.0.1,DNS:hermes-paperclip.internal",
                        "-addext", "extendedKeyUsage=serverAuth"],
                       check=True, capture_output=True)

    def active(self, name):
        current = self.state / "current"
        return (current if current.exists() else self.state) / name

    def run_script(self, renew=False, success=True):
        script = self.scripts["renew" if renew and self.scripts["renew"] else "provision"]
        script = script.replace("/var/lib/hermes-paperclip-tls", str(self.state))
        script = script.replace("root:nginx", f"{os.getuid()}:{os.getgid()}")
        result = subprocess.run(["bash", "-c", script], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def assert_pair(self):
        cert = self.active("server.crt")
        key = self.active("server.key")
        cert_pub = subprocess.check_output(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
        result = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout"], capture_output=True)
        self.assertEqual(result.returncode, 0, "active private key must parse")
        self.assertEqual(cert_pub, result.stdout)
        self.assertEqual(key.stat().st_mode & 0o777, 0o640)
        self.assertEqual(cert.stat().st_mode & 0o777, 0o644)

    def test_fresh_provision_and_healthy_preservation(self):
        self.run_script()
        self.assert_pair()
        before = {name: self.active(name).read_bytes() for name in ("server.crt", "server.key")}
        self.run_script()
        for name, content in before.items():
            self.assertTrue(content == self.active(name).read_bytes())
        self.assertFalse(self.calls.exists())

    def test_healthy_legacy_pair_is_preserved(self):
        self.seed()
        before = self.active("server.crt").read_bytes()
        self.run_script()
        self.assertTrue(before == self.active("server.crt").read_bytes())
        self.assert_pair()

    def test_broken_pairs_are_repaired(self):
        self.run_script()
        for defect in ("missing-key", "missing-cert", "bad-key", "bad-cert", "mismatch"):
            with self.subTest(defect=defect):
                if defect.startswith("missing"):
                    self.active("server.key" if defect.endswith("key") else "server.crt").unlink()
                elif defect.startswith("bad"):
                    self.active("server.key" if defect.endswith("key") else "server.crt").write_text("broken")
                else:
                    subprocess.run(["openssl", "genrsa", "-out", str(self.active("server.key")), "2048"],
                                   check=True, capture_output=True)
                self.run_script()
                self.assert_pair()

    def test_scheduled_rotation_refreshes_consumers_once(self):
        self.seed(days=1)
        self.run_script(renew=True)
        self.assertTrue(self.calls.exists(), "rotation must recreate container and restart nginx")
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["restart podman-paperclip.service nginx.service"])
        self.run_script(renew=True)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_restart_failure_is_retried_without_rotating_again(self):
        self.seed(days=1)
        self.env["RESTART_FAILURE"] = "1"
        self.run_script(renew=True, success=False)
        cert = self.active("server.crt").read_bytes()
        self.env["RESTART_FAILURE"] = "0"
        self.run_script(renew=True)
        self.assertTrue(cert == self.active("server.crt").read_bytes())
        self.assertEqual((self.root / "consumers").read_text(), "active",
                         "a failed/inactive consumer must recover on retry")
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)
        self.run_script(renew=True)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)

    def test_timer_and_consumers_use_published_pair(self):
        self.assertIsNotNone(self.scripts["timer"], "renewal must be scheduled")
        self.assertEqual(self.scripts["timer"]["timerConfig"]["OnCalendar"], "daily")
        self.assertTrue(self.scripts["timer"]["timerConfig"]["Persistent"])
        self.assertEqual(self.scripts["nginx"]["sslCertificate"],
                         "/var/lib/hermes-paperclip-tls/current/server.crt")
        self.assertEqual(self.scripts["nginx"]["sslCertificateKey"],
                         "/var/lib/hermes-paperclip-tls/current/server.key")
        self.assertEqual(self.scripts["volumes"], ["paperclip-data:/paperclip",
                         "/var/lib/hermes-paperclip-tls/current/server.crt:/etc/paperclip/hermes-server.crt:ro"])

    def test_interruption_after_publish_keeps_published_pair(self):
        mv = self.bin / "mv"
        mv.write_text(f'#!/bin/sh\n{shutil.which("mv")} "$@" || exit $?\nkill -TERM "$PPID"\n')
        mv.chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.run_script(renew=True, success=False)
        self.assertTrue((self.state / "current/server.key").exists(),
                        "cleanup must not remove a generation already published")
        self.assert_pair()
        mv.unlink()
        self.run_script(renew=True)
        self.assertTrue(self.calls.exists(), "interrupted rotation must retry refresh")

    def test_invalid_staged_pair_is_not_published(self):
        self.seed(days=1)
        before = {name: self.active(name).read_bytes() for name in ("server.crt", "server.key")}
        self.env["CORRUPT_GENERATION"] = "1"
        self.run_script(renew=True, success=False)
        for name, content in before.items():
            self.assertTrue(content == self.active(name).read_bytes())
        self.assertFalse(self.calls.exists())

    def test_generation_failure_keeps_previous_pair(self):
        self.seed(days=1)
        before = {name: self.active(name).read_bytes() for name in ("server.crt", "server.key")}
        self.env["FAIL_GENERATION"] = "1"
        self.run_script(renew=True, success=False)
        for name, content in before.items():
            self.assertTrue(content == self.active(name).read_bytes(),
                            f"failed generation changed live {name}")
        self.assertFalse(self.calls.exists())

    def test_near_expiry_is_rotated(self):
        self.seed(days=1)
        before = self.active("server.crt").read_bytes()
        self.run_script(renew=True)
        self.assertNotEqual(before, self.active("server.crt").read_bytes(),
                            "certificate inside renewal window must rotate")
        subprocess.run(["openssl", "x509", "-in", str(self.active("server.crt")),
                        "-noout", "-checkend", "2592000"], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
