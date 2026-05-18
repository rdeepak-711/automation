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

# Load site-specific .env (overrides root — WP_SITE_URL lives here)
_SLUG="${SITE_SLUG:-${CONTENT_SITE_SLUG:-}}"
if [[ -n "$_SLUG" && -f "$SCRIPT_DIR/input/$_SLUG/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/input/$_SLUG/.env"
  set +a
fi

# Restore SSH vars — parent's active server takes precedence over .env
[[ -n "$_SAVED_SSH_HOST" ]] && WP_SSH_HOST="$_SAVED_SSH_HOST"
[[ -n "$_SAVED_SSH_USER" ]] && WP_SSH_USER="$_SAVED_SSH_USER"
[[ -n "$_SAVED_SSH_KEY" ]] && WP_SSH_KEY="$_SAVED_SSH_KEY"

# CLI args override .env values
[[ $# -ge 1 ]] && WP_SITE_URL="$1"
[[ $# -ge 2 ]] && WP_USER="$2"
[[ $# -ge 3 ]] && WP_PASS="$3"

# Validate
if [[ -z "${WP_SITE_URL:-}" || -z "${WP_USER:-}" || -z "${WP_PASS:-}" ]]; then
  echo "Error: Missing credentials."
  echo "  Option 1: Create .env with WP_SITE_URL, WP_USER, WP_PASS"
  echo "  Option 2: $0 <site-url> <username> <app-password>"
  exit 1
fi

# Pre-flight: verify credentials work before launching Claude
echo "Verifying credentials..."
_WP_BASE="${WP_SITE_URL%/}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 10 --max-time 30 \
  -u "$WP_USER:$WP_PASS" \
  "${_WP_BASE}/wp-json/wp/v2/users/me/")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: WordPress authentication failed (HTTP $HTTP_CODE)."
  echo "  - Check WP_SITE_URL, WP_USER, and WP_PASS in .env"
  echo "  - WP_PASS must be an Application Password (Users → Profile → Application Passwords)"
  echo "  - The authenticated user must have the Administrator role"
  echo "  - Application Passwords require HTTPS"
  exit 1
fi
echo "Credentials verified."

# ── Plugin Cleanup (WP-CLI via SSH — deactivate all then delete all) ─────────
PROTECTED_PLUGIN="bluehost-wordpress-plugin"

echo "Deactivating and deleting plugins via WP-CLI..."
_SSH_KEY_EXPANDED="${WP_SSH_KEY/#\~/$HOME}"
_SSH_CMD=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15)
[[ -n "${_SSH_KEY_EXPANDED:-}" ]] && _SSH_CMD+=(-i "$_SSH_KEY_EXPANDED" -o IdentitiesOnly=yes)

"${_SSH_CMD[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
  wp plugin deactivate --all --path='${WP_PATH}' 2>/dev/null || true
  wp plugin list --field=name --path='${WP_PATH}' 2>/dev/null \
    | grep -v '${PROTECTED_PLUGIN}' \
    | xargs -r wp plugin delete --path='${WP_PATH}' 2>/dev/null || true
" && echo "Plugin cleanup complete." || echo "  WARNING: WP-CLI plugin cleanup failed"

# ── Safety check: abort if site has too much content (wrong WP_PATH?) ────────
echo "Counting existing content..."
_COUNTS=$("${_SSH_CMD[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
  POST_COUNT=\$(wp post list --post_type=post --format=count --path='${WP_PATH}' 2>/dev/null || echo 0)
  PAGE_COUNT=\$(wp post list --post_type=page --format=count --path='${WP_PATH}' 2>/dev/null || echo 0)
  echo \"\$POST_COUNT \$PAGE_COUNT\"
" 2>/dev/null) || _COUNTS="0 0"
POST_COUNT=$(echo "$_COUNTS" | awk '{print $1}')
PAGE_COUNT=$(echo "$_COUNTS" | awk '{print $2}')
POST_COUNT=$(echo "$POST_COUNT" | tr -dc '0-9'); POST_COUNT="${POST_COUNT:-0}"
PAGE_COUNT=$(echo "$PAGE_COUNT" | tr -dc '0-9'); PAGE_COUNT="${PAGE_COUNT:-0}"
echo "  Found: ${POST_COUNT} posts, ${PAGE_COUNT} pages"

if [[ "${POST_COUNT}" -gt 5 || "${PAGE_COUNT}" -gt 1 ]]; then
  echo ""
  echo "  ⚠ WARNING: More than 5 posts or 1 page detected."
  echo "  WP_SITE_URL: $WP_SITE_URL"
  echo "  WP_PATH:     ${WP_PATH:-<not set>}"
  printf "  Continue and delete all content? (y/N) " > /dev/tty
  read -r _CONFIRM < /dev/tty
  if [[ "${_CONFIRM}" != "y" && "${_CONFIRM}" != "Y" ]]; then
    echo "  Aborted."
    exit 1
  fi
fi

# ── Page & Post Cleanup (WP-CLI via SSH) ─────────────────────────────────────
echo "Deleting pages and posts via WP-CLI..."
"${_SSH_CMD[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
  wp post list --post_type=post,page --format=ids --path='${WP_PATH}' 2>/dev/null \
    | xargs -r wp post delete --force --path='${WP_PATH}' 2>/dev/null || true
" && echo "Page and post cleanup complete." || echo "  WARNING: WP-CLI page/post cleanup failed"
# ───────────────────────────────────────────────────────────────────────────
