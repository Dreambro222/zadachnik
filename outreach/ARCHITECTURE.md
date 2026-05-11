# Architecture

Full structural reference for the outreach toolkit. Source of truth for the
shape of the system; the README is the operator's guide. Everything in this
document maps to a real file/symbol — there is no aspirational design here.

---

## 1. Big picture

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ leads.csv    │───▶│  importer    │───▶│   research   │───▶│     plan     │
│ (73 SA cos)  │    │              │    │ (Playwright  │    │ (Claude →    │
│              │    │ column auto- │    │  + Claude    │    │  full multi- │
│              │    │ detection +  │    │  + WebSearch)│    │  turn play-  │
│              │    │ channel pick │    │              │    │  book JSON)  │
└──────────────┘    └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
                           ▼                   ▼                   ▼
                     ┌─────────────────────────────────────────────────┐
                     │            SQLite  outreach/data/leads.db       │
                     │   leads · messages · attempts · inbox_state     │
                     └────────────────┬────────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
       ┌────────────┐          ┌────────────┐          ┌────────────┐
       │  approve   │          │  playbook  │          │  status /  │
       │  (gate)    │          │ (markdown) │          │   report   │
       └─────┬──────┘          └────────────┘          └────────────┘
             │
   ┌─────────┼──────────┐
   ▼         ▼          ▼
┌──────┐  ┌──────┐  ┌──────┐
│ mail │  │ send │  │  …   │  (linkedin: planned)
│ SMTP │  │ form │  └──────┘
└──┬───┘  └──┬───┘
   │         │ Playwright + LLM strategy
   ▼         ▼
SMTP      contact form          ┌──────────────────────────┐
recipient submission            │  inbox poller (IMAP)     │
                                │  ↓ attach by Message-ID  │
                                │  ↓ classify_reply (LLM)  │
                                └──────────────────────────┘
```

The system is a four-stage pipeline (research → plan → approve → send) with a
read-side reply ingestor (IMAP poller + LLM classifier) closing the loop.
Every stage persists to SQLite so any step is resumable.

---

## 2. File map

```
outreach/
├── outreach/                      # Python package (entry: python -m outreach)
│   ├── __main__.py                # delegates to cli.app
│   ├── cli.py                     # Typer commands (the public surface)
│   ├── config.py                  # .env / sender.yaml / offer.md loaders +
│   │                              # MailerConfig / InboxConfig dataclasses
│   ├── db.py                      # SQLite schema, migrations, helpers
│   ├── importer.py                # CSV/XLSX → leads table
│   ├── claude_runner.py           # subprocess wrapper around `claude -p`
│   ├── research.py                # Playwright site fetch + LLM deep-research
│   ├── conversation.py            # plan_conversation() + classify_reply()
│   ├── form_filler.py             # Playwright form-fill, self-healing, screenshots
│   ├── mailer.py                  # SMTP outbound, RFC822 threading, dry-run
│   ├── inbox.py                   # IMAP poller, attach to lead, classify
│   ├── playbook.py                # markdown export of per-lead playbooks
│   ├── reporter.py                # CSV report export
│   ├── scheduler.py               # cadence state machine + due-list (legacy autopilot)
│   ├── smartlead.py               # Smartlead.ai API client + payload builders (thick mode)
│   ├── webhook.py                 # stdlib HTTP receiver for Smartlead events
│   └── prompts/                   # system prompts (markdown, version-controlled)
│       ├── deep_research.md       # input shape + JSON schema for research
│       ├── plan_conversation.md   # input shape + JSON schema for playbook
│       ├── classify_reply.md      # input shape + JSON schema for triage
│       ├── form_strategy.md       # input shape + JSON schema for form plan
│       └── verify_submission.md   # input shape + JSON schema for verify step
├── tests/                         # pytest, no network/LLM
│   ├── test_importer.py
│   ├── test_playbook.py
│   ├── test_mailer.py             # mocks smtplib via factory
│   └── test_inbox.py              # mocks imaplib via factory
├── data/                          # input CSVs (curated lead lists)
│   ├── leads.example.csv
│   └── leads.za.csv               # 73 SA companies
├── playbooks/                     # generated md (gitignored)
├── reports/                       # generated csv (gitignored)
├── screenshots/                   # form before/after (gitignored)
├── offer.md                       # base offer text + per-category angles
├── sender.yaml                    # operator identity (POPIA s.69 footer)
├── .env.example                   # SMTP/IMAP/sender env-var template
├── requirements.txt
├── README.md                      # operator's guide
├── ARCHITECTURE.md                # this file
└── AUDIT.md                       # known issues + recommended fixes
```

---

## 3. Data model (SQLite)

### `leads` — one row per company

| Column             | Type | Source                  | Notes                        |
|--------------------|------|-------------------------|------------------------------|
| `id`               | PK   | autoinc                 |                              |
| `company`          | TEXT | importer                | required                     |
| `website`          | TEXT | importer                |                              |
| `email`            | TEXT | importer                | drives email-channel send    |
| `linkedin`         | TEXT | importer                | not yet wired                |
| `form_url`         | TEXT | importer                | drives form-channel send     |
| `country`          | TEXT | importer                |                              |
| `notes`            | TEXT | importer                | analyst's commentary, sent to LLM |
| `raw`              | JSON | importer                | original CSV row             |
| `channel`          | TEXT | importer (`_detect_channel`) | form / email / linkedin / tender_only / none |
| `category`         | TEXT | importer                | Dealer Group / Rental & Fleet / … |
| `priority`         | TEXT | importer                | A / B / C                    |
| `hq_city`          | TEXT | importer                |                              |
| `phone`            | TEXT | importer                |                              |
| `contact_name`     | TEXT | importer                | primary CEO / MD / buyer     |
| `contact_role`     | TEXT | importer                |                              |
| `do_form_outreach` | INT  | importer                | 0 for `tender_only` cats     |
| `language`         | TEXT | research                | detected site language       |
| `site_summary`     | TEXT | research                | LLM business_model           |
| `research`         | JSON | research                | full deep_research output    |
| `conversation`     | JSON | plan                    | full plan_conversation output (the playbook) |
| `current_step`     | TEXT | plan / mail / send      | last step in the conversation state machine — see §6 |
| `next_action_at`   | TEXT | (unused — see AUDIT)    | ISO timestamp for scheduler  |
| `offer_text`       | TEXT | plan                    | first_touch.body cached      |
| `form_plan`        | TEXT | (dead — see AUDIT)      | never written                |
| `status`           | TEXT | every step              | see lifecycle §6             |
| `last_error`       | TEXT | every step              | last failure reason          |
| `created_at`       | TEXT |                         | UTC ISO                      |
| `updated_at`       | TEXT | every `update_lead`     | UTC ISO                      |

### `messages` — every outbound + inbound message

| Column          | Type | Notes                                          |
|-----------------|------|------------------------------------------------|
| `id`            | PK   |                                                |
| `lead_id`       | FK   | → leads.id (CASCADE)                           |
| `direction`     | TEXT | `outbound` \| `inbound`                        |
| `channel`       | TEXT | `email` \| `form` \| `linkedin` \| `manual`    |
| `step`          | TEXT | `first_touch` \| `followup_1/2` \| `nurture_30d` \| `close` \| `objection_<key>` \| `discovery` |
| `subject`       | TEXT |                                                |
| `body`          | TEXT |                                                |
| `classification`| TEXT | inbound only — `interested` / `objection` / `not_now` / `no` / `auto_reply` / `unsubscribe` / `unclear` |
| `confidence`    | REAL | 0..1 from classify_reply                       |
| `raw`           | TEXT | full RFC822 envelope (email) / submission snippet |
| `message_id`    | TEXT | RFC822 Message-ID we set on outbound; from header for inbound |
| `in_reply_to`   | TEXT | RFC822 In-Reply-To                             |
| `thread_id`     | TEXT | our stable thread key = Message-ID of the first_touch |
| `from_addr`     | TEXT | bare email                                     |
| `to_addr`       | TEXT | bare email                                     |
| `created_at`    | TEXT | UTC ISO                                        |

Indexes: `(lead_id, created_at)`, `message_id`, `thread_id`.

### `attempts` — form-channel submission attempts (one per try)

| Column         | Type | Notes                                          |
|----------------|------|------------------------------------------------|
| `id`           | PK   |                                                |
| `lead_id`      | FK   | → leads.id                                     |
| `channel`      | TEXT | always `form` today                            |
| `strategy`     | JSON | LLM-proposed selectors + values                |
| `success`      | INT  | 0 / 1                                          |
| `confirmation` | TEXT | excerpt of "thank-you" page text               |
| `error`        | TEXT | last error (or `dry-run`)                      |
| `screenshot`   | TEXT | relative path to the after-submit PNG          |
| `created_at`   | TEXT | UTC ISO                                        |

### `inbox_state` — IMAP poller cursor (one row per folder)

| Column        | Type | Notes                                           |
|---------------|------|-------------------------------------------------|
| `folder`      | PK   | usually `INBOX`                                 |
| `uidvalidity` | INT  | snapshot of server's UIDVALIDITY at last poll   |
| `last_uid`    | INT  | highest UID we've ingested                      |
| `updated_at`  | TEXT | UTC ISO                                         |

### `replies` — **DEAD** (see AUDIT). Never read or written.

---

## 4. Configuration surface

| Source         | Loader                | Keys                                              | Required for       |
|----------------|-----------------------|---------------------------------------------------|--------------------|
| `.env`         | `config.load_env`     | `CLAUDE_BIN`, `CLAUDE_MODEL`, `PLAYWRIGHT_*`      | research, plan, form |
| `.env`         | `config.load_mailer`  | `SMTP_HOST/PORT/USER/PASSWORD/USE_TLS/FROM_*/REPLY_TO`, `MAIL_DAILY_LIMIT`, `MAIL_DELAY_SECONDS` | `mail` |
| `.env`         | `config.load_inbox`   | `IMAP_HOST/PORT/USER/PASSWORD/FOLDER`, `IMAP_POLL_SECONDS` | `inbox` |
| `sender.yaml`  | `config.load_sender`  | `name`, `role`, `company`, `email`, `phone`, `website`, `address`, `country`, `product_short` | plan, send, mail |
| `offer.md`     | `config.load_offer`   | free-text base offer + per-category angles        | plan               |

YAML values take precedence over env-var fallbacks (e.g. `SENDER_NAME` is the
fallback for `sender.yaml: name`).

---

## 5. CLI surface (every command)

| Command                              | Purpose                                                | Reads                                    | Writes                                  |
|--------------------------------------|--------------------------------------------------------|------------------------------------------|-----------------------------------------|
| `init`                               | Create / migrate the SQLite DB                         | —                                        | `data/leads.db`                         |
| `import <file>`                      | CSV/XLSX → `leads` rows                                | file                                     | `leads`                                 |
| `research [--id|--limit|--refresh]`  | Playwright + LLM deep-research                         | `leads.website`                          | `leads.research`, `language`, `site_summary`, `status` |
| `plan [--id|--limit|--refresh]`      | Generate full multi-turn playbook                      | `leads.research` + sender + offer        | `leads.conversation`, `offer_text`, `current_step`, `status` |
| `analyze [--id|--limit]`             | research + plan in one go                              | as above                                 | as above                                |
| `playbook <id> [--show]`             | Render ONE lead → `playbooks/leadNN-<slug>.md`         | `leads`, `messages`                      | playbooks/                              |
| `playbooks`                          | Render every lead → one combined md                    | `leads`, `messages`                      | playbooks/                              |
| `approve [--id|--all|--batch N]`     | Move analyzed → approved (human gate)                  | `leads`                                  | `leads.status`                          |
| `mail [--id|--step|--limit|--due|--live]` | Send a step via SMTP. `--due` picks all due leads + auto-picks each one's next step | `leads.conversation`, `leads.next_action_at`, mailer cfg | `messages` (outbound), `leads.status`, `leads.current_step`, `leads.next_action_at` |
| `due [--limit]`                      | List leads where `next_action_at <= now`               | `leads`                                  | stdout                                  |
| `campaign-init "name" [--webhook-url --daily-limit]` | One-off: create Smartlead campaign + push sequence template + register webhook | `SMARTLEAD_API_KEY`, `sender.yaml` | Smartlead campaign (remote); prints campaign_id |
| `push [--id|--priority|--limit|--campaign-id|--dry-run]` | Push approved+planned leads with per-lead custom fields to a Smartlead campaign | `leads.conversation`, `SMARTLEAD_*` | `leads.smartlead_lead_id`, `leads.smartlead_campaign_id`, `leads.pushed_at` |
| `webhook --serve [--host --port]`    | Run the HTTP receiver for Smartlead events (foreground)| `SMARTLEAD_WEBHOOK_SECRET` (optional)    | `messages` (outbound/inbound), `leads.status`, `leads.current_step` |
| `send [--id|--limit|--live]`         | Submit contact form via Playwright                     | `leads.conversation`, sender             | `attempts`, `messages` (outbound), `leads.status` |
| `inbox [--once/--watch]`             | Poll IMAP, attach replies, classify each               | imap server, `messages`, `inbox_state`   | `messages` (inbound), `leads.status`, `inbox_state` |
| `reply <id>`                         | Manual fallback: paste an inbound, classify it         | stdin / file                             | `messages` (inbound)                    |
| `status`                             | Lead counts by status                                  | `leads`                                  | stdout                                  |
| `report`                             | CSV of every lead + outcome                            | `leads`, `attempts`                      | `reports/report-…csv`                   |

Every send command defaults to **dry-run**. `--live` is required to actually
submit / send.

---

## 6. Lead lifecycle (state machine)

```
                        ┌─────────────────────────────┐
                        │        new                  │ ← import
                        └────────────┬────────────────┘
                                     │ research
                                     ▼
                        ┌─────────────────────────────┐
                        │     researched              │
                        └────────────┬────────────────┘
                                     │ plan
                                     ▼
                        ┌─────────────────────────────┐
                        │     analyzed                │ ← human reads playbook
                        └────────────┬────────────────┘
                                     │ approve
                                     ▼
                        ┌─────────────────────────────┐
                        │     approved                │
                        └────────────┬────────────────┘
                                     │ mail / send
              ┌──────────────┬───────┴───────┬──────────────┐
              ▼              ▼               ▼              ▼
        ┌─────────┐    ┌──────────┐    ┌──────────┐   ┌──────────┐
        │ sending │    │   sent   │    │  failed  │   │  skipped │
        └─────────┘    └────┬─────┘    └──────────┘   └──────────┘
                            │ inbox / reply
                            ▼
                       ┌──────────┐
                       │  replied │ — classified, suggested next move
                       └──────────┘
```

**`current_step` field** holds the LAST COMPLETED step (settled convention,
no `_sent` suffix — see AUDIT M1 fix):

| value                     | meaning                                          | set by                |
|---------------------------|--------------------------------------------------|-----------------------|
| `NULL`                    | playbook ready, nothing sent yet                 | `plan`                |
| `first_touch`             | first_touch shipped, awaiting reply / followup_1 | `mail` / `send`       |
| `followup_1`              | followup_1 shipped                               | `mail`                |
| `followup_2`              | followup_2 shipped                               | `mail`                |
| `nurture_30d`             | nurture_30d shipped — terminal cadence step      | `mail`                |
| `close`                   | close template shipped                           | `mail`                |
| `objection_<key>`         | objection-handler reply shipped (off-sequence)   | `mail`                |

The mapping `current_step → next_step → next_action_at` is encoded in
`scheduler.py`:

- `NULL` → next is `first_touch`, but **first_touch is never auto-scheduled**
  (it's gated behind manual `approve` + `mail --id N --live`).
- `first_touch` → `followup_1`, due at `first_touch_sent_at + 5 days`.
- `followup_1` → `followup_2`, due at `first_touch_sent_at + 10 days`.
- `followup_2` → `nurture_30d`, due at `first_touch_sent_at + 30 days`.
- `nurture_30d` / `close` / `objection_*` → terminal, `next_action_at = NULL`.

When an inbound reply lands, `inbox.ingest` (and the manual `reply` command)
sets `status='replied'` and `next_action_at=NULL` so the operator owns the
next move.

---

## 7. Channel matrix

| `lead.channel` | Picked when                                  | Send via            | Reply via       |
|----------------|----------------------------------------------|---------------------|-----------------|
| `form`         | `form_url` present, or only `website`        | `send` (Playwright) | manual `reply`  |
| `email`        | `email` present, no `form_url`               | `mail` (SMTP)       | `inbox` (IMAP)  |
| `linkedin`     | only `linkedin` URL present                  | (planned)           | (planned)       |
| `tender_only`  | category ∈ {Government, Mining, Corporate, Industry Assoc} | — (skipped) | — |
| `none`         | nothing usable                               | —                   | —               |

`mail` will however send to ANY lead that has `email` populated, regardless of
the importer-assigned `channel` — operator can override by enriching the email
field after the fact.

---

## 8. LLM contracts

All four LLM calls go through `claude_runner.ask_json`, which:

1. Wraps the system prompt with a "respond with VALID JSON only" guardrail.
2. Spawns `claude -p --output-format json` (optionally with `--allowedTools`).
3. Strips markdown fences, falls back to greedy `{...}` extraction.

| Caller           | Prompt file              | Allowed tools           | Returns (top-level keys)                  |
|------------------|--------------------------|-------------------------|-------------------------------------------|
| `research.deep_research` | `deep_research.md`        | `WebSearch, WebFetch`   | `business_model`, `vehicle_categories`, `current_brands`, `chinese_exposure`, `pain_points`, `opportunities`, `recommended_models`, `decision_makers`, `recent_news`, `red_flags`, `skip` |
| `conversation.plan_conversation` | `plan_conversation.md` | (none)                  | `summary_one_liner`, `suggested_models`, `first_touch{subject,body,opener,cta,compliance_footer}`, `objection_handlers[]`, `followups[]{step_key, day_offset, subject, body, hook}`, `discovery_questions[]`, `close_message{subject,body}`, `if_no_response_after_30d` |
| `conversation.classify_reply` | `classify_reply.md`     | (none)                  | `classification`, `matched_objection_key`, `sentiment`, `urgency`, `recommended_action`, `suggested_subject`, `suggested_body`, `rationale`, `confidence`, `must_human_review` |
| `form_filler._strategy_for_attempt` | `form_strategy.md`     | (none)                  | `fields[]{selector,kind,value}`, `consent_selectors[]`, `submit_selector`, `captcha`, `abort`, `abort_reason` |
| `form_filler._verify` | `verify_submission.md`  | (none)                  | `success`, `confirmation_excerpt`, `reason_if_failed` |

Every prompt file is markdown, version-controlled, and contains the input
schema + the exact JSON shape the LLM must return. Treat them as part of the
public API of the corresponding Python module.

---

## 9. Email threading

Outbound messages always set `Message-ID` via `email.utils.make_msgid(domain=
sender_domain)`. We store it on the `messages` row and reuse it as the
`thread_id` of the conversation.

For follow-ups, `mail.py` (CLI command) looks up the original first_touch's
Message-ID, sets:

- `In-Reply-To: <first-touch-msgid>`
- `References: <first-touch-msgid>`
- `Subject: Re: <original subject>`

Gmail / Outlook / Apple Mail group the entire sequence into one thread on the
recipient's side. `inbox.py` reverses this: an incoming reply's `In-Reply-To`
is matched against `messages.message_id` to find the originating lead, before
falling back to sender-email / sender-domain matching.

---

## 10. Compliance enforcement

POPIA s.69 requires every electronic marketing communication to identify the
sender and provide a working opt-out. The compliance footer is generated by
the LLM as part of `first_touch.compliance_footer` and reused by the mailer
on every subsequent step (`mailer.assemble_body` raises `MailError` if the
footer is empty).

The form filler enforces the same rule: `cli.send` refuses to dispatch a
form submission without a non-empty footer (cli.py:394–401).

Daily-limit gate (`MAIL_DAILY_LIMIT`) is enforced by `mail` via
`db.count_messages_today(channel="email")`. Form channel has no equivalent
limit — the `RATE_LIMIT_PER_HOUR` env var in `.env.example` is currently
documented but **not enforced** anywhere (see AUDIT).

---

## 11. Tests

| File                 | Covers                                                     | Network? |
|----------------------|------------------------------------------------------------|----------|
| `test_importer.py`   | column auto-detection, channel classification, the SA CSV  | no       |
| `test_playbook.py`   | markdown rendering of research + plan + history            | no       |
| `test_mailer.py`     | envelope build, threading headers, dry-run, factory inject | no       |
| `test_inbox.py`      | IMAP attach by In-Reply-To, classify hook, cursor advance  | no       |
| `test_scheduler.py`  | state machine (next_cadence_step), next_action_at math, due-list selection | no       |
| `test_smartlead.py`  | payload builders (sequence template + per-lead vars), httpx mock for API client | no       |
| `test_webhook.py`    | event dispatch (SENT/REPLY/BOUNCE/UNSUB), idempotency, HMAC signature | no       |

Run: `pytest tests/`. All 54 tests are pure-Python with stdlib mocks
(smtplib + imaplib + httpx MockTransport) — no live SMTP/IMAP, no
Playwright, no Claude, no Smartlead account.

---

## 12. External dependencies

- `playwright` (Chromium) — research + form fill
- `claude` CLI — all LLM calls (no API key needed)
- `pandas`, `pyyaml`, `python-dotenv`, `typer`, `rich` — utility
- `smtplib` / `imaplib` — stdlib, no external broker
- `httpx` — Smartlead REST calls
- `http.server` — stdlib webhook receiver (no Flask/FastAPI)

The toolkit is single-process, single-machine, single-user. There is no
orchestrator, no queue, no daemon — every command runs to completion and
exits. Long-running modes: `inbox --watch` (legacy IMAP polling) and
`webhook --serve` (Smartlead receiver).

---

## 13. Thick mode — Smartlead.ai integration

Sending path the toolkit was extended with on 2026-05-11. The legacy SMTP
+ scheduler path still works; thick mode is opt-in via setting
`SMARTLEAD_API_KEY` and `SMARTLEAD_CAMPAIGN_ID` in `.env`.

### What Smartlead owns vs. what we own

```
┌─────────────────────────────────────────────────────────────────────┐
│ WE OWN                              │  SMARTLEAD OWNS                │
├─────────────────────────────────────┼────────────────────────────────┤
│ CSV import + dedup                  │  sending infrastructure        │
│ Claude research (per company)       │  inbox rotation (N mailboxes)  │
│ Claude playbook generation          │  domain warmup pool            │
│ Per-lead personalisation            │  cadence timing (day 0/5/10/30)│
│ Reply classification (Claude)       │  threading (RFC 5322 In-Reply) │
│ POPIA footer wording                │  bounce detection              │
│ State of every lead (sqlite)        │  open/click tracking (we opt   │
│                                     │  out — POPIA noise)            │
└─────────────────────────────────────┴────────────────────────────────┘
```

### Wire diagram (one-time setup + run loop)

```
ONE-TIME SETUP                                         RUN LOOP
─────────────                                         ────────

outreach import data/leads.csv                        outreach push --priority A
   │                                                       │
   ▼                                                       ▼
outreach research --priority A                       Smartlead.add_leads(campaign_id,
   │                                                      [per-lead payloads])
   ▼                                                       │
outreach plan --priority A                                 ▼
   │                                                  Smartlead enqueues
   │                                                  Day 0 send / Day 5 / etc.
   │                                                       │
   ▼                                                       ▼ (Smartlead sends)
outreach campaign-init "RHD Q3"                       ┌──────────────────────┐
   --webhook-url https://..                           │ EMAIL_SENT webhook   │
   --daily-limit 30                                   │   → record outbound  │
   │                                                  │   → current_step=N   │
   │  Smartlead.create_campaign()                     └──────────────────────┘
   │  Smartlead.update_sequence(            ◄──────── ┌──────────────────────┐
   │      [4 steps with                                │ EMAIL_REPLY webhook  │
   │       {{body_first_touch}} etc.])                 │   → record inbound   │
   │  Smartlead.update_settings(daily=30)             │   → classify (Claude)│
   │  Smartlead.register_webhook(...)                 │   → status=replied   │
   │                                                  │   → next_action=NULL │
   ▼                                                  └──────────────────────┘
campaign_id printed,                                  ┌──────────────────────┐
written to .env                                       │ EMAIL_BOUNCE webhook │
                                                      │   → status=failed    │
outreach webhook --serve --port 8080                  └──────────────────────┘
(runs on VPS, behind nginx + TLS)                     ┌──────────────────────┐
                                                      │ LEAD_UNSUBSCRIBED    │
                                                      │   → status=unsub.    │
                                                      │   → do_form_outreach │
                                                      │     = 0              │
                                                      └──────────────────────┘
```

### Sequence template + per-lead variables

We push the sequence template **once** to Smartlead (in `campaign-init`).
It's authored around `{{var}}` placeholders rather than hard-coded copy:

```
Step 1 (Day +0):
  Subject: {{subject_first_touch}}
  Body:    {{body_first_touch}}
           --
           <sender block from sender.yaml>
           {{compliance_footer}}

Step 2 (Day +5):
  Subject: (empty → Smartlead threads as Re:)
  Body:    {{body_followup_1}}
           --
           <sender block>
           {{compliance_footer}}

Step 3 (Day +10): {{body_followup_2}}
Step 4 (Day +30): {{body_nurture_30d}}
```

Per-lead variables (`subject_first_touch`, `body_first_touch`, …,
`body_nurture_30d`, `compliance_footer`, `our_lead_id`) are pushed via
`POST /campaigns/{id}/leads` from `outreach push`.

Missing follow-ups in the playbook → empty variable → Smartlead skips
the step. State machine semantics from `scheduler.py` still apply: the
webhook receiver advances `leads.current_step` as each EMAIL_SENT event
fires.

### Idempotency

`messages.smartlead_event_id` is a SHA-256 of
`(event_type, campaign_id, lead_id, sequence_step, event_timestamp,
message_id)`. A unique index drops re-deliveries; Smartlead does retry
on 5xx, so this matters. Returning 200 on duplicate is intentional.

### Identity mapping

```
leads.id              ←→  leads.smartlead_lead_id
leads.email           ←→  Smartlead's lead-by-email lookup (fallback)
messages.message_id   ←→  Smartlead's `message_id` field on EMAIL_SENT
                          (used for inbox.py threading too)
```

### Security

- HMAC verification (optional): set `SMARTLEAD_WEBHOOK_SECRET`, receiver
  validates `X-Smartlead-Signature: sha256=<hex>` on every POST.
- API key is sent as a `?api_key=` query param — Smartlead's design;
  not log-friendly. `webhook.py` never logs request URLs, only paths.
- TLS termination is OUT of scope: run `outreach webhook --serve` behind
  nginx / caddy that does TLS. The receiver is plain HTTP on localhost.
