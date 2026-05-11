#!/usr/bin/env python
"""Smartlead API smoke-test — verify the key works before campaign-init.

Read-only: hits a few GET endpoints and prints what it finds. No
campaigns created, no leads pushed, no money spent. Run this RIGHT AFTER
pasting SMARTLEAD_API_KEY into .env to confirm everything is wired.

Usage (from repo root, with venv activated):

    python scripts/smartlead_smoke.py
    python scripts/smartlead_smoke.py --campaign-id 12345  # also check a specific campaign

What it does:
    1. Loads SMARTLEAD_API_KEY from .env (via the toolkit's config module).
    2. GETs /email-accounts/ — lists every inbox attached to the workspace.
       This is the bit you care about: zero inboxes here means Primeforge /
       Maildoso / Mailforge haven't finished provisioning yet.
    3. GETs /campaigns/ — lists existing campaigns (so you don't accidentally
       create a duplicate when you run campaign-init).
    4. If --campaign-id is given, dumps that campaign's settings + sequence
       so you can sanity-check the template our `campaign-init` pushed.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow running from anywhere in the repo.
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from outreach import smartlead    # noqa: E402


def fmt_table(rows: list[dict], cols: list[tuple[str, str]]) -> str:
    """Tiny ASCII-table renderer so we don't pull in rich at script-level."""
    widths = {key: len(label) for key, label in cols}
    for row in rows:
        for key, _ in cols:
            widths[key] = max(widths[key], len(str(row.get(key, ""))))
    line = "  ".join(label.ljust(widths[key]) for key, label in cols)
    sep  = "  ".join("-" * widths[key] for key, _ in cols)
    body = "\n".join(
        "  ".join(str(row.get(key, "") or "").ljust(widths[key])
                  for key, _ in cols)
        for row in rows
    )
    return f"{line}\n{sep}\n{body}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--campaign-id", type=int, default=None,
                   help="Also dump this campaign's settings + sequence")
    args = p.parse_args()

    try:
        cfg = smartlead.load_smartlead()
    except RuntimeError as exc:
        print(f"\033[31mFAIL: {exc}\033[0m")
        print("\nFix: paste SMARTLEAD_API_KEY into outreach/.env.")
        return 1

    print(f"\033[32m✓\033[0m API key loaded from .env (length={len(cfg.api_key)})")
    print(f"  base URL: {cfg.base_url}")
    print()

    client = smartlead.SmartleadClient(cfg)

    # 1. List email accounts (the inboxes we'll send from).
    print("=== Email accounts attached to this workspace ===")
    try:
        accounts = client._request("GET", "/email-accounts/")
    except smartlead.SmartleadError as exc:
        print(f"\033[31mFAIL: {exc}\033[0m")
        return 2

    # Smartlead returns either a list directly or {"data": [...]}.
    if isinstance(accounts, dict):
        accounts = accounts.get("data") or accounts.get("email_accounts") or []
    if not accounts:
        print("\033[33m(no inboxes yet — Primeforge/Maildoso hasn't provisioned, "
              "or you haven't connected one manually in Smartlead → Email Accounts)\033[0m")
    else:
        rows = [{"id": a.get("id"), "from_email": a.get("from_email"),
                 "from_name": a.get("from_name"),
                 "daily_limit": a.get("message_per_day"),
                 "warmup": "on" if a.get("warmup_enabled") else "off"}
                for a in accounts]
        print(fmt_table(rows, [
            ("id", "ID"), ("from_email", "Email"),
            ("from_name", "Name"), ("daily_limit", "Day Cap"),
            ("warmup", "Warmup"),
        ]))
    print()

    # 2. List existing campaigns.
    print("=== Campaigns in this workspace ===")
    try:
        campaigns = client._request("GET", "/campaigns/")
    except smartlead.SmartleadError as exc:
        print(f"\033[31mFAIL: {exc}\033[0m")
        return 3

    if isinstance(campaigns, dict):
        campaigns = campaigns.get("data") or campaigns.get("campaigns") or []
    if not campaigns:
        print("\033[33m(no campaigns yet — run `outreach campaign-init \"name\" "
              "--webhook-url ...` to create one)\033[0m")
    else:
        rows = [{"id": c.get("id"), "name": c.get("name"),
                 "status": c.get("status"),
                 "created": (c.get("created_at") or "")[:10]}
                for c in campaigns]
        print(fmt_table(rows, [
            ("id", "ID"), ("name", "Name"),
            ("status", "Status"), ("created", "Created"),
        ]))
    print()

    # 3. Optional: inspect one campaign in detail.
    if args.campaign_id:
        print(f"=== Campaign #{args.campaign_id} detail ===")
        try:
            sequence = client._request("GET", f"/campaigns/{args.campaign_id}/sequences")
            settings = client._request("GET", f"/campaigns/{args.campaign_id}")
        except smartlead.SmartleadError as exc:
            print(f"\033[31mFAIL: {exc}\033[0m")
            return 4
        print("--- sequence ---")
        print(json.dumps(sequence, indent=2, ensure_ascii=False)[:2000])
        print("--- settings ---")
        print(json.dumps(settings, indent=2, ensure_ascii=False)[:2000])

    print("\n\033[32m✓ smoke test passed\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
