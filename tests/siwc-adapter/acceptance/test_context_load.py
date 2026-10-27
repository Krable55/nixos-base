#!/usr/bin/env python3
from __future__ import annotations

import http.client
import http.server
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import tomllib
import types
import unittest

import context_load as cl


CANONICAL = b'''schema_version = 3

[providers.models.openai.siwc]
uri = "http://127.0.0.1:18766/v1/responses"
wire_api = "responses"
requires_openai_auth = true
api_key = "synthetic-local-capability"
model = "gpt-5.6-sol"
context_window = 872000

[reliability]
provider_retries = 0

[gateway]
host = "127.0.0.1"
port = 42617
require_pairing = true
allow_public_bind = false

[runtime_profiles.siwc]
max_context_tokens = 872000
context_compact_ratio = 0.9
max_tool_iterations = 20
agentic = false

[risk_profiles.siwc]
level = "supervised"
workspace_only = true

[agents.pi4]
enabled = true
model_provider = "openai.siwc"
runtime_profile = "siwc"
risk_profile = "siwc"

[agents.pi4.memory]
backend = "sqlite"
'''


def _reserve_large_worker(ledger_path: str, queue: multiprocessing.Queue) -> None:
    try:
        cl.QuotaLedger.open(Path(ledger_path)).reserve("native", 8)
        queue.put(True)
    except cl.QuotaExceeded:
        queue.put(False)


def _reserve_direct_small_worker(ledger_path: str, queue: multiprocessing.Queue) -> None:
    try:
        cl.QuotaLedger.open(Path(ledger_path)).reserve("direct", 1)
        queue.put(True)
    except cl.QuotaExceeded:
        queue.put(False)


def _parent_receipts(directory: Path) -> tuple[Path, Path, str, str]:
    durable = {
        "schema_version": 1,
        "run_id": "siwc-context-load-user-task-v1",
        "large_threshold": 128 * 1024,
        "large_forwarded_total": 0,
        "large_remaining": {"native": 1, "direct": 1},
        "small_reserved": {"native": 0, "direct": 1},
        "small_remaining": {"native": 2, "direct": 1},
    }
    live = {
        "failure": "calibration_failed_no_large_spend",
        "ledger_summary": durable,
        "proxy_receipts": [{
            "phase": "direct",
            "size_class": "small",
            "forwarded": True,
            "upstream_status": 400,
            "outcome": "ambiguous_failure",
        }],
    }
    live_path = directory / "live.json"
    live_path.write_text(json.dumps(live, sort_keys=True))
    os.chmod(live_path, 0o600)
    live_hash = hashlib.sha256(live_path.read_bytes()).hexdigest()
    summary = {
        "status": "verified_preflight_failure_no_large_spend",
        "source_report": {"sha256": live_hash},
        "durable_ledger": durable,
    }
    summary_path = directory / "summary.json"
    summary_path.write_text(json.dumps(summary, sort_keys=True))
    os.chmod(summary_path, 0o600)
    return summary_path, live_path, hashlib.sha256(summary_path.read_bytes()).hexdigest(), live_hash


class QuotaTests(unittest.TestCase):
    def test_large_slots_are_phase_reserved_and_never_refunded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ledger_path = Path(directory) / "budget.json"
            quota = cl.QuotaLedger.initialize(
                ledger_path,
                large_threshold=128 * 1024,
                small_limits={"native": 2, "direct": 2},
                run_id="task-owned-budget-v1",
            )

            native = quota.reserve("native", 128 * 1024)
            native.mark_ambiguous_failure()
            with self.assertRaises(cl.QuotaExceeded):
                quota.reserve("native", 128 * 1024)

            direct = quota.reserve("direct", 128 * 1024)
            direct.mark_completed()
            with self.assertRaises(cl.QuotaExceeded):
                quota.reserve("direct", 128 * 1024)

            self.assertEqual(quota.snapshot()["large_forwarded_total"], 2)
            self.assertEqual(quota.snapshot()["large_remaining"], {"native": 0, "direct": 0})
            reopened = cl.QuotaLedger.open(ledger_path)
            with self.assertRaises(cl.QuotaExceeded):
                reopened.reserve("native", 128 * 1024)
            self.assertTrue(Path(str(ledger_path) + ".lock").exists())

    def test_small_budget_is_separate_and_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            quota = cl.QuotaLedger.initialize(
                Path(directory) / "budget.json",
                large_threshold=128 * 1024,
                small_limits={"native": 1, "direct": 2},
                run_id="task-owned-budget-v1",
            )
            quota.reserve("native", 1)
            with self.assertRaises(cl.QuotaExceeded):
                quota.reserve("native", 1)
            quota.reserve("direct", 1)
            quota.reserve("direct", 127 * 1024)
            with self.assertRaises(cl.QuotaExceeded):
                quota.reserve("direct", 1)
            self.assertEqual(quota.snapshot()["large_forwarded_total"], 0)

    def test_concurrent_native_large_reservations_admit_exactly_one(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ledger_path = Path(directory) / "budget.json"
            cl.QuotaLedger.initialize(
                ledger_path,
                large_threshold=8,
                small_limits={"native": 0, "direct": 0},
                run_id="task-owned-budget-v1",
            )
            context = multiprocessing.get_context("fork")
            queue = context.Queue()
            processes = [
                context.Process(target=_reserve_large_worker, args=(str(ledger_path), queue))
                for _ in range(8)
            ]
            for process in processes:
                process.start()
            for process in processes:
                process.join(5)
                self.assertEqual(process.exitcode, 0)
            admitted = [queue.get(timeout=1) for _ in processes]
            self.assertEqual(admitted.count(True), 1)

    def test_initialized_ledger_fails_closed_if_missing_or_malformed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ledger_path = Path(directory) / "budget.json"
            cl.QuotaLedger.initialize(
                ledger_path,
                large_threshold=8,
                small_limits={"native": 1, "direct": 1},
                run_id="task-owned-budget-v1",
            )
            ledger_path.unlink()
            with self.assertRaises(cl.LedgerError):
                cl.QuotaLedger.open(ledger_path)
            ledger_path.write_text("not-json")
            with self.assertRaises(cl.LedgerError):
                cl.QuotaLedger.open(ledger_path)
            with self.assertRaises(cl.LedgerError):
                cl.QuotaLedger.initialize(
                    ledger_path,
                    large_threshold=8,
                    small_limits={"native": 1, "direct": 1},
                    run_id="task-owned-budget-v1",
                )

    def test_safe_budget_summary_contains_counts_not_request_material(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ledger = cl.QuotaLedger.initialize(
                Path(directory) / "budget.json",
                large_threshold=8,
                small_limits={"native": 1, "direct": 1},
                run_id="task-owned-budget-v1",
            )
            ledger.reserve("native", 8)
            destination = Path(directory) / "safe-summary.json"
            cl.write_safe_budget_summary(ledger, destination)
            summary_text = destination.read_text()
            summary = json.loads(summary_text)
            self.assertEqual(summary["large_forwarded_total"], 1)
            self.assertEqual(summary["large_remaining"], {"native": 0, "direct": 1})
            self.assertNotIn("body", summary_text)
            self.assertNotIn("authorization", summary_text.lower())


class ResumeTests(unittest.TestCase):
    def test_resume_carries_counters_and_only_migrates_direct_small_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary, live, summary_hash, live_hash = _parent_receipts(Path(directory))
            state, evidence = cl.build_resumed_ledger_state(
                summary,
                live,
                expected_summary_sha256=summary_hash,
                expected_live_sha256=live_hash,
            )
            self.assertEqual(state, {
                "schema_version": 1,
                "run_id": "siwc-context-load-user-task-v1",
                "large_threshold": 128 * 1024,
                "large_forwarded_total": 0,
                "phases": {
                    "native": {"large_reserved": False, "small_limit": 2, "small_reserved": 0},
                    "direct": {"large_reserved": False, "small_limit": 3, "small_reserved": 1},
                },
            })
            self.assertEqual(evidence["migration"], {
                "phase": "direct",
                "small_limit_before": 2,
                "small_limit_after": 3,
                "small_reserved_carried": 1,
                "additional_small_allowance": 1,
            })
            self.assertIn("Astra", evidence["parent_authorization"])

    def test_resume_rejects_missing_parent_receipt_as_ledger_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary, live, summary_hash, live_hash = _parent_receipts(Path(directory))
            live.unlink()
            with self.assertRaises(cl.LedgerError):
                cl.build_resumed_ledger_state(
                    summary,
                    live,
                    expected_summary_sha256=summary_hash,
                    expected_live_sha256=live_hash,
                )

    def test_resumed_ledger_initialization_is_idempotent_only_for_exact_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary, live, summary_hash, live_hash = _parent_receipts(root)
            state, _ = cl.build_resumed_ledger_state(
                summary,
                live,
                expected_summary_sha256=summary_hash,
                expected_live_sha256=live_hash,
            )
            ledger_path = root / "budget.json"
            first, first_created = cl.QuotaLedger.initialize_from_state(ledger_path, state)
            second, second_created = cl.QuotaLedger.initialize_from_state(ledger_path, state)
            self.assertTrue(first_created)
            self.assertFalse(second_created)
            self.assertEqual(first.full_state(), state)
            self.assertEqual(second.full_state(), state)

            changed = json.loads(json.dumps(state))
            changed["phases"]["direct"]["small_reserved"] = 0
            with self.assertRaises(cl.LedgerError):
                cl.QuotaLedger.initialize_from_state(ledger_path, changed)

    def test_resumed_ledger_concurrently_admits_only_two_remaining_direct_smalls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary, live, summary_hash, live_hash = _parent_receipts(root)
            state, _ = cl.build_resumed_ledger_state(
                summary,
                live,
                expected_summary_sha256=summary_hash,
                expected_live_sha256=live_hash,
            )
            ledger_path = root / "budget.json"
            cl.QuotaLedger.initialize_from_state(ledger_path, state)
            context = multiprocessing.get_context("fork")
            queue = context.Queue()
            processes = [
                context.Process(target=_reserve_direct_small_worker, args=(str(ledger_path), queue))
                for _ in range(3)
            ]
            for process in processes:
                process.start()
            for process in processes:
                process.join(5)
                self.assertEqual(process.exitcode, 0)
            admitted = [queue.get(timeout=1) for _ in processes]
            self.assertEqual(admitted.count(True), 2)
            ledger = cl.QuotaLedger.open(ledger_path)
            self.assertEqual(ledger.snapshot()["small_reserved"]["direct"], 3)
            with self.assertRaises(cl.QuotaExceeded):
                ledger.reserve("direct", 1)

    def test_resume_rejects_wrong_hash_counter_decrease_and_other_cap_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary, live, summary_hash, live_hash = _parent_receipts(root)
            with self.assertRaises(cl.LedgerError):
                cl.build_resumed_ledger_state(
                    summary,
                    live,
                    expected_summary_sha256="0" * 64,
                    expected_live_sha256=live_hash,
                )

            for mutation in ("counter_decrease", "cap_change"):
                case = root / mutation
                case.mkdir()
                case_summary, case_live, _, _ = _parent_receipts(case)
                live_value = json.loads(case_live.read_text())
                durable = live_value["ledger_summary"]
                if mutation == "counter_decrease":
                    durable["small_reserved"]["direct"] = 0
                    durable["small_remaining"]["direct"] = 2
                else:
                    durable["small_remaining"]["direct"] = 2
                case_live.write_text(json.dumps(live_value, sort_keys=True))
                live_digest = hashlib.sha256(case_live.read_bytes()).hexdigest()
                summary_value = json.loads(case_summary.read_text())
                summary_value["durable_ledger"] = durable
                summary_value["source_report"]["sha256"] = live_digest
                case_summary.write_text(json.dumps(summary_value, sort_keys=True))
                summary_digest = hashlib.sha256(case_summary.read_bytes()).hexdigest()
                with self.subTest(mutation=mutation), self.assertRaises(cl.LedgerError):
                    cl.build_resumed_ledger_state(
                        case_summary,
                        case_live,
                        expected_summary_sha256=summary_digest,
                        expected_live_sha256=live_digest,
                    )


class ConfigTests(unittest.TestCase):
    def test_direct_body_matches_minimal_siwc_probe_schema(self) -> None:
        body = json.loads(cl.build_minimal_siwc_body("gpt-5.6-sol", "synthetic prompt"))
        self.assertEqual(set(body), {"model", "input", "stream", "store"})
        self.assertEqual(body["model"], "gpt-5.6-sol")
        self.assertIs(body["stream"], True)
        self.assertIs(body["store"], False)
        self.assertEqual(body["input"], [{"role": "user", "content": "synthetic prompt"}])

    def test_clone_keeps_pairing_and_denies_unauthorized_ws_bearers(self) -> None:
        run_root = Path("/run/siwc-context-load-task-v1")
        rendered = cl.build_acceptance_config(
            CANONICAL,
            proxy_port=28766,
            gateway_port=42627,
            run_root=run_root,
        )
        parsed = tomllib.loads(rendered.decode())
        provider = parsed["providers"]["models"]["openai"]["siwc"]

        self.assertEqual(provider["uri"], "http://127.0.0.1:28766/phase/native/v1/responses")
        self.assertEqual(provider["model"], "gpt-5.6-sol")
        self.assertEqual(provider["context_window"], 872000)
        self.assertEqual(parsed["runtime_profiles"]["siwc"]["max_context_tokens"], 872000)
        self.assertEqual(parsed["runtime_profiles"]["siwc"]["context_compact_ratio"], 0.9)
        self.assertEqual(parsed["runtime_profiles"]["siwc"]["max_tool_iterations"], 1)
        self.assertEqual(parsed["reliability"]["provider_retries"], 0)
        self.assertTrue(parsed["risk_profiles"]["siwc"]["deny_all_tools"])
        self.assertEqual(parsed["tools"]["optional"], [])
        self.assertEqual(parsed["memory"]["backend"], "none")
        self.assertFalse(parsed["memory"]["auto_save"])
        self.assertFalse(parsed["memory"]["hygiene_enabled"])
        self.assertFalse(parsed["memory"]["response_cache_enabled"])
        self.assertEqual(parsed["agents"]["pi4"]["memory"]["backend"], "none")
        self.assertTrue(parsed["gateway"]["require_pairing"])
        self.assertEqual(parsed["gateway"]["port"], 42627)
        self.assertEqual(provider["api_key"], "synthetic-local-capability")

        bearer = cl.derive_acceptance_bearer("synthetic-local-capability", run_root)
        self.assertTrue(cl.gateway_bearer_authorized(rendered, bearer))
        self.assertFalse(cl.gateway_bearer_authorized(rendered, "unrelated-local-bearer"))
        self.assertFalse(cl.gateway_bearer_authorized(rendered, "synthetic-local-capability"))
        self.assertNotIn(bearer.encode(), rendered)
        self.assertNotEqual(
            parsed["gateway"]["paired_tokens"][0],
            __import__("hashlib").sha256(b"synthetic-local-capability").hexdigest(),
        )

    def test_clone_rejects_source_with_provider_retries_enabled(self) -> None:
        unsafe = CANONICAL.replace(b"provider_retries = 0", b"provider_retries = 1")
        with self.assertRaises(cl.HarnessError):
            cl.build_acceptance_config(
                unsafe,
                proxy_port=28766,
                gateway_port=42627,
                run_root=Path("/run/siwc-context-load-task-v1"),
            )

    def test_private_layout_uses_only_private_modes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "run" / "context-load"
            canonical = Path(directory) / "canonical.toml"
            canonical.write_bytes(CANONICAL)
            os.chmod(canonical, 0o600)

            layout = cl.prepare_private_layout(
                canonical,
                root,
                proxy_port=28766,
                gateway_port=42627,
                require_run_root=False,
            )

            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(layout.config_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(layout.receipt_path.stat().st_mode), 0o600)
            self.assertTrue(layout.data_dir.is_dir())
            self.assertEqual(layout.data_dir, layout.config_dir / "data")
            self.assertTrue((layout.config_dir / "shared").is_dir())
            self.assertTrue((layout.config_dir / "agents" / "pi4" / "workspace").is_dir())
            self.assertEqual(stat.S_IMODE(layout.data_dir.stat().st_mode), 0o700)

    def test_transient_unit_limits_match_production_and_bound_wallclock(self) -> None:
        native = cl.transient_unit_properties("native", wallclock_seconds=900)
        proxy = cl.transient_unit_properties("proxy", wallclock_seconds=900)
        self.assertEqual(native["MemoryMax"], "1G")
        self.assertEqual(native["TasksMax"], "128")
        self.assertEqual(native["LimitNOFILE"], "1024")
        self.assertEqual(proxy["MemoryMax"], "768M")
        self.assertEqual(proxy["TasksMax"], "16")
        self.assertEqual(proxy["LimitNOFILE"], "128")
        self.assertEqual(native["RuntimeMaxSec"], "900s")
        self.assertEqual(proxy["RuntimeMaxSec"], "900s")
        self.assertEqual(native["User"], "zeroclaw-agent")
        self.assertEqual(native["Group"], "zeroclaw-agent")
        self.assertEqual(proxy["User"], "zeroclaw-agent")
        self.assertEqual(proxy["Group"], "zeroclaw-agent")
        self.assertEqual(native["KillMode"], "control-group")
        self.assertEqual(proxy["KillMode"], "control-group")

    def test_native_sequence_performs_authenticated_session_handshake(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            canonical = root / "canonical.toml"
            prompt_path = root / "prompt.txt"
            receipt_path = root / "receipt.json"
            canonical.write_bytes(CANONICAL)
            os.chmod(canonical, 0o600)
            markers = (
                "CTXLOAD_BEGIN_" + "a" * 32,
                "CTXLOAD_MIDDLE_" + "b" * 32,
                "CTXLOAD_END_" + "c" * 32,
            )
            prompt_path.write_text(cl.build_marked_prompt(" the", 100, markers=markers))
            os.chmod(prompt_path, 0o600)
            calls = []

            class Client:
                def __init__(self, *_args):
                    self.replies = [
                        {"type": "session_start", "resumed": False},
                        {"type": "connected"},
                    ]
                    self.connected = False

                def recv_json(self):
                    return self.replies.pop(0)

                def send_json(self, value):
                    self.connected = value.get("type") == "connect"
                    calls.append(value)

                def close(self):
                    calls.append({"type": "closed"})

            def run_message(client, content):
                if not client.connected:
                    raise AssertionError("message sent before connect handshake")
                calls.append({"type": "message", "bytes": len(content.encode())})
                if len([row for row in calls if row["type"] == "message"]) == 1:
                    return [{
                        "type": "done",
                        "full_response": "|".join(markers),
                        "input_tokens": 100,
                        "output_tokens": 3,
                    }]
                return [
                    {"type": "history_trimmed", "dropped_turns": 1, "unsatisfiable_floor": False},
                    {"type": "done", "input_tokens": 120, "output_tokens": 1},
                ]

            fake = types.ModuleType("paired_gateway")
            setattr(fake, "HOST", None)
            setattr(fake, "PORT", None)
            setattr(fake, "WsClient", Client)
            setattr(fake, "run_ws_message", run_message)
            previous = sys.modules.get("paired_gateway")
            sys.modules["paired_gateway"] = fake
            try:
                receipt = cl.run_native_sequence(
                    canonical_path=canonical,
                    run_root=root,
                    prompt_path=prompt_path,
                    gateway_port=42618,
                    receipt_path=receipt_path,
                    budget_tokens=500,
                )
            finally:
                if previous is None:
                    sys.modules.pop("paired_gateway", None)
                else:
                    sys.modules["paired_gateway"] = previous
            self.assertTrue(receipt["passed"])
            self.assertEqual(calls[0]["type"], "connect")
            self.assertEqual(len([row for row in calls if row["type"] == "message"]), 2)


class EvidenceTests(unittest.TestCase):
    def test_marked_prompt_places_unique_nonces_at_beginning_middle_and_end(self) -> None:
        markers = (
            "CTXLOAD_BEGIN_" + "a" * 32,
            "CTXLOAD_MIDDLE_" + "b" * 32,
            "CTXLOAD_END_" + "c" * 32,
        )
        prompt = cl.build_marked_prompt(" the", 100, markers=markers)
        extracted = cl.extract_nonce_markers(prompt.encode())
        self.assertEqual(extracted, markers)
        self.assertLess(prompt.index(markers[0]), len(prompt) // 4)
        self.assertLess(abs(prompt.index(markers[1]) - len(prompt) // 2), 256)
        self.assertGreater(prompt.index(markers[2]), 3 * len(prompt) // 4)

    def test_marked_prompt_writer_returns_only_safe_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "prompt.txt"
            metadata = cl.write_marked_prompt(output, filler_unit=" the", repetitions=100)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertIsNotNone(cl.extract_nonce_markers(output.read_bytes()))
            encoded = json.dumps(metadata, sort_keys=True)
            self.assertEqual(set(metadata), {"prompt_utf8_bytes", "marker_positions_valid"})
            self.assertTrue(metadata["marker_positions_valid"])
            self.assertNotIn("CTXLOAD_", encoded)

    def test_sse_evidence_retains_only_numeric_usage_and_completion_markers(self) -> None:
        collector = cl.SseEvidence()
        collector.feed(
            b'data: {"type":"response.completed","response":{"id":"secret-id",'
            b'"output":[{"text":"secret-output"}],"usage":{"input_tokens":840123,'
            b'"output_tokens":17,"input_tokens_details":{"cached_tokens":11}}}}\n\n'
            b'data: [DONE]\n\n'
        )
        evidence = collector.finish()
        encoded = json.dumps(evidence, sort_keys=True)

        self.assertEqual(evidence["usage"]["input_tokens"], 840123)
        self.assertEqual(evidence["usage"]["output_tokens"], 17)
        self.assertEqual(evidence["usage"]["cached_input_tokens"], 11)
        self.assertEqual(evidence["completion_markers"], ["response.completed", "[DONE]"])
        self.assertNotIn("secret-id", encoded)
        self.assertNotIn("secret-output", encoded)

    def test_acceptance_requires_2xx_completed_no_error_and_numeric_usage(self) -> None:
        good = {
            "completion_markers": ["response.completed"],
            "verified_response_completed": True,
            "saw_error": False,
            "usage": {"input_tokens": 840123, "output_tokens": 17},
        }
        self.assertTrue(cl.accepts_provider_result(200, good))
        self.assertFalse(cl.accepts_provider_result(500, good))
        self.assertFalse(cl.accepts_provider_result(200, good | {"saw_error": True}))
        self.assertFalse(cl.accepts_provider_result(200, good | {"verified_response_completed": False}))
        self.assertFalse(cl.accepts_provider_result(200, good | {"usage": {"input_tokens": 840123}}))

    def test_large_acceptance_requires_exact_three_marker_retrieval(self) -> None:
        markers = (
            "CTXLOAD_BEGIN_" + "a" * 32,
            "CTXLOAD_MIDDLE_" + "b" * 32,
            "CTXLOAD_END_" + "c" * 32,
        )
        collector = cl.SseEvidence(expected_markers=markers)
        answer = "|".join(markers)
        collector.feed(
            ("data: " + json.dumps({"type": "response.output_text.delta", "delta": answer}) + "\n\n").encode()
            + b'data: {"type":"response.completed","response":{"usage":{"input_tokens":770000,"output_tokens":40}}}\n\n'
        )
        evidence = collector.finish()
        self.assertTrue(cl.accepts_provider_result(200, evidence, require_retrieval=True))
        self.assertEqual(
            evidence["retrieval"],
            {"begin": True, "middle": True, "end": True, "exact_compact_answer": True},
        )

        wrong = cl.SseEvidence(expected_markers=markers)
        wrong.feed(
            ("data: " + json.dumps({"type": "response.output_text.delta", "delta": markers[0] + "|wrong|" + markers[2]}) + "\n\n").encode()
            + b'data: {"type":"response.completed","response":{"usage":{"input_tokens":770000,"output_tokens":40}}}\n\n'
        )
        self.assertFalse(cl.accepts_provider_result(200, wrong.finish(), require_retrieval=True))

    def test_gateway_evidence_requires_trim_frame_on_second_turn(self) -> None:
        markers = (
            "CTXLOAD_BEGIN_" + "a" * 32,
            "CTXLOAD_MIDDLE_" + "b" * 32,
            "CTXLOAD_END_" + "c" * 32,
        )
        first = [{"type": "done", "input_tokens": 770111, "output_tokens": 8, "full_response": "|".join(markers)}]
        second = [
            {
                "type": "history_trimmed",
                "dropped_messages": 2,
                "dropped_turns": 1,
                "token_budget": 784800,
                "tokens_before": 790000,
                "tokens_after": 5000,
                "unsatisfiable_floor": False,
                "count_source": "estimated",
            },
            {"type": "done", "input_tokens": 5123, "output_tokens": 7, "full_response": "secret"},
        ]
        receipt = cl.assess_native_sequence(first, second, expected_markers=markers)
        encoded = json.dumps(receipt, sort_keys=True)

        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["first_turn_usage"]["input_tokens"], 770111)
        self.assertEqual(receipt["second_turn_usage"]["input_tokens"], 5123)
        self.assertTrue(receipt["retrieval"]["exact_compact_answer"])
        for marker in markers:
            self.assertNotIn(marker, encoded)

    def test_two_point_calibration_is_explicitly_an_estimate(self) -> None:
        estimate = cl.calibrate_repetitions(
            first_units=1000,
            first_input_tokens=2050,
            second_units=2000,
            second_input_tokens=4050,
            target_input_tokens=770000,
        )
        self.assertEqual(estimate["estimated_units"], 384975)
        self.assertEqual(estimate["label"], "provider-calibrated estimate; final upstream usage is authoritative")

    def test_four_byte_filler_feasibility_prevents_blind_large_spend(self) -> None:
        feasible = cl.assess_filler_feasibility(
            filler_unit=" the",
            first_units=1000,
            first_input_tokens=1050,
            second_units=2000,
            second_input_tokens=2050,
            target_input_tokens=770000,
            budget_tokens=784800,
        )
        self.assertTrue(feasible["feasible"])
        self.assertAlmostEqual(feasible["estimated_utf8_bytes_per_token"], 4.0)
        self.assertLessEqual(feasible["followup_utf8_bytes"], 64 * 1024)

        infeasible = cl.assess_filler_feasibility(
            filler_unit="xx",
            first_units=1000,
            first_input_tokens=1050,
            second_units=2000,
            second_input_tokens=2050,
            target_input_tokens=770000,
            budget_tokens=784800,
        )
        self.assertFalse(infeasible["feasible"])
        self.assertEqual(infeasible["decision"], "do_not_spend_native_large_slot")

    def test_followup_size_uses_zeroclaw_bytes_over_four_trim_floor(self) -> None:
        budget = 784800
        first_user_bytes = 3_000_000
        followup_bytes = cl.minimum_followup_bytes_for_trim(
            first_user_utf8_bytes=first_user_bytes,
            budget_tokens=budget,
        )
        self.assertGreater(
            cl.conservative_two_user_turn_estimate(first_user_bytes, followup_bytes),
            budget,
        )
        self.assertLessEqual(
            cl.conservative_two_user_turn_estimate(first_user_bytes, followup_bytes - 1),
            budget,
        )


class _SseUpstream(http.server.BaseHTTPRequestHandler):
    calls = 0
    seen_authorization: list[str | None] = []
    response_body = (
        b'data: {"type":"response.completed","response":{"id":"must-not-log",'
        b'"output":[{"text":"must-not-log-output"}],"usage":{"input_tokens":123,'
        b'"output_tokens":4}}}\n\ndata: [DONE]\n\n'
    )

    def do_POST(self) -> None:  # noqa: N802
        type(self).calls += 1
        type(self).seen_authorization.append(self.headers.get("Authorization"))
        remaining = int(self.headers["Content-Length"])
        body = bytearray()
        while remaining:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            body.extend(chunk)
            remaining -= len(chunk)
        response_body = self.response_body
        markers = cl.extract_nonce_markers(bytes(body))
        if markers is not None and type(self) is _SseUpstream:
            answer = "|".join(markers)
            response_body = (
                ("data: " + json.dumps({"type": "response.output_text.delta", "delta": answer}) + "\n\n").encode()
                + b'data: {"type":"response.completed","response":{"usage":{"input_tokens":123,"output_tokens":4}}}\n\n'
                + b'data: [DONE]\n\n'
            )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)

    def log_message(self, format: str, *args: object) -> None:
        return


class _DropUpstream(_SseUpstream):
    def do_POST(self) -> None:  # noqa: N802
        type(self).calls += 1
        remaining = int(self.headers["Content-Length"])
        while remaining:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        self.connection.shutdown(2)
        self.connection.close()


class _TruncatedUpstream(_SseUpstream):
    response_body = b'data: {"type":"response.output_text.delta","delta":"partial"}\n\n'


class _ExplicitErrorUpstream(_SseUpstream):
    response_body = b'data: {"type":"error","message":"synthetic upstream failure"}\n\n'


class _DelayedSseUpstream(_SseUpstream):
    first_chunk_sent = threading.Event()
    release_final_chunk = threading.Event()

    def do_POST(self) -> None:  # noqa: N802
        type(self).calls += 1
        remaining = int(self.headers["Content-Length"])
        while remaining:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(b'data: {"type":"response.created"}\n\n')
        self.wfile.flush()
        type(self).first_chunk_sent.set()
        type(self).release_final_chunk.wait(5)
        self.wfile.write(_SseUpstream.response_body)
        self.wfile.flush()


class ProxyTests(unittest.TestCase):
    def setUp(self) -> None:
        _SseUpstream.calls = 0
        _SseUpstream.seen_authorization = []
        _DropUpstream.calls = 0
        _TruncatedUpstream.calls = 0
        _ExplicitErrorUpstream.calls = 0
        _DelayedSseUpstream.calls = 0
        _DelayedSseUpstream.first_chunk_sent.clear()
        _DelayedSseUpstream.release_final_chunk.clear()

    def _start(self, handler: type[http.server.BaseHTTPRequestHandler]):
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        self.addCleanup(upstream.shutdown)
        self.addCleanup(upstream.server_close)

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        receipt = Path(temporary.name) / "receipts.jsonl"
        receipt.touch(mode=0o600)
        quota = cl.QuotaLedger.initialize(
            Path(temporary.name) / "budget.json",
            large_threshold=64,
            small_limits={"native": 1, "direct": 1},
            run_id="task-owned-budget-v1",
        )
        proxy = cl.build_proxy_server(
            bind=("127.0.0.1", 0),
            quota=quota,
            receipt_path=receipt,
            upstream=cl.UpstreamEndpoint("127.0.0.1", upstream.server_port, "/v1/responses"),
            max_request_bytes=1024,
            max_response_bytes=4096,
            timeout_seconds=2,
            expected_capability="synthetic",
        )
        proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        proxy_thread.start()
        self.addCleanup(proxy.shutdown)
        self.addCleanup(proxy.server_close)
        return proxy, receipt, quota

    @staticmethod
    def _post(port: int, phase: str, size: int, *, marked: bool = False) -> tuple[int, bytes]:
        body = b"x" * size
        if marked:
            prompt = cl.build_marked_prompt(" the", max(size, 64))
            body = json.dumps({"input": prompt}, separators=(",", ":")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            connection.request(
                "POST",
                f"/phase/{phase}/v1/responses",
                body=body,
                headers={"Content-Type": "application/json", "Authorization": "Bearer synthetic"},
            )
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_proxy_enforces_immutable_phase_slots_and_logs_only_safe_evidence(self) -> None:
        proxy, receipt, quota = self._start(_SseUpstream)

        self.assertEqual(self._post(proxy.server_port, "native", 64, marked=True)[0], 200)
        self.assertEqual(self._post(proxy.server_port, "native", 64, marked=True)[0], 429)
        self.assertEqual(self._post(proxy.server_port, "direct", 64, marked=True)[0], 200)
        self.assertEqual(_SseUpstream.calls, 2)
        self.assertEqual(_SseUpstream.seen_authorization, ["Bearer synthetic", "Bearer synthetic"])
        self.assertEqual(quota.snapshot()["large_forwarded_total"], 2)

        log_text = receipt.read_text()
        records = [json.loads(line) for line in log_text.splitlines()]
        self.assertEqual(records[-1]["evidence"]["usage"]["input_tokens"], 123)
        self.assertTrue(records[-1]["evidence"]["retrieval"]["exact_compact_answer"])
        self.assertNotIn("must-not-log", log_text)
        self.assertNotIn("synthetic", log_text)
        self.assertNotIn("Authorization", log_text)
        self.assertNotIn("CTXLOAD_", log_text)

    def test_unauthorized_request_cannot_spend_quota(self) -> None:
        proxy, _receipt, quota = self._start(_SseUpstream)
        connection = http.client.HTTPConnection("127.0.0.1", proxy.server_port, timeout=3)
        try:
            connection.request(
                "POST",
                "/phase/native/v1/responses",
                body=b"x" * 64,
                headers={"Content-Type": "application/json", "Authorization": "Bearer wrong"},
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
        finally:
            connection.close()
        self.assertEqual(_SseUpstream.calls, 0)
        self.assertEqual(quota.snapshot()["large_forwarded_total"], 0)
        self.assertEqual(quota.snapshot()["large_remaining"], {"native": 1, "direct": 1})

    def test_truncated_or_explicit_error_sse_is_not_accepted(self) -> None:
        for handler in (_TruncatedUpstream, _ExplicitErrorUpstream):
            with self.subTest(handler=handler.__name__):
                proxy, receipt, _quota = self._start(handler)
                status, body = self._post(proxy.server_port, "native", 1)
                self.assertEqual(status, 200)
                self.assertIn(b'"type":"error"', body)
                record = json.loads(receipt.read_text().splitlines()[-1])
                self.assertEqual(record["outcome"], "ambiguous_failure")
                self.assertFalse(record["accepted"])
                self.assertFalse(cl.accepts_provider_result(status, record["evidence"]))

    def test_proxy_flushes_sse_before_upstream_eof(self) -> None:
        proxy, _receipt, _quota = self._start(_DelayedSseUpstream)
        connection = http.client.HTTPConnection("127.0.0.1", proxy.server_port, timeout=2)
        try:
            connection.request(
                "POST",
                "/phase/native/v1/responses",
                body=b"x",
                headers={"Content-Type": "application/json", "Authorization": "Bearer synthetic"},
            )
            response = connection.getresponse()
            self.assertTrue(_DelayedSseUpstream.first_chunk_sent.wait(1))
            first = response.read1(4096)
            self.assertIn(b"response.created", first)
        finally:
            _DelayedSseUpstream.release_final_chunk.set()
            connection.close()

    def test_ambiguous_upstream_failure_consumes_large_slot(self) -> None:
        proxy, _receipt, quota = self._start(_DropUpstream)

        self.assertEqual(self._post(proxy.server_port, "native", 64, marked=True)[0], 502)
        self.assertEqual(self._post(proxy.server_port, "native", 64, marked=True)[0], 429)
        self.assertEqual(_DropUpstream.calls, 1)
        self.assertEqual(quota.snapshot()["large_remaining"]["native"], 0)

    def test_proxy_rejects_oversize_and_non_phase_paths_before_upstream(self) -> None:
        proxy, _receipt, _quota = self._start(_SseUpstream)

        self.assertEqual(self._post(proxy.server_port, "native", 1025)[0], 413)
        connection = http.client.HTTPConnection("127.0.0.1", proxy.server_port, timeout=3)
        try:
            connection.request("POST", "/v1/responses", body=b"x", headers={"Content-Length": "1"})
            self.assertEqual(connection.getresponse().status, 404)
        finally:
            connection.close()
        self.assertEqual(_SseUpstream.calls, 0)


if __name__ == "__main__":
    unittest.main()
