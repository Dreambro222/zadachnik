"""HTTP webhook receiver for Smartlead.ai events.

Smartlead POSTs to our URL on EMAIL_SENT / EMAIL_REPLY / EMAIL_BOUNCE /
LEAD_UNSUBSCRIBED / LEAD_CATEGORY_UPDATED. We translate each event into a
row in `messages` (or a flag on `leads`) and run our Claude classifier on
replies — same pipeline as the legacy IMAP poll.

Design choices:
  • Stdlib http.server only — no Flask/FastAPI dependency. One endpoint,
    POST only, ~150 LOC. In production put nginx in front for TLS.
  • Idempotent: every event carries a (campaign_id, lead_id, sequence_no,
    event_type, time) tuple → we hash it into messages.smartlead_event_id
    and a unique index drops re-deliveries.
  • Optional HMAC-SHA256 verification via X-Smartlead-Signature header,
    matched against SMARTLEAD_WEBHOOK_SECRET in .env.
  • Synchronous DB writes; if Smartlead retries, that's fine — INSERT will
    UNIQUE-fail and we return 200 anyway.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Callable

from . import conversation, db, smartlead

log = logging.getLogger("outreach.webhook")


# ---------- core dispatch ----------

# Smartlead's authoritative event names.  Anything else → 200 + log.
EVENTS_HANDLED = frozenset({
    "EMAIL_SENT", "EMAIL_REPLY", "EMAIL_BOUNCE",
    "LEAD_UNSUBSCRIBED", "LEAD_CATEGORY_UPDATED",
})


def event_fingerprint(event: dict[str, Any]) -> str:
    """Stable hash used as messages.smartlead_event_id for idempotency."""
    parts = (
        str(event.get("event_type", "")),
        str(event.get("campaign_id", "")),
        str(event.get("lead_id", "")),
        str(event.get("sequence_step_no") or event.get("sequence_number") or ""),
        str(event.get("event_timestamp") or event.get("time_stamp") or ""),
        str(event.get("message_id") or ""),
    )
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:32]


def _find_lead(conn, event: dict[str, Any]) -> dict[str, Any] | None:
    """Locate our lead by Smartlead's IDs, falling back to email."""
    smid = event.get("lead_id")
    if smid is not None:
        try:
            row = db.find_lead_by_smartlead_id(conn, int(smid))
            if row:
                return dict(row)
        except (TypeError, ValueError):
            pass
    # Smartlead echoes the lead's email back on every event.
    email = event.get("lead_email") or event.get("from_email")
    if email:
        row = db.find_lead_by_email(conn, email)
        if row:
            return dict(row)
    return None


def handle_email_sent(conn, lead: dict, event: dict, fingerprint: str) -> str:
    step = smartlead.webhook_step_from_event(event) or "first_touch"
    db.record_message(
        conn, lead["id"],
        direction="outbound", channel="email", step=step,
        subject=event.get("subject"),
        body=event.get("text_body") or event.get("html_body"),
        message_id=event.get("message_id"),
        from_addr=event.get("from_email"),
        to_addr=event.get("lead_email"),
        raw=json.dumps(event, ensure_ascii=False)[:64_000],
        smartlead_event_id=fingerprint,
    )
    # Status transitions: only first_touch flips 'pushed' → 'sent'.
    new_status = "sent" if step == "first_touch" else lead["status"]
    db.update_lead(
        conn, lead["id"],
        status=new_status,
        current_step=step,
        last_error=None,
    )
    return f"EMAIL_SENT  step={step}  lead#{lead['id']}"


def handle_email_reply(conn, lead: dict, event: dict, fingerprint: str) -> str:
    plan_blob = json.loads(lead.get("conversation") or "{}")
    history = [dict(r) for r in db.message_history(conn, lead["id"])]
    inbound = {
        "subject": event.get("subject"),
        "body":    event.get("text_body") or event.get("html_body") or "",
        "from":    event.get("from_email") or event.get("lead_email"),
    }
    inbound_id = db.record_message(
        conn, lead["id"],
        direction="inbound", channel="email",
        subject=inbound["subject"], body=inbound["body"],
        message_id=event.get("message_id"),
        in_reply_to=event.get("in_reply_to"),
        from_addr=inbound["from"],
        to_addr=event.get("to_email"),
        raw=json.dumps(event, ensure_ascii=False)[:64_000],
        smartlead_event_id=fingerprint,
    )

    try:
        verdict = conversation.classify_reply(
            lead, plan_blob, history, inbound,
        )
    except Exception as exc:
        log.warning("classify_reply failed for lead %s: %s", lead["id"], exc)
        verdict = {"classification": "unclear", "confidence": 0.0}

    conn.execute(
        "UPDATE messages SET classification = ?, confidence = ? WHERE id = ?",
        (verdict.get("classification"), verdict.get("confidence"), inbound_id),
    )
    db.update_lead(
        conn, lead["id"],
        status="replied",
        next_action_at=None,    # operator owns the next move (see ARCHITECTURE)
        last_error=None,
    )
    return (
        f"EMAIL_REPLY  lead#{lead['id']}  "
        f"class={verdict.get('classification')}  conf={verdict.get('confidence')}"
    )


def handle_email_bounce(conn, lead: dict, event: dict, fingerprint: str) -> str:
    db.record_message(
        conn, lead["id"],
        direction="inbound", channel="email", step="bounce",
        body=event.get("bounce_reason") or "(no reason)",
        raw=json.dumps(event, ensure_ascii=False)[:64_000],
        smartlead_event_id=fingerprint,
    )
    db.update_lead(
        conn, lead["id"],
        status="failed",
        next_action_at=None,
        last_error=f"bounce: {event.get('bounce_reason') or 'unknown'}",
    )
    return f"EMAIL_BOUNCE  lead#{lead['id']}"


def handle_unsubscribe(conn, lead: dict, event: dict, fingerprint: str) -> str:
    db.record_message(
        conn, lead["id"],
        direction="inbound", channel="email", step="unsubscribe",
        body="(lead clicked unsubscribe in Smartlead)",
        raw=json.dumps(event, ensure_ascii=False)[:64_000],
        smartlead_event_id=fingerprint,
    )
    db.update_lead(
        conn, lead["id"],
        status="unsubscribed",
        next_action_at=None,
        do_form_outreach=0,
    )
    return f"LEAD_UNSUBSCRIBED  lead#{lead['id']}"


def handle_category_updated(conn, lead: dict, event: dict, fingerprint: str) -> str:
    """Smartlead has its own reply-categories (Interested / Not now / OOO / ...).
    We surface that as a status note but trust our Claude classifier more,
    so we don't overwrite `status` here."""
    db.update_lead(
        conn, lead["id"],
        last_error=f"smartlead_category: {event.get('category') or 'unknown'}",
    )
    return f"CATEGORY_UPDATED  lead#{lead['id']}  category={event.get('category')}"


HANDLERS: dict[str, Callable[..., str]] = {
    "EMAIL_SENT":            handle_email_sent,
    "EMAIL_REPLY":           handle_email_reply,
    "EMAIL_BOUNCE":          handle_email_bounce,
    "LEAD_UNSUBSCRIBED":     handle_unsubscribe,
    "LEAD_CATEGORY_UPDATED": handle_category_updated,
}


def dispatch(event: dict[str, Any]) -> str:
    """The single entry-point a webhook handler / test calls.

    Returns a human-readable status line. Raises only on programmer error;
    business errors (unknown lead, bad event) are logged and returned as
    descriptive strings — the HTTP layer always returns 200 to Smartlead.
    """
    event_type = event.get("event_type") or event.get("type") or ""
    if event_type not in EVENTS_HANDLED:
        return f"ignored event_type={event_type!r}"

    fingerprint = event_fingerprint(event)

    with db.session() as conn:
        if db.find_message_by_event(conn, fingerprint):
            return f"duplicate event {fingerprint} — skipped"

        lead = _find_lead(conn, event)
        if not lead:
            return (
                f"no matching lead (smartlead_lead_id={event.get('lead_id')}, "
                f"email={event.get('lead_email')!r}) — event dropped"
            )

        return HANDLERS[event_type](conn, lead, event, fingerprint)


# ---------- HTTP layer ----------

def verify_signature(body: bytes, header: str | None, secret: str) -> bool:
    if not header:
        return False
    expected = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    # Smartlead sends just the hex; some integrations prefix "sha256=".
    received = header.removeprefix("sha256=").strip()
    return hmac.compare_digest(expected, received)


class WebhookHandler(BaseHTTPRequestHandler):
    """One-endpoint receiver. POST /webhook/smartlead → dispatch(event)."""

    smartlead_secret: str | None = None     # set by `serve_forever`

    def _respond(self, status: int, body: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body.encode("utf-8"))))
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        # Cheap health-check for k8s/uptime monitoring.
        if self.path in ("/", "/health"):
            self._respond(200, "ok")
        else:
            self._respond(404, "not found")

    def do_POST(self) -> None:  # noqa: N802
        if self.path not in ("/webhook/smartlead", "/smartlead"):
            self._respond(404, "not found")
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if self.smartlead_secret:
            sig = self.headers.get("X-Smartlead-Signature")
            if not verify_signature(body, sig, self.smartlead_secret):
                log.warning("rejected webhook with bad signature from %s",
                            self.client_address[0])
                self._respond(401, "bad signature")
                return

        try:
            event = json.loads(body or b"{}")
        except json.JSONDecodeError:
            self._respond(400, "invalid json")
            return

        # Smartlead occasionally batches events into a list.
        events = event if isinstance(event, list) else [event]
        lines: list[str] = []
        for one in events:
            try:
                lines.append(dispatch(one))
            except Exception as exc:           # noqa: BLE001 — never crash on Smartlead
                log.exception("dispatch failed: %s", exc)
                lines.append(f"error: {exc}")

        self._respond(200, "\n".join(lines))

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default
        log.info("%s - " + fmt, self.address_string(), *args)


def serve(host: str = "0.0.0.0", port: int = 8080, secret: str | None = None) -> None:
    """Block-and-serve. Call from `outreach webhook --serve`."""
    WebhookHandler.smartlead_secret = secret
    httpd = HTTPServer((host, port), WebhookHandler)
    log.info("Smartlead webhook listening on http://%s:%s/webhook/smartlead",
             host, port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log.info("shutdown")
        httpd.server_close()
