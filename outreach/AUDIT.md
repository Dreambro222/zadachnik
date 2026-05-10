# Code audit — 2026-05-10

Audit of the entire `outreach/` package. Severity scale:

- **HIGH** — wrong output reaching the user / incorrect behaviour at runtime
- **MEDIUM** — wastes work, will surprise an operator, or blocks a feature
- **LOW** — cosmetic, edge case, or future hygiene
- **DEAD** — unused code paths

Each item has: where, what, why, recommended fix.

---

## HIGH

### H1. `reporter.py` reads a column that is never written

**Where:** `outreach/reporter.py:32-41` (the `_extract` helper).
**What:** reads `lead["form_plan"]` and pulls `offer.subject` / `offer.first_line`
from it. The `form_plan` column is defined in `db.py:28` but **no code ever
writes to it** (confirmed via `grep -rn 'form_plan' outreach/` — only the
schema definition + this reader).
**Effect:** every CSV report has empty `subject` and `first_line` columns.

**Fix:** `_extract` should read from `lead["conversation"]` (JSON) and pull:

```python
plan = json.loads(lead["conversation"] or "{}")
ft = plan.get("first_touch") or {}
subject = ft.get("subject") or ""
first_line = (ft.get("body") or "").splitlines()[0] if ft.get("body") else ""
```

### H2. `report` ignores email-channel sends

**Where:** `outreach/reporter.py:53-61` (the per-lead loop).
**What:** `sent_at` and `confirmation` are pulled from the `attempts` table,
which is only populated by the form-channel filler. Email sends only land in
`messages`. So every email-only lead shows blank `sent_at` in the report.

**Fix:** `sent_at` should come from `MAX(created_at)` over outbound
`messages` for that lead, not from `attempts`. Keep `attempts` for
form-only signal (screenshot path).

### H3. Importer has no dedup — re-running blows up the lead list

**Where:** `outreach/importer.py:103-138`.
**What:** every CSV row becomes a fresh `INSERT INTO leads`. There is no
UNIQUE constraint on `company` / `website`, no upsert. Running
`outreach import data/leads.za.csv` twice doubles the lead count.
**Effect:** silent corruption of state on re-import.

**Fix:**
- Add `UNIQUE(company, website)` (or just `company`) to the `leads` table.
- In `import_file`, do `INSERT … ON CONFLICT(company,website) DO UPDATE SET …`
  for the importable fields, leaving research/conversation/status untouched.
- Or, more conservatively: `SELECT id FROM leads WHERE lower(company)=?`
  before inserting, and skip / merge by hand.

---

## MEDIUM

### M1. `current_step` semantics are inconsistent

**Where:** three writers:

- `cli.py:204` — `plan` sets `current_step="first_touch"` (the **next** step
  to send).
- `cli.py:454` — `send` (form) sets `current_step="first_touch_sent"` (the
  **last** step that was sent, with `_sent` suffix).
- `cli.py:637` — `mail` sets `current_step=f"{step}_sent"` (matches `send`).

**Effect:** the field's value mixes "next step" and "last step + _sent". It's
never read by any decision logic today (only stamped into the
`classify_reply` payload at `conversation.py:68`), so it doesn't break
anything yet. But once an auto-scheduler is added, this is a foot-gun.

**Fix:** pick one convention and document it in `db.py` schema comment.
Recommended: store the **last completed step** with no suffix, so the value
matches `messages.step` directly:

- `plan` sets `current_step=NULL` (nothing sent yet).
- `mail` / `send` set `current_step=step` after a successful send.
- Compute "what to send next" via a small state-machine helper in
  `conversation.py` (or `mailer.py`):
  `NULL → first_touch → followup_1 → followup_2 → nurture_30d → close`.

### M2. `next_action_at` is never written

**Where:** `db.py:46` defines it; `README.md:279` documents it as "wired but
no scheduler reads it yet". Stronger: **nothing writes it**. `grep -rn
next_action_at outreach/` shows only the schema and the README mention.

**Effect:** `outreach due` / scheduled follow-ups can't be built without
first wiring writes.

**Fix:** in `mail` and `send`, after a successful step, compute
`next_action_at` from the playbook's `followups[*].day_offset`:

```python
ft_msg = first_outbound_for(lead_id)         # → messages.created_at
next_step = state_machine.next_after(step)   # e.g. "followup_2"
day_offset = plan.followups[next_step].day_offset
next_action_at = ft_msg.created_at + timedelta(days=day_offset)
```

For terminal states (`replied`, `nurture_30d_sent`, `close_sent`), set NULL.

### M3. `reply` CLI updates the wrong message under concurrency

**Where:** `cli.py:291-296`.
**What:** after `record_message` returns the new ID, the code re-finds it via
`SELECT MAX(id) FROM messages WHERE lead_id = ?`. Single-threaded this is
correct, but `record_message` already returns the rowid — just use it.

**Fix:**
```python
inbound_id = db.record_message(conn, lead_id, ...)
conn.execute(
    "UPDATE messages SET classification = ?, confidence = ? WHERE id = ?",
    (verdict["classification"], verdict["confidence"], inbound_id),
)
```

### M4. IMAP poller silently misses messages on UIDVALIDITY change

**Where:** `inbox.py:129-158`, `db.set_inbox_cursor` at line 298.
**What:** we read both `uidvalidity` and `last_uid` from `inbox_state`, but
we never **compare** the stored uidvalidity with the freshly-fetched one.
If the server bumps UIDVALIDITY (folder recreated, server migration), the
old `last_uid` is no longer meaningful — but the poller treats it as
authoritative and skips real new mail.

**Fix:** at the top of `fetch_new`, after reading server uidvalidity, if it
differs from the stored value, reset `last_uid=0` and log a warning. Or, on
mismatch, fetch by Date instead of UID.

### M5. First-run inbox poll fetches every email in INBOX

**Where:** `inbox.py:142`.
**What:** `criteria = "ALL" if last_uid==0 else "UID N+1:*"`. On first run,
this is `ALL` — every message in the dedicated outreach mailbox is parsed,
attached if possible, and possibly fed to `classify_reply`. A reused mailbox
means hundreds of unrelated old emails get processed (and unattached).

**Fix:** on first run, default to messages received **after the toolkit was
installed** — e.g. `SINCE today` IMAP criterion, or a `SETUP_AT` env var.

### M6. `RATE_LIMIT_PER_HOUR` is documented but not enforced

**Where:** `.env.example:11` declares `RATE_LIMIT_PER_HOUR=15`. No code reads
it.
**Effect:** form-channel `send --live` has no throttle; the operator could
hammer 73 sites in a minute.

**Fix:** add a check in `cli.send` that counts `attempts WHERE channel='form'
AND created_at >= now-1h` and bails if over the threshold. Same pattern as
`db.count_messages_today` for email.

### M7. `playbook.py` `_safe_load` swallows JSON errors silently

**Where:** `playbook.py:26-32`.
**What:** if `lead["research"]` is corrupted JSON, `_safe_load` returns `{}`
and the rendered playbook just shows "_Not researched yet._", which is
misleading.

**Fix:** log the JSON error to `last_error` (or print a warning at render
time) so the operator knows the LLM produced invalid JSON.

---

## LOW

### L1. Importer no-op `json.loads(json.dumps(...))`

**Where:** `importer.py:143`. Returns `json.loads(json.dumps(by_channel))`.
This is a round-trip that does nothing — the dict is already plain.
**Fix:** return `by_channel` directly.

### L2. `claude_runner.ask` accepts `cwd` but never uses it usefully

**Where:** `claude_runner.py:48`. `cwd` is passed to `subprocess.run`. No
caller passes a non-default cwd. Dead arg.
**Fix:** remove the parameter.

### L3. `mail` CLI sleeps in the foreground

**Where:** `cli.py:646-647`. With `MAIL_DAILY_LIMIT=20` and
`MAIL_DELAY_SECONDS=60`, the operator watches the terminal for 20 min.
**Fix:** acceptable for v1; future: schedule via cron with `--limit 1`.

### L4. `mailer.make_msgid` domain extraction assumes bare email

**Where:** `mailer.py:70`. Splits `cfg.from_email` on `@`. Works for the
expected `outreach@domain.com` shape; would break if someone puts
`Sender <a@b.com>` in `SMTP_FROM_EMAIL`. The mailer-loader doesn't validate.
**Fix:** run `cfg.from_email` through `email.utils.parseaddr` in
`config.load_mailer` and store the bare address.

### L5. `_DEFERRED_LEAD_COLUMNS` migration is now redundant

**Where:** `db.py:134-158`. The base SCHEMA already lists
`research / conversation / current_step / next_action_at`. The migration
table only matters for legacy DBs created before those columns landed.
**Fix:** keep the migration block (cheap insurance) but update the comment
to clarify it only services pre-migration databases.

### L6. `inbox.py` updates cursor only when new mail arrived

**Where:** `inbox.py:297-298`. If `new_last_uid == last_uid`, we never write
the row, so a freshly-bumped `uidvalidity` from the server is never recorded
on a no-mail poll.
**Fix:** unconditional `set_inbox_cursor` at the end of `ingest`.

### L7. `_extract_body` strips HTML naively

**Where:** `inbox.py:60-81`. Regex strips tags. Loses links, structure, and
quoted-reply markers. Acceptable for `classify_reply` since the LLM is
robust to messy text, but worth knowing if classifier accuracy drops.
**Fix:** consider `html2text` if classification accuracy becomes an issue.

### L8. README mentions only "Two suites" of tests

**Where:** `README.md:225` says "Two suites" — actually 4
(`test_importer.py`, `test_playbook.py`, `test_mailer.py`, `test_inbox.py`).
**Fix:** stale; will be updated in this commit.

### L9. README "Channel classification" is stale on email

**Where:** `README.md:140` still says "channel = email (sending TBD)".
Sending is now wired.
**Fix:** stale; updated in this commit.

### L10. Form filler types into elements with `delay=15`

**Where:** `form_filler.py:140`. 15 ms per character is human-ish, but
nothing varies. Easy to detect by anti-bot fingerprinters.
**Fix:** acceptable for v1. Future: jitter, or use a real browser profile
with cookies.

### L11. `screenshots/` dir grows unboundedly

**Where:** `form_filler.py:241,272`. Every form attempt writes 1–6 PNGs.
Over hundreds of leads with 3 attempts each, that's thousands of files.
**Fix:** add a `screenshots:purge` CLI or a date-based cleanup.

---

## DEAD code

### D1. `replies` table

**Where:** `db.py:95-103`. Created on init, never read or written. Replaced
by `messages` with `direction='inbound'`.
**Fix:** drop from schema. Run a migration that drops the table on init.

### D2. `leads.form_plan` column

**Where:** `db.py:28`. Only read by reporter (incorrectly — see H1).
**Fix:** drop from schema; it predates `conversation`.

### D3. `claude_runner.ClaudeResult.raw` field rarely used

**Where:** `claude_runner.py:25,110`. Returned but no caller reads
`.raw` — they all go through `ask_json`.
**Fix:** keep for debugging; document as such.

---

## SECURITY

### S1. SMTP / IMAP passwords in plaintext `.env`

**Where:** `.env.example:33,53`.
**What:** standard Unix practice but worth flagging. Anyone with read access
to the project root has the credentials.
**Fix:** for production, use OS keyring (`keyring.get_password("outreach",
"smtp")`) or a secrets manager. Not blocking for dev.

### S2. No outbound TLS verification toggle for local dev

**Where:** `mailer.py:96-104`. Uses `ssl.create_default_context()` which
verifies the cert chain. Good. No `verify_mode=CERT_NONE` shortcut anywhere.
No action needed.

### S3. No CAPTCHA detection for hCaptcha invisible / Turnstile auto-solve

**Where:** `form_filler.py:228-232` aborts only when LLM judges
`captcha != "none"`. If LLM misses an invisible challenge, we submit and
get silently dropped on the server side.
**Fix:** in addition to LLM judgement, regex-check the HTML for
`hcaptcha-checkbox`, `cf-turnstile`, `g-recaptcha` elements before submit.

---

## Recommended next-steps (in order)

1. **H1 + H2 fix**: rewire `reporter.py` to read `conversation` JSON and
   email `messages`. Without this, the report command is broken for the
   email channel — which is now our primary channel.
2. **H3 fix**: dedup on import. Otherwise re-import scenarios silently
   corrupt state.
3. **M1 + M2 fix**: settle `current_step` semantics + start writing
   `next_action_at`. Unblocks the autopilot scheduler (`outreach due`,
   `mail --due --live`).
4. **M4 + M5 fix**: harden the IMAP poller against UIDVALIDITY changes and
   first-run mailbox flooding.
5. **M6 fix**: enforce `RATE_LIMIT_PER_HOUR` for form sends.
6. **D1 + D2**: drop the dead `replies` table and `form_plan` column.
7. **L*** items: cosmetic, fix opportunistically.

The HIGH and MEDIUM-priority items together are roughly half a day of work.
None of them block a small-scale (10–20 leads) live test today — but H1, H3
and M1/M2 will bite as soon as we run the system at scale.
