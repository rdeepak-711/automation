#!/usr/bin/env zsh
set -euo pipefail

# ── htmlpush.sh ───────────────────────────────────────────────────────────────
# Two-step pipeline: convert a folder of .md files to HTML, then push to WP.
#
# Usage:
#   ./htmlpush.sh <md-folder> [--force]
#
# Examples:
#   ./htmlpush.sh input/auschwitz/plan-your-visit/
#   ./htmlpush.sh input/auschwitz/tickets-tours/ --force
#
# The folder must follow the path pattern: input/<site-slug>/<silo>/
# Outputs HTML to: output/<site-slug>/l2-articles/<silo>/
# Publishes only the HTML files produced in this run (not the full site).
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <md-folder> [--force] [--update]"
  echo "  --force   Reconvert MD→HTML even if HTML already exists"
  echo "  --update  Update existing WordPress posts (default: create only)"
  echo "  e.g. $0 input/auschwitz/plan-your-visit/"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MD_DIR="${1%/}"   # strip trailing slash
shift

FORCE_FLAG=""
UPDATE_FLAG=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE_FLAG="--force"; shift ;;
    --update) UPDATE_FLAG=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "Error: .env not found"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# ── Derive site-slug and silo from path ───────────────────────────────────────
# Expected: input/<site-slug>/<silo>
RELATIVE="${MD_DIR#$SCRIPT_DIR/}"
RELATIVE="${RELATIVE#input/}"
SITE_SLUG="${RELATIVE%%/*}"
SILO="${RELATIVE#*/}"
SILO="${SILO%%/*}"

[[ -n "$SITE_SLUG" ]] || { echo "Error: could not derive site-slug from path: $MD_DIR"; exit 1; }
[[ -n "$SILO" ]]      || { echo "Error: could not derive silo from path: $MD_DIR"; exit 1; }

case "$SILO" in
  tickets-and-tours|tickets-tours|plan-your-visit|what-to-see) ;;
  *) echo "Error: unrecognised silo '$SILO' (expected tickets-tours, plan-your-visit, or what-to-see)"; exit 1 ;;
esac

[[ -d "$MD_DIR" ]] || { echo "Error: folder not found: $MD_DIR"; exit 1; }

MD_TO_HTML="$SCRIPT_DIR/scripts/content/md-to-html-v2.sh"
WP_POSTS_API="${WP_SITE_URL%/}/wp-json/wp/v2/posts"

# ── Ensure URL registry is built ──────────────────────────────────────────────
REGISTRY_FILE="$SCRIPT_DIR/output/$SITE_SLUG/url-registry.json"
if [[ ! -f "$REGISTRY_FILE" ]]; then
  echo "  Building URL registry..."
  python3 "$SCRIPT_DIR/scripts/content/build-url-registry.py" "$SITE_SLUG" \
    || { echo "  ✗ Failed to build URL registry"; exit 1; }
fi

echo "════════════════════════════════════════════════════════════════════════════"
echo "  htmlpush — $SITE_SLUG / $SILO"
echo "  Source:  $MD_DIR"
echo "  Site:    $WP_SITE_URL"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Pre-flight: WP auth ───────────────────────────────────────────────────────
echo ""
echo "  Verifying WordPress auth..."
AUTH_CHECK=$(curl -s --connect-timeout 10 \
  -u "${WP_USER}:${WP_PASS}" \
  "${WP_SITE_URL%/}/wp-json/wp/v2/users/me" 2>&1) || true
AUTH_NAME=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get('name', 'AUTH_FAILED'))
except:
    print('AUTH_FAILED')
" "$AUTH_CHECK" 2>/dev/null) || AUTH_NAME="AUTH_FAILED"

if [[ "$AUTH_NAME" == "AUTH_FAILED" ]]; then
  echo "  ✗ WordPress auth failed. Check WP_USER and WP_PASS in .env"
  exit 1
fi
echo "  ✓ Authenticated as: $AUTH_NAME"

# ── Step 1: Convert MD → HTML (parallel workers) ─────────────────────────────
MAX_WORKERS=4
OUTPUT_DIR="$SCRIPT_DIR/output/$SITE_SLUG/l2-articles/$SILO"

echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 1 of 2 — Convert MD → HTML (up to $MAX_WORKERS parallel workers)"
echo "────────────────────────────────────────────────────────────────────────────"

# Collect files that need conversion
MD_FILES=()
SKIP_COUNT=0
for MD_FILE in "$MD_DIR"/*.md(N); do
  [[ -f "$MD_FILE" ]] || continue
  BASENAME=$(basename "$MD_FILE" .md)
  SLUG="${BASENAME#[0-9][0-9]-}"
  HTML_OUT="$OUTPUT_DIR/${SLUG}.html"
  if [[ -f "$HTML_OUT" && "$FORCE_FLAG" != "--force" ]]; then
    echo "  ⏭  $SLUG (already exists)"
    SKIP_COUNT=$(( SKIP_COUNT + 1 ))
  else
    MD_FILES+=("$MD_FILE")
  fi
done

TOTAL=${#MD_FILES[@]}
echo ""
if [[ $TOTAL -gt 0 ]]; then
  echo "  Will convert ($TOTAL files):"
  for _f in "${MD_FILES[@]}"; do
    echo "    → $(basename "$_f" .md)"
  done
  echo "  Skipped: $SKIP_COUNT (already exist)"
  echo ""
else
  echo "  To convert: 0  |  Skipped: $SKIP_COUNT"
fi

if [[ $TOTAL -gt 0 ]]; then
  # Create a temp dir for worker logs and exit codes
  WORK_DIR=$(mktemp -d /tmp/htmlpush-XXXXXX)
  ACTIVE_PIDS=()
  STARTED=0

  for MD_FILE in "${MD_FILES[@]}"; do
    BASENAME=$(basename "$MD_FILE" .md)
    SLUG="${BASENAME#[0-9][0-9]-}"
    LOG_FILE="$WORK_DIR/${SLUG}.log"
    EXIT_FILE="$WORK_DIR/${SLUG}.exit"

    # Wait if we've hit max workers
    while [[ ${#ACTIVE_PIDS[@]} -ge $MAX_WORKERS ]]; do
      NEW_PIDS=()
      for pid in "${ACTIVE_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          NEW_PIDS+=("$pid")
        fi
      done
      ACTIVE_PIDS=("${NEW_PIDS[@]}")
      [[ ${#ACTIVE_PIDS[@]} -ge $MAX_WORKERS ]] && sleep 2
    done

    STARTED=$(( STARTED + 1 ))
    echo "  [$STARTED/$TOTAL] Starting: $SLUG"

    # Launch worker in background
    (
      "$MD_TO_HTML" "$SITE_SLUG" "$MD_FILE" ${FORCE_FLAG:+$FORCE_FLAG} > "$LOG_FILE" 2>&1
      echo $? > "$EXIT_FILE"
    ) &
    ACTIVE_PIDS+=($!)
  done

  # Wait for all workers with heartbeat showing progress
  echo ""
  _HB_START=$SECONDS
  while true; do
    # Count completed workers
    DONE_COUNT=0
    for _f in "${MD_FILES[@]}"; do
      _s="$(basename "$_f" .md)"
      _s="${_s#[0-9][0-9]-}"
      [[ -f "$WORK_DIR/${_s}.exit" ]] && DONE_COUNT=$(( DONE_COUNT + 1 ))
    done
    if [[ $DONE_COUNT -ge $TOTAL ]]; then
      break
    fi
    printf "    ⏱  %ds — %d/%d complete\n" "$(( SECONDS - _HB_START ))" "$DONE_COUNT" "$TOTAL"
    sleep 10
  done
  printf "    ✓ All %d conversions finished in %ds\n" "$TOTAL" "$(( SECONDS - _HB_START ))"
  # Reap background processes
  for pid in "${ACTIVE_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Collect results
  COUNT_CONVERTED=0
  COUNT_FAILED=0
  echo ""
  for MD_FILE in "${MD_FILES[@]}"; do
    BASENAME=$(basename "$MD_FILE" .md)
    SLUG="${BASENAME#[0-9][0-9]-}"
    EXIT_CODE=$(cat "$WORK_DIR/${SLUG}.exit" 2>/dev/null || echo "1")
    if [[ "$EXIT_CODE" == "0" ]]; then
      SIZE=$(wc -c < "$OUTPUT_DIR/${SLUG}.html" 2>/dev/null | tr -d ' ')
      echo "  ✓ $SLUG ($SIZE bytes)"
      COUNT_CONVERTED=$(( COUNT_CONVERTED + 1 ))
    else
      echo "  ✗ $SLUG FAILED"
      cat "$WORK_DIR/${SLUG}.log" | tail -5 | sed 's/^/    /'
      COUNT_FAILED=$(( COUNT_FAILED + 1 ))
    fi
  done

  rm -rf "$WORK_DIR"
  echo ""
  echo "  Converted: $COUNT_CONVERTED  |  Skipped: $SKIP_COUNT  |  Failed: $COUNT_FAILED"
else
  COUNT_FAILED=0
fi

# Collect all slugs that have HTML files (converted + previously existing)
CONVERTED_SLUGS=()
for MD_FILE in "$MD_DIR"/*.md(N); do
  [[ -f "$MD_FILE" ]] || continue
  BASENAME=$(basename "$MD_FILE" .md)
  SLUG="${BASENAME#[0-9][0-9]-}"
  [[ -f "$OUTPUT_DIR/${SLUG}.html" ]] && CONVERTED_SLUGS+=("$SLUG")
done

if [[ $COUNT_FAILED -gt 0 ]]; then
  echo "  ⚠  Some conversions failed — publishing successful ones only."
fi

# ── Step 1.5: Validate internal links ────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 1.5 — Validate internal links"
echo "────────────────────────────────────────────────────────────────────────────"
python3 "$SCRIPT_DIR/scripts/content/validate-links.py" "$SITE_SLUG" --silo "$SILO"
if [[ $? -ne 0 ]]; then
  echo ""
  echo "  ✗ Link validation failed. Fix broken links before publishing."
  echo "  Tip: run 'python3 scripts/content/validate-links.py $SITE_SLUG' for full report"
  exit 1
fi

if [[ ${#CONVERTED_SLUGS[@]} -eq 0 ]]; then
  echo "  No HTML files to publish."
  exit 0
fi

# ── Step 2: Publish to WordPress ──────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 2 of 2 — Publish to WordPress (${#CONVERTED_SLUGS[@]} articles)"
echo "────────────────────────────────────────────────────────────────────────────"

PUB_CREATED=0
PUB_UPDATED=0
PUB_FAILED=0

for SLUG in "${CONVERTED_SLUGS[@]}"; do
  HTML_FILE="$OUTPUT_DIR/${SLUG}.html"
  [[ -f "$HTML_FILE" ]] || { echo "  ⚠  Missing HTML for $SLUG — skipping"; continue; }

  echo ""
  echo "  ── $SILO/$SLUG"

  # Extract title from SEO comment block
  TITLE=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
m = re.search(r'<!--\s*SEO.*?title:\s*(.+?)[\r\n]', content, re.DOTALL | re.IGNORECASE)
print(m.group(1).strip() if m else '')
" "$HTML_FILE" 2>/dev/null) || TITLE=""
  [[ -z "$TITLE" ]] && TITLE="$SLUG"

  # Check if post with this slug already exists
  EXISTING=$(curl -s --connect-timeout 10 --max-time 30 \
    -u "${WP_USER}:${WP_PASS}" \
    "${WP_POSTS_API}?slug=${SLUG}&status=any&per_page=1" 2>/dev/null) || EXISTING="[]"

  EXISTING_ID=$(python3 -c "
import json, sys
posts = json.loads(sys.argv[1])
print(posts[0]['id'] if posts else '')
" "$EXISTING" 2>/dev/null) || EXISTING_ID=""

  # Build payload via temp file
  TMP_PAYLOAD=$(mktemp /tmp/wp-payload-XXXXXX.json)
  python3 - "$HTML_FILE" "$TITLE" "$SLUG" > "$TMP_PAYLOAD" 2>/dev/null << 'PYEOF'
import json, sys
html_file, title, slug = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(html_file).read()
wrapped = '<!-- wp:html -->\n' + content + '\n<!-- /wp:html -->'
print(json.dumps({'title': title, 'slug': slug, 'content': wrapped, 'status': 'draft'}))
PYEOF

  if [[ ! -s "$TMP_PAYLOAD" ]]; then
    echo "  ✗ Failed to build payload for: $SLUG"
    rm -f "$TMP_PAYLOAD"
    PUB_FAILED=$(( PUB_FAILED + 1 ))
    continue
  fi

  if [[ -n "$EXISTING_ID" ]]; then
    if [[ "$UPDATE_FLAG" != "true" ]]; then
      echo "  ⏭  Already exists (id=$EXISTING_ID) — use --update to overwrite"
      rm -f "$TMP_PAYLOAD"
      PUB_UPDATED=$(( PUB_UPDATED + 1 ))
      continue
    fi
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 \
      -X POST \
      -u "${WP_USER}:${WP_PASS}" \
      -H "Content-Type: application/json" \
      --data-binary "@${TMP_PAYLOAD}" \
      "${WP_POSTS_API}/${EXISTING_ID}" 2>/dev/null) || RESPONSE="{}"
    rm -f "$TMP_PAYLOAD"

    STATUS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('status', 'error'))
" "$RESPONSE" 2>/dev/null) || STATUS="error"

    if [[ "$STATUS" == "draft" || "$STATUS" == "publish" ]]; then
      echo "  ↺ Updated (id=$EXISTING_ID): $TITLE"
      PUB_UPDATED=$(( PUB_UPDATED + 1 ))
    else
      echo "  ✗ Update failed for: $SLUG"
      PUB_FAILED=$(( PUB_FAILED + 1 ))
    fi
  else
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 \
      -X POST \
      -u "${WP_USER}:${WP_PASS}" \
      -H "Content-Type: application/json" \
      --data-binary "@${TMP_PAYLOAD}" \
      "$WP_POSTS_API" 2>/dev/null) || RESPONSE="{}"
    rm -f "$TMP_PAYLOAD"

    NEW_ID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('id', ''))
" "$RESPONSE" 2>/dev/null) || NEW_ID=""

    if [[ -n "$NEW_ID" ]]; then
      echo "  ✓ Created (id=$NEW_ID): $TITLE"
      PUB_CREATED=$(( PUB_CREATED + 1 ))
    else
      echo "  ✗ Create failed for: $SLUG"
      echo "     Response: ${RESPONSE:0:200}"
      PUB_FAILED=$(( PUB_FAILED + 1 ))
    fi
  fi
done

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Done — Created: $PUB_CREATED  |  Updated: $PUB_UPDATED  |  Failed: $PUB_FAILED"
echo "════════════════════════════════════════════════════════════════════════════"

[[ $PUB_FAILED -eq 0 ]] || exit 1
