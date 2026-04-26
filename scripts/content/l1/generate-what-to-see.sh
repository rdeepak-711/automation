#!/usr/bin/env zsh
# generate-l1-what-to-see.sh — Generate L1 What to See page for a site.
#
# Usage:
#   ./scripts/content/generate-l1-what-to-see.sh <site-slug> [--force]
#
# Examples:
#   ./scripts/content/generate-l1-what-to-see.sh amsterdam-canal-cruise
#   ./scripts/content/generate-l1-what-to-see.sh museo-del-prado --force

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

# ── Args ──────────────────────────────────────────────────────────────────────
SITE_SLUG="${1:-}"
FORCE=""
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE="--force"
done

if [[ -z "$SITE_SLUG" ]]; then
  echo "Usage: $0 <site-slug> [--force]"
  exit 1
fi

# ── Load env ──────────────────────────────────────────────────────────────────
ROOT_ENV="$SCRIPT_DIR/.env"
SITE_ENV="$SCRIPT_DIR/input/$SITE_SLUG/.env"

[[ -f "$ROOT_ENV" ]] && { set -a; source "$ROOT_ENV"; set +a; }
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; echo "  ✓ Loaded $SITE_ENV"; }

# ── Check input dir ───────────────────────────────────────────────────────────
INPUT_DIR="$SCRIPT_DIR/input/$SITE_SLUG"
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: input/$SITE_SLUG/ not found"
  exit 1
fi

XLSX_COUNT=$(ls "$INPUT_DIR"/*.xlsx 2>/dev/null | wc -l | tr -d ' ')
if [[ "$XLSX_COUNT" -eq 0 ]]; then
  echo "Error: no .xlsx found in input/$SITE_SLUG/"
  exit 1
fi

L1_CONFIG="$INPUT_DIR/l1-config.json"
if [[ ! -f "$L1_CONFIG" ]]; then
  echo "Error: l1-config.json not found in input/$SITE_SLUG/"
  exit 1
fi

# ── Run assembler ─────────────────────────────────────────────────────────────
echo ""
echo "Generating L1 What to See page for: $SITE_SLUG"
echo "──────────────────────────────────────────────"

cd "$SCRIPT_DIR"
python3 -m scripts.content.l1.assembler.what_to_see "$SITE_SLUG" $FORCE

echo ""
echo "Output: output/$SITE_SLUG/l1-pages/what-to-see.html"
