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


[[ $# -ge 1 ]] && WP_SITE_URL="$1"
[[ $# -ge 2 ]] && WP_USER="$2"
[[ $# -ge 3 ]] && WP_PASS="$3"

if [[ -z "${WP_SITE_URL:-}" || -z "${WP_USER:-}" || -z "${WP_PASS:-}" ]]; then
  echo "Error: Missing credentials."
  echo "  Option 1: Create .env with WP_SITE_URL, WP_USER, WP_PASS"
  echo "  Option 2: $0 <site-url> <username> <app-password>"
  exit 1
fi

# ── Phase 2: curl pre-flight ──────────────────────────────────────────────────
_WP_BASE="${WP_SITE_URL%/}"
echo "Verifying credentials..."
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

# ── Phase 3 (early): Sanitize color value before it's used in any echo/SSH ────
BODY_BG_COLOR="${BODY_BG_COLOR:-ffffff}"
BODY_BG_COLOR="${BODY_BG_COLOR#\#}"
BODY_BG_COLOR="${BODY_BG_COLOR//[^0-9a-fA-F]/}"
[[ ${#BODY_BG_COLOR} -eq 6 ]] || BODY_BG_COLOR="ffffff"

# ── SSH multiplexed setup + WP_PATH auto-discovery ───────────────────────────
SSH_OK=false
SSH_KEY_OPT=()
SSH_CTL="${SSH_CONTROL_PATH:-/tmp/wp-ssh-ctl-$$}"

if [[ -n "${WP_SSH_HOST:-}" && -n "${WP_SSH_USER:-}" ]]; then
  SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
               -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
               -o ConnectTimeout=15
               -o ControlMaster=auto
               -o ControlPath="$SSH_CTL"
               -o ControlPersist=120)
  echo "Verifying SSH + WP-CLI..."

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
    WP_PATH="${WP_PATH%/}"
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
      echo "  ERROR: SSH connection or WP-CLI failed."
      echo "  This script requires WP-CLI access — no REST fallback available."
      exit 1
    fi
  else
    echo "  ERROR: WP_PATH could not be determined — cannot proceed without SSH + WP-CLI."
    exit 1
  fi
else
  echo "  ERROR: WP_SSH_HOST / WP_SSH_USER not set in .env — cannot proceed without SSH + WP-CLI."
  echo ""
  echo "  Apply these settings manually in WP Admin:"
  echo ""
  echo "  Appearance → Customize → Colors → Body"
  echo "    Background Color: #${BODY_BG_COLOR}"
  exit 1
fi

# ── Phase 4: Single WP-CLI SSH wp eval round-trip ────────────────────────────
echo ""
echo "── Applying GeneratePress color settings ───────────────────────────────────"

RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp eval '
    // 1. Body background — use var(--base-3) if GP global color exists, else white
    \$gp_colors = get_option(\"generate_settings\", []);
    \$global_colors = \$gp_colors[\"global_colors\"] ?? [];
    \$base3_hex = \"\";
    if (is_array(\$global_colors)) {
      foreach (\$global_colors as \$c) {
        if (isset(\$c[\"slug\"]) && \$c[\"slug\"] === \"base-3\" && !empty(\$c[\"color\"])) {
          \$base3_hex = ltrim(\$c[\"color\"], \"#\");
          break;
        }
      }
    }
    \$bg = \$base3_hex ?: \"${BODY_BG_COLOR}\";
    //    GP 3.x: stored as WordPress theme mod (hex without #)
    //    GP 2.x: also stored in generate_settings[background_color] (hex with #)
    set_theme_mod(\"background_color\", \$bg);
    echo \"body background_color theme mod → \" . \$bg . \" (\" . (\$base3_hex ? \"from var(--base-3)\" : \"fallback white\") . \")\n\";

    \$gs = (array) get_option(\"generate_settings\", []);
    \$gs[\"background_color\"] = \"#\" . \$bg;
    update_option(\"generate_settings\", \$gs);
    echo \"generate_settings[background_color] → #\" . \$bg . \"\n\";

    // Verify readback
    \$mod = get_theme_mod(\"background_color\", \"NOT SET\");
    \$opt = get_option(\"generate_settings\", [])[\"background_color\"] ?? \"NOT SET\";
    echo \"Readback: theme_mod=\" . \$mod . \" | generate_settings=\" . \$opt . \"\n\";

    echo \"Done\n\";
  ' --path='${WP_PATH}' 2>&1") || RESULT="failed"

if [[ "$RESULT" == *"Done"* ]]; then
  echo "  $RESULT"
  echo ""
  echo "Verify in WP Admin → Appearance → Customize → Colors → Body:"
  echo "  Background Color: #${BODY_BG_COLOR}"
else
  echo "  ERROR: wp eval returned unexpected output:"
  echo "  $RESULT"
  exit 1
fi

echo ""
echo "Color configuration complete."
