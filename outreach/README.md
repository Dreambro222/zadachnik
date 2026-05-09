# Outreach — automated lead-contact toolkit

Python CLI that takes a CSV/XLSX of B2B leads (South African dealer groups,
rental & fleet operators, taxi-recap financiers, used-car wholesalers, logistics
truck buyers, bus operators) and runs each one through a full sales sequence:

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

> **Status:** form channel + research + playbook + reply classifier are wired
> end-to-end. Email and LinkedIn are stubbed (LinkedIn planned via Heyreach /
> Phantombuster API; email via Gmail OAuth or SMTP). Government / mining /
> corporate / industry-association leads are auto-classified as
> `channel=tender_only` and skipped from cold outreach — those go through
> CSD / Ariba / Coupa supplier portals separately.

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
python -m outreach send                         # dry-run, prints fill plan
python -m outreach send --id 1 --live           # actually submits the form

# When a reply lands in your inbox, classify it against the prepared playbook.
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
│   ├── playbook.py              # markdown export of per-lead playbooks
│   ├── reporter.py              # CSV report export
│   ├── config.py                # .env + sender.yaml + offer.md
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
form_url present              → channel = form
email present (no form_url)   → channel = email     (sending TBD)
linkedin URL present          → channel = linkedin  (sending TBD)
website only                  → channel = form (we discover the form)
nothing                       → channel = none      (skipped)
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

Two suites (no LLM, no network):
- `test_importer.py` — column auto-detection, channel classification, the
  73-row SA database stays intact + tier-A targets are form-eligible.
- `test_playbook.py` — markdown rendering covers research + playbook +
  history; `export_lead` writes the file.

## What is NOT done yet

- Email sending (Gmail OAuth / SMTP / Postmark).
- LinkedIn outreach via Heyreach / Phantombuster / Expandi API.
- IMAP-based reply ingestion (today: paste manually into `outreach reply`).
- Tender-watch agent for the 24 `tender_only` leads (etenders.gov.za + Coupa
  + Ariba notifications + Claude classifier).
- Hunter / Apollo email-pattern verification batch.
- Per-priority filtering on `report` and `status`.
