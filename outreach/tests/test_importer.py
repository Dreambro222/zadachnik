"""Smoke tests for the importer (no LLM, no network)."""
from __future__ import annotations

import sqlite3
from pathlib import Path

from outreach import db, importer


def test_import_example_csv(tmp_path: Path) -> None:
    csv_path = Path(__file__).resolve().parent.parent / "data" / "leads.example.csv"
    db_path = tmp_path / "leads.db"
    db.init_db(db_path)

    # monkey-patch DB_PATH for the importer
    original = db.DB_PATH
    try:
        db.DB_PATH = db_path  # type: ignore[assignment]
        stats = importer.import_file(csv_path, db_path=db_path)
    finally:
        db.DB_PATH = original  # type: ignore[assignment]

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
