"""LLM-driven site analysis + offer personalization."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

from . import claude_runner

PROMPTS_DIR = Path(__file__).parent / "prompts"

MAX_PAGE_TEXT = 6000  # chars sent to Claude


def _load_prompt(name: str) -> str:
    return (PROMPTS_DIR / f"{name}.md").read_text(encoding="utf-8")


@dataclass
class SiteSnapshot:
    url: str
    text: str
    html: str
    final_url: str


def fetch_site_snapshot(url: str, timeout_ms: int = 20000) -> SiteSnapshot:
    """Render the page in Playwright and return trimmed text + HTML."""
    from playwright.sync_api import sync_playwright  # local import (heavy)

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
        try:
            page.goto(url, timeout=timeout_ms, wait_until="domcontentloaded")
            try:
                page.wait_for_load_state("networkidle", timeout=4000)
            except Exception:  # noqa: BLE001
                pass
            html = page.content()
            text = page.evaluate(
                "() => document.body ? document.body.innerText : ''"
            ) or ""
            final_url = page.url
        finally:
            ctx.close()
            browser.close()

    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if len(text) > MAX_PAGE_TEXT:
        text = text[:MAX_PAGE_TEXT] + "\n…[truncated]"
    return SiteSnapshot(url=url, text=text, html=html, final_url=final_url)


def find_contact_url(home_url: str, html: str) -> str | None:
    """Heuristic: scan anchors for a 'contact' link."""
    needles = ("contact", "kontakt", "контакт", "yhteys", "kontakti")
    matches = re.findall(
        r'<a[^>]+href="([^"]+)"[^>]*>([^<]{0,80})</a>',
        html,
        flags=re.IGNORECASE,
    )
    for href, text in matches:
        blob = f"{href} {text}".lower()
        if any(n in blob for n in needles):
            return urljoin(home_url, href)
    return None


def analyze_site(lead: dict[str, Any]) -> dict[str, Any]:
    """Return structured analysis dict for a lead. Caller persists it."""
    url = lead.get("website") or lead.get("form_url")
    if not url:
        return {
            "error": "no website",
            "language": None,
            "summary": None,
        }

    snap = fetch_site_snapshot(url)
    prompt_input = {
        "company_name_hint": lead.get("company"),
        "url": snap.final_url,
        "page_text": snap.text,
    }
    payload = claude_runner.ask_json(
        json.dumps(prompt_input, ensure_ascii=False),
        system=_load_prompt("analyze_site"),
        timeout=120,
    )
    payload["_snapshot_url"] = snap.final_url
    return payload


def personalize_offer(
    lead: dict[str, Any],
    analysis: dict[str, Any],
    sender: dict[str, Any],
    base_offer: str,
    *,
    channel: str = "form",
) -> dict[str, Any]:
    prompt_input = {
        "BASE_OFFER": base_offer,
        "LEAD": {
            "company": lead.get("company"),
            "website": lead.get("website"),
            "category": lead.get("category"),
            "priority": lead.get("priority"),
            "hq_city": lead.get("hq_city"),
            "contact_name": lead.get("contact_name"),
            "contact_role": lead.get("contact_role"),
            "notes": lead.get("notes"),
            "industry": analysis.get("industry"),
            "summary": analysis.get("summary"),
            "language": analysis.get("language"),
            "audience": analysis.get("audience"),
            "personalization_hooks": analysis.get("personalization_hooks") or [],
            "red_flags": analysis.get("red_flags") or [],
        },
        "SENDER": sender,
        "CONTEXT": {"channel": channel, "max_chars": 1500 if channel == "form" else 1800},
    }
    return claude_runner.ask_json(
        json.dumps(prompt_input, ensure_ascii=False),
        system=_load_prompt("personalize_offer"),
        timeout=90,
    )
