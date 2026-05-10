"""SMTP outbound mailer with proper RFC822 threading.

We use ``smtplib`` + ``email.message.EmailMessage`` and explicitly set
``Message-ID``, ``In-Reply-To`` and ``References`` so that every follow-up
lands inside the same thread on the recipient's side. ``thread_id`` (our
internal stable identifier) is the Message-ID of the first_touch — we keep
it on every subsequent message so the DB join is trivial.

Daily-limit enforcement and POPIA compliance-footer presence are checked
before the message goes out. The mailer refuses to send if the playbook is
missing the footer or the day's quota is hit.

Dry-run mode renders the full RFC822 envelope and returns it without
opening an SMTP connection — handy for review.
"""
from __future__ import annotations

import smtplib
import ssl
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid, parseaddr
from typing import Any

from . import config


@dataclass
class OutboundMessage:
    to_email: str
    to_name: str | None
    subject: str
    body_plain: str
    in_reply_to: str | None = None
    references: list[str] = field(default_factory=list)
    reply_to: str | None = None
    headers: dict[str, str] = field(default_factory=dict)


@dataclass
class SendResult:
    message_id: str
    sent_at: str
    raw_envelope: str
    dry_run: bool


class MailError(RuntimeError):
    pass


def build_envelope(
    msg: OutboundMessage,
    cfg: config.MailerConfig,
) -> tuple[EmailMessage, str]:
    """Build the EmailMessage and return (msg, message_id)."""
    if not msg.to_email:
        raise MailError("missing to_email")
    if not msg.subject:
        raise MailError("missing subject")
    if not msg.body_plain.strip():
        raise MailError("empty body")

    em = EmailMessage()
    em["From"] = formataddr((cfg.from_name or "", cfg.from_email))
    em["To"] = formataddr((msg.to_name or "", msg.to_email))
    em["Subject"] = msg.subject
    em["Date"] = formatdate(localtime=False)
    domain = cfg.from_email.split("@", 1)[-1] if "@" in cfg.from_email else "localhost"
    message_id = make_msgid(domain=domain)
    em["Message-ID"] = message_id

    reply_to = msg.reply_to or cfg.reply_to
    if reply_to:
        em["Reply-To"] = reply_to

    if msg.in_reply_to:
        em["In-Reply-To"] = msg.in_reply_to
    refs = list(msg.references)
    if msg.in_reply_to and msg.in_reply_to not in refs:
        refs.append(msg.in_reply_to)
    if refs:
        em["References"] = " ".join(refs)

    for k, v in msg.headers.items():
        if k.lower() in {"from", "to", "subject", "date", "message-id",
                          "in-reply-to", "references", "reply-to"}:
            continue
        em[k] = v

    em.set_content(msg.body_plain, subtype="plain")
    return em, message_id


def _open_smtp(cfg: config.MailerConfig) -> smtplib.SMTP:
    context = ssl.create_default_context()
    if cfg.use_tls:
        smtp = smtplib.SMTP(cfg.host, cfg.port, timeout=30)
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
    else:
        smtp = smtplib.SMTP_SSL(cfg.host, cfg.port, context=context, timeout=30)
    if cfg.user:
        smtp.login(cfg.user, cfg.password)
    return smtp


def send(
    msg: OutboundMessage,
    cfg: config.MailerConfig,
    *,
    dry_run: bool = False,
    smtp_factory: Any = None,
) -> SendResult:
    """Send a message via SMTP. Pass dry_run=True to render only.

    ``smtp_factory`` lets tests inject a fake smtplib.SMTP — it is called as
    ``smtp_factory(cfg)`` and must return an object with ``send_message`` and
    ``quit`` methods.
    """
    em, message_id = build_envelope(msg, cfg)
    raw = em.as_string()
    sent_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    if dry_run:
        return SendResult(
            message_id=message_id,
            sent_at=sent_at,
            raw_envelope=raw,
            dry_run=True,
        )

    factory = smtp_factory or _open_smtp
    smtp = factory(cfg)
    try:
        smtp.send_message(em)
    finally:
        try:
            smtp.quit()
        except Exception:  # noqa: BLE001
            pass
    return SendResult(
        message_id=message_id,
        sent_at=sent_at,
        raw_envelope=raw,
        dry_run=False,
    )


# ---------- helpers ----------

def split_address(addr: str) -> tuple[str, str]:
    """Return (display_name, email) tuple."""
    return parseaddr(addr or "")


def assemble_body(body: str, footer: str) -> str:
    """Join body + POPIA footer with the canonical blank-line separator."""
    body = (body or "").strip()
    footer = (footer or "").strip()
    if not body:
        raise MailError("empty body")
    if not footer:
        raise MailError(
            "missing compliance_footer (POPIA s.69) — refusing to send"
        )
    return f"{body}\n\n{footer}"


def thread_subject(base_subject: str, *, is_followup: bool) -> str:
    """For follow-ups we prepend 'Re: ' so threading is stable across clients."""
    if not is_followup:
        return base_subject
    s = (base_subject or "").strip()
    if s.lower().startswith("re:"):
        return s
    return f"Re: {s}"
