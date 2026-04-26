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

# CLI args override .env values
SITE_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-slug) SITE_SLUG="$2"; shift 2 ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] && WP_SITE_URL="$1"
[[ $# -ge 2 ]] && WP_USER="$2"
[[ $# -ge 3 ]] && WP_PASS="$3"

# Auto-detect logo/favicon from input/<site-slug>/images/ if not set in .env
if [[ -n "$SITE_SLUG" ]]; then
  IMAGES_DIR="$SCRIPT_DIR/input/$SITE_SLUG/images"
  if [[ -z "${logo_path:-}" && -f "$IMAGES_DIR/logo.png" ]]; then
    logo_path="$IMAGES_DIR/logo.png"
    echo "  Auto-detected logo: $logo_path"
  fi
  if [[ -z "${favicon_path:-}" && -f "$IMAGES_DIR/favicon.png" ]]; then
    favicon_path="$IMAGES_DIR/favicon.png"
    echo "  Auto-detected favicon: $favicon_path"
  fi
fi

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
      echo "  WARNING: SSH connection failed — site identity settings will need manual configuration"
    fi
  fi
else
  echo "  SSH not configured (WP_SSH_HOST/WP_SSH_USER not set) — site identity settings will need manual configuration"
fi

# ── Helper: get MIME type from file extension ─────────────────────────────────
get_mime_type() {
  local EXT="${1##*.}"; EXT="${EXT:l}"
  case "$EXT" in
    jpg|jpeg) echo "image/jpeg" ;;
    png)      echo "image/png" ;;
    ico)      echo "image/x-icon" ;;
    svg)      echo "image/svg+xml" ;;
    webp)     echo "image/webp" ;;
    *)        echo "image/png" ;;
  esac
}

# ── Helper: upload media via REST API, returns attachment ID or 0 ─────────────
upload_media() {
  local FILE_PATH="$1"
  local FILENAME; FILENAME="$(basename "$FILE_PATH")"
  local MIME_TYPE; MIME_TYPE="$(get_mime_type "$FILE_PATH")"
  local RESPONSE
  RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 -u "$WP_USER:$WP_PASS" -X POST \
    -H "Content-Disposition: attachment; filename=${FILENAME}" \
    -H "Content-Type: ${MIME_TYPE}" \
    --data-binary @"${FILE_PATH}" \
    "$WP_SITE_URL/wp-json/wp/v2/media") || RESPONSE="{}"
  python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'id' in d: print(int(d['id']))
    else:
        msg = d.get('message', d.get('code', 'unknown error'))
        print(f'  Upload API error: {msg}', file=sys.stderr)
        print(0)
except (ValueError, KeyError, TypeError) as e:
    print(f'  Upload parse error: {e}', file=sys.stderr)
    print(0)
" <<< "$RESPONSE"
}

# ── Upload logo ───────────────────────────────────────────────────────────────
echo ""
echo "── Upload logo ─────────────────────────────────────────────────────────────"
LOGO_ID=0
if [[ -n "${logo_path:-}" ]]; then
  if [[ -f "$logo_path" ]]; then
    echo "  Uploading logo: $logo_path"
    LOGO_ID=$(upload_media "$logo_path")
    if [[ "$LOGO_ID" -gt 0 ]]; then
      echo "  Logo uploaded — attachment ID: $LOGO_ID"
    else
      echo "  WARNING: Logo upload failed (API returned ID 0)" >&2
    fi
  else
    echo "  WARNING: logo_path is set but file not found: $logo_path" >&2
  fi
else
  echo "  INFO: logo_path not set — skipping logo upload"
fi

# ── Upload favicon ────────────────────────────────────────────────────────────
echo ""
echo "── Upload favicon ──────────────────────────────────────────────────────────"
FAVICON_ID=0
if [[ -n "${favicon_path:-}" ]]; then
  if [[ -f "$favicon_path" ]]; then
    echo "  Uploading favicon: $favicon_path"
    FAVICON_ID=$(upload_media "$favicon_path")
    if [[ "$FAVICON_ID" -gt 0 ]]; then
      echo "  Favicon uploaded — attachment ID: $FAVICON_ID"
    else
      echo "  WARNING: Favicon upload failed (API returned ID 0)" >&2
    fi
  else
    echo "  WARNING: favicon_path is set but file not found: $favicon_path" >&2
  fi
else
  echo "  INFO: favicon_path not set — skipping favicon upload"
fi

# ── Integer coercion (injection safety) ──────────────────────────────────────
LOGO_ID_INT=$(( LOGO_ID + 0 ))
FAVICON_ID_INT=$(( FAVICON_ID + 0 ))
LOGO_WIDTH=$(( ${LOGO_WIDTH:-320} + 0 ))  # configurable via .env, default 320px

# ── Apply settings via WP-CLI over SSH ───────────────────────────────────────
echo ""
echo "── Apply site identity settings ────────────────────────────────────────────"
if $SSH_OK; then
  RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
    "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp eval '
      \$settings = (array) get_option(\"generate_settings\", []);

      if (!empty(\$settings[\"hide_title\"])) {
          echo \"hide_title already set -- skipped\n\";
      } else {
          \$settings[\"hide_title\"] = true;
          echo \"hide_title set to true\n\";
      }

      if (!empty(\$settings[\"hide_tagline\"])) {
          echo \"hide_tagline already set -- skipped\n\";
      } else {
          \$settings[\"hide_tagline\"] = true;
          echo \"hide_tagline set to true\n\";
      }

      \$logo_id = (int) ${LOGO_ID_INT};
      if (\$logo_id > 0) {
          set_theme_mod(\"custom_logo\", \$logo_id);
          echo \"custom_logo set to {\$logo_id}\n\";
          \$settings[\"logo_width\"] = ${LOGO_WIDTH};
          echo \"logo_width set to ${LOGO_WIDTH}\n\";
      }

      update_option(\"generate_settings\", \$settings);

      \$favicon_id = (int) ${FAVICON_ID_INT};
      if (\$favicon_id > 0) {
          update_option(\"site_icon\", \$favicon_id);
          echo \"site_icon set to {\$favicon_id}\n\";
      }

      echo \"Done\n\";
    ' --path='${WP_PATH}' 2>&1") || RESULT="failed"

  if [[ "$RESULT" == *"Done"* ]]; then
    echo "  $RESULT"
    echo ""
    echo "Verify in WP Admin:"
    echo "  → Appearance → Customize → Site Identity (title hidden, logo and favicon shown)"
    echo "  → Appearance → GP Premium → Layout (Logo Width should be 320)"
  else
    echo "  ERROR: wp eval returned unexpected output:"
    echo "  $RESULT"
    exit 1
  fi
else
  echo "  SSH not available — apply these settings manually in WP Admin:"
  echo ""
  echo "  1. Hide site title + tagline:"
  echo "     Appearance → Customize → Site Identity → uncheck 'Display Site Title and Tagline'"
  echo ""
  if [[ "$LOGO_ID_INT" -gt 0 ]]; then
    echo "  2. Set custom logo (attachment ID: $LOGO_ID_INT):"
    echo "     Appearance → Customize → Site Identity → Logo → select from Media Library"
    echo ""
    echo "  3. Set logo width to ${LOGO_WIDTH}px:"
    echo "     Appearance → GP Premium → Layout → Header → Logo Width → ${LOGO_WIDTH}"
    echo ""
  fi
  if [[ "$FAVICON_ID_INT" -gt 0 ]]; then
    echo "  4. Set site icon (attachment ID: $FAVICON_ID_INT):"
    echo "     Appearance → Customize → Site Identity → Site Icon → select from Media Library"
    echo ""
  fi
fi

echo ""
echo "Appearance customization complete."
