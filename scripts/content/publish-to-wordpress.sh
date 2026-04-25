#!/usr/bin/env zsh
set -euo pipefail

# ── publish-to-wordpress.sh ───────────────────────────────────────────────────
# Publishes generated HTML to WordPress.
#   L2 articles  → WP posts  (/wp-json/wp/v2/posts)
#   L1 pages     → WP pages  (/wp-json/wp/v2/pages)
#   homepage     → WP pages  (/wp-json/wp/v2/pages)
#
# Usage:
#   ./scripts/content/publish-to-wordpress.sh <site-slug> [--only <target>]
#
# Targets for --only:
#   homepage            output/<site-slug>/homepage.html
#   plan-your-visit     output/<site-slug>/l1-pages/plan-your-visit.html
#   tickets-tours       output/<site-slug>/l1-pages/tickets-tours.html
#   what-to-see         output/<site-slug>/l1-pages/what-to-see.html
#   l2-articles         all silos under output/<site-slug>/l2-articles/
#   <silo-name>         one specific silo under l2-articles/
#
# Default (no --only): publishes homepage + all L1 pages + all L2 articles.
#
# Requires in .env: WP_SITE_URL, WP_USER, WP_PASS
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--only <target>]"
  exit 1
fi

SITE_SLUG="$1"
shift

# Load url-registry.json category mapping (dir_name → WP category slug)
# Built after REPO_ROOT is set below; populated in a second pass after env loading.
# Static fallback for standard 3-silo layout — overwritten by url-registry.json if present
declare -A CAT_SLUG_MAP=(
  [tickets-tours]="tickets"
  [tickets-and-tours]="tickets"
  [plan-your-visit]="plan-your-visit"
  [what-to-see]="what-to-see"
)

ONLY=""
SAMPLE=false
POST_STATUS="draft"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)   ONLY="$2"; shift 2 ;;
    --sample) SAMPLE=true; shift ;;
    --status) POST_STATUS="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Preserve SSH vars already exported by main.sh (server selection at step 0)
# so that sourcing .env files below does not overwrite the user's choice.
_PRE_SSH_HOST="${WP_SSH_HOST:-}"
_PRE_SSH_USER="${WP_SSH_USER:-}"
_PRE_SSH_KEY="${WP_SSH_KEY:-}"

# Load root .env then site-specific .env (site overrides root)
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

# If site .env specifies WP_SERVER=2, activate Server 2 credentials
if [[ "${WP_SERVER:-}" == "2" ]]; then
  export WP_SSH_HOST="${WP_SSH_HOST2:-$WP_SSH_HOST}"
  export WP_SSH_USER="${WP_SSH_USER2:-$WP_SSH_USER}"
  export WP_SSH_KEY="${WP_SSH_KEY2:-$WP_SSH_KEY}"
elif [[ -n "$_PRE_SSH_HOST" ]]; then
  # Restore SSH vars from parent if they were set (main.sh server selection wins)
  export WP_SSH_HOST="$_PRE_SSH_HOST"
  export WP_SSH_USER="$_PRE_SSH_USER"
  export WP_SSH_KEY="$_PRE_SSH_KEY"
fi

# Pre-flight checks
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required"; exit 1; }
[[ -n "${WP_SITE_URL:-}" ]] || { echo "Error: WP_SITE_URL not set in .env"; exit 1; }
[[ -n "${WP_USER:-}"     ]] || { echo "Error: WP_USER not set in .env"; exit 1; }
[[ -n "${WP_PASS:-}"     ]] || { echo "Error: WP_PASS not set in .env"; exit 1; }

OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG"

# Build dir_name → category_slug mapping from url-registry.json if available
URL_REGISTRY="$OUTPUT_DIR/url-registry.json"
if [[ -f "$URL_REGISTRY" ]]; then
  _map_json=$(python3 - "$URL_REGISTRY" << 'PYEOF'
import json, sys
try:
    reg = json.load(open(sys.argv[1]))
    cats = reg.get("categories", {})
    # categories keyed by slug, with dir_name inside: { "tickets": { "dir_name": "tickets-tours" } }
    for cat_slug, info in cats.items():
        dir_name = info.get("dir_name", cat_slug) if isinstance(info, dict) else cat_slug
        if dir_name and cat_slug:
            print(f"{dir_name}={cat_slug}")
except Exception:
    pass
PYEOF
  ) || _map_json=""
  while IFS='=' read -r _dir _slug; do
    _dir="${_dir//\"/}"  # strip any surrounding quotes
    _slug="${_slug//\"/}"
    [[ -n "$_dir" && -n "$_slug" ]] && CAT_SLUG_MAP[$_dir]="$_slug"
  done <<< "$_map_json"
  if [[ ${#CAT_SLUG_MAP[@]} -gt 0 ]]; then
    echo "  Loaded category slug map from url-registry.json (${#CAT_SLUG_MAP[@]} entries)"
  fi
fi

ARTICLES_DIR="$OUTPUT_DIR/l2-articles"
L1_DIR="$OUTPUT_DIR/l1-pages"
HOMEPAGE_FILE="$OUTPUT_DIR/homepage.html"

WP_POSTS_API="${WP_SITE_URL%/}/wp-json/wp/v2/posts"
WP_PAGES_API="${WP_SITE_URL%/}/wp-json/wp/v2/pages"

# SSH setup — uses ControlMaster to reuse a single connection for all WP-CLI calls
SSH_OK=false
SSH_KEY_OPT=()
SSH_CTL=""
if [[ -n "${WP_SSH_HOST:-}" && -n "${WP_SSH_USER:-}" && -n "${WP_PATH:-}" ]]; then
  SSH_CTL="/tmp/wp-ssh-ctl-$$"
  SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
               -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
               -o ConnectTimeout=15
               -o ControlMaster=auto
               -o ControlPath="$SSH_CTL"
               -o ControlPersist=120)
  # Open master connection
  ssh "${SSH_KEY_OPT[@]}" -N -f "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null && SSH_OK=true || true
  # Cleanup master on exit
  trap '[[ -n "$SSH_CTL" ]] && ssh -O exit -o ControlPath="$SSH_CTL" "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null; true' EXIT
fi

# Parse <!-- SEO title/description/canonical --> from an HTML file.
# Outputs: SEO_TITLE, SEO_DESC, SEO_CANONICAL
parse_seo_comment() {
  local html_file="$1"
  local _result
  _result=$(python3 - "$html_file" << 'PYEOF'
import re, sys, json, html as html_lib
content = open(sys.argv[1]).read()

# Match both formats:
# Format A: <!-- SEO\ntitle: ...\n-->
# Format B: <!--\n  ===\n  SEO Title: ...\n  ===\n-->
block = ''
m = re.search(r'<!--\s*SEO([\s\S]*?)-->', content, re.IGNORECASE)
if m:
    block = m.group(1)
else:
    m = re.search(r'<!--([\s\S]*?)-->', content)
    if m and re.search(r'SEO\s+Title', m.group(1), re.IGNORECASE):
        block = m.group(1)

def field(key):
    # Match "key:" or "key Title:" or "Meta key:" variants
    patterns = [rf'{key}:\s*(.+)', rf'SEO\s+{key}:\s*(.+)', rf'Meta\s+{key}:\s*(.+)']
    for pat in patterns:
        fm = re.search(pat, block, re.IGNORECASE)
        if fm:
            return html_lib.unescape(fm.group(1).strip())
    return ''

title = field('title')
desc  = field('description')
canonical = field('canonical') or field('url')

# Fallback 1: <title> tag
if not title:
    m = re.search(r'<title[^>]*>(.*?)</title>', content, re.IGNORECASE | re.DOTALL)
    if m: title = html_lib.unescape(m.group(1).strip())
# Fallback 2: first <h1>
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

# Apply all post meta in ONE SSH call: GP disable elements + RankMath SEO
apply_post_meta() {
  local post_id="$1" seo_title="$2" seo_desc="$3" seo_canonical="$4"

  [[ $SSH_OK == true ]] || return 0

  local cmd=""

  # GP Premium: disable headline and featured image
  cmd+="wp post meta update ${post_id} _generate-disable-headline true --path='${WP_PATH}' 2>/dev/null; "
  cmd+="wp post meta update ${post_id} _generate-disable-post-image true --path='${WP_PATH}' 2>/dev/null; "

  # RankMath SEO (base64-encoded to avoid quoting issues)
  if [[ -n "$seo_title" ]]; then
    local b64=$(printf '%s' "$seo_title" | base64)
    cmd+="wp post meta update ${post_id} rank_math_title \"\$(printf '%s' '${b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null; "
  fi
  if [[ -n "$seo_desc" ]]; then
    local b64=$(printf '%s' "$seo_desc" | base64)
    cmd+="wp post meta update ${post_id} rank_math_description \"\$(printf '%s' '${b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null; "
  fi
  # rank_math_canonical_url left empty — Rank Math auto-generates from post URL

  ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "$cmd" </dev/null 2>/dev/null && \
    echo "  ⚙ Meta set (id=$post_id): GP elements disabled + RankMath SEO applied" || \
    echo "  ⚠ Could not set post meta for id=$post_id"
}

echo "========================================================="
echo "  Publish to WordPress — $SITE_SLUG"
echo "  Site:   $WP_SITE_URL"
[[ -n "$ONLY" ]] && echo "  Target: $ONLY" || echo "  Target: all"
echo "========================================================="

# Verify WP REST API auth
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
  echo "  ✗ WordPress auth failed. Check WP_USER and WP_PASS in .env"
  exit 1
fi
echo "  ✓ Authenticated as: $AUTH_NAME"

COUNT_CREATED=0
COUNT_UPDATED=0
COUNT_FAILED=0

# ── Helper: publish one HTML file as a WP page ───────────────────────────────
# Resolve the WP page slug for an L1 page from the registry dir_to_url map.
# e.g. "tickets-tours" -> "tickets"  (because dir_to_url maps tickets-tours -> /tickets)
# Falls back to the dir name itself if not in registry.
resolve_l1_slug() {
  local DIR_NAME="$1"
  python3 - "$URL_REGISTRY" "$DIR_NAME" 2>/dev/null << 'PYEOF'
import json, sys
try:
    reg = json.load(open(sys.argv[1]))
    dir_name = sys.argv[2]
    url_path = reg.get("dir_to_url", {}).get(dir_name, "")
    slug = url_path.strip("/").split("/")[-1] if url_path else ""
    print(slug if slug else dir_name)
except Exception:
    print(sys.argv[2])
PYEOF
}

publish_page() {
  local HTML_FILE="$1"
  local SLUG="$2"
  local LABEL="${3:-$SLUG}"

  [[ -f "$HTML_FILE" ]] || { echo "  ✗ File not found: $HTML_FILE"; COUNT_FAILED=$(( COUNT_FAILED + 1 )); return; }

  echo ""
  echo "  ── page: $LABEL"

  # Parse SEO comment BEFORE stripping it from the payload
  parse_seo_comment "$HTML_FILE"
  TITLE="${SEO_TITLE:-$SLUG}"

  # Check if a page with this slug already exists
  EXISTING=$(curl -s --connect-timeout 10 --max-time 30 \
    -u "${WP_USER}:${WP_PASS}" \
    "${WP_PAGES_API}?slug=${SLUG}&status=any&per_page=1" 2>/dev/null) || EXISTING="[]"

  EXISTING_ID=$(python3 -c "
import json, sys
pages = json.loads(sys.argv[1])
print(pages[0]['id'] if pages else '')
" "$EXISTING" 2>/dev/null) || EXISTING_ID=""

  TMP_PAYLOAD=$(mktemp /tmp/wp-payload-XXXXXX)
  python3 - "$HTML_FILE" "$TITLE" "$SLUG" "$POST_STATUS" > "$TMP_PAYLOAD" 2>/dev/null << 'PYEOF'
import json, re, sys
html_file, title, slug, status = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
# Decode presentation entities so WP doesn't double-encode them
for ent, ch in [('&rarr;','→'),('&larr;','←'),('&mdash;','—'),('&ndash;','–'),('&middot;','·'),('&bull;','•'),('&hellip;','…'),('&times;','×')]:
    content = content.replace(ent, ch)
# Split at <section> boundaries — each section becomes its own editable wp:html block
parts = re.split(r'(?=<section\b)', content)
blocks = '\n\n'.join('<!-- wp:html -->\n' + p.strip() + '\n<!-- /wp:html -->' for p in parts if p.strip())
print(json.dumps({'title': title, 'slug': slug, 'content': blocks, 'status': status}))
PYEOF

  if [[ ! -s "$TMP_PAYLOAD" ]]; then
    echo "  ✗ Failed to build payload for: $SLUG"
    rm -f "$TMP_PAYLOAD"
    COUNT_FAILED=$(( COUNT_FAILED + 1 ))
    return
  fi

  if [[ -n "$EXISTING_ID" ]]; then
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 \
      -X POST \
      -u "${WP_USER}:${WP_PASS}" \
      -H "Content-Type: application/json" \
      --data-binary "@${TMP_PAYLOAD}" \
      "${WP_PAGES_API}/${EXISTING_ID}" 2>/dev/null) || RESPONSE="{}"
    rm -f "$TMP_PAYLOAD"
    STATUS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('status','error'))" "$RESPONSE" 2>/dev/null) || STATUS="error"
    if [[ "$STATUS" == "draft" || "$STATUS" == "publish" || "$STATUS" == "pending" ]]; then
      echo "  ↺ Updated page (id=$EXISTING_ID) [$STATUS]: $TITLE"
      apply_post_meta "$EXISTING_ID" "$SEO_TITLE" "$SEO_DESC" "$SEO_CANONICAL"

      COUNT_UPDATED=$(( COUNT_UPDATED + 1 ))
    else
      echo "  ✗ Update failed for page: $SLUG"
      echo "     Response: ${RESPONSE:0:200}"
      COUNT_FAILED=$(( COUNT_FAILED + 1 ))
    fi
  else
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 \
      -X POST \
      -u "${WP_USER}:${WP_PASS}" \
      -H "Content-Type: application/json" \
      --data-binary "@${TMP_PAYLOAD}" \
      "$WP_PAGES_API" 2>/dev/null) || RESPONSE="{}"
    rm -f "$TMP_PAYLOAD"
    NEW_ID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('id',''))" "$RESPONSE" 2>/dev/null) || NEW_ID=""
    if [[ -n "$NEW_ID" ]]; then
      echo "  ✓ Created page (id=$NEW_ID): $TITLE"
      apply_post_meta "$NEW_ID" "$SEO_TITLE" "$SEO_DESC" "$SEO_CANONICAL"

      COUNT_CREATED=$(( COUNT_CREATED + 1 ))
    else
      echo "  ✗ Create failed for page: $SLUG"
      echo "     Response: ${RESPONSE:0:200}"
      COUNT_FAILED=$(( COUNT_FAILED + 1 ))
    fi
  fi
}

# ── Helper: publish all L2 articles in a silo as WP posts ────────────────────
publish_silo() {
  local SILO="$1"
  local SILO_DIR="$ARTICLES_DIR/$SILO"
  [[ -d "$SILO_DIR" ]] || return 0

  # Resolve WP category slug: check registry mapping first, fall back to silo dir name
  local CAT_SLUG="$SILO"
  if [[ -n "${CAT_SLUG_MAP[$SILO]:-}" ]]; then
    CAT_SLUG="${CAT_SLUG_MAP[$SILO]}"
  fi

  # Look up category ID by slug
  local CAT_RESPONSE CAT_ID
  CAT_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 \
    -u "${WP_USER}:${WP_PASS}" \
    "${WP_SITE_URL%/}/wp-json/wp/v2/categories/?slug=${CAT_SLUG}&per_page=1" 2>/dev/null) || CAT_RESPONSE="[]"
  CAT_ID=$(python3 -c "
import json, sys
cats = json.loads(sys.argv[1])
print(cats[0]['id'] if cats else 0)
" "$CAT_RESPONSE" 2>/dev/null) || CAT_ID=0

  if [[ "$CAT_ID" -gt 0 ]]; then
    echo "  ✓ Category: $CAT_SLUG (id=$CAT_ID) [silo: $SILO]"
  else
    echo "  ✗ Category not found for silo '$SILO' (looked up slug '$CAT_SLUG')"
    echo "    Create it with:"
    echo "      wp term create category '$CAT_SLUG' --slug='$CAT_SLUG' --path='\${WP_PATH}'"
    return 1
  fi

  local _count=0
  for HTML_FILE in "$SILO_DIR"/*.html(N); do
    [[ -f "$HTML_FILE" ]] || continue
    $SAMPLE && [[ $_count -gt 0 ]] && break
    _count=$(( _count + 1 ))

    SLUG=$(basename "$HTML_FILE" .html)
    echo ""
    echo "  ── post: $SILO/$SLUG"

    # Parse SEO comment BEFORE stripping it from the payload
    parse_seo_comment "$HTML_FILE"
    TITLE="${SEO_TITLE:-$SLUG}"

    EXISTING=$(curl -s --connect-timeout 10 --max-time 30 \
      -u "${WP_USER}:${WP_PASS}" \
      "${WP_POSTS_API}?slug=${SLUG}&status=any&per_page=1" 2>/dev/null) || EXISTING="[]"

    EXISTING_ID=$(python3 -c "
import json, sys
posts = json.loads(sys.argv[1])
print(posts[0]['id'] if posts else '')
" "$EXISTING" 2>/dev/null) || EXISTING_ID=""

    TMP_PAYLOAD=$(mktemp /tmp/wp-payload-XXXXXX)
    python3 - "$HTML_FILE" "$TITLE" "$SLUG" "$CAT_ID" "$POST_STATUS" > "$TMP_PAYLOAD" 2>/dev/null << 'PYEOF'
import json, re, sys
html_file, title, slug, cat_id, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
# Decode presentation entities so WP doesn't double-encode them
for ent, ch in [('&rarr;','→'),('&larr;','←'),('&mdash;','—'),('&ndash;','–'),('&middot;','·'),('&bull;','•'),('&hellip;','…'),('&times;','×')]:
    content = content.replace(ent, ch)
# Split at <section> boundaries — each section becomes its own editable wp:html block
parts = re.split(r'(?=<section\b)', content)
blocks = '\n\n'.join('<!-- wp:html -->\n' + p.strip() + '\n<!-- /wp:html -->' for p in parts if p.strip())
payload = {'title': title, 'slug': slug, 'content': blocks, 'status': status}
if cat_id > 0:
    payload['categories'] = [cat_id]
print(json.dumps(payload))
PYEOF
    if [[ ! -s "$TMP_PAYLOAD" ]]; then
      echo "  ✗ Failed to build payload for: $SLUG"
      rm -f "$TMP_PAYLOAD"
      COUNT_FAILED=$(( COUNT_FAILED + 1 ))
      continue
    fi

    if [[ -n "$EXISTING_ID" ]]; then
      RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 \
        -X POST \
        -u "${WP_USER}:${WP_PASS}" \
        -H "Content-Type: application/json" \
        --data-binary "@${TMP_PAYLOAD}" \
        "${WP_POSTS_API}/${EXISTING_ID}" 2>/dev/null) || RESPONSE="{}"
      rm -f "$TMP_PAYLOAD"
      STATUS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('status','error'))" "$RESPONSE" 2>/dev/null) || STATUS="error"
      if [[ "$STATUS" == "draft" || "$STATUS" == "publish" || "$STATUS" == "pending" ]]; then
        echo "  ↺ Updated post (id=$EXISTING_ID) [$SILO/$STATUS]: $TITLE"
        apply_post_meta "$EXISTING_ID" "$SEO_TITLE" "$SEO_DESC" "$SEO_CANONICAL"
  
        COUNT_UPDATED=$(( COUNT_UPDATED + 1 ))
      else
        echo "  ✗ Update failed for: $SLUG"
        COUNT_FAILED=$(( COUNT_FAILED + 1 ))
      fi
    else
      RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 \
        -X POST \
        -u "${WP_USER}:${WP_PASS}" \
        -H "Content-Type: application/json" \
        --data-binary "@${TMP_PAYLOAD}" \
        "$WP_POSTS_API" 2>/dev/null) || RESPONSE="{}"
      rm -f "$TMP_PAYLOAD"
      NEW_ID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('id',''))" "$RESPONSE" 2>/dev/null) || NEW_ID=""
      if [[ -n "$NEW_ID" ]]; then
        echo "  ✓ Created post (id=$NEW_ID) [$SILO]: $TITLE"
        apply_post_meta "$NEW_ID" "$SEO_TITLE" "$SEO_DESC" "$SEO_CANONICAL"
  
        COUNT_CREATED=$(( COUNT_CREATED + 1 ))
      else
        echo "  ✗ Create failed for: $SLUG"
        echo "     Response: ${RESPONSE:0:200}"
        COUNT_FAILED=$(( COUNT_FAILED + 1 ))
      fi
    fi
  done
}

# ── Helper: publish About Us & Contact Us from templates ─────────────────────
# Renders templates/about-us-template.html and templates/contact-us-template.html
# with site-specific variables, publishes via REST API, and sets noindex meta.
publish_utility_page() {
  local TEMPLATE_FILE="$1" PAGE_SLUG="$2" PAGE_TITLE="$3"

  [[ -f "$TEMPLATE_FILE" ]] || { echo "  ✗ Template not found: $TEMPLATE_FILE"; COUNT_FAILED=$(( COUNT_FAILED + 1 )); return; }

  # Derive site variables from WP_SITE_URL
  local _SITE_URL="${WP_SITE_URL%/}"
  local _HOSTNAME="${_SITE_URL#https://}"; _HOSTNAME="${_HOSTNAME#http://}"; _HOSTNAME="${_HOSTNAME%%/*}"
  local _SITE_NAME=$(echo "$_HOSTNAME" | sed 's/-guide\.com$//' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')
  local _ATTRACTION_NAME="$_SITE_NAME"
  local _ATTRACTION_SLUG=$(echo "$_ATTRACTION_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')

  # Render template with variable substitution
  local _RENDERED
  _RENDERED=$(sed \
    -e "s|{{SITE_URL}}|${_SITE_URL}|g" \
    -e "s|{{SITE_NAME}}|${_SITE_NAME}|g" \
    -e "s|{{ATTRACTION_NAME}}|${_ATTRACTION_NAME}|g" \
    -e "s|{{ATTRACTION_SLUG}}|${_ATTRACTION_SLUG}|g" \
    "$TEMPLATE_FILE")

  # Write rendered HTML to a temp file so publish_page can read it
  local _TMP_HTML
  _TMP_HTML=$(mktemp /tmp/wp-utility-XXXXXX.html)
  printf '%s' "$_RENDERED" > "$_TMP_HTML"

  publish_page "$_TMP_HTML" "$PAGE_SLUG" "$PAGE_TITLE"
  rm -f "$_TMP_HTML"

  # Apply extra meta: noindex + GP disable title/featured image
  if [[ $SSH_OK == true ]]; then
    local _PAGE_ID
    _PAGE_ID=$(curl -s --connect-timeout 10 --max-time 30 \
      -u "${WP_USER}:${WP_PASS}" \
      "${WP_PAGES_API}?slug=${PAGE_SLUG}&status=any&per_page=1" 2>/dev/null) || _PAGE_ID="[]"
    _PAGE_ID=$(python3 -c "import json,sys; p=json.loads(sys.argv[1]); print(p[0]['id'] if p else '')" "$_PAGE_ID" 2>/dev/null) || _PAGE_ID=""

    if [[ -n "$_PAGE_ID" ]]; then
      local _rm_title_b64=$(printf '%s' "About Us — ${_SITE_NAME} Guide | ${_HOSTNAME}" | base64)
      local _rm_desc_b64=$(printf '%s' "Learn about ${_SITE_NAME} Guide — your complete resource for tickets, tours, and visitor tips." | base64)
      if [[ "$PAGE_SLUG" == "contact-us" ]]; then
        _rm_title_b64=$(printf '%s' "Contact Us — ${_SITE_NAME} Guide | ${_HOSTNAME}" | base64)
        _rm_desc_b64=$(printf '%s' "Get in touch with the ${_SITE_NAME} Guide team. Questions about tickets, tours, or visiting? We are here to help." | base64)
      fi
      ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
        wp post meta update ${_PAGE_ID} _generate_disable_title true --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} _generate_disable_featured_image true --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} rank_math_title \"\$(printf '%s' '${_rm_title_b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} rank_math_description \"\$(printf '%s' '${_rm_desc_b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null
        wp eval \"update_post_meta(${_PAGE_ID}, 'rank_math_robots', array('noindex'));\" --path='${WP_PATH}' 2>/dev/null
      " </dev/null 2>/dev/null && \
        echo "  ⚙ Utility meta set (id=${_PAGE_ID}): GP title/image disabled + noindex" || \
        echo "  ⚠ Could not set utility meta for id=${_PAGE_ID}"
    fi
  fi
}

publish_utility_pages() {
  local _TEMPLATES_DIR="$REPO_ROOT/templates"
  echo ""
  echo "  ── Utility pages (About Us + Contact Us) ──"
  publish_utility_page "$_TEMPLATES_DIR/about-us-template.html" "about-us" "About Us"
  publish_utility_page "$_TEMPLATES_DIR/contact-us-template.html" "contact-us" "Contact Us"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [[ -z "$ONLY" ]]; then
  # Publish everything
  publish_page "$HOMEPAGE_FILE" "homepage" "homepage"
  # Set homepage as static front page
  HP_ID=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp post list --post_type=page --name=homepage --field=ID --path='${WP_PATH}' 2>/dev/null | head -1" </dev/null 2>/dev/null || true)
  if [[ -n "$HP_ID" ]]; then
    ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
      "wp option update show_on_front page --path='${WP_PATH}' && wp option update page_on_front '${HP_ID}' --path='${WP_PATH}'" </dev/null 2>/dev/null || true
    echo "✓ Homepage (ID $HP_ID) set as static front page"
  else
    echo "⚠ Could not find homepage page ID — set front page manually"
  fi
  for L1 in "$L1_DIR"/*.html(N); do
    local L1_NAME="$(basename "$L1" .html)"
    local L1_SLUG="$(resolve_l1_slug "$L1_NAME")"
    publish_page "$L1" "$L1_SLUG" "$L1_NAME"
  done
  if [[ -d "$ARTICLES_DIR" ]]; then
    for SILO_DIR in "$ARTICLES_DIR"/*/; do
      publish_silo "$(basename "$SILO_DIR")"
    done
  fi
  publish_utility_pages
elif [[ "$ONLY" == "about-us" ]]; then
  publish_utility_page "$REPO_ROOT/templates/about-us-template.html" "about-us" "About Us"
elif [[ "$ONLY" == "contact-us" ]]; then
  publish_utility_page "$REPO_ROOT/templates/contact-us-template.html" "contact-us" "Contact Us"
elif [[ "$ONLY" == "homepage" ]]; then
  publish_page "$HOMEPAGE_FILE" "homepage" "homepage"
elif [[ "$ONLY" == "l1-pages" ]]; then
  for L1 in "$L1_DIR"/*.html(N); do
    local L1_NAME="$(basename "$L1" .html)"
    local L1_SLUG="$(resolve_l1_slug "$L1_NAME")"
    publish_page "$L1" "$L1_SLUG" "$L1_NAME"
  done
elif [[ -f "$L1_DIR/${ONLY}.html" ]]; then
  local ONLY_SLUG="$(resolve_l1_slug "$ONLY")"
  publish_page "$L1_DIR/${ONLY}.html" "$ONLY_SLUG" "$ONLY"
elif [[ "$ONLY" == "l2-articles" ]]; then
  [[ -d "$ARTICLES_DIR" ]] || { echo "Error: l2-articles directory not found: $ARTICLES_DIR"; exit 1; }
  for SILO_DIR in "$ARTICLES_DIR"/*/; do
    publish_silo "$(basename "$SILO_DIR")"
  done
else
  # Treat as a specific silo name
  [[ -d "$ARTICLES_DIR" ]] || { echo "Error: l2-articles directory not found: $ARTICLES_DIR"; exit 1; }
  publish_silo "$ONLY"
fi

echo ""
echo "========================================================="
echo "  Done — Created: $COUNT_CREATED  |  Updated: $COUNT_UPDATED  |  Failed: $COUNT_FAILED"
echo "========================================================="

[[ $COUNT_FAILED -eq 0 ]] || exit 1
