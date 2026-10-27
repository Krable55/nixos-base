#!/usr/bin/env python3
"""Validate a ZeroClaw web/dist tree and optionally its live gateway URL."""

from __future__ import annotations

import argparse
import html.parser
import json
import pathlib
import urllib.parse
import urllib.request


class References(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.refs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "script" and values.get("src"):
            self.refs.append(values["src"] or "")
        if tag == "link" and values.get("href"):
            self.refs.append(values["href"] or "")


def parse_refs(index: bytes) -> list[str]:
    parser = References()
    parser.feed(index.decode("utf-8"))
    return [ref for ref in parser.refs if ref.startswith("/_app/")]


def check_tree(root: pathlib.Path) -> dict[str, object]:
    index_path = root / "index.html"
    index = index_path.read_bytes()
    refs = parse_refs(index)
    if not refs:
        raise SystemExit("index.html has no /_app/ references")
    missing: list[str] = []
    empty: list[str] = []
    for ref in refs:
        path = root / ref.removeprefix("/_app/")
        if not path.is_file():
            missing.append(ref)
        elif path.stat().st_size == 0:
            empty.append(ref)
    if missing or empty:
        raise SystemExit(f"bad references: missing={missing!r} empty={empty!r}")
    suffixes = {pathlib.PurePosixPath(ref).suffix for ref in refs}
    if not {".js", ".css"}.issubset(suffixes):
        raise SystemExit(f"expected referenced JS and CSS, got {sorted(suffixes)!r}")
    all_files = [path for path in root.rglob("*") if path.is_file()]
    return {
        "index_bytes": len(index),
        "referenced_assets": refs,
        "files": len(all_files),
        "bytes": sum(path.stat().st_size for path in all_files),
    }


def fetch(url: str) -> tuple[int, str, bytes]:
    request = urllib.request.Request(url, headers={"User-Agent": "zeroclaw-web-acceptance"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status, response.headers.get_content_type(), response.read()


def check_live(base_url: str) -> dict[str, object]:
    base = base_url.rstrip("/") + "/"
    status, content_type, index = fetch(base)
    if status != 200 or content_type != "text/html":
        raise SystemExit(f"bad root response: {status} {content_type}")
    refs = parse_refs(index)
    if not refs:
        raise SystemExit("live index has no /_app/ references")
    fetched: list[dict[str, object]] = []
    for ref in refs:
        url = urllib.parse.urljoin(base, ref.lstrip("/"))
        asset_status, asset_type, body = fetch(url)
        if asset_status != 200 or not body:
            raise SystemExit(f"bad live asset: {ref} {asset_status} {len(body)}")
        fetched.append({"path": ref, "content_type": asset_type, "bytes": len(body)})
    return {"root_status": status, "root_content_type": content_type, "assets": fetched}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("dist", type=pathlib.Path)
    parser.add_argument("--url")
    args = parser.parse_args()
    result: dict[str, object] = {"tree": check_tree(args.dist)}
    if args.url:
        result["live"] = check_live(args.url)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
