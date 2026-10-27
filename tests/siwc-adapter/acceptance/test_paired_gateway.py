#!/usr/bin/env python3
import hashlib
import json
import pathlib
import socket
import struct
import sys
import unittest
from unittest.mock import Mock, patch

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import paired_gateway as pg


class WebSocketFrameTests(unittest.TestCase):
    def test_upgrade_writer_sends_runtime_bearer_and_header_terminator(self):
        synthetic_bearer = "synthetic-paired-bearer-for-wire-test"
        client, server = socket.socketpair()
        try:
            pg.send_ws_upgrade_request(
                client,
                bearer=synthetic_bearer,
                query="agent=pi4&session_id=synthetic",
                key="c3ludGhldGljLXdlYnNvY2tldC1rZXk=",
            )
            client.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                chunk = server.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            actual_wire = b"".join(chunks)
        finally:
            client.close()
            server.close()

        expected_header = (
            ("Author" + "ization") + ": " + ("Bear" + "er ") + synthetic_bearer
        ).encode()
        self.assertIn(expected_header + b"\r\n", actual_wire)
        self.assertTrue(actual_wire.endswith(b"\r\n\r\n"))
        self.assertNotIn(b"***", actual_wire)

    def test_client_text_frame_is_masked_and_roundtrips(self):
        payload = json.dumps({"type": "message", "content": "hello"}, separators=(",", ":")).encode()
        frame = pg.encode_client_frame(0x1, payload, mask=b"\x01\x02\x03\x04")
        self.assertEqual(frame[0], 0x81)
        self.assertTrue(frame[1] & 0x80)
        opcode, decoded = pg.decode_frame_bytes(frame, expect_masked=True)
        self.assertEqual(opcode, 0x1)
        self.assertEqual(decoded, payload)

    def test_server_frame_decoder_accepts_extended_payload(self):
        payload = b"x" * 130
        frame = bytes([0x81, 126]) + struct.pack("!H", len(payload)) + payload
        opcode, decoded = pg.decode_frame_bytes(frame, expect_masked=False)
        self.assertEqual(opcode, 0x1)
        self.assertEqual(decoded, payload)


class SessionCleanupTests(unittest.TestCase):
    def run_synthetic(self, start=None, websocket_error=None):
        requests = []
        revoked = False

        def fake_http(method, path, **kwargs):
            nonlocal revoked
            requests.append((method, path))
            if (method, path) == ("GET", "/health"):
                return 200, {"require_pairing": True, "paired": False}
            if (method, path) == ("POST", "/api/pair"):
                return 200, {"paired": True, "persisted": True, "token": "synthetic-token"}
            if (method, path) == ("GET", "/api/devices"):
                if revoked:
                    return 401, {}
                return 200, {"devices": [{
                    "id": "synthetic-device", "name": "siwc-synthetic-cleanup",
                    "device_type": pg.DEVICE_TYPE,
                }]}
            if method == "GET" and path.startswith("/api/memory?"):
                return 200, {"entries": []}
            if (method, path) == ("DELETE", "/api/devices/synthetic-device"):
                revoked = True
                return 200, {}
            if (method, path) == ("DELETE", "/api/sessions/synthetic-cleanup"):
                return 200, {}
            raise AssertionError(f"Unexpected synthetic HTTP request: {method} {path}")

        ws = Mock()
        ws.recv_json.side_effect = [start, {"type": "invalid-connected"}]
        paircode = Mock(returncode=0, stdout=b'{"pairing_code":"synthetic-code"}')
        with (
            patch.dict(pg.os.environ, {"SIWC_ACCEPTANCE_RUN_ID": "synthetic-cleanup"}),
            patch.object(pg, "http_json", side_effect=fake_http),
            patch.object(pg.subprocess, "run", return_value=paircode),
            patch.object(pg, "WsClient", return_value=ws, side_effect=websocket_error),
        ):
            report = pg.run()
        session_deletes = [request for request in requests
                           if request[0] == "DELETE" and request[1].startswith("/api/sessions/")]
        return report, session_deletes, ws

    def test_resumed_session_is_not_deleted(self):
        report, deletes, ws = self.run_synthetic({"type": "session_start", "resumed": True})
        self.assertEqual(report["failure"], "session_start_invalid")
        self.assertEqual(deletes, [])
        self.assertFalse(report["cleanup"]["session_deleted"])
        ws.close.assert_called_once()

    def test_precreation_failure_does_not_delete_session(self):
        report, deletes, ws = self.run_synthetic(
            websocket_error=pg.HarnessError("synthetic_precreation_failure")
        )
        self.assertEqual(report["failure"], "synthetic_precreation_failure")
        self.assertEqual(deletes, [])
        self.assertFalse(report["cleanup"]["session_deleted"])
        ws.close.assert_not_called()

    def test_fresh_session_is_deleted_after_later_failure(self):
        report, deletes, ws = self.run_synthetic({"type": "session_start", "resumed": False})
        self.assertEqual(report["failure"], "session_connect_invalid")
        self.assertEqual(deletes, [("DELETE", "/api/sessions/synthetic-cleanup")])
        self.assertTrue(report["cleanup"]["session_deleted"])
        ws.close.assert_called_once()

    def test_unconfirmed_session_start_does_not_delete_session(self):
        for start in [
            {"type": "session_start"},
            {"type": "session_start", "resumed": 0},
            {"type": "invalid-start", "resumed": False},
        ]:
            with self.subTest(start=start):
                report, deletes, ws = self.run_synthetic(start)
                self.assertEqual(report["failure"], "session_start_invalid")
                self.assertEqual(deletes, [])
                self.assertFalse(report["cleanup"]["session_deleted"])
                ws.close.assert_called_once()


class ReceiptTests(unittest.TestCase):
    def test_paircode_command_requests_one_additional_client_without_rotation(self):
        command = pg.paircode_command()
        self.assertIn("--new", command)
        self.assertNotIn("--rotate", command)
        self.assertNotIn("--rotate-device", command)
        self.assertEqual(command[-1], "--json")

    def test_tool_turn_receipt_contains_only_safe_evidence(self):
        events = [
            {"type": "tool_call", "id": "secret-call-id", "name": "calculator", "args": {"expression": "321 * 654"}},
            {"type": "tool_result", "id": "secret-call-id", "name": "calculator", "output": "209934"},
            {"type": "done", "full_response": "STAGE1_CALC=209934", "model": "gpt-5.6-sol", "provider": "openai.siwc", "tokens_used": 17},
        ]
        receipt = pg.safe_tool_receipt(events, expected="209934")
        self.assertEqual(receipt, {
            "calculator_call_seen": True,
            "calculator_result_seen": True,
            "calculator_output_matches": True,
            "answer_matches": True,
            "model": "gpt-5.6-sol",
            "terminal_type": "done",
        })
        encoded = json.dumps(receipt)
        self.assertNotIn("secret-call-id", encoded)
        self.assertNotIn("expression", encoded)
        self.assertNotIn("provider", encoded)

    def test_proposed_provider_budget_counts_both_ambiguous_background_attempts(self):
        self.assertEqual(
            pg.provider_request_budget(tool_loop_calls=2, ws_background_attempts=2, followup_calls=1),
            5,
        )
        with self.assertRaises(ValueError):
            pg.provider_request_budget(tool_loop_calls=2, ws_background_attempts=3, followup_calls=1)

    def test_followup_uses_second_message_on_same_websocket(self):
        class FakeWebSocket:
            def __init__(self):
                self.sent = []
                self.events = iter([
                    {"type": "done", "full_response": "FIRST"},
                    {"type": "done", "full_response": "STAGE2_FOLLOWUP_OK", "model": "gpt-5.6-sol"},
                ])

            def send_json(self, value):
                self.sent.append(value)

            def recv_json(self):
                return next(self.events)

        ws = FakeWebSocket()
        first = pg.run_ws_message(ws, "first")
        followup = pg.run_ws_message(ws, "followup")
        self.assertEqual(first[-1]["full_response"], "FIRST")
        self.assertEqual(followup[-1]["full_response"], "STAGE2_FOLLOWUP_OK")
        self.assertEqual(
            ws.sent,
            [
                {"type": "message", "content": "first"},
                {"type": "message", "content": "followup"},
            ],
        )

    def test_followup_prompt_requires_prior_result_without_disclosing_it(self):
        prompt = pg.followup_prompt()
        self.assertIn("previous calculator turn", prompt)
        self.assertIn("STAGE2_PRIOR_RESULT=<result>", prompt)
        self.assertNotIn(pg.EXPECTED, prompt)
        self.assertNotIn("STAGE2_FOLLOWUP_OK", prompt)

    def test_followup_receipt_classifies_safe_response_shapes(self):
        expected = "STAGE2_PRIOR_RESULT=209934"
        fixtures = {
            expected: "expected",
            '"STAGE2_PRIOR_RESULT=209934"': "quoted_or_fenced_expected",
            "```text\nSTAGE2_PRIOR_RESULT=209934\n```": "quoted_or_fenced_expected",
            "STAGE1_CALC=209934": "previous_answer",
            "": "empty",
            "unrelated private prose": "other",
        }
        for raw_response, expected_class in fixtures.items():
            with self.subTest(expected_class=expected_class):
                events = [
                    {
                        "type": "done",
                        "full_response": raw_response,
                        "model": pg.MODEL,
                    }
                ]
                receipt = pg.safe_followup_receipt(
                    events,
                    expected=expected,
                    previous_answer="STAGE1_CALC=209934",
                    expected_model=pg.MODEL,
                )
                self.assertEqual(receipt["response_class"], expected_class)
                self.assertEqual(receipt["answer_matches"], expected_class == "expected")
                self.assertTrue(receipt["model_matches"])
                self.assertEqual(receipt["tool_calls"], 0)
                self.assertEqual(receipt["terminal_type"], "done")
                self.assertTrue(receipt["completion_correlated"])
                encoded = json.dumps(receipt)
                self.assertNotIn(raw_response or "unreachable-empty-marker", encoded)
                self.assertNotIn("full_response", encoded)

    def test_followup_failure_retains_safe_partial_report(self):
        raw_private_response = '"STAGE2_PRIOR_RESULT=209934" plus private prose'
        events = [
            {"type": "chunk", "content": raw_private_response},
            {
                "type": "done",
                "full_response": raw_private_response,
                "model": pg.MODEL,
            },
        ]
        partial = {}
        with self.assertRaises(pg.HarnessError) as caught:
            pg.record_followup_result(
                partial,
                events,
                expected="STAGE2_PRIOR_RESULT=209934",
                previous_answer="STAGE1_CALC=209934",
                expected_model=pg.MODEL,
            )
        self.assertEqual(caught.exception.code, "followup_acceptance_failed")
        self.assertEqual(partial["followup"]["response_class"], "other")
        self.assertEqual(partial["followup"]["event_counts"]["chunk"], 1)
        self.assertEqual(partial["followup"]["event_counts"]["done"], 1)
        self.assertNotIn(raw_private_response, json.dumps(partial))

    def test_followup_error_receipt_classifies_only_allowlisted_metadata(self):
        private_message = "private dynamic provider failure detail"
        events = [{
            "type": "error",
            "message": private_message,
            "code": "SESSION_RESTORE_UNAVAILABLE",
            "http_status": 503,
            "provider_code": "rate_limit_exceeded",
        }]
        receipt = pg.safe_followup_receipt(
            events,
            expected="STAGE2_PRIOR_RESULT=209934",
            previous_answer="STAGE1_CALC=209934",
            expected_model=pg.MODEL,
        )
        self.assertEqual(receipt["error_category"], "history")
        self.assertEqual(receipt["http_status"], 503)
        self.assertEqual(receipt["provider_code_class"], "rate_limit")
        encoded = json.dumps(receipt)
        self.assertNotIn(private_message, encoded)
        self.assertNotIn("SESSION_RESTORE_UNAVAILABLE", encoded)
        self.assertNotIn("rate_limit_exceeded", encoded)

    def test_followup_error_receipt_rejects_dynamic_or_malformed_metadata(self):
        private_code = "DYNAMIC_PRIVATE_CODE"
        private_provider_code = "private-provider-detail"
        events = [{
            "type": "error",
            "message": "private message",
            "code": private_code,
            "http_status": "503",
            "provider_code": private_provider_code,
        }]
        receipt = pg.safe_followup_receipt(
            events,
            expected="STAGE2_PRIOR_RESULT=209934",
            previous_answer="STAGE1_CALC=209934",
            expected_model=pg.MODEL,
        )
        self.assertEqual(receipt["error_category"], "other")
        self.assertIsNone(receipt["http_status"])
        self.assertEqual(receipt["provider_code_class"], "other")
        encoded = json.dumps(receipt)
        self.assertNotIn(private_code, encoded)
        self.assertNotIn(private_provider_code, encoded)

    def test_followup_uncorrelated_completion_is_not_called_production_failure(self):
        events = [
            {"type": "done", "full_response": "STAGE2_PRIOR_RESULT=209934", "model": pg.MODEL},
            {"type": "chunk", "content": "late"},
        ]
        partial = {}
        with self.assertRaises(pg.HarnessError) as caught:
            pg.record_followup_result(
                partial,
                events,
                expected="STAGE2_PRIOR_RESULT=209934",
                previous_answer="STAGE1_CALC=209934",
                expected_model=pg.MODEL,
            )
        self.assertEqual(caught.exception.code, "followup_completion_uncorrelated")
        self.assertFalse(partial["followup"]["completion_correlated"])

    def test_memory_snapshot_detects_new_or_changed_entries_without_retaining_content(self):
        before = [{"key": "keep", "content": "private old", "category": "core"}]
        after = [
            {"key": "keep", "content": "private old", "category": "core"},
            {"key": "daily_new", "content": "temporary result", "category": "daily"},
        ]
        baseline = pg.memory_fingerprints(before)
        current = pg.memory_fingerprints(after)
        self.assertEqual(pg.new_memory_keys(baseline, current), {"daily_new"})
        self.assertEqual(pg.changed_memory_keys(baseline, current), set())
        self.assertEqual(
            baseline["keep"],
            hashlib.sha256(b"core\x00private old").hexdigest(),
        )

    def test_report_secret_guard_rejects_secret_fields_recursively(self):
        pg.assert_report_safe({"paired": True, "cleanup": {"device_revoked": True}})
        for report in [
            {"token": "x"},
            {"nested": {"pairing_code": "123456"}},
            {"adminToken": "x"},
            {"capability": "x"},
            {"credentialJSON": "x"},
        ]:
            with self.assertRaises(ValueError):
                pg.assert_report_safe(report)


if __name__ == "__main__":
    unittest.main()
