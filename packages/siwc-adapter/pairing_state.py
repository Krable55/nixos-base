#!/usr/bin/env python3
"""Persist only ZeroClaw gateway paired-token hashes.

Success is silent. Validation failures deliberately omit values and file contents.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import tomllib

import tomli_w  # type: ignore[import-not-found]

STORE_VERSION = 1
MAX_STORE_BYTES = 64 * 1024
MAX_RUNTIME_BYTES = 2 * 1024 * 1024
MAX_PAIRED_TOKENS = 256
HASH_RE = re.compile(r"[0-9a-f]{64}\Z")


class PairingStateError(RuntimeError):
    pass


def _open_parent(path: Path) -> tuple[int, str]:
    path = Path(path)
    if not path.is_absolute() or path.name in {"", ".", ".."}:
        raise PairingStateError("invalid path")
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        directory_fd = os.open(path.parent, flags)
    except OSError as error:
        raise PairingStateError("unsafe parent directory") from error
    metadata = os.fstat(directory_fd)
    if not stat.S_ISDIR(metadata.st_mode):
        os.close(directory_fd)
        raise PairingStateError("unsafe parent directory")
    if metadata.st_uid not in {0, os.geteuid()}:
        os.close(directory_fd)
        raise PairingStateError("unsafe parent ownership")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        os.close(directory_fd)
        raise PairingStateError("unsafe parent mode")
    return directory_fd, path.name


def _validate_file_metadata(metadata: os.stat_result) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        raise PairingStateError("unsafe file type")
    if metadata.st_uid != os.geteuid() or metadata.st_gid != os.getegid():
        raise PairingStateError("unsafe file ownership")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise PairingStateError("unsafe file mode")


def _read_secure(path: Path, limit: int, *, missing_ok: bool = False) -> bytes | None:
    directory_fd, name = _open_parent(path)
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        try:
            file_fd = os.open(name, flags, dir_fd=directory_fd)
        except FileNotFoundError:
            if missing_ok:
                return None
            raise PairingStateError("required file missing") from None
        except OSError as error:
            raise PairingStateError("unsafe file open") from error
        try:
            metadata = os.fstat(file_fd)
            _validate_file_metadata(metadata)
            if metadata.st_size > limit:
                raise PairingStateError("file too large")
            chunks: list[bytes] = []
            remaining = limit + 1
            while remaining:
                chunk = os.read(file_fd, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) > limit:
                raise PairingStateError("file too large")
            return data
        finally:
            os.close(file_fd)
    finally:
        os.close(directory_fd)


def _validate_existing_target(directory_fd: int, name: str) -> None:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        file_fd = os.open(name, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        return
    except OSError as error:
        raise PairingStateError("unsafe target open") from error
    try:
        _validate_file_metadata(os.fstat(file_fd))
    finally:
        os.close(file_fd)


def _atomic_write(path: Path, data: bytes) -> None:
    directory_fd, name = _open_parent(path)
    temporary_name = f".{name}.tmp-{os.getpid()}-{secrets.token_hex(8)}"
    temporary_fd: int | None = None
    try:
        _validate_existing_target(directory_fd, name)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        temporary_fd = os.open(temporary_name, flags, 0o600, dir_fd=directory_fd)
        os.fchmod(temporary_fd, 0o600)
        view = memoryview(data)
        while view:
            written = os.write(temporary_fd, view)
            if written <= 0:
                raise PairingStateError("short write")
            view = view[written:]
        os.fsync(temporary_fd)
        os.close(temporary_fd)
        temporary_fd = None
        os.replace(
            temporary_name,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        os.fsync(directory_fd)
    except OSError as error:
        raise PairingStateError("atomic write failed") from error
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        finally:
            os.close(directory_fd)


def _decode_runtime(data: bytes) -> dict:
    try:
        document = tomllib.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise PairingStateError("invalid runtime configuration") from error
    if not isinstance(document, dict):
        raise PairingStateError("invalid runtime configuration")
    return document


def _api_key(document: dict) -> str:
    try:
        value = document["providers"]["models"]["openai"]["siwc"]["api_key"]
    except (KeyError, TypeError) as error:
        raise PairingStateError("canonical api key missing") from error
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise PairingStateError("canonical api key invalid")
    return value


def _validate_hashes(values: object, api_key: str) -> list[str]:
    if not isinstance(values, list) or len(values) > MAX_PAIRED_TOKENS:
        raise PairingStateError("paired token set invalid")
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str) or HASH_RE.fullmatch(value) is None:
            raise PairingStateError("paired token hash invalid")
        if value == api_key:
            raise PairingStateError("paired token hash aliases canonical api key")
        if value in seen:
            raise PairingStateError("duplicate paired token hash")
        seen.add(value)
        result.append(value)
    return sorted(result)


def _runtime_hashes(document: dict, canonical_api_key: str) -> list[str]:
    _api_key(document)
    gateway = document.get("gateway")
    if not isinstance(gateway, dict):
        raise PairingStateError("gateway configuration missing")
    return _validate_hashes(gateway.get("paired_tokens", []), canonical_api_key)


def _decode_store(data: bytes, api_key: str) -> list[str]:
    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PairingStateError("invalid pairing store") from error
    if not isinstance(document, dict) or set(document) != {"version", "paired_tokens"}:
        raise PairingStateError("invalid pairing store schema")
    if type(document["version"]) is not int or document["version"] != STORE_VERSION:
        raise PairingStateError("unsupported pairing store version")
    return _validate_hashes(document["paired_tokens"], api_key)


def _encode_store(hashes: list[str]) -> bytes:
    return (
        json.dumps(
            {"version": STORE_VERSION, "paired_tokens": hashes},
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def merge(runtime_config: Path, store: Path, canonical_config: Path) -> None:
    runtime_data = _read_secure(Path(runtime_config), MAX_RUNTIME_BYTES)
    assert runtime_data is not None
    runtime_document = _decode_runtime(runtime_data)
    canonical_data = _read_secure(Path(canonical_config), MAX_RUNTIME_BYTES)
    assert canonical_data is not None
    canonical_api_key = _api_key(_decode_runtime(canonical_data))
    _runtime_hashes(runtime_document, canonical_api_key)
    store_data = _read_secure(Path(store), MAX_STORE_BYTES, missing_ok=True)
    hashes = [] if store_data is None else _decode_store(store_data, canonical_api_key)
    gateway = runtime_document["gateway"]
    gateway["paired_tokens"] = hashes
    rendered = tomli_w.dumps(runtime_document).encode("utf-8")
    if len(rendered) > MAX_RUNTIME_BYTES:
        raise PairingStateError("rendered runtime configuration too large")
    _atomic_write(Path(runtime_config), rendered)


def snapshot(runtime_config: Path, store: Path, canonical_config: Path) -> None:
    runtime_data = _read_secure(Path(runtime_config), MAX_RUNTIME_BYTES)
    assert runtime_data is not None
    runtime_document = _decode_runtime(runtime_data)
    canonical_data = _read_secure(Path(canonical_config), MAX_RUNTIME_BYTES)
    assert canonical_data is not None
    canonical_api_key = _api_key(_decode_runtime(canonical_data))
    hashes = _runtime_hashes(runtime_document, canonical_api_key)
    _atomic_write(Path(store), _encode_store(hashes))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pi4-zeroclaw-pairing-state")
    parser.add_argument("action", choices=("merge", "snapshot"))
    parser.add_argument("--runtime-config", required=True, type=Path)
    parser.add_argument("--canonical-config", required=True, type=Path)
    parser.add_argument("--store", required=True, type=Path)
    return parser


def main() -> int:
    os.umask(0o077)
    arguments = _parser().parse_args()
    try:
        if arguments.action == "merge":
            merge(arguments.runtime_config, arguments.store, arguments.canonical_config)
        else:
            snapshot(arguments.runtime_config, arguments.store, arguments.canonical_config)
    except PairingStateError:
        print("pi4-zeroclaw-pairing-state: validation failed", file=sys.stderr)
        return 1
    except Exception:
        print("pi4-zeroclaw-pairing-state: operation failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
