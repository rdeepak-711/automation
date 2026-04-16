#!/usr/bin/env zsh
set -euo pipefail

# ── retry-failed.sh ──────────────────────────────────────────────────────────
# Retries publishing specific failed articles for a site.
# Reuses the same env, auth, and meta logic as publish-to-wordpress.sh.
#
# Usage:
#   ./scripts/content/retry-failed.sh <site-slug>
#
# The failed slugs are hardcoded below — edit as needed per run.
# ─────────────────────────────────────────────────────────────────────────────

SITE_SLUG="${1:-angkor-wat}"

# ── Failed items to retry ────────────────────────────────────────────────────
# Format: silo/slug
FAILED_POSTS=(
  "plan-your-visit/small-circuit-vs-grand-circuit"
  "tickets-tours/angkor-pass"
  "what-to-see/angkor-wat-sunrise"
  "what-to-see/angkor-wat-towers"
)
RETRY_HOMEPAGE=true
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load env
[[ -f "$REPO_ROOT/.env" ]] && { set -a; source "$REPO_ROOT/.env"; set +a; }
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

# Server selection
if [[ "${WP_SERVER:-}" == "2" ]]; then
  export WP_SSH_HOST="${WP_SSH_HOST2:-$WP_SSH_HOST}"
  export WP_SSH_USER="${WP_SSH_USER2:-$WP_SSH_USER}"
  export WP_SSH_KEY="${WP_SSH_KEY2:-$WP_SSH_KEY}"
fi

[[ -n "${WP_SITE_URL:-}" ]] || { echo "Error: WP_SITE_URL not set"; exit 1; }
[[ -n "${WP_USER:-}"     ]] || { echo "Error: WP_USER not set"; exit 1; }
[[ -n "${WP_PASS:-}"     ]] || { echo "Error: WP_PASS not set"; exit 1; }

OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG"
ARTICLES_DIR="$OUTPUT_DIR/l2-articles"
HOMEPAGE_FILE="$OUTPUT_DIR/homepage.html"
WP_POSTS_API="${WP_SITE_URL%/}/wp-json/wp/v2/posts"
WP_PAGES_API="${WP_SITE_URL%/}/wp-json/wp/v2/pages"
POST_STATUS="draft"
DELAY=3  # seconds between requests to avoid rate limiting

# Category slug map from url-registry.json
declare -A CAT_SLUG_MAP=(
  [tickets-tours]="tickets"
  [tickets-and-tours]="tickets"
  [plan-your-visit]="plan-your-visit"
  [what-to-see]="what-to-see"
)
URL_REGISTRY="$OUTPUT_DIR/url-registry.json"
if [[ -f "$URL_REGISTRY" ]]; then
  _map_json=$(python3 - "$URL_REGISTRY" << 'PYEOF'
import json, sys
try:
    reg = json.load(open(sys.argv[1]))
    cats = reg.get("categories", {})
    for cat_slug, info in cats.items():
        dir_name = info.get("dir_name", cat_slug) if isinstance(info, dict) else cat_slug
        if dir_name and cat_slug:
            print(f"{dir_name}={cat_slug}")
except Exception:
    pass
PYEOF
  ) || _map_json=""
  while IFS='=' read -r _dir _slug; do
    _dir="${_dir//\"/}"
    _slug="${_slug//\"/}"
    [[ -n "$_dir" && -n "$_slug" ]] && CAT_SLUG_MAP[$_dir]="$_slug"
  done <<< "$_map_json"
fi

# SSH setup for WP-CLI meta calls
SSH_OK=false
SSH_KEY_OPT=()
SSH_CTL=""
if [[ -n "${WP_SSH_HOST:-}" && -n "${WP_SSH_USER:-}" && -n "${WP_PATH:-}" ]]; then
  SSH_CTL="/tmp/wp-ssh-retry-$$"
  SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
               -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
               -o ConnectTimeout=15
               -o ControlMaster=auto
               -o ControlPath="$SSH_CTL"
               -o ControlPersist=120)
  ssh "${SSH_KEY_OPT[@]}" -N -f "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null && SSH_OK=true || true
  trap '[[ -n "$SSH_CTL" ]] && ssh -O exit -o ControlPath="$SSH_CTL" "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null; true' EXIT
fi

# Parse SEO comment from HTML
parse_seo_comment() {
  local html_file="$1"
  local _result
  _result=$(python3 - "$html_file" << 'PYEOF'
import re, sys, json, html as html_lib
content = open(sys.argv[1]).read()
m = re.search(r'<!--\s*SEO([\s\S]*?)-->', content, re.IGNORECASE)
block = m.group(1) if m else ''
if not block:
    m = re.search(r'<!--([\s\S]*?)-->', content)
    if m and re.search(r'SEO\s+Title', m.group(1), re.IGNORECASE):
        block = m.group(1)
def field(key):
    for pat in [rf'{key}:\s*(.+)', rf'SEO\s+{key}:\s*(.+)', rf'Meta\s+{key}:\s*(.+)']:
        fm = re.search(pat, block, re.IGNORECASE)
        if fm: return html_lib.unescape(fm.group(1).strip())
    return ''
title = field('title')
desc  = field('description')
canonical = field('canonical') or field('url')
if not title:
    m = re.search(r'<title[^>]*>(.*?)</title>', content, re.IGNORECASE | re.DOTALL)
    if m: title = html_lib.unescape(m.group(1).strip())
if not title:
    m = re.search(r'<h1[^>]*>(.*?)</h1>', content, re.IGNORECASE | re.DOTALL)
    if m: title = html_lib.unescape(re.sub(r'<[^>]+>', '', m.group(1)).strip())
print(json.dumps({'title': title, 'desc': desc, 'canonical': canonical}))
PYEOF
  ) || _result='{}'
  SEO_TITLE=$(python3    -c "import json,sys; print(json.loads(sys.argv[1])['title'])"     "$_result" 2>/dev/null) || SEO_TITLE=""
  SEO_DESC=$(python3     -c "import json,sys; print(json.loads(sys.argv[1])['desc'])"      "$_result" 2>/dev/null) || SEO_DESC=""
  SEO_CANONICAL=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['canonical'])" "$_result" 2>/dev/null) || SEO_CANONICAL=""
}

# Apply post meta via SSH + WP-CLI
apply_post_meta() {
  local post_id="$1" seo_title="$2" seo_desc="$3" seo_canonical="$4"
  [[ $SSH_OK == true ]] || return 0
  local cmd=""
  cmd+="wp post meta update ${post_id} _generate-disable-headline true --path='${WP_PATH}' 2>/dev/null; "
  cmd+="wp post meta update ${post_id} _generate-disable-post-image true --path='${WP_PATH}' 2>/dev/null; "
  if [[ -n "$seo_title" ]]; then
    local b64=$(printf '%s' "$seo_title" | base64)
    cmd+="wp post meta update ${post_id} rank_math_title \"\$(printf '%s' '${b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null; "
  fi
  if [[ -n "$seo_desc" ]]; then
    local b64=$(printf '%s' "$seo_desc" | base64)
    cmd+="wp post meta update ${post_id} rank_math_description \"\$(printf '%s' '${b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null; "
  fi
  if [[ -n "$seo_canonical" ]]; then
    local b64=$(printf '%s' "$seo_canonical" | base64)
    cmd+="wp post meta update ${post_id} rank_math_canonical_url \"\$(printf '%s' '${b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null; "
  fi
  ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "$cmd" </dev/null 2>/dev/null && \
    echo "  ⚙ Meta set (id=$post_id): GP elements disabled + RankMath SEO applied" || \
    echo "  ⚠ Could not set post meta for id=$post_id"
}

# Category ID cache
declare -A CAT_ID_CACHE=()

get_cat_id() {
  local silo="$1"
  [[ -n "${CAT_ID_CACHE[$silo]:-}" ]] && { echo "${CAT_ID_CACHE[$silo]}"; return; }
  local cat_slug="$silo"
  [[ -n "${CAT_SLUG_MAP[$silo]:-}" ]] && cat_slug="${CAT_SLUG_MAP[$silo]}"
  local resp
  resp=$(curl -s --connect-timeout 10 --max-time 30 \
    -u "${WP_USER}:${WP_PASS}" \
    "${WP_SITE_URL%/}/wp-json/wp/v2/categories/?slug=${cat_slug}&per_page=1" 2>/dev/null) || resp="[]"
  local cid
  cid=$(python3 -c "import json,sys; cats=json.loads(sys.argv[1]); print(cats[0]['id'] if cats else 0)" "$resp" 2>/dev/null) || cid=0
  CAT_ID_CACHE[$silo]="$cid"
  echo "$cid"
}

# ── Auth check ───────────────────────────────────────────────────────────────
echo "========================================================="
echo "  Retry failed publishes — $SITE_SLUG"
echo "  Site: $WP_SITE_URL"
echo "  Items: ${#FAILED_POSTS[@]} posts + homepage=$RETRY_HOMEPAGE"
echo "========================================================="
echo ""
echo "  Verifying WordPress auth..."
AUTH_CHECK=$(curl -s --connect-timeout 10 \
  -u "${WP_USER}:${WP_PASS}" \
  "${WP_SITE_URL%/}/wp-json/wp/v2/users/me/" 2>&1) || true
AUTH_NAME=$(printf '%s' "$AUTH_CHECK" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('name', 'AUTH_FAILED'))
except Exception:
    print('AUTH_FAILED')
" 2>/dev/null) || AUTH_NAME="AUTH_FAILED"
if [[ "$AUTH_NAME" == "AUTH_FAILED" ]]; then
  echo "  ✗ WordPress auth failed."
  exit 1
fi
echo "  ✓ Authenticated as: $AUTH_NAME"

CREATED=0
FAILED=0
MAX_RETRIES=2

# ── Publish posts ────────────────────────────────────────────────────────────
for ITEM in "${FAILED_POSTS[@]}"; do
  SILO="${ITEM%%/*}"
  SLUG="${ITEM##*/}"
  HTML_FILE="$ARTICLES_DIR/$SILO/$SLUG.html"

  echo ""
  echo "  ── post: $SILO/$SLUG"

  if [[ ! -f "$HTML_FILE" ]]; then
    echo "  ✗ File not found: $HTML_FILE"
    FAILED=$(( FAILED + 1 ))
    continue
  fi

  parse_seo_comment "$HTML_FILE"
  TITLE="${SEO_TITLE:-$SLUG}"

  CAT_ID=$(get_cat_id "$SILO")
  if [[ "$CAT_ID" -eq 0 ]]; then
    echo "  ✗ Category not found for silo: $SILO"
    FAILED=$(( FAILED + 1 ))
    continue
  fi

  # Check if already exists
  EXISTING=$(curl -s --connect-timeout 10 --max-time 30 \
    -u "${WP_USER}:${WP_PASS}" \
    "${WP_POSTS_API}?slug=${SLUG}&status=any&per_page=1" 2>/dev/null) || EXISTING="[]"
  EXISTING_ID=$(python3 -c "import json,sys; posts=json.loads(sys.argv[1]); print(posts[0]['id'] if posts else '')" "$EXISTING" 2>/dev/null) || EXISTING_ID=""

  if [[ -n "$EXISTING_ID" ]]; then
    echo "  ↺ Already exists (id=$EXISTING_ID) — skipping"
    continue
  fi

  # Build payload
  TMP_PAYLOAD=$(mktemp /tmp/wp-retry-XXXXXX)
  python3 - "$HTML_FILE" "$TITLE" "$SLUG" "$CAT_ID" "$POST_STATUS" > "$TMP_PAYLOAD" 2>/dev/null << 'PYEOF'
import json, re, sys
html_file, title, slug, cat_id, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
wrapped = '<!-- wp:html -->\n' + content + '\n<!-- /wp:html -->'
payload = {'title': title, 'slug': slug, 'content': wrapped, 'status': status}
if cat_id > 0:
    payload['categories'] = [cat_id]
print(json.dumps(payload))
PYEOF

  if [[ ! -s "$TMP_PAYLOAD" ]]; then
    echo "  ✗ Failed to build payload"
    rm -f "$TMP_PAYLOAD"
    FAILED=$(( FAILED + 1 ))
    continue
  fi

  # Create with retries
  SUCCESS=false
  for attempt in $(seq 1 $MAX_RETRIES); do
    [[ $attempt -gt 1 ]] && echo "  ↻ Retry $attempt/$MAX_RETRIES (waiting ${DELAY}s)..." && sleep "$DELAY"

    HTTP_CODE=$(curl -s -o /tmp/wp-retry-resp-$$.json -w "%{http_code}" \
      --connect-timeout 15 --max-time 120 \
      -X POST \
      -u "${WP_USER}:${WP_PASS}" \
      -H "Content-Type: application/json" \
      --data-binary "@${TMP_PAYLOAD}" \
      "$WP_POSTS_API" 2>/dev/null) || HTTP_CODE="000"

    RESPONSE=$(cat /tmp/wp-retry-resp-$$.json 2>/dev/null) || RESPONSE="{}"

    NEW_ID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('id',''))" "$RESPONSE" 2>/dev/null) || NEW_ID=""

    if [[ -n "$NEW_ID" ]]; then
      echo "  ✓ Created post (id=$NEW_ID) [$SILO]: $TITLE"
      apply_post_meta "$NEW_ID" "$SEO_TITLE" "$SEO_DESC" "$SEO_CANONICAL"
      CREATED=$(( CREATED + 1 ))
      SUCCESS=true
      break
    else
      echo "  ✗ Attempt $attempt failed (HTTP $HTTP_CODE)"
      echo "     Response: ${RESPONSE:0:300}"
    fi
  done

  rm -f "$TMP_PAYLOAD" /tmp/wp-retry-resp-$$.json
  $SUCCESS || FAILED=$(( FAILED + 1 ))

  # Delay between posts
  sleep "$DELAY"
done

# ── Homepage ─────────────────────────────────────────────────────────────────
if $RETRY_HOMEPAGE; then
  echo ""
  echo "  ── homepage"
  if [[ -f "$HOMEPAGE_FILE" ]]; then
    parse_seo_comment "$HOMEPAGE_FILE"
    TITLE="${SEO_TITLE:-Homepage}"
    SLUG="homepage"

    EXISTING=$(curl -s --connect-timeout 10 --max-time 30 \
      -u "${WP_USER}:${WP_PASS}" \
      "${WP_PAGES_API}?slug=${SLUG}&status=any&per_page=1" 2>/dev/null) || EXISTING="[]"
    EXISTING_ID=$(python3 -c "import json,sys; pages=json.loads(sys.argv[1]); print(pages[0]['id'] if pages else '')" "$EXISTING" 2>/dev/null) || EXISTING_ID=""

    if [[ -n "$EXISTING_ID" ]]; then
      echo "  ↺ Already exists (id=$EXISTING_ID) — skipping"
    else
      TMP_PAYLOAD=$(mktemp /tmp/wp-retry-XXXXXX)
      python3 - "$HOMEPAGE_FILE" "$TITLE" "$SLUG" "0" "$POST_STATUS" > "$TMP_PAYLOAD" 2>/dev/null << 'PYEOF'
import json, re, sys
html_file, title, slug, cat_id, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
wrapped = '<!-- wp:html -->\n' + content + '\n<!-- /wp:html -->'
payload = {'title': title, 'slug': slug, 'content': wrapped, 'status': status}
print(json.dumps(payload))
PYEOF

      for attempt in $(seq 1 $MAX_RETRIES); do
        [[ $attempt -gt 1 ]] && echo "  ↻ Retry $attempt/$MAX_RETRIES (waiting ${DELAY}s)..." && sleep "$DELAY"
        HTTP_CODE=$(curl -s -o /tmp/wp-retry-resp-$$.json -w "%{http_code}" \
          --connect-timeout 15 --max-time 120 \
          -X POST \
          -u "${WP_USER}:${WP_PASS}" \
          -H "Content-Type: application/json" \
          --data-binary "@${TMP_PAYLOAD}" \
          "$WP_PAGES_API" 2>/dev/null) || HTTP_CODE="000"
        RESPONSE=$(cat /tmp/wp-retry-resp-$$.json 2>/dev/null) || RESPONSE="{}"
        NEW_ID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('id',''))" "$RESPONSE" 2>/dev/null) || NEW_ID=""
        if [[ -n "$NEW_ID" ]]; then
          echo "  ✓ Created page (id=$NEW_ID): $TITLE"
          apply_post_meta "$NEW_ID" "$SEO_TITLE" "$SEO_DESC" "$SEO_CANONICAL"
          CREATED=$(( CREATED + 1 ))
          break
        else
          echo "  ✗ Attempt $attempt failed (HTTP $HTTP_CODE)"
          echo "     Response: ${RESPONSE:0:300}"
        fi
      done
      rm -f "$TMP_PAYLOAD" /tmp/wp-retry-resp-$$.json
    fi
  else
    echo "  ✗ File not found: $HOMEPAGE_FILE"
    echo "    (Homepage must be generated first)"
    FAILED=$(( FAILED + 1 ))
  fi
fi

echo ""
echo "========================================================="
echo "  Done — Created: $CREATED  |  Failed: $FAILED"
echo "========================================================="
