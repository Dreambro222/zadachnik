"""CSV / XLSX importer with column auto-detection and channel classification."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pandas as pd

from . import db

# Map common column names (case-insensitive substrings) → normalized field
# Order matters: more specific targets MUST be matched before generic ones
# (e.g. "form_url" before "website", because "url" is a substring of "form_url").
COLUMN_HINTS: dict[str, list[str]] = {
    "form_url": ["form_url", "form url", "contact_url", "form", "contact", "контакт"],
    "linkedin": ["linkedin", "li_url", "li-url"],
    "email":    ["email", "e-mail", "mail", "почта"],
    "website":  ["website", "homepage", "domain", "url", "site", "сайт"],
    "company":  ["company", "organization", "firma", "компани", "name"],
    "country":  ["country", "страна"],
    "notes":    ["note", "comment", "коммент"],
}

EMAIL_RE = re.compile(r"[\w.\-+]+@[\w.\-]+\.\w+")
URL_RE = re.compile(r"https?://\S+", re.IGNORECASE)


def _normalize_column(col: str) -> str | None:
    c = col.strip().lower()
    for target, hints in COLUMN_HINTS.items():
        for hint in hints:
            if hint in c:
                return target
    return None


def _read_table(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in {".xlsx", ".xls"}:
        return pd.read_excel(path, dtype=str).fillna("")
    if suffix == ".csv":
        # Try utf-8 first; fall back to common encodings.
        for enc in ("utf-8", "utf-8-sig", "cp1251", "latin-1"):
            try:
                return pd.read_csv(path, dtype=str, encoding=enc).fillna("")
            except UnicodeDecodeError:
                continue
        raise ValueError(f"Cannot decode {path} with common encodings")
    raise ValueError(f"Unsupported file: {path.suffix}")


def _detect_channel(row: dict[str, Any]) -> str:
    if row.get("form_url"):
        return "form"
    if row.get("email"):
        return "email"
    if row.get("linkedin"):
        return "linkedin"
    # last resort: try to discover form on the website
    if row.get("website"):
        return "form"
    return "none"


def _scrape_inline(value: str) -> dict[str, str]:
    """Extract email / URLs from a free-text cell."""
    out: dict[str, str] = {}
    if not value:
        return out
    if (m := EMAIL_RE.search(value)):
        out["email"] = m.group(0)
    urls = URL_RE.findall(value)
    for u in urls:
        if "linkedin." in u and "linkedin" not in out:
            out["linkedin"] = u.rstrip(".,;)")
        elif "website" not in out:
            out["website"] = u.rstrip(".,;)")
    return out


def import_file(path: Path, db_path: Path | None = None) -> dict[str, int]:
    df = _read_table(path)

    # Build column mapping
    mapping: dict[str, str] = {}
    for col in df.columns:
        target = _normalize_column(str(col))
        if target and target not in mapping.values():
            mapping[col] = target

    inserted = 0
    skipped = 0
    by_channel: dict[str, int] = {}

    db.init_db(db_path)
    with db.session(db_path) as conn:
        for _, raw_row in df.iterrows():
            row = {target: str(raw_row[col]).strip() for col, target in mapping.items()}
            # opportunistic scrape of un-mapped columns
            for col, val in raw_row.items():
                if col in mapping:
                    continue
                scraped = _scrape_inline(str(val))
                for k, v in scraped.items():
                    row.setdefault(k, v)

            if not row.get("company") and not row.get("website") and not row.get("email"):
                skipped += 1
                continue

            row["raw"] = {str(k): str(v) for k, v in raw_row.items()}
            row["channel"] = _detect_channel(row)
            by_channel[row["channel"]] = by_channel.get(row["channel"], 0) + 1
            db.insert_lead(conn, row)
            inserted += 1

    return {
        "inserted": inserted,
        "skipped": skipped,
        "by_channel": json.loads(json.dumps(by_channel)),  # plain dict
    }
