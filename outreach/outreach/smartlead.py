"""Smartlead.ai API client + payload builders.

Thick-mode integration: Smartlead owns sending, inbox rotation, warmup
and the daily cadence. We push:

  • a *sequence template* once per campaign — built around {{custom_var}}
    placeholders (subject/body for each step).
  • a *lead* per row with the placeholders filled from our Claude-generated
    plan blob.

After that Smartlead does the work and pings our webhook (see webhook.py)
on EMAIL_SENT / EMAIL_REPLY / EMAIL_BOUNCE / LEAD_UNSUBSCRIBED.

API reference (public, as of 2026-05):
  https://api.smartlead.ai/  →  server.smartlead.ai/api/v1
  Auth: `?api_key=...` query param on every call.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any

import httpx

# Their docs list this as the stable base. They sometimes mirror at
# api.smartlead.ai; both resolve to the same backend.
DEFAULT_BASE_URL = "https://server.smartlead.ai/api/v1"

# Our 4-step cadence (matches scheduler.CADENCE_STEPS). Smartlead numbers
# its sequence steps 1..N; this is how we translate when we read the
# sequence_step field on inbound webhooks.
SEQUENCE_STEP_NAMES = ("first_touch", "followup_1", "followup_2", "nurture_30d")
SEQUENCE_DAY_OFFSETS = (0, 5, 10, 30)


# ---------- config ----------

@dataclass
class SmartleadConfig:
    api_key: str
    base_url: str = DEFAULT_BASE_URL
    default_campaign_id: int | None = None
    webhook_secret: str | None = None   # optional HMAC for X-Smartlead-Signature
    timeout_seconds: float = 20.0


def load_smartlead() -> SmartleadConfig:
    """Read SMARTLEAD_* env vars. Raises if SMARTLEAD_API_KEY is missing."""
    from . import config as cfg
    cfg.load_env()
    key = os.environ.get("SMARTLEAD_API_KEY", "").strip()
    if not key:
        raise RuntimeError(
            "SMARTLEAD_API_KEY must be set in .env. See .env.example."
        )
    raw_campaign = os.environ.get("SMARTLEAD_CAMPAIGN_ID", "").strip()
    return SmartleadConfig(
        api_key=key,
        base_url=os.environ.get("SMARTLEAD_BASE_URL", DEFAULT_BASE_URL).rstrip("/"),
        default_campaign_id=int(raw_campaign) if raw_campaign else None,
        webhook_secret=os.environ.get("SMARTLEAD_WEBHOOK_SECRET") or None,
        timeout_seconds=float(os.environ.get("SMARTLEAD_TIMEOUT") or 20.0),
    )


# ---------- HTTP client ----------

class SmartleadError(RuntimeError):
    """Raised when Smartlead returns a non-2xx OR ok=false body."""


@dataclass
class SmartleadClient:
    """Thin wrapper over httpx. One instance per CLI invocation is fine —
    Smartlead's rate limit is generous (~10 req/s per workspace)."""

    cfg: SmartleadConfig
    http: httpx.Client = field(default=None, repr=False)  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.http is None:
            self.http = httpx.Client(timeout=self.cfg.timeout_seconds)

    def _url(self, path: str) -> str:
        path = path if path.startswith("/") else f"/{path}"
        return f"{self.cfg.base_url}{path}"

    def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        params = kwargs.pop("params", {}) or {}
        params["api_key"] = self.cfg.api_key
        resp = self.http.request(method, self._url(path), params=params, **kwargs)
        if resp.status_code >= 400:
            raise SmartleadError(
                f"{method} {path} → HTTP {resp.status_code}: {resp.text[:300]}"
            )
        if not resp.content:
            return {}
        try:
            body = resp.json()
        except json.JSONDecodeError as exc:
            raise SmartleadError(
                f"{method} {path} returned non-JSON: {resp.text[:300]}"
            ) from exc
        # Smartlead returns either {"ok": true, ...} or {"ok": false, "error": ...}
        # plus older endpoints return raw lists. Be tolerant.
        if isinstance(body, dict) and body.get("ok") is False:
            raise SmartleadError(f"{method} {path} → {body.get('error') or body}")
        return body

    # ----- campaign lifecycle -----

    def create_campaign(self, *, name: str, client_id: int | None = None) -> dict[str, Any]:
        payload = {"name": name}
        if client_id is not None:
            payload["client_id"] = client_id
        return self._request("POST", "/campaigns/create", json=payload)

    def update_sequence(
        self, campaign_id: int, sequence: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Set the sequence template. `sequence` is a list of step dicts:
            {"seq_number": 1, "seq_delay_details": {"delay_in_days": 0},
             "subject": "...", "email_body": "...", "variant_label": "A"}
        Body MAY contain Smartlead's {{var}} placeholders."""
        return self._request(
            "POST", f"/campaigns/{campaign_id}/sequences",
            json={"sequences": sequence},
        )

    def assign_email_accounts(
        self, campaign_id: int, email_account_ids: list[int]
    ) -> dict[str, Any]:
        return self._request(
            "POST", f"/campaigns/{campaign_id}/email-accounts",
            json={"email_account_ids": email_account_ids},
        )

    def update_settings(
        self,
        campaign_id: int,
        *,
        daily_limit: int | None = None,
        track_opens: bool | None = None,
        track_clicks: bool | None = None,
        stop_lead_settings: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {}
        if daily_limit is not None:
            payload["max_leads_per_day"] = daily_limit
        if track_opens is not None:
            payload["track_settings"] = (
                ["DONT_TRACK_EMAIL_OPEN", "DONT_TRACK_LINK_CLICK"]
                if not (track_opens and track_clicks)
                else []
            )
        if stop_lead_settings:
            # 'REPLY_TO_AN_EMAIL' (default) | 'CLICK_ON_A_LINK' | 'OPEN_AN_EMAIL'
            payload["stop_lead_settings"] = stop_lead_settings
        return self._request(
            "POST", f"/campaigns/{campaign_id}/settings", json=payload,
        )

    def set_status(self, campaign_id: int, status: str) -> dict[str, Any]:
        # status: START | PAUSED | STOPPED
        return self._request(
            "POST", f"/campaigns/{campaign_id}/status",
            json={"status": status},
        )

    def register_webhook(
        self,
        campaign_id: int,
        *,
        url: str,
        event_types: list[str],
        name: str = "outreach-toolkit",
        secret: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "name": name,
            "webhook_url": url,
            "event_types": event_types,
        }
        if secret:
            payload["secret"] = secret
        return self._request(
            "POST", f"/campaigns/{campaign_id}/webhooks", json=payload,
        )

    # ----- lead push -----

    def add_leads(
        self, campaign_id: int, leads: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Bulk-add leads. Each lead dict must have at least `email` and may
        carry a `custom_fields` sub-dict for sequence-template placeholders."""
        return self._request(
            "POST", f"/campaigns/{campaign_id}/leads",
            json={"lead_list": leads},
        )

    def get_lead_status(
        self, campaign_id: int, lead_id: int
    ) -> dict[str, Any]:
        return self._request(
            "GET", f"/campaigns/{campaign_id}/leads/{lead_id}",
        )


# ---------- payload builders ----------

def step_message(plan: dict[str, Any], step: str) -> tuple[str, str, str]:
    """Pull (subject, body, footer) for one cadence step out of the plan blob.

    Mirrors cli._step_message but lives here so smartlead.py is import-time
    independent of cli.py.
    """
    footer = ((plan.get("first_touch") or {}).get("compliance_footer") or "").strip()

    if step == "first_touch":
        ft = plan.get("first_touch") or {}
        return ft.get("subject", ""), ft.get("body", ""), footer

    for f in plan.get("followups") or []:
        if f.get("step_key") == step:
            return f.get("subject", ""), f.get("body", ""), footer

    raise KeyError(f"step `{step}` not in plan")


def build_sequence_template(
    sender: dict[str, Any],
) -> list[dict[str, Any]]:
    """Build the {{var}}-based sequence template that gets POSTed once to
    Smartlead per campaign. Per-lead content arrives via custom_fields.

    Subjects are short variables (`{{subject_first_touch}}` etc.) because
    Smartlead's UI lets you template subjects too. Bodies include the
    POPIA-compliance footer.
    """
    sender_block = (
        f"\n\n--\n{sender.get('name','')}\n"
        f"{sender.get('role','')}\n"
        f"{sender.get('company','')}\n"
        f"{sender.get('email','')}  |  {sender.get('phone','')}\n"
        f"{sender.get('website','')}"
    ).rstrip()

    sequence = []
    for idx, step in enumerate(SEQUENCE_STEP_NAMES, start=1):
        body_var = f"body_{step}"
        sequence.append({
            "seq_number": idx,
            "seq_delay_details": {"delay_in_days": SEQUENCE_DAY_OFFSETS[idx - 1]},
            "subject": "{{subject_" + step + "}}" if idx == 1 else "",
            # Empty subject on followups → Smartlead threads automatically
            # under the first email (proper Re: handling).
            "email_body": (
                "{{" + body_var + "}}\n"
                + sender_block
                + "\n\n{{compliance_footer}}"
            ),
            "variant_label": "A",
        })
    return sequence


def build_lead_payload(
    lead: dict[str, Any],
    plan: dict[str, Any],
    *,
    include_followups: bool = True,
) -> dict[str, Any]:
    """One lead row for POST /campaigns/{id}/leads.

    `lead` is the sqlite3.Row coerced to dict. `plan` is the Claude-generated
    blob from leads.conversation. Returns the Smartlead-shaped payload with
    `custom_fields` for every cadence step.
    """
    ft_subject, ft_body, footer = step_message(plan, "first_touch")
    custom: dict[str, str] = {
        "subject_first_touch": ft_subject,
        "body_first_touch":    ft_body,
        "compliance_footer":   footer,
        # Useful metadata for the operator looking at Smartlead's UI.
        "our_lead_id":         str(lead["id"]),
        "company_name":        lead.get("company") or "",
        "priority":            lead.get("priority") or "",
        "channel":             lead.get("channel") or "email",
    }

    if include_followups:
        for step in SEQUENCE_STEP_NAMES[1:]:
            try:
                _, body, _ = step_message(plan, step)
            except KeyError:
                body = ""  # Smartlead will skip the step
            custom[f"body_{step}"] = body

    payload: dict[str, Any] = {
        "email":        (lead.get("email") or "").strip().lower(),
        "first_name":   (lead.get("contact_name") or "").split(" ")[0] if lead.get("contact_name") else "",
        "last_name":    " ".join((lead.get("contact_name") or "").split(" ")[1:]),
        "company_name": lead.get("company") or "",
        "phone_number": lead.get("phone") or "",
        "website":      lead.get("website") or "",
        "location":     lead.get("hq_city") or "",
        "custom_fields": custom,
    }
    return payload


def webhook_step_from_event(event: dict[str, Any]) -> str | None:
    """Map an inbound webhook payload's sequence step → our step name.

    Smartlead sends `sequence_step_no` (1-indexed) on EMAIL_SENT events.
    On EMAIL_REPLY / EMAIL_BOUNCE the `sequence_number` field carries the
    same value. Returns None if the index is out of bounds.
    """
    for key in ("sequence_step_no", "sequence_number", "step_number"):
        if key in event and event[key] is not None:
            try:
                idx = int(event[key])
            except (TypeError, ValueError):
                continue
            if 1 <= idx <= len(SEQUENCE_STEP_NAMES):
                return SEQUENCE_STEP_NAMES[idx - 1]
    return None
