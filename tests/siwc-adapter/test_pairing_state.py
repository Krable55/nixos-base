#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "packages/siwc-adapter/pairing_state.py"
TEMPLATE = SOURCE.with_name("config.toml.in")
HASH = "a" * 64
CAPABILITY = "b" * 64


def load_helper():
    spec = importlib.util.spec_from_file_location("pairing_state", SOURCE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fresh_config(capability=CAPABILITY):
    return (
        "schema_version = 3\n"
        "[providers.models.openai.siwc]\n"
        f'api_key = "{capability}"\n'
        'model = "gpt-5.6-sol"\n'
        "[gateway]\n"
        'host = "127.0.0.1"\n'
        "port = 42617\n"
        "require_pairing = true\n"
    )


def canonical_config(root: Path) -> Path:
    canonical = root / "canonical.toml"
    canonical.write_text(fresh_config())
    os.chmod(canonical, 0o600)
    return canonical


class PairingRestart(unittest.TestCase):
    def test_real_template_roundtrips_with_only_paired_hashes_added(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            rendered = TEMPLATE.read_text().replace("@CAPABILITY@", CAPABILITY)
            runtime.write_text(rendered)
            store.write_text(json.dumps({"version": 1, "paired_tokens": [HASH]}))
            os.chmod(runtime, 0o600)
            os.chmod(store, 0o600)
            expected = tomllib.loads(rendered)
            expected["gateway"]["paired_tokens"] = [HASH]
            helper.merge(runtime, store, canonical_config(root))
            self.assertEqual(tomllib.loads(runtime.read_text()), expected)

    def test_persisted_hash_is_merged_into_fresh_runtime_config(self):
        self.assertTrue(SOURCE.exists(), "pairing-state helper is missing")
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            runtime.write_text(fresh_config())
            store.write_text(json.dumps({"version": 1, "paired_tokens": [HASH]}))
            os.chmod(runtime, 0o600)
            os.chmod(store, 0o600)

            helper.merge(runtime, store, canonical_config(root))

            parsed = tomllib.loads(runtime.read_text())
            self.assertEqual(parsed["gateway"]["paired_tokens"], [HASH])
            self.assertEqual(
                parsed["providers"]["models"]["openai"]["siwc"]["api_key"],
                CAPABILITY,
            )

    def test_missing_store_is_initially_unpaired(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            runtime.write_text(fresh_config())
            os.chmod(runtime, 0o600)
            helper.merge(runtime, root / "missing.json", canonical_config(root))
            self.assertEqual(tomllib.loads(runtime.read_text())["gateway"]["paired_tokens"], [])

    def test_snapshot_restart_and_revocation_roundtrip(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            runtime.write_text(fresh_config() + f'paired_tokens = ["{HASH}"]\n')
            os.chmod(runtime, 0o600)
            helper.snapshot(runtime, store, canonical_config(root))
            self.assertEqual(store.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(store.read_text())["paired_tokens"], [HASH])

            runtime.write_text(fresh_config())
            os.chmod(runtime, 0o600)
            helper.merge(runtime, store, canonical_config(root))
            self.assertEqual(tomllib.loads(runtime.read_text())["gateway"]["paired_tokens"], [HASH])

            runtime.write_text(fresh_config() + "paired_tokens = []\n")
            os.chmod(runtime, 0o600)
            helper.snapshot(runtime, store, canonical_config(root))
            self.assertEqual(json.loads(store.read_text())["paired_tokens"], [])
            runtime.write_text(fresh_config())
            os.chmod(runtime, 0o600)
            helper.merge(runtime, store, canonical_config(root))
            self.assertEqual(tomllib.loads(runtime.read_text())["gateway"]["paired_tokens"], [])

    def test_malformed_existing_store_fails_without_changing_runtime(self):
        helper = load_helper()
        malformed = [
            b"not-json",
            json.dumps({"version": 2, "paired_tokens": []}).encode(),
            json.dumps({"version": 1, "paired_tokens": "not-a-list"}).encode(),
            json.dumps({"version": 1, "paired_tokens": ["zc_raw_bearer"]}).encode(),
            json.dumps({"version": 1, "paired_tokens": ["A" * 64]}).encode(),
            json.dumps({"version": 1, "paired_tokens": [CAPABILITY]}).encode(),
            json.dumps({"version": 1, "paired_tokens": [HASH, HASH]}).encode(),
            json.dumps({"version": 1, "paired_tokens": [], "extra": True}).encode(),
        ]
        for payload in malformed:
            with self.subTest(payload=payload[:16]):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    runtime = root / "runtime.toml"
                    store = root / "gateway-pairing.json"
                    original = fresh_config().encode()
                    runtime.write_bytes(original)
                    store.write_bytes(payload)
                    os.chmod(runtime, 0o600)
                    os.chmod(store, 0o600)
                    with self.assertRaises(helper.PairingStateError):
                        helper.merge(runtime, store, canonical_config(root))
                    self.assertEqual(runtime.read_bytes(), original)

    def test_symlink_and_unsafe_mode_are_rejected(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            target = root / "target.json"
            store = root / "gateway-pairing.json"
            runtime.write_text(fresh_config())
            target.write_text(json.dumps({"version": 1, "paired_tokens": [HASH]}))
            os.chmod(runtime, 0o600)
            os.chmod(target, 0o600)
            store.symlink_to(target)
            with self.assertRaises(helper.PairingStateError):
                helper.merge(runtime, store, canonical_config(root))
            self.assertEqual(json.loads(target.read_text())["paired_tokens"], [HASH])
            store.unlink()
            store.write_text(json.dumps({"version": 1, "paired_tokens": [HASH]}))
            os.chmod(store, 0o640)
            with self.assertRaises(helper.PairingStateError):
                helper.merge(runtime, store, canonical_config(root))

    def test_bounded_size_count_and_element_types_fail_closed(self):
        helper = load_helper()
        payloads = [
            b"x" * (helper.MAX_STORE_BYTES + 1),
            json.dumps(
                {
                    "version": 1,
                    "paired_tokens": [f"{index:064x}" for index in range(helper.MAX_PAIRED_TOKENS + 1)],
                }
            ).encode(),
            json.dumps({"version": 1, "paired_tokens": [False]}).encode(),
        ]
        for payload in payloads:
            with self.subTest(size=len(payload)):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    runtime = root / "runtime.toml"
                    store = root / "gateway-pairing.json"
                    original = fresh_config().encode()
                    runtime.write_bytes(original)
                    store.write_bytes(payload)
                    os.chmod(runtime, 0o600)
                    os.chmod(store, 0o600)
                    with self.assertRaises(helper.PairingStateError):
                        helper.merge(runtime, store, canonical_config(root))
                    self.assertEqual(runtime.read_bytes(), original)

    def test_runtime_config_symlink_is_rejected(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.toml"
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            target.write_text(fresh_config())
            store.write_text(json.dumps({"version": 1, "paired_tokens": [HASH]}))
            os.chmod(target, 0o600)
            os.chmod(store, 0o600)
            runtime.symlink_to(target)
            with self.assertRaises(helper.PairingStateError):
                helper.merge(runtime, store, canonical_config(root))
            self.assertEqual(target.read_text(), fresh_config())

    def test_atomic_failure_preserves_previous_store(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            runtime.write_text(fresh_config() + f'paired_tokens = ["{HASH}"]\n')
            old = b'{"paired_tokens":[],"version":1}\n'
            store.write_bytes(old)
            os.chmod(runtime, 0o600)
            os.chmod(store, 0o600)
            with mock.patch.object(helper.os, "replace", side_effect=OSError("synthetic")):
                with self.assertRaises(helper.PairingStateError):
                    helper.snapshot(runtime, store, canonical_config(root))
            self.assertEqual(store.read_bytes(), old)
            self.assertEqual(list(root.glob(".gateway-pairing.json.tmp-*")), [])

    def test_encrypted_runtime_api_key_cannot_hide_canonical_capability_alias(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            runtime.write_text(
                fresh_config("ENC[zeroclaw-managed-runtime-value]")
                + f'paired_tokens = ["{CAPABILITY}"]\n'
            )
            old = b'{"paired_tokens":[],"version":1}\n'
            store.write_bytes(old)
            os.chmod(runtime, 0o600)
            os.chmod(store, 0o600)
            with self.assertRaises(helper.PairingStateError):
                helper.snapshot(runtime, store, canonical_config(root))
            self.assertEqual(store.read_bytes(), old)

    def test_merge_rejects_canonical_capability_when_runtime_api_key_is_encrypted(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            original = fresh_config("ENC[zeroclaw-managed-runtime-value]").encode()
            runtime.write_bytes(original)
            store.write_text(json.dumps({"version": 1, "paired_tokens": [CAPABILITY]}))
            os.chmod(runtime, 0o600)
            os.chmod(store, 0o600)
            with self.assertRaises(helper.PairingStateError):
                helper.merge(runtime, store, canonical_config(root))
            self.assertEqual(runtime.read_bytes(), original)

    def test_fifo_store_is_rejected_without_blocking(self):
        for action in ("merge", "snapshot"):
            with self.subTest(action=action):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    runtime = root / "runtime.toml"
                    store = root / "gateway-pairing.json"
                    runtime.write_text(fresh_config() + f'paired_tokens = ["{HASH}"]\n')
                    os.chmod(runtime, 0o600)
                    os.mkfifo(store, 0o600)
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(SOURCE),
                            action,
                            "--runtime-config",
                            str(runtime),
                            "--canonical-config",
                            str(canonical_config(root)),
                            "--store",
                            str(store),
                        ],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=2,
                    )
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(
                        result.stderr,
                        b"pi4-zeroclaw-pairing-state: validation failed\n",
                    )

    def test_cli_error_does_not_leak_file_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.toml"
            store = root / "gateway-pairing.json"
            raw_bearer = "zc_raw_bearer_must_not_leak"
            runtime.write_text(fresh_config())
            store.write_text(json.dumps({"version": 1, "paired_tokens": [raw_bearer]}))
            os.chmod(runtime, 0o600)
            os.chmod(store, 0o600)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SOURCE),
                    "merge",
                    "--runtime-config",
                    str(runtime),
                    "--canonical-config",
                    str(canonical_config(root)),
                    "--store",
                    str(store),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            output = result.stdout + result.stderr
            self.assertNotIn(raw_bearer.encode(), output)
            self.assertNotIn(CAPABILITY.encode(), output)
            self.assertEqual(result.stdout, b"")

    def test_store_is_unreadable_by_distinct_uid(self):
        if os.geteuid() != 0:
            self.skipTest("requires mapped root with subordinate IDs")
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o711)
            owned = root / "owned"
            owned.mkdir(mode=0o700)
            os.chown(owned, 1, 1)
            runtime = owned / "runtime.toml"
            runtime.write_text(fresh_config() + f'paired_tokens = ["{HASH}"]\n')
            os.chmod(runtime, 0o600)
            os.chown(runtime, 1, 1)
            store = owned / "gateway-pairing.json"
            pid = os.fork()
            if pid == 0:
                os.setgroups([])
                os.setgid(1)
                os.setuid(1)
                try:
                    helper.snapshot(runtime, store, canonical_config(owned))
                except Exception:
                    os._exit(2)
                os._exit(0)
            self.assertEqual(os.waitpid(pid, 0)[1], 0)
            self.assertEqual(store.stat().st_uid, 1)
            self.assertEqual(store.stat().st_mode & 0o777, 0o600)
            pid = os.fork()
            if pid == 0:
                os.setgroups([])
                os.setgid(2)
                os.setuid(2)
                os._exit(1 if os.access(store, os.R_OK) else 0)
            self.assertEqual(os.waitpid(pid, 0)[1], 0)


if __name__ == "__main__":
    unittest.main()
