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


# ── configure-categories.sh ──────────────────────────────────────────────────
# Configures exactly the categories in WP_CATEGORIES (.env).
# Strategy: rename Uncategorized to first category, create remaining ones,
# delete any others that don't match.
# Format: "Name 1:slug-1|Name 2:slug-2|Name 3:slug-3"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${WP_CATEGORIES:-}" ]]; then
  echo "Error: WP_CATEGORIES not set in .env"; exit 1
fi

echo "========================================================="
echo "  Configure Categories — ${SITE_SLUG:-$WP_SITE_URL}"
echo "  Site: $WP_SITE_URL"
echo "  Categories: $WP_CATEGORIES"
echo "========================================================="

_WP_BASE="${WP_SITE_URL%/}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 \
  -u "$WP_USER:$WP_PASS" "${_WP_BASE}/wp-json/wp/v2/users/me/")
[[ "$HTTP_CODE" == "200" ]] || { echo "Error: Auth failed (HTTP $HTTP_CODE)"; exit 1; }
echo "  ✓ Authenticated"

# Parse WP_CATEGORIES into arrays
CAT_NAMES=()
CAT_SLUGS=()
echo "$WP_CATEGORIES" | tr '|' '\n' | while IFS=: read -r n s; do
  echo "$n|$s"
done | {
  while IFS='|' read -r n s; do
    CAT_NAMES+=("$n")
    CAT_SLUGS+=("$s")
  done

  FIRST_NAME="${CAT_NAMES[1]}"
  FIRST_SLUG="${CAT_SLUGS[1]}"

  # ── Step 1: Rename Uncategorized (id=1) to first category via WP-CLI ─────────
  # REST API returns 500 for default category — must use WP-CLI
  echo ""
  echo "── Renaming Uncategorized → $FIRST_NAME ($FIRST_SLUG) ──────────────────────"
  _WP_KEY="${WP_SSH_KEY/#\~/$HOME}"
  SSH_OUT=$(ssh -i "$_WP_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp term update category 1 --name=\"$FIRST_NAME\" --slug=\"$FIRST_SLUG\" --path=\"${WP_PATH}\" 2>&1")
  echo "  $SSH_OUT"

  # ── Step 2: Delete any existing categories that aren't id=1 ────────────────
  echo ""
  echo "── Deleting other existing categories ──────────────────────────────────────"
  EXISTING=$(curl -s --connect-timeout 10 --max-time 30 \
    -u "$WP_USER:$WP_PASS" \
    "${_WP_BASE}/wp-json/wp/v2/categories/?per_page=100&hide_empty=false")
  echo "$EXISTING" | python3 -c "
import sys,json
for c in json.load(sys.stdin):
    if c['id'] != 1:
        print(str(c['id']) + '|' + c['name'])
" | while IFS='|' read -r cat_id cat_name; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      --connect-timeout 10 --max-time 30 \
      -u "$WP_USER:$WP_PASS" \
      "${_WP_BASE}/wp-json/wp/v2/categories/${cat_id}?force=true")
    echo "  Deleted: $cat_name (id=$cat_id, HTTP $HTTP)"
  done

  # ── Step 3: Create remaining categories ────────────────────────────────────
  echo ""
  echo "── Creating remaining categories ───────────────────────────────────────────"
  for i in {2..${#CAT_NAMES[@]}}; do
    n="${CAT_NAMES[$i]}"
    s="${CAT_SLUGS[$i]}"
    PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'name':sys.argv[1],'slug':sys.argv[2]}))" "$n" "$s")
    RESP=$(curl -s -w "\n%{http_code}" -X POST \
      --connect-timeout 10 --max-time 30 \
      -u "$WP_USER:$WP_PASS" -H "Content-Type: application/json" \
      -d "$PAYLOAD" "${_WP_BASE}/wp-json/wp/v2/categories")
    HTTP=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | head -1)
    CAT_ID=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','?'))" 2>/dev/null || echo "?")
    [[ "$HTTP" == "201" ]] && echo "  ✓ Created: $n ($s) → id=$CAT_ID" || echo "  ✗ Failed: $n ($s) HTTP $HTTP"
  done
}

echo ""
echo "── Verification ─────────────────────────────────────────────────────────────"
curl -s -u "$WP_USER:$WP_PASS" \
  "${_WP_BASE}/wp-json/wp/v2/categories/?per_page=20&hide_empty=false" | \
  python3 -c "
import sys,json
for c in sorted(json.load(sys.stdin), key=lambda x: x['id']):
    print('  id={:3}  slug={:<25}  name={}'.format(c['id'],c['slug'],c['name']))
"
echo ""
echo "✓ Done."
