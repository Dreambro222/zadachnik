"""SQLite storage for leads, attempts and reports."""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "leads.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS leads (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    company         TEXT NOT NULL,
    website         TEXT,
    email           TEXT,
    linkedin        TEXT,
    form_url        TEXT,
    country         TEXT,
    notes           TEXT,
    raw             TEXT,                 -- original CSV row as JSON
    channel         TEXT,                 -- form | email | linkedin | tender_only | none
    language        TEXT,                 -- detected site language
    site_summary    TEXT,                 -- LLM-extracted company summary
    offer_text      TEXT,                 -- personalized offer for this lead
    form_plan       TEXT,                 -- JSON: planned form-fill strategy
    status          TEXT NOT NULL DEFAULT 'new',
        -- new | analyzed | approved | sending | sent | failed | skipped | replied
    last_error      TEXT,
    -- segmentation
    category        TEXT,                 -- Dealer Group | Rental & Fleet | Taxi-Recap & Minibus | …
    priority        TEXT,                 -- A | B | C
    hq_city         TEXT,
    phone           TEXT,
    contact_name    TEXT,                 -- primary CEO/MD/buyer
    contact_role    TEXT,                 -- e.g. "Group CEO", "MD", "Procurement Director"
    do_form_outreach INTEGER NOT NULL DEFAULT 1,
        -- 0 for tender-only categories (gov / mining / corporate / industry assoc)

    -- deep research + multi-turn conversation playbook
    research        TEXT,                 -- JSON: deep_research(lead) output
    conversation    TEXT,                 -- JSON: full plan_conversation() output
    current_step    TEXT,                 -- 'first_touch' | 'followup_1' | 'discovery' | 'closed' | …
    next_action_at  TEXT,                 -- ISO timestamp for when the next touch is due

    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_id     INTEGER NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
    direction   TEXT NOT NULL,            -- outbound | inbound
    channel     TEXT NOT NULL,            -- form | email | linkedin | manual
    step        TEXT,                     -- first_touch | followup_1 | objection_<key> | discovery | close | nurture
    subject     TEXT,
    body        TEXT,
    classification TEXT,                  -- inbound only: interested | objection_<key> | not_now | no | auto_reply | unsubscribe | unclear
    confidence  REAL,                     -- 0..1
    raw         TEXT,                     -- raw payload (full email / form-thank-you snippet)
    created_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_lead ON messages(lead_id, created_at);

CREATE TABLE IF NOT EXISTS attempts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_id     INTEGER NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
    channel     TEXT NOT NULL,            -- form | email | linkedin
    strategy    TEXT,                     -- JSON of the strategy used
    success     INTEGER NOT NULL DEFAULT 0,
    confirmation TEXT,                    -- detected confirmation text/snippet
    error       TEXT,
    screenshot  TEXT,                     -- relative path to screenshot
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS replies (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_id     INTEGER NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
    channel     TEXT NOT NULL,
    received_at TEXT NOT NULL,
    classification TEXT,                  -- interested | not_now | auto_reply | unsubscribe | unclear
    excerpt     TEXT,
    raw         TEXT
);

CREATE INDEX IF NOT EXISTS idx_leads_status ON leads(status);
CREATE INDEX IF NOT EXISTS idx_attempts_lead ON attempts(lead_id);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def connect(db_path: Path | None = None) -> sqlite3.Connection:
    path = db_path or DB_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


def init_db(db_path: Path | None = None) -> Path:
    path = db_path or DB_PATH
    with connect(path) as conn:
        conn.executescript(SCHEMA)
        _migrate(conn)
        conn.commit()
    return path


# Columns added after the first release. ALTER TABLE ADD COLUMN is idempotent
# only via try/except in SQLite, so we list them explicitly.
_DEFERRED_LEAD_COLUMNS = [
    ("research",       "TEXT"),
    ("conversation",   "TEXT"),
    ("current_step",   "TEXT"),
    ("next_action_at", "TEXT"),
]


def _migrate(conn: sqlite3.Connection) -> None:
    existing = {row["name"] for row in conn.execute("PRAGMA table_info(leads)")}
    for name, sql_type in _DEFERRED_LEAD_COLUMNS:
        if name not in existing:
            conn.execute(f"ALTER TABLE leads ADD COLUMN {name} {sql_type}")


@contextmanager
def session(db_path: Path | None = None) -> Iterator[sqlite3.Connection]:
    conn = connect(db_path)
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ---------- lead helpers ----------

def insert_lead(conn: sqlite3.Connection, lead: dict[str, Any]) -> int:
    ts = now_iso()
    cur = conn.execute(
        """
        INSERT INTO leads (company, website, email, linkedin, form_url,
                           country, notes, raw, channel, status,
                           category, priority, hq_city, phone,
                           contact_name, contact_role, do_form_outreach,
                           created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'new',
                ?, ?, ?, ?, ?, ?, ?,
                ?, ?)
        """,
        (
            lead.get("company") or "(unknown)",
            lead.get("website"),
            lead.get("email"),
            lead.get("linkedin"),
            lead.get("form_url"),
            lead.get("country"),
            lead.get("notes"),
            json.dumps(lead.get("raw") or {}, ensure_ascii=False),
            lead.get("channel"),
            lead.get("category"),
            lead.get("priority"),
            lead.get("hq_city"),
            lead.get("phone"),
            lead.get("contact_name"),
            lead.get("contact_role"),
            1 if lead.get("do_form_outreach", True) else 0,
            ts,
            ts,
        ),
    )
    return cur.lastrowid


def update_lead(conn: sqlite3.Connection, lead_id: int, **fields: Any) -> None:
    if not fields:
        return
    fields["updated_at"] = now_iso()
    columns = ", ".join(f"{k} = ?" for k in fields)
    conn.execute(
        f"UPDATE leads SET {columns} WHERE id = ?",
        (*fields.values(), lead_id),
    )


def fetch_leads(
    conn: sqlite3.Connection,
    status: str | list[str] | None = None,
    limit: int | None = None,
) -> list[sqlite3.Row]:
    sql = "SELECT * FROM leads"
    params: list[Any] = []
    if status:
        statuses = [status] if isinstance(status, str) else list(status)
        placeholders = ",".join("?" * len(statuses))
        sql += f" WHERE status IN ({placeholders})"
        params.extend(statuses)
    sql += " ORDER BY id"
    if limit:
        sql += " LIMIT ?"
        params.append(limit)
    return list(conn.execute(sql, params))


def get_lead(conn: sqlite3.Connection, lead_id: int) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM leads WHERE id = ?", (lead_id,)).fetchone()


def record_attempt(
    conn: sqlite3.Connection,
    lead_id: int,
    channel: str,
    *,
    strategy: dict[str, Any] | None = None,
    success: bool = False,
    confirmation: str | None = None,
    error: str | None = None,
    screenshot: str | None = None,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO attempts (lead_id, channel, strategy, success,
                              confirmation, error, screenshot, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            lead_id,
            channel,
            json.dumps(strategy, ensure_ascii=False) if strategy else None,
            1 if success else 0,
            confirmation,
            error,
            screenshot,
            now_iso(),
        ),
    )
    return cur.lastrowid


def record_message(
    conn: sqlite3.Connection,
    lead_id: int,
    *,
    direction: str,
    channel: str,
    step: str | None = None,
    subject: str | None = None,
    body: str | None = None,
    classification: str | None = None,
    confidence: float | None = None,
    raw: str | None = None,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO messages (lead_id, direction, channel, step, subject, body,
                              classification, confidence, raw, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (lead_id, direction, channel, step, subject, body,
         classification, confidence, raw, now_iso()),
    )
    return cur.lastrowid


def message_history(conn: sqlite3.Connection, lead_id: int) -> list[sqlite3.Row]:
    return list(
        conn.execute(
            "SELECT * FROM messages WHERE lead_id = ? ORDER BY id",
            (lead_id,),
        )
    )


def status_counts(conn: sqlite3.Connection) -> dict[str, int]:
    rows = conn.execute(
        "SELECT status, COUNT(*) AS n FROM leads GROUP BY status"
    ).fetchall()
    return {row["status"]: row["n"] for row in rows}
