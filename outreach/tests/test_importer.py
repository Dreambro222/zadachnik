"""Smoke tests for the importer (no LLM, no network)."""
from __future__ import annotations

import sqlite3
from pathlib import Path

from outreach import db, importer

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def test_import_example_csv(tmp_path: Path) -> None:
    csv_path = DATA_DIR / "leads.example.csv"
    db_path = tmp_path / "leads.db"
    db.init_db(db_path)

    stats = importer.import_file(csv_path, db_path=db_path)

    assert stats["inserted"] == 5
    assert stats["skipped"] == 0
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = list(conn.execute("SELECT * FROM leads ORDER BY id"))
    assert {r["channel"] for r in rows} == {"form", "linkedin", "email"}
    by_company = {r["company"]: r for r in rows}
    assert by_company["ExampleAuto OU"]["channel"] == "form"
    assert by_company["RentARide"]["channel"] == "linkedin"
    assert by_company["FleetPlus"]["channel"] == "email"
    assert by_company["LeasingHub"]["channel"] == "form"  # falls back to website


def test_import_za_csv_categorises_correctly(tmp_path: Path) -> None:
    csv_path = DATA_DIR / "leads.za.csv"
    db_path = tmp_path / "za.db"
    db.init_db(db_path)

    stats = importer.import_file(csv_path, db_path=db_path)

    assert stats["inserted"] == 73, stats
    assert stats["skipped"] == 0

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = list(conn.execute("SELECT * FROM leads"))

    by_channel: dict[str, int] = {}
    for r in rows:
        by_channel[r["channel"]] = by_channel.get(r["channel"], 0) + 1

    # Tender-only categories must NOT be cold-form-targeted
    tender_only = [r for r in rows if r["channel"] == "tender_only"]
    assert len(tender_only) == 24, by_channel
    tender_categories = {r["category"] for r in tender_only}
    assert tender_categories == {
        "Government Fleet",
        "Mining Fleet",
        "Corporate Fleet",
        "Industry Assoc",
    }

    # Spot-check key A-tier targets are form-eligible
    by_company = {r["company"]: r for r in rows}
    for tier_a in ("Motus Holdings Ltd", "Eastvaal Motor Group",
                   "Lazarus Motor Company", "Zeda Limited",
                   "WeBuyCars", "Bridge Taxi Finance"):
        assert by_company[tier_a]["channel"] == "form", tier_a
        assert by_company[tier_a]["priority"] == "A", tier_a
        assert by_company[tier_a]["do_form_outreach"] == 1, tier_a

    # Tender-only entries must have do_form_outreach == 0
    assert all(r["do_form_outreach"] == 0 for r in tender_only)
