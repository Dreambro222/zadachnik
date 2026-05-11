"""Tests for outreach.smartlead — payload builders + HTTP client wiring."""
from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from outreach import smartlead


PLAN = {
    "first_touch": {
        "subject": "Bulk RHD Tiggo for Motus Q3",
        "body":    "Hi Ockert,\n\nWe ship Chery 8-Pro RHD in lots of 200…",
        "compliance_footer": "Reply UNSUBSCRIBE to opt out. POPIA s.69.",
    },
    "followups": [
        {"step_key": "followup_1",  "day_offset": 5,  "subject": "Re: Tiggo", "body": "Bump 1."},
        {"step_key": "followup_2",  "day_offset": 10, "subject": "Re: Tiggo", "body": "Bump 2."},
        {"step_key": "nurture_30d", "day_offset": 30, "subject": "Re: Tiggo", "body": "FYI."},
    ],
}

LEAD = {
    "id": 42,
    "company": "Motus Holdings Ltd",
    "email":   "ockert@motus.co.za",
    "phone":   "+27 11 532 9510",
    "website": "https://www.motus.co.za",
    "contact_name": "Ockert Janse van Rensburg",
    "hq_city": "Sandton",
    "priority": "A",
    "channel": "email",
}

SENDER = {
    "name": "Pavel",
    "role": "Director, Partnerships SADC",
    "company": "Acme Trading FZE",
    "email": "pavel@acme.africa",
    "phone": "+971 4 000 0000",
    "website": "https://acme.africa",
}


# ---------- payload builders ----------

def test_step_message_pulls_first_touch() -> None:
    subject, body, footer = smartlead.step_message(PLAN, "first_touch")
    assert "Tiggo" in subject
    assert "Hi Ockert" in body
    assert "POPIA" in footer


def test_step_message_pulls_followup() -> None:
    _, body, _ = smartlead.step_message(PLAN, "followup_1")
    assert body == "Bump 1."


def test_step_message_raises_on_unknown_step() -> None:
    with pytest.raises(KeyError):
        smartlead.step_message(PLAN, "nope")


def test_build_sequence_template_has_four_steps_with_day_offsets() -> None:
    seq = smartlead.build_sequence_template(SENDER)
    assert len(seq) == 4
    assert [s["seq_delay_details"]["delay_in_days"] for s in seq] == [0, 5, 10, 30]
    # Step 1 carries the {{subject_...}} placeholder; followups inherit thread.
    assert "{{subject_first_touch}}" in seq[0]["subject"]
    assert seq[1]["subject"] == ""
    # Sender block + footer baked into every body.
    assert "{{body_first_touch}}" in seq[0]["email_body"]
    assert "{{body_followup_1}}"  in seq[1]["email_body"]
    assert "{{compliance_footer}}" in seq[0]["email_body"]
    assert "Acme Trading FZE" in seq[0]["email_body"]


def test_build_lead_payload_carries_personalised_vars() -> None:
    payload = smartlead.build_lead_payload(LEAD, PLAN)
    assert payload["email"] == "ockert@motus.co.za"
    assert payload["first_name"] == "Ockert"
    assert payload["last_name"].startswith("Janse")
    assert payload["company_name"] == "Motus Holdings Ltd"
    assert payload["website"] == "https://www.motus.co.za"

    cv = payload["custom_fields"]
    assert cv["subject_first_touch"] == "Bulk RHD Tiggo for Motus Q3"
    assert cv["body_first_touch"].startswith("Hi Ockert")
    assert cv["body_followup_1"] == "Bump 1."
    assert cv["body_nurture_30d"] == "FYI."
    assert cv["compliance_footer"].startswith("Reply UNSUBSCRIBE")
    assert cv["our_lead_id"] == "42"
    assert cv["priority"] == "A"


def test_build_lead_payload_handles_missing_followup() -> None:
    plan_no_f2 = {
        "first_touch": PLAN["first_touch"],
        "followups":   [PLAN["followups"][0]],   # only followup_1
    }
    cv = smartlead.build_lead_payload(LEAD, plan_no_f2)["custom_fields"]
    assert cv["body_followup_1"] == "Bump 1."
    # Missing follow-ups land as empty strings — Smartlead just skips the step.
    assert cv["body_followup_2"] == ""
    assert cv["body_nurture_30d"] == ""


def test_build_lead_payload_lowercases_email_and_strips() -> None:
    lead = {**LEAD, "email": "  OCKERT@motus.co.za "}
    payload = smartlead.build_lead_payload(lead, PLAN)
    assert payload["email"] == "ockert@motus.co.za"


def test_webhook_step_from_event_round_trips_through_indexes() -> None:
    assert smartlead.webhook_step_from_event({"sequence_step_no": 1}) == "first_touch"
    assert smartlead.webhook_step_from_event({"sequence_step_no": 2}) == "followup_1"
    assert smartlead.webhook_step_from_event({"sequence_number":  3}) == "followup_2"
    assert smartlead.webhook_step_from_event({"step_number":      4}) == "nurture_30d"
    assert smartlead.webhook_step_from_event({"sequence_step_no": 99}) is None
    assert smartlead.webhook_step_from_event({"sequence_step_no": None}) is None
    assert smartlead.webhook_step_from_event({}) is None


# ---------- HTTP client wiring ----------

def _mock_transport(handler) -> httpx.Client:
    """Wrap a callable(request)→Response into an httpx.Client."""
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_client_attaches_api_key_query_param() -> None:
    captured: dict[str, Any] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        captured["url"] = str(req.url)
        captured["method"] = req.method
        captured["body"] = json.loads(req.content) if req.content else None
        return httpx.Response(200, json={"id": 12345})

    cfg = smartlead.SmartleadConfig(api_key="sk-test-xyz", base_url="https://test")
    client = smartlead.SmartleadClient(cfg, http=_mock_transport(handler))

    result = client.create_campaign(name="hello")

    assert result == {"id": 12345}
    assert "api_key=sk-test-xyz" in captured["url"]
    assert captured["method"] == "POST"
    assert captured["url"].startswith("https://test/campaigns/create")
    assert captured["body"] == {"name": "hello"}


def test_client_raises_smartleaderror_on_4xx() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(401, text="bad key")

    cfg = smartlead.SmartleadConfig(api_key="sk-test", base_url="https://test")
    client = smartlead.SmartleadClient(cfg, http=_mock_transport(handler))

    with pytest.raises(smartlead.SmartleadError, match="HTTP 401"):
        client.create_campaign(name="x")


def test_client_raises_when_body_has_ok_false() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ok": False, "error": "campaign exists"})

    cfg = smartlead.SmartleadConfig(api_key="sk-test", base_url="https://test")
    client = smartlead.SmartleadClient(cfg, http=_mock_transport(handler))

    with pytest.raises(smartlead.SmartleadError, match="campaign exists"):
        client.create_campaign(name="x")


def test_add_leads_posts_correct_envelope() -> None:
    captured: dict[str, Any] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        captured["path"] = req.url.path
        captured["body"] = json.loads(req.content)
        return httpx.Response(200, json={
            "upload_count": 1,
            "created_leads": [{"email": LEAD["email"], "id": 9001}],
        })

    cfg = smartlead.SmartleadConfig(api_key="k", base_url="https://test")
    client = smartlead.SmartleadClient(cfg, http=_mock_transport(handler))
    payload = smartlead.build_lead_payload(LEAD, PLAN)

    resp = client.add_leads(123, [payload])

    assert captured["path"] == "/campaigns/123/leads"
    assert captured["body"]["lead_list"][0]["email"] == "ockert@motus.co.za"
    assert resp["created_leads"][0]["id"] == 9001


def test_register_webhook_posts_event_types_and_secret() -> None:
    captured: dict[str, Any] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        captured["path"] = req.url.path
        captured["body"] = json.loads(req.content)
        return httpx.Response(200, json={"ok": True, "id": 7})

    cfg = smartlead.SmartleadConfig(api_key="k", base_url="https://test")
    client = smartlead.SmartleadClient(cfg, http=_mock_transport(handler))

    client.register_webhook(
        99, url="https://outreach.example/webhook/smartlead",
        event_types=["EMAIL_REPLY", "EMAIL_BOUNCE"], secret="hush",
    )

    assert captured["path"] == "/campaigns/99/webhooks"
    assert captured["body"]["webhook_url"].endswith("/webhook/smartlead")
    assert captured["body"]["event_types"] == ["EMAIL_REPLY", "EMAIL_BOUNCE"]
    assert captured["body"]["secret"] == "hush"
