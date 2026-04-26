#!/usr/bin/env zsh
# content.sh — Phase 2: Content generation (Steps 16–23)
# Called from main.sh or directly: ./scripts/phases/content.sh
set -euo pipefail

PHASE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PHASE_SCRIPT_DIR/../.." && pwd)"
source "$PHASE_SCRIPT_DIR/common.sh"

CONTENT_SITE_SLUG="${CONTENT_SITE_SLUG:-}"
if [[ -z "$CONTENT_SITE_SLUG" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi

load_env "$CONTENT_SITE_SLUG"

SITE_HOST="${WP_SITE_URL:-default}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"
mkdir -p "$REPO_ROOT/state"
export STATE_FILE="$REPO_ROOT/state/.setup-state-${SITE_HOST}"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Content Phase — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"

_INPUT_DIR="$REPO_ROOT/input/$CONTENT_SITE_SLUG"

# ── Step 16: Convert tickets.docx → tickets.md ───────────────────────────────
if [[ -f "$_INPUT_DIR/tickets.docx" && ! -f "$_INPUT_DIR/tickets.md" ]]; then
  if prompt_step 16 "Convert tickets.docx → tickets.md" \
      "Parses tickets.docx and generates the tickets.md file needed for config generation." \
      "docx_to_tickets_done"; then
    "$REPO_ROOT/scripts/content/docx-to-tickets.sh" "$CONTENT_SITE_SLUG"
    echo "  Review input/$CONTENT_SITE_SLUG/tickets.md before continuing."
    mark_done "docx_to_tickets_done"
  else
    echo "  Skipped."
  fi
elif [[ -f "$_INPUT_DIR/tickets.md" ]]; then
  echo "  ✓ tickets.md already exists — skipping docx conversion."
fi

# ── Step 17: Generate Site Configs ───────────────────────────────────────────
if prompt_step 17 "Generate Site Configs" \
    "Generates homepage-config.json and l1-config.json from tickets.md via Claude." \
    "generate_configs_done"; then
  if [[ ! -f "$_INPUT_DIR/tickets.md" ]]; then
    echo "  ERROR: input/$CONTENT_SITE_SLUG/tickets.md not found."; exit 1
  fi
  "$REPO_ROOT/scripts/content/generate-configs.sh" "$CONTENT_SITE_SLUG" && mark_done "generate_configs_done"
else
  echo "  Skipped."
fi

# ── Step 18: Populate Tickets Array ──────────────────────────────────────────
if prompt_step 18 "Populate Tickets Array" \
    "Parses tickets.md and populates the tickets[] array in homepage-config.json." \
    "populate_tickets_done"; then
  if [[ ! -f "$_INPUT_DIR/homepage-config.json" ]]; then
    echo "  ERROR: homepage-config.json not found. Run Step 17 first."; exit 1
  fi
  "$REPO_ROOT/scripts/content/populate-tickets.sh" "$CONTENT_SITE_SLUG" && mark_done "populate_tickets_done"
else
  echo "  Skipped."
fi

# ── Step 19: Sample MD to HTML (1 per silo) ──────────────────────────────────
if prompt_step 19 "Sample MD to HTML (1 per silo)" \
    "Converts 1 article from each silo to HTML for verification before full batch." \
    "md_to_html_sample_done"; then
  _PIDS=(); _LOGS=()
  for silo in tickets-tours plan-your-visit what-to-see; do
    _FIRST=$(ls "$_INPUT_DIR/$silo/"*.md 2>/dev/null | head -1)
    if [[ -z "$_FIRST" ]]; then echo "  ⚠ No articles in $silo — skipping"; continue; fi
    _LOG=$(mktemp /tmp/md-sample-XXXXXX)
    _LOGS+=("$silo:$_LOG")
    echo "  → $silo: $(basename "$_FIRST")"
    "$REPO_ROOT/scripts/content/md-to-html.sh" "$CONTENT_SITE_SLUG" "$_FIRST" --force > "$_LOG" 2>&1 &
    _PIDS+=($!)
  done
  _HB_START=$SECONDS
  ( while true; do sleep 5; printf "    ⏱  %ds elapsed\n" "$(( SECONDS - _HB_START ))" >&2; done ) &
  _HB_PID=$!
  _SAMPLE_OK=true
  for pid in "${_PIDS[@]}"; do wait "$pid" || _SAMPLE_OK=false; done
  kill "$_HB_PID" 2>/dev/null; wait "$_HB_PID" 2>/dev/null || true
  for entry in "${_LOGS[@]}"; do
    echo ""; echo "  ── ${entry%%:*} ──"; cat "${entry##*:}"; rm -f "${entry##*:}"
  done
  if $_SAMPLE_OK; then
    mark_done "md_to_html_sample_done"
    echo "  ✓ Samples generated. Review output/$CONTENT_SITE_SLUG/l2-articles/ before continuing."
  else
    echo "  ✗ Some samples failed — fix before proceeding."; exit 1
  fi
else
  echo "  Skipped."
fi

# ── Step 20: Convert All MD to HTML ──────────────────────────────────────────
if prompt_step 20 "Convert All MD to HTML" \
    "Converts all markdown articles to HTML using the article template." \
    "md_to_html_done"; then
  "$REPO_ROOT/scripts/content/batch-md-to-html.sh" "$CONTENT_SITE_SLUG" && mark_done "md_to_html_done"
else
  echo "  Skipped."
fi

# ── Step 21: Build Article Metas ─────────────────────────────────────────────
if prompt_step 21 "Build Article Metas" \
    "Auto-generates article descriptions, card titles, tags, and bullets via Claude." \
    "build_article_metas_done"; then
  python3 "$REPO_ROOT/scripts/content/build-article-metas.py" "$CONTENT_SITE_SLUG" && mark_done "build_article_metas_done"
  echo "  Review output/$CONTENT_SITE_SLUG/article-metas.json before building L1."
else
  echo "  Skipped."
fi

# ── Step 22: Generate L1 Pages ───────────────────────────────────────────────
if prompt_step 22 "Generate L1 Pages" \
    "Builds 3 L1 category hub pages (Tickets & Tours, Plan Your Visit, What to See)." \
    "generate_l1_html_done"; then
  "$REPO_ROOT/scripts/content/l1/generate-plan-your-visit.sh" "$CONTENT_SITE_SLUG" --force
  "$REPO_ROOT/scripts/content/l1/generate-what-to-see.sh" "$CONTENT_SITE_SLUG" --force
  "$REPO_ROOT/scripts/content/l1/generate-tickets-tours.sh" "$CONTENT_SITE_SLUG" --force
  mark_done "generate_l1_html_done"
else
  echo "  Skipped."
fi

# ── Step 23: Generate Homepage ───────────────────────────────────────────────
if prompt_step 23 "Generate Homepage" \
    "Generates the homepage with ticket cards, highlights, tips, and FAQ from tickets.md." \
    "generate_homepage_done"; then
  "$REPO_ROOT/scripts/content/l1/generate-homepage.sh" "$CONTENT_SITE_SLUG" --force && mark_done "generate_homepage_done"
else
  echo "  Skipped."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Content phase complete — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"
