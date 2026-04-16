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
# Load site-specific .env (overrides root — WP_SITE_URL, WP_USER, WP_PASS live here)
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

# Validate required vars
if [[ -z "${GeneratePress_license_key:-}" ]]; then
  echo "Error: GeneratePress_license_key is not set in .env"
  exit 1
fi

if [[ -z "${WP_SSH_HOST:-}" || -z "${WP_SSH_USER:-}" ]]; then
  echo "Error: WP_SSH_HOST and WP_SSH_USER must be set in .env"
  exit 1
fi

if [[ -z "${WP_SITE_URL:-}" ]]; then
  echo "Error: WP_SITE_URL must be set in .env"
  exit 1
fi

# ── SSH multiplexed connection ────────────────────────────────────────────────
SSH_CTL="${SSH_CONTROL_PATH:-/tmp/wp-ssh-ctl-$$}"
SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
             -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
             -o ConnectTimeout=15
             -o ControlMaster=auto
             -o ControlPath="$SSH_CTL"
             -o ControlPersist=120)

# ── Auto-discover WP_PATH ─────────────────────────────────────────────────────
if [[ -z "${WP_PATH:-}" ]]; then
  echo "WP_PATH not set — searching for WordPress install matching $WP_SITE_URL ..."
  SITE_HOST="${WP_SITE_URL#https://}"
  SITE_HOST="${SITE_HOST#http://}"
  SITE_HOST="${SITE_HOST%%/*}"
  SEARCH_ROOT="/home1/${WP_SSH_USER}/public_html"
  WP_PATH=$(ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" "
      for d in ${SEARCH_ROOT}/website_*/; do
        url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || continue
        if [[ \"\$url\" == *\"${SITE_HOST}\"* ]]; then
          echo \"\$d\"
          break
        fi
      done
    " 2>/dev/null) || WP_PATH=""
  WP_PATH="${WP_PATH%/}"  # strip trailing slash
  if [[ -n "$WP_PATH" ]]; then
    echo "  Found WordPress at: $WP_PATH"
  else
    echo "Error: Could not find a WordPress install matching $WP_SITE_URL"
    echo "  Set WP_PATH manually in .env to fix this"
    exit 1
  fi
fi

# ── Activate license + modules ────────────────────────────────────────────────
echo "Activating GP Premium license and modules..."

LICENSE_KEY="${GeneratePress_license_key}"

# Store license key + status via wp option update (safe — value is not interpolated into PHP code)
SSH_RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp option update gen_premium_license_key '${LICENSE_KEY}' --path='${WP_PATH}' 2>&1 \
   && wp option update gen_premium_license_key_status valid --path='${WP_PATH}' 2>&1 \
   && echo 'License stored'") || SSH_RESULT="failed"

if [[ "$SSH_RESULT" != *"License stored"* ]]; then
  echo "  ERROR: Failed to store license key:"
  echo "  $SSH_RESULT"
  exit 1
fi
echo "  License key stored."

# Activate 7 modules — no user input in this block, safe to use wp eval
MODULES_RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp eval '
    foreach ([\"blog\",\"copyright\",\"disable_elements\",\"elements\",\"menu_plus\",\"secondary_nav\",\"spacing\"] as \$m) {
      update_option(\"generate_package_\" . \$m, \"activated\");
    }
    echo \"Done\n\";
  ' --path='${WP_PATH}' 2>&1") || MODULES_RESULT="failed"

if [[ "$MODULES_RESULT" == *"Done"* ]]; then
  echo "  7 modules activated."
  echo ""
  echo "Verify in WP Admin:"
  echo "  → Appearance → GP Premium → License (should show key as valid)"
  echo "  → Appearance → GP Premium → Modules (7 modules should be active)"
else
  echo "  ERROR: Module activation returned unexpected output:"
  echo "  $MODULES_RESULT"
  exit 1
fi
