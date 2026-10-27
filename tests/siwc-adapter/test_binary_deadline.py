"""Real retained ARM client must fail, not succeed on worker deadline EOF."""
import http.server
import json
import multiprocessing
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from test_runtime import load, ROOT

BINARY = '/nix/store/adkc7f6i4b46gaf1296ir59whcjva4cl-zeroclaw-0.8.6/bin/zeroclaw'
CAP = 'synthetic-capability-for-offline-tests-only'


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]


def wait_port(port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            socket.create_connection(('127.0.0.1', port), .05).close(); return
        except OSError: time.sleep(.01)
    raise RuntimeError('startup timeout')


def upstream(port, count):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_POST(self):
            with count.get_lock(): count.value += 1
            self.rfile.read(int(self.headers['Content-Length']))
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close'); self.end_headers()
            self.wfile.write(b'data: {"type":"response.output_text.delta","delta":"PARTIAL-DEADLINE-MUST-FAIL"}\n\n')
            self.wfile.flush()
            time.sleep(5)
    http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()


def adapter(port, upstream_port, count, force_kill=False):
    os.setsid()
    a = load(); a._CACHED_CAPABILITY_VALUE = CAP
    a.UPSTREAM_PORT = upstream_port
    a.MAX_REQUEST_SECONDS = .7; a.MAX_TOTAL_SECONDS = .3
    a.IDLE_READ_TIMEOUT_SECONDS = 2
    original = a.Handler.do_POST
    def counted(self):
        with count.get_lock(): count.value += 1
        return original(self)
    a.Handler.do_POST = counted
    if force_kill:
        # Exercise the independent supervisor, not the child's soft alarm.
        a.OneRequestHandler.arm_inference_deadline = lambda self: signal.signal(signal.SIGALRM, signal.SIG_IGN)
    a.run_server(port)


class BinaryDeadline(unittest.TestCase):
    def test_partial_stream_worker_death_is_nonzero_once(self):
        self.run_case(False, 1)

    def test_forced_sigkill_fails_without_upstream_replay(self):
        self.run_case(True, 2)

    def run_case(self, force_kill, expected_ingress):
        self.assertEqual(sorted(n for _, n in socket.if_nameindex()), ['lo'])
        port, up = free_port(), free_port()
        ingress, upstream_count = multiprocessing.Value('i', 0), multiprocessing.Value('i', 0)
        processes = [multiprocessing.Process(target=upstream, args=(up, upstream_count)),
                     multiprocessing.Process(target=adapter, args=(port, up, ingress, force_kill))]
        for p in processes: p.start()
        try:
            wait_port(up); wait_port(port)
            with tempfile.TemporaryDirectory(prefix='siwc-deadline-') as d:
                root = Path(d); config = root / 'config'; config.mkdir(); home = root / 'home'; home.mkdir()
                template = (ROOT / 'packages/siwc-adapter/config.toml.in').read_text()
                template = template.replace('@CAPABILITY@', CAP).replace('127.0.0.1:18766', f'127.0.0.1:{port}')
                (config / 'config.toml').write_text(template); (config / 'config.toml').chmod(0o600)
                try:
                    p = subprocess.run([BINARY, '--config-dir', str(config), '--log-level', 'error',
                                        'agent', '-a', 'pi4', '-m', 'Say hello.'],
                                       env={'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
                                       capture_output=True, text=True, timeout=20)
                except subprocess.TimeoutExpired:
                    self.fail('outer timeout is not a passing failure result')
                print(json.dumps({'client_exit': p.returncode, 'ingress': ingress.value,
                                  'upstream': upstream_count.value, 'outer_timeout': False}))
                self.assertEqual(ingress.value, expected_ingress)
                self.assertEqual(upstream_count.value, 1)
                self.assertNotEqual(p.returncode, 0, 'worker death was accepted as successful partial output')
                self.assertNotIn(CAP, p.stdout + p.stderr)
        finally:
            for p in processes:
                if p.is_alive():
                    if p == processes[1]: os.killpg(p.pid, signal.SIGKILL)
                    else: p.terminate()
                p.join(timeout=3)


if __name__ == '__main__': unittest.main()
