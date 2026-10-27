"""Authenticated SIWC Responses adapter, verified offline with ZeroClaw 0.8.6.

Secure CLI: --listen-port PORT --state-dir PATH --capability-file PATH.
The default upstream is pinned HTTPS; the existing shared siwc helper owns
credential locking, rotation and ambiguity recovery. No tokens are passed in
arguments. Test-only loopback overrides require namespace isolation.

Relay complete SSE records without whole-response buffering. Require a verified
response.completed, reject tool-identity/history inconsistencies before forwarding,
and emit the error shape the actual consumer recognizes. Logs contain decision
codes, never OAuth credentials or tool-argument values.

Nix substitutes the shared helper's immutable source path when packaging.
Production bounds and deployment limitations are documented in pi4-siwc-adapter.md.
"""
import hmac
import http.client
import ipaddress
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer, HTTPServer
import signal
import socket

MAX_REQUEST_SECONDS = 360
MAX_CONNECTIONS = 4

UPSTREAM_HOST = '127.0.0.1'
UPSTREAM_PORT = None
DECISION_LOG = None
UPSTREAM_SCHEME = 'http'
CAPABILITY_FILE = None
SIWC_STATE_DIR = None
SIWC_MODULE = None
MIN_CAPABILITY_LEN = 32

# Cached once at startup (N2): never re-opened per request, so a
# capability file widened or re-owned after startup does not retroactively
# become trusted mid-run.
_CACHED_CAPABILITY_VALUE = None

# Deny-by-default (N3): a Handler constructed without going through
# main()/legacy_test_harness_main() -- e.g. an in-process test harness
# that sets CAPABILITY_FILE directly -- must still refuse unauthenticated
# traffic unless this is explicitly set True by the same sanctioned
# module-attribute seam as REFRESH_CLIENT_FACTORY. There is no CLI/env
# path to it.
INSECURE_TEST_MODE_ACKNOWLEDGED = False

SIWC_PY_PATH = '/home/kyll/Documents/pi-nix/nixos-base/packages/chatgpt-auth/siwc.py'
PRODUCTION_UPSTREAM_URL = 'https://api.openai.com/v1/responses'  # == siwc.RESOURCE + '/responses'

EXPECTED_PATH = '/v1/responses'
FIXED_ERROR_MESSAGE = 'Upstream did not confirm a completed response.'
TERMINAL_OR_SUSPECT_TYPES = {
    'response.completed', 'response.done', 'response.incomplete',
    'response.failed', 'error',
}

MAX_REQUEST_BYTES = 32 * 1024 * 1024
MAX_FORWARD_BYTES = 8 * 1024 * 1024
MAX_FRAME_BYTES = 4 * 1024 * 1024
MAX_TOOL_CALLS = 128
MAX_TOOL_ARGUMENT_BYTES = 1024 * 1024
MAX_TOTAL_SECONDS = 180
IDLE_READ_TIMEOUT_SECONDS = 30


def log_decision(record):
    if not DECISION_LOG:
        return
    with open(DECISION_LOG, 'a') as handle:
        handle.write(json.dumps(record) + '\n')


def error_frame():
    return ('data: ' + json.dumps({'type': 'error', 'message': FIXED_ERROR_MESSAGE})
            + '\n\n').encode()


def classify(joined_data):
    """Return (verdict, parsed_event_or_None). verdict is 'completed',
    'terminal_unverified', or 'pass'."""
    if joined_data == '[DONE]':
        return 'terminal_unverified', None
    try:
        event = json.loads(joined_data)
    except json.JSONDecodeError:
        return 'terminal_unverified', None
    if not isinstance(event, dict):
        # A JSON array/number/string/null is not a valid SSE event frame
        # -- treat it exactly like a decode failure, not as something to
        # call .get() on.
        return 'terminal_unverified', None
    kind = event.get('type')
    if not isinstance(kind, str):
        return 'terminal_unverified', event
    if kind not in TERMINAL_OR_SUSPECT_TYPES:
        return 'pass', event
    if kind == 'response.completed' and isinstance(event.get('response'), dict) and event['response'].get('status') == 'completed':
        return 'completed', event
    return 'terminal_unverified', event


class ToolCalls(dict):
    """Tool map plus response identity; metadata never counts as a tool."""
    response_id: str | None = None


def validate_response_identity(tracked, event):
    ids = []
    if 'response_id' in event:
        ids.append(event['response_id'])
    response = event.get('response')
    if isinstance(response, dict) and 'id' in response:
        ids.append(response['id'])
    for identity in ids:
        if not isinstance(identity, str) or not identity:
            return {'reason': 'invalid_response_id'}
        if isinstance(tracked, ToolCalls):
            if tracked.response_id is not None and identity != tracked.response_id:
                return {'reason': 'response_identity_changed'}
            tracked.response_id = identity
    return None


def track_incremental_tool_call(tracked, event):
    """Validate before forwarding; never overwrite previously announced identity."""
    violation = validate_response_identity(tracked, event)
    if violation:
        return violation
    kind = event.get('type')
    if kind not in ('response.output_item.added', 'response.output_item.done',
                    'response.function_call_arguments.delta', 'response.function_call_arguments.done'):
        return None
    is_item = kind in ('response.output_item.added', 'response.output_item.done')
    item = event.get('item') if is_item else event
    if not isinstance(item, dict):
        return {'reason': 'invalid_item_shape'}
    if is_item and item.get('type') != 'function_call':
        identity = item.get('id')
        if not isinstance(identity, (str, type(None))):
            return {'reason': 'invalid_item_id'}
        if identity in tracked or ('output_index' in event and any(
                e.get('_index') == event['output_index'] for e in tracked.values())):
            return {'reason': 'incremental_type_changed'}
        return None
    if 'status' in item:
        allowed = ('in_progress', 'completed') if kind == 'response.output_item.added' else ('completed',)
        if item['status'] not in allowed:
            return {'reason': 'invalid_tool_status'}
    if 'output_index' in event and (type(event['output_index']) is not int or event['output_index'] < 0):
        return {'reason': 'invalid_output_index'}
    arguments = item.get('delta', item.get('arguments', ''))
    if isinstance(arguments, str) and len(arguments.encode()) > MAX_TOOL_ARGUMENT_BYTES:
        return {'reason': 'tool_argument_cap_exceeded'}
    item_id = item.get('id') if is_item else item.get('item_id')
    if not isinstance(item_id, str) or not item_id:
        return {'reason': 'missing_item_id'}
    if kind == 'response.output_item.added':
        if len(tracked) >= MAX_TOOL_CALLS:
            return {'reason': 'tool_count_cap_exceeded'}
        if item_id in tracked:
            return {'reason': 'duplicate_item_id'}
        if any(not isinstance(item.get(f), str) or not item[f] for f in ('call_id', 'name')):
            return {'reason': 'missing_tool_identity'}
        if not isinstance(item.get('arguments', ''), str):
            return {'reason': 'invalid_arguments'}
        if any(e['call_id'] == item['call_id'] for e in tracked.values()):
            return {'reason': 'duplicate_call_id'}
        if 'output_index' in event and any(e.get('_index') == event['output_index'] for e in tracked.values()):
            return {'reason': 'duplicate_output_index'}
        tracked[item_id] = {f: item.get(f, '') for f in ('call_id', 'name', 'arguments')}
        if 'output_index' in event:
            tracked[item_id]['_index'] = event['output_index']
        tracked[item_id]['_delta_seen'] = False
        return None
    entry = tracked.get(item_id)
    if entry is None:
        return {'reason': 'unannounced_item_id'}
    if 'output_index' in event:
        index = event['output_index']
        if '_index' in entry and entry['_index'] != index:
            return {'reason': 'output_index_changed'}
        if any(e is not entry and e.get('_index') == index for e in tracked.values()):
            return {'reason': 'duplicate_output_index'}
        entry['_index'] = index
    if kind == 'response.output_item.done' and any(f not in item for f in ('call_id', 'name', 'arguments')):
        return {'reason': 'missing_tool_identity'}
    for field in ('call_id', 'name'):
        if field in item and item[field] != entry[field]:
            return {'reason': 'incremental_identity_changed', 'field': field}
    if kind == 'response.function_call_arguments.delta':
        delta = item.get('delta')
        if not isinstance(delta, str) or entry.get('_done'):
            return {'reason': 'invalid_argument_delta'}
        if len(entry['arguments'].encode()) + len(delta.encode()) > MAX_TOOL_ARGUMENT_BYTES:
            return {'reason': 'tool_argument_cap_exceeded'}
        entry['arguments'] += delta
        entry['_delta_seen'] = True
    else:
        arguments = item.get('arguments')
        if not isinstance(arguments, str):
            return {'reason': 'invalid_arguments'}
        if (entry['arguments'] or entry['_delta_seen'] or entry.get('_done')) and arguments != entry['arguments']:
            return {'reason': 'incremental_arguments_changed'}
        entry['arguments'] = arguments
        entry['_done'] = True
        if kind == 'response.output_item.done':
            entry['_item_done'] = True
    return None


def find_integrity_violation(tracked, completion_event):
    """Compare tool sets and identities, returning fixed codes, never payloads."""
    violation = validate_response_identity(tracked, completion_event)
    if violation:
        return violation
    response = completion_event.get('response')
    if not isinstance(response, dict):
        return {'reason': 'invalid_response_shape'}
    output = response.get('output') if tracked else response.get('output', [])
    if not isinstance(output, list):
        return {'reason': 'invalid_output_shape'}
    # Approved compatibility exception: explicit empty array only. Item-final
    # evidence is independent of arguments.done; never synthesize output/history.
    if output == [] and tracked and all(e.get('_item_done') for e in tracked.values()):
        return None
    seen = set()
    for output_index, item in enumerate(output):
        if not isinstance(item, dict):
            return {'reason': 'invalid_output_item'}
        if item.get('type') != 'function_call':
            identity = item.get('id')
            if not isinstance(identity, (str, type(None))):
                return {'reason': 'invalid_item_id'}
            if identity in tracked:
                return {'reason': 'completion_type_changed'}
            continue
        if 'status' in item and item['status'] != 'completed':
            return {'reason': 'invalid_tool_status'}
        item_id = item.get('id')
        if not isinstance(item_id, str) or not item_id:
            return {'reason': 'missing_item_id'}
        if item_id in seen:
            return {'reason': 'duplicate_item_id'}
        seen.add(item_id)
        if item_id not in tracked:
            return {'reason': 'unannounced_item_id'}
        if '_index' in tracked[item_id] and tracked[item_id]['_index'] != output_index:
            return {'reason': 'output_index_changed'}
        for field in ('call_id', 'name', 'arguments'):
            if item.get(field) != tracked[item_id].get(field):
                return {'reason': 'completion_mismatch', 'field': field}
    if seen != set(tracked):
        return {'reason': 'omitted_tool_call'}
    return None


def load_siwc():
    global SIWC_MODULE
    if SIWC_MODULE is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location('siwc', SIWC_PY_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        SIWC_MODULE = module
    return SIWC_MODULE


def load_capability_value(capability_file):
    """Validate the opened fd, not a pathname that can change before open."""
    import stat
    siwc = load_siwc()
    try:
        fd = os.open(capability_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 4096):
                raise siwc.SafeError('Capability file metadata is unsafe.')
            raw = handle.read(4097)
        value = raw.decode('ascii').strip()
        if len(raw) > 4096 or not MIN_CAPABILITY_LEN <= len(value) <= 4096:
            raise siwc.SafeError('Capability file content length is invalid.')
        if any(ord(c) < 33 or ord(c) > 126 for c in value):
            raise siwc.SafeError('Capability file content is invalid.')
        return value
    except (OSError, UnicodeError):
        raise siwc.SafeError('Capability file cannot be safely read.') from None


def capability_auth_ok(headers):
    """Constant-time check of the inbound capability token against the
    value cached at startup by load_capability_value(). Never logs the
    token value on either side -- only whether it matched.

    Absent capability config does NOT mean "allow": do_POST only skips
    this check when INSECURE_TEST_MODE_ACKNOWLEDGED is explicitly True
    (N3) -- there is no silent unauthenticated production fallback."""
    auth_header = headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        return False
    presented = auth_header[len('Bearer '):].strip()
    if not presented or not _CACHED_CAPABILITY_VALUE:
        return False
    return hmac.compare_digest(presented.encode(), _CACHED_CAPABILITY_VALUE.encode())


class FakeRefreshClient:
    """Synthetic transport for TESTS ONLY -- no `requests`, no real
    network, ever. Matches the shape `siwc.refresh_session` needs from a
    `Client`: `get_jwks()` and `request(method, url, **kwargs)`
    returning a context manager with `.json()`.

    This class must never be the default. A test harness that wants
    deterministic synthetic rotation sets
    `filtering_adapter.REFRESH_CLIENT_FACTORY = lambda: FakeRefreshClient(...)`
    on the imported module *before* starting the server -- there is no
    command-line or environment-variable path to enable it, precisely so
    a production invocation can't acquire it by accident."""

    class _Ctx:
        def __init__(self, payload):
            self._payload = payload

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def json(self):
            return self._payload

    def __init__(self, new_access_token, new_refresh_token):
        self.new_access_token = new_access_token
        self.new_refresh_token = new_refresh_token

    def get_jwks(self):
        return {'keys': []}

    def request(self, method, url, **kwargs):
        return self._Ctx({
            'token_type': 'Bearer', 'access_token': self.new_access_token,
            'refresh_token': self.new_refresh_token, 'expires_in': 3600,
            'scope': 'chatgpt.tokens.use.direct resource.invoke offline_access',
        })


def default_refresh_client():
    """Production default: the real, unmodified `siwc.Client` -- real
    `requests`, real TOKEN/JWKS URLs. Offline tests enforce their own
    loopback-only network namespace; production intentionally uses TLS."""
    return load_siwc().Client()


# The one sanctioned injection seam. A module-level attribute, not a CLI
# flag or env var -- a test harness imports this module and overwrites
# it directly before starting the server, which is deliberately not
# something a production command line can trigger.
REFRESH_CLIENT_FACTORY = default_refresh_client


def ensure_fresh_access_token():
    """Acquire the real (unmodified) `locked_state`/`refresh_session`,
    held only for the refresh itself -- not through the subsequent SSE
    relay. Returns (access_token, decision_note). Raises the module's
    own SafeError on contention, an ambiguous prior outcome, or a
    refreshed-but-still-expired result; the caller must fail the request
    closed, not retry blindly, not use a stale token."""
    siwc = load_siwc()
    import pathlib
    import time as _time
    with siwc.locked_state(pathlib.Path(SIWC_STATE_DIR)) as state:
        client = REFRESH_CLIENT_FACTORY()
        credentials, evidence = siwc.refresh_session(state, client)
    # refresh_due() can legitimately return "not due" even past
    # expires_at when `earliest_refresh_at` is set further out than
    # expires_at -- refresh_session() then hands back the SAME,
    # already-expired credentials unchanged. Never use an expired token
    # for the actual upstream call just because rotation wasn't due.
    if credentials['expires_at'] <= _time.time():
        raise siwc.SafeError('Access token expired or near expiry; refresh is required.')
    return credentials['access_token'], evidence


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send_frame(self, payload):
        # A killed worker MUST leave an incomplete chunked body, not clean EOF.
        self._sending_frame = True
        try:
            self.wfile.write(f'{len(payload):x}\r\n'.encode() + payload + b'\r\n')
            self.wfile.flush()
        finally:
            self._sending_frame = False

    def finish_frames(self):
        self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()

    def reject_noncompliant(self, reason, *_unused):
        """`reason` is always one of a small set of fixed codes -- never
        the raw path, body, or header values, which are caller-supplied
        and could carry a prompt or a secret. `*_unused` keeps the
        existing 4-arg call sites working during this cleanup without
        reflecting those values into the log."""
        body = json.dumps({'error': {'message': FIXED_ERROR_MESSAGE}}).encode()
        self.send_response(400)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        log_decision({'event': 'request', 'header_names': sorted(self.headers.keys()),
                      'decision': 'refused_noncompliant', 'reason': reason,
                      'upstream_contacted': False, 'http_status': 400, 'ts': time.time()})

    def reject_unauthorized(self):
        body = json.dumps({'error': {'message': FIXED_ERROR_MESSAGE}}).encode()
        self.send_response(401)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        # Deliberately no header_names/path here: an unauthenticated
        # caller gets nothing beyond "401", not even request-shape
        # evidence, and nothing about the capability token is logged.
        log_decision({'event': 'request', 'decision': 'unauthorized',
                      'upstream_contacted': False, 'http_status': 401, 'ts': time.time()})

    def do_POST(self):
        request_start = time.monotonic()
        # Capability auth first: before the body is read, before
        # upstream or local credential state is touched at all. Deny by
        # default (N3): this check runs regardless of how the Handler
        # was started -- only an explicit, disclosed
        # INSECURE_TEST_MODE_ACKNOWLEDGED (the same kind of module-
        # attribute-only seam as REFRESH_CLIENT_FACTORY, never CLI/env)
        # skips it. A Handler someone starts without going through
        # main()/legacy_test_harness_main() at all still refuses
        # unauthenticated traffic.
        if not INSECURE_TEST_MODE_ACKNOWLEDGED and not capability_auth_ok(self.headers):
            self.reject_unauthorized()
            return

        # Finite, validated HTTP framing before any read: no
        # Transfer-Encoding support (we only accept Content-Length), and
        # exactly one well-formed non-negative Content-Length -- not
        # negative, not non-numeric, not duplicated.
        if self.headers.get('Transfer-Encoding'):
            self.reject_noncompliant('transfer_encoding_not_supported', None, None, None)
            return
        content_length_values = self.headers.get_all('Content-Length') or []
        if len(content_length_values) > 1:
            self.reject_noncompliant('duplicate_content_length', None, None, None)
            return
        try:
            length = int(content_length_values[0]) if content_length_values else 0
            if length < 0:
                raise ValueError
        except ValueError:
            self.reject_noncompliant('invalid_content_length', None, None, None)
            return
        if length > MAX_REQUEST_BYTES:
            self.reject_noncompliant('request_body_exceeds_byte_budget', None, None, None)
            return
        raw_body = self.rfile.read(length) if length else b''
        try:
            parsed_body = json.loads(raw_body) if raw_body else {}
        except json.JSONDecodeError:
            parsed_body = {}
        if not isinstance(parsed_body, dict):
            # A JSON array/number/string/null body -- not a decode
            # failure, but not something to call .get() on either.
            parsed_body = {}
        stream = parsed_body.get('stream')
        store = parsed_body.get('store')
        header_names = sorted(self.headers.keys())

        # Fixed reason codes only -- never the raw path, prompt text, or
        # request body in a log line: the path is caller-supplied and
        # could itself carry something sensitive.
        if self.path != EXPECTED_PATH:
            self.reject_noncompliant('unexpected_path', None, None, None)
            return
        if stream is not True or store is not False:
            self.reject_noncompliant('contract_violation_stream_or_store', None, None, None)
            return

        decision = None
        http_status = None
        first_forward_rel = None
        integrity_violation = None

        # Pinned outbound header set (invariant G): never derived from
        # the inbound request. The client's own Content-Type,
        # Authorization, x-openai-*, chatgpt-account-id, originator --
        # none of it is read here, let alone forwarded.
        upstream_headers = {'Content-Type': 'application/json', 'Accept': 'text/event-stream'}
        if SIWC_STATE_DIR:
            siwc = load_siwc()
            try:
                access_token, refresh_evidence = ensure_fresh_access_token()
            except siwc.SafeError as exc:
                # Fails the request closed -- never retried blindly, no
                # upstream call made, no secret in the error shown.
                log_decision({'event': 'request',
                              'decision': 'credential_unavailable',
                              'reason': str(exc),  # siwc's own SafeError text is already non-secret
                              'upstream_contacted': False, 'http_status': 503, 'ts': time.time()})
                body = json.dumps({'error': {'message': FIXED_ERROR_MESSAGE}}).encode()
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body)
                return
            # Inject the internally-managed token; nothing from the
            # inbound request's own Authorization/identity headers is
            # ever forwarded upstream.
            upstream_headers['Authorization'] = f'Bearer {access_token}'

        deadline = time.monotonic() + MAX_TOTAL_SECONDS
        if hasattr(self, 'arm_inference_deadline'):
            self.arm_inference_deadline()

        # http.client.HTTPConnection/HTTPResponse, not a hand-rolled socket
        # parser: a real upstream streaming SSE almost always uses
        # `Transfer-Encoding: chunked` (length is unknown ahead of time),
        # and a hand-written status/header reader that forwards bytes
        # verbatim would relay the raw chunk-size/CRLF framing as if it
        # were SSE content while discarding the header that said how to
        # decode it. http.client dechunks transparently on `.read()`.
        conn_class = http.client.HTTPSConnection if UPSTREAM_SCHEME == 'https' else http.client.HTTPConnection
        conn = conn_class(UPSTREAM_HOST, UPSTREAM_PORT, timeout=IDLE_READ_TIMEOUT_SECONDS)
        headers_sent = False
        try:
            conn.request('POST', self.path, body=raw_body, headers=upstream_headers)
            response = conn.getresponse()
            http_status = response.status

            self.send_response(http_status)
            for name, value in response.getheaders():
                if name.lower() in ('connection', 'transfer-encoding', 'content-length'):
                    continue
                self.send_header(name, value)
            self.send_header('Connection', 'close')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            headers_sent = True
            self._headers_sent = True

            seen_completed = False
            terminated = False
            forwarded_bytes = 0
            pending = b''
            tracked_calls = ToolCalls()

            def emit_error_and_stop():
                nonlocal terminated
                self.send_frame(error_frame())
                self.wfile.flush()
                terminated = True

            while not terminated:
                if time.monotonic() > deadline:
                    emit_error_and_stop()
                    decision = 'time_cap_exceeded'
                    break
                try:
                    # read1(), not read(): read(n) on HTTPResponse can
                    # still wait to fill n bytes (or hit EOF) even when a
                    # complete dechunked record is already available --
                    # the same whole-response-buffering trap as the
                    # earlier raw-socket read() bug. read1() returns as
                    # soon as any dechunked data is available.
                    chunk = response.read1(4096)
                except (TimeoutError, OSError):
                    emit_error_and_stop()
                    decision = 'upstream_timeout'
                    break
                except http.client.HTTPException:
                    # e.g. IncompleteRead: the connection closed with an
                    # unterminated chunk -- a genuinely broken chunked
                    # body, not necessarily an idle stall.
                    emit_error_and_stop()
                    decision = 'incomplete_chunked_body'
                    break
                if not chunk:
                    if not seen_completed:
                        emit_error_and_stop()
                        decision = 'eof_no_terminal'
                    else:
                        decision = 'completed'
                    break
                forwarded_bytes += len(chunk)
                if forwarded_bytes > MAX_FORWARD_BYTES:
                    emit_error_and_stop()
                    decision = 'byte_cap_exceeded'
                    break
                pending = (pending + chunk).replace(b'\r\n', b'\n')
                if any(len(part) > MAX_FRAME_BYTES for part in pending.split(b'\n\n')):
                    emit_error_and_stop()
                    decision = 'frame_cap_exceeded'
                    break
                while b'\n\n' in pending and not terminated:
                    record, pending = pending.split(b'\n\n', 1)
                    data_lines = [line[5:].strip().decode('utf-8', 'replace')
                                  for line in record.split(b'\n') if line.startswith(b'data:')]
                    if not data_lines:
                        continue
                    # Join multi-line `data:` records with "\n" before
                    # classifying, matching the binary's own join
                    # (openai_codex.rs:908-918) -- a JSON event split
                    # across lines must not look like several frames.
                    joined = '\n'.join(data_lines)
                    verdict, event = classify(joined)
                    if verdict == 'completed':
                        # Tool-replay integrity (F14): never forward a
                        # completion whose output array disagrees with
                        # what the client was already incrementally told
                        # about a function_call. Checked before this
                        # frame is relayed -- the inconsistent completion
                        # must never reach the binary at all. Unconditional
                        # on seen_completed: this branch is only reachable
                        # while seen_completed is still False, because a
                        # validated completion terminates the loop
                        # immediately below (response.completed is
                        # terminal; there is no legitimate second one to
                        # wait for, per siwc-finish-review.md's
                        # clarification on GAP-2).
                        violation = find_integrity_violation(tracked_calls, event)
                        if violation is not None:
                            integrity_violation = violation
                            emit_error_and_stop()
                            decision = 'tool_integrity_violation'
                        else:
                            self.send_frame(record + b'\n\n')
                            self.wfile.flush()
                            if first_forward_rel is None:
                                first_forward_rel = time.monotonic() - request_start
                            seen_completed = True
                            decision = 'completed'
                            terminated = True  # close immediately; nothing legitimate follows
                    elif verdict == 'pass':
                        violation = track_incremental_tool_call(tracked_calls, event)
                        if violation is not None:
                            integrity_violation = violation
                            emit_error_and_stop()
                            decision = 'tool_integrity_violation'
                            continue
                        self.send_frame(record + b'\n\n')
                        self.wfile.flush()
                        if first_forward_rel is None:
                            first_forward_rel = time.monotonic() - request_start
                    else:  # terminal_unverified
                        if not seen_completed:
                            emit_error_and_stop()
                            decision = 'terminal_unverified'
                # terminated guard is checked by the while conditions above,
                # so nothing past a synthesized error is ever written, even
                # from later records already sitting in this same chunk.

            if decision is None:
                decision = 'completed' if seen_completed else 'eof_no_terminal'
            self.finish_frames()
        except (OSError, http.client.HTTPException):
            decision = 'transport_failure'
            try:
                if headers_sent:
                    self.send_frame(error_frame())
                    self.finish_frames()
                else:
                    body = json.dumps({'error': {'message': FIXED_ERROR_MESSAGE}}).encode()
                    self.send_response(502)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(body)))
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    self.wfile.write(body)
            except OSError:
                pass
        finally:
            conn.close()

        log_decision({'event': 'request', 'path': self.path, 'stream': stream, 'store': store,
                      'header_names': header_names, 'decision': decision,
                      'upstream_contacted': True, 'http_status': http_status, 'ts': time.time(),
                      'first_forward_rel': first_forward_rel,
                      'decision_rel': time.monotonic() - request_start,
                      'integrity_violation': integrity_violation})


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(IDLE_READ_TIMEOUT_SECONDS)
        return connection, address

    def handle_error(self, request, client_address):
        pass  # never print a traceback that might embed request content


def is_loopback_host(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == 'localhost'


def running_in_isolated_namespace():
    import socket as _socket
    return sorted(name for _, name in _socket.if_nameindex()) == ['lo']


def resolve_upstream(test_upstream):
    """Returns (host, port, scheme). `test_upstream` (e.g.
    'http://127.0.0.1:18200') is accepted ONLY when its host is loopback
    AND this process is itself inside the isolated namespace -- not an
    open proxy to an arbitrary caller-supplied URL, and not usable
    outside the sandboxed test environment this spike runs in.
    With no override, resolves the one pinned production endpoint;
    building the connection object from this does not itself touch the
    network (`http.client.HTTPSConnection()` doesn't connect until a
    request is made)."""
    from urllib.parse import urlsplit
    if test_upstream:
        if not running_in_isolated_namespace():
            print('BLOCKED: --test-upstream is only usable inside the isolated '
                  'loopback-only namespace', file=sys.stderr)
            sys.exit(2)
        parsed = urlsplit(test_upstream)
        if not is_loopback_host(parsed.hostname):
            print(f'BLOCKED: --test-upstream must be loopback, got {parsed.hostname!r}',
                  file=sys.stderr)
            sys.exit(2)
        scheme = parsed.scheme or 'http'
        port = parsed.port or (443 if scheme == 'https' else 80)
        return parsed.hostname, port, scheme
    parsed = urlsplit(PRODUCTION_UPSTREAM_URL)
    return parsed.hostname, 443, 'https'


def require_capability_file_or_die(capability_file):
    """Validates permissions (check_private) AND content (N1: rejects
    empty/too-short), then caches the value once (N2) into
    _CACHED_CAPABILITY_VALUE. Both entry points call this; it is the
    only place that ever reads the file."""
    global _CACHED_CAPABILITY_VALUE
    siwc = load_siwc()
    try:
        _CACHED_CAPABILITY_VALUE = load_capability_value(capability_file)
    except siwc.SafeError as exc:
        print(f'BLOCKED: capability file rejected: {exc}', file=sys.stderr)
        sys.exit(2)


class OneRequestHandler(Handler):
    def deadline_exit(self, *_):
        # Never block during cancellation. Normal upstream stalls receive an
        # explicit API error (avoids the client's built-in stream=false retry).
        # A blocked/partial downstream write instead remains incomplete chunked
        # transport: fail closed, and any stream=false fallback is rejected.
        packet = b''
        if getattr(self, '_headers_sent', False):
            if not getattr(self, '_sending_frame', False):
                payload = error_frame()
                packet = f'{len(payload):x}\r\n'.encode() + payload + b'\r\n0\r\n\r\n'
        else:
            body = b'{"error":{"message":"Upstream did not confirm a completed response."}}'
            packet = (b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n'
                      b'Content-Type: application/json\r\nContent-Length: ' + str(len(body)).encode()
                      + b'\r\n\r\n' + body)
        try:
            if packet:
                self.connection.send(packet, socket.MSG_DONTWAIT | socket.MSG_NOSIGNAL)
        except OSError:
            pass
        os._exit(124)

    def arm_inference_deadline(self):
        remaining = min(MAX_TOTAL_SECONDS, self.server.request_deadline - time.monotonic())
        signal.signal(signal.SIGALRM, self.deadline_exit)
        signal.setitimer(signal.ITIMER_REAL, max(.001, remaining))

    def handle(self):
        # No keep-alive/pipelining: one accepted connection, one wall budget.
        self.close_connection = True
        signal.signal(signal.SIGALRM, self.deadline_exit)
        self.handle_one_request()
        self.close_connection = True


class BoundedProcessHTTPServer(HTTPServer):
    """Single-threaded supervisor; kill workers even inside blocking DNS/I/O.

    Deadlines include TLS, headers, body, refresh and slow consumers. Killing a
    refresh worker preserves the shared helper's durable ambiguity marker.
    Children inherit no other accepted sockets: parent closes its copy on fork.
    """
    request_queue_size = 4

    def __init__(self, *args, **kwargs):
        self.children = {}
        super().__init__(*args, **kwargs)

    def service_actions(self):
        now = time.monotonic()
        for pid, deadline in list(self.children.items()):
            if os.waitpid(pid, os.WNOHANG)[0]:
                del self.children[pid]
            elif now >= deadline:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def process_request(self, request, address):
        self.service_actions()
        if len(self.children) >= MAX_CONNECTIONS:
            self.shutdown_request(request)
            return
        deadline = time.monotonic() + MAX_REQUEST_SECONDS
        pid = os.fork()
        if pid:
            self.children[pid] = deadline
            self.close_request(request)
            return
        try:
            self.socket.close()
            self.request_deadline = deadline
            signal.signal(signal.SIGALRM, lambda *_: os._exit(124))
            signal.setitimer(signal.ITIMER_REAL, MAX_REQUEST_SECONDS)
            request.settimeout(IDLE_READ_TIMEOUT_SECONDS)
            self.finish_request(request, address)
        except BaseException:
            pass  # Never print request/credential-bearing exception details.
        finally:
            self.shutdown_request(request)
            os._exit(0)

    def server_close(self):
        for pid in self.children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for pid in self.children:
            os.waitpid(pid, 0)
        self.children.clear()
        super().server_close()

    def handle_error(self, request, client_address):
        pass


def run_server(listen_port):
    with BoundedProcessHTTPServer(('127.0.0.1', listen_port), OneRequestHandler) as server:
        print(f'FILTERING_ADAPTER_READY port={server.server_port}', flush=True)
        server.serve_forever(poll_interval=0.05)


def main():
    """The real, secure entry point. Requires a state dir and a
    capability file -- no silent unauthenticated or no-credential mode.
    Defaults to the one pinned production HTTPS endpoint; `--test-upstream`
    is the only way to point elsewhere, and only inside the isolated
    namespace, only at loopback."""
    import argparse
    global UPSTREAM_HOST, UPSTREAM_PORT, UPSTREAM_SCHEME, DECISION_LOG, CAPABILITY_FILE, SIWC_STATE_DIR

    parser = argparse.ArgumentParser(description='SIWC adapter (secure entry point)')
    parser.add_argument('--listen-port', type=int, required=True)
    parser.add_argument('--state-dir', required=True, help='siwc.py credential state dir path')
    parser.add_argument('--capability-file', required=True, help='path to the private capability file')
    parser.add_argument('--decision-log', default=None)
    parser.add_argument('--test-upstream', default=None,
                         help='TEST-ONLY loopback override; refused outside the isolated namespace')
    global MAX_REQUEST_BYTES, MAX_FRAME_BYTES, MAX_FORWARD_BYTES, MAX_CONNECTIONS
    global MAX_REQUEST_SECONDS, MAX_TOTAL_SECONDS, IDLE_READ_TIMEOUT_SECONDS
    import math
    parser.add_argument('--max-request-bytes', type=int, default=MAX_REQUEST_BYTES)
    parser.add_argument('--max-frame-bytes', type=int, default=MAX_FRAME_BYTES)
    parser.add_argument('--max-stream-bytes', type=int, default=MAX_FORWARD_BYTES)
    parser.add_argument('--max-connections', type=int, default=MAX_CONNECTIONS)
    parser.add_argument('--request-seconds', type=float, default=MAX_REQUEST_SECONDS)
    parser.add_argument('--inference-seconds', type=float, default=MAX_TOTAL_SECONDS)
    parser.add_argument('--idle-seconds', type=float, default=IDLE_READ_TIMEOUT_SECONDS)
    args = parser.parse_args(sys.argv[1:])
    for value, limit in ((args.max_request_bytes, 64 * 1024 * 1024),
                         (args.max_frame_bytes, 16 * 1024 * 1024),
                         (args.max_stream_bytes, 64 * 1024 * 1024),
                         (args.max_connections, 16), (args.request_seconds, 900),
                         (args.inference_seconds, 600), (args.idle_seconds, 120)):
        if not math.isfinite(value) or not 0 < value <= limit:
            parser.error('limit outside supported positive finite range')
    if not 1 <= args.listen_port <= 65535:
        parser.error('port outside supported range')
    MAX_REQUEST_BYTES, MAX_FRAME_BYTES = args.max_request_bytes, args.max_frame_bytes
    MAX_FORWARD_BYTES, MAX_CONNECTIONS = args.max_stream_bytes, args.max_connections
    MAX_REQUEST_SECONDS = args.request_seconds
    MAX_TOTAL_SECONDS, IDLE_READ_TIMEOUT_SECONDS = args.inference_seconds, args.idle_seconds

    SIWC_STATE_DIR = args.state_dir
    CAPABILITY_FILE = args.capability_file
    DECISION_LOG = args.decision_log
    UPSTREAM_HOST, UPSTREAM_PORT, UPSTREAM_SCHEME = resolve_upstream(args.test_upstream)

    require_capability_file_or_die(CAPABILITY_FILE)
    run_server(args.listen_port)


def legacy_test_harness_main():
    """TEST-ONLY entry point, explicitly named as such: the original
    positional-argument harness used by this spike's own gate scripts
    (listen_port, upstream_port, decision_log, capability_file,
    siwc_state_dir). Always loopback (never resolves the production
    endpoint), and always enforces the isolated namespace -- this is
    not a quieter way to run the adapter for real."""
    global UPSTREAM_PORT, DECISION_LOG, CAPABILITY_FILE, SIWC_STATE_DIR
    if not running_in_isolated_namespace():
        print('BLOCKED: legacy test harness refuses to run outside the isolated namespace',
              file=sys.stderr)
        sys.exit(2)
    listen_port = int(sys.argv[1])
    UPSTREAM_PORT = int(sys.argv[2])
    DECISION_LOG = sys.argv[3] if len(sys.argv) > 3 else None
    CAPABILITY_FILE = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
    SIWC_STATE_DIR = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

    global INSECURE_TEST_MODE_ACKNOWLEDGED
    if CAPABILITY_FILE:
        require_capability_file_or_die(CAPABILITY_FILE)
    elif os.environ.get('SIWC_ADAPTER_INSECURE_TEST_MODE') != '1':
        print('BLOCKED: no capability file configured and '
              'SIWC_ADAPTER_INSECURE_TEST_MODE=1 not set -- refusing to start '
              'unauthenticated.', file=sys.stderr)
        sys.exit(2)
    else:
        print('INSECURE_TEST_MODE (legacy test harness): no capability file configured '
              '-- every request is accepted unauthenticated. The secure main() entry '
              'point always requires one.', file=sys.stderr)
        INSECURE_TEST_MODE_ACKNOWLEDGED = True

    run_server(listen_port)


if __name__ == '__main__':
    # Dispatch: the real entry point uses --flags; this spike's own test
    # scripts invoke the legacy positional harness unchanged (plain
    # integers/paths, never starting with "-"). Both are explicit code
    # paths, not an implicit fallback into each other.
    if len(sys.argv) >= 2 and sys.argv[1].startswith('--'):
        main()
    else:
        legacy_test_harness_main()
