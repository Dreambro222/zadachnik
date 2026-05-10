"""Auto-scheduler for the cadence steps.

Closes the loop on follow-ups: after `mail` / `send` ships a step, this
module decides what the next step is and when it is due. `outreach due`
lists everything past its scheduled time, and `mail --due` ships the
next step on every due lead in one batch (respecting MAIL_DAILY_LIMIT).

State convention (settled — see AUDIT M1 fix):
- `leads.current_step` stores the LAST COMPLETED step, no `_sent` suffix.
  Values: NULL / 'first_touch' / 'followup_1' / 'followup_2' /
  'nurture_30d' / 'close' / 'objection_<key>'.
- `leads.next_action_at` is the ISO-8601 UTC timestamp at which the NEXT
  step in CADENCE_STEPS is due. NULL means no scheduled action — either
  the lead is in a terminal state (close / nurture_30d), waiting for human
  intervention (replied / objection_*), or hasn't shipped first_touch yet.
"""
from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any

# Linear cadence sequence. Anything off-sequence (close, objection_*) is
# considered terminal for auto-scheduling — the operator picks what to send.
CADENCE_STEPS = ("first_touch", "followup_1", "followup_2", "nurture_30d")

TERMINAL_STEPS = {"nurture_30d", "close"}


def next_cadence_step(plan: dict[str, Any], current_step: str | None) -> str | None:
    """Return the next CADENCE_STEPS step that is also present in the
    playbook, or None if we're at the end / off-sequence.

    plan: full playbook (the JSON blob from leads.conversation).
    """
    if current_step is None:
        # Nothing sent yet — first_touch is the entry point.
        if (plan.get("first_touch") or {}).get("body"):
            return "first_touch"
        return None

    if current_step in TERMINAL_STEPS:
        return None
    if current_step.startswith("objection_") or current_step == "close":
        return None
    if current_step not in CADENCE_STEPS:
        return None

    available_followups = {
        f.get("step_key")
        for f in (plan.get("followups") or [])
        if f.get("step_key") and (f.get("body") or "").strip()
    }
    idx = CADENCE_STEPS.index(current_step)
    for candidate in CADENCE_STEPS[idx + 1:]:
        if candidate in available_followups:
            return candidate
    return None


def step_day_offset(plan: dict[str, Any], step: str) -> int | None:
    """Day-offset (from first_touch) for ``step``, per the playbook."""
    if step == "first_touch":
        return 0
    for f in plan.get("followups") or []:
        if f.get("step_key") == step:
            offset = f.get("day_offset")
            if isinstance(offset, (int, float)):
                return int(offset)
    return None


def compute_next_action_at(
    plan: dict[str, Any],
    current_step: str | None,
    first_touch_sent_at: str | None,
) -> str | None:
    """Returns ISO-8601 UTC timestamp for the next due action, or None.

    For terminal / off-sequence states returns None. For step N just
    completed, returns first_touch_sent_at + day_offset(step N+1) days.
    """
    next_step = next_cadence_step(plan, current_step)
    if not next_step or next_step == "first_touch":
        # first_touch is gated behind manual approve — never auto-scheduled.
        return None

    day_offset = step_day_offset(plan, next_step)
    if day_offset is None:
        return None

    if not first_touch_sent_at:
        return None

    try:
        # first_touch_sent_at is ISO from db.now_iso() — UTC, "+00:00" form.
        anchor = datetime.fromisoformat(first_touch_sent_at)
    except ValueError:
        return None
    if anchor.tzinfo is None:
        anchor = anchor.replace(tzinfo=timezone.utc)

    due = anchor + timedelta(days=day_offset)
    return due.astimezone(timezone.utc).isoformat(timespec="seconds")


def first_touch_sent_at(
    conn: sqlite3.Connection, lead_id: int
) -> str | None:
    """Return the created_at of the FIRST outbound first_touch on this lead."""
    row = conn.execute(
        """SELECT created_at FROM messages
           WHERE lead_id = ?
             AND direction = 'outbound'
             AND step = 'first_touch'
           ORDER BY id LIMIT 1""",
        (lead_id,),
    ).fetchone()
    return row["created_at"] if row else None


def fetch_due(
    conn: sqlite3.Connection,
    *,
    now: datetime | None = None,
    limit: int | None = None,
) -> list[sqlite3.Row]:
    """Leads where next_action_at <= now AND status not terminal-bad.

    Excludes 'failed', 'skipped' (operator paused them deliberately) and
    'replied' (operator owns the next move). Includes 'sent' — those are
    the leads in the middle of a cadence.
    """
    now = now or datetime.now(timezone.utc)
    sql = """
        SELECT * FROM leads
        WHERE next_action_at IS NOT NULL
          AND next_action_at <= ?
          AND status IN ('sent', 'approved')
        ORDER BY next_action_at
    """
    params: list[Any] = [now.isoformat(timespec="seconds")]
    if limit:
        sql += " LIMIT ?"
        params.append(limit)
    return list(conn.execute(sql, params))


def days_overdue(now: datetime, due_iso: str) -> float:
    """Helper for status displays: how many days past due."""
    try:
        due = datetime.fromisoformat(due_iso)
    except ValueError:
        return 0.0
    if due.tzinfo is None:
        due = due.replace(tzinfo=timezone.utc)
    return (now - due).total_seconds() / 86400.0
