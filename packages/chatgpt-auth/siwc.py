"""Pi-owned ChatGPT credential manager. Never log credentials."""
import base64
import hashlib
import hmac
import secrets
import contextlib
import fcntl
import json
import os
from pathlib import Path
import stat
import tempfile
import time


def check_private(path, directory=False):
    info = path.lstat()
    valid_type = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if not valid_type or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise SafeError('State ownership, file type, or permissions are unsafe.')


@contextlib.contextmanager
def locked_state(path):
    path.mkdir(mode=0o700, parents=False, exist_ok=True)
    check_private(path, directory=True)
    fd = os.open(path / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        check_private(path / '.lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SafeError('Another process owns this login/refresh session.') from None
        yield path
    finally:
        os.close(fd)


def atomic_json(path, value):
    check_private(path.parent, directory=True)
    if path.exists() or path.is_symlink():
        check_private(path)
    fd, temp = tempfile.mkstemp(prefix='.pending-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        parent_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def load_json(path):
    check_private(path)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as handle:
        return json.load(handle)
from urllib.parse import parse_qs, urlencode

ISSUER = 'https://auth.openai.com'
RESOURCE = 'https://api.openai.com/v1'
AUTHORIZE = ISSUER + '/api/accounts/authorize'
TOKEN = ISSUER + '/api/accounts/oauth/token'
APP_NAME = 'Pi4 ChatGPT Login Test'
DISCOVERY = ISSUER + '/.well-known/openid-configuration'
JWKS = ISSUER + '/.well-known/jwks.json'
REVOKE = ISSUER + '/api/accounts/oauth/revoke'


def inference_body(model):
    return {'model':model, 'input':[{'role':'user', 'content':'Say exactly: Hello from Pi4.'}],
            'store':False, 'stream':True}


def consume_events(lines):
    text = ''
    data = []
    count = 0
    deadline = time.monotonic() + 120
    for line in lines:
        count += len(line)
        if count > 2_000_000 or time.monotonic() > deadline:
            raise SafeError('Response stream exceeded the test budget.')
        if line.startswith('data:'):
            data.append(line[5:].lstrip())
        elif not line and data:
            raw = '\n'.join(data)
            data = []
            if raw == '[DONE]':
                break
            event = json.loads(raw)
            kind = event.get('type')
            if kind in ('response.failed', 'response.incomplete', 'error'):
                raise SafeError('Provider stream reported failure or incomplete response.')
            if kind == 'response.output_text.delta':
                text += event.get('delta', '')
                if len(text) > 1000:
                    raise SafeError('Model output exceeded the minimal test budget.')
            if kind == 'response.completed':
                if event.get('response', {}).get('status') != 'completed':
                    raise SafeError('Completion event had a non-completed status.')
                return text
    raise SafeError('Stream ended without verified response.completed.')


class Client:
    def __init__(self):
        import requests
        self.session = requests.Session()
        self.session.trust_env = False  # No proxy, netrc, or ambient credentials.

    def request(self, method, url, **kwargs):
        allowed = {('GET', DISCOVERY), ('GET', JWKS), ('GET', RESOURCE + '/models'),
                   ('POST', TOKEN), ('POST', RESOURCE + '/responses'), ('POST', REVOKE)}
        if (method, url) not in allowed:
            raise SafeError('Refusing an unexpected network destination.')
        import requests
        refreshing = url == TOKEN and kwargs.get('data', {}).get('grant_type') == 'refresh_token'
        try:
            response = self.session.request(method, url, allow_redirects=False, timeout=(15, 30), **kwargs)
        except requests.ConnectTimeout:
            raise TransientError('Connection timed out before request delivery.') from None
        except requests.RequestException:
            if method == 'GET':
                raise TransientError('Read-only provider request failed temporarily.') from None
            raise SafeError('Request outcome unknown; do not blindly retry rotating credentials.') from None
        if not 200 <= response.status_code < 300:
            status = response.status_code
            code = None
            if refreshing:
                try:
                    error = response.json().get('error')
                    code = error.get('code') if isinstance(error, dict) else error
                except Exception:
                    pass
            response.close()
            terminal_codes = {'invalid_grant','invalid_refresh_token','token_expired',
                              'refresh_token_expired','refresh_token_invalidated','refresh_token_reused'}
            if isinstance(code, str) and code in terminal_codes:
                raise LoginRequired('Provider confirmed an unusable refresh token.')
            if code == 'invalid_client':
                raise ClientConfigurationError('Provider rejected the saved client configuration.')
            # A gateway response does not prove a rotating POST was unprocessed.
            if method == 'GET' and status in (429, 502, 503, 504):
                raise TransientError(f'Temporary read-only provider HTTP status {status}.')
            raise SafeError(f'Provider HTTP status {status}; response body suppressed.')
        return response

    def get_jwks(self):
        with self.request('GET', DISCOVERY) as response:
            discovery = response.json()
        if discovery.get('issuer') != ISSUER or discovery.get('jwks_uri') != JWKS:
            raise SafeError('OpenID discovery did not match the pinned issuer/JWKS origin.')
        with self.request('GET', JWKS) as response:
            return response.json()

    def models(self, credentials):
        with self.request('GET', RESOURCE + '/models', headers={'Authorization':'Bearer ' + credentials['access_token']}) as response:
            payload = response.json()
        models = payload.get('models')
        if not isinstance(models, list):
            raise SafeError('Model catalog is not the documented ChatGPT-plan shape.')
        return [{'slug':m['slug'], 'display_name':m.get('display_name', m['slug'])}
                for m in models if m.get('visibility') == 'list' and isinstance(m.get('slug'), str)]

    def probe(self, credentials, model):
        with self.request('POST', RESOURCE + '/responses',
                          headers={'Authorization':'Bearer ' + credentials['access_token']},
                          json=inference_body(model), stream=True) as response:
            response.encoding = 'utf-8'
            return consume_events(response.iter_lines(decode_unicode=True))

class SafeError(Exception):
    """Only fixed, non-secret messages may be passed to this exception."""


class TransientError(SafeError):
    """A definitive transient failure, safe for bounded retry."""


class LoginRequired(SafeError):
    """Provider confirmed the renewable session is unusable."""


class ClientConfigurationError(SafeError):
    """The provider rejected the client configuration, not the user session."""


def new_pending(host_id, port, client_id='dynamic_agent_client'):
    return {'host_id': host_id, 'client_id': client_id,
            'redirect_uri': f'http://127.0.0.1:{port}/auth/callback',
            'state': secrets.token_urlsafe(32), 'nonce': secrets.token_urlsafe(32),
            'verifier': secrets.token_urlsafe(48)}


def authorization(pending):
    challenge = base64.urlsafe_b64encode(hashlib.sha256(pending['verifier'].encode()).digest()).decode().rstrip('=')
    params = {'client_id': pending['client_id'], 'ext_agent_host_id': pending['host_id'],
              'response_type': 'code', 'redirect_uri': pending['redirect_uri'],
              'scope': 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
              'resource': RESOURCE, 'state': pending['state'], 'nonce': pending['nonce'],
              'code_challenge_method': 'S256', 'code_challenge': challenge}
    if pending['client_id'] == 'dynamic_agent_client':
        params['agent_name_hint'] = APP_NAME
    return AUTHORIZE + '?' + urlencode(params)


def callback(query, pending):
    try:
        values = parse_qs(query, keep_blank_values=True, strict_parsing=True, max_num_fields=16)
    except ValueError:
        raise SafeError('Invalid callback parameters.') from None
    if any(len(v) != 1 for v in values.values()):
        raise SafeError('Duplicate callback parameters.')
    state = values.get('state', [''])[0]
    if not hmac.compare_digest(state.encode(), pending['state'].encode()):
        raise SafeError('Callback state did not match.')
    if 'error' in values:
        raise SafeError('Authorization declined or failed.')
    client = values.get('client_id', [pending['client_id']])[0]
    if not client or client == 'dynamic_agent_client':
        raise SafeError('Registration did not return an issued client ID.')
    if pending['client_id'] != 'dynamic_agent_client' and client != pending['client_id']:
        raise SafeError('Callback changed the selected client registration.')
    code = values.get('code', [''])[0]
    if not code:
        raise SafeError('Callback is missing an authorization code.')
    return client, code


def validate_tokens(response, client_id, nonce, jwks, expected_subject=None):
    import jwt
    import time
    stage = 'token_type'
    try:
        if response.get('token_type', '').lower() != 'bearer':
            raise ValueError()
        stage = 'credential_fields'
        if not all(isinstance(response.get(k), str) and response[k] for k in ('access_token', 'refresh_token', 'id_token')):
            raise ValueError()
        stage = 'granted_scopes'
        scopes = response.get('scope', '').split()
        if not {'chatgpt.tokens.use.direct', 'resource.invoke', 'offline_access'} <= set(scopes):
            raise ValueError()
        stage = 'jwt_header'
        header = jwt.get_unverified_header(response['id_token'])
        if header.get('alg') != 'RS256' or not header.get('kid'):
            raise ValueError()
        stage = 'signing_key_match'
        keys = [k for k in jwks['keys'] if k.get('kid') == header['kid'] and k.get('kty') == 'RSA' and k.get('use', 'sig') == 'sig']
        if len(keys) != 1:
            raise ValueError()
        key = jwt.PyJWK.from_dict(keys[0], algorithm='RS256').key
        stage = 'signed_jwt_claims'
        claims = jwt.decode(response['id_token'], key, algorithms=['RS256'], audience=client_id,
                            issuer=ISSUER, options={'require':['iss','aud','sub','exp','iat']})
        stage = 'audience_and_authorized_party'
        audiences = claims['aud'] if isinstance(claims['aud'], list) else [claims['aud']]
        # Accept the OIDC string/array encodings, but no untrusted additional audience.
        if not audiences or any(audience != client_id for audience in audiences):
            raise ValueError()
        if 'azp' in claims and claims['azp'] != client_id:
            raise ValueError()
        stage = 'nonce'
        if nonce is not None and not hmac.compare_digest(str(claims.get('nonce', '')).encode(), nonce.encode()):
            raise ValueError()
        stage = 'subject'
        if not isinstance(claims['sub'], str) or not claims['sub']:
            raise ValueError()
        if expected_subject is not None and claims['sub'] != expected_subject:
            raise ValueError()
        stage = 'access_token_expiry'
        expires_in = response['expires_in']
        if type(expires_in) is not int or not 0 < expires_in <= 86400:
            raise ValueError()
        now = int(time.time())
        return {'subject':claims['sub'], 'issuer':ISSUER, 'client_id':client_id,
                'access_token':response['access_token'], 'refresh_token':response['refresh_token'],
                'id_token':response['id_token'], 'scopes':scopes, 'token_type':'Bearer',
                'saved_at':now, 'expires_at':now + expires_in,
                'earliest_refresh_at':response.get('earliest_refresh_at')}
    except Exception as exc:
        allowed_errors = {'ValueError','TypeError','KeyError','DecodeError','InvalidSignatureError',
                          'ExpiredSignatureError','InvalidAudienceError','InvalidIssuerError',
                          'ImmatureSignatureError','MissingRequiredClaimError','InvalidIssuedAtError'}
        category = type(exc).__name__ if type(exc).__name__ in allowed_errors else 'validation_error'
        # Only booleans and fixed diagnostic labels; never exception messages or claims.
        scope_value = response.get('scope', '')
        scope_set = set(scope_value.split()) if isinstance(scope_value, str) else set()
        flags = {name: bool(isinstance(response.get(name), str) and response[name])
                 for name in ('access_token','refresh_token','id_token')}
        flags.update(plan_scope='chatgpt.tokens.use.direct' in scope_set,
                     invoke_scope='resource.invoke' in scope_set, offline_scope='offline_access' in scope_set,
                     integer_expiry=type(response.get('expires_in')) is int)
        raise SafeError(f'Token validation failed: stage={stage}; category={category}; presence={json.dumps(flags, sort_keys=True)}') from None


def refresh_due(credentials, now):
    earliest = credentials.get('earliest_refresh_at')
    if isinstance(earliest, str):
        from datetime import datetime
        try:
            earliest = datetime.fromisoformat(earliest.replace('Z', '+00:00')).timestamp()
        except ValueError:
            raise SafeError('Unrecognized provider refresh timing; refusing early rotation.') from None
    if earliest is not None and type(earliest) not in (int, float):
        raise SafeError('Unrecognized provider refresh timing; refusing early rotation.')
    return now >= max(credentials['expires_at'] - 120, earliest or 0)


def refresh_credentials(response, previous, jwks):
    effective = response.copy()
    effective.setdefault('scope', ' '.join(previous['scopes']))
    if effective.get('id_token'):
        updated = validate_tokens(effective, previous['client_id'], None, jwks,
                                  expected_subject=previous['subject'])
    else:
        if (effective.get('token_type', '').lower() != 'bearer'
                or not all(isinstance(effective.get(k), str) and effective[k] for k in ('access_token','refresh_token'))
                or type(effective.get('expires_in')) is not int
                or not 0 < effective['expires_in'] <= 86400
                or not {'chatgpt.tokens.use.direct','resource.invoke','offline_access'} <= set(effective['scope'].split())):
            raise SafeError('Refresh token response failed validation.')
        now = int(time.time())
        updated = previous | {k:effective[k] for k in ('access_token','refresh_token','token_type')}
        updated.update(saved_at=now, expires_at=now + effective['expires_in'],
                       scopes=effective['scope'].split(), earliest_refresh_at=effective.get('earliest_refresh_at'))
    updated['ext_agent_host_id'] = previous['ext_agent_host_id']
    return updated


def remove_private(path):
    if path.exists():
        check_private(path)
        path.unlink()
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def refresh_session(state, client):
    """Caller holds the shared state lock; never retry an uncertain rotation."""
    import uuid
    path = state / 'credentials.json'
    credentials = load_json(path)
    if credentials.get('auth_state') == 'login_required':
        raise LoginRequired('Login required; the previous renewable session is unusable.')
    inflight = state / 'refresh-inflight.json'
    if inflight.exists():
        operation = load_json(inflight)
        if credentials.get('refresh_generation') == operation.get('operation_id'):
            remove_private(inflight)  # Replacement was durable before the prior crash.
        else:
            raise SafeError('Refresh outcome is uncertain; login/recovery required before another rotation.')
    if not refresh_due(credentials, time.time()):
        return credentials, {'refresh':'not_due', 'expires_at':credentials['expires_at']}
    for attempt in range(3):
        operation_id = str(uuid.uuid4())
        try:
            jwks = client.get_jwks()
            atomic_json(inflight, {'operation_id':operation_id, 'previous_saved_at':credentials['saved_at']})
            with client.request('POST', TOKEN, data={'grant_type':'refresh_token',
                                'client_id':credentials['client_id'], 'resource':RESOURCE,
                                'refresh_token':credentials['refresh_token']}) as response:
                replacement = refresh_credentials(response.json(), credentials, jwks)
            replacement['refresh_generation'] = operation_id
            atomic_json(path, replacement)
            if load_json(path) != replacement:
                raise SafeError('Refreshed credential read-back verification failed.')
        except TransientError:
            remove_private(inflight)
            if attempt == 2:
                raise SafeError('Temporary provider failure; bounded retries exhausted, credentials preserved.') from None
            time.sleep((5, 15)[attempt])
            continue
        except LoginRequired:
            unusable = {key:value for key,value in credentials.items()
                        if key not in ('access_token','refresh_token','id_token')}
            unusable['auth_state'] = 'login_required'
            atomic_json(path, unusable)
            remove_private(inflight)
            raise LoginRequired('Login required; provider confirmed the renewable session is unusable.') from None
        except ClientConfigurationError:
            remove_private(inflight)
            raise
        except Exception:
            raise SafeError('Refresh could not be confirmed; inspect outcome marker before retrying.') from None
        remove_private(inflight)
        evidence = {'refresh':'verified', 'expires_at':replacement['expires_at'],
                    'previous_expires_at':credentials['expires_at'],
                    'saved_at':replacement['saved_at'], 'operation_id':operation_id,
                    'refresh_token_replaced':replacement['refresh_token'] != credentials['refresh_token']}
        atomic_json(state / 'last-refresh.json', evidence)
        return replacement, evidence


def make_server(pending):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlsplit
    import threading

    class QuietServer(ThreadingHTTPServer):
        daemon_threads = True
        block_on_close = False

        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(3)
            return connection, address

        def handle_error(self, request, client_address):
            pass  # Never emit a traceback containing callback data.

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body='', location=None):
            self.send_response(status)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            if location:
                self.send_header('Location', location)
            encoded = body.encode()
            self.send_header('Content-Length', str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            origin = f'http://127.0.0.1:{self.server.server_port}'
            if self.headers.get('Host') != origin.removeprefix('http://') or self.headers.get('Origin') not in (None, origin):
                self.reply(400, 'Invalid local request.')
                return
            parsed = urlsplit(self.path)
            if len(self.path) > 16384:
                self.reply(400, 'Invalid callback size.')
            elif parsed.path == '/health':
                self.reply(200, 'Pi4 login helper ready.')
            elif parsed.path == '/':
                self.reply(200, '<h1>Pi4 ChatGPT Login Test</h1><p>This authorizes a separate test application on your Pi. Existing API keys are not used.</p><p>Review plan and paid-credit permissions on the OpenAI consent screen.</p><a href="/start">Continue with ChatGPT</a>')
            elif parsed.path == '/start' and not self.server.callback_ready.is_set():
                self.reply(303, location=authorization(pending))
            elif parsed.path == '/auth/callback' and not self.server.callback_ready.is_set():
                with self.server.callback_lock:
                    if self.server.callback_ready.is_set():
                        self.reply(409, 'Callback already consumed.')
                        return
                    try:
                        self.server.callback_result = callback(parsed.query, pending)
                    except SafeError as exc:
                        if str(exc) == 'Authorization declined or failed.':
                            self.server.callback_error = exc
                            self.server.callback_ready.set()
                        self.reply(400, 'Authorization not accepted. Check the test terminal; no credential was displayed.')
                        return
                    self.server.callback_ready.set()
                    self.reply(303, location='/done')
            elif parsed.path == '/done':
                self.reply(200, '<h1>Callback received</h1><p>The Pi is validating the authorization. Check the test terminal for the verified result. You may close this tab.</p>')
            else:
                self.reply(404, 'Not found.')

    port = urlsplit(pending['redirect_uri']).port
    server = QuietServer(('127.0.0.1', port), Handler)
    pending['redirect_uri'] = f'http://127.0.0.1:{server.server_port}/auth/callback'
    server.callback_ready = threading.Event()
    server.callback_lock = threading.Lock()
    server.callback_result = None
    server.callback_error = None
    return server


def read_registration(state, host):
    registration_path = state / 'registration.json'
    registration = load_json(registration_path) if registration_path.exists() else {}
    if registration and registration.get('host_id') != host:
        raise SafeError('Registration belongs to a different host.')
    credential_path = state / 'credentials.json'
    if credential_path.exists():
        credentials = load_json(credential_path)
        if (credentials.get('ext_agent_host_id') != host
                or registration.get('client_id', credentials['client_id']) != credentials['client_id']
                or registration.get('subject', credentials['subject']) != credentials['subject']):
            raise SafeError('Stored registration and validated credentials disagree.')
        # The atomic credential record is authoritative after an interrupted metadata write.
        return {'client_id':credentials['client_id'], 'subject':credentials['subject'],
                'host_id':host, 'validated':True}
    return registration


def login(state, client, port, wait_seconds):
    import threading
    import uuid
    host_path = state / 'host.json'
    if not host_path.exists():
        atomic_json(host_path, {'host_id':'urn:uuid:' + str(uuid.uuid4())})
    host = load_json(host_path)['host_id']
    registration_path = state / 'registration.json'
    registration = read_registration(state, host)
    pending = new_pending(host, port, registration.get('client_id', 'dynamic_agent_client'))
    # Fail before showing sign-in if trusted OpenID metadata is unavailable.
    jwks = client.get_jwks()
    server = make_server(pending)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        print(f'READY: open http://127.0.0.1:{server.server_port}/ through the SSH tunnel.', flush=True)
        if not server.callback_ready.wait(wait_seconds):
            raise SafeError('Login timed out without a valid browser callback.')
        if server.callback_error:
            raise server.callback_error
        issued_client, code = server.callback_result
        # Retain the issued ID even if code exchange fails; retry by reauthorizing.
        atomic_json(registration_path, registration | {'client_id':issued_client, 'host_id':host,
                                                     'validated':bool(registration.get('subject'))})
        with client.request('POST', TOKEN, data={'grant_type':'authorization_code',
                            'client_id':issued_client, 'code':code, 'code_verifier':pending['verifier'],
                            'redirect_uri':pending['redirect_uri'], 'resource':RESOURCE}) as response:
            tokens = response.json()
        credentials = validate_tokens(tokens, issued_client, pending['nonce'], jwks,
                                      expected_subject=registration.get('subject'))
        credentials['ext_agent_host_id'] = host
        atomic_json(state / 'credentials.json', credentials)
        atomic_json(registration_path, {'client_id':issued_client, 'host_id':host,
                                       'subject':credentials['subject']})
        saved = load_json(state / 'credentials.json')
        if saved != credentials:
            raise SafeError('Credential file read-back verification failed.')
        remove_private(state / 'refresh-inflight.json')
        print(json.dumps({'login':'verified', 'plan_scope':True, 'credential_mode':'0600',
                          'expires_at':credentials['expires_at'], 'credentials_remained_on_pi':True}), flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)


def main(argv=None):
    import argparse
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--state-dir', type=Path, default=Path.home() / 'siwc-test-state')
    parser.add_argument('command', choices=['login','status','models','probe','refresh','discovery'])
    parser.add_argument('--port', type=int, default=18765)
    parser.add_argument('--wait-seconds', type=int, default=600)
    parser.add_argument('--model')
    args = parser.parse_args(argv)
    if not 1024 <= args.port <= 65535 or not 1 <= args.wait_seconds <= 1800:
        raise SafeError('Invalid listener port or wait budget.')
    client = Client()
    if args.command == 'discovery':
        jwks = client.get_jwks()
        print(json.dumps({'discovery':'verified', 'issuer':ISSUER, 'signing_key_count':len(jwks['keys'])}))
        return
    with locked_state(args.state_dir) as state:
        if args.command == 'login':
            login(state, client, args.port, args.wait_seconds)
            return
        credential_path = state / 'credentials.json'
        if not credential_path.exists():
            if args.command == 'status':
                print(json.dumps({'authenticated':False}))
                return
            raise SafeError('No validated login is stored for this isolated test.')
        credentials = load_json(credential_path)
        if args.command == 'status':
            login_required = credentials.get('auth_state') == 'login_required'
            print(json.dumps({'authenticated':not login_required, 'login_required':login_required,
                              'refresh_outcome_pending':(state / 'refresh-inflight.json').exists(),
                              'expires_at':credentials['expires_at'],
                              'expired':credentials['expires_at'] <= time.time(), 'credential_mode':'0600'}))
            return
        if args.command == 'refresh':
            _, evidence = refresh_session(state, client)
            print(json.dumps(evidence))
            return
        credentials, _ = refresh_session(state, client)
        if credentials['expires_at'] <= time.time() + 30:
            raise SafeError('Access token expired or near expiry; refresh is required.')
        models = client.models(credentials)
        if args.command == 'models':
            print(json.dumps({'models':models}, indent=2))
        elif args.command == 'probe':
            if not args.model or args.model not in [model['slug'] for model in models]:
                raise SafeError('Choose an exact model slug from the live visible catalog.')
            text = client.probe(credentials, args.model)
            evidence = {'response_completed':True, 'model':args.model,
                        'expected_greeting':text.strip() == 'Hello from Pi4.', 'observed_at':int(time.time())}
            atomic_json(state / 'last-probe.json', evidence)
            print(json.dumps(evidence | {'response_text':text}, ensure_ascii=True))


if __name__ == '__main__':
    try:
        main()
    except SafeError as error:
        print('BLOCKED: ' + str(error), flush=True)
        raise SystemExit(1) from None
    except KeyboardInterrupt:
        print('Cancelled; no secret diagnostics printed.', flush=True)
        raise SystemExit(130) from None
    except Exception:
        print('BLOCKED: unexpected error; credential-bearing diagnostics suppressed.', flush=True)
        raise SystemExit(1) from None
