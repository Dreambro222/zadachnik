# Outreach — automated lead-contact toolkit

Python CLI that takes a CSV/XLSX of leads (car dealers, rental companies, fleet
operators) and, for each one:

1. **Analyses the company website** with Claude (industry, summary, hooks).
2. **Generates a personalised English offer** based on `offer.md` + the lead.
3. **Plans how to fill the contact form** — Claude writes selectors + values,
   self-heals on failure (up to 3 different strategies per lead).
4. **Submits the form** in headless Chromium, captures before/after
   screenshots, asks Claude to verify the submission landed.
5. **Tracks state** in SQLite and exports a CSV report.

LLM calls go through the local `claude` CLI (`claude -p`), so no API key is
needed if you already have Claude Code authenticated.

> **Status:** contact-form channel is implemented end-to-end. Email & LinkedIn
> channels are stubbed: the importer classifies them, but actual sending is
> deferred (LinkedIn is planned via Heyreach/Phantombuster API; email TBD).

## Quick start

```bash
cd outreach
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium

cp .env.example .env
# edit .env and sender.yaml — your name, company, email, phone
# edit offer.md — your real offer

python -m outreach init
python -m outreach import data/leads.example.csv
python -m outreach analyze --limit 3            # uses Claude to read sites
python -m outreach status
python -m outreach plan 1                       # inspect generated offer + plan
python -m outreach approve --batch 3
python -m outreach send                         # DRY-RUN by default
python -m outreach send --live                  # actually submit forms
python -m outreach report                       # writes reports/report-…csv
```

## Lifecycle of a lead

```
new        # imported from CSV
  ↓ analyze
analyzed   # has site_summary + offer + form_plan
  ↓ approve
approved   # ready to submit
  ↓ send --live
sending → sent | failed | skipped
              ↓ (later, when reply tracking lands)
            replied
```

`send` defaults to dry-run: it generates the form-fill strategy and shows
selectors + planned values, but never types anything. Add `--live` to submit
for real.

## Files & layout

```
outreach/
├── outreach/                  # python package
│   ├── cli.py                 # Typer commands
│   ├── db.py                  # SQLite schema + helpers
│   ├── importer.py            # CSV/XLSX → DB
│   ├── claude_runner.py       # subprocess wrapper around `claude -p`
│   ├── analyzer.py            # site fetch + LLM analysis + offer
│   ├── form_filler.py         # Playwright + LLM-driven form filling
│   ├── reporter.py            # CSV report export
│   ├── config.py              # .env + sender.yaml + offer.md
│   └── prompts/               # system prompts (Markdown)
├── data/                      # input CSVs (gitignored except example)
├── reports/                   # generated CSV reports (gitignored)
├── screenshots/               # before/after submit screenshots (gitignored)
├── offer.md                   # YOUR base offer (edit before running)
├── sender.yaml                # YOUR identity (name, email, phone, …)
├── .env.example
└── requirements.txt
```

## Input format

The importer auto-detects column names (case/locale-insensitive). Supported
columns: `company`, `website`, `email`, `linkedin`, `form_url` (or any column
whose name contains `contact`, `form`, `сайт`, `почта`, `linkedin`, etc.).
Unmapped cells are scraped for inline emails / URLs as a fallback.

A row is **skipped** only if it has no company, no website and no email.

## Channel classification

```
form_url present        → channel = form
email present           → channel = email
linkedin URL present    → channel = linkedin
website only            → channel = form (we'll discover the contact page)
nothing                 → channel = none (skipped)
```

## How the form filler self-heals

For each `send --live` attempt the filler:

1. Fetches the page in Chromium, captures HTML + visible text.
2. Trims HTML to `<form>…</form>` blocks (or top of body if no `<form>`).
3. Sends the trimmed HTML + the personalised message to Claude with
   `prompts/form_strategy.md` and gets back JSON: `{ form_selector, fields,
   submit_selector, consent_selectors, captcha, abort }`.
4. Applies the strategy — fills inputs, ticks consent boxes, clicks submit.
5. Captures network responses (POST/XHR), before/after page text & URL.
6. Asks Claude (`prompts/verify_submission.md`) to verify success.
7. On failure, retries — up to 3 times — passing the previous error so
   Claude proposes a different strategy.
8. Aborts immediately if Claude detects: not a contact form, login form,
   newsletter, or a captcha (recaptcha / hcaptcha / turnstile).

Screenshots are saved to `screenshots/leadN-<ts>-attemptN-{before,after}.png`.

## What is NOT done yet

- Email sending (Gmail OAuth / SMTP / Postmark) — channel decided "later".
- LinkedIn outreach — to be wired via Heyreach/Phantombuster/Expandi API
  (their API + a small `linkedin_sender.py` module).
- IMAP-based reply tracking + Claude classification of replies.
- Exponential-backoff scheduling between submissions (currently submits
  back-to-back; respect `RATE_LIMIT_PER_HOUR` is on the TODO list).
- HTML/PDF report (only CSV today).

## Tests

```bash
pytest tests/
```

Smoke test covers importer + channel classification (no network, no LLM).
