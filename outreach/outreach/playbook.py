"""Render a per-lead conversation playbook as readable Markdown.

This is the human-review surface: before any cold message goes out, the
operator opens ``playbooks/leadNN-<slug>.md`` and reads what we plan to send,
which objections we are prepared for, what the follow-ups look like.
"""
from __future__ import annotations

import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from textwrap import indent

from . import db

ROOT = Path(__file__).resolve().parent.parent
PLAYBOOKS_DIR = ROOT / "playbooks"


def _slug(s: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower() or "lead"


def _safe_load(text: str | None) -> dict:
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {}


def render_lead(lead: sqlite3.Row, history: list[sqlite3.Row]) -> str:
    research = _safe_load(lead["research"])
    plan = _safe_load(lead["conversation"])

    lines: list[str] = []
    lines.append(f"# Lead {lead['id']} — {lead['company']}")
    lines.append("")
    lines.append(
        f"**Category:** {lead['category'] or '?'}  ·  "
        f"**Priority:** {lead['priority'] or '?'}  ·  "
        f"**Channel:** {lead['channel'] or '?'}  ·  "
        f"**Status:** {lead['status']}"
    )
    if lead["website"] or lead["form_url"]:
        lines.append(
            f"**Website:** {lead['website'] or '—'}  ·  "
            f"**Form:** {lead['form_url'] or '—'}"
        )
    if lead["contact_name"]:
        lines.append(
            f"**Primary contact:** {lead['contact_name']} "
            f"({lead['contact_role'] or '?'})"
        )
    if lead["phone"]:
        lines.append(f"**Phone:** {lead['phone']}")
    lines.append("")

    # ---- Research
    lines.append("## Research")
    if not research or research.get("skip"):
        reason = research.get("skip_reason") if research else "no research yet"
        lines.append(f"_Skipped: {reason}_" if reason else "_Not researched yet._")
    else:
        if research.get("business_model"):
            lines.append(f"**Business model:** {research['business_model']}")
        if research.get("fleet_size_estimate"):
            lines.append(f"**Fleet size:** {research['fleet_size_estimate']}")
        if research.get("vehicle_categories"):
            lines.append(
                "**Vehicle categories:** " + ", ".join(research["vehicle_categories"])
            )
        if research.get("current_brands"):
            lines.append(
                "**Current brands:** " + ", ".join(research["current_brands"])
            )
        if research.get("chinese_exposure"):
            lines.append(f"**Chinese-brand exposure:** {research['chinese_exposure']}")
        if research.get("decision_makers"):
            lines.append("**Decision makers:**")
            for dm in research["decision_makers"]:
                line = f"- {dm.get('name', '?')} — {dm.get('role', '?')}"
                if dm.get("likely_email"):
                    line += f" (`{dm['likely_email']}`)"
                lines.append(line)
        if research.get("pain_points"):
            lines.append("**Pain points:**")
            for p in research["pain_points"]:
                lines.append(f"- {p}")
        if research.get("opportunities"):
            lines.append("**Opportunities:**")
            for o in research["opportunities"]:
                lines.append(f"- {o}")
        if research.get("recommended_models"):
            lines.append("**Recommended models for this lead:**")
            for m in research["recommended_models"]:
                price = m.get("price_band_zar") or "?"
                lot = m.get("lot_size") or "?"
                lines.append(
                    f"- **{m.get('model', '?')}** — ZAR {price}, lot {lot}. "
                    f"_{m.get('why_this_lead', '')}_"
                )
        if research.get("recent_news"):
            lines.append("**Recent news (web research):**")
            for n in research["recent_news"]:
                date = n.get("date") or ""
                source = n.get("source") or ""
                url = n.get("url") or ""
                head = n.get("headline") or ""
                rel = n.get("relevance") or ""
                lines.append(f"- {date} — *{source}*: [{head}]({url}). {rel}")
        if research.get("red_flags"):
            lines.append("**Red flags:**")
            for r in research["red_flags"]:
                lines.append(f"- ⚠ {r}")
    lines.append("")

    # ---- Conversation playbook
    lines.append("## Conversation playbook")
    if not plan:
        lines.append("_No playbook generated yet — run `outreach plan`._")
        return "\n".join(lines).rstrip() + "\n"
    if plan.get("skip"):
        lines.append(f"_Skipped: {plan.get('skip_reason')}_")
        return "\n".join(lines).rstrip() + "\n"

    if plan.get("summary_one_liner"):
        lines.append(f"> _{plan['summary_one_liner']}_")
    if plan.get("suggested_models"):
        lines.append(
            "**Models we will lead with:** " + ", ".join(plan["suggested_models"])
        )
    lines.append("")

    ft = plan.get("first_touch") or {}
    lines.append("### Touch 1 — first contact")
    lines.append(f"**Subject:** {ft.get('subject', '')}")
    if ft.get("opener"):
        lines.append(f"**Opener:** {ft['opener']}")
    if ft.get("cta"):
        lines.append(f"**CTA:** {ft['cta']}")
    lines.append("")
    lines.append("```")
    lines.append((ft.get("body") or "").rstrip())
    lines.append("")
    lines.append((ft.get("compliance_footer") or "").rstrip())
    lines.append("```")
    lines.append("")

    if plan.get("objection_handlers"):
        lines.append("### Anticipated objections + prepared replies")
        for o in plan["objection_handlers"]:
            lines.append(
                f"**{o.get('objection_key', '?')} — \"{o.get('objection_quote', '')}\"** "
                f"({o.get('intent', '?')})"
            )
            lines.append(f"  *Reply subject:* {o.get('reply_subject', '')}")
            lines.append("  ```")
            lines.append(indent((o.get("reply_body") or "").rstrip(), "  "))
            lines.append("  ```")
        lines.append("")

    if plan.get("followups"):
        lines.append("### Follow-up cadence")
        for f in plan["followups"]:
            lines.append(
                f"#### Day +{f.get('day_offset', '?')} — `{f.get('step_key', '')}`"
            )
            if f.get("hook"):
                lines.append(f"_Hook: {f['hook']}_")
            lines.append(f"**Subject:** {f.get('subject', '')}")
            lines.append("```")
            lines.append((f.get("body") or "").rstrip())
            lines.append("```")
        lines.append("")

    if plan.get("discovery_questions"):
        lines.append("### Discovery questions (after a warm reply)")
        for i, q in enumerate(plan["discovery_questions"], 1):
            lines.append(f"{i}. {q}")
        lines.append("")

    cm = plan.get("close_message") or {}
    if cm.get("body"):
        lines.append("### Close template (after positive intent)")
        lines.append(f"**Subject:** {cm.get('subject', '')}")
        lines.append("```")
        lines.append((cm.get("body") or "").rstrip())
        lines.append("```")
        lines.append("")

    if plan.get("if_no_response_after_30d"):
        lines.append(
            f"**If no response after 30 days:** "
            f"`{plan['if_no_response_after_30d']}`"
        )
        lines.append("")

    if history:
        lines.append("## Message history")
        for m in history:
            arrow = "→" if m["direction"] == "outbound" else "←"
            lines.append(
                f"- {m['created_at']} {arrow} {m['channel']}/{m['step'] or '?'}"
                + (f"  [{m['classification']}]" if m["classification"] else "")
            )
            if m["subject"]:
                lines.append(f"  **{m['subject']}**")

    return "\n".join(lines).rstrip() + "\n"


def export_lead(lead_id: int, db_path: Path | None = None) -> Path:
    PLAYBOOKS_DIR.mkdir(parents=True, exist_ok=True)
    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        if not lead:
            raise ValueError(f"Lead {lead_id} not found")
        history = db.message_history(conn, lead_id)
    md = render_lead(lead, history)
    out = PLAYBOOKS_DIR / f"lead{lead_id:02d}-{_slug(lead['company'])}.md"
    out.write_text(md, encoding="utf-8")
    return out


def export_all(db_path: Path | None = None) -> Path:
    """Concatenate every lead's playbook into one big markdown file."""
    PLAYBOOKS_DIR.mkdir(parents=True, exist_ok=True)
    out = PLAYBOOKS_DIR / f"all-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}.md"

    chunks: list[str] = ["# Outreach playbooks\n"]
    with db.session(db_path) as conn:
        for lead in db.fetch_leads(conn):
            history = db.message_history(conn, lead["id"])
            chunks.append(render_lead(lead, history))
            chunks.append("\n---\n")
    out.write_text("\n".join(chunks), encoding="utf-8")
    return out
