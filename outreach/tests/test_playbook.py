"""Smoke tests for the playbook renderer (no LLM, no network)."""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from outreach import db, playbook


def _seed_lead(db_path: Path) -> int:
    db.init_db(db_path)
    with db.session(db_path) as conn:
        lead_id = db.insert_lead(conn, {
            "company": "Eastvaal Motor Group",
            "website": "https://www.eastvaalmotors.co.za",
            "form_url": "https://www.eastvaalmotors.co.za/contact-us/",
            "email": "careers@eastvaal.co.za",
            "phone": "+27 17 634 7151",
            "country": "South Africa",
            "category": "Dealer Group",
            "priority": "A",
            "hq_city": "Secunda",
            "contact_name": "Clive Blechman",
            "contact_role": "CEO",
            "channel": "form",
            "notes": "27 brands. Already sells BAIC, BYD, GWM, Haval.",
        })
        research_blob = {
            "company_name": "Eastvaal Motor Group",
            "business_model": "Multi-franchise dealer group across 12 dealerships in Mpumalanga / NW.",
            "fleet_size_estimate": "27 brands, 12 dealerships",
            "vehicle_categories": ["passenger", "suv", "bakkie"],
            "current_brands": ["BAIC", "BYD", "GWM", "Haval", "Mahindra", "TATA"],
            "chinese_exposure": "high",
            "decision_makers": [
                {"name": "Clive Blechman", "role": "CEO",
                 "likely_email": "clive.blechman@eastvaal.co.za"},
            ],
            "pain_points": [
                "Volume pressure on Chery / Omoda — Motus now controls Penta supply",
                "Need diversification beyond BAIC for B-segment SUV gap",
            ],
            "opportunities": [
                "Top-up Haval Jolion / Chery Tiggo 4 Pro stock",
                "Add JAC T8 bakkie to bakkie shelf",
            ],
            "recommended_models": [
                {"model": "Chery Tiggo 4 Pro", "price_band_zar": "210000-240000",
                 "lot_size": "100-200", "why_this_lead": "B-segment SUV demand"},
                {"model": "JAC T8 Pro", "price_band_zar": "360000-400000",
                 "lot_size": "100-150", "why_this_lead": "double-cab bakkie shelf"},
            ],
            "recent_news": [
                {"date": "2025-12", "source": "BusinessTech",
                 "url": "https://example.com/eastvaal-news",
                 "headline": "Eastvaal opens new BYD showroom",
                 "relevance": "Active expansion of Chinese-brand footprint"},
            ],
            "site_language": "en",
            "red_flags": [],
            "skip": False,
            "skip_reason": None,
            "research_confidence": "high",
        }
        plan_blob = {
            "skip": False,
            "skip_reason": None,
            "summary_one_liner": "Tier-A dealer with high Chinese exposure — pitch Tiggo 4 Pro + JAC T8 lots",
            "suggested_models": ["Chery Tiggo 4 Pro", "JAC T8 Pro"],
            "first_touch": {
                "subject": "Bulk RHD Tiggo 4 Pro and JAC T8 — direct from China",
                "opener": "Saw Eastvaal opened a new BYD showroom in December — congrats on the expansion.",
                "body": "We supply RHD Chinese vehicles in 100-300 unit lots, FOB China or CIF Durban...",
                "cta": "Open to a 15-minute call this week or next?",
                "compliance_footer": "Test Sender, Director Partnerships SADC, Test FZE\nDMCC, Dubai, UAE\n+971 4 000 0000 · sender@example.com\nReply UNSUBSCRIBE to opt out (POPIA s.69).",
            },
            "objection_handlers": [
                {"objection_key": "already_have_chery",
                 "objection_quote": "We already have Chery via Penta supply.",
                 "reply_subject": "Top-up volume on Chery / new SKUs",
                 "reply_body": "Understood. We top-up Tiggo 4 Pro / Tiggo 7 Pro with extra colour and trim mix...",
                 "intent": "augment"},
                {"objection_key": "send_pricing_pack",
                 "objection_quote": "Send your pricing.",
                 "reply_subject": "One-page pricing summary",
                 "reply_body": "Sending a one-page summary with FOB and CIF Durban prices...",
                 "intent": "reframe"},
            ],
            "followups": [
                {"step_key": "followup_1", "day_offset": 5,
                 "subject": "Tiggo 4 Pro container schedule for Q2",
                 "body": "Quick note on the next two containers...",
                 "hook": "supply timing"},
                {"step_key": "followup_2", "day_offset": 10,
                 "subject": "Permission to close the file",
                 "body": "Should I close the file or is there interest at all?",
                 "hook": "permission to close"},
                {"step_key": "nurture_30d", "day_offset": 30,
                 "subject": "Industry note — January container pricing",
                 "body": "Sharing the latest FOB Shanghai vs Tianjin spread...",
                 "hook": "stay top-of-mind"},
            ],
            "discovery_questions": [
                "What's your current monthly volume on B-segment SUV?",
                "Who signs off on stock orders above R20m?",
                "What's the mix of cash vs floor-plan you run?",
                "When does your Q2 stock window open?",
                "What BBBEE level are you targeting on procurement?",
            ],
            "close_message": {
                "subject": "Letter of Authority + first-container deposit terms",
                "body": "Per our last call, here are the LOA copies and the deposit terms...",
            },
            "if_no_response_after_30d": "requeue_after_90d",
        }
        db.update_lead(
            conn, lead_id,
            status="analyzed",
            research=json.dumps(research_blob, ensure_ascii=False),
            conversation=json.dumps(plan_blob, ensure_ascii=False),
            site_summary=research_blob["business_model"],
            language="en",
            offer_text=plan_blob["first_touch"]["body"],
            current_step="first_touch",
        )
        db.record_message(
            conn, lead_id,
            direction="outbound", channel="form", step="first_touch",
            subject=plan_blob["first_touch"]["subject"],
            body=plan_blob["first_touch"]["body"],
        )
    return lead_id


def test_render_lead_includes_research_and_playbook(tmp_path: Path) -> None:
    db_path = tmp_path / "play.db"
    lead_id = _seed_lead(db_path)

    with db.session(db_path) as conn:
        lead = db.get_lead(conn, lead_id)
        history = db.message_history(conn, lead_id)

    md = playbook.render_lead(lead, history)

    # Header + segmentation
    assert "Eastvaal Motor Group" in md
    assert "**Priority:** A" in md
    # Research section
    assert "Multi-franchise dealer group" in md
    assert "Chery Tiggo 4 Pro" in md
    assert "BYD showroom" in md
    # Playbook
    assert "first contact" in md.lower()
    assert "Bulk RHD Tiggo 4 Pro" in md
    assert "POPIA" in md
    assert "already_have_chery" in md
    assert "Day +5" in md and "Day +10" in md and "Day +30" in md
    # Discovery + close
    assert "Discovery questions" in md
    assert "Letter of Authority" in md
    # History
    assert "first_touch" in md


def test_export_lead_writes_markdown_file(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(playbook, "PLAYBOOKS_DIR", tmp_path / "out")
    db_path = tmp_path / "play.db"
    lead_id = _seed_lead(db_path)

    out = playbook.export_lead(lead_id, db_path=db_path)
    assert out.exists()
    body = out.read_text(encoding="utf-8")
    assert f"Lead {lead_id}" in body
    assert "Chery Tiggo 4 Pro" in body
