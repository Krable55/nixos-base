"""Approved empty-output exception: synthetic, pure contract tests."""
import copy
import importlib.util
import os
from pathlib import Path
import unittest

SOURCE = Path(os.environ.get('ADAPTER_SOURCE', Path(__file__).resolve().parents[2] / 'packages/siwc-adapter/filtering_adapter.py'))
spec = importlib.util.spec_from_file_location('candidate', SOURCE)
assert spec is not None and spec.loader is not None
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def events():
    item = dict(type='function_call', id='fc_1', call_id='call_1', name='calculator', arguments='')
    final = dict(item, arguments='{}', status='completed')
    return [
        dict(type='response.output_item.added', response_id='resp_1', output_index=0, item=item),
        dict(type='response.function_call_arguments.delta', response_id='resp_1', output_index=0, item_id='fc_1', delta='{}'),
        dict(type='response.function_call_arguments.done', response_id='resp_1', output_index=0, item_id='fc_1', arguments='{}'),
        dict(type='response.output_item.done', response_id='resp_1', output_index=0, item=final),
        dict(type='response.completed', response=dict(id='resp_1', status='completed', output=[])),
    ]


def check(stream):
    tracked = a.ToolCalls() if hasattr(a, 'ToolCalls') else {}
    for event in stream[:-1]:
        violation = a.track_incremental_tool_call(tracked, event)
        if violation:
            return violation
    return a.find_integrity_violation(tracked, stream[-1])


class Contract(unittest.TestCase):
    def test_explicit_done_empty_output_accepted_without_mutation(self):
        stream = events(); before = copy.deepcopy(stream)
        self.assertIsNone(check(stream))
        self.assertEqual(stream, before)

    def test_final_item_identity_and_lifecycle(self):
        for field, value in [('id', 'other'), ('call_id', 'other'), ('name', 'other'),
                             ('arguments', 'other'), ('type', 'message'), ('status', 'incomplete')]:
            with self.subTest(field=field):
                stream = events(); stream[-2]['item'][field] = value
                self.assertIsNotNone(check(stream))
        for field in ('id', 'call_id', 'name', 'arguments', 'type'):
            with self.subTest(missing=field):
                stream = events(); del stream[-2]['item'][field]
                self.assertIsNotNone(check(stream))
        for field, value in [('output_index', 1), ('output_index', -1), ('output_index', True),
                             ('response_id', 'other')]:
            with self.subTest(field=field, value=value):
                stream = events(); stream[-2][field] = value
                self.assertIsNotNone(check(stream))
        stream = events(); stream[-1]['response']['id'] = 'other'
        self.assertIsNotNone(check(stream))
        stream = events(); stream.insert(-1, copy.deepcopy(stream[-2]))
        stream[-2]['item']['arguments'] = 'changed'
        self.assertIsNotNone(check(stream))

    def test_unique_call_and_index(self):
        for field in ('call_id', 'output_index'):
            stream = events(); extra = copy.deepcopy(stream[0])
            extra['item']['id'] = 'fc_2'
            if field == 'call_id': extra['output_index'] = 1
            else: extra['item']['call_id'] = 'call_2'
            stream.insert(1, extra)
            # Full completion avoids omission hiding a missed duplicate.
            stream[-1]['response']['output'] = [dict(stream[-2]['item']), dict(extra['item'])]
            self.assertIsNotNone(check(stream))

    def test_completion_contradictions(self):
        for output in (None, {}, [{'type': 'message'}]):
            stream = events(); stream[-1]['response']['output'] = output
            self.assertIsNotNone(check(stream))
        for field, value in [('call_id', 'other'), ('arguments', 'other'),
                             ('type', 'message'), ('status', 'incomplete')]:
            stream = events(); item = dict(stream[-2]['item']); item[field] = value
            stream[-1]['response']['output'] = [item]
            self.assertIsNotNone(check(stream))
        stream = events(); stream[-1]['response']['output'] = [dict(stream[-2]['item'])]
        self.assertIsNone(check(stream))

    def test_full_output_index_and_non_tool_collision(self):
        stream = events(); stream[-1]['response']['output'] = [{'type': 'reasoning'}, dict(stream[-2]['item'])]
        self.assertIsNotNone(check(stream))
        stream = events(); stream.insert(-1, dict(type='response.output_item.done', output_index=0,
                                                 item=dict(id='rs_1', type='reasoning')))
        self.assertIsNotNone(check(stream))

    def test_nonempty_initial_arguments_cannot_change(self):
        stream = events(); stream[0]['item']['arguments'] = 'initial'; del stream[1]
        self.assertIsNotNone(check(stream))

    def test_multiple_calls_need_every_item_done(self):
        first = events(); second = copy.deepcopy(first)
        for event in second[:-1]:
            event['output_index'] = 1
            if 'item' in event:
                event['item']['id'] = 'fc_2'; event['item']['call_id'] = 'call_2'
            else: event['item_id'] = 'fc_2'
        stream = first[:-1] + second
        self.assertIsNone(check(stream))
        del stream[-2]
        self.assertIsNotNone(check(stream))
        stream = first[:-1] + second
        stream[-1]['response']['output'] = [dict(first[-2]['item'])]
        self.assertIsNotNone(check(stream))

    def test_arguments_done_alone_rejected(self):
        stream = events(); del stream[-2]
        self.assertIsNotNone(check(stream))

    def test_absent_output_rejected(self):
        stream = events(); del stream[-1]['response']['output']
        self.assertIsNotNone(check(stream))


if __name__ == '__main__': unittest.main()
