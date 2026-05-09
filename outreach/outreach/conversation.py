"""Multi-turn conversation playbook generator + reply classifier.

Each lead, once researched, gets one ``plan_conversation()`` call which
returns the entire sales sequence in JSON: first touch, prepared replies for
4–6 typical objections, three follow-ups, discovery questions, and a close
message. The plan is stored on the lead and drives every subsequent step.

When a reply lands in the monitored mailbox, ``classify_reply()`` matches it
against the prepared plan and tells the operator (or downstream automation)
what to send next.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import claude_runner

PROMPTS_DIR = Path(__file__).parent / "prompts"


def _load_prompt(name: str) -> str:
    return (PROMPTS_DIR / f"{name}.md").read_text(encoding="utf-8")


def plan_conversation(
    lead: dict[str, Any],
    research: dict[str, Any],
    sender: dict[str, Any],
    base_offer: str,
    *,
    channel: str = "form",
) -> dict[str, Any]:
    payload = {
        "LEAD": {
            "company": lead.get("company"),
            "category": lead.get("category"),
            "priority": lead.get("priority"),
            "hq_city": lead.get("hq_city"),
            "contact_name": lead.get("contact_name"),
            "contact_role": lead.get("contact_role"),
            "notes": lead.get("notes"),
        },
        "RESEARCH": research,
        "SENDER": sender,
        "BASE_OFFER": base_offer,
        "CONTEXT": {"channel": channel, "max_chars": 1500 if channel == "form" else 1800},
    }
    return claude_runner.ask_json(
        json.dumps(payload, ensure_ascii=False),
        system=_load_prompt("plan_conversation"),
        timeout=180,
    )


def classify_reply(
    lead: dict[str, Any],
    plan: dict[str, Any],
    history: list[dict[str, Any]],
    incoming: dict[str, Any],
) -> dict[str, Any]:
    payload = {
        "LEAD": {
            "company": lead.get("company"),
            "category": lead.get("category"),
            "contact_name": lead.get("contact_name"),
            "current_step": lead.get("current_step"),
        },
        "PLAN": plan,
        "HISTORY": history,
        "INCOMING": incoming,
    }
    return claude_runner.ask_json(
        json.dumps(payload, ensure_ascii=False),
        system=_load_prompt("classify_reply"),
        timeout=90,
    )
