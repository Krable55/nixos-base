import unittest
from urllib.parse import parse_qs, urlsplit
import siwc

class AuthorizationTests(unittest.TestCase):
    def test_new_authorization_and_fail_closed_callback(self):
        self.assertTrue(callable(getattr(siwc, 'authorization', None)), 'authorization builder not implemented')
        pending = siwc.new_pending('urn:uuid:00000000-0000-4000-8000-000000000001', 18765)
        params = parse_qs(urlsplit(siwc.authorization(pending)).query)
        self.assertEqual(params['client_id'], ['dynamic_agent_client'])
        self.assertEqual(params['redirect_uri'], ['http://127.0.0.1:18765/auth/callback'])
        self.assertIn('chatgpt.tokens.use.direct', params['scope'][0].split())
        self.assertEqual(params['code_challenge_method'], ['S256'])
        self.assertEqual(params['resource'], ['https://api.openai.com/v1'])
        query = 'state=' + pending['state'] + '&code=not-a-real-code&client_id=oaiapp_test'
        self.assertEqual(siwc.callback(query, pending), ('oaiapp_test', 'not-a-real-code'))
        for bad in [query.replace(pending['state'], 'wrong'), query + '&state=duplicate',
                    query.replace('oaiapp_test', 'dynamic_agent_client'),
                    'state=' + pending['state'] + '&error=access_denied',
                    'state=' + pending['state'] + '&code=no-client']:
            with self.subTest(bad=bad), self.assertRaises(siwc.SafeError):
                siwc.callback(bad, pending)
        pending['client_id'] = 'oaiapp_previous'
        self.assertNotIn('agent_name_hint', parse_qs(urlsplit(siwc.authorization(pending)).query))
        with self.assertRaises(siwc.SafeError):
            siwc.callback(query, pending)

    def test_identity_signature_claims_and_scope(self):
        self.assertTrue(callable(getattr(siwc, 'validate_tokens', None)), 'identity validation not implemented')
        import json, time, jwt
        from cryptography.hazmat.primitives.asymmetric import rsa
        private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private.public_key()))
        jwk.update(kid='test-key', alg='RS256', use='sig')
        now = int(time.time())
        claims = {'iss': siwc.ISSUER, 'aud': 'oaiapp_test', 'sub': 'subject-test',
                  'exp': now + 300, 'iat': now, 'nonce': 'nonce-test'}
        def response(changes=None):
            return {'access_token': 'test-access', 'refresh_token': 'test-refresh',
                    'id_token': jwt.encode(claims | (changes or {}), private, algorithm='RS256', headers={'kid': 'test-key'}),
                    'token_type': 'Bearer', 'expires_in': 3600,
                    'scope': 'openid offline_access resource.invoke chatgpt.tokens.use.direct'}
        result = siwc.validate_tokens(response(), 'oaiapp_test', 'nonce-test', {'keys':[jwk]})
        self.assertEqual(result['subject'], 'subject-test')
        array_result = siwc.validate_tokens(response({'aud':['oaiapp_test']}), 'oaiapp_test', 'nonce-test', {'keys':[jwk]})
        self.assertEqual(array_result['subject'], 'subject-test')
        for changes in [{'aud':['wrong']}, {'aud':['oaiapp_test','untrusted-client']}, {'azp':'wrong'},
                        {'aud':'wrong'}, {'iss':'https://evil.example'}, {'exp':now-60}, {'nonce':'wrong'}]:
            with self.subTest(changes=changes), self.assertRaises(siwc.SafeError):
                siwc.validate_tokens(response(changes), 'oaiapp_test', 'nonce-test', {'keys':[jwk]})
        for field, value in [('scope','openid'), ('refresh_token',''), ('token_type','Basic')]:
            with self.subTest(field=field), self.assertRaises(siwc.SafeError):
                siwc.validate_tokens(response() | {field:value}, 'oaiapp_test', 'nonce-test', {'keys':[jwk]})
        with self.assertRaises(siwc.SafeError):
            siwc.validate_tokens(response(), 'oaiapp_test', 'nonce-test', {'keys':[]})
        with self.assertRaises(siwc.SafeError):
            siwc.validate_tokens(response(), 'oaiapp_test', 'nonce-test', {'keys':[jwk]}, expected_subject='other')

    def test_private_state_atomic_storage_and_lock(self):
        self.assertTrue(callable(getattr(siwc, 'locked_state', None)), 'private state storage not implemented')
        import tempfile, os, json
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state'
            with siwc.locked_state(state):
                siwc.atomic_json(state / 'credentials.json', {'test':'dummy-value'})
                self.assertEqual((state.stat().st_mode & 0o777), 0o700)
                self.assertEqual(((state/'credentials.json').stat().st_mode & 0o777), 0o600)
                self.assertEqual(siwc.load_json(state/'credentials.json'), {'test':'dummy-value'})
                with self.assertRaises(siwc.SafeError):
                    with siwc.locked_state(state):
                        pass
                (state/'link.json').symlink_to(state/'credentials.json')
                with self.assertRaises(siwc.SafeError):
                    siwc.load_json(state/'link.json')
                with self.assertRaises(siwc.SafeError):
                    siwc.atomic_json(state/'link.json', {'test':'overwrite'})
            os.chmod(state, 0o755)
            with self.assertRaises(siwc.SafeError):
                with siwc.locked_state(state):
                    pass

    def test_response_wire_and_stream_completion(self):
        self.assertTrue(callable(getattr(siwc, 'inference_body', None)), 'Responses transport not implemented')
        import json
        body = siwc.inference_body('test-model')
        self.assertEqual(set(body), {'model','input','stream','store'})
        self.assertIs(body['store'], False)
        self.assertIs(body['stream'], True)
        self.assertIsInstance(body['input'], list)
        complete = ['data: ' + json.dumps({'type':'response.output_text.delta', 'delta':'Hello from Pi4.'}), '',
                    'data: ' + json.dumps({'type':'response.completed','response':{'status':'completed'}}), '']
        self.assertEqual(siwc.consume_events(iter(complete)), 'Hello from Pi4.')
        for lines in [complete[:2], ['data: {"type":"response.failed"}', ''],
                      ['data: {"type":"response.incomplete"}', ''],
                      ['data: {"type":"response.completed","response":{"status":"failed"}}', '']]:
            with self.assertRaises(siwc.SafeError):
                siwc.consume_events(iter(lines))
        client = siwc.Client()
        self.assertFalse(client.session.trust_env)
        for bad_url in ['http://api.openai.com/v1/models','https://evil.example/v1/models',
                        'https://api.openai.com/v1/models?access_token=dummy',
                        'https://api.openai.com.evil.example/v1/models']:
            with self.assertRaises(siwc.SafeError):
                client.request('GET', bad_url)

    def test_loopback_callback_server_and_cli(self):
        self.assertTrue(callable(getattr(siwc, 'make_server', None)), 'loopback login server not implemented')
        import http.client, threading, subprocess, sys
        pending = siwc.new_pending('urn:uuid:00000000-0000-4000-8000-000000000001', 0)
        server = siwc.make_server(pending)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            conn.request('GET', '/health')
            self.assertEqual(conn.getresponse().status, 200)
            conn.close()
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            conn.request('GET', '/start', headers={'Host':'evil.example'})
            self.assertEqual(conn.getresponse().status, 400)
            conn.close()
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            conn.request('GET', '/auth/callback?state=wrong&code=test&client_id=oaiapp_test')
            self.assertEqual(conn.getresponse().status, 400)
            self.assertFalse(server.callback_ready.is_set())
            conn.close()
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            conn.request('GET', '/auth/callback?state=' + pending['state'] + '&code=test&client_id=oaiapp_test')
            self.assertEqual(conn.getresponse().status, 303)
            self.assertTrue(server.callback_ready.wait(1))
            self.assertEqual(server.callback_result, ('oaiapp_test', 'test'))
            conn.close()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(2)
        result = subprocess.run([sys.executable, str(siwc.Path(siwc.__file__)), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('login', result.stdout)

    def test_refresh_gate_and_atomic_credential_replacement(self):
        self.assertTrue(callable(getattr(siwc, 'refresh_due', None)), 'refresh support not implemented')
        old = {'expires_at':1000, 'saved_at':0, 'subject':'same-subject', 'client_id':'oaiapp_test',
               'refresh_token':'old-dummy', 'access_token':'old-access', 'id_token':'previously-validated-id',
               'scopes':['chatgpt.tokens.use.direct','resource.invoke','offline_access'],
               'ext_agent_host_id':'urn:uuid:test'}
        self.assertFalse(siwc.refresh_due(old, 500))
        self.assertTrue(siwc.refresh_due(old, 900))
        self.assertFalse(siwc.refresh_due(old | {'earliest_refresh_at':950}, 900))
        new = siwc.refresh_credentials({'access_token':'new-access','refresh_token':'new-refresh',
                                       'token_type':'Bearer','expires_in':3600}, old, {'keys':[]})
        self.assertEqual(new['subject'], old['subject'])
        self.assertEqual(new['refresh_token'], 'new-refresh')
        self.assertEqual(new['client_id'], old['client_id'])
        with self.assertRaises(siwc.SafeError):
            siwc.refresh_credentials({'access_token':'new-access', 'refresh_token':'new-refresh',
                                      'token_type':'Bearer', 'expires_in':3600, 'scope':'openid'}, old, {'keys':[]})

    def test_incomplete_http_request_does_not_block_callback(self):
        import socket, threading, http.client, time
        server = siwc.make_server(siwc.new_pending('urn:uuid:test', 0))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        stalled = socket.create_connection(('127.0.0.1', server.server_port), timeout=1)
        stalled.sendall(b'GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n')
        try:
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=1)
            connection.request('GET', '/health')
            self.assertEqual(connection.getresponse().status, 200)
            connection.close()
            shutdown = threading.Thread(target=server.shutdown, daemon=True)
            shutdown.start()
            shutdown.join(2)
            self.assertFalse(shutdown.is_alive(), 'shutdown blocked on incomplete headers')
        finally:
            stalled.close()
            server.shutdown()
            server.server_close()
            worker.join(2)

    def test_existing_credentials_bind_identity_after_interrupted_registration_write(self):
        self.assertTrue(callable(getattr(siwc, 'read_registration', None)), 'account reconciliation not implemented')
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)/'state'
            with siwc.locked_state(state):
                siwc.atomic_json(state/'registration.json', {'client_id':'oaiapp_test','host_id':'host'})
                siwc.atomic_json(state/'credentials.json', {'client_id':'oaiapp_test', 'subject':'original-subject', 'ext_agent_host_id':'host'})
                restored = siwc.read_registration(state, 'host')
                self.assertEqual(restored['subject'], 'original-subject')
                siwc.atomic_json(state/'registration.json', {'client_id':'different-client','host_id':'host'})
                with self.assertRaises(siwc.SafeError):
                    siwc.read_registration(state, 'host')

    def test_validation_failure_identifies_check_without_secret_values(self):
        sentinel = 'SENSITIVE_TEST_VALUE_DO_NOT_LOG'
        with self.assertRaises(siwc.SafeError) as caught:
            siwc.validate_tokens({'access_token':sentinel, 'refresh_token':sentinel,
                                  'id_token':sentinel, 'token_type':'Bearer',
                                  'expires_in':3600, 'scope':'openid'}, 'oaiapp_test', 'nonce', {'keys':[]})
        self.assertIn('stage=granted_scopes', str(caught.exception))
        self.assertNotIn(sentinel, str(caught.exception))

if __name__ == '__main__':
    unittest.main()
