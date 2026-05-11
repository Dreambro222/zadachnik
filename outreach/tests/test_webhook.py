"""Tests for outreach.webhook — event dispatch, idempotency, signature."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest

from outreach import db, webhook


PLAN = {
    "first_touch": {
        "subject": "Bulk RHD Tiggo",
        "body":    "Hi.",
        "compliance_footer": "Footer.",
    },
    "followups": [
        {"step_key": "followup_1",  "day_offset": 5,  "subject": "f1", "body": "x"},
        {"step_key": "followup_2",  "day_offset": 10, "subject": "f2", "body": "x"},
        {"step_key": "nurture_30d", "day_offset": 30, "subject": "f3", "body": "x"},
    ],
}


@pytest.fixture
def lead_with_smartlead_id(tmp_path: Path, monkeypatch) -> tuple[Path, int, int]:
    """Spin up an isolated DB with one approved lead that's been pushed."""
    db_path = tmp_path / "t.db"
    db.init_db(db_path)
    monkeypatch.setattr(db, "DB_PATH", db_path)

    with db.session(db_path) as conn:
        lead_id = db.insert_lead(conn, {
            "company": "Motus",
            "email":   "ockert@motus.co.za",
        })
        db.update_lead(
            conn, lead_id,
            status="approved",
            conversation=json.dumps(PLAN),
            smartlead_lead_id=9001,
            smartlead_campaign_id=123,
            pushed_at=db.now_iso(),
        )

    return db_path, lead_id, 9001


# ---------- event_fingerprint ----------

def test_fingerprint_is_stable_for_same_event() -> None:
    e = {"event_type": "EMAIL_SENT", "campaign_id": 1, "lead_id": 2,
         "sequence_step_no": 1, "event_timestamp": "2026-05-11T00:00:00Z",
         "message_id": "<abc@x>"}
    assert webhook.event_fingerprint(e) == webhook.event_fingerprint(e)


def test_fingerprint_differs_across_events() -> None:
    a = {"event_type": "EMAIL_SENT", "lead_id": 1, "message_id": "<a>"}
    b = {"event_type": "EMAIL_SENT", "lead_id": 1, "message_id": "<b>"}
    assert webhook.event_fingerprint(a) != webhook.event_fingerprint(b)


# ---------- dispatch: EMAIL_SENT ----------

def test_dispatch_email_sent_records_outbound_and_flips_status(
    lead_with_smartlead_id,
) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id
    event = {
        "event_type": "EMAIL_SENT",
        "campaign_id": 123,
        "lead_id": smid,
        "lead_email": "ockert@motus.co.za",
        "sequence_step_no": 1,
        "subject": "Bulk RHD Tiggo",
        "text_body": "Hi.",
        "message_id": "<msg-1@smartlead>",
        "from_email": "outreach@trading.africa",
        "event_timestamp": "2026-05-11T08:00:00Z",
    }

    result = webhook.dispatch(event)
    assert "first_touch" in result

    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        assert lead["status"] == "sent"
        assert lead["current_step"] == "first_touch"
        msgs = db.message_history(conn, lead_id)
        assert len(msgs) == 1
        assert msgs[0]["direction"] == "outbound"
        assert msgs[0]["step"] == "first_touch"
        assert msgs[0]["smartlead_event_id"] is not None


def test_dispatch_email_sent_followup_2_keeps_status_advances_step(
    lead_with_smartlead_id,
) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id
    with db.session(db_path) as conn:
        db.update_lead(conn, lead_id, status="sent", current_step="followup_1")

    event = {
        "event_type": "EMAIL_SENT", "campaign_id": 123, "lead_id": smid,
        "lead_email": "ockert@motus.co.za", "sequence_step_no": 3,
        "subject": "Re: ...", "text_body": "Bump 2.",
        "message_id": "<msg-3@smartlead>",
        "event_timestamp": "2026-05-21T08:00:00Z",
    }
    webhook.dispatch(event)

    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        assert lead["status"] == "sent"               # unchanged
        assert lead["current_step"] == "followup_2"   # advanced


# ---------- dispatch: EMAIL_REPLY ----------

def test_dispatch_email_reply_records_inbound_and_clears_schedule(
    lead_with_smartlead_id,
) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id
    with db.session(db_path) as conn:
        db.update_lead(
            conn, lead_id,
            status="sent", current_step="first_touch",
            next_action_at="2026-05-16T08:00:00+00:00",
        )

    event = {
        "event_type": "EMAIL_REPLY", "campaign_id": 123, "lead_id": smid,
        "lead_email": "ockert@motus.co.za",
        "from_email": "ockert@motus.co.za",
        "subject": "Re: Bulk RHD Tiggo",
        "text_body": "Send pricing for 200 units.",
        "message_id": "<reply-1@motus>",
        "in_reply_to": "<msg-1@smartlead>",
        "event_timestamp": "2026-05-12T10:00:00Z",
    }
    with patch("outreach.conversation.classify_reply",
                return_value={"classification": "interested", "confidence": 0.9}):
        result = webhook.dispatch(event)

    assert "EMAIL_REPLY" in result and "interested" in result

    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        assert lead["status"] == "replied"
        assert lead["next_action_at"] is None
        msgs = db.message_history(conn, lead_id)
        inbound = [m for m in msgs if m["direction"] == "inbound"]
        assert len(inbound) == 1
        assert inbound[0]["classification"] == "interested"


def test_dispatch_email_reply_handles_classifier_crash_gracefully(
    lead_with_smartlead_id,
) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id

    event = {
        "event_type": "EMAIL_REPLY", "campaign_id": 123, "lead_id": smid,
        "lead_email": "ockert@motus.co.za",
        "from_email": "ockert@motus.co.za",
        "subject": "Re: ...", "text_body": "...",
        "message_id": "<r@x>", "event_timestamp": "2026-05-12T10:00:00Z",
    }
    with patch("outreach.conversation.classify_reply",
                side_effect=RuntimeError("Claude down")):
        result = webhook.dispatch(event)

    assert "EMAIL_REPLY" in result
    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        assert lead["status"] == "replied"           # still flipped
        inbound = [m for m in db.message_history(conn, lead_id)
                   if m["direction"] == "inbound"]
        assert inbound[0]["classification"] == "unclear"


# ---------- dispatch: EMAIL_BOUNCE ----------

def test_dispatch_email_bounce_marks_failed(lead_with_smartlead_id) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id

    event = {
        "event_type": "EMAIL_BOUNCE", "campaign_id": 123, "lead_id": smid,
        "lead_email": "ockert@motus.co.za",
        "bounce_reason": "550 5.1.1 No such user",
        "event_timestamp": "2026-05-11T08:01:00Z",
    }
    result = webhook.dispatch(event)
    assert "EMAIL_BOUNCE" in result

    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        assert lead["status"] == "failed"
        assert "550" in (lead["last_error"] or "")


# ---------- dispatch: LEAD_UNSUBSCRIBED ----------

def test_dispatch_unsubscribe_blocks_future_outreach(lead_with_smartlead_id) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id

    event = {
        "event_type": "LEAD_UNSUBSCRIBED", "campaign_id": 123, "lead_id": smid,
        "lead_email": "ockert@motus.co.za",
        "event_timestamp": "2026-05-12T11:00:00Z",
    }
    webhook.dispatch(event)

    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        assert lead["status"] == "unsubscribed"
        assert lead["do_form_outreach"] == 0


# ---------- idempotency ----------

def test_dispatch_duplicate_event_is_dropped(lead_with_smartlead_id) -> None:
    db_path, lead_id, smid = lead_with_smartlead_id
    event = {
        "event_type": "EMAIL_SENT", "campaign_id": 123, "lead_id": smid,
        "lead_email": "ockert@motus.co.za", "sequence_step_no": 1,
        "message_id": "<m1@x>",
        "event_timestamp": "2026-05-11T08:00:00Z",
    }
    first  = webhook.dispatch(event)
    second = webhook.dispatch(event)

    assert "first_touch" in first
    assert "duplicate" in second
    with db.session(db_path) as conn:
        msgs = db.message_history(conn, lead_id)
        assert len(msgs) == 1


# ---------- lead lookup fallbacks ----------

def test_dispatch_falls_back_to_email_when_no_smartlead_id(
    lead_with_smartlead_id,
) -> None:
    db_path, lead_id, _ = lead_with_smartlead_id

    event = {
        "event_type": "EMAIL_SENT", "campaign_id": 123,
        "lead_email": "ockert@motus.co.za",    # no lead_id
        "sequence_step_no": 1, "message_id": "<m@x>",
        "event_timestamp": "2026-05-11T08:00:00Z",
    }
    result = webhook.dispatch(event)
    assert "first_touch" in result
    with db.session(db_path) as conn:
        assert db.get_lead(conn, lead_id)["status"] == "sent"


def test_dispatch_returns_descriptive_string_when_lead_unknown(
    lead_with_smartlead_id,
) -> None:
    event = {
        "event_type": "EMAIL_REPLY", "lead_id": 99999,
        "lead_email": "ghost@nowhere.io",
        "subject": "?", "text_body": "?", "message_id": "<x>",
    }
    result = webhook.dispatch(event)
    assert "no matching lead" in result


def test_dispatch_ignores_unknown_event_type() -> None:
    result = webhook.dispatch({"event_type": "EMAIL_OPEN", "lead_id": 1})
    assert "ignored" in result


# ---------- signature ----------

def test_verify_signature_accepts_correct_hmac() -> None:
    body = b'{"event_type":"EMAIL_SENT"}'
    secret = "hush"
    import hashlib
    import hmac
    sig = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    assert webhook.verify_signature(body, sig, secret)
    assert webhook.verify_signature(body, f"sha256={sig}", secret)


def test_verify_signature_rejects_wrong_hmac() -> None:
    assert not webhook.verify_signature(b"{}", "deadbeef", "hush")
    assert not webhook.verify_signature(b"{}", None, "hush")
