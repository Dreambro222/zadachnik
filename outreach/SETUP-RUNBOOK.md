# Setup runbook — from zero to first `outreach push --live`

**Audience**: you (the operator), running through this once on your laptop +
your Hetzner VPS, after deciding to use the **Smartlead.ai thick mode**.

**Time budget**: 90 minutes of clicking + 24–48h of waiting for pre-warmed
inboxes (or 30 minutes if you pick Primeforge).

**Total spend month 1**: ~$55–80 (Smartlead $39 + inboxes $13–30 + domain
$15/yr + Hetzner already covered).

---

## Stage 0 — Decisions you make before clicking anything

Two choices, both fast:

### A. Pre-warmed inbox provider — pick ONE

| Pick | Cost | Ready in | Why pick it |
|---|---|---|---|
| **Primeforge Google Workspace × 3** ⭐ | $13.50/mo | 30 minutes | Your own brand domain, native Smartlead integration, fastest |
| Smartlead native pre-warmed (Outlook × 3) | $13.50/mo + $18/yr | 24–48 h | Single vendor (everything in Smartlead UI), but generic domain |
| Infraforge × 3 | $12/mo + dedicated IP | 5 minutes | Dedicated IPs (overkill for 74 leads) |

**Recommended: Primeforge.** Rest of this runbook assumes that. The
substitutions are obvious if you pick another.

### B. Sending domain

If you went with Primeforge → they sell you the domain in checkout. Pick a
neutral one (e.g. `tradehub-africa.com`). Done.

If you went with Smartlead native → they provide a generic domain. You
don't choose it.

### C. Webhook domain — for the inbound reply receiver

You need ONE more domain (or a subdomain of any existing one you own) to
host the webhook receiver on your Hetzner box. Example:
`outreach.yourdomain.io`. **Not the same as the sending domain** — keeps
reputation isolated.

If you have no domain anywhere, buy one for $10–15 on
[namecheap.com](https://www.namecheap.com) or
[cloudflare.com/products/registrar](https://www.cloudflare.com/products/registrar/).
Cloudflare is cheaper but requires using their DNS.

---

## Stage 1 — Smartlead account + API key  (10 min)

1. Open https://app.smartlead.ai/signup
2. Sign up with the email you'll use for support tickets (not the sending
   domain — use your personal/corporate inbox).
3. Pick the **Basic plan $39/mo** after the 14-day trial — or skip the
   payment screen for now and use the trial for the smoke-test.
4. In the dashboard: **Settings → API Keys → Create New Key**.
5. Copy the key. **Save it somewhere safe.** Smartlead won't show it again.

✅ At this point you have `SMARTLEAD_API_KEY`. Hold it for Stage 4.

---

## Stage 2 — Pre-warmed inboxes  (5 min order, 30 min wait)

### If Primeforge:
1. Open https://www.primeforge.ai/
2. Click **Get Started** → choose **Google Workspace mailboxes**.
3. Quantity: **3 mailboxes**. Plan: monthly billing.
4. Pick a domain in checkout (e.g. `tradehub-africa.com`).
5. Pay (Stripe, accepts most cards).
6. After payment Primeforge sends you 3 emails over the next 30 minutes
   with credentials for each inbox.
7. Inside Primeforge dashboard → **"Connect to Smartlead"** button →
   one-click OAuth → your 3 inboxes appear in Smartlead → **Email
   Accounts**.

### If Smartlead native:
1. In Smartlead dashboard → **Email Accounts → Add → "Buy Pre-Warmed
   Mailboxes"**.
2. Pick **Outlook** (cheapest, $3.99/mo) or **Google** ($9/mo).
3. Quantity: **3**, billing: monthly.
4. Pay.
5. Inboxes appear in 24–48h — you'll get an email when ready.

✅ At this point you have 3 connected inboxes in Smartlead. Verify by
running stage 4's smoke test.

---

## Stage 3 — VPS bootstrap on Hetzner  (15 min)

You already have a Hetzner box. SSH in as root.

### 3a. DNS first
On your DNS provider (Cloudflare / Namecheap), add:
```
Type: A
Name: outreach    (or whatever subdomain you want)
Value: <your Hetzner public IP>
TTL: 5 min
```

Wait 2 minutes, verify:
```bash
dig +short outreach.yourdomain.io
# should print your Hetzner IP
```

### 3b. Run the bootstrap script
On the Hetzner box:
```bash
curl -fsSL https://raw.githubusercontent.com/dreambro222/zadachnik/claude/automated-lead-outreach-mlZ8U/outreach/deploy/bootstrap.sh -o /tmp/bootstrap.sh

# Substitute YOUR webhook domain:
sudo DOMAIN=outreach.yourdomain.io \
     REPO=https://github.com/dreambro222/zadachnik.git \
     bash /tmp/bootstrap.sh
```

What it does:
- installs python 3.11, nginx, certbot, git
- creates `outreach` system user
- clones the repo to `/home/outreach/zadachnik`
- creates `.venv`, pip installs
- copies `.env.example` → `.env`, generates a fresh `SMARTLEAD_WEBHOOK_SECRET`
- installs nginx config with TLS via Let's Encrypt
- installs systemd unit `outreach-webhook`, starts it
- opens firewall ports 22 / 80 / 443 (closes everything else)
- prints next-steps summary

Output should end with `✓ smoke test passed` and a public webhook URL.

### 3c. Verify
```bash
curl https://outreach.yourdomain.io/health   # → "ok"
systemctl status outreach-webhook            # → active (running)
```

✅ Public HTTPS endpoint listening at
`https://outreach.yourdomain.io/webhook/smartlead`.

---

## Stage 4 — Paste keys into .env, run smoke test  (5 min)

SSH to Hetzner, become the `outreach` user:
```bash
sudo -u outreach -i
cd /home/outreach/zadachnik/outreach
```

Edit `.env`:
```bash
nano .env
```

Fill these (the file already has comments explaining each):
```
SMARTLEAD_API_KEY=sk_live_...                          # from Stage 1
SMARTLEAD_CAMPAIGN_ID=                                  # leave empty for now
SMARTLEAD_WEBHOOK_SECRET=                              # already set by bootstrap
ANTHROPIC_API_KEY=                                     # if not using `claude login`
SENDER_NAME="Your Name"
SENDER_COMPANY="Your Company"
SENDER_EMAIL="you@tradehub-africa.com"                 # the Primeforge inbox
SENDER_PHONE="+27..."                                  # working number
SENDER_WEBSITE="https://tradehub-africa.com"
```

Save. Run the smoke test:
```bash
source /home/outreach/zadachnik/.venv/bin/activate
python /home/outreach/zadachnik/outreach/scripts/smartlead_smoke.py
```

Expected: ✓ API key works, lists your 3 Primeforge inboxes, lists 0
campaigns. If it fails — check the API key.

✅ The Hetzner box can now talk to Smartlead.

---

## Stage 5 — Create the Smartlead campaign  (1 minute)

Still on Hetzner as `outreach` user:
```bash
cd /home/outreach/zadachnik/outreach
python -m outreach campaign-init "RHD-SA Q1 2026" \
    --webhook-url https://outreach.yourdomain.io/webhook/smartlead \
    --daily-limit 30
```

This:
1. POSTs to Smartlead → creates a campaign called "RHD-SA Q1 2026".
2. Pushes our 4-step sequence template (Day 0 / +5 / +10 / +30) with
   `{{var}}` placeholders.
3. Registers the webhook URL with HMAC secret.
4. Prints the new `campaign_id`.

Copy the printed campaign_id into `.env`:
```
SMARTLEAD_CAMPAIGN_ID=12345
```

In Smartlead UI → **Campaigns → RHD-SA Q1 2026 → Email Accounts** →
attach all 3 of your Primeforge inboxes to this campaign.

✅ Campaign live, but with zero leads.

---

## Stage 6 — Prep the leads (research + plan)  (15 min)

You can do this on the Hetzner box OR on your laptop — it only writes to
`data/leads.db`. Let's say laptop, for convenience.

On your laptop, with the repo cloned and `.venv` activated:
```bash
outreach init                               # creates leads.db locally
outreach import data/leads.za.csv           # ingests 74 leads
outreach research --priority A --limit 5    # 5 leads * ~2 min = 10 min
outreach plan --priority A --limit 5        # 5 leads * ~1 min = 5 min
outreach playbooks                          # exports markdown → playbooks/
```

Open `playbooks/leadXX-<slug>.md` files. **Read them with your own eyes.**
If Claude wrote anything fishy / off-tone / factually wrong about a
company — fix the lead's `conversation` blob via SQL, OR `outreach plan
--id N --refresh`, OR just `outreach approve --id N` for the ones that
look good and skip the rest.

✅ 5 leads in `analyzed` status with playbooks you've eyeballed.

---

## Stage 7 — Push to Smartlead, dry-run first  (3 min)

Get `leads.db` to the Hetzner box (so the webhook receiver can find
each lead when Smartlead pings):
```bash
scp data/leads.db outreach@<hetzner>:/home/outreach/zadachnik/outreach/data/
```

Then on Hetzner:
```bash
sudo -u outreach -i
cd /home/outreach/zadachnik/outreach
source ../.venv/bin/activate

# Dry-run: print payloads, don't POST.
outreach push --priority A --limit 5 --dry-run
```

Read the dry-run output. If it looks right:
```bash
outreach push --priority A --limit 5
```

Smartlead will start sending Day-0 emails to those 5 leads, throttled by
campaign's daily limit and inbox rotation.

✅ First 5 emails queued. Live.

---

## Stage 8 — Watch  (ongoing)

### What to watch on Smartlead UI
- **Campaigns → RHD-SA Q1 2026 → Statistics**: sent / opens / replies
- **Email Accounts**: deliverability scores per inbox (should stay >90%)
- **Master Inbox**: every reply lands here as well as our DB

### What to watch on our side
```bash
# On Hetzner — webhook events arriving:
journalctl -u outreach-webhook -f

# On your laptop or Hetzner — status overview:
outreach status

# Detailed report:
outreach report
cat reports/outreach_report.csv
```

### Replies — operator action

When `status='replied'` appears for a lead:
1. Read the conversation in Smartlead Master Inbox.
2. Decide: send the playbook's `close_message`, send an objection
   handler, or just answer manually.
3. Send your reply directly from Smartlead UI (it threads under the
   right Message-ID automatically).
4. After reply: `outreach mail --id <N> --step close --live` IF you
   want to send the close template through our pipeline. Or just keep
   it in Smartlead — either works since the webhook syncs back.

✅ You're running on autopilot. Replies pile up. Operator only intervenes
on conversations.

---

## Stage 9 — Scale to 74  (after 5-lead test goes well, ~3 days in)

If after 3 days the first 5 leads show:
- 0 bounces on Smartlead UI
- ≥1 reply (5–20% is normal, depends on offer + ICP fit)
- Deliverability score >90% per inbox

Then push the rest:
```bash
outreach push --priority A           # all remaining HIGH priority
outreach push --priority B           # then MEDIUM
outreach push --priority C           # then LOW
```

Smartlead throttles at `--daily-limit 30` → 74 leads fully Day-0'd over
~2.5 days.

---

## Stage 10 — Maintenance

### Daily
- `outreach status` (laptop) — see lead counts by status
- Read replies in Smartlead Master Inbox
- Reply to interested leads from Smartlead UI

### Weekly
- `outreach report` → review CSV
- Check Hetzner uptime: `systemctl status outreach-webhook`
- Check inbox deliverability scores in Smartlead

### Monthly
- Rotate Smartlead API key if any leak suspected
- Back up `leads.db`: `rsync /home/outreach/zadachnik/outreach/data/leads.db
  <backup-server>:/backup/leads-$(date +%F).db`
- Re-evaluate which priority bucket to load next

---

## Troubleshooting

### `outreach push` errors with `SmartleadError: HTTP 401`
→ API key wrong / expired. Re-copy from Smartlead → Settings → API Keys.

### Webhook receiver returns 401 on Smartlead's POST
→ `SMARTLEAD_WEBHOOK_SECRET` in `.env` doesn't match the secret Smartlead
is signing with. Either regenerate (`openssl rand -hex 32`) and re-register
the webhook in Smartlead UI, OR copy Smartlead's secret into `.env` and
`systemctl restart outreach-webhook`.

### `outreach status` shows 0 leads `sent` even though Smartlead sent them
→ Hetzner box isn't receiving webhooks. Check:
```bash
curl -X POST https://outreach.yourdomain.io/webhook/smartlead \
     -H "Content-Type: application/json" -d '{}'
# should return some text, not 404 / certificate error
```
Then check Smartlead → Campaign → Webhooks — is the URL correctly registered?

### "no matching lead" in webhook logs
→ Webhook arrived for a lead our DB doesn't have. Either:
- The webhook came from a campaign you set up manually in Smartlead UI
  (not via our `campaign-init`) — leads have no `smartlead_lead_id`.
- The lead exists in Smartlead but our DB doesn't have it (you pushed
  via the UI directly).

Fix: in Smartlead UI, find the lead's `smartlead_lead_id`, and
`UPDATE leads SET smartlead_lead_id = ? WHERE email = ?` in sqlite.

### `journalctl -u outreach-webhook` shows nothing at all
→ Smartlead is hitting the URL but nginx is dropping it. Check
`/var/log/nginx/access.log` — look for `POST /webhook/smartlead` lines.

---

## Cheat sheet — what to paste, where, in what order

```
Stage 1:  https://app.smartlead.ai/signup
          → Settings → API Keys → Create → copy key → KEEP

Stage 2:  https://www.primeforge.ai/
          → 3 Google mailboxes + domain
          → after 30 min: "Connect to Smartlead" button

Stage 3:  ssh root@<hetzner>
          DNS: A record outreach.<domain> → <hetzner-ip>
          curl ... bootstrap.sh | sudo DOMAIN=... bash

Stage 4:  ssh, nano /home/outreach/zadachnik/outreach/.env
          paste: SMARTLEAD_API_KEY, SENDER_*
          python scripts/smartlead_smoke.py    # verify

Stage 5:  outreach campaign-init "RHD-SA Q1 2026" --webhook-url ...
          copy printed campaign_id → .env → restart webhook
          Smartlead UI → attach inboxes to campaign

Stage 6:  (laptop) outreach research / plan / playbooks / approve

Stage 7:  scp leads.db → hetzner
          outreach push --priority A --limit 5 --dry-run
          outreach push --priority A --limit 5

Stage 8:  watch journalctl, outreach status, Smartlead UI

Stage 9:  outreach push --priority A / B / C (after 3 days verified)
```

That's it. From "I have nothing" to "first 5 leads sent" is ~90 minutes
of clicking + 30 min of Primeforge provisioning.
