#!/usr/bin/env zsh
set -euo pipefail
setopt extendedglob

# ── batch-md-to-html.sh ─────────────────────────────────────────────────────
# Parallel batch converts all markdown files in input/<site-slug>/ to HTML.
# Runs up to 4 workers simultaneously using md-to-html.sh.
#
# Usage:
#   ./scripts/content/batch-md-to-html.sh <site-slug> [--force]
#
# Input:  input/<site-slug>/{tickets-and-tours,tickets-tours,plan-your-visit,what-to-see}/*.md
# Output: output/<site-slug>/l2-articles/<silo>/<slug>.html
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--force]"
  exit 1
fi

SITE_SLUG="$1"
shift

FORCE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_FLAG="--force"; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INPUT_DIR="$REPO_ROOT/input/$SITE_SLUG"
MD_TO_HTML="$SCRIPT_DIR/md-to-html.sh"
MAX_WORKERS=4

[[ -f "$MD_TO_HTML" ]] || { echo "Error: md-to-html.sh not found: $MD_TO_HTML"; exit 1; }
[[ -d "$INPUT_DIR" ]]  || { echo "Error: Input directory not found: $INPUT_DIR"; exit 1; }

echo "========================================================="
echo "  Batch MD→HTML (parallel, $MAX_WORKERS workers) — $SITE_SLUG"
echo "  Input:  $INPUT_DIR"
echo "  Force:  ${FORCE_FLAG:-no}"
echo "========================================================="

# ── Collect all MD files across all silos ────────────────────────────────────
ALL_MD_FILES=()
SKIP_COUNT=0

for SILO in tickets-and-tours tickets-tours plan-your-visit what-to-see; do
  SILO_DIR="$INPUT_DIR/$SILO"
  [[ -d "$SILO_DIR" ]] || continue

  OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l2-articles/$SILO"
  mkdir -p "$OUTPUT_DIR"

  for MD_FILE in "$SILO_DIR"/*.md(N); do
    [[ -f "$MD_FILE" ]] || continue
    BASENAME=$(basename "$MD_FILE" .md)
    SLUG=$(echo "$BASENAME" | sed 's/^article-[0-9]*-//; s/^article[0-9]*_//; s/^[0-9]*-//')
    HTML_OUT="$OUTPUT_DIR/${SLUG}.html"

    if [[ -f "$HTML_OUT" && "$FORCE_FLAG" != "--force" ]]; then
      echo "  ⏭  $SILO/$SLUG (already exists)"
      SKIP_COUNT=$(( SKIP_COUNT + 1 ))
    else
      ALL_MD_FILES+=("$MD_FILE")
    fi
  done
done

TOTAL=${#ALL_MD_FILES[@]}
echo ""
if [[ $TOTAL -gt 0 ]]; then
  echo "  Will convert ($TOTAL files):"
  for _f in "${ALL_MD_FILES[@]}"; do
    _silo=$(basename "$(dirname "$_f")")
    echo "    → $_silo/$(basename "$_f" .md)"
  done
  echo "  Skipped: $SKIP_COUNT (already exist)"
  echo ""
else
  echo "  Nothing to convert. Skipped: $SKIP_COUNT (already exist)"
  exit 0
fi

# ── Run parallel workers ─────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d /tmp/batch-md-XXXXXX)
STARTED=0

# Semaphore: count active workers via exit-file presence
active_count() {
  local running=0
  for MD_FILE in "${ALL_MD_FILES[@]:0:$STARTED}"; do
    BASENAME=$(basename "$MD_FILE" .md)
    SLUG=$(echo "$BASENAME" | sed 's/^article-[0-9]*-//; s/^article[0-9]*_//; s/^[0-9]*-//')
    SILO=$(basename "$(dirname "$MD_FILE")")
    [[ -f "$WORK_DIR/${SILO}__${SLUG}.exit" ]] || running=$(( running + 1 ))
  done
  echo "$running"
}

for MD_FILE in "${ALL_MD_FILES[@]}"; do
  BASENAME=$(basename "$MD_FILE" .md)
  SLUG=$(echo "$BASENAME" | sed 's/^article-[0-9]*-//; s/^article[0-9]*_//; s/^[0-9]*-//')
  SILO=$(basename "$(dirname "$MD_FILE")")
  LOG_FILE="$WORK_DIR/${SILO}__${SLUG}.log"
  EXIT_FILE="$WORK_DIR/${SILO}__${SLUG}.exit"

  # Wait until a worker slot is free
  _WAIT_SECS=0
  while [[ $(active_count) -ge $MAX_WORKERS ]]; do
    sleep 2
    _WAIT_SECS=$(( _WAIT_SECS + 2 ))
    [[ $(( _WAIT_SECS % 10 )) -eq 0 ]] && printf "    ⏳ %ds — waiting for worker slot (%d/%d active)...\n" "$_WAIT_SECS" "$(active_count)" "$MAX_WORKERS"
  done

  STARTED=$(( STARTED + 1 ))
  echo "  [$STARTED/$TOTAL] Starting: $SILO/$SLUG"

  (
    set +e
    "$MD_TO_HTML" "$SITE_SLUG" "$MD_FILE" ${FORCE_FLAG:+$FORCE_FLAG} > "$LOG_FILE" 2>&1
    echo $? > "$EXIT_FILE"
  ) &
done

# ── Wait with heartbeat ─────────────────────────────────────────────────────
echo ""
_HB_START=$SECONDS
while true; do
  DONE_COUNT=0
  for MD_FILE in "${ALL_MD_FILES[@]}"; do
    BASENAME=$(basename "$MD_FILE" .md)
    SLUG=$(echo "$BASENAME" | sed 's/^article-[0-9]*-//; s/^article[0-9]*_//; s/^[0-9]*-//')
    SILO=$(basename "$(dirname "$MD_FILE")")
    [[ -f "$WORK_DIR/${SILO}__${SLUG}.exit" ]] && DONE_COUNT=$(( DONE_COUNT + 1 ))
  done
  if [[ $DONE_COUNT -ge $TOTAL ]]; then
    break
  fi
  printf "    ⏱  %ds — %d/%d complete\n" "$(( SECONDS - _HB_START ))" "$DONE_COUNT" "$TOTAL"
  sleep 10
done
printf "    ✓ All %d conversions finished in %ds\n" "$TOTAL" "$(( SECONDS - _HB_START ))"

# Reap all background workers
wait 2>/dev/null || true

# ── Results ──────────────────────────────────────────────────────────────────
COUNT_CONVERTED=0
COUNT_FAILED=0
echo ""
for MD_FILE in "${ALL_MD_FILES[@]}"; do
  BASENAME=$(basename "$MD_FILE" .md)
  SLUG=$(echo "$BASENAME" | sed 's/^article-[0-9]*-//; s/^article[0-9]*_//; s/^[0-9]*-//')
  SILO=$(basename "$(dirname "$MD_FILE")")
  EXIT_CODE=$(cat "$WORK_DIR/${SILO}__${SLUG}.exit" 2>/dev/null || echo "1")
  OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l2-articles/$SILO"
  if [[ "$EXIT_CODE" == "0" ]]; then
    SIZE=$(wc -c < "$OUTPUT_DIR/${SLUG}.html" 2>/dev/null | tr -d ' ')
    echo "  ✓ $SILO/$SLUG ($SIZE bytes)"
    COUNT_CONVERTED=$(( COUNT_CONVERTED + 1 ))
  else
    echo "  ✗ $SILO/$SLUG FAILED"
    tail -5 "$WORK_DIR/${SILO}__${SLUG}.log" 2>/dev/null | sed 's/^/    /'
    COUNT_FAILED=$(( COUNT_FAILED + 1 ))
  fi
done

rm -rf "$WORK_DIR"

echo ""
echo "========================================================="
echo "  Done — Converted: $COUNT_CONVERTED  |  Skipped: $SKIP_COUNT  |  Failed: $COUNT_FAILED"
echo "========================================================="

[[ $COUNT_FAILED -eq 0 ]] || exit 1
