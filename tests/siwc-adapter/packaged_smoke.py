"""Smoke test the built ARM shell wrapper/Python environment, synthetic state only."""
import http.client
import multiprocessing
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
from test_runtime import load, upstream_worker
from test_binary_deadline import free_port, wait_port


def main():
    assert sorted(n for _, n in socket.if_nameindex()) == ['lo']
    package = Path(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix='siwc-package-') as d:
        root = Path(d); cap = root / 'capability'; cap.write_text(secrets.token_hex(32)); cap.chmod(0o600)
        state = root / 'state'; siwc = load().load_siwc()
        with siwc.locked_state(state):
            siwc.atomic_json(state / 'credentials.json', {
                'expires_at': time.time() + 3600, 'earliest_refresh_at': None,
                'access_token': 'synthetic-only', 'saved_at': time.time()})
        port, up = free_port(), free_port()
        mock = multiprocessing.Process(target=upstream_worker, args=(up,
            b'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n'))
        mock.start(); adapter = None
        try:
            wait_port(up)
            adapter = subprocess.Popen([str(package / 'bin/pi4-siwc-adapter'), '--listen-port', str(port),
                '--state-dir', str(state), '--capability-file', str(cap), '--test-upstream', f'http://127.0.0.1:{up}'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            wait_port(port)
            c = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
            c.request('POST', '/v1/responses', b'{"stream":true,"store":false,"model":"gpt-5.6-sol"}',
                      {'Authorization': 'Bearer ' + cap.read_text()})
            response = c.getresponse(); assert response.status == 200
            assert b'response.completed' in response.read(); c.close()
            print('PASS: packaged ARM wrapper, isolated Python dependencies, synthetic credential path, completed response')
        finally:
            if adapter:
                os.killpg(adapter.pid, signal.SIGKILL)
                stdout, stderr = adapter.communicate(timeout=5)
                assert cap.read_bytes() not in stdout + stderr
                assert b'synthetic-only' not in stdout + stderr
            mock.terminate(); mock.join(timeout=3)


if __name__ == '__main__': main()
