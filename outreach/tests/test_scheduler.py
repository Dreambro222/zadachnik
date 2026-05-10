"""Tests for the cadence scheduler (state machine + due-list)."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from outreach import db, scheduler


PLAN = {
    "first_touch": {
        "subject": "Bulk RHD Tiggo",
        "body": "Hi.",
        "compliance_footer": "Footer\nReply UNSUBSCRIBE.",
    },
    "followups": [
        {"step_key": "followup_1",  "day_offset": 5,  "subject": "f1", "body": "Bump."},
        {"step_key": "followup_2",  "day_offset": 10, "subject": "f2", "body": "Yes/no?"},
        {"step_key": "nurture_30d", "day_offset": 30, "subject": "f3", "body": "FYI."},
    ],
    "discovery_questions": ["q1", "q2"],
    "close_message": {"subject": "C", "body": "Close."},
}


# ---------- next_cadence_step ----------

def test_next_step_from_null_is_first_touch() -> None:
    assert scheduler.next_cadence_step(PLAN, None) == "first_touch"


def test_next_step_from_first_touch_is_followup_1() -> None:
    assert scheduler.next_cadence_step(PLAN, "first_touch") == "followup_1"


def test_next_step_walks_through_cadence() -> None:
    assert scheduler.next_cadence_step(PLAN, "followup_1") == "followup_2"
    assert scheduler.next_cadence_step(PLAN, "followup_2") == "nurture_30d"


def test_next_step_terminal_at_nurture_30d() -> None:
    assert scheduler.next_cadence_step(PLAN, "nurture_30d") is None


def test_next_step_terminal_for_close_and_objections() -> None:
    assert scheduler.next_cadence_step(PLAN, "close") is None
    assert scheduler.next_cadence_step(PLAN, "objection_send_pricing_pack") is None


def test_next_step_skips_missing_followups() -> None:
    plan_no_f2 = {
        "first_touch": PLAN["first_touch"],
        "followups": [
            {"step_key": "followup_1",  "day_offset": 5,  "subject": "x", "body": "y"},
            {"step_key": "nurture_30d", "day_offset": 30, "subject": "x", "body": "y"},
        ],
    }
    # After followup_1, jumps over the missing followup_2 to nurture_30d.
    assert scheduler.next_cadence_step(plan_no_f2, "followup_1") == "nurture_30d"


def test_next_step_returns_none_when_no_first_touch_body() -> None:
    plan = {"first_touch": {"subject": "x", "body": ""}, "followups": []}
    assert scheduler.next_cadence_step(plan, None) is None


# ---------- compute_next_action_at ----------

def test_no_first_touch_anchor_means_no_schedule() -> None:
    assert scheduler.compute_next_action_at(PLAN, "first_touch", None) is None


def test_first_touch_is_never_auto_scheduled() -> None:
    # current_step=None → next is first_touch, but first_touch is gated.
    assert scheduler.compute_next_action_at(PLAN, None, "2026-05-10T00:00:00+00:00") is None


def test_after_first_touch_due_in_5_days() -> None:
    anchor = "2026-05-01T12:00:00+00:00"
    due = scheduler.compute_next_action_at(PLAN, "first_touch", anchor)
    assert due is not None
    parsed = datetime.fromisoformat(due)
    expected = datetime(2026, 5, 6, 12, 0, tzinfo=timezone.utc)
    assert parsed == expected


def test_after_followup_1_due_at_day_10() -> None:
    anchor = "2026-05-01T00:00:00+00:00"
    due = scheduler.compute_next_action_at(PLAN, "followup_1", anchor)
    assert due is not None
    parsed = datetime.fromisoformat(due)
    assert parsed == datetime(2026, 5, 11, 0, 0, tzinfo=timezone.utc)


def test_after_followup_2_due_at_day_30() -> None:
    anchor = "2026-05-01T00:00:00+00:00"
    due = scheduler.compute_next_action_at(PLAN, "followup_2", anchor)
    assert due is not None
    parsed = datetime.fromisoformat(due)
    assert parsed == datetime(2026, 5, 31, 0, 0, tzinfo=timezone.utc)


def test_terminal_returns_none() -> None:
    anchor = "2026-05-01T00:00:00+00:00"
    assert scheduler.compute_next_action_at(PLAN, "nurture_30d", anchor) is None
    assert scheduler.compute_next_action_at(PLAN, "close", anchor) is None
    assert scheduler.compute_next_action_at(PLAN, "objection_x", anchor) is None


# ---------- fetch_due ----------

def test_fetch_due_picks_only_overdue_leads(tmp_path: Path) -> None:
    db_path = tmp_path / "x.db"
    db.init_db(db_path)
    now = datetime(2026, 5, 10, 12, 0, tzinfo=timezone.utc)
    yesterday = (now - timedelta(days=1)).isoformat(timespec="seconds")
    tomorrow = (now + timedelta(days=1)).isoformat(timespec="seconds")
    plan = json.dumps(PLAN, ensure_ascii=False)

    with db.session(db_path) as conn:
        a = db.insert_lead(conn, {"company": "Due Lead",  "email": "a@a.co.za"})
        b = db.insert_lead(conn, {"company": "Future Lead", "email": "b@b.co.za"})
        c = db.insert_lead(conn, {"company": "No Schedule", "email": "c@c.co.za"})
        d = db.insert_lead(conn, {"company": "Replied",     "email": "d@d.co.za"})

        db.update_lead(conn, a, status="sent", current_step="first_touch",
                       next_action_at=yesterday, conversation=plan)
        db.update_lead(conn, b, status="sent", current_step="first_touch",
                       next_action_at=tomorrow,  conversation=plan)
        db.update_lead(conn, c, status="sent", current_step="first_touch",
                       next_action_at=None,     conversation=plan)
        db.update_lead(conn, d, status="replied", current_step="first_touch",
                       next_action_at=yesterday, conversation=plan)

    with db.session(db_path) as conn:
        due_rows = scheduler.fetch_due(conn, now=now)
        ids = [r["id"] for r in due_rows]

    # Only the overdue, non-replied lead surfaces.
    assert ids == [a]


def test_first_touch_sent_at_returns_first_outbound(tmp_path: Path) -> None:
    db_path = tmp_path / "y.db"
    db.init_db(db_path)
    with db.session(db_path) as conn:
        lead_id = db.insert_lead(conn, {"company": "X", "email": "x@x.co.za"})
        db.record_message(
            conn, lead_id,
            direction="outbound", channel="email", step="first_touch",
            subject="s", body="b", message_id="<m1@x>",
        )
        db.record_message(
            conn, lead_id,
            direction="outbound", channel="email", step="followup_1",
            subject="s2", body="b2", message_id="<m2@x>",
        )
    with db.session(db_path) as conn:
        ts = scheduler.first_touch_sent_at(conn, lead_id)
    assert ts is not None
    # ISO parses back; should be the FIRST one (today's UTC date)
    parsed = datetime.fromisoformat(ts)
    assert (datetime.now(timezone.utc) - parsed).total_seconds() < 30


def test_days_overdue_handles_garbage() -> None:
    now = datetime(2026, 5, 10, 12, 0, tzinfo=timezone.utc)
    assert scheduler.days_overdue(now, "not-a-date") == 0.0
    yesterday = (now - timedelta(days=2, hours=12)).isoformat(timespec="seconds")
    overdue = scheduler.days_overdue(now, yesterday)
    assert 2.4 < overdue < 2.6
