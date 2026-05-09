"""LLM-driven contact-form filler with self-healing retries.

Flow:
  1. Open the form URL in Playwright.
  2. Trim the HTML to relevant elements (forms, inputs, labels, buttons).
  3. Ask Claude to plan the form-fill strategy (selectors + values).
  4. Execute the plan; if it fails, ask Claude for a different strategy
     (up to MAX_ATTEMPTS), passing the previous error.
  5. After submit, capture before/after text + URL + network log; ask Claude to
     verify success.
  6. Save screenshots before & after submit for the audit trail.

Dry-run mode:
  - Step 1-3 still run (so the user can review the planned strategy)
  - Steps 4-6 are skipped; nothing is submitted.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import claude_runner

PROMPTS_DIR = Path(__file__).parent / "prompts"
SCREENSHOTS_DIR = Path(__file__).resolve().parent.parent / "screenshots"

MAX_ATTEMPTS = 3
MAX_HTML_FOR_LLM = 18000


def _load_prompt(name: str) -> str:
    return (PROMPTS_DIR / f"{name}.md").read_text(encoding="utf-8")


def _trim_html_for_form(html: str) -> str:
    """Aggressively trim HTML so the LLM only sees form-relevant pieces."""
    # Drop scripts, styles, svg, head meta — keep body structure.
    h = re.sub(r"<script[\s\S]*?</script>", "", html, flags=re.IGNORECASE)
    h = re.sub(r"<style[\s\S]*?</style>", "", h, flags=re.IGNORECASE)
    h = re.sub(r"<svg[\s\S]*?</svg>", "", h, flags=re.IGNORECASE)
    h = re.sub(r"<!--[\s\S]*?-->", "", h)
    h = re.sub(r"\s+", " ", h)

    # Prefer the section between the first <form ...> and last </form>.
    forms = re.findall(r"<form[\s\S]*?</form>", h, flags=re.IGNORECASE)
    if forms:
        joined = "\n\n".join(forms)
        if len(joined) > MAX_HTML_FOR_LLM:
            joined = joined[:MAX_HTML_FOR_LLM] + " <!--truncated-->"
        return joined

    if len(h) > MAX_HTML_FOR_LLM:
        h = h[:MAX_HTML_FOR_LLM] + " <!--truncated-->"
    return h


@dataclass
class FillOutcome:
    success: bool
    confirmation: str | None = None
    error: str | None = None
    strategy: dict[str, Any] = field(default_factory=dict)
    attempts: int = 0
    screenshots: list[str] = field(default_factory=list)
    aborted: bool = False
    abort_reason: str | None = None


def _strategy_for_attempt(
    *,
    url: str,
    trimmed_html: str,
    visible_text: str,
    sender: dict[str, Any],
    message: str,
    subject: str | None,
    attempt: int,
    last_error: str | None,
) -> dict[str, Any]:
    payload = {
        "URL": url,
        "HTML_SNAPSHOT": trimmed_html,
        "VISIBLE_TEXT": visible_text[:2000],
        "SENDER": sender,
        "MESSAGE": message,
        "SUBJECT": subject,
        "ATTEMPT_NUMBER": attempt,
        "LAST_ERROR": last_error,
    }
    return claude_runner.ask_json(
        json.dumps(payload, ensure_ascii=False),
        system=_load_prompt("form_strategy"),
        timeout=90,
    )


def _verify(*, before_text: str, after_text: str, after_url: str, network: list[dict]) -> dict[str, Any]:
    payload = {
        "BEFORE_TEXT": before_text[:3000],
        "AFTER_TEXT": after_text[:3000],
        "AFTER_URL": after_url,
        "LAST_NETWORK": network[-10:],
    }
    return claude_runner.ask_json(
        json.dumps(payload, ensure_ascii=False),
        system=_load_prompt("verify_submission"),
        timeout=60,
    )


def _apply_strategy(page, strategy: dict[str, Any]) -> None:
    """Execute the LLM-proposed plan against the live page."""
    for field_plan in strategy.get("fields") or []:
        sel = field_plan.get("selector")
        kind = (field_plan.get("kind") or "text").lower()
        value = field_plan.get("value")
        if not sel:
            continue
        loc = page.locator(sel).first
        loc.wait_for(state="visible", timeout=5000)
        if kind in {"checkbox"}:
            if value in (True, "true", "check", "on", 1, "1"):
                loc.check()
            continue
        if kind in {"radio"}:
            loc.check()
            continue
        if kind == "select":
            try:
                loc.select_option(label=value)
            except Exception:  # noqa: BLE001
                loc.select_option(value=value)
            continue
        # default: text/email/tel/textarea/name/company
        loc.fill("")
        loc.type(str(value), delay=15)

    for sel in strategy.get("consent_selectors") or []:
        try:
            page.locator(sel).first.check(timeout=2000)
        except Exception:  # noqa: BLE001
            pass


def fill_and_submit(
    *,
    lead_id: int,
    url: str,
    sender: dict[str, Any],
    message: str,
    subject: str | None,
    dry_run: bool,
) -> FillOutcome:
    from playwright.sync_api import sync_playwright  # local import (heavy)

    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    outcome = FillOutcome(success=False)

    network_log: list[dict[str, Any]] = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
            ),
            locale="en-US",
        )
        page = ctx.new_page()

        def _on_response(resp):
            try:
                if resp.request.method in ("POST", "PUT") and resp.status:
                    body = ""
                    try:
                        body = resp.text()[:400]
                    except Exception:  # noqa: BLE001
                        body = "<binary>"
                    network_log.append({
                        "url": resp.url,
                        "status": resp.status,
                        "method": resp.request.method,
                        "body": body,
                    })
            except Exception:  # noqa: BLE001
                pass

        page.on("response", _on_response)

        try:
            page.goto(url, timeout=25000, wait_until="domcontentloaded")
            try:
                page.wait_for_load_state("networkidle", timeout=4000)
            except Exception:  # noqa: BLE001
                pass

            html = page.content()
            visible = page.evaluate("() => document.body ? document.body.innerText : ''") or ""
            trimmed = _trim_html_for_form(html)

            last_error: str | None = None
            strategy: dict[str, Any] = {}
            for attempt in range(1, MAX_ATTEMPTS + 1):
                outcome.attempts = attempt
                strategy = _strategy_for_attempt(
                    url=url,
                    trimmed_html=trimmed,
                    visible_text=visible,
                    sender=sender,
                    message=message,
                    subject=subject,
                    attempt=attempt,
                    last_error=last_error,
                )
                outcome.strategy = strategy

                if strategy.get("abort"):
                    outcome.aborted = True
                    outcome.abort_reason = strategy.get("abort_reason") or "LLM aborted"
                    break

                captcha = strategy.get("captcha") or "none"
                if captcha not in ("none", "unknown"):
                    outcome.aborted = True
                    outcome.abort_reason = f"captcha required: {captcha}"
                    break

                if dry_run:
                    # We have the plan; do not interact with the page.
                    outcome.success = False
                    outcome.error = "dry-run"
                    return outcome

                # Screenshot before any interaction
                shot_before = SCREENSHOTS_DIR / f"lead{lead_id}-{ts}-attempt{attempt}-before.png"
                try:
                    page.screenshot(path=str(shot_before), full_page=True)
                    outcome.screenshots.append(str(shot_before))
                except Exception:  # noqa: BLE001
                    pass

                try:
                    _apply_strategy(page, strategy)
                except Exception as exc:  # noqa: BLE001
                    last_error = f"apply failed: {exc}"
                    continue

                before_text = page.evaluate("() => document.body.innerText") or ""

                submit_sel = strategy.get("submit_selector")
                if not submit_sel:
                    last_error = "no submit selector proposed"
                    continue
                try:
                    page.locator(submit_sel).first.click(timeout=5000)
                except Exception as exc:  # noqa: BLE001
                    last_error = f"submit click failed: {exc}"
                    continue

                # Give the site a moment to react.
                try:
                    page.wait_for_load_state("networkidle", timeout=6000)
                except Exception:  # noqa: BLE001
                    pass

                shot_after = SCREENSHOTS_DIR / f"lead{lead_id}-{ts}-attempt{attempt}-after.png"
                try:
                    page.screenshot(path=str(shot_after), full_page=True)
                    outcome.screenshots.append(str(shot_after))
                except Exception:  # noqa: BLE001
                    pass

                after_text = page.evaluate("() => document.body.innerText") or ""
                verdict = _verify(
                    before_text=before_text,
                    after_text=after_text,
                    after_url=page.url,
                    network=network_log,
                )

                if verdict.get("success"):
                    outcome.success = True
                    outcome.confirmation = verdict.get("confirmation_excerpt")
                    return outcome

                last_error = verdict.get("reason_if_failed") or "verification failed"

            # All attempts exhausted
            outcome.error = last_error or "no attempts executed"
        finally:
            ctx.close()
            browser.close()

    return outcome
