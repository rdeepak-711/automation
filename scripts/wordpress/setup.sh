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

# Pre-flight: verify credentials
echo "Verifying credentials..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 10 --max-time 30 \
  -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/users/me/")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: WordPress authentication failed (HTTP $HTTP_CODE)."
  echo "  - Check WP_SITE_URL, WP_USER, and WP_PASS in .env"
  echo "  - WP_PASS must be an Application Password (Users → Profile → Application Passwords)"
  echo "  - The authenticated user must have the Administrator role"
  echo "  - Application Passwords require HTTPS"
  exit 1
fi
echo "Credentials verified."

# ── SSH + WP-CLI pre-flight ───────────────────────────────────────────────────
SSH_OK=false
SSH_KEY_OPT=()
# Use parent's ControlMaster if available (main.sh exports SSH_CONTROL_PATH),
# otherwise create our own — avoids Bluehost fail2ban on rapid reconnections.
SSH_CTL="${SSH_CONTROL_PATH:-/tmp/wp-ssh-ctl-$$}"

if [[ -n "${WP_SSH_HOST:-}" && -n "${WP_SSH_USER:-}" ]]; then
  SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
               -o IdentitiesOnly=yes
               -o StrictHostKeyChecking=no
               -o ConnectTimeout=15
               -o ControlMaster=auto
               -o ControlPath="$SSH_CTL"
               -o ControlPersist=120)
  echo "Verifying SSH + WP-CLI..."

  # Auto-discover WP_PATH: strip protocol with zsh expansion (BSD sed-safe)
  if [[ -z "${WP_PATH:-}" ]]; then
    echo "  WP_PATH not set — searching for WordPress install matching $WP_SITE_URL ..."
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
      echo "  WARNING: Could not find a WordPress install matching $WP_SITE_URL"
      echo "  Set WP_PATH manually in .env to fix this"
    fi
  fi

  if [[ -n "${WP_PATH:-}" ]]; then
    SSH_TEST=$(ssh "${SSH_KEY_OPT[@]}" \
      "${WP_SSH_USER}@${WP_SSH_HOST}" "wp --version --path='${WP_PATH}' 2>&1") && SSH_OK=true || true
    if $SSH_OK; then
      echo "  SSH + WP-CLI verified: $SSH_TEST"
    else
      echo "  WARNING: SSH connection failed — zip plugins will need manual upload"
    fi
  fi
else
  echo "  SSH not configured (WP_SSH_HOST/WP_SSH_USER not set) — zip plugins will need manual upload"
fi

# ── Helper: install + activate a plugin from WordPress.org ───────────────────
install_from_wporg() {
  local SLUG="$1"
  local NAME="$2"

  # Skip if already active
  local CURRENT_STATUS
  CURRENT_STATUS=$(curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
    "$WP_SITE_URL/wp-json/wp/v2/plugins" | python3 -c "
import json, sys
try:
    for p in json.load(sys.stdin):
        if p.get('plugin','').startswith('$SLUG/'):
            print(p.get('status',''))
            break
except (ValueError, KeyError, TypeError): pass
" 2>/dev/null) || CURRENT_STATUS=""
  if [[ "$CURRENT_STATUS" == "active" ]]; then
    echo "  Already active, skipping: $NAME"
    return
  fi

  echo "Installing $NAME..."

  BODY=$(curl -s --connect-timeout 10 --max-time 60 -u "$WP_USER:$WP_PASS" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"slug\":\"$SLUG\",\"status\":\"active\"}" \
    "$WP_SITE_URL/wp-json/wp/v2/plugins") || BODY="{}"

  RESULT=$(printf '%s' "$BODY" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'code' in d:
        print('error: ' + d.get('message', 'unknown'))
    else:
        print(d.get('status', 'unknown'))
except (ValueError, KeyError, TypeError):
    print('parse_error')
" 2>/dev/null) || RESULT="unknown"

  if [[ "$RESULT" == "active" ]]; then
    echo "  Installed and activated: $NAME"
  else
    echo "  WARNING: $NAME — $RESULT" >&2
  fi
}

# ── Helper: install a zip plugin via SSH + WP-CLI ────────────────────────────
MANUAL_ZIPS=()

install_from_zip() {
  local ZIP_PATH="$1"
  local NAME="$2"
  local SLUG="${3:-}"
  local FILENAME
  FILENAME=$(basename "$ZIP_PATH")

  # Skip if already active (SSH check)
  if $SSH_OK && [[ -n "$SLUG" ]]; then
    if ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
        "wp plugin is-active '$SLUG' --path='${WP_PATH}' 2>/dev/null" 2>/dev/null; then
      echo "  Already active, skipping: $NAME"
      return
    fi
  fi

  if [[ ! -f "$ZIP_PATH" ]]; then
    echo "  SKIP: $NAME — zip not found: $ZIP_PATH"
    return
  fi

  if ! $SSH_OK; then
    MANUAL_ZIPS+=("$NAME|$ZIP_PATH")
    echo "  Queued for manual upload: $NAME"
    return
  fi

  echo "Installing $NAME via WP-CLI..."

  # Copy zip to remote temp dir (reuses multiplexed connection)
  scp "${SSH_KEY_OPT[@]}" \
    "$ZIP_PATH" "${WP_SSH_USER}@${WP_SSH_HOST}:/tmp/$FILENAME"

  # Install and activate (--force overwrites if already installed)
  RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp plugin install '/tmp/$FILENAME' --activate --force --path='${WP_PATH}' 2>&1") || RESULT="failed"

  echo "  $RESULT"

  # Cleanup remote zip
  ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" "rm -f '/tmp/$FILENAME'" || true
}

# ── Helper: find latest zip for a plugin prefix ──────────────────────────────
find_plugin_zip() {
  local prefix="$1"
  ls "$SCRIPT_DIR/plugins/${prefix}"*.zip 2>/dev/null | sort -V | tail -1
}

# ── WordPress.org plugins ─────────────────────────────────────────────────────
echo ""
echo "── WordPress.org plugins ──────────────────────────────────────────────────"
install_from_wporg "generateblocks" "GenerateBlocks"
install_from_wporg "megamenu"       "Max Mega Menu"
install_from_wporg "fluentform"     "Fluent Forms"

# ── Premium plugins from zip ──────────────────────────────────────────────────
echo ""
echo "── Premium plugins from zip ───────────────────────────────────────────────"
install_from_zip "$(find_plugin_zip "generateblocks-pro")"     "GenerateBlocks Pro" "generateblocks-pro"
install_from_zip "$(find_plugin_zip "gp-premium")"             "GP Premium"         "gp-premium"
install_from_zip "$(find_plugin_zip "wp-rocket")"              "WP Rocket"          "wp-rocket"
install_from_zip "$SCRIPT_DIR/plugins/seo-by-rank-math-pro.zip" "Rank Math Pro"    "seo-by-rank-math-pro"

# ── Post-install fixes ────────────────────────────────────────────────────────
# Rank Math Pro activates the free version as a dependency, which causes a PHP
# 8.4 fatal error (wp_rand undefined). Delete the free plugin directory.
if $SSH_OK; then
  ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "rm -rf '${WP_PATH}/wp-content/plugins/seo-by-rank-math' && echo '  Rank Math free removed'" 2>/dev/null || true
fi

# GP Premium 2.5.x has a PHP 8.4 incompatibility in class-conditions.php where
# serialized condition strings are passed directly to in_array(). Patch it.
if $SSH_OK; then
  ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
    FILE='${WP_PATH}/wp-content/plugins/gp-premium/elements/class-conditions.php'
    if [[ -f \"\$FILE\" ]] && ! grep -q 'maybe_unserialize' \"\$FILE\"; then
      sed -i 's/public static function show_data( \$conditionals, \$exclude, \$roles ) {/public static function show_data( \$conditionals, \$exclude, \$roles ) {\n\t\tif ( is_string( \$conditionals ) ) { \$conditionals = maybe_unserialize( \$conditionals ); }\n\t\tif ( is_string( \$exclude ) ) { \$exclude = maybe_unserialize( \$exclude ); }/' \"\$FILE\"
      echo '  GP Premium PHP 8.4 patch applied'
    else
      echo '  GP Premium already patched — skipping'
    fi
  " 2>/dev/null || true
fi

# ── Bluehost plugin update ────────────────────────────────────────────────────
echo ""
echo "── Bluehost plugin ────────────────────────────────────────────────────────"
if $SSH_OK; then
  BH_RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp plugin update bluehost-wordpress-plugin --path='${WP_PATH}' 2>&1") || BH_RESULT="failed"
  echo "  $BH_RESULT"
else
  echo "  SSH not configured — update Bluehost plugin manually via WP Admin → Dashboard → Updates"
fi

# ── GeneratePress theme ───────────────────────────────────────────────────────
echo ""
echo "── GeneratePress theme ────────────────────────────────────────────────────"

if $SSH_OK; then
  ACTIVE_THEME=$(ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp theme list --status=active --field=name --path='${WP_PATH}' 2>/dev/null") || ACTIVE_THEME=""
  if [[ "$ACTIVE_THEME" == "generatepress" ]]; then
    echo "  Already active, skipping: GeneratePress"
  else
    THEME_RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
      "${WP_SSH_USER}@${WP_SSH_HOST}" \
      "wp theme install generatepress --activate --force --path='${WP_PATH}' 2>&1") || THEME_RESULT="failed"
    echo "  $THEME_RESULT"
  fi
else
  echo "  SSH not configured — install and activate GeneratePress manually:"
  echo "  WP Admin → Appearance → Themes → Add New → search 'GeneratePress' → Install → Activate"
fi

if [[ ${#MANUAL_ZIPS[@]} -gt 0 ]]; then
  echo ""
  echo "── Manual plugin uploads required ─────────────────────────────────────────"
  echo "  SSH not configured. Upload these via:"
  echo "  WP Admin → Plugins → Add New → Upload Plugin"
  echo ""
  for item in "${MANUAL_ZIPS[@]}"; do
    echo "  [${item%%|*}]"
    echo "    ${item##*|}"
    echo ""
  done
fi

echo ""
echo "Setup complete."
