"""Offline transport regressions; run in an isolated loopback namespace."""
import importlib.util
import multiprocessing
import os
from pathlib import Path
import signal
import socket
import time
import unittest
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


def upstream_worker(port, payload):
    class Upstream(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            if isinstance(payload, tuple) and payload[0] == 'refresh_stall':
                payload[1].set(); time.sleep(5); return
            if payload == 'slow_headers':
                try:
                    for byte in b'HTTP/1.1 200 OK\r\nX-Trickle: ' + b'x' * 100:
                        self.connection.send(bytes([byte])); time.sleep(.03)
                except OSError: pass
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                if payload == 'slow_sse':
                    for byte in b'data: ' + b'x' * 100:
                        self.wfile.write(bytes([byte])); self.wfile.flush(); time.sleep(.03)
                else:
                    self.wfile.write(payload)
            except OSError: pass
    HTTPServer(('127.0.0.1', port), Upstream).serve_forever()

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get('ADAPTER_SOURCE', ROOT / 'packages/siwc-adapter/filtering_adapter.py'))
if not SOURCE.exists() and 'ADAPTER_SOURCE' not in os.environ:
    SOURCE = ROOT.parent / 'spikes/siwc-adapter/adapter/filtering_adapter.py'


def load():
    spec = importlib.util.spec_from_file_location('adapter', SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def worker(port, settings):
    os.setsid()
    a = load()
    a._CACHED_CAPABILITY_VALUE = 'synthetic-capability-for-offline-tests-only'
    delay = settings.pop('refresh_delay', 0)
    if delay:
        import types
        a.SIWC_STATE_DIR = '/synthetic-unused'
        a.SIWC_MODULE = types.SimpleNamespace(SafeError=RuntimeError)
        def fresh():
            time.sleep(delay)
            return 'synthetic-access', {}
        a.ensure_fresh_access_token = fresh
    stall_state = settings.pop('stall_state', None)
    if stall_state:
        a.SIWC_STATE_DIR = stall_state
        class StallClient(a.load_siwc().Client):
            def __init__(self):
                super().__init__()
                request = self.session.request
                self.session.request = lambda method, url, **kwargs: request(
                    method, f"http://127.0.0.1:{settings['UPSTREAM_PORT']}/token", **kwargs)
            def get_jwks(self): return {'keys': []}
        a.REFRESH_CLIENT_FACTORY = StallClient
    for key, value in settings.items():
        setattr(a, key, value)
    a.run_server(port)


class Transport(unittest.TestCase):
    def setUp(self):
        self.assertEqual(sorted(n for _, n in socket.if_nameindex()), ['lo'])
        s = socket.socket(); s.bind(('127.0.0.1', 0))
        self.port = s.getsockname()[1]; s.close()
        s = socket.socket(); s.bind(('127.0.0.1', 0))
        self.upstream_port = s.getsockname()[1]; s.close()
        self.upstream_process = None
        self.start_adapter({})

    def start_adapter(self, settings):
        if hasattr(self, 'process') and self.process.is_alive():
            os.killpg(self.process.pid, signal.SIGKILL); self.process.join(timeout=2)
        config = {'MAX_REQUEST_SECONDS': .35, 'IDLE_READ_TIMEOUT_SECONDS': 2,
                  'MAX_CONNECTIONS': 2, 'MAX_TOTAL_SECONDS': .25,
                  'UPSTREAM_PORT': self.upstream_port, 'MAX_FRAME_BYTES': 256}
        config.update(settings)
        self.process = multiprocessing.Process(target=worker, args=(self.port, config))
        self.process.start()
        deadline = time.monotonic() + 3
        while True:
            try:
                with socket.create_connection(('127.0.0.1', self.port), timeout=.05):
                    break
            except OSError:
                if time.monotonic() > deadline:
                    self.fail('server did not start')
                time.sleep(.01)
        time.sleep(.1)

    def tearDown(self):
        if self.process.is_alive():
            os.killpg(self.process.pid, signal.SIGKILL)
        self.process.join(timeout=2)
        if self.upstream_process:
            self.upstream_process.terminate(); self.upstream_process.join(timeout=2)

    def start_upstream(self, payload):
        self.upstream_process = multiprocessing.Process(target=upstream_worker, args=(self.upstream_port, payload))
        self.upstream_process.start()
        for _ in range(100):
            try:
                socket.create_connection(('127.0.0.1', self.upstream_port), .05).close()
                return
            except OSError:
                time.sleep(.01)
        self.fail('upstream did not start')

    def request(self):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
        conn.request('POST', '/v1/responses', b'{"stream":true,"store":false}',
                     {'Authorization': 'Bearer synthetic-capability-for-offline-tests-only'})
        r = conn.getresponse()
        status, body = r.status, r.read()
        conn.close()
        return status, body

    def test_oversized_frame_not_forwarded(self):
        payload = b'data: {"type":"response.output_text.delta","delta":"FRAME_CANARY' + b'x' * 300 + b'"}\n\n'
        payload += b'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n'
        self.start_upstream(payload)
        status, body = self.request()
        self.assertEqual(status, 200)
        self.assertNotIn(b'FRAME_CANARY', body)
        self.assertIn(b'"type": "error"', body)

    def test_connect_failure_has_fixed_error(self):
        try:
            status, body = self.request()
        except Exception:
            self.fail('transport failure closed without the fixed HTTP error')
        self.assertEqual(status, 502)
        self.assertIn(b'Upstream did not confirm a completed response.', body)
        self.assertNotIn(b'Traceback', body)

    def test_refresh_does_not_consume_inference_budget(self):
        self.start_adapter({'refresh_delay': .3, 'MAX_REQUEST_SECONDS': 2, 'MAX_TOTAL_SECONDS': .2})
        self.start_upstream(b'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n')
        status, body = self.request()
        self.assertEqual(status, 200)
        self.assertIn(b'response.completed', body)
        self.assertNotIn(b'"type": "error"', body)

    def assert_workers_reaped(self):
        path = Path(f'/proc/{self.process.pid}/task/{self.process.pid}/children')
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if not path.read_text().strip(): return
            time.sleep(.02)
        self.fail('request process survived deadline')

    def test_slow_authenticated_body_is_killed(self):
        with socket.create_connection(('127.0.0.1', self.port)) as s:
            s.sendall(b'POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer synthetic-capability-for-offline-tests-only\r\nContent-Length: 4096\r\n\r\n')
            for _ in range(10):
                try: s.sendall(b'x')
                except OSError: break
                time.sleep(.05)
            self.assert_workers_reaped()

    def test_trickling_upstream_headers_is_killed(self):
        self.start_upstream('slow_headers')
        status, _ = self.request()
        self.assertEqual(status, 503)
        self.assert_workers_reaped()

    def test_trickling_sse_is_killed(self):
        self.start_upstream('slow_sse')
        status, body = self.request()
        self.assertEqual(status, 200)
        self.assertIn(b'"type": "error"', body)
        self.assert_workers_reaped()

    def test_nonreading_consumer_is_killed(self):
        payload = (b'data: {"type":"response.output_text.delta","delta":"' + b'x' * 150 + b'"}\n\n') * 30000
        self.start_upstream(payload)
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            s.connect(('127.0.0.1', self.port))
            s.sendall(b'POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer synthetic-capability-for-offline-tests-only\r\nContent-Length: 29\r\n\r\n{"stream":true,"store":false}')
            time.sleep(.6)
            self.assert_workers_reaped()

    def test_refresh_stall_preserves_marker_releases_lock(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            a = load(); siwc = a.load_siwc(); state = Path(d) / 'state'
            with siwc.locked_state(state):
                siwc.atomic_json(state / 'credentials.json', {
                    'expires_at': 0, 'earliest_refresh_at': None, 'saved_at': 0,
                    'client_id': 'synthetic', 'refresh_token': 'synthetic', 'access_token': 'synthetic'})
            delivered = multiprocessing.Event()
            self.start_upstream(('refresh_stall', delivered))
            self.start_adapter({'stall_state': str(state)})
            status = None
            transport_closed = False
            try:
                status, _ = self.request()
            except __import__('http.client').client.RemoteDisconnected:
                transport_closed = True

            # Evaluate every independent fail-closed invariant even when the
            # request process is killed before it can write the expected 503.
            with self.subTest('refresh POST delivered'):
                self.assertTrue(delivered.is_set(), 'no HTTP refresh POST reached the synthetic server')
            with self.subTest('request worker reaped'):
                self.assert_workers_reaped()
            with self.subTest('in-flight marker retained'):
                self.assertTrue((state / 'refresh-inflight.json').exists())

            lock_rejected = False
            unexpected_lock_error = None
            try:
                with siwc.locked_state(state):
                    siwc.refresh_session(state, object())
            except siwc.SafeError:
                lock_rejected = True
            except Exception as error:
                unexpected_lock_error = type(error).__name__
            with self.subTest('subsequent refresh rejected safely'):
                self.assertIsNone(unexpected_lock_error)
                self.assertTrue(lock_rejected)

            # Retain the original transport contract: a closed connection is
            # evidence, not an acceptable replacement for the fixed HTTP 503.
            with self.subTest('fixed HTTP 503 returned'):
                self.assertFalse(transport_closed, 'remote end closed without the fixed HTTP error')
                self.assertEqual(status, 503)

    def test_connection_admission_is_bounded(self):
        sockets = [socket.create_connection(('127.0.0.1', self.port)) for _ in range(3)]
        try:
            time.sleep(.1)
            path = Path(f'/proc/{self.process.pid}/task/{self.process.pid}/children')
            self.assertLessEqual(len(path.read_text().split()), 2)
            sockets[-1].settimeout(.2)
            self.assertEqual(sockets[-1].recv(1), b'')
        finally:
            for s in sockets: s.close()

    def test_large_body_and_oversized_length(self):
        import http.client, json
        self.start_adapter({'MAX_REQUEST_SECONDS': 3, 'MAX_TOTAL_SECONDS': 1})
        self.start_upstream(b'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n')
        body = json.dumps({'stream': True, 'store': False, 'input': 'x' * (3 * 1024 * 1024)})
        # Use an upstream that drains the upload, matching production HTTP.
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=4)
        c.request('POST', '/v1/responses', body, {'Authorization': 'Bearer synthetic-capability-for-offline-tests-only'})
        r = c.getresponse(); self.assertEqual(r.status, 200); self.assertIn(b'response.completed', r.read()); c.close()
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
        c.request('POST', '/v1/responses', headers={'Authorization': 'Bearer synthetic-capability-for-offline-tests-only', 'Content-Length': str(32 * 1024 * 1024 + 1)})
        self.assertEqual(c.getresponse().status, 400); c.close()

    def test_missing_capability_fails_without_traceback(self):
        p = subprocess.run([sys.executable, '-B', str(SOURCE), '--listen-port', '18766',
                            '--state-dir', '/does-not-exist', '--capability-file', '/does-not-exist'],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        self.assertNotIn('Traceback', p.stderr)

    def test_cli_has_bounded_limit_configuration(self):
        r = subprocess.run([sys.executable, '-B', str(SOURCE), '--help'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        for flag in ('--max-request-bytes', '--max-frame-bytes', '--max-stream-bytes',
                     '--max-connections', '--request-seconds', '--inference-seconds', '--idle-seconds'):
            self.assertIn(flag, r.stdout)
        r = subprocess.run([sys.executable, '-B', str(SOURCE), '--listen-port', '1',
                            '--state-dir', '/does-not-exist', '--capability-file', '/does-not-exist',
                            '--request-seconds', 'nan'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertNotIn('Traceback', r.stderr)

    def test_slow_headers_have_wall_deadline(self):
        with socket.create_connection(('127.0.0.1', self.port)) as s:
            s.settimeout(.05)
            start = time.monotonic()
            s.sendall(b'POST /v1/responses HTTP/1.1\r\nX-Slow: ')
            closed = False
            while time.monotonic() - start < 1.2:
                try:
                    s.sendall(b'x')
                    if s.recv(1) == b'':
                        closed = True; break
                except socket.timeout:
                    pass
                except (BrokenPipeError, ConnectionResetError):
                    closed = True; break
            self.assertTrue(closed, 'trickling headers survived the absolute deadline')
            self.assertLess(time.monotonic() - start, 1.2)


class Capability(unittest.TestCase):
    def test_tool_tracking_is_bounded(self):
        a = load(); a.MAX_TOOL_CALLS = 2; a.MAX_TOOL_ARGUMENT_BYTES = 8
        tracked = {}
        def added(i, arguments=''):
            return {'type': 'response.output_item.added', 'item': {
                'type': 'function_call', 'id': str(i), 'call_id': str(i),
                'name': 'calculator', 'arguments': arguments}}
        self.assertIsNone(a.track_incremental_tool_call(tracked, added(1)))
        self.assertIsNone(a.track_incremental_tool_call(tracked, added(2)))
        self.assertIsNotNone(a.track_incremental_tool_call(tracked, added(3)))
        self.assertIsNotNone(a.track_incremental_tool_call({}, added(1, 'x' * 9)))
        self.assertIsNotNone(a.track_incremental_tool_call(tracked, {
            'type': 'response.function_call_arguments.delta', 'item_id': '1', 'delta': 'x' * 9}))

    def test_opened_descriptor_validation_and_bounded_content(self):
        import tempfile
        import types
        with tempfile.TemporaryDirectory() as d:
            a = load(); a.SIWC_MODULE = types.SimpleNamespace(SafeError=RuntimeError)
            p = Path(d) / 'cap'; p.write_text('c' * 64); p.chmod(0o600)
            self.assertEqual(a.load_capability_value(p), 'c' * 64)
            link = Path(d) / 'link'; link.symlink_to(p)
            with self.assertRaises(RuntimeError):
                a.load_capability_value(link)
            p.write_text('c' * 10000)
            with self.assertRaises(RuntimeError):
                a.load_capability_value(p)
            p.write_text('c' * 64); p.chmod(0o644)
            with self.assertRaises(RuntimeError):
                a.load_capability_value(p)


if __name__ == '__main__':
    unittest.main()
