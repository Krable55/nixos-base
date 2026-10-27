"""New approved contract, run by regression.py in its disposable fixture tree.
Historical fixtures/results are never edited. The original args-done-only
omission negative remains valid; only explicit item-done + [] is newly accepted.
"""
import copy
import json
from pathlib import Path
import unittest
import gate6_acceptance as old


class EmptyCompletion(old.Acceptance):
    def test_empty_completion_real_binary_roundtrip(self):
        mock = old.ROOT / 'adapter/mock_upstream_gate2.py'
        original = mock.read_text()
        needle = "def emit_completion_with_output(handler, output_items, status='completed'):\n"
        assert original.count(needle) == 1
        extension = """    # Approved new fixture: finalize actual streamed function items, then
    # explicitly empty terminal output. No change to adapter or client events.
    for output_index, item in enumerate(output_items):
        if item.get('type') == 'function_call':
            handler.send_chunk(sse('response.output_item.done', {'output_index': output_index, 'item': item}))
    output_items = []
"""
        try:
            mock.write_text(original.replace(needle, needle + extension))
            self.test_secure_cli_real_binary_tool_roundtrip()
            requests = [json.loads(line) for line in (self.path / 'mock.jsonl').read_text().splitlines()]
            reasoning = next(i for i in requests[1]['body']['input'] if i.get('type') == 'reasoning')
            self.assertEqual(reasoning['id'], 'rs_1')
            self.assertEqual(reasoning['encrypted_content'], 'enc_reasoning_marker')
            self.assertEqual(reasoning['summary'], [])
        finally:
            mock.write_text(original)

    def test_empty_completion_http_contract(self):
        added = old.announced(); added['output_index'] = 0; added['response_id'] = 'r1'
        args = old.done(); args['output_index'] = 0; args['response_id'] = 'r1'
        item = dict(added['item'], arguments=old.CANARY, status='completed')
        done = dict(type='response.output_item.done', response_id='r1', output_index=0, item=item)
        end = old.completed(); end['response']['id'] = 'r1'
        positive = [added, args, done, end]
        with self.servers(positive) as port:
            _, data = self.request(port)
            self.assertEqual(data, b''.join(old.frame(e) for e in positive))
        negatives = [positive[:2] + [end]]
        missing = copy.deepcopy(positive); del missing[-1]['response']['output']; negatives.append(missing)
        partial = copy.deepcopy(positive); partial[-1]['response']['output'] = [{'type': 'message'}]; negatives.append(partial)
        for key, value in [('id', 'other'), ('call_id', 'other'), ('name', 'other'), ('arguments', 'other'),
                           ('type', 'message'), ('status', 'incomplete')]:
            changed = copy.deepcopy(positive); changed[-2]['item'][key] = value; negatives.append(changed)
        for key, value in [('output_index', 1), ('response_id', 'other')]:
            changed = copy.deepcopy(positive); changed[-2][key] = value; negatives.append(changed)
        duplicate = copy.deepcopy(positive); extra = copy.deepcopy(added)
        extra['item']['id'] = 'fc_2'; extra['output_index'] = 1; duplicate.insert(1, extra); negatives.append(duplicate)
        for index, stream in enumerate(negatives):
            with self.subTest(case=index), self.servers(stream) as port:
                _, data = self.request(port)
                self.assertNotIn(b'response.completed', data)
                self.assertIn(b'"type": "error"', data)


if __name__ == '__main__':
    suite = unittest.TestSuite(EmptyCompletion(name) for name in (
        'test_empty_completion_real_binary_roundtrip', 'test_empty_completion_http_contract'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps(dict(tests_run=result.testsRun, failures=len(result.failures), errors=len(result.errors))))
    raise SystemExit(not result.wasSuccessful())
