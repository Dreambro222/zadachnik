"""Generate CSV reports from the leads DB."""
from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path

from . import db

REPORTS_DIR = Path(__file__).resolve().parent.parent / "reports"


REPORT_COLUMNS = [
    "id",
    "company",
    "website",
    "channel",
    "status",
    "language",
    "subject",
    "first_line",
    "sent_at",
    "confirmation",
    "last_error",
    "form_url",
    "email",
    "linkedin",
]


def _extract(lead, field: str) -> str:
    plan = lead["form_plan"]
    if not plan:
        return ""
    try:
        data = json.loads(plan)
    except json.JSONDecodeError:
        return ""
    offer = data.get("offer") or {}
    return offer.get(field) or ""


def export(db_path: Path | None = None) -> Path:
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    out = REPORTS_DIR / f"report-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}.csv"

    with db.session(db_path) as conn, out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=REPORT_COLUMNS)
        writer.writeheader()
        leads = db.fetch_leads(conn)
        for lead in leads:
            # Latest attempt for sent_at / confirmation
            attempt = conn.execute(
                """
                SELECT created_at, success, confirmation
                FROM attempts WHERE lead_id = ? ORDER BY id DESC LIMIT 1
                """,
                (lead["id"],),
            ).fetchone()
            writer.writerow(
                {
                    "id": lead["id"],
                    "company": lead["company"],
                    "website": lead["website"] or "",
                    "channel": lead["channel"] or "",
                    "status": lead["status"],
                    "language": lead["language"] or "",
                    "subject": _extract(lead, "subject"),
                    "first_line": _extract(lead, "first_line"),
                    "sent_at": (attempt["created_at"] if attempt and attempt["success"] else ""),
                    "confirmation": (attempt["confirmation"] if attempt else "") or "",
                    "last_error": lead["last_error"] or "",
                    "form_url": lead["form_url"] or "",
                    "email": lead["email"] or "",
                    "linkedin": lead["linkedin"] or "",
                }
            )
    return out
