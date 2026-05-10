"""Smoke tests for the SMTP mailer (no network)."""
from __future__ import annotations

import re

import pytest

from outreach import config, mailer


def _cfg() -> config.MailerConfig:
    return config.MailerConfig(
        host="smtp.example.com", port=587,
        user="outreach@example.com", password="x",
        use_tls=True,
        from_name="Test Sender",
        from_email="outreach@example.com",
        reply_to=None,
        daily_limit=20, delay_seconds=0,
    )


def test_assemble_body_requires_footer() -> None:
    with pytest.raises(mailer.MailError):
        mailer.assemble_body("Hello there.", "")
    body = mailer.assemble_body("Hello.", "Sender, +0 0 0\nReply UNSUBSCRIBE.")
    assert body.startswith("Hello.")
    assert "UNSUBSCRIBE" in body
    assert "\n\n" in body  # blank line between body and footer


def test_thread_subject_re_prefix() -> None:
    assert mailer.thread_subject("Test", is_followup=False) == "Test"
    assert mailer.thread_subject("Test", is_followup=True) == "Re: Test"
    assert mailer.thread_subject("Re: Test", is_followup=True) == "Re: Test"


def test_build_envelope_sets_threading_headers() -> None:
    cfg = _cfg()
    msg = mailer.OutboundMessage(
        to_email="ceo@motus.co.za",
        to_name="Ockert",
        subject="Re: Bulk RHD Tiggo",
        body_plain="Hello.\n\nFooter.",
        in_reply_to="<orig@example.com>",
        references=["<orig@example.com>"],
    )
    em, mid = mailer.build_envelope(msg, cfg)
    assert em["From"] == 'Test Sender <outreach@example.com>'
    assert em["To"] == 'Ockert <ceo@motus.co.za>'
    assert em["Subject"] == "Re: Bulk RHD Tiggo"
    assert em["In-Reply-To"] == "<orig@example.com>"
    assert "<orig@example.com>" in em["References"]
    assert re.match(r"<.+@example\.com>", mid)
    assert em["Message-ID"] == mid
    body = em.get_payload()
    assert "Hello." in body and "Footer." in body


def test_send_dry_run_does_not_call_smtp() -> None:
    calls: list = []

    def fake_factory(cfg):
        calls.append(cfg)
        raise AssertionError("dry-run must not open SMTP")

    cfg = _cfg()
    msg = mailer.OutboundMessage(
        to_email="ceo@example.co.za",
        to_name=None,
        subject="Test",
        body_plain="Body.\n\nFooter.",
    )
    res = mailer.send(msg, cfg, dry_run=True, smtp_factory=fake_factory)
    assert res.dry_run is True
    assert res.message_id.endswith("@example.com>")
    assert "Body." in res.raw_envelope
    assert calls == []


def test_send_uses_factory_in_live_mode() -> None:
    sent: list = []

    class FakeSmtp:
        def send_message(self, em):
            sent.append(em)
        def quit(self):
            sent.append("quit")

    cfg = _cfg()
    msg = mailer.OutboundMessage(
        to_email="x@example.co.za", to_name=None,
        subject="Hi", body_plain="Body.\n\nFooter.",
    )
    res = mailer.send(msg, cfg, dry_run=False, smtp_factory=lambda c: FakeSmtp())
    assert res.dry_run is False
    assert len(sent) == 2
    assert sent[1] == "quit"
    sent_em = sent[0]
    assert "x@example.co.za" in str(sent_em["To"])
    assert sent_em["Message-ID"] == res.message_id
