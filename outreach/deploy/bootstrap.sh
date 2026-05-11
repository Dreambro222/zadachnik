#!/usr/bin/env bash
# bootstrap.sh — one-shot VPS setup for the outreach toolkit.
#
# Run as root (or via sudo) on a fresh Ubuntu 22.04 / 24.04 box. It is
# IDEMPOTENT — safe to re-run after editing .env or pulling a new commit.
#
# What it does, in order:
#   1. Install system packages (python, nginx, certbot, git).
#   2. Create the `outreach` system user (if missing) and clone/pull repo.
#   3. Build a Python venv at /home/outreach/outreach/.venv and pip install.
#   4. Initialise data/leads.db (sqlite migration runs automatically).
#   5. Install /etc/nginx/sites-available/outreach with envsubst $DOMAIN.
#   6. Run certbot --nginx -d $DOMAIN to obtain Let's Encrypt cert.
#   7. Install systemd unit, enable, start.
#   8. Print the public URL Smartlead should POST to.
#
# Usage:
#   sudo DOMAIN=outreach.yourdomain.africa REPO=https://github.com/you/zadachnik bash bootstrap.sh
#
# Requirements before running:
#   - .env file already exists at /home/outreach/outreach/outreach/.env
#     (this script will create a skeleton if missing; you still need to
#     paste the real SMARTLEAD_API_KEY etc.)
#   - DNS A record for $DOMAIN already points at this box's public IP.
#     Check with: dig +short $DOMAIN — should match `curl -s ifconfig.me`.

set -euo pipefail

# ---------- configuration ----------
: "${DOMAIN:?Set DOMAIN=outreach.yourdomain.africa before running}"
: "${REPO:=https://github.com/dreambro222/zadachnik.git}"
: "${SERVICE_USER:=outreach}"
: "${REPO_DIR:=/home/${SERVICE_USER}/zadachnik}"
: "${BRANCH:=claude/automated-lead-outreach-mlZ8U}"
: "${ADMIN_EMAIL:=postmaster@${DOMAIN}}"   # for Let's Encrypt expiry warnings

OUTREACH_DIR="${REPO_DIR}/outreach"
VENV_DIR="${REPO_DIR}/.venv"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[bootstrap] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. system packages ----------
log "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    python3.11 python3.11-venv python3-pip \
    git nginx certbot python3-certbot-nginx \
    ufw curl jq sqlite3 \
    >/dev/null

# ---------- 2. service user + repo ----------
if ! id "${SERVICE_USER}" &>/dev/null; then
    log "Creating service user '${SERVICE_USER}'..."
    adduser --disabled-password --gecos "" "${SERVICE_USER}"
fi

if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log "Cloning ${REPO} into ${REPO_DIR}..."
    sudo -u "${SERVICE_USER}" git clone --branch "${BRANCH}" "${REPO}" "${REPO_DIR}"
else
    log "Updating ${REPO_DIR}..."
    sudo -u "${SERVICE_USER}" git -C "${REPO_DIR}" fetch origin "${BRANCH}"
    sudo -u "${SERVICE_USER}" git -C "${REPO_DIR}" checkout "${BRANCH}"
    sudo -u "${SERVICE_USER}" git -C "${REPO_DIR}" pull --ff-only origin "${BRANCH}"
fi

# ---------- 3. python venv ----------
if [[ ! -d "${VENV_DIR}" ]]; then
    log "Creating Python venv at ${VENV_DIR}..."
    sudo -u "${SERVICE_USER}" python3.11 -m venv "${VENV_DIR}"
fi
log "Installing requirements..."
sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/pip" install -q --upgrade pip
sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/pip" install -q -r "${OUTREACH_DIR}/requirements.txt"

# ---------- 4. .env skeleton + leads.db ----------
ENV_FILE="${OUTREACH_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    log "Creating skeleton .env (you MUST fill SMARTLEAD_API_KEY before running webhook!)"
    sudo -u "${SERVICE_USER}" cp "${OUTREACH_DIR}/.env.example" "${ENV_FILE}"
    # Pre-generate the HMAC secret so Smartlead webhook signatures work out of the box.
    HMAC=$(openssl rand -hex 32)
    sudo -u "${SERVICE_USER}" sed -i "s|^SMARTLEAD_WEBHOOK_SECRET=.*|SMARTLEAD_WEBHOOK_SECRET=${HMAC}|" "${ENV_FILE}"
    log "  → generated SMARTLEAD_WEBHOOK_SECRET in .env. Paste the same value"
    log "    into Smartlead → Campaigns → Webhooks → Secret when registering."
fi

log "Initialising leads.db (idempotent)..."
sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/python" -m outreach init || true

# ---------- 5. nginx ----------
log "Installing nginx config for ${DOMAIN}..."
export DOMAIN
envsubst '${DOMAIN}' < "${OUTREACH_DIR}/deploy/nginx-outreach.conf" \
    > /etc/nginx/sites-available/outreach
ln -sf /etc/nginx/sites-available/outreach /etc/nginx/sites-enabled/outreach
[[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

# Privacy policy file served at /privacy.
mkdir -p /var/www/outreach
cp "${OUTREACH_DIR}/deploy/privacy-policy.html" /var/www/outreach/privacy-policy.html

nginx -t
systemctl reload nginx

# ---------- 6. TLS cert ----------
if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log "Obtaining Let's Encrypt certificate for ${DOMAIN}..."
    certbot --nginx -d "${DOMAIN}" \
        --non-interactive --agree-tos --email "${ADMIN_EMAIL}" \
        --redirect \
        || die "certbot failed — check that DNS A record for ${DOMAIN} points here. Public IP is $(curl -s ifconfig.me)"
else
    log "TLS cert for ${DOMAIN} already exists — skipping certbot."
fi

# ---------- 7. systemd unit ----------
log "Installing systemd unit..."
export SERVICE_USER REPO_DIR
envsubst '${SERVICE_USER} ${REPO_DIR}' < "${OUTREACH_DIR}/deploy/outreach-webhook.service" \
    > /etc/systemd/system/outreach-webhook.service
systemctl daemon-reload
systemctl enable outreach-webhook
systemctl restart outreach-webhook

# ---------- 8. firewall ----------
log "Configuring ufw (22/80/443 only)..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp  >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

# ---------- 9. summary ----------
log "Done. Smoke-checking..."
sleep 2
HEALTH=$(curl -fsS "https://${DOMAIN}/health" || echo "UNREACHABLE")
STATUS=$(systemctl is-active outreach-webhook)

cat <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║  OUTREACH TOOLKIT — VPS BOOTSTRAP COMPLETE                            ║
╠══════════════════════════════════════════════════════════════════════╣
║  Public webhook URL:                                                  ║
║    https://${DOMAIN}/webhook/smartlead
║                                                                       ║
║  Health check:        ${HEALTH}                                       ║
║  systemd service:     ${STATUS}                                       ║
║                                                                       ║
║  Next steps:                                                          ║
║    1. Edit ${ENV_FILE}
║       — paste SMARTLEAD_API_KEY, SMARTLEAD_CAMPAIGN_ID                ║
║       — fill SENDER_* / SMTP_* if you also want legacy mode           ║
║    2. systemctl restart outreach-webhook                              ║
║    3. As the outreach user, run on this box (or from your laptop):    ║
║         outreach campaign-init "RHD Q3 2026" \\                       ║
║           --webhook-url https://${DOMAIN}/webhook/smartlead \\        ║
║           --daily-limit 30                                            ║
║    4. Copy the printed campaign_id back into .env, then:              ║
║         outreach push --priority A --dry-run                          ║
║         outreach push --priority A                                    ║
║                                                                       ║
║  Logs:                                                                ║
║    journalctl -u outreach-webhook -f                                  ║
║    tail -f /var/log/nginx/access.log                                  ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
