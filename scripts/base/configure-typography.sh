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

# ── Phase 3: SSH multiplexed setup + WP_PATH auto-discovery ───────────────────
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

# ── Phase 4: Read configurable typography values from env (with defaults) ──────
FONT_NAME="${FONT_NAME:-Karla}"
# Sanitize: letters, numbers, spaces only (no shell/PHP injection)
FONT_NAME="${FONT_NAME//[^a-zA-Z0-9 ]/}"
FONT_SLUG="${FONT_NAME:l}"                # lowercase (zsh)
FONT_SLUG="${FONT_SLUG// /-}"             # spaces → hyphens
CSS_VARIABLE="--gp-font--${FONT_SLUG}"

# Build Google Fonts URL for this font (ital,wght axis order required by GF CSS2 API)
GF_FAMILY="${FONT_NAME// /+}"
GF_URL="https://fonts.googleapis.com/css2?family=${GF_FAMILY}:ital,wght@0,200;0,300;0,400;0,500;0,600;0,700;0,800;1,200;1,300;1,400;1,500;1,600;1,700;1,800\&display=auto"

BODY_FONT_SIZE=$(( ${BODY_FONT_SIZE:-18} + 0 ))
BODY_LINE_HEIGHT="${BODY_LINE_HEIGHT:-1.6}"
PARAGRAPH_MARGIN="${PARAGRAPH_MARGIN:-1.5}"
H1_FONT_SIZE=$(( ${H1_FONT_SIZE:-35} + 0 ))
H2_FONT_SIZE=$(( ${H2_FONT_SIZE:-32} + 0 ))
H3_FONT_SIZE=$(( ${H3_FONT_SIZE:-28} + 0 ))
H4_FONT_SIZE=$(( ${H4_FONT_SIZE:-24} + 0 ))

# ── Phase 5: GP Font Library ──────────────────────────────────────────────────
echo ""
echo "── Configuring GP Font Library: ${FONT_NAME} ───────────────────────────────"

PHP_TEMPLATE1="$SCRIPT_DIR/scripts/base/typography-font-library.php"
PHP_LOCAL="/tmp/gp_typography_$$.php"
PHP_REMOTE="/tmp/gp_typography_$$.php"

# Substitute placeholders into a temp copy (PHP file stays clean/static in repo)
sed \
  -e "s|{{FONT_NAME}}|${FONT_NAME}|g" \
  -e "s|{{FONT_SLUG}}|${FONT_SLUG}|g" \
  -e "s|{{CSS_VARIABLE}}|${CSS_VARIABLE}|g" \
  -e "s|{{GF_URL}}|${GF_URL}|g" \
  "$PHP_TEMPLATE1" > "$PHP_LOCAL"

# Transfer PHP file to remote server
echo "  Transferring script to server..."
scp -i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o ControlMaster=auto \
    -o ControlPath="$SSH_CTL" \
    "$PHP_LOCAL" "${WP_SSH_USER}@${WP_SSH_HOST}:${PHP_REMOTE}" 2>&1

# Execute and collect result
RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp eval-file '$PHP_REMOTE' --path='${WP_PATH}' 2>&1; rm -f '$PHP_REMOTE'") || RESULT="failed"

# Clean up local temp
rm -f "$PHP_LOCAL"

if [[ "$RESULT" == *"Done"* ]]; then
  echo "  $RESULT"
  echo ""
  echo "Verify in WP Admin → Appearance → Font Library:"
  echo "  Font: ${FONT_NAME}"
  echo "  Source: Google Fonts API"
  echo "  Category: sans-serif"
  echo "  Display: auto"
  echo "  Variants: 14 (200–800 normal + italic)"
  echo "  CSS variable: ${CSS_VARIABLE}"
else
  echo "  ERROR: script returned unexpected output:"
  echo "  $RESULT"
  exit 1
fi

# ── Phase 6: GP Typography Manager — Desktop ──────────────────────────────────
echo ""
echo "── Configuring GP Typography Manager: Desktop ──────────────────────────────"

PHP_TEMPLATE2="$SCRIPT_DIR/scripts/base/typography-manager.php"
PHP_LOCAL2="/tmp/gp_typo_manager_$$.php"
PHP_REMOTE2="/tmp/gp_typo_manager_$$.php"

# Substitute placeholders
sed \
  -e "s|{{FONT_NAME}}|${FONT_NAME}|g" \
  -e "s|{{BODY_FONT_SIZE}}|${BODY_FONT_SIZE}|g" \
  -e "s|{{BODY_LINE_HEIGHT}}|${BODY_LINE_HEIGHT}|g" \
  -e "s|{{PARAGRAPH_MARGIN}}|${PARAGRAPH_MARGIN}|g" \
  -e "s|{{H1_FONT_SIZE}}|${H1_FONT_SIZE}|g" \
  -e "s|{{H2_FONT_SIZE}}|${H2_FONT_SIZE}|g" \
  -e "s|{{H3_FONT_SIZE}}|${H3_FONT_SIZE}|g" \
  -e "s|{{H4_FONT_SIZE}}|${H4_FONT_SIZE}|g" \
  "$PHP_TEMPLATE2" > "$PHP_LOCAL2"

# Transfer PHP file to remote server
echo "  Transferring script to server..."
scp -i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o ControlMaster=auto \
    -o ControlPath="$SSH_CTL" \
    "$PHP_LOCAL2" "${WP_SSH_USER}@${WP_SSH_HOST}:${PHP_REMOTE2}" 2>&1

# Execute and collect result
RESULT2=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp eval-file '$PHP_REMOTE2' --path='${WP_PATH}' 2>&1; rm -f '$PHP_REMOTE2'") || RESULT2="failed"

# Clean up local temp
rm -f "$PHP_LOCAL2"

if [[ "$RESULT2" == *"Done"* ]]; then
  echo "  $RESULT2"
  echo ""
  echo "Verify in WP Admin → Appearance → GP Premium → Typography Manager:"
  echo "  Body:  ${BODY_FONT_SIZE}px / ${BODY_LINE_HEIGHT}em / 0px letter-spacing / ${PARAGRAPH_MARGIN}em paragraph margin"
  echo "  H1:    ${H1_FONT_SIZE}px / 1.2em / 20px bottom margin — weight: bold"
  echo "  H2:    ${H2_FONT_SIZE}px / 1.2em / 20px bottom margin — weight: bold"
  echo "  H3:    ${H3_FONT_SIZE}px / 1.2em / 20px bottom margin — weight: bold / style: oblique"
  echo "  H4:    ${H4_FONT_SIZE}px / 1.2em / 20px bottom margin — weight: bold"
else
  echo "  ERROR: script returned unexpected output:"
  echo "  $RESULT2"
  exit 1
fi

echo ""
echo "Typography configuration complete."
