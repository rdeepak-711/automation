#!/usr/bin/env zsh
set -euo pipefail
# ── Phase 2: HTML Generation ──────────────────────────────────────────────────
# Generates all HTML from MD articles + configs, validates links.
#
# Usage: ./scripts/phase2.sh <site-slug> [--force]
#
# Steps:
#   0a. Standardize XLSX (if not already done)
#   0b. Convert tickets.docx → tickets.md (if not present)
#   0c. Split Articles/ into silo folders (if Articles/ exists)
#   0d. Populate tickets array in homepage-config.json (from tickets.md)
#   0e. Generate homepage-config.json + l1-config.json (if missing)
#   1. Build URL registry from XLSX
#   2. Convert all L2 MD articles to HTML (parallel workers)
#   3. Generate L1 hub pages
#   4. Generate homepage
#   5. Validate all internal links (gate: exits 1 if errors found)
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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "Error: .env not found at $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# Load site-specific .env overrides
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
if [[ -f "$SITE_ENV" ]]; then
  set -a; source "$SITE_ENV"; set +a
  echo "  ✓ Loaded per-site config: input/$SITE_SLUG/.env"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Phase 2 — HTML Generation: $SITE_SLUG"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 0a: Standardize XLSX ─────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0a — Standardize XLSX"
echo "────────────────────────────────────────────────────────────────────────────"
_XLSX=$(echo "$REPO_ROOT/input/$SITE_SLUG/"*.xlsx 2>/dev/null | grep -v '\.bak' | head -1)
if [[ -f "$_XLSX" ]]; then
  python3 "$SCRIPT_DIR/content/standardize-xlsx.py" "$_XLSX" \
    || { echo "  ✗ Failed to standardize XLSX"; exit 1; }
  echo "  ✓ XLSX standardized"
else
  echo "  ⚠ No XLSX found — skipping"
fi

# ── Step 0b: Convert tickets.docx → tickets.md ───────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0b — Convert tickets.docx → tickets.md"
echo "────────────────────────────────────────────────────────────────────────────"
_TICKETS_MD="$REPO_ROOT/input/$SITE_SLUG/tickets.md"
_TICKETS_DOCX=$(echo "$REPO_ROOT/input/$SITE_SLUG/"*[Tt]ickets*.docx 2>/dev/null | head -1)
if [[ -f "$_TICKETS_MD" ]]; then
  echo "  ⏭  tickets.md already exists — skipping (use --force to regenerate)"
elif [[ -f "$_TICKETS_DOCX" ]]; then
  "$SCRIPT_DIR/content/docx-to-tickets.sh" "$SITE_SLUG" \
    || { echo "  ✗ Failed to convert tickets.docx"; exit 1; }
  echo "  ✓ tickets.md generated"
else
  echo "  ⚠ No tickets.docx found and no tickets.md — skipping"
fi

# ── Step 0c: Split articles into silo folders ─────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0c — Split articles into silo folders"
echo "────────────────────────────────────────────────────────────────────────────"
_ARTICLES_DIR=""
for _d in "$REPO_ROOT/input/$SITE_SLUG/Articles" "$REPO_ROOT/input/$SITE_SLUG/articles"; do
  [[ -d "$_d" ]] && { _ARTICLES_DIR="$_d"; break; }
done
if [[ -n "$_ARTICLES_DIR" && -n "$(ls "$_ARTICLES_DIR"/*.md 2>/dev/null)" ]]; then
  # Rename article-NN-slug.md → articleN_slug.md if needed
  _renamed=0
  for _f in "$_ARTICLES_DIR"/article-*.md; do
    [[ -f "$_f" ]] || continue
    _base=$(basename "$_f")
    _num=$(echo "$_base" | sed -E 's/article-0*([0-9]+)-.*/\1/')
    _rest=$(echo "$_base" | sed -E 's/article-0*[0-9]+-//')
    _new="article${_num}_${_rest}"
    mv "$_f" "$_ARTICLES_DIR/$_new"
    (( _renamed++ )) || true
  done
  [[ $_renamed -gt 0 ]] && echo "  ✓ Renamed $_renamed files to article{N}_slug.md format"
  "$SCRIPT_DIR/content/split-articles-to-silos.sh" "$SITE_SLUG" \
    || { echo "  ✗ Failed to split articles"; exit 1; }
  echo "  ✓ Articles split into silos"
else
  echo "  ⏭  No Articles/ folder or already empty — skipping"
fi

# ── Step 0d: Populate tickets array in homepage-config.json ──────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0d — Populate tickets array"
echo "────────────────────────────────────────────────────────────────────────────"
_HP_JSON="$REPO_ROOT/input/$SITE_SLUG/homepage-config.json"
if [[ ! -f "$_TICKETS_MD" ]]; then
  echo "  ⚠ tickets.md missing — skipping"
else
  "$SCRIPT_DIR/content/populate-tickets.sh" "$SITE_SLUG" \
    || { echo "  ✗ Failed to populate tickets"; exit 1; }
  echo "  ✓ Tickets array populated"
fi

# ── Step 0e: Generate homepage-config.json and l1-config.json ────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0e — Generate config JSONs (homepage + L1)"
echo "────────────────────────────────────────────────────────────────────────────"
_L1_JSON="$REPO_ROOT/input/$SITE_SLUG/l1-config.json"
if [[ -f "$_HP_JSON" && -f "$_L1_JSON" ]]; then
  echo "  ⏭  homepage-config.json and l1-config.json already exist — skipping"
elif [[ ! -f "$_TICKETS_MD" ]]; then
  echo "  ⚠ tickets.md missing — cannot generate configs. Create it manually first."
else
  "$SCRIPT_DIR/content/generate-configs.sh" "$SITE_SLUG" \
    || { echo "  ✗ Failed to generate config JSONs"; exit 1; }
  echo "  ✓ Config JSONs generated"
fi

# ── Step 1: Build URL registry ────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 1 — Build URL registry"
echo "────────────────────────────────────────────────────────────────────────────"
python3 "$SCRIPT_DIR/content/build-url-registry.py" "$SITE_SLUG" \
  || { echo "  ✗ Failed to build URL registry"; exit 1; }
echo "  ✓ URL registry built"

# ── Step 2: Convert all L2 MD articles to HTML ───────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 2 — Convert MD articles to HTML (all silos)"
echo "────────────────────────────────────────────────────────────────────────────"
"$SCRIPT_DIR/content/batch-md-to-html.sh" "$SITE_SLUG" ${FORCE_FLAG:+$FORCE_FLAG} \
  || { echo "  ✗ batch-md-to-html.sh failed"; exit 1; }

# ── Step 3: Generate L1 hub pages ────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 3 — Generate L1 hub pages"
echo "────────────────────────────────────────────────────────────────────────────"
"$SCRIPT_DIR/content/generate-l1-pages.sh" "$SITE_SLUG" \
  || { echo "  ✗ generate-l1-pages.sh failed"; exit 1; }
echo "  ✓ L1 hub pages generated"

# ── Step 4: Generate homepage ────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 4 — Generate homepage"
echo "────────────────────────────────────────────────────────────────────────────"
"$SCRIPT_DIR/content/generate-homepage.sh" "$SITE_SLUG" \
  || { echo "  ✗ generate-homepage.sh failed"; exit 1; }
echo "  ✓ Homepage generated"

# ── Step 5: Validate internal links (gate) ───────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 5 — Validate internal links"
echo "────────────────────────────────────────────────────────────────────────────"
python3 "$SCRIPT_DIR/content/validate-links.py" "$SITE_SLUG"
if [[ $? -ne 0 ]]; then
  echo ""
  echo "  ✗ Link validation failed. Fix broken links before publishing."
  echo "  Tip: run 'python3 scripts/content/validate-links.py $SITE_SLUG' for full report"
  exit 1
fi
echo "  ✓ All internal links valid"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  ✓ Phase 2 complete — HTML generation done for: $SITE_SLUG"
echo "  Next: ./scripts/phase3.sh $SITE_SLUG"
echo "════════════════════════════════════════════════════════════════════════════"
