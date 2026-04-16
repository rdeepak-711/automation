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


# ── configure-permalinks.sh ──────────────────────────────────────────────────
# Sets WordPress permalink structure to /%category%/%postname%/
# Flushes rewrite rules so the structure takes effect immediately.
#
# Usage:
#   ./scripts/base/configure-permalinks.sh
#
# Requires in .env: WP_SSH_HOST, WP_SSH_USER, WP_PATH
# ─────────────────────────────────────────────────────────────────────────────

# Validate required SSH vars
if [[ -z "${WP_SSH_HOST:-}" || -z "${WP_SSH_USER:-}" ]]; then
  echo "Error: WP_SSH_HOST and WP_SSH_USER must be set to configure permalinks via WP-CLI"
  exit 1
fi
if [[ -z "${WP_PATH:-}" ]]; then
  echo "Error: WP_PATH must be set to configure permalinks via WP-CLI"
  exit 1
fi

SSH_KEY_OPT=()
[[ -n "${WP_SSH_KEY:-}" ]] && SSH_KEY_OPT=(-i "$WP_SSH_KEY")
SSH_KEY_OPT+=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)

echo "Setting permalink structure..."
ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp option update permalink_structure '/%category%/%postname%/' --path='${WP_PATH}'"

echo "Flushing rewrite rules..."
ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp rewrite flush --path='${WP_PATH}'"

echo "Verifying permalink structure..."
ACTUAL=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp option get permalink_structure --path='${WP_PATH}'")

if [[ "$ACTUAL" == "/%category%/%postname%/" ]]; then
  echo "✓ Permalink structure confirmed: $ACTUAL"
else
  echo "✗ Permalink structure mismatch — expected '/%category%/%postname%/', got '$ACTUAL'"
  exit 1
fi
