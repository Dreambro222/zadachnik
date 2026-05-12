"""Tests for outreach.sync — polling-based Smartlead → local DB ingest."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import httpx
import pytest

from outreach import db, smartlead, sync


PLAN = {
    "first_touch": {"subject": "Bulk RHD", "body": "Hi.", "compliance_footer": "F"},
    "followups": [
        {"step_key": "followup_1",  "day_offset": 5,  "subject": "f1", "body": "x"},
        {"step_key": "followup_2",  "day_offset": 10, "subject": "f2", "body": "x"},
        {"step_key": "nurture_30d", "day_offset": 30, "subject": "f3", "body": "x"},
    ],
}


@pytest.fixture
def fake_db(tmp_path: Path, monkeypatch) -> Path:
    """Isolated DB with one approved lead pushed to Smartlead."""
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

    return db_path


def _mock_client(handler) -> smartlead.SmartleadClient:
    cfg = smartlead.SmartleadConfig(api_key="k", base_url="https://test")
    return smartlead.SmartleadClient(
        cfg, http=httpx.Client(transport=httpx.MockTransport(handler)),
    )


# ---------- _reply_fingerprint ----------

def test_reply_fingerprint_stable() -> None:
    r = {"campaign_id": 123, "lead_id": 9001, "message_id": "<x@y>",
         "received_time": "2026-05-12T08:00:00Z"}
    assert sync._reply_fingerprint(r) == sync._reply_fingerprint(r)


def test_reply_fingerprint_differs_on_different_messages() -> None:
    a = {"campaign_id": 1, "lead_id": 2, "message_id": "<a>"}
    b = {"campaign_id": 1, "lead_id": 2, "message_id": "<b>"}
    assert sync._reply_fingerprint(a) != sync._reply_fingerprint(b)


# ---------- sync_once: replies ----------

def test_sync_records_one_new_reply(fake_db: Path) -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": [{
                "campaign_id": 123, "lead_id": 9001,
                "lead_email": "ockert@motus.co.za",
                "from_email": "ockert@motus.co.za",
                "subject": "Re: Bulk RHD",
                "text_body": "Send pricing for 200 units.",
                "message_id": "<reply-1@motus>",
                "received_time": "2026-05-12T10:00:00Z",
            }]})
        if "/campaigns/123/leads" in req.url.path:
            return httpx.Response(200, json={"data": []})
        return httpx.Response(404)

    client = _mock_client(handler)
    with patch("outreach.conversation.classify_reply",
                return_value={"classification": "interested", "confidence": 0.9}):
        stats = sync.sync_once(client, campaign_ids=[123])

    assert stats.replies_new == 1
    assert stats.replies_skipped == 0
    with db.session(fake_db) as conn:
        lead = db.get_lead(conn, 1)
        assert lead["status"] == "replied"
        assert lead["next_action_at"] is None
        inbound = [m for m in db.message_history(conn, 1)
                   if m["direction"] == "inbound"]
        assert len(inbound) == 1
        assert inbound[0]["classification"] == "interested"


def test_sync_dedupes_replies_via_event_fingerprint(fake_db: Path) -> None:
    payload = {
        "campaign_id": 123, "lead_id": 9001,
        "lead_email": "ockert@motus.co.za", "from_email": "ockert@motus.co.za",
        "subject": "Re: X", "text_body": "...",
        "message_id": "<r1>", "received_time": "2026-05-12T10:00:00Z",
    }

    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": [payload]})
        if "/leads" in req.url.path:
            return httpx.Response(200, json={"data": []})
        return httpx.Response(404)

    client = _mock_client(handler)
    with patch("outreach.conversation.classify_reply",
                return_value={"classification": "interested", "confidence": 0.9}):
        first  = sync.sync_once(client, campaign_ids=[123])
        second = sync.sync_once(client, campaign_ids=[123])

    assert first.replies_new == 1
    assert second.replies_new == 0
    assert second.replies_skipped == 1
    with db.session(fake_db) as conn:
        inbound = [m for m in db.message_history(conn, 1)
                   if m["direction"] == "inbound"]
        assert len(inbound) == 1


def test_sync_skips_when_lead_not_in_our_db(fake_db: Path) -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": [{
                "campaign_id": 123, "lead_id": 99999,  # not ours
                "lead_email": "ghost@nowhere.io",
                "subject": "Re:", "text_body": "...",
                "message_id": "<g@x>", "received_time": "2026-05-12T10:00:00Z",
            }]})
        if "/leads" in req.url.path:
            return httpx.Response(200, json={"data": []})
        return httpx.Response(404)

    client = _mock_client(handler)
    stats = sync.sync_once(client, campaign_ids=[123], classify=False)
    assert stats.replies_new == 0
    assert stats.replies_skipped == 0


def test_sync_classifier_crash_falls_back_to_unclear(fake_db: Path) -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": [{
                "campaign_id": 123, "lead_id": 9001,
                "lead_email": "ockert@motus.co.za",
                "subject": "Re:", "text_body": "...",
                "message_id": "<r@x>", "received_time": "2026-05-12T10:00:00Z",
            }]})
        if "/leads" in req.url.path:
            return httpx.Response(200, json={"data": []})
        return httpx.Response(404)

    client = _mock_client(handler)
    with patch("outreach.conversation.classify_reply",
                side_effect=RuntimeError("Claude down")):
        stats = sync.sync_once(client, campaign_ids=[123])

    assert stats.replies_new == 1
    with db.session(fake_db) as conn:
        inbound = [m for m in db.message_history(conn, 1)
                   if m["direction"] == "inbound"]
        assert inbound[0]["classification"] == "unclear"


# ---------- sync_once: terminal states ----------

def test_sync_detects_bounce_from_lead_status(fake_db: Path) -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": []})
        if "/leads/9001" in req.url.path:
            return httpx.Response(200, json={"data": []})
        if req.url.path == "/campaigns/123/leads":
            return httpx.Response(200, json={"data": [{
                "id": 9001, "email": "ockert@motus.co.za",
                "email_lead_status": "bounced",
            }]})
        return httpx.Response(404)

    client = _mock_client(handler)
    stats = sync.sync_once(client, campaign_ids=[123], classify=False)

    assert stats.bounces_recorded == 1
    with db.session(fake_db) as conn:
        lead = db.get_lead(conn, 1)
        assert lead["status"] == "failed"
        assert "bounce" in (lead["last_error"] or "").lower()


def test_sync_detects_unsubscribe(fake_db: Path) -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": []})
        if req.url.path == "/campaigns/123/leads":
            return httpx.Response(200, json={"data": [{
                "id": 9001, "email": "ockert@motus.co.za",
                "email_lead_status": "unsubscribed",
            }]})
        return httpx.Response(404)

    client = _mock_client(handler)
    stats = sync.sync_once(client, campaign_ids=[123], classify=False)

    assert stats.unsubs_recorded == 1
    with db.session(fake_db) as conn:
        lead = db.get_lead(conn, 1)
        assert lead["status"] == "unsubscribed"
        assert lead["do_form_outreach"] == 0


# ---------- sync_once: sends advance current_step ----------

def test_sync_records_send_when_smartlead_step_advanced(fake_db: Path) -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": []})
        if req.url.path == "/campaigns/123/leads/9001/message-history":
            return httpx.Response(200, json={"history": [{
                "type": "sent",
                "sequence_step_no": 1,
                "subject": "Bulk RHD",
                "text_body": "Hi.",
                "from_email": "x@autosignal-trade.com",
                "to_email": "ockert@motus.co.za",
                "message_id": "<m1@sl>",
                "sent_time": "2026-05-12T09:00:00Z",
            }]})
        if req.url.path == "/campaigns/123/leads":
            return httpx.Response(200, json={"data": [{
                "id": 9001, "email": "ockert@motus.co.za",
                "last_email_sequence_sent": 1,
            }]})
        return httpx.Response(404)

    client = _mock_client(handler)
    stats = sync.sync_once(client, campaign_ids=[123], classify=False)

    assert stats.sends_recorded == 1
    with db.session(fake_db) as conn:
        lead = db.get_lead(conn, 1)
        assert lead["current_step"] == "first_touch"
        assert lead["status"] == "sent"


def test_sync_skips_send_fetch_when_step_not_advanced(fake_db: Path) -> None:
    """If our `current_step` already matches Smartlead's last-sent, we don't
    hit /message-history — saves API calls. Verify by handler refusing it."""
    with db.session(fake_db) as conn:
        db.update_lead(conn, 1, current_step="first_touch", status="sent")

    history_calls: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        if "message-history" in req.url.path:
            history_calls.append(req.url.path)
            return httpx.Response(500, text="should not be called")
        if "statistics-replies" in req.url.path:
            return httpx.Response(200, json={"data": []})
        if req.url.path == "/campaigns/123/leads":
            return httpx.Response(200, json={"data": [{
                "id": 9001, "email": "ockert@motus.co.za",
                "last_email_sequence_sent": 1,    # same as ours
            }]})
        return httpx.Response(404)

    client = _mock_client(handler)
    sync.sync_once(client, campaign_ids=[123], classify=False)
    assert history_calls == []


# ---------- stats line ----------

def test_stats_oneline_includes_all_counters() -> None:
    s = sync.SyncStats(campaigns=2, leads_inspected=74, replies_new=3,
                       replies_skipped=1, sends_recorded=12,
                       bounces_recorded=2, unsubs_recorded=1, status_updates=3,
                       errors=["x"])
    line = s.as_oneline()
    for needle in ("campaigns=2", "leads=74", "replies_new=3", "dup 1",
                   "sends=12", "bounces=2", "unsubs=1", "errors=1"):
        assert needle in line
