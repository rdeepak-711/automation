#!/usr/bin/env bash
set -euo pipefail

# Fix card "Learn more" links AND images on homepage + L1 pages.
# Matches each card by its <h3> title to find the correct WordPress post,
# then updates both the href and featured image. Works for wrong/invented slugs.
#
# Usage:
#   ./scripts/base/18-fix-card-links-and-images.sh <hostname>
#
# Example:
#   ./scripts/base/18-fix-card-links-and-images.sh vangoghmuseum-guide.com
#   ./scripts/base/18-fix-card-links-and-images.sh hagiasofia-guide.com
#
# Env vars (from .env or parent):
#   WP_SSH_HOST, WP_SSH_USER, WP_SSH_KEY, WP_PATH (optional — auto-discovered)

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

HOSTNAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/fix-card-links-and-images.py"

# Save any env vars passed on command line BEFORE loading .env (so they take precedence)
_SAVED_HOST="${WP_SSH_HOST:-}"
_SAVED_USER="${WP_SSH_USER:-}"
_SAVED_KEY="${WP_SSH_KEY:-}"
_SAVED_PATH="${WP_PATH:-}"

# Load .env if present
ENV_FILE="$SCRIPT_DIR/../../.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# Restore passed-in values — they take precedence over .env
[[ -n "$_SAVED_HOST" ]] && WP_SSH_HOST="$_SAVED_HOST"
[[ -n "$_SAVED_USER" ]] && WP_SSH_USER="$_SAVED_USER"
[[ -n "$_SAVED_KEY"  ]] && WP_SSH_KEY="$_SAVED_KEY"
[[ -n "$_SAVED_PATH" ]] && WP_PATH="$_SAVED_PATH"

# Build SSH key options
SSH_KEY_OPTS=()
if [[ -n "${WP_SSH_KEY:-}" ]]; then
    _KEY="${WP_SSH_KEY/#\~/$HOME}"
    SSH_KEY_OPTS=(-i "$_KEY" -o IdentitiesOnly=yes)
fi
SSH_KEY_OPTS+=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)

_SSH_PREFIX="SSH_AUTH_SOCK="  # always clear agent to prevent cPHulk/CSF port-22 blocks from wrong-key failures

_SSH() { env ${_SSH_PREFIX} ssh "${SSH_KEY_OPTS[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "$@"; }
_SCP() { env ${_SSH_PREFIX} scp "${SSH_KEY_OPTS[@]}" "$@"; }

# Discover WP_PATH if not already set
if [[ -z "${WP_PATH:-}" ]]; then
    echo "Discovering WP path for $HOSTNAME..."
    WP_PATH=$(_SSH \
        "for d in /home*/${WP_SSH_USER}/public_html/website_*/; do \
            wp option get siteurl --path=\"\$d\" 2>/dev/null | grep -q '$HOSTNAME' && echo \"\$d\" && break; \
         done; \
         wp option get siteurl --path=\"/home*/${WP_SSH_USER}/public_html/\" 2>/dev/null | grep -q '$HOSTNAME' && echo \"/home*/${WP_SSH_USER}/public_html/\" || true" \
        2>/dev/null | tr -d '\n' | sed 's|/$||')
fi

if [[ -z "$WP_PATH" ]]; then
    echo "❌ Could not find WordPress installation for $HOSTNAME"
    echo "   Set WP_PATH manually or ensure WP_SSH_HOST/USER/KEY are correct"
    exit 1
fi

echo "Found: $WP_PATH"

SITE_URL="https://$HOSTNAME"

echo "Uploading script..."
_SCP "$PY_SCRIPT" "${WP_SSH_USER}@${WP_SSH_HOST}:/tmp/18-fix-card-links-and-images.py"

echo "Running..."
_SSH "python3 /tmp/18-fix-card-links-and-images.py '$WP_PATH' '$SITE_URL'; rm -f /tmp/18-fix-card-links-and-images.py"

echo ""
echo "✅ Done for $HOSTNAME"
