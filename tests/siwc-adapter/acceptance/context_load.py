#!/usr/bin/env python3
"""Bounded local harness for later SIWC context acceptance.

This module performs no network activity unless an explicit live subcommand is
invoked. The quota ledger contains counts only. Request/response bodies,
capabilities, and OAuth material are never written to evidence.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from fractions import Fraction
import fcntl
import hashlib
import hmac
import http.client
import http.server
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import sys
import tempfile
import threading
import time
import tomllib
from typing import Any, BinaryIO, Mapping

LARGE_THRESHOLD = 128 * 1024
MAX_REQUEST_BYTES = 32 * 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_SSE_EVENT_BYTES = 4 * 1024 * 1024
CANONICAL_MAX_BYTES = 2 * 1024 * 1024
PRODUCTION_ADAPTER = ("127.0.0.1", 18766, "/v1/responses")
PHASES = ("native", "direct")
LEDGER_SCHEMA = 1
DEFAULT_RUN_ID = "siwc-context-load-user-task-v1"
DEFAULT_SMALL_LIMITS = {"native": 2, "direct": 2}
PRODUCTION_PROVIDER_URI = "http://127.0.0.1:18766/v1/responses"
FOLLOWUP_CONTENT_MAX = 64 * 1024
ACCEPTANCE_BEARER_PURPOSE = b"siwc-context-load-gateway-v1"
RESUME_PARENT_SUMMARY_SHA256 = "d6df7f8099f193e29e969ac3f73c9e1de0d7f3a5f92c1a73be091b595a26b30e"
RESUME_PARENT_LIVE_SHA256 = "d2508477651d6d797fe626ed261c1400730ea90a86e203933e1616338b8347dd"
RESUME_PARENT_AUTHORIZATION = (
    "Astra approved one explicit direct-small limit migration from 2 to 3 while carrying "
    "all spent counters forward; native small and both large limits remain unchanged."
)
GENERIC_SSE_ERROR = (
    b'data: {"type":"error","message":"Upstream did not confirm a completed response."}\n\n'
)
MARKER_PATTERNS = (
    re.compile(rb"CTXLOAD_BEGIN_[0-9a-f]{32}"),
    re.compile(rb"CTXLOAD_MIDDLE_[0-9a-f]{32}"),
    re.compile(rb"CTXLOAD_END_[0-9a-f]{32}"),
)


class HarnessError(RuntimeError):
    pass


class LedgerError(HarnessError):
    pass


class QuotaExceeded(HarnessError):
    pass


@dataclass(frozen=True)
class UpstreamEndpoint:
    host: str
    port: int
    path: str


@dataclass(frozen=True)
class Layout:
    root: Path
    config_dir: Path
    config_path: Path
    data_dir: Path
    receipt_path: Path
    ledger_path: Path


@dataclass
class Reservation:
    phase: str
    size_class: str
    request_bytes: int
    outcome: str = "reserved"

    def mark_completed(self) -> None:
        self.outcome = "completed"

    def mark_ambiguous_failure(self) -> None:
        self.outcome = "ambiguous_failure"


def build_marked_prompt(
    filler_unit: str,
    repetitions: int,
    *,
    markers: tuple[str, str, str] | None = None,
) -> str:
    if not filler_unit or repetitions < 0:
        raise HarnessError("marked prompt inputs invalid")
    if markers is None:
        markers = (
            "CTXLOAD_BEGIN_" + secrets.token_hex(16),
            "CTXLOAD_MIDDLE_" + secrets.token_hex(16),
            "CTXLOAD_END_" + secrets.token_hex(16),
        )
    try:
        encoded_markers = tuple(marker.encode("ascii", "strict") for marker in markers)
    except (UnicodeEncodeError, AttributeError) as error:
        raise HarnessError("nonce marker format invalid") from error
    if len(markers) != 3 or any(
        pattern.fullmatch(value) is None
        for pattern, value in zip(MARKER_PATTERNS, encoded_markers)
    ):
        raise HarnessError("nonce marker format invalid")
    first_half = repetitions // 2
    second_half = repetitions - first_half
    return (
        "Return exactly the three values labeled BEGIN_MARKER, MIDDLE_MARKER, and END_MARKER "
        "in that order separated by |, with no other text.\n"
        f"BEGIN_MARKER:{markers[0]}\n"
        + filler_unit * first_half
        + f"\nMIDDLE_MARKER:{markers[1]}\n"
        + filler_unit * second_half
        + f"\nEND_MARKER:{markers[2]}\n"
    )


def build_minimal_siwc_body(model: str, prompt: str) -> bytes:
    if not isinstance(model, str) or not model or not isinstance(prompt, str):
        raise HarnessError("minimal SIWC body inputs invalid")
    return json.dumps(
        {
            "model": model,
            "input": [{"role": "user", "content": prompt}],
            "stream": True,
            "store": False,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def extract_nonce_markers(data: bytes) -> tuple[str, str, str] | None:
    found: list[str] = []
    positions: list[int] = []
    for pattern in MARKER_PATTERNS:
        matches = list(pattern.finditer(data))
        if len(matches) != 1:
            return None
        found.append(matches[0].group().decode("ascii"))
        positions.append(matches[0].start())
    if positions != sorted(positions):
        return None
    return found[0], found[1], found[2]


def write_marked_prompt(
    output: Path,
    *,
    filler_unit: str,
    repetitions: int,
) -> dict[str, Any]:
    encoded = build_marked_prompt(filler_unit, repetitions).encode("utf-8")
    if extract_nonce_markers(encoded) is None:
        raise HarnessError("generated prompt marker preflight failed")
    _atomic_private_write(output, encoded)
    return {
        "prompt_utf8_bytes": len(encoded),
        "marker_positions_valid": True,
    }


def _retrieval_result(answer: str, markers: tuple[str, str, str]) -> dict[str, bool]:
    parts = answer.strip().split("|")
    begin = len(parts) == 3 and hmac.compare_digest(parts[0], markers[0])
    middle = len(parts) == 3 and hmac.compare_digest(parts[1], markers[1])
    end = len(parts) == 3 and hmac.compare_digest(parts[2], markers[2])
    return {
        "begin": begin,
        "middle": middle,
        "end": end,
        "exact_compact_answer": begin and middle and end,
    }


def _require_private_regular(path: Path, *, max_bytes: int | None = None) -> os.stat_result:
    try:
        metadata = path.stat(follow_symlinks=False)
    except OSError as error:
        raise HarnessError("private file unavailable") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise HarnessError("private path is not a regular file")
    if metadata.st_uid != os.geteuid():
        raise HarnessError("private file ownership mismatch")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise HarnessError("private file mode must be 0600")
    if max_bytes is not None and metadata.st_size > max_bytes:
        raise HarnessError("private file exceeds size bound")
    return metadata


def _fsync_parent(path: Path) -> None:
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _ensure_safe_directory(path: Path) -> None:
    if not path.exists():
        path.mkdir(mode=0o700, parents=True)
        os.chmod(path, 0o700)
    metadata = path.stat(follow_symlinks=False)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise HarnessError("output directory ownership invalid")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise HarnessError("output directory is group/world writable")


def _atomic_private_write(path: Path, encoded: bytes) -> None:
    _ensure_safe_directory(path.parent)
    temporary = path.parent / f".{path.name}.tmp-{os.getpid()}-{secrets.token_hex(8)}"
    descriptor: int | None = None
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise HarnessError("short atomic write")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path)
        os.chmod(path, 0o600)
        _fsync_parent(path)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_json_write(path: Path, value: Mapping[str, Any]) -> None:
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    _atomic_private_write(path, encoded)


def _private_json_with_hash(path: Path) -> tuple[dict[str, Any], str]:
    try:
        _require_private_regular(path, max_bytes=1024 * 1024)
        encoded = path.read_bytes()
    except (HarnessError, OSError) as error:
        raise LedgerError("resume receipt unavailable") from error
    try:
        value = json.loads(encoded)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise LedgerError("resume receipt invalid") from error
    if not isinstance(value, dict):
        raise LedgerError("resume receipt invalid")
    return value, hashlib.sha256(encoded).hexdigest()


def build_resumed_ledger_state(
    summary_path: Path,
    live_report_path: Path,
    *,
    expected_summary_sha256: str = RESUME_PARENT_SUMMARY_SHA256,
    expected_live_sha256: str = RESUME_PARENT_LIVE_SHA256,
) -> tuple[dict[str, Any], dict[str, Any]]:
    summary, summary_hash = _private_json_with_hash(Path(summary_path))
    live, live_hash = _private_json_with_hash(Path(live_report_path))
    if not re.fullmatch(r"[0-9a-f]{64}", expected_summary_sha256) or not re.fullmatch(
        r"[0-9a-f]{64}", expected_live_sha256
    ):
        raise LedgerError("resume receipt hash pin invalid")
    if not hmac.compare_digest(summary_hash, expected_summary_sha256) or not hmac.compare_digest(
        live_hash, expected_live_sha256
    ):
        raise LedgerError("resume receipt hash mismatch")
    if summary.get("status") != "verified_preflight_failure_no_large_spend":
        raise LedgerError("resume summary status invalid")
    source = summary.get("source_report")
    durable = summary.get("durable_ledger")
    if not isinstance(source, dict) or source.get("sha256") != live_hash or not isinstance(durable, dict):
        raise LedgerError("resume receipt linkage invalid")
    if live.get("failure") != "calibration_failed_no_large_spend" or live.get("ledger_summary") != durable:
        raise LedgerError("resume live report state mismatch")
    expected_durable = {
        "schema_version": 1,
        "run_id": DEFAULT_RUN_ID,
        "large_threshold": LARGE_THRESHOLD,
        "large_forwarded_total": 0,
        "large_remaining": {"native": 1, "direct": 1},
        "small_reserved": {"native": 0, "direct": 1},
        "small_remaining": {"native": 2, "direct": 1},
    }
    if durable != expected_durable:
        raise LedgerError("resume parent counters invalid")
    records = live.get("proxy_receipts")
    if not isinstance(records, list) or len(records) != 1:
        raise LedgerError("resume parent forwarding evidence invalid")
    record = records[0]
    if not isinstance(record, dict) or any(
        record.get(key) != value
        for key, value in {
            "phase": "direct",
            "size_class": "small",
            "forwarded": True,
            "upstream_status": 400,
            "outcome": "ambiguous_failure",
        }.items()
    ):
        raise LedgerError("resume parent forwarding evidence invalid")
    state = {
        "schema_version": LEDGER_SCHEMA,
        "run_id": durable["run_id"],
        "large_threshold": durable["large_threshold"],
        "large_forwarded_total": durable["large_forwarded_total"],
        "phases": {
            "native": {"large_reserved": False, "small_limit": 2, "small_reserved": 0},
            "direct": {"large_reserved": False, "small_limit": 3, "small_reserved": 1},
        },
    }
    _validate_ledger_state(state)
    evidence = {
        "schema_version": 1,
        "run_id": state["run_id"],
        "parent_summary_sha256": summary_hash,
        "parent_live_report_sha256": live_hash,
        "parent_authorization": RESUME_PARENT_AUTHORIZATION,
        "migration_rationale": (
            "The first direct calibration was permanently spent on an upstream HTTP 400 without "
            "numeric usage. One additional direct-small allowance permits two valid calibration points."
        ),
        "migration": {
            "phase": "direct",
            "small_limit_before": 2,
            "small_limit_after": 3,
            "small_reserved_carried": 1,
            "additional_small_allowance": 1,
        },
        "unchanged_limits": {
            "native_small_limit": 2,
            "native_large_limit": 1,
            "direct_large_limit": 1,
            "large_total_limit": 2,
        },
    }
    return state, evidence


def _validate_ledger_state(value: object) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise LedgerError("ledger schema invalid")
    expected = {
        "schema_version",
        "run_id",
        "large_threshold",
        "large_forwarded_total",
        "phases",
    }
    if set(value) != expected or value.get("schema_version") != LEDGER_SCHEMA:
        raise LedgerError("ledger schema invalid")
    if not isinstance(value.get("run_id"), str) or not value["run_id"]:
        raise LedgerError("ledger run identifier invalid")
    threshold = value.get("large_threshold")
    total = value.get("large_forwarded_total")
    if type(threshold) is not int or threshold <= 0 or type(total) is not int or not 0 <= total <= 2:
        raise LedgerError("ledger counters invalid")
    phases = value.get("phases")
    if not isinstance(phases, dict) or set(phases) != set(PHASES):
        raise LedgerError("ledger phases invalid")
    recomputed_total = 0
    for phase in PHASES:
        entry = phases[phase]
        if not isinstance(entry, dict) or set(entry) != {"large_reserved", "small_limit", "small_reserved"}:
            raise LedgerError("ledger phase schema invalid")
        if type(entry["large_reserved"]) is not bool:
            raise LedgerError("ledger phase reservation invalid")
        if type(entry["small_limit"]) is not int or entry["small_limit"] < 0:
            raise LedgerError("ledger small limit invalid")
        if type(entry["small_reserved"]) is not int or not 0 <= entry["small_reserved"] <= entry["small_limit"]:
            raise LedgerError("ledger small counter invalid")
        recomputed_total += int(entry["large_reserved"])
    if total != recomputed_total:
        raise LedgerError("ledger total mismatch")
    return value


class QuotaLedger:
    """Persistent, process-safe two-phase forwarding budget.

    The stable ``.lock`` inode is never replaced. The JSON ledger is atomically
    replaced and directory-fsynced while holding an exclusive flock. A
    reservation is durable before the caller is allowed to forward.
    """

    def __init__(self, path: Path):
        self.path = Path(path)
        self.lock_path = Path(str(self.path) + ".lock")

    @classmethod
    def initialize(
        cls,
        path: Path,
        *,
        large_threshold: int,
        small_limits: Mapping[str, int],
        run_id: str,
    ) -> "QuotaLedger":
        path = Path(path)
        if large_threshold <= 0 or set(small_limits) != set(PHASES):
            raise LedgerError("invalid initial quota")
        if not run_id:
            raise LedgerError("run identifier required")
        _ensure_safe_directory(path.parent)
        lock_path = Path(str(path) + ".lock")
        lock_fd = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        try:
            os.fchmod(lock_fd, 0o600)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            if os.path.lexists(path):
                raise LedgerError("ledger already initialized")
            state = {
                "schema_version": LEDGER_SCHEMA,
                "run_id": run_id,
                "large_threshold": large_threshold,
                "large_forwarded_total": 0,
                "phases": {
                    phase: {
                        "large_reserved": False,
                        "small_limit": int(small_limits[phase]),
                        "small_reserved": 0,
                    }
                    for phase in PHASES
                },
            }
            _validate_ledger_state(state)
            _atomic_json_write(path, state)
            os.fsync(lock_fd)
        finally:
            os.close(lock_fd)
        return cls.open(path)

    @classmethod
    def initialize_from_state(
        cls,
        path: Path,
        state: Mapping[str, Any],
    ) -> tuple["QuotaLedger", bool]:
        path = Path(path)
        candidate = _validate_ledger_state(json.loads(json.dumps(state)))
        _ensure_safe_directory(path.parent)
        lock_path = Path(str(path) + ".lock")
        lock_fd = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        created = False
        try:
            os.fchmod(lock_fd, 0o600)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            if os.path.lexists(path):
                try:
                    _require_private_regular(path, max_bytes=64 * 1024)
                    existing = _validate_ledger_state(json.loads(path.read_bytes()))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError, HarnessError) as error:
                    raise LedgerError("existing resumed ledger invalid") from error
                if existing != candidate:
                    raise LedgerError("existing resumed ledger state mismatch")
            else:
                _atomic_json_write(path, candidate)
                os.fsync(lock_fd)
                created = True
        finally:
            os.close(lock_fd)
        return cls.open(path), created

    @classmethod
    def open(cls, path: Path) -> "QuotaLedger":
        ledger = cls(path)
        if not ledger.path.exists() or not ledger.lock_path.exists():
            raise LedgerError("initialized ledger or stable lock missing")
        try:
            _require_private_regular(ledger.path, max_bytes=64 * 1024)
            _require_private_regular(ledger.lock_path, max_bytes=64 * 1024)
            with ledger._locked_state() as state:
                _validate_ledger_state(state)
        except HarnessError as error:
            if isinstance(error, LedgerError):
                raise
            raise LedgerError("initialized ledger metadata invalid") from error
        return ledger

    class _LockedState:
        def __init__(self, owner: "QuotaLedger"):
            self.owner = owner
            self.fd: int | None = None
            self.state: dict[str, Any] | None = None

        def __enter__(self) -> dict[str, Any]:
            try:
                self.fd = os.open(
                    self.owner.lock_path,
                    os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
                )
            except OSError as error:
                raise LedgerError("stable ledger lock unavailable") from error
            fcntl.flock(self.fd, fcntl.LOCK_EX)
            try:
                _require_private_regular(self.owner.path, max_bytes=64 * 1024)
                raw = self.owner.path.read_bytes()
                value = json.loads(raw)
                self.state = _validate_ledger_state(value)
            except (OSError, UnicodeDecodeError, json.JSONDecodeError, HarnessError) as error:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
                os.close(self.fd)
                self.fd = None
                raise LedgerError("ledger unreadable or malformed") from error
            return self.state

        def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
            if self.fd is not None:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
                os.close(self.fd)
                self.fd = None

    def _locked_state(self) -> "QuotaLedger._LockedState":
        return self._LockedState(self)

    def reserve(self, phase: str, request_bytes: int) -> Reservation:
        if phase not in PHASES or type(request_bytes) is not int or request_bytes < 0:
            raise QuotaExceeded("invalid phase or request size")
        with self._locked_state() as state:
            entry = state["phases"][phase]
            if request_bytes >= state["large_threshold"]:
                if entry["large_reserved"] or state["large_forwarded_total"] >= 2:
                    raise QuotaExceeded("large phase slot already spent")
                entry["large_reserved"] = True
                state["large_forwarded_total"] += 1
                size_class = "large"
            else:
                if entry["small_reserved"] >= entry["small_limit"]:
                    raise QuotaExceeded("small phase budget exhausted")
                entry["small_reserved"] += 1
                size_class = "small"
            _validate_ledger_state(state)
            # This fsync/replace occurs before the caller receives permission to forward.
            _atomic_json_write(self.path, state)
        return Reservation(phase=phase, size_class=size_class, request_bytes=request_bytes)

    def full_state(self) -> dict[str, Any]:
        with self._locked_state() as state:
            return json.loads(json.dumps(state))

    def snapshot(self) -> dict[str, Any]:
        with self._locked_state() as state:
            return {
                "schema_version": state["schema_version"],
                "run_id": state["run_id"],
                "large_threshold": state["large_threshold"],
                "large_forwarded_total": state["large_forwarded_total"],
                "large_remaining": {
                    phase: int(not state["phases"][phase]["large_reserved"])
                    for phase in PHASES
                },
                "small_reserved": {
                    phase: state["phases"][phase]["small_reserved"]
                    for phase in PHASES
                },
                "small_remaining": {
                    phase: state["phases"][phase]["small_limit"]
                    - state["phases"][phase]["small_reserved"]
                    for phase in PHASES
                },
            }


def write_safe_budget_summary(ledger: QuotaLedger, destination: Path) -> None:
    _atomic_json_write(Path(destination), ledger.snapshot())


def _set_toml_key(text: str, table: str, key: str, rendered_value: str) -> str:
    lines = text.splitlines()
    header = f"[{table}]"
    try:
        start = lines.index(header)
    except ValueError:
        suffix = "" if not lines or lines[-1] == "" else "\n"
        return text + suffix + f"\n{header}\n{key} = {rendered_value}\n"
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("[") and lines[index].endswith("]"):
            end = index
            break
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    matches = [index for index in range(start + 1, end) if pattern.match(lines[index])]
    if len(matches) > 1:
        raise HarnessError(f"duplicate TOML key in {table}")
    replacement = f"{key} = {rendered_value}"
    if matches:
        lines[matches[0]] = replacement
    else:
        lines.insert(start + 1, replacement)
    return "\n".join(lines) + "\n"


def _toml_string(value: str) -> str:
    return json.dumps(value)


def derive_acceptance_bearer(canonical_capability: str, run_root: Path) -> str:
    run_root = Path(run_root)
    if not canonical_capability or not run_root.is_absolute():
        raise HarnessError("acceptance bearer inputs invalid")
    normalized_root = os.path.normpath(str(run_root)).encode("utf-8")
    digest = hmac.new(
        canonical_capability.encode("utf-8"),
        ACCEPTANCE_BEARER_PURPOSE + b"\0" + normalized_root,
        hashlib.sha256,
    ).hexdigest()
    return "zcat-context-v1-" + digest


def gateway_bearer_authorized(config: bytes, bearer: str) -> bool:
    try:
        document = tomllib.loads(config.decode("utf-8"))
        paired_tokens = document["gateway"]["paired_tokens"]
    except (UnicodeDecodeError, tomllib.TOMLDecodeError, KeyError, TypeError):
        return False
    if not isinstance(paired_tokens, list) or not isinstance(bearer, str):
        return False
    candidate = hashlib.sha256(bearer.encode("utf-8")).hexdigest()
    return any(
        isinstance(value, str) and hmac.compare_digest(candidate, value)
        for value in paired_tokens
    )


def build_acceptance_config(
    canonical: bytes,
    *,
    proxy_port: int,
    gateway_port: int,
    run_root: Path,
) -> bytes:
    if len(canonical) > CANONICAL_MAX_BYTES or not 1 <= proxy_port <= 65535 or not 1 <= gateway_port <= 65535:
        raise HarnessError("acceptance config input invalid")
    try:
        source = tomllib.loads(canonical.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise HarnessError("canonical config invalid") from error
    try:
        provider = source["providers"]["models"]["openai"]["siwc"]
        runtime = source["runtime_profiles"]["siwc"]
        reliability = source["reliability"]
        capability = provider["api_key"]
    except (KeyError, TypeError) as error:
        raise HarnessError("canonical SIWC configuration missing") from error
    if provider.get("uri") != PRODUCTION_PROVIDER_URI:
        raise HarnessError("canonical adapter URI differs from fixed production loopback")
    if provider.get("model") != "gpt-5.6-sol" or provider.get("context_window") != 872000:
        raise HarnessError("canonical model or context window differs")
    if runtime.get("max_context_tokens") != 872000 or runtime.get("context_compact_ratio") != 0.9:
        raise HarnessError("canonical runtime budget differs")
    if reliability.get("provider_retries") != 0:
        raise HarnessError("canonical provider retries must remain disabled")
    if not isinstance(capability, str) or not capability:
        raise HarnessError("canonical local capability missing")
    acceptance_bearer = derive_acceptance_bearer(capability, run_root)
    acceptance_bearer_hash = hashlib.sha256(acceptance_bearer.encode("utf-8")).hexdigest()

    text = canonical.decode("utf-8")
    native_uri = f"http://127.0.0.1:{proxy_port}/phase/native/v1/responses"
    updates = (
        ("providers.models.openai.siwc", "uri", _toml_string(native_uri)),
        ("gateway", "host", _toml_string("127.0.0.1")),
        ("gateway", "port", str(gateway_port)),
        ("gateway", "require_pairing", "true"),
        ("gateway", "paired_tokens", json.dumps([acceptance_bearer_hash])),
        ("gateway", "allow_public_bind", "false"),
        ("runtime_profiles.siwc", "max_tool_iterations", "1"),
        ("runtime_profiles.siwc", "agentic", "false"),
        ("risk_profiles.siwc", "deny_all_tools", "true"),
        ("tools", "optional", "[]"),
        ("memory", "backend", _toml_string("none")),
        ("memory", "auto_save", "false"),
        ("memory", "hygiene_enabled", "false"),
        ("memory", "response_cache_enabled", "false"),
        ("agents.pi4.memory", "backend", _toml_string("none")),
    )
    for table, key, rendered in updates:
        text = _set_toml_key(text, table, key, rendered)
    rendered = text.encode("utf-8")
    parsed = tomllib.loads(text)
    rendered_provider = parsed["providers"]["models"]["openai"]["siwc"]
    rendered_runtime = parsed["runtime_profiles"]["siwc"]
    if (
        rendered_provider["model"] != provider["model"]
        or rendered_provider["context_window"] != provider["context_window"]
        or rendered_runtime["max_context_tokens"] != runtime["max_context_tokens"]
        or rendered_runtime["context_compact_ratio"] != runtime["context_compact_ratio"]
    ):
        raise HarnessError("acceptance clone changed production model budget")
    return rendered


def prepare_private_layout(
    canonical_path: Path,
    root: Path,
    *,
    proxy_port: int,
    gateway_port: int,
    require_run_root: bool = True,
    run_id: str = DEFAULT_RUN_ID,
) -> Layout:
    canonical_path = Path(canonical_path)
    root = Path(root)
    _require_private_regular(canonical_path, max_bytes=CANONICAL_MAX_BYTES)
    if require_run_root and not root.is_absolute():
        raise HarnessError("layout root must be absolute")
    if require_run_root and root != Path("/run") and Path("/run") not in root.parents:
        raise HarnessError("live layout must be under /run")
    if root.exists():
        raise HarnessError("acceptance layout already exists; never auto-reset a run")
    root.mkdir(mode=0o700, parents=True)
    os.chmod(root, 0o700)
    config_dir = root / "config"
    config_dir.mkdir(mode=0o700)
    data_dir = config_dir / "data"
    for directory in (
        data_dir,
        config_dir / "shared",
        config_dir / "agents",
        config_dir / "agents" / "pi4",
        config_dir / "agents" / "pi4" / "workspace",
    ):
        directory.mkdir(mode=0o700)
    config_path = config_dir / "config.toml"
    receipt_path = root / "evidence.jsonl"
    ledger_path = root / "forward-budget.json"
    rendered = build_acceptance_config(
        canonical_path.read_bytes(),
        proxy_port=proxy_port,
        gateway_port=gateway_port,
        run_root=root,
    )
    descriptor = os.open(config_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    try:
        view = memoryview(rendered)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise HarnessError("short config write")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    receipt_path.touch(mode=0o600, exist_ok=False)
    with receipt_path.open("rb") as receipt:
        os.fsync(receipt.fileno())
    QuotaLedger.initialize(
        ledger_path,
        large_threshold=LARGE_THRESHOLD,
        small_limits=DEFAULT_SMALL_LIMITS,
        run_id=run_id,
    )
    _fsync_parent(config_path)
    return Layout(root, config_dir, config_path, data_dir, receipt_path, ledger_path)


def transient_unit_properties(role: str, *, wallclock_seconds: int) -> dict[str, str]:
    if not 1 <= wallclock_seconds <= 3600:
        raise HarnessError("wallclock must be between 1 and 3600 seconds")
    common = {
        "User": "zeroclaw-agent",
        "Group": "zeroclaw-agent",
        "RuntimeMaxSec": f"{wallclock_seconds}s",
        "KillMode": "control-group",
        "UMask": "0077",
        "LimitCORE": "0",
        "Environment": "CONTEXT_LOAD_BOUNDED=1",
        "StandardOutput": "null",
        "StandardError": "null",
    }
    if role == "native":
        return common | {
            "MemoryMax": "1G",
            "TasksMax": "128",
            "LimitNOFILE": "1024",
            "TimeoutStopSec": "15s",
        }
    if role == "proxy":
        return common | {
            "MemoryMax": "768M",
            "TasksMax": "16",
            "LimitNOFILE": "128",
            "TimeoutStopSec": "10s",
        }
    raise HarnessError("unknown bounded role")


def transient_systemd_argv(
    role: str,
    unit_name: str,
    command: list[str],
    *,
    wallclock_seconds: int,
) -> list[str]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", unit_name) or not command:
        raise HarnessError("invalid transient unit request")
    properties = transient_unit_properties(role, wallclock_seconds=wallclock_seconds)
    argv = ["systemd-run", "--unit", unit_name, "--collect", "--service-type=exec"]
    for key, value in properties.items():
        argv.extend(("--property", f"{key}={value}"))
    return argv + ["--"] + command


class SseEvidence:
    def __init__(
        self,
        *,
        max_event_bytes: int = MAX_SSE_EVENT_BYTES,
        expected_markers: tuple[str, str, str] | None = None,
    ):
        self.max_event_bytes = max_event_bytes
        self.expected_markers = expected_markers
        self.buffer = bytearray()
        self.usage: dict[str, int] = {}
        self.markers: list[str] = []
        self.saw_error = False
        self.output_parts: list[str] = []
        self.completed_text: str | None = None

    def feed(self, data: bytes) -> None:
        self.buffer.extend(data)
        if len(self.buffer) > self.max_event_bytes and b"\n" not in self.buffer:
            raise HarnessError("SSE event exceeds safe bound")
        while True:
            newline = self.buffer.find(b"\n")
            if newline < 0:
                break
            line = bytes(self.buffer[:newline]).rstrip(b"\r")
            del self.buffer[: newline + 1]
            self._line(line)

    def _line(self, line: bytes) -> None:
        if not line.startswith(b"data:"):
            return
        payload = line[5:].strip()
        if payload == b"[DONE]":
            if "[DONE]" not in self.markers:
                self.markers.append("[DONE]")
            return
        try:
            event = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(event, dict):
            return
        event_type = event.get("type")
        if event_type == "response.output_text.delta":
            delta = event.get("delta")
            if isinstance(delta, str):
                if sum(len(part) for part in self.output_parts) + len(delta) > 4096:
                    self.saw_error = True
                else:
                    self.output_parts.append(delta)
        if event_type in {"response.completed", "response.failed", "response.incomplete", "error"}:
            if event_type not in self.markers:
                self.markers.append(event_type)
        if event_type in {"response.failed", "response.incomplete", "error"}:
            self.saw_error = True
        response = event.get("response")
        if not isinstance(response, dict):
            return
        if event_type == "response.completed":
            completed_parts: list[str] = []
            output = response.get("output")
            if isinstance(output, list):
                for item in output:
                    if not isinstance(item, dict):
                        continue
                    content = item.get("content")
                    if not isinstance(content, list):
                        continue
                    for part in content:
                        if isinstance(part, dict) and isinstance(part.get("text"), str):
                            completed_parts.append(part["text"])
            completed = "".join(completed_parts)
            if completed and len(completed) <= 4096:
                self.completed_text = completed
        usage = response.get("usage")
        if not isinstance(usage, dict):
            return
        mapping = {
            "input_tokens": "input_tokens",
            "output_tokens": "output_tokens",
            "total_tokens": "total_tokens",
        }
        for source, destination in mapping.items():
            value = usage.get(source)
            if type(value) is int and value >= 0:
                self.usage[destination] = value
        details = usage.get("input_tokens_details")
        if isinstance(details, dict):
            cached = details.get("cached_tokens")
            if type(cached) is int and cached >= 0:
                self.usage["cached_input_tokens"] = cached

    def finish(self) -> dict[str, Any]:
        if self.buffer:
            self._line(bytes(self.buffer).rstrip(b"\r"))
            self.buffer.clear()
        result: dict[str, Any] = {
            "completion_markers": list(self.markers),
            "verified_response_completed": "response.completed" in self.markers,
            "saw_error": self.saw_error,
            "usage": dict(self.usage),
        }
        if self.expected_markers is not None:
            answer = self.completed_text if self.completed_text is not None else "".join(self.output_parts)
            result["retrieval"] = _retrieval_result(answer, self.expected_markers)
        return result


def accepts_provider_result(
    http_status: int | None,
    evidence: Mapping[str, Any],
    *,
    require_retrieval: bool = False,
) -> bool:
    usage = evidence.get("usage")
    retrieval = evidence.get("retrieval")
    return bool(
        type(http_status) is int
        and 200 <= http_status < 300
        and evidence.get("verified_response_completed") is True
        and evidence.get("saw_error") is False
        and isinstance(usage, dict)
        and type(usage.get("input_tokens")) is int
        and usage["input_tokens"] >= 0
        and type(usage.get("output_tokens")) is int
        and usage["output_tokens"] >= 0
        and (
            not require_retrieval
            or (
                isinstance(retrieval, dict)
                and retrieval.get("begin") is True
                and retrieval.get("middle") is True
                and retrieval.get("end") is True
                and retrieval.get("exact_compact_answer") is True
            )
        )
    )


def _append_receipt(path: Path, receipt: Mapping[str, Any]) -> None:
    encoded = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.write(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fixed_error(handler: http.server.BaseHTTPRequestHandler, status: int, code: str) -> None:
    payload = (json.dumps({"error": code}, separators=(",", ":")) + "\n").encode()
    try:
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(payload)))
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(payload)
    except OSError:
        pass
    handler.close_connection = True


def build_proxy_server(
    *,
    bind: tuple[str, int],
    quota: QuotaLedger,
    receipt_path: Path,
    upstream: UpstreamEndpoint,
    max_request_bytes: int = MAX_REQUEST_BYTES,
    max_response_bytes: int = MAX_RESPONSE_BYTES,
    timeout_seconds: int = 370,
    expected_capability: str,
) -> http.server.ThreadingHTTPServer:
    if bind[0] != "127.0.0.1" or upstream.host != "127.0.0.1":
        raise HarnessError("proxy endpoints must be loopback")
    if not expected_capability or "\r" in expected_capability or "\n" in expected_capability:
        raise HarnessError("proxy capability invalid")
    _require_private_regular(Path(receipt_path), max_bytes=None)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:
            return

        def do_POST(self) -> None:  # noqa: N802
            match = re.fullmatch(r"/phase/(native|direct)/v1/responses", self.path)
            if match is None:
                _fixed_error(self, 404, "path_not_allowed")
                return
            phase = match.group(1)
            authorization = self.headers.get("Authorization", "")
            supplied = authorization[7:] if authorization.startswith("Bearer ") else ""
            if not hmac.compare_digest(supplied, expected_capability):
                _fixed_error(self, 401, "unauthorized")
                return
            if self.headers.get("Transfer-Encoding") is not None:
                _fixed_error(self, 400, "chunked_request_not_allowed")
                return
            try:
                content_length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                _fixed_error(self, 411, "content_length_required")
                return
            if content_length < 0:
                _fixed_error(self, 400, "content_length_invalid")
                return
            if content_length > max_request_bytes:
                _fixed_error(self, 413, "request_too_large")
                return
            try:
                reservation = quota.reserve(phase, content_length)
            except (QuotaExceeded, LedgerError):
                _fixed_error(self, 429, "forward_budget_exhausted")
                return

            spool = tempfile.SpooledTemporaryFile(max_size=1024 * 1024, mode="w+b")
            self.connection.settimeout(min(timeout_seconds, 60))
            remaining = content_length
            try:
                while remaining:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        raise HarnessError("request body incomplete")
                    spool.write(chunk)
                    remaining -= len(chunk)
                spool.seek(0)
                expected_markers = extract_nonce_markers(spool.read())
                spool.seek(0)
            except (OSError, HarnessError):
                reservation.mark_ambiguous_failure()
                _append_receipt(
                    Path(receipt_path),
                    {
                        "phase": phase,
                        "size_class": reservation.size_class,
                        "request_bytes": content_length,
                        "outcome": reservation.outcome,
                        "forwarded": False,
                    },
                )
                spool.close()
                _fixed_error(self, 400, "request_body_failed")
                return

            if reservation.size_class == "large" and expected_markers is None:
                reservation.mark_ambiguous_failure()
                _append_receipt(
                    Path(receipt_path),
                    {
                        "phase": phase,
                        "size_class": reservation.size_class,
                        "request_bytes": content_length,
                        "outcome": reservation.outcome,
                        "forwarded": False,
                        "accepted": False,
                        "retrieval": {
                            "begin": False,
                            "middle": False,
                            "end": False,
                            "exact_compact_answer": False,
                        },
                    },
                )
                spool.close()
                _fixed_error(self, 400, "large_prompt_markers_required")
                return

            connection = http.client.HTTPConnection(upstream.host, upstream.port, timeout=timeout_seconds)
            evidence = SseEvidence(expected_markers=expected_markers)
            response_started = False
            upstream_status: int | None = None
            response_bytes = 0
            accepted = False
            safe_evidence: dict[str, Any] = evidence.finish()
            try:
                connection.putrequest("POST", upstream.path, skip_accept_encoding=True)
                connection.putheader("Content-Length", str(content_length))
                connection.putheader("Content-Type", self.headers.get("Content-Type", "application/json"))
                connection.putheader("Accept", "text/event-stream, application/json")
                connection.putheader("Authorization", f"Bearer {expected_capability}")
                connection.endheaders()
                while True:
                    chunk = spool.read(65536)
                    if not chunk:
                        break
                    connection.send(chunk)
                response = connection.getresponse()
                upstream_status = response.status
                self.send_response(response.status)
                self.send_header("Content-Type", response.getheader("Content-Type", "application/octet-stream"))
                self.send_header("Connection", "close")
                self.end_headers()
                response_started = True
                while True:
                    chunk = response.read1(65536)
                    if not chunk:
                        break
                    response_bytes += len(chunk)
                    if response_bytes > max_response_bytes:
                        raise HarnessError("upstream response exceeded bound")
                    evidence.feed(chunk)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                safe_evidence = evidence.finish()
                accepted = accepts_provider_result(
                    upstream_status,
                    safe_evidence,
                    require_retrieval=reservation.size_class == "large",
                )
                if accepted:
                    reservation.mark_completed()
                else:
                    reservation.mark_ambiguous_failure()
                    evidence.feed(GENERIC_SSE_ERROR)
                    safe_evidence = evidence.finish()
                    self.wfile.write(GENERIC_SSE_ERROR)
                    self.wfile.flush()
            except (OSError, http.client.HTTPException, HarnessError):
                reservation.mark_ambiguous_failure()
                if not response_started:
                    _fixed_error(self, 502, "upstream_failed")
                else:
                    try:
                        evidence.feed(GENERIC_SSE_ERROR)
                        safe_evidence = evidence.finish()
                        self.wfile.write(GENERIC_SSE_ERROR)
                        self.wfile.flush()
                    except (OSError, HarnessError):
                        pass
                    self.close_connection = True
            finally:
                connection.close()
                spool.close()
                _append_receipt(
                    Path(receipt_path),
                    {
                        "phase": phase,
                        "size_class": reservation.size_class,
                        "request_bytes": content_length,
                        "forwarded": True,
                        "upstream_status": upstream_status,
                        "response_bytes": response_bytes,
                        "outcome": reservation.outcome,
                        "accepted": accepted,
                        "evidence": safe_evidence,
                    },
                )

    server = http.server.ThreadingHTTPServer(bind, Handler)
    server.daemon_threads = True
    return server


def _numeric_usage(event: Mapping[str, Any]) -> dict[str, int]:
    result: dict[str, int] = {}
    for key in ("input_tokens", "output_tokens", "tokens_used", "last_input_tokens"):
        value = event.get(key)
        if type(value) is int and value >= 0:
            result[key] = value
    return result


def assess_native_sequence(
    first_events: list[dict[str, Any]],
    second_events: list[dict[str, Any]],
    *,
    expected_markers: tuple[str, str, str],
) -> dict[str, Any]:
    first_terminal = next(
        (event for event in reversed(first_events) if event.get("type") in {"done", "error", "aborted"}),
        {},
    )
    second_terminal = next(
        (event for event in reversed(second_events) if event.get("type") in {"done", "error", "aborted"}),
        {},
    )
    trim = next((event for event in second_events if event.get("type") == "history_trimmed"), None)
    safe_trim: dict[str, Any] | None = None
    if isinstance(trim, dict):
        safe_trim = {"type": "history_trimmed"}
        for key in (
            "dropped_messages",
            "dropped_turns",
            "kept_turns",
            "token_budget",
            "tokens_before",
            "tokens_after",
        ):
            value = trim.get(key)
            if type(value) is int and value >= 0:
                safe_trim[key] = value
        if type(trim.get("unsatisfiable_floor")) is bool:
            safe_trim["unsatisfiable_floor"] = trim["unsatisfiable_floor"]
        if trim.get("count_source") in {"estimated", "provider", "calibrated"}:
            safe_trim["count_source"] = trim["count_source"]
    first_usage = _numeric_usage(first_terminal)
    second_usage = _numeric_usage(second_terminal)
    usage_verified = all(
        type(usage.get(key)) is int
        for usage in (first_usage, second_usage)
        for key in ("input_tokens", "output_tokens")
    )
    first_answer = first_terminal.get("full_response")
    retrieval = _retrieval_result(
        first_answer if isinstance(first_answer, str) else "",
        expected_markers,
    )
    passed = (
        first_terminal.get("type") == "done"
        and second_terminal.get("type") == "done"
        and usage_verified
        and retrieval["exact_compact_answer"]
        and safe_trim is not None
        and safe_trim.get("dropped_turns", 0) >= 1
        and not safe_trim.get("unsatisfiable_floor", False)
    )
    return {
        "passed": passed,
        "usage_verified": usage_verified,
        "retrieval": retrieval,
        "first_terminal": first_terminal.get("type"),
        "first_turn_usage": first_usage,
        "second_terminal": second_terminal.get("type"),
        "second_turn_usage": second_usage,
        "trim": safe_trim,
    }


def calibrate_repetitions(
    *,
    first_units: int,
    first_input_tokens: int,
    second_units: int,
    second_input_tokens: int,
    target_input_tokens: int,
) -> dict[str, Any]:
    if not (0 <= first_units < second_units and 0 <= first_input_tokens < second_input_tokens):
        raise HarnessError("calibration points must increase")
    slope = Fraction(second_input_tokens - first_input_tokens, second_units - first_units)
    intercept = Fraction(first_input_tokens) - slope * first_units
    if slope <= 0 or target_input_tokens <= intercept:
        raise HarnessError("calibration does not reach target")
    estimate = math.ceil(Fraction(target_input_tokens - intercept, 1) / slope)
    return {
        "estimated_units": estimate,
        "target_input_tokens": target_input_tokens,
        "tokens_per_unit_numerator": slope.numerator,
        "tokens_per_unit_denominator": slope.denominator,
        "fixed_tokens_numerator": intercept.numerator,
        "fixed_tokens_denominator": intercept.denominator,
        "label": "provider-calibrated estimate; final upstream usage is authoritative",
    }


def assess_filler_feasibility(
    *,
    filler_unit: str,
    first_units: int,
    first_input_tokens: int,
    second_units: int,
    second_input_tokens: int,
    target_input_tokens: int,
    budget_tokens: int,
) -> dict[str, Any]:
    encoded_unit = filler_unit.encode("utf-8")
    if not encoded_unit:
        raise HarnessError("filler unit must not be empty")
    calibration = calibrate_repetitions(
        first_units=first_units,
        first_input_tokens=first_input_tokens,
        second_units=second_units,
        second_input_tokens=second_input_tokens,
        target_input_tokens=target_input_tokens,
    )
    slope = Fraction(
        calibration["tokens_per_unit_numerator"],
        calibration["tokens_per_unit_denominator"],
    )
    estimated_units = calibration["estimated_units"]
    fixed_markers = (
        "CTXLOAD_BEGIN_" + "0" * 32,
        "CTXLOAD_MIDDLE_" + "1" * 32,
        "CTXLOAD_END_" + "2" * 32,
    )
    fixed_framing_bytes = len(build_marked_prompt(filler_unit, 0, markers=fixed_markers).encode("utf-8"))
    estimated_prompt_bytes = fixed_framing_bytes + len(encoded_unit) * estimated_units
    followup_bytes = minimum_followup_bytes_for_trim(
        first_user_utf8_bytes=estimated_prompt_bytes,
        budget_tokens=budget_tokens,
    )
    bytes_per_token = float(Fraction(len(encoded_unit), 1) / slope)
    feasible = 3.5 <= bytes_per_token <= 4.5 and 0 < followup_bytes <= FOLLOWUP_CONTENT_MAX
    return {
        "feasible": feasible,
        "decision": "proceed_after_live_gate" if feasible else "do_not_spend_native_large_slot",
        "filler_unit_utf8_bytes": len(encoded_unit),
        "fixed_framing_utf8_bytes": fixed_framing_bytes,
        "estimated_utf8_bytes_per_token": bytes_per_token,
        "estimated_units": estimated_units,
        "estimated_prompt_utf8_bytes": estimated_prompt_bytes,
        "followup_utf8_bytes": followup_bytes,
        "target_input_tokens": target_input_tokens,
        "estimate_label": "provider-calibrated estimate; final upstream usage is authoritative",
    }


def _estimate_message_tokens(utf8_bytes: int) -> int:
    if utf8_bytes < 0:
        raise HarnessError("negative message size")
    return (utf8_bytes + 3) // 4 + 4


def conservative_two_user_turn_estimate(first_user_utf8_bytes: int, followup_utf8_bytes: int) -> int:
    """Lower bound for the real ZeroClaw bytes/4 + four/message estimate.

    System and assistant messages and any calibration ratio greater than one are
    deliberately omitted, so exceeding the budget here guarantees the actual
    pre-dispatch counter exceeds it too for plain text/no-tool turns.
    """
    return _estimate_message_tokens(first_user_utf8_bytes) + _estimate_message_tokens(followup_utf8_bytes)


def minimum_followup_bytes_for_trim(*, first_user_utf8_bytes: int, budget_tokens: int) -> int:
    if budget_tokens <= 0:
        raise HarnessError("positive trim budget required")
    first = _estimate_message_tokens(first_user_utf8_bytes)
    content_tokens_needed = budget_tokens + 1 - first - 4
    if content_tokens_needed <= 0:
        return 0
    return 4 * (content_tokens_needed - 1) + 1


def _read_capability(canonical_path: Path) -> str:
    _require_private_regular(canonical_path, max_bytes=CANONICAL_MAX_BYTES)
    try:
        parsed = tomllib.loads(canonical_path.read_text())
        capability = parsed["providers"]["models"]["openai"]["siwc"]["api_key"]
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError, KeyError, TypeError) as error:
        raise HarnessError("canonical local capability unavailable") from error
    if not isinstance(capability, str) or not capability or "\r" in capability or "\n" in capability:
        raise HarnessError("canonical local capability invalid")
    return capability


def direct_request(
    *,
    canonical_path: Path,
    body_path: Path,
    proxy_port: int,
    timeout_seconds: int,
) -> dict[str, Any]:
    metadata = _require_private_regular(body_path, max_bytes=MAX_REQUEST_BYTES)
    expected_markers = extract_nonce_markers(body_path.read_bytes())
    require_retrieval = metadata.st_size >= LARGE_THRESHOLD
    if require_retrieval and expected_markers is None:
        raise HarnessError("direct large prompt requires unique begin/middle/end nonce markers")
    capability = _read_capability(canonical_path)
    connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=timeout_seconds)
    evidence = SseEvidence(expected_markers=expected_markers)
    status: int | None = None
    try:
        connection.putrequest("POST", "/phase/direct/v1/responses", skip_accept_encoding=True)
        connection.putheader("Content-Length", str(metadata.st_size))
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Accept", "text/event-stream")
        connection.putheader("Authorization", f"Bearer {capability}")
        connection.endheaders()
        with body_path.open("rb") as body:
            while chunk := body.read(65536):
                connection.send(chunk)
        response = connection.getresponse()
        status = response.status
        seen = 0
        while chunk := response.read1(65536):
            seen += len(chunk)
            if seen > MAX_RESPONSE_BYTES:
                raise HarnessError("direct response exceeded bound")
            evidence.feed(chunk)
    except (OSError, http.client.HTTPException) as error:
        raise HarnessError("direct proxy request failed") from error
    finally:
        connection.close()
    safe_evidence = evidence.finish()
    return {
        "http_status": status,
        "accepted": accepts_provider_result(
            status,
            safe_evidence,
            require_retrieval=require_retrieval,
        ),
        "evidence": safe_evidence,
    }


def native_daemon_command(binary: Path, layout: Layout, *, gateway_port: int) -> tuple[list[str], dict[str, str]]:
    binary = Path(binary)
    if not binary.is_absolute() or not binary.exists() or not os.access(binary, os.X_OK):
        raise HarnessError("exact ZeroClaw binary must be an absolute executable path")
    argv = [
        str(binary),
        "--config-dir",
        str(layout.config_dir),
        "--log-level",
        "error",
        "daemon",
        "--host",
        "127.0.0.1",
        "--port",
        str(gateway_port),
    ]
    env = {
        "HOME": str(layout.data_dir),
        "PATH": "/run/current-system/sw/bin",
        "LANG": "C.UTF-8",
        "SSL_CERT_FILE": "/etc/ssl/certs/ca-bundle.crt",
    }
    return argv, env


def _write_safe_receipt(path: Path, value: Mapping[str, Any]) -> None:
    _atomic_json_write(path, value)


def run_native_sequence(
    *,
    canonical_path: Path,
    run_root: Path,
    prompt_path: Path,
    gateway_port: int,
    receipt_path: Path,
    budget_tokens: int = 784800,
) -> dict[str, Any]:
    _require_private_regular(prompt_path, max_bytes=16 * 1024 * 1024)
    prompt_bytes = prompt_path.read_bytes()
    try:
        prompt = prompt_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise HarnessError("native prompt must be UTF-8") from error
    expected_markers = extract_nonce_markers(prompt_bytes)
    if expected_markers is None:
        raise HarnessError("large prompt requires unique begin/middle/end nonce markers")
    followup_bytes = minimum_followup_bytes_for_trim(
        first_user_utf8_bytes=len(prompt_bytes),
        budget_tokens=budget_tokens,
    )
    if followup_bytes <= 0 or followup_bytes > FOLLOWUP_CONTENT_MAX:
        raise HarnessError("offline follow-up does not fit conservative small-request envelope")
    # Import only for the gated live operation; no module-level socket activity.
    import paired_gateway as gateway

    gateway.HOST = "127.0.0.1"
    gateway.PORT = gateway_port
    session = f"context-load-{secrets.token_hex(8)}"
    capability = _read_capability(canonical_path)
    acceptance_bearer = derive_acceptance_bearer(capability, run_root)
    client = gateway.WsClient(acceptance_bearer, session, session)
    try:
        start = client.recv_json()
        if start.get("type") != "session_start" or start.get("resumed") is not False:
            raise HarnessError("native session start invalid")
        client.send_json({
            "type": "connect",
            "session_id": session,
            "device_name": session,
            "capabilities": [],
        })
        if client.recv_json().get("type") != "connected":
            raise HarnessError("native session connect invalid")
        first_events = gateway.run_ws_message(client, prompt)
        if not any(event.get("type") == "done" for event in first_events):
            raise HarnessError("native large turn did not complete")
        second_events = gateway.run_ws_message(client, "x" * followup_bytes)
    finally:
        client.close()
    receipt = assess_native_sequence(
        first_events,
        second_events,
        expected_markers=expected_markers,
    )
    receipt["sizing"] = {
        "first_user_utf8_bytes": len(prompt_bytes),
        "followup_utf8_bytes": followup_bytes,
        "zeroclaw_estimate": "ceil(utf8_bytes/4)+4 per retained plain-text message",
        "provider_usage_authoritative": True,
    }
    _write_safe_receipt(receipt_path, receipt)
    return receipt


def _layout_from_root(root: Path) -> Layout:
    root = Path(root)
    return Layout(
        root=root,
        config_dir=root / "config",
        config_path=root / "config" / "config.toml",
        data_dir=root / "config" / "data",
        receipt_path=root / "evidence.jsonl",
        ledger_path=root / "forward-budget.json",
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="context_load.py")
    commands = parser.add_subparsers(dest="command", required=True)

    prepare = commands.add_parser("prepare")
    prepare.add_argument("--canonical-config", required=True, type=Path)
    prepare.add_argument("--root", required=True, type=Path)
    prepare.add_argument("--proxy-port", required=True, type=int)
    prepare.add_argument("--gateway-port", required=True, type=int)
    prepare.add_argument("--run-id", default=DEFAULT_RUN_ID)

    proxy = commands.add_parser("proxy")
    proxy.add_argument("--root", required=True, type=Path)
    proxy.add_argument("--listen-port", required=True, type=int)
    proxy.add_argument("--wallclock-seconds", type=int, default=900)

    summary = commands.add_parser("budget-summary")
    summary.add_argument("--ledger", required=True, type=Path)
    summary.add_argument("--output", required=True, type=Path)

    followup = commands.add_parser("plan-followup")
    followup.add_argument("--first-user-file", required=True, type=Path)
    followup.add_argument("--budget-tokens", type=int, default=784800)

    marked = commands.add_parser("build-prompt")
    marked.add_argument("--output", required=True, type=Path)
    marked.add_argument("--filler-unit", default=" the")
    marked.add_argument("--repetitions", required=True, type=int)

    feasibility = commands.add_parser("assess-filler")
    feasibility.add_argument("--filler-unit", default=" the")
    feasibility.add_argument("--first-units", required=True, type=int)
    feasibility.add_argument("--first-input-tokens", required=True, type=int)
    feasibility.add_argument("--second-units", required=True, type=int)
    feasibility.add_argument("--second-input-tokens", required=True, type=int)
    feasibility.add_argument("--target-input-tokens", type=int, default=770000)
    feasibility.add_argument("--budget-tokens", type=int, default=784800)

    direct = commands.add_parser("direct")
    direct.add_argument("--canonical-config", required=True, type=Path)
    direct.add_argument("--body", required=True, type=Path)
    direct.add_argument("--proxy-port", required=True, type=int)
    direct.add_argument("--receipt", required=True, type=Path)
    direct.add_argument("--timeout-seconds", type=int, default=370)

    native = commands.add_parser("native-sequence")
    native.add_argument("--canonical-config", required=True, type=Path)
    native.add_argument("--root", required=True, type=Path)
    native.add_argument("--prompt", required=True, type=Path)
    native.add_argument("--gateway-port", required=True, type=int)
    native.add_argument("--receipt", required=True, type=Path)
    native.add_argument("--budget-tokens", type=int, default=784800)

    daemon = commands.add_parser("exec-native-daemon")
    daemon.add_argument("--binary", required=True, type=Path)
    daemon.add_argument("--root", required=True, type=Path)
    daemon.add_argument("--gateway-port", required=True, type=int)
    return parser


def main() -> int:
    os.umask(0o077)
    args = _parser().parse_args()
    try:
        if args.command == "prepare":
            prepare_private_layout(
                args.canonical_config,
                args.root,
                proxy_port=args.proxy_port,
                gateway_port=args.gateway_port,
                run_id=args.run_id,
            )
            return 0
        if args.command == "proxy":
            if os.environ.get("CONTEXT_LOAD_BOUNDED") != "1":
                raise HarnessError("proxy must run in bounded transient unit")
            if not 1 <= args.wallclock_seconds <= 3600:
                raise HarnessError("invalid proxy wallclock")
            layout = _layout_from_root(args.root)
            ledger = QuotaLedger.open(layout.ledger_path)
            expected_capability = _read_capability(layout.config_path)
            server = build_proxy_server(
                bind=("127.0.0.1", args.listen_port),
                quota=ledger,
                receipt_path=layout.receipt_path,
                upstream=UpstreamEndpoint(*PRODUCTION_ADAPTER),
                expected_capability=expected_capability,
            )
            timer = threading.Timer(args.wallclock_seconds, server.shutdown)
            timer.daemon = True
            timer.start()
            try:
                server.serve_forever()
            finally:
                timer.cancel()
                server.server_close()
            return 0
        if args.command == "budget-summary":
            write_safe_budget_summary(QuotaLedger.open(args.ledger), args.output)
            return 0
        if args.command == "plan-followup":
            metadata = _require_private_regular(args.first_user_file, max_bytes=16 * 1024 * 1024)
            size = minimum_followup_bytes_for_trim(
                first_user_utf8_bytes=metadata.st_size,
                budget_tokens=args.budget_tokens,
            )
            print(json.dumps({
                "first_user_utf8_bytes": metadata.st_size,
                "followup_utf8_bytes": size,
                "fits_small_envelope": 0 < size <= FOLLOWUP_CONTENT_MAX,
                "estimate_label": "ZeroClaw bytes/4 lower-bound estimate; provider usage remains authoritative",
            }, sort_keys=True))
            return 0 if 0 < size <= FOLLOWUP_CONTENT_MAX else 2
        if args.command == "build-prompt":
            metadata = write_marked_prompt(
                args.output,
                filler_unit=args.filler_unit,
                repetitions=args.repetitions,
            )
            print(json.dumps(metadata, sort_keys=True))
            return 0
        if args.command == "assess-filler":
            decision = assess_filler_feasibility(
                filler_unit=args.filler_unit,
                first_units=args.first_units,
                first_input_tokens=args.first_input_tokens,
                second_units=args.second_units,
                second_input_tokens=args.second_input_tokens,
                target_input_tokens=args.target_input_tokens,
                budget_tokens=args.budget_tokens,
            )
            print(json.dumps(decision, sort_keys=True))
            return 0 if decision["feasible"] else 2
        if args.command == "direct":
            receipt = direct_request(
                canonical_path=args.canonical_config,
                body_path=args.body,
                proxy_port=args.proxy_port,
                timeout_seconds=args.timeout_seconds,
            )
            _write_safe_receipt(args.receipt, receipt)
            return 0 if receipt["accepted"] else 2
        if args.command == "native-sequence":
            receipt = run_native_sequence(
                canonical_path=args.canonical_config,
                run_root=args.root,
                prompt_path=args.prompt,
                gateway_port=args.gateway_port,
                receipt_path=args.receipt,
                budget_tokens=args.budget_tokens,
            )
            return 0 if receipt["passed"] else 2
        if args.command == "exec-native-daemon":
            if os.environ.get("CONTEXT_LOAD_BOUNDED") != "1":
                raise HarnessError("native daemon must run in bounded transient unit")
            layout = _layout_from_root(args.root)
            argv, env = native_daemon_command(args.binary, layout, gateway_port=args.gateway_port)
            os.execve(argv[0], argv, env)
            return 127
    except (HarnessError, OSError) as error:
        # Fixed-class errors only: never print paths, headers, bodies, or capabilities.
        print(f"context-load: {type(error).__name__}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
