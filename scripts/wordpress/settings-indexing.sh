#!/usr/bin/env zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# Preserve SSH vars set by parent (active server selection from main.sh)
_SAVED_SSH_HOST="${WP_SSH_HOST:-}"
_SAVED_SSH_USER="${WP_SSH_USER:-}"
_SAVED_SSH_KEY="${WP_SSH_KEY:-}"

# Load root .env if present
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
# Load site-specific .env (overrides root — WP_SITE_URL, WP_USER, WP_PASS, WP_PATH live here)
_SLUG="${CONTENT_SITE_SLUG:-${SITE_SLUG:-}}"
if [[ -n "$_SLUG" && -f "$SCRIPT_DIR/input/$_SLUG/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/input/$_SLUG/.env"
  set +a
fi

# Restore SSH vars — parent's active server takes precedence over .env
[[ -n "$_SAVED_SSH_HOST" ]] && WP_SSH_HOST="$_SAVED_SSH_HOST"
[[ -n "$_SAVED_SSH_USER" ]] && WP_SSH_USER="$_SAVED_SSH_USER"
[[ -n "$_SAVED_SSH_KEY" ]] && WP_SSH_KEY="$_SAVED_SSH_KEY"


# ── Phase 2: curl pre-flight ──────────────────────────────────────────────────
echo "Verifying credentials..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 10 --max-time 30 \
  -u "$WP_USER:$WP_PASS" "$WP_SITE_URL/wp-json/wp/v2/users/me/")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: WordPress authentication failed (HTTP $HTTP_CODE)."
  exit 1
fi
echo "Credentials verified."

# ── SSH multiplexed setup + WP_PATH auto-discovery ───────────────────────────
SSH_CTL="${SSH_CONTROL_PATH:-/tmp/wp-ssh-ctl-$$}"
if [[ -z "${WP_SSH_HOST:-}" || -z "${WP_SSH_USER:-}" ]]; then
  echo "ERROR: WP_SSH_HOST / WP_SSH_USER not set in .env"; exit 1
fi
SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
             -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
             -o ConnectTimeout=15
             -o ControlMaster=auto
             -o ControlPath="$SSH_CTL"
             -o ControlPersist=120)
echo "Verifying SSH + WP-CLI..."

if [[ -z "${WP_PATH:-}" ]]; then
  SITE_HOST="${WP_SITE_URL#https://}"; SITE_HOST="${SITE_HOST#http://}"; SITE_HOST="${SITE_HOST%%/*}"
  SEARCH_ROOT="/home1/${WP_SSH_USER}/public_html"
  WP_PATH=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
    for d in ${SEARCH_ROOT}/website_*/; do
      url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || continue
      if [[ \"\$url\" == *\"${SITE_HOST}\"* ]]; then echo \"\$d\"; break; fi
    done" 2>/dev/null) || WP_PATH=""
  WP_PATH="${WP_PATH%/}"
  [[ -n "$WP_PATH" ]] && echo "  Found WordPress at: $WP_PATH" || { echo "  ERROR: Could not find WordPress install"; exit 1; }
fi

SSH_TEST=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" "wp --version --path='${WP_PATH}' 2>&1") && SSH_OK=true || SSH_OK=false
$SSH_OK && echo "  SSH + WP-CLI verified: $SSH_TEST" || { echo "  ERROR: SSH/WP-CLI failed"; exit 1; }

# ── Phase 3: Check and set blog_public ────────────────────────────────────────
echo ""
echo "── Configuring Search Engine Indexing ──────────────────────────────────────"

CURRENT=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp option get blog_public --path='${WP_PATH}' 2>&1")

if [[ "$CURRENT" == "0" ]]; then
  echo "  Already set: search engines discouraged (blog_public=0) — no change needed."
else
  ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp option update blog_public 0 --path='${WP_PATH}' 2>&1"
  echo "  blog_public set to 0 — search engines discouraged."
fi

echo ""
echo "Verify in WP Admin → Settings → Reading:"
echo "  'Discourage search engines from indexing this site' should be checked."
