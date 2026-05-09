"""Deep per-lead research.

For each lead we want to understand:
- What they actually do (business model, fleet size).
- What brands they currently operate / sell.
- What pain points open the door for our Chinese-vehicle offer.
- Which specific models from our portfolio match their use case.
- What recent news (acquisitions, BBBEE, electrification, fleet renewal)
  gives us a personalisation hook.

Strategy:
1. Playwright fetches the homepage + a handful of "interesting" pages
   (about / leadership / press / news / contact) using simple link heuristics.
2. Claude is invoked with WebSearch + WebFetch enabled to look up recent
   industry news, BBBEE status, fleet announcements.
3. The combined snapshot is sent to the deep_research prompt; Claude returns
   structured JSON describing the lead.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse

from . import claude_runner

PROMPTS_DIR = Path(__file__).parent / "prompts"

MAX_PAGE_TEXT = 6000          # chars of the homepage we keep
MAX_EXTRA_PAGE_TEXT = 3000    # per extra page
MAX_EXTRA_PAGES = 4           # how many extra pages we crawl


def _load_prompt(name: str) -> str:
    return (PROMPTS_DIR / f"{name}.md").read_text(encoding="utf-8")


@dataclass
class SiteSnapshot:
    home_url: str
    final_url: str
    home_text: str
    extra_pages: dict[str, str]


_INTERESTING_LINK_HINTS = (
    "about", "company", "leadership", "team", "executive", "management",
    "press", "news", "media", "blog", "investor", "annual",
    "fleet", "sustainability", "bbbee", "transformation",
    "о-нас", "про-нас", "наша-команда",
    "kontakt", "kohta", "kontakti",
)


def _trim_text(text: str, limit: int) -> str:
    text = re.sub(r"\n{3,}", "\n\n", text or "").strip()
    if len(text) > limit:
        text = text[:limit] + "\n…[truncated]"
    return text


def fetch_site(url: str, timeout_ms: int = 20000) -> SiteSnapshot:
    """Fetch homepage + up to MAX_EXTRA_PAGES interesting sub-pages."""
    from playwright.sync_api import sync_playwright

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

            home_text = page.evaluate(
                "() => document.body ? document.body.innerText : ''"
            ) or ""
            home_html = page.content()
            final_url = page.url

            base_host = urlparse(final_url).netloc.lower()
            picked: list[tuple[str, str]] = []
            seen: set[str] = set()
            for href, label in re.findall(
                r'<a[^>]+href="([^"]+)"[^>]*>([^<]{0,120})</a>',
                home_html,
                flags=re.IGNORECASE,
            ):
                blob = (href + " " + label).lower()
                if not any(h in blob for h in _INTERESTING_LINK_HINTS):
                    continue
                full = urljoin(final_url, href).split("#")[0]
                if full in seen:
                    continue
                if urlparse(full).netloc.lower() not in {"", base_host}:
                    continue
                if any(full.lower().endswith(ext) for ext in
                       (".pdf", ".jpg", ".jpeg", ".png", ".zip", ".mp4")):
                    continue
                seen.add(full)
                picked.append((full, label.strip()))
                if len(picked) >= MAX_EXTRA_PAGES:
                    break

            extra: dict[str, str] = {}
            for sub_url, _label in picked:
                try:
                    page.goto(sub_url, timeout=timeout_ms, wait_until="domcontentloaded")
                    sub_text = page.evaluate(
                        "() => document.body ? document.body.innerText : ''"
                    ) or ""
                    extra[sub_url] = _trim_text(sub_text, MAX_EXTRA_PAGE_TEXT)
                except Exception:  # noqa: BLE001
                    continue

            return SiteSnapshot(
                home_url=url,
                final_url=final_url,
                home_text=_trim_text(home_text, MAX_PAGE_TEXT),
                extra_pages=extra,
            )
        finally:
            ctx.close()
            browser.close()


def deep_research(lead: dict[str, Any]) -> dict[str, Any]:
    """Run the full research pipeline for one lead."""
    url = lead.get("website") or lead.get("form_url")
    if not url:
        return {
            "skip": True,
            "skip_reason": "no website",
            "research_confidence": "low",
        }

    try:
        snap = fetch_site(url)
    except Exception as exc:  # noqa: BLE001
        return {
            "skip": True,
            "skip_reason": f"site fetch failed: {exc}",
            "research_confidence": "low",
        }

    payload = {
        "LEAD": {
            "company": lead.get("company"),
            "category": lead.get("category"),
            "priority": lead.get("priority"),
            "hq_city": lead.get("hq_city"),
            "contact_name": lead.get("contact_name"),
            "contact_role": lead.get("contact_role"),
            "notes": lead.get("notes"),
            "website": lead.get("website"),
            "form_url": lead.get("form_url"),
        },
        "HOMEPAGE_TEXT": snap.home_text,
        "EXTRA_PAGES": snap.extra_pages,
    }
    result = claude_runner.ask_json(
        json.dumps(payload, ensure_ascii=False),
        system=_load_prompt("deep_research"),
        timeout=240,
        allowed_tools=["WebSearch", "WebFetch"],
    )
    result.setdefault("_snapshot", {
        "home_url": snap.final_url,
        "extra_urls": list(snap.extra_pages.keys()),
    })
    return result
