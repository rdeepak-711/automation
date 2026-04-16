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


SITE_SLUG_ARG=""
_POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-slug) SITE_SLUG_ARG="$2"; shift 2 ;;
    *) _POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${_POSITIONAL[@]}"

[[ $# -ge 1 ]] && WP_SITE_URL="$1"
[[ $# -ge 2 ]] && WP_USER="$2"
[[ $# -ge 3 ]] && WP_PASS="$3"

# Validate required credentials
if [[ -z "${WP_SITE_URL:-}" || -z "${WP_USER:-}" || -z "${WP_PASS:-}" ]]; then
  echo "Error: Missing credentials."
  echo "  Option 1: Create .env with WP_SITE_URL, WP_USER, WP_PASS"
  echo "  Option 2: $0 <site-url> <username> <app-password>"
  exit 1
fi

if [[ -z "${GA4_MEASUREMENT_ID:-}" ]]; then
  echo "ERROR: GA4_MEASUREMENT_ID not set in .env"
  echo "  Add GA4_MEASUREMENT_ID=G-XXXXXXXXXX to your .env file"
  exit 1
fi

# ── Phase 2: curl pre-flight ──────────────────────────────────────────────────
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

# ── Phase 3: Resolve active SSH server (try new server first, fall back to old) ──
SSH_OK=false
SSH_CTL="${SSH_CONTROL_PATH:-/tmp/wp-ssh-ctl-$$}"
WP_SSH_HOST_ACTIVE=""
WP_SSH_USER_ACTIVE=""
WP_SSH_KEY_ACTIVE=""

_try_ssh() {
  local host="$1" user="$2" key="$3"
  [[ -z "$host" || -z "$user" || -z "$key" ]] && return 1
  local keyfile="${key/#\~/$HOME}"
  [[ ! -f "$keyfile" ]] && return 1
  ssh -i "$keyfile" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 "$user@$host" "wp --version --path='${WP_PATH}' 2>/dev/null" &>/dev/null
}

WP_SSH_HOST_ACTIVE="${WP_SSH_HOST}"
WP_SSH_USER_ACTIVE="${WP_SSH_USER}"
WP_SSH_KEY_ACTIVE="${WP_SSH_KEY/#\~/$HOME}"

echo "Verifying SSH + WP-CLI (${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE})..."
if ! _try_ssh "$WP_SSH_HOST_ACTIVE" "$WP_SSH_USER_ACTIVE" "$WP_SSH_KEY_ACTIVE"; then
  echo "ERROR: Cannot connect to ${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}"
  echo "  Check WP_SSH_HOST/USER/KEY in .env"
  exit 1
fi
echo "  ✓ SSH verified"

SSH_KEY_OPT=(-i "$WP_SSH_KEY_ACTIVE"
             -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
             -o ConnectTimeout=15
             -o ControlMaster=auto
             -o ControlPath="$SSH_CTL"
             -o ControlPersist=120)
SSH_OK=true

echo ""
echo "── Importing GeneratePress Elements ───────────────────────────────────────"

# ── Phase 6: Idempotency check ────────────────────────────────────────────────
echo "Checking for existing GP Elements..."
EXISTING=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}" \
  "wp post list --post_type=gp_elements --name=google-analytics \
   --fields=post_name --path='${WP_PATH}' --format=count 2>&1") || EXISTING="0"

if [[ "$EXISTING" -ge 1 ]]; then
  echo "GP Elements already imported — skipping."
  exit 0
fi

# ── Phase 7: GA4 substitution + transfer ─────────────────────────────────────
if [[ -n "${GP_ELEMENTS_XML:-}" ]]; then
  if [[ "$GP_ELEMENTS_XML" = /* ]]; then
    XML_SRC="$GP_ELEMENTS_XML"
  else
    XML_SRC="$SCRIPT_DIR/$GP_ELEMENTS_XML"
  fi
else
  XML_SRC="$SCRIPT_DIR/input/gp-elements.xml"
fi
XML_TMP="/tmp/gp_elements_import_$$.xml"
XML_REMOTE="/tmp/gp_elements_import_$$.xml"

if [[ ! -f "$XML_SRC" ]]; then
  echo "ERROR: XML source file not found: $XML_SRC"
  exit 1
fi

echo "Substituting GA4 measurement ID (${GA4_MEASUREMENT_ID})..."
sed "s/G-FWFXHB13EK/${GA4_MEASUREMENT_ID}/g" "$XML_SRC" > "$XML_TMP"

echo "Transferring XML to server..."
scp "${SSH_KEY_OPT[@]}" "$XML_TMP" "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}:${XML_REMOTE}"
rm -f "$XML_TMP"

# ── Phase 8: Ensure importer active, run import, cleanup ─────────────────────
echo "Running wp import..."
ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}" "
  # Activate importer plugin (installs if needed, no-op if already active)
  wp plugin install wordpress-importer --activate --path='${WP_PATH}' 2>&1

  # Run import — skip author creation (authors not needed for gp_elements)
  wp import '${XML_REMOTE}' --authors=skip --path='${WP_PATH}' 2>&1

  # Clean up remote XML
  rm -f '${XML_REMOTE}'
"

# ── Phase 9: Create Menu GP element from per-site menu.txt ───────────────────
MENU_TXT="$SCRIPT_DIR/input/${SITE_SLUG_ARG}/menu.txt"

if [[ -f "$MENU_TXT" ]]; then
  echo ""
  echo "── Creating Menu GP Element from $MENU_TXT ────────────────────────────────"

  # Check if menu element already exists
  MENU_EXISTS=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}" \
    "wp post list --post_type=gp_elements --name=menu \
     --fields=post_name --path='${WP_PATH}' --format=count 2>&1") || MENU_EXISTS="0"

  if [[ "$MENU_EXISTS" -ge 1 ]]; then
    echo "  Menu element already exists — skipping."
  else
    # SCP the menu HTML to the server (preserves exact bytes, no newline corruption)
    MENU_REMOTE="/tmp/menu_content_$$.html"
    scp "${SSH_KEY_OPT[@]}" "$MENU_TXT" \
      "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}:${MENU_REMOTE}"

    # Deploy via PHP eval-file — no shell variable expansion of HTML content
    _MENU_PHP=$(mktemp /tmp/menu_php_XXXXXX)
    cat > "$_MENU_PHP" << PHPEOF
<?php
\$content = file_get_contents('${MENU_REMOTE}');
if (!\$content) { echo "ERROR: could not read menu file\n"; exit(1); }
\$existing = get_posts(['post_type'=>'gp_elements','name'=>'menu','post_status'=>'any','numberposts'=>1]);
if (\$existing) {
    \$id = \$existing[0]->ID;
    update_post_meta(\$id, '_generate_element_content', \$content);
    echo "Updated Menu element (ID: \$id)\n";
} else {
    \$id = wp_insert_post(['post_type'=>'gp_elements','post_title'=>'Menu','post_name'=>'menu','post_status'=>'publish']);
    update_post_meta(\$id, '_generate_element_type',              'hook');
    update_post_meta(\$id, '_generate_hook',                      'generate_before_header');
    update_post_meta(\$id, '_generate_hook_priority',             10);
    update_post_meta(\$id, '_generate_element_display_conditions', [['rule'=>'general:site','object'=>'0']]);
    update_post_meta(\$id, '_generate_element_content',           \$content);
    echo "Created Menu element (ID: \$id)\n";
}
unlink('${MENU_REMOTE}');
PHPEOF
    _MENU_PHP_REMOTE="/tmp/menu_php_$$.php"
    scp "${SSH_KEY_OPT[@]}" "$_MENU_PHP" \
      "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}:${_MENU_PHP_REMOTE}"
    rm -f "$_MENU_PHP"
    ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}" \
      "wp eval-file '${_MENU_PHP_REMOTE}' --path='${WP_PATH}' 2>&1; rm -f '${_MENU_PHP_REMOTE}'"
  fi
else
  echo ""
  echo "  NOTE: No menu.txt found at $MENU_TXT — skipping Menu element creation."
  echo "  To create a Menu element, add input/<site-slug>/menu.txt"
fi

# ── Phase 10: Verify all 5 slugs are present ─────────────────────────────────
echo ""
echo "── Verification ───────────────────────────────────────────────────────────"
RESULT=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER_ACTIVE}@${WP_SSH_HOST_ACTIVE}" \
  "wp post list --post_type=gp_elements \
   --fields=post_name,post_status --path='${WP_PATH}' --format=table 2>&1")
echo "$RESULT"

FAILED=false
for slug in author-profile contained-width-for-all-post google-analytics stay22; do
  if [[ "$RESULT" != *"$slug"* ]]; then
    echo "ERROR: Element '$slug' not found after import"
    FAILED=true
  fi
done

# Check menu separately (only warn if menu.txt was provided)
if [[ -f "$MENU_TXT" && "$RESULT" != *"menu"* ]]; then
  echo "ERROR: Element 'menu' not found after creation"
  FAILED=true
fi

if $FAILED; then
  exit 1
fi

echo ""
if [[ -f "$MENU_TXT" ]]; then
  echo "All 5 GP Elements imported/created successfully."
else
  echo "All 4 base GP Elements imported successfully."
fi
