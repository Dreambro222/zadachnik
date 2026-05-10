"""Smoke tests for the IMAP inbox poller (no network)."""
from __future__ import annotations

import json
from email.message import EmailMessage
from email.utils import formataddr, make_msgid
from pathlib import Path

from outreach import config, db, inbox as inbox_mod


def _cfg() -> config.InboxConfig:
    return config.InboxConfig(
        host="imap.example.com", port=993,
        user="outreach@example.com", password="x",
        folder="INBOX", poll_seconds=60,
    )


def _build_reply_bytes(*, from_addr: str, to_addr: str,
                       subject: str, body: str,
                       in_reply_to: str | None = None) -> bytes:
    em = EmailMessage()
    em["From"] = formataddr(("Lead Person", from_addr))
    em["To"] = to_addr
    em["Subject"] = subject
    em["Message-ID"] = make_msgid(domain="lead-domain.co.za")
    if in_reply_to:
        em["In-Reply-To"] = in_reply_to
        em["References"] = in_reply_to
    em.set_content(body, subtype="plain")
    return em.as_bytes()


class FakeIMAP:
    """Minimal imaplib.IMAP4-shaped stub for testing."""

    def __init__(self, mails: list[tuple[int, bytes]], uidvalidity: int = 12345):
        self.mails = mails
        self.uidvalidity = uidvalidity

    def select(self, folder):
        return "OK", [b"OK"]

    def status(self, folder, what):
        return "OK", [f"{folder} (UIDVALIDITY {self.uidvalidity})".encode()]

    def uid(self, command, *args):
        if command == "SEARCH":
            criteria = args[1] if len(args) >= 2 else args[0]
            after = 0
            if isinstance(criteria, str) and criteria.startswith("UID "):
                lo = criteria.split(" ", 1)[1].split(":", 1)[0]
                if lo.isdigit():
                    after = int(lo) - 1
            uids = [uid for uid, _ in self.mails if uid > after]
            return "OK", [" ".join(str(u) for u in uids).encode()]
        if command == "FETCH":
            target = int(args[0])
            for uid, raw in self.mails:
                if uid == target:
                    return "OK", [(f"{uid} (RFC822 {{{len(raw)}}})".encode(), raw)]
            return "NO", [b""]
        return "BAD", [b""]

    def logout(self):
        pass


def test_ingest_attaches_inbound_to_lead_via_in_reply_to(
    tmp_path: Path, monkeypatch
) -> None:
    db_path = tmp_path / "x.db"
    db.init_db(db_path)

    # Seed a lead with a conversation plan + a prior outbound first_touch
    with db.session(db_path) as conn:
        lead_id = db.insert_lead(conn, {
            "company": "Eastvaal Motor Group",
            "email": "info@eastvaal.co.za",
            "category": "Dealer Group",
            "channel": "email",
            "country": "South Africa",
        })
        plan_blob = {
            "first_touch": {
                "subject": "Bulk RHD Tiggo",
                "body": "Hi.",
                "compliance_footer": "Test Sender, Test FZE, DMCC, Dubai\nReply UNSUBSCRIBE.",
            },
            "objection_handlers": [
                {"objection_key": "send_pricing_pack",
                 "objection_quote": "Send your pricing pack",
                 "reply_subject": "One-page pricing",
                 "reply_body": "Sending one-page pricing.",
                 "intent": "reframe"},
            ],
            "followups": [],
            "discovery_questions": ["q1", "q2", "q3"],
            "close_message": {"subject": "C", "body": "B"},
        }
        db.update_lead(
            conn, lead_id,
            status="sent",
            conversation=json.dumps(plan_blob, ensure_ascii=False),
        )
        outbound_msgid = "<original-touch@example.com>"
        db.record_message(
            conn, lead_id,
            direction="outbound", channel="email", step="first_touch",
            subject="Bulk RHD Tiggo", body="Hi.",
            message_id=outbound_msgid, thread_id=outbound_msgid,
            from_addr="outreach@example.com", to_addr="info@eastvaal.co.za",
        )

    # Stub classify_reply so we don't touch the LLM.
    captured: dict = {}

    def fake_classify(lead, plan, history, incoming):
        captured["lead"] = lead["company"]
        captured["incoming_subj"] = incoming["subject"]
        return {
            "classification": "objection",
            "matched_objection_key": "send_pricing_pack",
            "sentiment": "neutral",
            "urgency": "medium",
            "recommended_action": "send_objection_reply",
            "suggested_subject": "One-page pricing",
            "suggested_body": "Sending one-page pricing.",
            "rationale": "asks for pricing",
            "confidence": 0.8,
            "must_human_review": False,
        }

    monkeypatch.setattr(inbox_mod.conversation, "classify_reply", fake_classify)

    raw = _build_reply_bytes(
        from_addr="ceo@eastvaal.co.za",
        to_addr="outreach@example.com",
        subject="Re: Bulk RHD Tiggo",
        body="Send your pricing pack please.",
        in_reply_to=outbound_msgid,
    )

    # Run ingest with a faked IMAP connection.
    summary = inbox_mod.ingest(
        db_path=db_path,
        inbox_cfg=_cfg(),
        imap_factory=lambda cfg: FakeIMAP([(101, raw)]),
        classify=True,
    )

    assert summary["fetched"] == 1
    assert summary["attached"] == 1
    assert summary["classified"] == 1
    assert captured["lead"] == "Eastvaal Motor Group"
    assert captured["incoming_subj"].startswith("Re:")

    # Verify storage
    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        history = db.message_history(conn, lead_id)
        _, last_uid = db.get_inbox_cursor(conn, "INBOX")

    assert lead["status"] == "replied"
    assert last_uid == 101
    inbound = [m for m in history if m["direction"] == "inbound"]
    assert len(inbound) == 1
    assert inbound[0]["classification"] == "objection"
    assert inbound[0]["thread_id"] == outbound_msgid


def test_ingest_skips_unmatched_replies(tmp_path: Path) -> None:
    db_path = tmp_path / "y.db"
    db.init_db(db_path)

    raw = _build_reply_bytes(
        from_addr="random@nowhere.example",
        to_addr="outreach@example.com",
        subject="Hello!",
        body="Random message.",
    )
    summary = inbox_mod.ingest(
        db_path=db_path,
        inbox_cfg=_cfg(),
        imap_factory=lambda cfg: FakeIMAP([(50, raw)]),
        classify=False,
    )
    assert summary["fetched"] == 1
    assert summary["attached"] == 0
    assert summary["classified"] == 0
    assert len(summary["unattached"]) == 1
    assert summary["unattached"][0]["from"] == "random@nowhere.example"
