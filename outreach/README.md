# Outreach — automated lead-contact toolkit

Python CLI that takes a CSV/XLSX of B2B leads (South African dealer groups,
rental & fleet operators, taxi-recap financiers, used-car wholesalers, logistics
truck buyers, bus operators) and runs each one through a full sales sequence.

> **Companion docs:**
> - [`ARCHITECTURE.md`](ARCHITECTURE.md) — full structure: data flow, schema,
>   file map, lifecycle states, LLM contracts. Source of truth for the shape
>   of the system.
> - [`AUDIT.md`](AUDIT.md) — known issues + recommended fixes (HIGH/MEDIUM/
>   LOW + dead code + security). Read before deploying.

---

1. **Deep research** — Playwright pulls the homepage + about / leadership /
   press / news pages; Claude (with `WebSearch` + `WebFetch` enabled) digs up
   recent fleet news, BBBEE level, electrification mandates, post-acquisition
   integration headlines.
2. **Conversation playbook** — Claude writes the entire multi-turn sequence
   for the lead in one JSON document: first-touch message, four-to-six prepared
   replies for the typical objections, three follow-ups (Day +5 bump, Day +10
   close-the-file, Day +30 nurture), discovery questions for warm replies and
   a close template.
3. **Form-fill submission** — Playwright opens the contact form, Claude plans
   the selectors, the toolkit submits with before/after screenshots and a
   submission-verified check. POPIA s.69 footer (sender identity + opt-out) is
   mandatory; the toolkit refuses to submit without it.
4. **Reply triage** — when an inbound reply arrives, paste it into
   `outreach reply <id>` and Claude classifies it against the prepared playbook
   and returns the suggested next move (matching prepared objection-reply,
   discovery questions, archive, or escalate to human).

LLM calls go through the local `claude` CLI (`claude -p`). No API key needed
if Claude Code is already authenticated.

> **Status:** email channel + form channel + research + playbook + reply
> classifier are wired end-to-end. LinkedIn is stubbed (planned via Heyreach
> / Phantombuster API). Government / mining / corporate / industry-association
> leads are auto-classified as `channel=tender_only` and skipped from cold
> outreach — those go through CSD / Ariba / Coupa supplier portals separately.

## Quick start

```bash
cd outreach
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium

cp .env.example .env
# edit .env and sender.yaml — your name, company, Dubai DMCC address, phone
# offer.md is already populated with the wholesale-Chinese-vehicle offer

python -m outreach init
python -m outreach import data/leads.za.csv

# Per-lead deep research (Playwright + Claude + WebSearch). Takes ~60s/lead.
python -m outreach research --limit 5
# Per-lead full conversation playbook (first touch + objections + follow-ups).
python -m outreach plan --limit 5

# Or run both in one go:
python -m outreach analyze --limit 5

# Read the playbook for a specific lead before approving anything.
python -m outreach playbook 1                   # writes + prints lead 1
python -m outreach playbooks                    # one big file with all leads

python -m outreach approve --id 1

# ---- EMAIL channel (SMTP) ----
python -m outreach mail --id 1                  # dry-run by default
python -m outreach mail --id 1 --live           # actually sends first_touch
python -m outreach mail --id 1 --step followup_1 --live  # threaded follow-up
python -m outreach mail --id 1 --step close --live       # close template

# ---- FORM channel (Playwright) ----
python -m outreach send                         # dry-run, prints fill plan
python -m outreach send --id 1 --live           # actually submits the form

# ---- AUTO follow-up cadence (legacy SMTP mode) ----
python -m outreach due                          # what's due today?
python -m outreach mail --due --live            # ship every due step in one batch

# ---- INBOUND replies via IMAP (legacy mode) ----
python -m outreach inbox --once                 # one poll
python -m outreach inbox --watch                # long-running poll loop

# ---- THICK MODE via Smartlead.ai (recommended for new domains) ----
python -m outreach campaign-init "RHD Q3 2026" \
    --webhook-url https://outreach.your.com/webhook/smartlead \
    --daily-limit 30                             # one-off campaign setup
python -m outreach push --priority A --dry-run   # preview payloads
python -m outreach push --priority A             # ship leads to Smartlead
python -m outreach webhook --serve --port 8080   # receive events (run on VPS)

# Manual fallback (paste a reply that came through some other channel):
python -m outreach reply 1 --from "ceo@motus.co.za" --subject "Re: …"
# (paste body, Ctrl-D)

python -m outreach status
python -m outreach report                       # CSV at reports/report-…csv
```

## Lifecycle of a lead

```
new          # imported from CSV
  ↓ research            Playwright + Claude (WebSearch+WebFetch)
researched   # has research JSON: business model, brands, pains, models
  ↓ plan                Claude writes the multi-turn playbook
analyzed     # has conversation JSON: first_touch, objections, follow-ups
  ↓ approve
approved     # human gate cleared — ready to submit
  ↓ send --live
sending → sent | failed | skipped
              ↓ outreach reply <id>
            replied (classified → next-move suggested)
```

## Files & layout

```
outreach/
├── outreach/                    # python package
│   ├── cli.py                   # Typer commands
│   ├── db.py                    # SQLite schema + migrations + helpers
│   ├── importer.py              # CSV/XLSX → DB
│   ├── claude_runner.py         # subprocess wrapper around `claude -p`
│   ├── research.py              # Playwright fetch + LLM deep-research
│   ├── conversation.py          # plan_conversation() + classify_reply()
│   ├── form_filler.py           # Playwright form-fill with self-healing
│   ├── mailer.py                # SMTP outbound with RFC822 threading
│   ├── inbox.py                 # IMAP poll + reply attach + classify
│   ├── playbook.py              # markdown export of per-lead playbooks
│   ├── reporter.py              # CSV report export
│   ├── config.py                # .env + sender.yaml + offer.md + mailer/inbox
│   └── prompts/                 # system prompts (markdown)
│       ├── deep_research.md
│       ├── plan_conversation.md
│       ├── classify_reply.md
│       ├── form_strategy.md
│       └── verify_submission.md
├── data/                        # input CSVs
│   ├── leads.example.csv
│   └── leads.za.csv             # 73 SA leads (curated)
├── playbooks/                   # markdown playbooks (gitignored)
├── reports/                     # CSV reports (gitignored)
├── screenshots/                 # form before/after screenshots (gitignored)
├── offer.md                     # base offer + per-category angles
├── sender.yaml                  # YOUR identity (name, address, phone…)
├── .env.example
└── requirements.txt
```

## Channel classification (importer)

```
form_url present              → channel = form        (→ outreach send)
email present (no form_url)   → channel = email       (→ outreach mail)
linkedin URL present          → channel = linkedin    (sending: planned)
website only                  → channel = form        (we discover the form)
nothing                       → channel = none        (skipped)
category in tender-only set   → channel = tender_only (skipped from cold)
```

`tender_only` covers: Government Fleet, Mining Fleet, Corporate Fleet,
Industry Assoc — these procure via CSD / Ariba / Coupa, never via cold
contact-form.

## How `research` enriches a lead

For each lead that isn't `tender_only`:

1. Playwright opens the homepage and follows up to 4 same-domain links whose
   text or path contains: `about`, `leadership`, `press`, `news`,
   `bbbee`, `transformation`, etc.
2. The trimmed home + extras text is sent to Claude with the
   `prompts/deep_research.md` system prompt and `WebSearch` + `WebFetch`
   tools enabled.
3. Claude searches recent SA-business news ("{company} fleet renewal",
   "{company} BBBEE", "{company} electric vehicles") and fetches one or two
   articles to ground its analysis.
4. Output JSON: `business_model`, `vehicle_categories`, `current_brands`,
   `chinese_exposure`, `pain_points`, `opportunities`, `recommended_models`
   (specific models from our portfolio with price band & lot size),
   `decision_makers`, `recent_news`, `red_flags`, `skip` flag.

Cached in `leads.research`. Re-run with `--refresh` to redo.

## How `plan` builds the conversation

Given the research, Claude returns ONE JSON containing:

- `first_touch`: subject + opener + body + CTA + POPIA-compliant footer.
- `objection_handlers`: 4–6 prepared replies keyed by objection type
  (`already_have_chery`, `send_pricing_pack`, `not_decision_maker`,
  `tender_only`, `bbbee_concern`, `warranty_aftersales`, `sanctions_russia`,
  `captcha_or_compliance` — whichever apply to the lead).
- `followups`: three messages at Day +5, +10, +30 (each with a NEW angle).
- `discovery_questions`: 5 questions for after a positive reply.
- `close_message`: subject + body for the deal-closing email.

`outreach playbook <id>` renders all of this as readable markdown so you
can review every word before approving the lead for sending.

## How `reply` triages an inbound

```bash
outreach reply 7 --from "ceo@example.co.za" --subject "Re: …"
# paste body, Ctrl-D
```

The toolkit:

1. Logs the inbound message to the `messages` table.
2. Loads the lead's `conversation` plan + full message history.
3. Asks Claude (`prompts/classify_reply.md`) to classify the reply
   (`interested`, `objection`, `not_now`, `unsubscribe`, …) and pick the
   matching prepared reply or escalate to a human.
4. Prints the classification, recommended action, suggested response, and
   sets `must_human_review=true` whenever there's any ambiguity (especially
   around unsubscribes — POPIA s.69 demands removal within 24 h).

## How the form filler self-heals

Per `send --live` attempt:

1. Playwright fetches the page; the toolkit trims HTML to `<form>` blocks.
2. Claude (`prompts/form_strategy.md`) plans selectors + values.
3. The plan is applied; before / after screenshots are saved.
4. Claude (`prompts/verify_submission.md`) checks success against page text +
   network log.
5. Up to 3 retries with the previous error fed back to Claude so it proposes
   a different strategy.
6. Aborts on CAPTCHA (recaptcha / hcaptcha / turnstile), login forms,
   newsletter signups, or anything Claude judges to be the wrong form.

## Tests

```bash
pytest tests/
```

Four suites (no LLM, no network — 11 tests):
- `test_importer.py` — column auto-detection, channel classification, the
  73-row SA database stays intact + tier-A targets are form-eligible.
- `test_playbook.py` — markdown rendering covers research + playbook +
  history; `export_lead` writes the file.
- `test_mailer.py` — RFC822 envelope build, threading headers (Message-ID /
  In-Reply-To / References), POPIA-footer enforcement, dry-run path,
  `smtp_factory` injection.
- `test_inbox.py` — IMAP attach by `In-Reply-To`, classifier hook, cursor
  advancement, unattached-reply path; `imap_factory` stub for offline tests.

## Email channel — operating notes

- Use a **dedicated outreach domain** (e.g. `outreach-yourbiz.com`), never
  your main corporate domain. Set up SPF + DKIM + DMARC on it BEFORE the
  first send — otherwise SA-corporate spam filters will burn the domain
  reputation in 24 h.
- For Google Workspace, generate an **app password** (Account → Security →
  2-step verification → App passwords) and put it in `SMTP_PASSWORD` /
  `IMAP_PASSWORD`. Don't use your main account password.
- The mailer enforces `MAIL_DAILY_LIMIT` (default 20). Start at 10–15/day,
  raise by +5/day after the first week, target 50/day after a month.
- Threading is built on `Message-ID` / `In-Reply-To` / `References` headers.
  `outreach mail --step followup_1` automatically chains to the original
  `first_touch` Message-ID so the recipient sees one continuous thread.
- The footer (POPIA s.69 — sender identity + opt-out) is enforced — the
  mailer refuses to send without it.
- For SCALE (>50 emails/day), swap SMTP for **Instantly.ai** or **Smartlead**
  (proper cold-email infra with mailbox rotation + warm-up). The interface
  in `mailer.py` is provider-agnostic — only the `_open_smtp` factory
  changes.
- Avoid Postmark / Mailgun / SendGrid for cold outreach — their TOS
  explicitly bans it and they will suspend the account.

## Inbox poller — operating notes

- `outreach inbox --once` does a single poll: fetches new UIDs since the
  last cursor, attaches each reply to a lead via `In-Reply-To` (or sender
  email / domain as a fallback), runs `classify_reply`, stores the
  classification + suggested next move on the inbound message.
- The cursor (`uidvalidity`, `last_uid`) is stored in the `inbox_state`
  table — replies are never reprocessed.
- Recommended: run in a `cron` or `launchd` job every 5 minutes:

  ```cron
  */5 * * * *  cd ~/outreach && .venv/bin/python -m outreach inbox --once
  ```

- For lower latency, `--watch` opens a long-running loop (uses
  `IMAP_POLL_SECONDS`).

## Two send modes — pick one

The toolkit supports **two mutually-exclusive sending paths**. Pick the one
that fits your situation:

| | **Legacy SMTP mode** | **Thick mode (Smartlead.ai)** |
|---|---|---|
| Who sends | `outreach mail --live` over SMTP from your own mailbox | Smartlead.ai through its rotating inbox pool |
| Cadence engine | our `scheduler.py` + `next_action_at` + `mail --due` cron | Smartlead's built-in sequence editor |
| Domain warmup | you, manually, 2–4 weeks | Smartlead's "warmup pool" — automatic |
| Inbox rotation | none (single mailbox) | yes, across N mailboxes you assign |
| Bounce handling | you (TODO — currently classified as `unclear`) | automatic |
| Inbound replies | `outreach inbox --watch` (IMAP poll) | `outreach webhook --serve` (push from Smartlead) |
| Cost | $0 / month | ~$60–100 / mo (Smartlead $39 + 5 Maildoso inboxes $20) |
| Setup time | 2–4 weeks (domain warmup) | ~1 day after Maildoso provisions inboxes |
| Best for | low volume, established sender | new domain, 50+ leads/day, no time to warm up |

For thick-mode operator runbook see [`docs/SMARTLEAD.md`](docs/SMARTLEAD.md)
(coming soon). Quickstart:

```bash
# 1. Add SMARTLEAD_API_KEY to .env (from Smartlead → Settings → API).
# 2. Provision N inboxes (Maildoso recommended) and connect them in
#    Smartlead → Email Accounts.
# 3. Create campaign + push our 4-step cadence template + register webhook:
outreach campaign-init "RHD Q3 2026" \
    --webhook-url https://outreach.your.com/webhook/smartlead \
    --daily-limit 30
# 4. Copy the printed campaign_id into .env as SMARTLEAD_CAMPAIGN_ID.
# 5. Run the receiver on your VPS (behind nginx + TLS):
outreach webhook --serve --port 8080
# 6. Push leads:
outreach push --priority A --dry-run    # preview
outreach push --priority A              # for real
```

Smartlead does sending, threading, follow-ups (Day +0/+5/+10/+30) and
warmup. We do per-lead Claude personalisation and reply classification
(over the inbound webhook). Both paths write to the same `messages` /
`leads` tables — `outreach status` and `report` work for either.

## Auto-scheduler — operating notes (legacy SMTP mode only)

After every successful `mail --live` / `send --live`, the toolkit writes
`leads.next_action_at` based on the playbook's cadence (Day +5 / +10 / +30
from the original first_touch). To run on autopilot:

```cron
# Poll inbox every 5 minutes
*/5 * * * *  cd ~/outreach && .venv/bin/python -m outreach inbox --once

# Daily at 09:00 UTC: ship every due cadence step
0 9 * * *    cd ~/outreach && .venv/bin/python -m outreach mail --due --live
```

`mail --due` auto-picks each lead's next cadence step (`first_touch_sent` →
`followup_1`, etc.), respects `MAIL_DAILY_LIMIT`, and clears
`next_action_at` on the lead once the cadence reaches `nurture_30d`. When
an inbound reply arrives, the inbox poller (or manual `reply`) sets
`status='replied'` and clears `next_action_at` so the operator owns the
next move on that thread.

`outreach due` shows the dashboard: who's overdue and what step would go
out next.

## What is NOT done yet

- LinkedIn outreach via Heyreach / Phantombuster / Expandi API.
- Tender-watch agent for the 24 `tender_only` leads (etenders.gov.za + Coupa
  + Ariba notifications + Claude classifier).
- Hunter / Apollo email-pattern verification batch.
- Bounce / NDR detection (today bounce-backs are classified as `unclear`
  and flagged for human review).
- Per-priority filtering on `report` and `status`.
- HIGH-priority issues from [`AUDIT.md`](AUDIT.md): H1 (reporter reads dead
  column), H2 (reporter ignores email channel), H3 (importer has no dedup).
