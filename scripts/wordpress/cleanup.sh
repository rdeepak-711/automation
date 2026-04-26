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

# ── Plugin Cleanup (via REST API with proper URL-encoding) ──────────────────
PROTECTED_PLUGIN="bluehost-wordpress-plugin"

echo "Fetching plugin list..."
PLUGINS_JSON=$(curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/plugins") || PLUGINS_JSON="[]"

PLUGIN_SLUGS=$(printf '%s' "$PLUGINS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
protected = '$PROTECTED_PLUGIN'
for plugin in data:
    slug = plugin.get('plugin', '')
    if protected not in slug:
        print(slug)
" 2>/dev/null) || PLUGIN_SLUGS=""

echo "Deactivating and deleting plugins..."
while IFS= read -r slug; do
  [[ -z "$slug" ]] && continue

  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    -u "$WP_USER:$WP_PASS" -X POST \
    -H "Content-Type: application/json" \
    -d '{"status":"inactive"}' \
    "$WP_SITE_URL/wp-json/wp/v2/plugins/$slug") || HTTP="000"
  [[ "$HTTP" == "200" ]] && echo "  Deactivated: $slug" \
    || echo "  WARNING: deactivate $slug returned HTTP $HTTP" >&2

  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    -u "$WP_USER:$WP_PASS" -X DELETE \
    "$WP_SITE_URL/wp-json/wp/v2/plugins/$slug") || HTTP="000"
  [[ "$HTTP" == "200" ]] && echo "  Deleted: $slug" \
    || echo "  WARNING: delete $slug returned HTTP $HTTP" >&2

done <<< "$PLUGIN_SLUGS"
echo "Plugin cleanup complete."

echo "Verifying plugin cleanup..."
REMAINING=$(curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/plugins" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
protected = '$PROTECTED_PLUGIN'
for p in data:
    slug = p.get('plugin', '')
    if protected not in slug:
        print(slug)
" 2>/dev/null) || REMAINING=""

if [[ -n "$REMAINING" ]]; then
  echo "  The following plugins could not be auto-deleted (uninstall hook error):"
  while IFS= read -r s; do
    echo "    - $s  →  delete manually: WP Admin > Plugins"
  done <<< "$REMAINING"
else
  echo "  All non-protected plugins removed."
fi

echo "Checking Bluehost plugin version..."
BH_VERSION=$(curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/plugins" \
  | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    if 'bluehost' in p.get('plugin','').lower():
        print(p.get('version','unknown'))
        break
" 2>/dev/null) || BH_VERSION=""

if [[ -n "$BH_VERSION" ]]; then
  LATEST=$(curl -s --connect-timeout 10 --max-time 30 \
    "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&request[slug]=bluehost-wordpress-plugin" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null) || LATEST=""
  if [[ -n "$LATEST" && "$BH_VERSION" != "$LATEST" ]]; then
    echo "  UPDATE AVAILABLE: Bluehost plugin $BH_VERSION → $LATEST"
    echo "  Update via WP Admin > Dashboard > Updates"
  else
    echo "  Bluehost plugin is up to date ($BH_VERSION)."
  fi
fi
# ───────────────────────────────────────────────────────────────────────────

# ── Page & Post Cleanup (all statuses via REST API) ─────────────────────────
delete_post_type() {
  local TYPE="$1"
  local PAGE=1
  while true; do
    IDS=$(curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
      "$WP_SITE_URL/wp-json/wp/v2/${TYPE}?status=publish,draft,pending,private,future,auto-draft&per_page=100&page=${PAGE}&_fields=id" \
      | python3 -c "import json,sys; [print(x['id']) for x in json.load(sys.stdin)]" 2>/dev/null) || IDS=""
    [[ -z "$IDS" ]] && break
    COUNT=0
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 30 \
        -u "$WP_USER:$WP_PASS" -X DELETE \
        "$WP_SITE_URL/wp-json/wp/v2/${TYPE}/${id}?force=true") || HTTP="000"
      [[ "$HTTP" == "200" ]] && echo "  Deleted ${TYPE%s}: $id" \
        || echo "  WARNING: delete ${TYPE} $id returned HTTP $HTTP" >&2
      COUNT=$((COUNT+1))
    done <<< "$IDS"
    [[ "$COUNT" -lt 100 ]] && break
    PAGE=$((PAGE+1))
  done
}

# ── Safety check: abort if site has too much content (wrong WP_PATH?) ────────
echo "Counting existing content..."
_TMP_HDR=$(mktemp /tmp/wp-hdr-XXXXXX)
# Use index.php?rest_route= fallback — works on Bluehost regardless of permalink config
curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
  "${WP_SITE_URL%/}/index.php?rest_route=/wp/v2/pages/&status=publish,draft,pending,private,future&per_page=1&_fields=id" \
  -D "$_TMP_HDR" -o /dev/null 2>/dev/null
PAGE_COUNT=$(grep -i 'x-wp-total:' "$_TMP_HDR" | tr -d '\r' | sed 's/.*: *//' || true)
PAGE_COUNT="${PAGE_COUNT:-0}"

curl -s --connect-timeout 10 --max-time 30 -u "$WP_USER:$WP_PASS" \
  "${WP_SITE_URL%/}/index.php?rest_route=/wp/v2/posts/&status=publish,draft,pending,private,future&per_page=1&_fields=id" \
  -D "$_TMP_HDR" -o /dev/null 2>/dev/null
POST_COUNT=$(grep -i 'x-wp-total:' "$_TMP_HDR" | tr -d '\r' | sed 's/.*: *//' || true)
POST_COUNT="${POST_COUNT:-0}"
rm -f "$_TMP_HDR"

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

echo "Fetching pages..."
delete_post_type "pages"
echo "Page cleanup complete."

echo "Fetching posts..."
delete_post_type "posts"
echo "Post cleanup complete."
# ───────────────────────────────────────────────────────────────────────────
