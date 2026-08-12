#!/usr/bin/env python3
"""Exercise the local OpenAI-compatible endpoint with real UTF-8 bytes.

This deliberately avoids PowerShell's native string-body encoding path.  It
tests both JSON responses and SSE streaming, including multibyte characters
that can be split across HTTP chunks.
"""

from __future__ import annotations

import argparse
import codecs
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def configure_utf8_console() -> None:
    """Keep Windows PowerShell output from falling back to an ANSI code page."""

    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="backslashreplace")


configure_utf8_console()


CASES: dict[str, dict[str, Any]] = {
    "japanese_capital": {
        "prompt": "日本の首都はどこですか。答えは都市名だけにしてください。",
        "expected": ["東京"],
        "max_tokens": 16,
    },
    "cjk_echo": {
        "prompt": "次の文字列をそのまま一度だけ返してください: 東京・大阪 / 中文 / 한국어 / 😀",
        "expected": ["東京・大阪", "中文", "한국어", "😀"],
        "max_tokens": 48,
    },
    "json_japanese": {
        "prompt": '次のJSONだけを返してください: {"都市":"東京","国":"日本"}',
        "expected": ["都市", "東京", "国", "日本"],
        "max_tokens": 48,
    },
    "emoji": {
        "prompt": "次の文字列だけを返してください: 😀🚀",
        "expected": ["😀🚀"],
        "max_tokens": 16,
    },
    "ascii_control": {
        "prompt": "Reply with exactly OK.",
        "expected": ["OK"],
        "max_tokens": 16,
    },
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def endpoint(base_url: str, suffix: str) -> str:
    return f"{base_url.rstrip('/')}/{suffix.lstrip('/')}"


def make_opener() -> urllib.request.OpenerDirector:
    # A local smoke test must not accidentally go through a corporate proxy.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def post_json(
    opener: urllib.request.OpenerDirector,
    url: str,
    body: dict[str, Any],
    timeout: float,
) -> tuple[dict[str, Any], float, str]:
    payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": "Bearer not-needed",
        },
    )
    started = time.perf_counter()
    with opener.open(request, timeout=timeout) as response:
        raw = response.read()
        elapsed = time.perf_counter() - started
        text = raw.decode("utf-8")
        return json.loads(text), elapsed, response.headers.get("content-type", "")


def post_stream(
    opener: urllib.request.OpenerDirector,
    url: str,
    body: dict[str, Any],
    timeout: float,
) -> tuple[str, float, str, bool]:
    payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Accept": "text/event-stream",
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": "Bearer not-needed",
        },
    )
    started = time.perf_counter()
    content: list[str] = []
    content_type = ""
    saw_done = False
    decoder = codecs.getincrementaldecoder("utf-8")()
    pending = ""
    with opener.open(request, timeout=timeout) as response:
        content_type = response.headers.get("content-type", "")
        while True:
            chunk = response.read(4096)
            if not chunk:
                break
            pending += decoder.decode(chunk)
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                line = line.rstrip("\r")
                if not line.startswith("data: "):
                    continue
                event = line[6:]
                if event == "[DONE]":
                    saw_done = True
                    continue
                data = json.loads(event)
                choices = data.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                value = delta.get("content")
                if isinstance(value, str):
                    content.append(value)
        pending += decoder.decode(b"", final=True)
        if pending.strip():
            # The server normally ends each SSE event with a newline.  Keep
            # strict UTF-8 validation even for a final unterminated event.
            for line in pending.splitlines():
                if line.startswith("data: ") and line[6:] != "[DONE]":
                    json.loads(line[6:])
    return "".join(content), time.perf_counter() - started, content_type, saw_done


def extract_content(data: dict[str, Any]) -> str:
    choices = data.get("choices") or []
    if not choices:
        return ""
    message = choices[0].get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and isinstance(block.get("text"), str)
        )
    return ""


def evaluate(content: str, expected: list[str]) -> tuple[bool, list[str]]:
    missing = [token for token in expected if token not in content]
    bad_markers = [marker for marker in ("�", "???", "����") if marker in content]
    return not missing and not bad_markers, missing + bad_markers


def discover_models(opener: urllib.request.OpenerDirector, base_url: str, timeout: float) -> list[str]:
    request = urllib.request.Request(
        endpoint(base_url, "/models"),
        method="GET",
        headers={"Accept": "application/json"},
    )
    with opener.open(request, timeout=timeout) as response:
        data = json.loads(response.read().decode("utf-8"))
    models = data.get("data") or []
    return [str(item["id"]) for item in models if isinstance(item, dict) and item.get("id")]


def run_case(
    opener: urllib.request.OpenerDirector,
    base_url: str,
    model: str,
    name: str,
    case: dict[str, Any],
    mode: str,
    timeout: float,
) -> dict[str, Any]:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": case["prompt"]}],
        "temperature": 0,
        "max_tokens": case["max_tokens"],
        "chat_template_kwargs": {"enable_thinking": False},
        "stream": mode == "stream",
    }
    result: dict[str, Any] = {
        "timestamp": utc_now(),
        "model": model,
        "case": name,
        "mode": mode,
        "prompt": case["prompt"],
    }
    try:
        if mode == "stream":
            content, elapsed, content_type, saw_done = post_stream(
                opener, endpoint(base_url, "/chat/completions"), body, timeout
            )
            result["saw_done"] = saw_done
        else:
            data, elapsed, content_type = post_json(
                opener, endpoint(base_url, "/chat/completions"), body, timeout
            )
            content = extract_content(data)
        passed, issues = evaluate(content, case["expected"])
        result.update(
            {
                "status": "pass" if passed else "fail",
                "content": content,
                "expected": case["expected"],
                "issues": issues,
                "elapsed_seconds": round(elapsed, 3),
                "content_type": content_type,
            }
        )
    except (UnicodeDecodeError, json.JSONDecodeError, urllib.error.URLError, TimeoutError) as exc:
        result.update(
            {
                "status": "error",
                "content": "",
                "issues": [f"{type(exc).__name__}: {exc}"],
            }
        )
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080/v1")
    parser.add_argument("--model", action="append", dest="models", help="Model id; repeat for multiple models")
    parser.add_argument("--case", action="append", choices=sorted(CASES), dest="cases")
    parser.add_argument("--mode", choices=("both", "nonstream", "stream"), default="both")
    parser.add_argument("--timeout-sec", type=float, default=180)
    parser.add_argument("--output-path", type=Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    opener = make_opener()
    if args.models:
        models = args.models
    else:
        try:
            models = discover_models(opener, args.base_url, args.timeout_sec)
        except Exception as exc:
            print(f"ERROR model discovery: {type(exc).__name__}: {exc}", file=sys.stderr)
            return 2
    if not models:
        print("ERROR no models found", file=sys.stderr)
        return 2

    case_names = args.cases or list(CASES)
    modes = ["nonstream", "stream"] if args.mode == "both" else [args.mode]
    root = Path(__file__).resolve().parents[1]
    output_path = args.output_path or (root / "mcp-data" / "utf8-smoke-results.jsonl")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    results: list[dict[str, Any]] = []
    for model in models:
        for name in case_names:
            for mode in modes:
                result = run_case(
                    opener,
                    args.base_url,
                    model,
                    name,
                    CASES[name],
                    mode,
                    args.timeout_sec,
                )
                results.append(result)
                print(
                    f"{result['status'].upper():5} model={model} case={name} mode={mode} "
                    f"content={result.get('content', '')!r}"
                )

    with output_path.open("a", encoding="utf-8", newline="\n") as handle:
        for result in results:
            handle.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    failures = [result for result in results if result["status"] != "pass"]
    print(f"SUMMARY models={len(models)} cases={len(results)} failures={len(failures)} report={output_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
