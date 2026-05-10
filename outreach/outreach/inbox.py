"""IMAP inbound poller.

Strategy: track UIDVALIDITY + last_uid in ``inbox_state``. On each poll,
fetch all messages with UID > last_uid in the configured folder, parse each
RFC822 envelope, try to attach it to a lead by:

1. matching ``In-Reply-To`` to a Message-ID we previously sent (most reliable)
2. matching the sender address to a lead's ``email`` field
3. matching the sender's domain to a lead's ``website`` netloc

Anything that can't be attached is logged with ``lead_id = NULL`` semantics
(actually we just skip it — the operator will see it in their mailbox).

For each attached reply we record_message + run ``classify_reply`` so the
suggested next action is ready by the time the operator opens the playbook.
"""
from __future__ import annotations

import email
import email.policy
import imaplib
import json
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from email.message import EmailMessage
from typing import Any, Iterator
from urllib.parse import urlparse

from . import config, conversation, db


@dataclass
class InboundEmail:
    uid: int
    message_id: str
    in_reply_to: str | None
    references: list[str]
    from_name: str
    from_addr: str
    to_addr: str
    subject: str
    body: str
    received_at: str
    raw: str


def _decode(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            return value.decode("latin-1", errors="replace")
    return str(value)


def _extract_body(msg: EmailMessage) -> str:
    """Best-effort plain-text body extraction."""
    if msg.is_multipart():
        # Prefer text/plain over text/html; strip tags as a last resort.
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and not part.is_attachment():
                payload = part.get_payload(decode=True) or b""
                charset = part.get_content_charset() or "utf-8"
                return payload.decode(charset, errors="replace")
        for part in msg.walk():
            if part.get_content_type() == "text/html" and not part.is_attachment():
                payload = part.get_payload(decode=True) or b""
                charset = part.get_content_charset() or "utf-8"
                html = payload.decode(charset, errors="replace")
                return re.sub(r"<[^>]+>", "", html)
        return ""
    payload = msg.get_payload(decode=True) or b""
    charset = msg.get_content_charset() or "utf-8"
    text = payload.decode(charset, errors="replace") if isinstance(payload, bytes) else str(payload)
    if msg.get_content_type() == "text/html":
        text = re.sub(r"<[^>]+>", "", text)
    return text


def _parse(raw: bytes, uid: int) -> InboundEmail:
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    from_full = _decode(msg.get("From"))
    name, addr = email.utils.parseaddr(from_full)
    to_full = _decode(msg.get("To"))
    refs_raw = _decode(msg.get("References"))
    refs = [r for r in refs_raw.split() if r] if refs_raw else []
    return InboundEmail(
        uid=uid,
        message_id=_decode(msg.get("Message-ID")) or "",
        in_reply_to=_decode(msg.get("In-Reply-To")) or None,
        references=refs,
        from_name=name or "",
        from_addr=addr or "",
        to_addr=email.utils.parseaddr(to_full)[1] or "",
        subject=_decode(msg.get("Subject")) or "",
        body=_extract_body(msg),
        received_at=_decode(msg.get("Date")) or datetime.now(timezone.utc).isoformat(),
        raw=raw.decode("utf-8", errors="replace"),
    )


# ---------- IMAP fetcher ----------

def _open_imap(cfg: config.InboxConfig) -> imaplib.IMAP4:
    if cfg.port == 993:
        imap = imaplib.IMAP4_SSL(cfg.host, cfg.port)
    else:
        imap = imaplib.IMAP4(cfg.host, cfg.port)
    imap.login(cfg.user, cfg.password)
    return imap


def fetch_new(
    cfg: config.InboxConfig,
    last_uid: int,
    *,
    imap_factory: Any = None,
) -> tuple[list[InboundEmail], int, int]:
    """Return (new_emails, new_last_uid, uidvalidity).

    Pass ``imap_factory(cfg)`` for tests; it must return an object that
    implements the imaplib.IMAP4 interface (select, uid, logout).
    """
    factory = imap_factory or _open_imap
    imap = factory(cfg)
    try:
        typ, sel = imap.select(cfg.folder)
        if typ != "OK":
            raise RuntimeError(f"IMAP SELECT failed: {sel}")
        typ, data = imap.status(cfg.folder, "(UIDVALIDITY)")
        uidvalidity = 0
        if typ == "OK" and data:
            m = re.search(rb"UIDVALIDITY (\d+)", data[0] or b"")
            if m:
                uidvalidity = int(m.group(1))

        # Fetch UIDs greater than last_uid.
        criteria = f"UID {last_uid + 1}:*" if last_uid else "ALL"
        typ, raw_uids = imap.uid("SEARCH", None, criteria)
        if typ != "OK":
            return [], last_uid, uidvalidity
        uids = [int(u) for u in (raw_uids[0] or b"").split() if u.isdigit() and int(u) > last_uid]

        results: list[InboundEmail] = []
        new_last = last_uid
        for uid in sorted(uids):
            typ, fetched = imap.uid("FETCH", str(uid).encode(), "(RFC822)")
            if typ != "OK" or not fetched or not fetched[0]:
                continue
            payload = fetched[0]
            if isinstance(payload, tuple) and len(payload) >= 2:
                results.append(_parse(payload[1], uid))
                new_last = max(new_last, uid)
        return results, new_last, uidvalidity
    finally:
        try:
            imap.logout()
        except Exception:  # noqa: BLE001
            pass


# ---------- attaching to leads ----------

def _attach_lead(
    conn: sqlite3.Connection, mail: InboundEmail
) -> tuple[sqlite3.Row | None, sqlite3.Row | None, str]:
    """Return (lead_row, our_outbound_row, match_reason)."""
    # 1) In-Reply-To match against an outbound Message-ID we sent
    candidate_ids = []
    if mail.in_reply_to:
        candidate_ids.append(mail.in_reply_to.strip())
    candidate_ids.extend(mail.references)
    for cid in candidate_ids:
        if not cid:
            continue
        outbound = db.find_message_by_id(conn, cid)
        if outbound:
            lead = db.get_lead(conn, outbound["lead_id"])
            return lead, outbound, "in-reply-to"

    # 2) Sender email matches a lead's email
    if mail.from_addr:
        row = conn.execute(
            "SELECT * FROM leads WHERE lower(email) = lower(?) LIMIT 1",
            (mail.from_addr,),
        ).fetchone()
        if row:
            return row, None, "from-address"

    # 3) Sender domain matches lead website netloc
    if "@" in mail.from_addr:
        domain = mail.from_addr.split("@", 1)[1].lower()
        row = conn.execute(
            "SELECT * FROM leads WHERE lower(website) LIKE ? LIMIT 1",
            (f"%{domain}%",),
        ).fetchone()
        if row:
            return row, None, "from-domain"

    return None, None, "no-match"


def ingest(
    *,
    db_path: Any = None,
    imap_factory: Any = None,
    inbox_cfg: config.InboxConfig | None = None,
    classify: bool = True,
) -> dict[str, Any]:
    """Poll once, attach replies to leads, classify each.

    Returns a summary: { fetched, attached, classified, unattached }.
    """
    inbox_cfg = inbox_cfg or config.load_inbox()

    with db.session(db_path) as conn:
        _, last_uid = db.get_inbox_cursor(conn, inbox_cfg.folder)

    mails, new_last_uid, uidvalidity = fetch_new(
        inbox_cfg, last_uid, imap_factory=imap_factory
    )

    fetched = len(mails)
    attached = 0
    classified = 0
    unattached: list[dict[str, str]] = []

    with db.session(db_path) as conn:
        for mail in mails:
            lead, outbound, reason = _attach_lead(conn, mail)
            if not lead:
                unattached.append({
                    "from": mail.from_addr,
                    "subject": mail.subject,
                    "uid": str(mail.uid),
                })
                continue
            attached += 1

            # Reuse the thread_id from the outbound (Message-ID of first_touch),
            # falling back to the in_reply_to if outbound isn't found.
            thread_id = (outbound["thread_id"] if outbound else None) or mail.in_reply_to

            inbound_id = db.record_message(
                conn, lead["id"],
                direction="inbound",
                channel="email",
                subject=mail.subject,
                body=mail.body,
                raw=mail.raw,
                message_id=mail.message_id,
                in_reply_to=mail.in_reply_to,
                thread_id=thread_id,
                from_addr=mail.from_addr,
                to_addr=mail.to_addr,
            )

            if classify:
                plan_blob = json.loads(lead["conversation"] or "{}")
                if plan_blob:
                    history = [dict(m) for m in db.message_history(conn, lead["id"])]
                    incoming = {
                        "subject": mail.subject,
                        "body": mail.body,
                        "from": mail.from_addr,
                        "received_at": mail.received_at,
                    }
                    try:
                        verdict = conversation.classify_reply(
                            dict(lead), plan_blob, history, incoming
                        )
                    except Exception as exc:  # noqa: BLE001
                        verdict = {
                            "classification": "unclear",
                            "must_human_review": True,
                            "rationale": f"classify_reply failed: {exc}",
                            "confidence": 0.0,
                        }
                    conn.execute(
                        """UPDATE messages SET classification = ?, confidence = ?
                           WHERE id = ?""",
                        (verdict.get("classification"),
                         verdict.get("confidence"),
                         inbound_id),
                    )
                    db.update_lead(
                        conn, lead["id"],
                        status="replied",
                        next_action_at=None,   # operator owns the next move
                        last_error=None,
                    )
                    classified += 1

        if new_last_uid > last_uid:
            db.set_inbox_cursor(conn, inbox_cfg.folder, uidvalidity, new_last_uid)

    return {
        "fetched": fetched,
        "attached": attached,
        "classified": classified,
        "unattached": unattached,
        "new_last_uid": new_last_uid,
    }
