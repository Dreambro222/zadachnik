"""Polling-based replacement for the webhook receiver.

When running laptop-local (no public server, no Smartlead webhook), we
pull state from the Smartlead REST API every N minutes and replay it
into the same `leads` / `messages` tables that webhook.py writes to.

Pipeline per run:
  1. For each campaign in (SMARTLEAD_CAMPAIGN_ID or every campaign in
     workspace), GET /campaigns/{id}/statistics-replies.
  2. For every reply we haven't seen before (idempotency via
     `smartlead_event_id` exactly like webhook.py uses):
        - record_message(direction='inbound', channel='email', ...)
        - conversation.classify_reply(...)  — same Claude call as webhook
        - update_lead(status='replied', next_action_at=NULL)
  3. For each lead in the campaign, GET /campaigns/{id}/leads/{lead_id}
     and reconcile `current_step` based on Smartlead's
     `sequence_step` / `last_email_sequence_sent`.
  4. Bounces + unsubscribes: read off the lead's `email_lead_status`
     field — Smartlead exposes it on the lead record.

Trade-offs vs webhook:
  + No server, no DNS, no certbot, no inbound HTTP.
  - Up to `--interval` minutes latency on reply ingestion.
  - More Smartlead API calls (still well inside their 10 rps quota
    for a single workspace).
"""
from __future__ import annotations

import hashlib
import json
import logging
import sqlite3
import time
from dataclasses import dataclass
from typing import Any

from . import conversation, db, smartlead

log = logging.getLogger("outreach.sync")


# ---------- per-run summary ----------

@dataclass
class SyncStats:
    """Returned by sync_once() so the CLI can render a one-line report."""
    campaigns:         int = 0
    leads_inspected:   int = 0
    replies_new:       int = 0
    replies_skipped:   int = 0   # duplicates by smartlead_event_id
    sends_recorded:    int = 0
    bounces_recorded:  int = 0
    unsubs_recorded:   int = 0
    status_updates:    int = 0
    errors:            list[str] = None       # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.errors is None:
            self.errors = []

    def as_oneline(self) -> str:
        return (
            f"campaigns={self.campaigns}  leads={self.leads_inspected}  "
            f"replies_new={self.replies_new} (dup {self.replies_skipped})  "
            f"sends={self.sends_recorded}  bounces={self.bounces_recorded}  "
            f"unsubs={self.unsubs_recorded}  status_changes={self.status_updates}  "
            f"errors={len(self.errors)}"
        )


# ---------- fingerprint (same scheme as webhook.event_fingerprint) ----------

def _reply_fingerprint(reply: dict[str, Any]) -> str:
    """Stable hash of a reply event so we can dedupe across runs."""
    parts = (
        "EMAIL_REPLY",
        str(reply.get("campaign_id", "")),
        str(reply.get("lead_id") or reply.get("smartlead_lead_id", "")),
        str(reply.get("message_id") or ""),
        str(reply.get("received_time") or reply.get("reply_time") or ""),
    )
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:32]


def _send_fingerprint(msg: dict[str, Any], lead_id: int) -> str:
    parts = (
        "EMAIL_SENT",
        str(lead_id),
        str(msg.get("sequence_step_no") or msg.get("seq_number") or ""),
        str(msg.get("sent_time") or msg.get("send_time") or ""),
        str(msg.get("message_id") or ""),
    )
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:32]


# ---------- per-event handlers ----------

def _ingest_reply(
    conn: sqlite3.Connection,
    lead: sqlite3.Row,
    reply: dict[str, Any],
    *,
    classify: bool,
) -> str:
    """Returns one of 'new' | 'duplicate' so the caller can count."""
    fp = _reply_fingerprint(reply)
    if db.find_message_by_event(conn, fp):
        return "duplicate"

    plan_blob = json.loads(lead["conversation"] or "{}")
    history = [dict(r) for r in db.message_history(conn, lead["id"])]
    inbound = {
        "subject": reply.get("subject"),
        "body":    reply.get("text_body") or reply.get("reply_message") or "",
        "from":    reply.get("from_email") or reply.get("lead_email"),
    }
    inbound_id = db.record_message(
        conn, lead["id"],
        direction="inbound", channel="email",
        subject=inbound["subject"], body=inbound["body"],
        message_id=reply.get("message_id"),
        in_reply_to=reply.get("in_reply_to"),
        from_addr=inbound["from"],
        to_addr=reply.get("to_email"),
        raw=json.dumps(reply, ensure_ascii=False)[:64_000],
        smartlead_event_id=fp,
    )

    verdict: dict[str, Any] = {"classification": "unclear", "confidence": 0.0}
    if classify:
        try:
            verdict = conversation.classify_reply(
                dict(lead), plan_blob, history, inbound,
            )
        except Exception as exc:  # noqa: BLE001 — never crash the sync loop
            log.warning("classify_reply failed for lead %s: %s", lead["id"], exc)

    conn.execute(
        "UPDATE messages SET classification = ?, confidence = ? WHERE id = ?",
        (verdict.get("classification"), verdict.get("confidence"), inbound_id),
    )
    db.update_lead(
        conn, lead["id"],
        status="replied",
        next_action_at=None,
        last_error=None,
    )
    return "new"


def _ingest_send(
    conn: sqlite3.Connection,
    lead: sqlite3.Row,
    msg: dict[str, Any],
) -> str:
    fp = _send_fingerprint(msg, lead["id"])
    if db.find_message_by_event(conn, fp):
        return "duplicate"

    step = smartlead.webhook_step_from_event(msg) or "first_touch"
    db.record_message(
        conn, lead["id"],
        direction="outbound", channel="email", step=step,
        subject=msg.get("subject"),
        body=msg.get("text_body") or msg.get("email_body"),
        message_id=msg.get("message_id"),
        from_addr=msg.get("from_email"),
        to_addr=msg.get("to_email") or lead["email"],
        raw=json.dumps(msg, ensure_ascii=False)[:64_000],
        smartlead_event_id=fp,
    )
    new_status = "sent" if step == "first_touch" else lead["status"]
    db.update_lead(
        conn, lead["id"],
        status=new_status,
        current_step=step,
        last_error=None,
    )
    return "new"


def _ingest_terminal_state(
    conn: sqlite3.Connection,
    lead: sqlite3.Row,
    smartlead_lead: dict[str, Any],
    stats: SyncStats,
) -> None:
    """Smartlead exposes `email_lead_status` / `status` per lead. We mirror
    the bounce / unsubscribe terminal states (replies handled elsewhere)."""
    status_field = (smartlead_lead.get("email_lead_status") or
                    smartlead_lead.get("status") or "").lower()

    if "bounce" in status_field and lead["status"] != "failed":
        db.update_lead(
            conn, lead["id"],
            status="failed",
            next_action_at=None,
            last_error=f"smartlead_status: {status_field}",
        )
        stats.bounces_recorded += 1
        stats.status_updates += 1
    elif "unsubscrib" in status_field and lead["status"] != "unsubscribed":
        db.update_lead(
            conn, lead["id"],
            status="unsubscribed",
            next_action_at=None,
            do_form_outreach=0,
        )
        stats.unsubs_recorded += 1
        stats.status_updates += 1


# ---------- main entry points ----------

def sync_once(
    client: smartlead.SmartleadClient,
    *,
    campaign_ids: list[int] | None = None,
    classify: bool = True,
) -> SyncStats:
    """One full sync pass: replies + sends + terminal states."""
    stats = SyncStats()

    if campaign_ids is None:
        # Pull every campaign in the workspace.
        try:
            resp = client._request("GET", "/campaigns/")
        except smartlead.SmartleadError as exc:
            stats.errors.append(f"list campaigns: {exc}")
            return stats
        if isinstance(resp, dict):
            resp = resp.get("data") or resp.get("campaigns") or []
        campaign_ids = [c["id"] for c in resp if isinstance(c, dict) and c.get("id")]

    with db.session() as conn:
        for cid in campaign_ids:
            stats.campaigns += 1
            try:
                _sync_one_campaign(conn, client, cid, stats=stats, classify=classify)
            except smartlead.SmartleadError as exc:
                stats.errors.append(f"campaign {cid}: {exc}")
            except Exception as exc:  # noqa: BLE001
                stats.errors.append(f"campaign {cid}: unexpected {exc!r}")
                log.exception("unexpected error syncing campaign %s", cid)

    return stats


def _sync_one_campaign(
    conn: sqlite3.Connection,
    client: smartlead.SmartleadClient,
    campaign_id: int,
    *,
    stats: SyncStats,
    classify: bool,
) -> None:
    # 1. Inbound replies — single endpoint, cheaper than walking every lead.
    offset, batch_size = 0, 100
    while True:
        replies = client.campaign_replies(
            campaign_id, offset=offset, limit=batch_size,
        )
        if not replies:
            break
        for reply in replies:
            lead = _resolve_lead(conn, reply)
            if not lead:
                continue
            outcome = _ingest_reply(conn, lead, reply, classify=classify)
            if outcome == "new":
                stats.replies_new += 1
            else:
                stats.replies_skipped += 1
        if len(replies) < batch_size:
            break
        offset += batch_size

    # 2. Walk leads — pick up sends + terminal states. Use the cheaper
    # paginated list endpoint (no per-lead RPC unless we need detail).
    offset = 0
    while True:
        smartlead_leads = client.list_leads(
            campaign_id, offset=offset, limit=batch_size,
        )
        if not smartlead_leads:
            break
        for sl in smartlead_leads:
            lead = _resolve_lead(conn, sl)
            if not lead:
                continue
            stats.leads_inspected += 1
            _ingest_terminal_state(conn, lead, sl, stats)
            # Sends: Smartlead embeds message history if we ask for it.
            # We only fetch when sequence_step advanced beyond what we know.
            advanced = _smartlead_step_index(sl)
            if advanced and advanced > _our_step_index(lead):
                msgs = client.lead_message_history(campaign_id, sl["id"])
                for msg in msgs:
                    if (msg.get("type") or "").lower() != "sent":
                        continue
                    if _ingest_send(conn, lead, msg) == "new":
                        stats.sends_recorded += 1
        if len(smartlead_leads) < batch_size:
            break
        offset += batch_size


def _resolve_lead(
    conn: sqlite3.Connection, payload: dict[str, Any]
) -> sqlite3.Row | None:
    """Match a Smartlead payload row to one of our leads."""
    smid = payload.get("id") or payload.get("lead_id")
    if smid is not None:
        try:
            row = db.find_lead_by_smartlead_id(conn, int(smid))
            if row:
                return row
        except (TypeError, ValueError):
            pass
    email = payload.get("email") or payload.get("lead_email")
    if email:
        return db.find_lead_by_email(conn, email)
    return None


# ---------- step-index helpers (laptop-local mirror of scheduler.next_*) -----

def _smartlead_step_index(sl_lead: dict[str, Any]) -> int:
    """1-indexed last-sent step per Smartlead. 0 if nothing sent yet."""
    for key in ("last_email_sequence_sent", "sequence_step_no",
                "sent_sequence_step"):
        val = sl_lead.get(key)
        if val is None:
            continue
        try:
            return int(val)
        except (TypeError, ValueError):
            continue
    return 0


def _our_step_index(lead: sqlite3.Row) -> int:
    """1-indexed last-completed step per our `current_step` column."""
    step = lead["current_step"] or ""
    try:
        return smartlead.SEQUENCE_STEP_NAMES.index(step) + 1
    except ValueError:
        return 0


# ---------- watch loop ----------

def watch(
    client: smartlead.SmartleadClient,
    *,
    interval_seconds: int = 300,
    campaign_ids: list[int] | None = None,
    classify: bool = True,
) -> None:
    """Block-and-poll. Stops on KeyboardInterrupt; safe to re-run."""
    log.info("sync watch loop — interval=%ss", interval_seconds)
    while True:
        started = time.monotonic()
        stats = sync_once(
            client, campaign_ids=campaign_ids, classify=classify,
        )
        log.info("sync: %s", stats.as_oneline())
        for err in stats.errors:
            log.warning("sync error: %s", err)
        elapsed = time.monotonic() - started
        sleep_for = max(5, interval_seconds - int(elapsed))
        try:
            time.sleep(sleep_for)
        except KeyboardInterrupt:
            log.info("sync stopped by Ctrl-C")
            return
