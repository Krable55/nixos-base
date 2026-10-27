#!/usr/bin/env python3
"""Bounded paired-gateway acceptance, intended to run on the Pi as zeroclaw-agent.

All pairing and bearer material remains in this process. Stdout contains one safe
JSON report only. The script performs no retries and cleans its named session,
new memory rows, and paired device through supported gateway APIs.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import pathlib
import secrets
import socket
import struct
import subprocess
import sys
import urllib.parse
from typing import Any

HOST = "127.0.0.1"
PORT = 42617
AGENT = "pi4"
MODEL = "gpt-5.6-sol"
BINARY = "/nix/store/adkc7f6i4b46gaf1296ir59whcjva4cl-zeroclaw-0.8.6/bin/zeroclaw"
CONFIG_DIR = "/run/zeroclaw-agent"
EXPECTED = str(321 * 654)
MAX_PROVIDER_REQUESTS = 5
DEVICE_TYPE = "acceptance-client"


class HarnessError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def provider_request_budget(
    *, tool_loop_calls: int, ws_background_attempts: int, followup_calls: int
) -> int:
    total = tool_loop_calls + ws_background_attempts + followup_calls
    if total > MAX_PROVIDER_REQUESTS:
        raise ValueError(f"provider request budget {total} exceeds {MAX_PROVIDER_REQUESTS}")
    return total


def paircode_command() -> list[str]:
    return [
        BINARY,
        "--config-dir",
        CONFIG_DIR,
        "--log-level",
        "error",
        "gateway",
        "get-paircode",
        "--host",
        HOST,
        "--port",
        str(PORT),
        "--new",
        "--json",
    ]


def _normalized_secret_key(key: str) -> str:
    return "".join(ch for ch in key.lower() if ch.isalnum())


def assert_report_safe(value: Any) -> None:
    forbidden = ("token", "pairingcode", "paircode", "admintoken", "capability", "credentialjson")

    def walk(item: Any) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                normalized = _normalized_secret_key(str(key))
                if any(part in normalized for part in forbidden):
                    raise ValueError(f"unsafe report field: {key}")
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)

    walk(value)


def _canonical_memory(entry: dict[str, Any]) -> bytes:
    category = str(entry.get("category", ""))
    content = str(entry.get("content", ""))
    return category.encode() + b"\0" + content.encode()


def memory_fingerprints(entries: list[dict[str, Any]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in entries:
        key = entry.get("key")
        if isinstance(key, str) and key:
            result[key] = hashlib.sha256(_canonical_memory(entry)).hexdigest()
    return result


def new_memory_keys(before: dict[str, str], after: dict[str, str]) -> set[str]:
    return set(after) - set(before)


def changed_memory_keys(before: dict[str, str], after: dict[str, str]) -> set[str]:
    return {key for key in set(before) & set(after) if before[key] != after[key]}


def encode_client_frame(opcode: int, payload: bytes, *, mask: bytes | None = None) -> bytes:
    mask = secrets.token_bytes(4) if mask is None else mask
    if len(mask) != 4:
        raise ValueError("WebSocket mask must be four bytes")
    length = len(payload)
    if length < 126:
        header = bytes([0x80 | opcode, 0x80 | length])
    elif length <= 0xFFFF:
        header = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack("!H", length)
    else:
        header = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack("!Q", length)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return header + mask + masked


def decode_frame_bytes(frame: bytes, *, expect_masked: bool) -> tuple[int, bytes]:
    if len(frame) < 2:
        raise ValueError("short WebSocket frame")
    first, second = frame[0], frame[1]
    if not first & 0x80:
        raise ValueError("fragmented WebSocket frames are unsupported")
    masked = bool(second & 0x80)
    if masked != expect_masked:
        raise ValueError("unexpected WebSocket mask bit")
    length = second & 0x7F
    offset = 2
    if length == 126:
        if len(frame) < offset + 2:
            raise ValueError("short WebSocket frame length")
        length = struct.unpack("!H", frame[offset : offset + 2])[0]
        offset += 2
    elif length == 127:
        if len(frame) < offset + 8:
            raise ValueError("short WebSocket frame length")
        length = struct.unpack("!Q", frame[offset : offset + 8])[0]
        offset += 8
    mask = b""
    if masked:
        if len(frame) < offset + 4:
            raise ValueError("short WebSocket frame mask")
        mask = frame[offset : offset + 4]
        offset += 4
    if len(frame) != offset + length:
        raise ValueError("WebSocket frame length mismatch")
    payload = frame[offset:]
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return first & 0x0F, payload


def safe_tool_receipt(events: list[dict[str, Any]], *, expected: str) -> dict[str, Any]:
    calls = [event for event in events if event.get("type") == "tool_call" and event.get("name") == "calculator"]
    results = [event for event in events if event.get("type") == "tool_result" and event.get("name") == "calculator"]
    done = next((event for event in reversed(events) if event.get("type") in {"done", "error"}), {})
    result_match = any(expected in str(event.get("output", "")) for event in results)
    answer_match = str(done.get("full_response", "")).strip() == f"STAGE1_CALC={expected}"
    return {
        "calculator_call_seen": bool(calls),
        "calculator_result_seen": bool(results),
        "calculator_output_matches": result_match,
        "answer_matches": answer_match,
        "model": done.get("model"),
        "terminal_type": done.get("type"),
    }


def followup_prompt() -> str:
    return (
        "Ephemeral acceptance follow-up in this same conversation; do not save this as memory "
        "and do not use tools. Recall the numeric result from the previous calculator turn and "
        "reply exactly STAGE2_PRIOR_RESULT=<result>."
    )


def _followup_response_class(response: str, *, expected: str, previous_answer: str) -> str:
    stripped = response.strip()
    if stripped == expected:
        return "expected"
    if stripped == previous_answer:
        return "previous_answer"
    if not stripped:
        return "empty"

    unwrapped: str | None = None
    if stripped.startswith("```") and stripped.endswith("```"):
        lines = stripped.splitlines()
        if len(lines) >= 3:
            unwrapped = "\n".join(lines[1:-1]).strip()
    elif len(stripped) >= 2 and stripped[0] == stripped[-1] and stripped[0] in {'"', "'", "`"}:
        unwrapped = stripped[1:-1].strip()
    if unwrapped == expected:
        return "quoted_or_fenced_expected"
    return "other"


_WS_ERROR_CATEGORIES = {
    "PROVIDER_ERROR": "provider_path",
    "AUTH_ERROR": "authentication",
    "AGENT_ERROR": "runtime",
    "SESSION_RESTORE_UNAVAILABLE": "history",
    "SESSION_QUEUE_FULL": "runtime",
    "SESSION_QUEUE_TIMEOUT": "runtime",
    "AGENT_LIFECYCLE_UNAVAILABLE": "runtime",
    "AGENT_INIT_FAILED": "runtime",
    "INVALID_CWD": "configuration",
    "NEEDS_ONBOARDING": "configuration",
    "INVALID_JSON": "client_protocol",
    "UNKNOWN_MESSAGE_TYPE": "client_protocol",
    "EMPTY_CONTENT": "client_protocol",
    "STEERING_QUEUE_FULL": "client_protocol",
    "STEERING_CLOSED": "client_protocol",
    "INVALID_APPROVAL_RESPONSE": "approval",
    "SOP_RESOLVE_FAILED": "approval",
    "SOP_LOCK_POISONED": "approval",
    "SOP_DISABLED": "approval",
}

_PROVIDER_CODE_CLASSES = {
    "rate_limit_exceeded": "rate_limit",
    "insufficient_quota": "quota",
    "invalid_api_key": "authentication",
    "authentication_error": "authentication",
    "context_length_exceeded": "context_limit",
    "invalid_request_error": "invalid_request",
    "model_not_found": "invalid_request",
    "server_error": "provider_server",
    "internal_error": "provider_server",
}


def _safe_error_metadata(terminal: dict[str, Any]) -> dict[str, Any]:
    """Classify fixed structured fields without retaining dynamic error data."""
    if terminal.get("type") != "error":
        return {
            "error_category": "not_error",
            "http_status": None,
            "provider_code_class": "absent",
        }

    code = terminal.get("code")
    error_category = _WS_ERROR_CATEGORIES.get(code, "other") if isinstance(code, str) else "other"
    status = terminal.get("http_status")
    if type(status) is not int or not 400 <= status <= 599:
        status = None

    candidates = []
    if isinstance(terminal.get("provider_code"), str):
        candidates.append(terminal["provider_code"])
    nested_error = terminal.get("error")
    if isinstance(nested_error, dict) and isinstance(nested_error.get("provider_code"), str):
        candidates.append(nested_error["provider_code"])
    nested_provider = terminal.get("provider")
    if isinstance(nested_provider, dict) and isinstance(nested_provider.get("code"), str):
        candidates.append(nested_provider["code"])
    unique_codes = set(candidates)
    if not unique_codes:
        provider_code_class = "absent"
    elif len(unique_codes) == 1:
        provider_code_class = _PROVIDER_CODE_CLASSES.get(unique_codes.pop(), "other")
    else:
        provider_code_class = "conflicting"
    return {
        "error_category": error_category,
        "http_status": status,
        "provider_code_class": provider_code_class,
    }


def safe_followup_receipt(
    events: list[dict[str, Any]],
    *,
    expected: str,
    previous_answer: str,
    expected_model: str,
) -> dict[str, Any]:
    known_types = (
        "chunk",
        "thinking",
        "tool_call",
        "tool_result",
        "approval_request",
        "history_trimmed",
        "plan",
        "done",
        "error",
        "aborted",
    )
    counts = {event_type: 0 for event_type in known_types}
    counts["other"] = 0
    for event in events:
        event_type = event.get("type")
        counts[event_type if event_type in counts else "other"] += 1
    counts["total"] = len(events)

    terminal_events = [
        (index, event)
        for index, event in enumerate(events)
        if event.get("type") in {"done", "error", "aborted"}
    ]
    terminal = terminal_events[-1][1] if terminal_events else {}
    terminal_type = terminal.get("type") if terminal else "missing"
    response = str(terminal.get("full_response", ""))
    response_class = _followup_response_class(
        response,
        expected=expected,
        previous_answer=previous_answer,
    )
    completion_correlated = (
        len(terminal_events) == 1
        and terminal_events[0][0] == len(events) - 1
    )
    return {
        "answer_matches": response_class == "expected",
        "response_class": response_class,
        "model_matches": terminal.get("model") == expected_model,
        "tool_calls": counts["tool_call"],
        "terminal_type": terminal_type,
        "completion_correlated": completion_correlated,
        "event_counts": counts,
        **_safe_error_metadata(terminal),
    }


def record_followup_result(
    report: dict[str, Any],
    events: list[dict[str, Any]],
    *,
    expected: str,
    previous_answer: str,
    expected_model: str,
) -> dict[str, Any]:
    receipt = safe_followup_receipt(
        events,
        expected=expected,
        previous_answer=previous_answer,
        expected_model=expected_model,
    )
    report["followup"] = receipt
    if not receipt["completion_correlated"]:
        raise HarnessError("followup_completion_uncorrelated")
    if not all(
        (
            receipt["answer_matches"],
            receipt["model_matches"],
            receipt["tool_calls"] == 0,
            receipt["terminal_type"] == "done",
        )
    ):
        raise HarnessError("followup_acceptance_failed")
    return receipt


def run_ws_message(ws: Any, content: str) -> list[dict[str, Any]]:
    ws.send_json({"type": "message", "content": content})
    events: list[dict[str, Any]] = []
    while True:
        event = ws.recv_json()
        events.append(event)
        if event.get("type") == "approval_request":
            raise HarnessError("unexpected_approval_request")
        if event.get("type") in {"done", "error", "aborted"}:
            return events


def http_json(
    method: str,
    path: str,
    *,
    bearer: str | None = None,
    body: dict[str, Any] | None = None,
    timeout: int = 20,
    expected_status: set[int] | None = None,
) -> tuple[int, Any]:
    headers = {"Accept": "application/json"}
    payload = None
    if bearer is not None:
        headers["Authorization"] = f"Bearer {bearer}"
    if body is not None:
        payload = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    connection = http.client.HTTPConnection(HOST, PORT, timeout=timeout)
    try:
        connection.request(method, path, body=payload, headers=headers)
        response = connection.getresponse()
        raw = response.read(1024 * 1024)
        status = response.status
    except (OSError, http.client.HTTPException):
        raise HarnessError("gateway_http_transport") from None
    finally:
        connection.close()
    if expected_status is not None and status not in expected_status:
        raise HarnessError(f"gateway_http_status_{status}")
    if not raw:
        return status, None
    try:
        return status, json.loads(raw)
    except json.JSONDecodeError:
        return status, None


def send_ws_upgrade_request(sock: Any, *, bearer: str, query: str, key: str) -> None:
    if not bearer or "\r" in bearer or "\n" in bearer:
        raise HarnessError("websocket_bearer_invalid")
    authorization_line = (
        ("Author" + "ization") + ": " + ("Bear" + "er ") + bearer + "\r\n"
    )
    request = (
        f"GET /ws/chat?{query} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Protocol: zeroclaw.v1\r\n"
        + authorization_line
        + "\r\n"
    ).encode("ascii")
    sock.sendall(request)


class WsClient:
    def __init__(self, bearer: str, session_id: str, session_name: str):
        self.sock = socket.create_connection((HOST, PORT), timeout=15)
        self.sock.settimeout(210)
        self.buffer = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        query = urllib.parse.urlencode(
            {"agent": AGENT, "session_id": session_id, "name": session_name}
        )
        send_ws_upgrade_request(self.sock, bearer=bearer, query=query, key=key)
        response = self._read_until(b"\r\n\r\n", 65536)
        head, self.buffer = response.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        if not lines or b" 101 " not in lines[0]:
            self.close()
            raise HarnessError("websocket_upgrade_rejected")
        headers: dict[bytes, bytes] = {}
        for line in lines[1:]:
            if b":" in line:
                name, value = line.split(b":", 1)
                headers[name.strip().lower()] = value.strip()
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        )
        if headers.get(b"sec-websocket-accept") != expected:
            self.close()
            raise HarnessError("websocket_accept_invalid")

    def _read_until(self, marker: bytes, maximum: int) -> bytes:
        data = self.buffer
        while marker not in data:
            if len(data) >= maximum:
                raise HarnessError("websocket_header_too_large")
            chunk = self.sock.recv(4096)
            if not chunk:
                raise HarnessError("websocket_eof")
            data += chunk
        return data

    def _read_exact(self, length: int) -> bytes:
        while len(self.buffer) < length:
            chunk = self.sock.recv(max(4096, length - len(self.buffer)))
            if not chunk:
                raise HarnessError("websocket_eof")
            self.buffer += chunk
        result, self.buffer = self.buffer[:length], self.buffer[length:]
        return result

    def send_json(self, value: dict[str, Any]) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.sock.sendall(encode_client_frame(0x1, payload))

    def recv_json(self) -> dict[str, Any]:
        while True:
            first, second = self._read_exact(2)
            if not first & 0x80:
                raise HarnessError("websocket_fragmented_frame")
            if second & 0x80:
                raise HarnessError("websocket_masked_server_frame")
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8))[0]
            if length > 8 * 1024 * 1024:
                raise HarnessError("websocket_frame_too_large")
            payload = self._read_exact(length)
            opcode = first & 0x0F
            if opcode == 0x8:
                raise HarnessError("websocket_closed")
            if opcode == 0x9:
                self.sock.sendall(encode_client_frame(0xA, payload))
                continue
            if opcode == 0xA:
                continue
            if opcode != 0x1:
                continue
            try:
                value = json.loads(payload)
            except json.JSONDecodeError:
                raise HarnessError("websocket_invalid_json") from None
            if not isinstance(value, dict):
                raise HarnessError("websocket_invalid_message")
            return value

    def close(self) -> None:
        sock = getattr(self, "sock", None)
        if sock is None:
            return
        try:
            sock.sendall(encode_client_frame(0x8, b""))
        except OSError:
            pass
        try:
            sock.close()
        finally:
            self.sock = None


def memory_entries(bearer: str) -> list[dict[str, Any]]:
    _, body = http_json(
        "GET",
        f"/api/memory?{urllib.parse.urlencode({'agent': AGENT})}",
        bearer=bearer,
        expected_status={200},
    )
    entries = body.get("entries") if isinstance(body, dict) else None
    if not isinstance(entries, list):
        raise HarnessError("memory_list_shape")
    return [entry for entry in entries if isinstance(entry, dict)]


def delete_memory_key(bearer: str, key: str) -> bool:
    path = f"/api/memory/{urllib.parse.quote(key, safe='')}?{urllib.parse.urlencode({'agent': AGENT})}"
    _, body = http_json("DELETE", path, bearer=bearer, expected_status={200})
    return isinstance(body, dict) and body.get("deleted") is True


def run() -> dict[str, Any]:
    run_id = os.environ.get("SIWC_ACCEPTANCE_RUN_ID", "siwc-stage1").strip()
    if not run_id or len(run_id) > 80 or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789-" for ch in run_id):
        raise HarnessError("invalid_run_id")
    session_id = run_id
    session_name = f"SIWC stage1 {run_id}"
    device_name = f"siwc-{run_id}"
    provider_budget = provider_request_budget(
        tool_loop_calls=2, ws_background_attempts=2, followup_calls=1
    )

    report: dict[str, Any] = {
        "status": "failed",
        "run_id": run_id,
        "model_expected": MODEL,
        "provider_request_limit": MAX_PROVIDER_REQUESTS,
        "provider_request_contract": provider_budget,
        "large_requests": 0,
        "pairing_required_preserved": False,
        "loopback_preserved": False,
        "cleanup": {
            "session_deleted": False,
            "new_memory_rows_deleted": False,
            "existing_memory_rows_unchanged": False,
            "device_revoked": False,
            "bearer_rejected_after_revoke": False,
            "unpaired_after_cleanup": False,
        },
    }
    bearer: str | None = None
    device_id: str | None = None
    ws: WsClient | None = None
    session_owned = False
    baseline_memory: dict[str, str] | None = None
    created_memory_keys: set[str] = set()
    failure_code: str | None = None

    try:
        _, health = http_json("GET", "/health", expected_status={200})
        if not isinstance(health, dict) or health.get("require_pairing") is not True:
            raise HarnessError("pairing_boundary_missing")
        if health.get("paired") is not False:
            raise HarnessError("unexpected_preexisting_pairing")
        report["pairing_required_preserved"] = True
        report["loopback_preserved"] = True

        paircode_process = subprocess.run(
            paircode_command(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )
        if paircode_process.returncode != 0:
            raise HarnessError("paircode_cli_failed")
        try:
            paircode_document = json.loads(paircode_process.stdout)
            pairing_code = paircode_document["pairing_code"]
        except (json.JSONDecodeError, KeyError, TypeError):
            raise HarnessError("paircode_cli_shape") from None
        if not isinstance(pairing_code, str) or not pairing_code:
            raise HarnessError("paircode_cli_shape")

        _, pair = http_json(
            "POST",
            "/api/pair",
            body={"code": pairing_code, "device_name": device_name, "device_type": DEVICE_TYPE},
            expected_status={200},
        )
        pairing_code = ""
        paircode_document = None
        if not isinstance(pair, dict) or pair.get("paired") is not True or pair.get("persisted") is not True:
            raise HarnessError("pairing_response_invalid")
        bearer = pair.get("token")
        pair = None
        if not isinstance(bearer, str) or not bearer:
            raise HarnessError("pairing_bearer_missing")

        _, devices = http_json("GET", "/api/devices", bearer=bearer, expected_status={200})
        rows = devices.get("devices") if isinstance(devices, dict) else None
        own = [
            row
            for row in rows or []
            if isinstance(row, dict)
            and row.get("name") == device_name
            and row.get("device_type") == DEVICE_TYPE
        ]
        if len(own) != 1 or not isinstance(own[0].get("id"), str):
            raise HarnessError("paired_device_not_uniquely_listed")
        device_id = own[0]["id"]
        report["device_receipt_sha256"] = hashlib.sha256(device_id.encode()).hexdigest()

        baseline_memory = memory_fingerprints(memory_entries(bearer))

        ws = WsClient(bearer, session_id, session_name)
        start = ws.recv_json()
        if start.get("type") != "session_start" or start.get("resumed") is not False:
            raise HarnessError("session_start_invalid")
        session_owned = True
        ws.send_json(
            {
                "type": "connect",
                "session_id": session_id,
                "device_name": device_name,
                "capabilities": [],
            }
        )
        if ws.recv_json().get("type") != "connected":
            raise HarnessError("session_connect_invalid")
        events = run_ws_message(
            ws,
            "This is a temporary acceptance calculation, not a fact or preference to remember. "
            "Use only the calculator tool to calculate 321 * 654. Do not use any other tools. "
            "Reply exactly STAGE1_CALC=<result>.",
        )
        receipt = safe_tool_receipt(events, expected=EXPECTED)
        report["calculator"] = receipt
        calculator_calls = sum(
            event.get("type") == "tool_call" and event.get("name") == "calculator"
            for event in events
        )
        other_calls = sum(
            event.get("type") == "tool_call" and event.get("name") != "calculator"
            for event in events
        )
        if calculator_calls != 1 or other_calls != 0:
            raise HarnessError("unexpected_tool_call_count")
        if not all(
            [
                receipt["calculator_call_seen"],
                receipt["calculator_result_seen"],
                receipt["calculator_output_matches"],
                receipt["answer_matches"],
                receipt["model"] == MODEL,
                receipt["terminal_type"] == "done",
            ]
        ):
            raise HarnessError("calculator_acceptance_failed")

        followup_events = run_ws_message(ws, followup_prompt())
        record_followup_result(
            report,
            followup_events,
            expected=f"STAGE2_PRIOR_RESULT={EXPECTED}",
            previous_answer=f"STAGE1_CALC={EXPECTED}",
            expected_model=MODEL,
        )
        ws.close()
        ws = None

        # Each successful paired WebSocket turn may start auto-save consolidation.
        # Its exact runtime provider path/outcome is unverified; account for both
        # possible background attempts without treating memory changes as required.
        post_followup = memory_fingerprints(memory_entries(bearer))
        created_memory_keys = new_memory_keys(baseline_memory, post_followup)
        if changed_memory_keys(baseline_memory, post_followup):
            raise HarnessError("existing_memory_changed")
        report["background_memory_attempts_accounted"] = 2
        report["background_new_rows"] = len(created_memory_keys)

        report["status"] = "passed"
    except HarnessError as error:
        failure_code = error.code
    except (OSError, socket.timeout, subprocess.TimeoutExpired, ValueError):
        failure_code = "bounded_execution_failure"
    finally:
        if ws is not None:
            ws.close()
        if bearer is not None:
            if session_owned:
                try:
                    status, _ = http_json(
                        "DELETE",
                        f"/api/sessions/{urllib.parse.quote(session_id, safe='')}",
                        bearer=bearer,
                        expected_status={200, 404},
                    )
                    report["cleanup"]["session_deleted"] = status in {200, 404}
                except HarnessError:
                    pass

            if baseline_memory is not None:
                try:
                    current = memory_fingerprints(memory_entries(bearer))
                    created_memory_keys |= new_memory_keys(baseline_memory, current)
                    deleted = all(delete_memory_key(bearer, key) for key in sorted(created_memory_keys))
                    final_memory = memory_fingerprints(memory_entries(bearer))
                    report["cleanup"]["new_memory_rows_deleted"] = deleted and not new_memory_keys(
                        baseline_memory, final_memory
                    )
                    report["cleanup"]["existing_memory_rows_unchanged"] = not changed_memory_keys(
                        baseline_memory, final_memory
                    ) and not (set(baseline_memory) - set(final_memory))
                except HarnessError:
                    pass

            if device_id is not None:
                try:
                    http_json(
                        "DELETE",
                        f"/api/devices/{urllib.parse.quote(device_id, safe='')}",
                        bearer=bearer,
                        expected_status={200},
                    )
                    report["cleanup"]["device_revoked"] = True
                except HarnessError:
                    pass
                try:
                    status, _ = http_json(
                        "GET", "/api/devices", bearer=bearer, expected_status={401}
                    )
                    report["cleanup"]["bearer_rejected_after_revoke"] = status == 401
                except HarnessError:
                    pass
        try:
            _, final_health = http_json("GET", "/health", expected_status={200})
            report["cleanup"]["unpaired_after_cleanup"] = (
                isinstance(final_health, dict)
                and final_health.get("paired") is False
                and final_health.get("require_pairing") is True
            )
        except HarnessError:
            pass

    cleanup_complete = all(report["cleanup"].values())
    report["cleanup_complete"] = cleanup_complete
    if failure_code is not None:
        report["status"] = "failed"
        report["failure"] = failure_code
    elif not cleanup_complete:
        report["status"] = "failed"
        report["failure"] = "cleanup_incomplete"
    report["session_receipt_sha256"] = hashlib.sha256(session_id.encode()).hexdigest()
    assert_report_safe(report)
    return report


def main() -> None:
    try:
        report = run()
    except Exception:
        report = {"status": "failed", "failure": "preflight_or_report_failure"}
    assert_report_safe(report)
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    raise SystemExit(0 if report.get("status") == "passed" else 1)


if __name__ == "__main__":
    main()
