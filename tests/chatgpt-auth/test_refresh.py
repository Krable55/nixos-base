"""Offline fixture tests; never load real credentials or send network requests."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import siwc

OLD = {'access_token':'old-fixture-access', 'refresh_token':'old-fixture-refresh',
       'id_token':'previously-validated-fixture-id', 'client_id':'oaiapp_fixture',
       'subject':'fixture-subject', 'issuer':siwc.ISSUER, 'ext_agent_host_id':'urn:uuid:fixture',
       'saved_at':100, 'expires_at':200, 'earliest_refresh_at':150, 'token_type':'Bearer',
       'scopes':['chatgpt.tokens.use.direct','resource.invoke','offline_access']}
NEW = {'access_token':'new-fixture-access','refresh_token':'new-fixture-refresh',
       'token_type':'Bearer','expires_in':3600}

class FakeResponse:
    def __init__(self, data): self.data = data
    def __enter__(self): return self
    def __exit__(self, *args): return False
    def json(self): return self.data

class FakeClient:
    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.calls = []
    def get_jwks(self): return {'keys':[]}
    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception): raise outcome
        return FakeResponse(outcome)

class RefreshTests(unittest.TestCase):
    def test_cli_refresh_persists_replacement_and_skips_early(self):
        self.assertTrue(callable(getattr(siwc, 'refresh_session', None)), 'serialized refresh workflow missing')
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)/'state'
            with siwc.locked_state(state):
                siwc.atomic_json(state/'credentials.json', OLD)
            fake = FakeClient([NEW])
            output = io.StringIO()
            with patch.object(siwc, 'Client', return_value=fake), patch.object(siwc.time, 'time', return_value=180), contextlib.redirect_stdout(output):
                siwc.main(['--state-dir', str(state), 'refresh'])
            saved = siwc.load_json(state/'credentials.json')
            self.assertEqual(saved['refresh_token'], NEW['refresh_token'])
            self.assertEqual(saved['subject'], OLD['subject'])
            self.assertEqual(saved['client_id'], OLD['client_id'])
            self.assertFalse((state/'refresh-inflight.json').exists())
            self.assertEqual((state/'credentials.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual(fake.calls[0][1], siwc.TOKEN)
            self.assertNotIn('scope', fake.calls[0][2]['data'])
            self.assertIn('verified', output.getvalue())
            for token in [OLD['access_token'], OLD['refresh_token'], NEW['access_token'], NEW['refresh_token']]:
                self.assertNotIn(token, output.getvalue())
            with patch.object(siwc, 'Client', return_value=fake), patch.object(siwc.time, 'time', return_value=181), contextlib.redirect_stdout(io.StringIO()):
                siwc.main(['--state-dir', str(state), 'refresh'])
            self.assertEqual(len(fake.calls), 1)

    def test_transient_retry_is_bounded_and_preserves_tokens_on_exhaustion(self):
        self.assertTrue(hasattr(siwc, 'TransientError'), 'classified retry support missing')
        for outcomes, succeeds in [([siwc.TransientError('temporary'), siwc.TransientError('temporary'), NEW], True),
                                   ([siwc.TransientError('temporary')]*3, False)]:
            with self.subTest(succeeds=succeeds), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp)/'state'
                fake = FakeClient(outcomes)
                with siwc.locked_state(state), patch.object(siwc.time, 'time', return_value=180), patch.object(siwc.time, 'sleep') as sleep:
                    siwc.atomic_json(state/'credentials.json', OLD)
                    if succeeds:
                        _, evidence = siwc.refresh_session(state, fake)
                        self.assertEqual(evidence['refresh'], 'verified')
                    else:
                        with self.assertRaises(siwc.SafeError): siwc.refresh_session(state, fake)
                        self.assertEqual(siwc.load_json(state/'credentials.json'), OLD)
                    self.assertEqual(len(fake.calls), 3)
                    self.assertEqual(sleep.call_count, 2)
                    self.assertFalse((state/'refresh-inflight.json').exists())

    def test_terminal_revocation_clears_tokens_but_preserves_registration(self):
        self.assertTrue(hasattr(siwc, 'LoginRequired'), 'terminal auth error support missing')
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)/'state'
            fake = FakeClient([siwc.LoginRequired('invalid_grant')])
            with siwc.locked_state(state), patch.object(siwc.time, 'time', return_value=180):
                siwc.atomic_json(state/'credentials.json', OLD)
                with self.assertRaises(siwc.LoginRequired): siwc.refresh_session(state, fake)
                saved = siwc.load_json(state/'credentials.json')
                self.assertEqual(saved['client_id'], OLD['client_id'])
                self.assertEqual(saved['subject'], OLD['subject'])
                self.assertEqual(saved['auth_state'], 'login_required')
                for name in ['access_token','refresh_token','id_token']:
                    self.assertNotIn(name, saved)
                with self.assertRaises(siwc.LoginRequired): siwc.refresh_session(state, fake)
                self.assertEqual(len(fake.calls), 1)

    def test_ambiguous_refresh_and_write_failure_are_not_retried(self):
        for outcome in [RuntimeError('SENSITIVE_NETWORK_DIAGNOSTIC'), NEW]:
            with self.subTest(outcome_type=type(outcome).__name__), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp)/'state'
                fake = FakeClient([outcome])
                with siwc.locked_state(state), patch.object(siwc.time, 'time', return_value=180):
                    siwc.atomic_json(state/'credentials.json', OLD)
                    real_write = siwc.atomic_json
                    def failing_write(path, value):
                        if path.name == 'credentials.json': raise OSError('SENSITIVE_DISK_DIAGNOSTIC')
                        return real_write(path, value)
                    with patch.object(siwc, 'atomic_json', side_effect=failing_write):
                        with self.assertRaises(siwc.SafeError) as error: siwc.refresh_session(state, fake)
                    self.assertNotIn('SENSITIVE_', str(error.exception))
                    self.assertTrue((state/'refresh-inflight.json').exists())
                    self.assertEqual(siwc.load_json(state/'credentials.json'), OLD)
                    with self.assertRaises(siwc.SafeError): siwc.refresh_session(state, fake)
                    self.assertEqual(len(fake.calls), 1)

    def test_http_and_transport_error_classification_redacts_provider_details(self):
        import requests, json
        client = siwc.Client()
        data = {'grant_type':'refresh_token','refresh_token':'fixture-secret'}
        for status, body, expected in [
                (400, {'error':'invalid_grant','error_description':'SENSITIVE_DETAIL'}, siwc.LoginRequired),
                (400, {'error':{'code':'refresh_token_reused','message':'SENSITIVE_DETAIL'}}, siwc.LoginRequired),
                (400, {'error':'invalid_client'}, siwc.ClientConfigurationError),
                (503, {'detail':'SENSITIVE_DETAIL'}, siwc.SafeError),
                (429, {'error':'temporarily_unavailable'}, siwc.SafeError)]:
            response = requests.Response()
            response.status_code = status
            response._content = json.dumps(body).encode()
            response._content_consumed = True
            with self.subTest(status=status, expected=expected.__name__), patch.object(client.session, 'request', return_value=response):
                with self.assertRaises(expected) as caught:
                    client.request('POST', siwc.TOKEN, data=data)
                if status in (429, 503):
                    self.assertNotIsInstance(caught.exception, siwc.TransientError)
                self.assertNotIn('SENSITIVE_DETAIL', str(caught.exception))
        with patch.object(client.session, 'request', side_effect=requests.ConnectTimeout('SENSITIVE_DETAIL')):
            with self.assertRaises(siwc.TransientError): client.request('POST', siwc.TOKEN, data=data)
        with patch.object(client.session, 'request', side_effect=requests.ReadTimeout('SENSITIVE_DETAIL')):
            with self.assertRaises(siwc.SafeError) as caught:
                client.request('POST', siwc.TOKEN, data=data)
            self.assertNotIsInstance(caught.exception, siwc.TransientError)
            self.assertNotIn('SENSITIVE_DETAIL', str(caught.exception))

    def test_status_reports_revocation_and_recovers_postwrite_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)/'state'
            with siwc.locked_state(state):
                siwc.atomic_json(state/'credentials.json', OLD | {'auth_state':'login_required'})
            output = io.StringIO()
            with patch.object(siwc, 'Client', return_value=FakeClient([])), contextlib.redirect_stdout(output):
                siwc.main(['--state-dir', str(state), 'status'])
            import json
            self.assertFalse(json.loads(output.getvalue())['authenticated'])
            with siwc.locked_state(state), patch.object(siwc.time, 'time', return_value=180):
                saved = OLD | {'expires_at':4000, 'refresh_generation':'saved-operation'}
                siwc.atomic_json(state/'credentials.json', saved)
                siwc.atomic_json(state/'refresh-inflight.json', {'operation_id':'saved-operation'})
                fake = FakeClient([])
                _, result = siwc.refresh_session(state, fake)
                self.assertEqual(result['refresh'], 'not_due')
                self.assertFalse((state/'refresh-inflight.json').exists())
                self.assertEqual(fake.calls, [])

    def test_gateway_refresh_failure_keeps_marker_and_never_replays(self):
        import requests
        for status in [429, 502, 503, 504]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp)/'state'
                response = requests.Response()
                response.status_code = status
                response._content = b'{"detail":"SENSITIVE_GATEWAY_ERROR"}'
                response._content_consumed = True
                client = siwc.Client()
                with siwc.locked_state(state), patch.object(siwc.time, 'time', return_value=180), patch.object(siwc.time, 'sleep'):
                    siwc.atomic_json(state/'credentials.json', OLD)
                    with patch.object(client, 'get_jwks', return_value={'keys':[]}), patch.object(client.session, 'request', return_value=response) as post:
                        with self.assertRaises(siwc.SafeError): siwc.refresh_session(state, client)
                        self.assertTrue((state/'refresh-inflight.json').exists())
                        self.assertEqual(siwc.load_json(state/'credentials.json'), OLD)
                        with self.assertRaises(siwc.SafeError): siwc.refresh_session(state, client)
                        self.assertEqual(post.call_count, 1)

    def test_cli_rejects_abbreviated_state_override(self):
        import subprocess, sys
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, str(Path(siwc.__file__)), '--state=' + str(Path(tmp)/'state'), 'status'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)

if __name__ == '__main__':
    unittest.main()
