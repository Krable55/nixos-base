"""Exercise retained ARM binary with a read-only runtime config mount.
Run: unshare --user --map-auto --map-root-user --net --mount sh -c 'ip link set lo up; python3 -B tests/siwc-adapter/binary_runtime.py'
All state is temporary and all provider traffic is confined to loopback.
"""
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BINARY = '/nix/store/adkc7f6i4b46gaf1296ir59whcjva4cl-zeroclaw-0.8.6/bin/zeroclaw'


def main():
    assert sorted(n for _, n in socket.if_nameindex()) == ['lo']
    with tempfile.TemporaryDirectory(prefix='siwc-binary-') as temp:
        base = Path(temp); base.chmod(0o711)
        config = base / 'config'; config.mkdir(mode=0o750); os.chown(config, 0, 2)
        home = base / 'home'; home.mkdir(); data = home / 'data'; data.mkdir()
        cap = secrets.token_hex(32)
        text = (ROOT / 'packages/siwc-adapter/config.toml.in').read_text().replace('@CAPABILITY@', cap)
        (config / 'config.toml').write_text(text)
        (config / 'config.toml').chmod(0o600)
        os.chown(config / 'config.toml', 2, 2)
        subprocess.run(['mount', '--bind', str(config), str(config)], check=True)
        subprocess.run(['mount', '-o', 'remount,bind,ro', str(config)], check=True)
        client = base / 'client'; client.mkdir(mode=0o700)
        import shutil
        shutil.copyfile(config / 'config.toml', client / 'config.toml')
        (client / 'config.toml').chmod(0o600)
        os.chown(client, 2, 2); os.chown(client / 'config.toml', 2, 2)
        os.chown(home, 2, 2); home.chmod(0o700)
        for part in ('data', 'shared', 'agents'):
            (home / part).mkdir(exist_ok=True)
            os.chown(home / part, 2, 2); (home / part).chmod(0o700)
            (client / part).symlink_to(home / part, target_is_directory=True)
        env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'}
        def agent_uid():
            os.setgroups([]); os.setgid(2); os.setuid(2)
        oauth = base / 'oauth'; oauth.mkdir(mode=0o700); os.chown(oauth, 1, 1)
        denied = subprocess.run(['/usr/bin/python3', '-c', 'import os,sys; sys.exit(1 if os.access(sys.argv[1],os.R_OK) else 0)', str(oauth)], preexec_fn=agent_uid)
        assert denied.returncode == 0
        try:
            values = {}
            for key in ['providers.models.openai.siwc.model', 'providers.models.openai.siwc.context_window',
                        'runtime_profiles.siwc.max_context_tokens', 'runtime_profiles.siwc.context_compact_ratio',
                        'runtime_profiles.siwc.history_pruning.enabled', 'reliability.provider_retries',
                        'gateway.require_pairing', 'gateway.host']:
                p = subprocess.run([BINARY, '--config-dir', str(client), 'config', 'get', key],
                                   env=env, preexec_fn=agent_uid, capture_output=True, text=True, timeout=20)
                if p.returncode:
                    print(json.dumps({'config_get_failed': key, 'exit': p.returncode,
                                      'read_only_error': 'Read-only' in p.stderr,
                                      'permission_error': 'Permission denied' in p.stderr}))
                    return 1
                assert cap not in p.stdout and cap not in p.stderr
                values[key] = p.stdout.strip()
            print(json.dumps({'config_values': values}))
            with (base / 'stdout').open('w') as out, (base / 'stderr').open('w') as err:
                proc = subprocess.Popen([BINARY, '--config-dir', str(client), '--log-level', 'error',
                                         'daemon', '--host', '127.0.0.1', '--port', '42617'],
                                        env=env, preexec_fn=agent_uid, stdout=out, stderr=err)
                healthy = False
                try:
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline and proc.poll() is None:
                        try:
                            conn = http.client.HTTPConnection('127.0.0.1', 42617, timeout=.2)
                            conn.request('GET', '/health'); response = conn.getresponse(); response.read(); conn.close()
                            if response.status == 200:
                                healthy = True
                                listeners = []
                                for table in ('tcp', 'tcp6'):
                                    for row in Path('/proc/net/' + table).read_text().splitlines()[1:]:
                                        fields = row.split()
                                        if fields[3] == '0A': listeners.append(fields[1])
                                assert listeners == [f'0100007F:{42617:04X}'], ('unexpected listeners', listeners)
                                break
                        except OSError:
                            pass
                        time.sleep(.1)
                finally:
                    proc.terminate()
                    try: proc.wait(timeout=5)
                    except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
            stderr = (base / 'stderr').read_text()
            stdout = (base / 'stdout').read_text()
            print(json.dumps({'daemon_health_200': healthy,
                              'read_only_error': 'Read-only' in stderr,
                              'permission_error': 'Permission denied' in stderr,
                              'capability_in_output': cap in stdout or cap in stderr,
                              'native_oauth_profiles_created': any(base.rglob('auth-profiles.json')),
                              'data_files_created': len(list(data.rglob('*')))}))
            assert healthy, 'daemon failed read-only-config startup (raw output deliberately suppressed)'
            assert cap not in stdout + stderr
            assert not any(base.rglob('auth-profiles.json'))
            assert list(data.rglob('*')), 'persistent data path was not used'
            assert all(cap.encode() not in f.read_bytes() for f in home.rglob('*') if f.is_file()), 'capability leaked into persistent state'
            return 0
        finally:
            subprocess.run(['umount', str(config)], check=True)


if __name__ == '__main__': raise SystemExit(main())
