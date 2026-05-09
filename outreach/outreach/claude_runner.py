"""Thin wrapper around the Claude CLI (`claude -p ...`).

Why CLI and not the Anthropic SDK: the user already has `claude` authenticated
locally, so we don't have to manage API keys. We invoke `claude -p` in
non-interactive mode, ask for `--output-format json` for parsable answers, and
parse out the `result` field.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ClaudeError(RuntimeError):
    pass


@dataclass
class ClaudeResult:
    text: str
    raw: dict[str, Any] | None


def _bin() -> str:
    return os.environ.get("CLAUDE_BIN", "claude")


def ensure_available() -> str:
    path = shutil.which(_bin())
    if not path:
        raise ClaudeError(
            f"Claude CLI '{_bin()}' not found on PATH. "
            "Install it or set CLAUDE_BIN in .env."
        )
    return path


def ask(
    prompt: str,
    *,
    system: str | None = None,
    timeout: int = 180,
    cwd: Path | None = None,
    allowed_tools: list[str] | None = None,
) -> ClaudeResult:
    """Run a single non-interactive Claude prompt and return its text result.

    Pass ``allowed_tools=["WebSearch", "WebFetch"]`` for calls that need to
    research the live web (e.g. recent fleet news). For pure-text reasoning,
    leave it None — the CLI will run with no tools and finish faster.
    """
    ensure_available()
    cmd = [_bin(), "-p", "--output-format", "json"]
    if system:
        cmd.extend(["--append-system-prompt", system])
    model = os.environ.get("CLAUDE_MODEL")
    if model:
        cmd.extend(["--model", model])
    if allowed_tools:
        cmd.extend(["--allowedTools", ",".join(allowed_tools)])
    cmd.append(prompt)

    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ClaudeError(f"Claude CLI timed out after {timeout}s") from exc

    if proc.returncode != 0:
        raise ClaudeError(
            f"Claude CLI exited with {proc.returncode}: {proc.stderr.strip()[:500]}"
        )

    stdout = proc.stdout.strip()
    if not stdout:
        raise ClaudeError("Claude CLI returned empty output")

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        # Some CLI versions stream multiple JSON lines; take the last full doc.
        last = stdout.splitlines()[-1]
        try:
            payload = json.loads(last)
        except json.JSONDecodeError as exc:
            raise ClaudeError(
                f"Claude CLI did not return JSON: {stdout[:300]}"
            ) from exc

    text = (
        payload.get("result")
        or payload.get("output")
        or payload.get("text")
        or ""
    )
    if not text and isinstance(payload, dict):
        # As a last resort, dump the dict — caller can still parse.
        text = json.dumps(payload, ensure_ascii=False)
    return ClaudeResult(text=text.strip(), raw=payload if isinstance(payload, dict) else None)


def ask_json(
    prompt: str,
    *,
    system: str | None = None,
    timeout: int = 180,
    allowed_tools: list[str] | None = None,
) -> dict[str, Any]:
    """Run a prompt that must return JSON; parse it leniently."""
    extra = (
        "Respond with VALID JSON only, no prose, no markdown fences. "
        "If you cannot comply, return {\"error\": \"<short reason>\"}."
    )
    sys_prompt = f"{system}\n\n{extra}" if system else extra
    res = ask(prompt, system=sys_prompt, timeout=timeout, allowed_tools=allowed_tools)
    text = res.text.strip()

    # Strip code fences if the model added them anyway
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
        text = text.strip()
        # remove trailing fence
        if text.endswith("```"):
            text = text[:-3].strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        # Try to locate a JSON object inside the text
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end > start:
            snippet = text[start : end + 1]
            try:
                return json.loads(snippet)
            except json.JSONDecodeError:
                pass
        raise ClaudeError(
            f"Claude returned non-JSON: {res.text[:300]}"
        ) from exc
