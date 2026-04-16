#!/usr/bin/env zsh
set -euo pipefail

# ── split-articles-to-silos.sh ────────────────────────────────────────────────
# Reads the IA xlsx and copies articles from Articles/ into silo subfolders:
#   input/<site-slug>/plan-your-visit/
#   input/<site-slug>/what-to-see/
#   input/<site-slug>/tickets-tours/
#
# Matches by article number: article{N}_*.md → row N in xlsx → category slug
#
# Usage: ./scripts/content/split-articles-to-silos.sh <site-slug>
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug>"; exit 1; }

SITE_SLUG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INPUT_DIR="$SCRIPT_DIR/input/$SITE_SLUG"
ARTICLES_DIR=""
for _d in "$INPUT_DIR/Articles" "$INPUT_DIR/articles"; do
  [[ -d "$_d" ]] && { ARTICLES_DIR="$_d"; break; }
done
[[ -n "$ARTICLES_DIR" ]] || { echo "Error: Articles/ folder not found in $INPUT_DIR"; exit 1; }

XLSX=$(echo "$INPUT_DIR"/*.xlsx)
[[ -f "$XLSX" ]] || { echo "Error: No xlsx found in $INPUT_DIR"; exit 1; }

echo "========================================================="
echo "  Split Articles to Silos — $SITE_SLUG"
echo "  Source:  $ARTICLES_DIR"
echo "  IA:      $XLSX"
echo "========================================================="

python3 - "$ARTICLES_DIR" "$XLSX" "$INPUT_DIR" << 'PYEOF'
import sys, os, glob, shutil, openpyxl, re

articles_dir = sys.argv[1]
xlsx_path    = sys.argv[2]
input_dir    = sys.argv[3]

# ── Load xlsx: build map of sequential article number → silo ─────────────────
wb = openpyxl.load_workbook(xlsx_path)
ws = wb.active

def silo_from_url(url_slug):
    """Derive silo folder name from a URL slug like /tickets/foo/ or /plan-your-visit/foo/"""
    url_slug = str(url_slug).strip().lstrip('/')
    segment = url_slug.split('/')[0]
    mapping = {
        'tickets':       'tickets-tours',
        'tickets-tours': 'tickets-tours',
        'plan-your-visit': 'plan-your-visit',
        'what-to-see':   'what-to-see',
    }
    return mapping.get(segment, '')

def silo_from_category(cat):
    """Derive silo from a category string like 'Tickets & Tours\n/tickets/'"""
    cat = str(cat).lower()
    if 'ticket' in cat or 'tour' in cat:
        return 'tickets-tours'
    if 'plan' in cat:
        return 'plan-your-visit'
    if 'see' in cat or 'do' in cat:
        return 'what-to-see'
    return ''

num_to_silo = {}
seq = 0           # sequential article counter (matches article{N}_ filenames)
current_silo = '' # tracks active category across merged/blank rows

for row in ws.iter_rows(values_only=True):
    if not any(row):
        continue
    vals = [str(c).strip() if c else '' for c in row]

    # Header row — skip
    if vals[0] == '#':
        continue

    # Detect a category header cell (col 0 non-empty, looks like a silo name)
    if vals[0]:
        derived = silo_from_category(vals[0])
        if derived:
            current_silo = derived

    # Check if this row is an article row:
    # Standard format: col 1 has T/W/P prefix (T1, W2, etc.) or is a digit
    # Also try: col 3 has a URL slug
    col1, col3 = vals[1], vals[3] if len(vals) > 3 else ''

    is_article = bool(re.match(r'^[TWP]\d+$', col1) or re.match(r'^\d+$', col1))
    if not is_article and col3:
        is_article = col3.startswith('/')

    if not is_article:
        continue

    seq += 1

    # Prefer silo from URL slug (most reliable)
    silo = silo_from_url(col3) if col3.startswith('/') else ''
    if not silo:
        silo = current_silo

    num_to_silo[seq] = silo

# ── Create silo folders ───────────────────────────────────────────────────────
silos = {'plan-your-visit', 'what-to-see', 'tickets-tours'}
for silo in silos:
    os.makedirs(os.path.join(input_dir, silo), exist_ok=True)

# ── Copy each article to its silo ─────────────────────────────────────────────
files = sorted(glob.glob(os.path.join(articles_dir, 'article*.md')))
copied = 0
skipped = 0

for f in files:
    fname = os.path.basename(f)
    # Match both formats: article{N}_slug.md and article-{NN}-slug.md
    m = re.match(r'article(\d+)_', fname) or re.match(r'article-0*(\d+)-', fname)
    if not m:
        print(f"  ⚠ Skipping (no number): {fname}")
        skipped += 1
        continue

    num = int(m.group(1))
    silo = num_to_silo.get(num)
    if not silo:
        print(f"  ⚠ No silo found for article {num}: {fname}")
        skipped += 1
        continue

    # Normalize filename to article{N}_slug.md format
    if re.match(r'article-0*\d+-', fname):
        slug = re.sub(r'^article-0*\d+-', '', fname)
        fname = f"article{num}_{slug}"

    dest = os.path.join(input_dir, silo, fname)
    shutil.move(f, dest)
    print(f"  ✓ [{silo}] {fname}")
    copied += 1

# Remove Articles/ folder if empty
remaining = glob.glob(os.path.join(articles_dir, '*'))
if not remaining:
    os.rmdir(articles_dir)
    print(f"\n  ✓ Removed empty Articles/ folder.")
else:
    print(f"\n  ⚠ Articles/ not empty ({len(remaining)} files remain) — not removed.")

print(f"  Done — {copied} copied, {skipped} skipped.")
for silo in sorted(silos):
    count = len(glob.glob(os.path.join(input_dir, silo, '*.md')))
    print(f"    {silo}/: {count} articles")
PYEOF
