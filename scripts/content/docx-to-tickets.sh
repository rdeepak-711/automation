#!/usr/bin/env zsh
set -euo pipefail

# ── docx-to-tickets.sh ────────────────────────────────────────────────────────
# Converts a tickets.docx file to tickets.md using Claude CLI.
# Extracts raw text from the docx, passes to Claude with a strict prompt,
# Claude outputs the T1 | Title | URL | ref | /slug/ rows directly.
#
# Output tickets.md format:
#   T1 | Title | URL | GYG t12345 / Viator / Tiqets p12345 | /tickets/<slug>/
#
# Usage:
#   ./scripts/content/docx-to-tickets.sh <site-slug> [--force]
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug> [--force]"; exit 1; }

SITE_SLUG="$1"
FORCE=false
[[ "${2:-}" == "--force" ]] && FORCE=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOCX="$REPO_ROOT/input/$SITE_SLUG/tickets.docx"
OUTPUT="$REPO_ROOT/input/$SITE_SLUG/tickets.md"

[[ -f "$DOCX" ]] || { echo "Error: tickets.docx not found: $DOCX"; exit 1; }

if [[ "$FORCE" == "false" && -f "$OUTPUT" ]]; then
  echo "  tickets.md already exists. Use --force to regenerate."
  exit 0
fi

echo "========================================================="
echo "  docx → tickets.md — $SITE_SLUG"
echo "  Input:  $DOCX"
echo "  Output: $OUTPUT"
echo "========================================================="

# Extract raw text from docx (paragraphs + tables), preserving line order
RAW_TEXT=$(python3 - "$DOCX" << 'PYEOF'
import sys
import docx

try:
    doc = docx.Document(sys.argv[1])
except Exception as e:
    print(f"ERROR: Cannot open {sys.argv[1]}: {e}", file=sys.stderr)
    print("  The file may be corrupt, an old .doc format, or not a valid .docx file.", file=sys.stderr)
    print("  Fix: open in Word and re-save as File → Save As → .docx", file=sys.stderr)
    sys.exit(1)

lines = []

# Paragraphs — split on soft returns within each paragraph
for p in doc.paragraphs:
    for line in p.text.split('\n'):
        line = line.strip()
        if line:
            lines.append(line)

# Tables
for table in doc.tables:
    for row in table.rows:
        for cell in row.cells:
            text = cell.text.strip()
            if text:
                lines.append(text)

print('\n'.join(lines))
PYEOF
)

if [[ -z "$RAW_TEXT" ]]; then
  echo "  ✗ No text extracted from docx"
  exit 1
fi

SITE_TITLE=$(echo "$SITE_SLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')

PROMPT="You are converting a raw ticket list from a Word document into a structured markdown format.

Here is the raw text extracted from the docx:

${RAW_TEXT}

Output ONLY the ticket rows, one per line, in this exact format:
T1 | Title | URL | Partner ref | /tickets/slug/

Rules:
- Title: use the human-readable title from the docx (not the URL listing title). Preserve original capitalisation.
- URL: the full affiliate URL. Strip tracking query params (?ranking_uuid=, ?adults=, etc.) but keep the path.
- Partner ref: extract from the URL:
    - getyourguide.com → GYG t<number>  (e.g. GYG t422336)
    - tiqets.com       → Tiqets p<number>  (e.g. Tiqets p1121998)
    - viator.com       → Viator
- Slug: lowercase, hyphens, derived from the Title, max 60 chars
- Number tickets sequentially T1, T2, T3 ...
- Keep EVERY ticket line exactly as-is — never skip, never deduplicate, even if two tickets share the same URL or GYG tour ID
- Output nothing else — no header, no footer, no notes, no explanation, no blank lines"

echo "  Calling Claude CLI..."
SITE_HEADER="# ${SITE_TITLE} Tickets"

AI_ENGINE="${AI_ENGINE:-claude}"
if [[ "$AI_ENGINE" == "gemini" ]]; then
  ROWS=$(echo "$PROMPT" | gemini --model gemini-2.5-pro -p -)
else
  ROWS=$(echo "$PROMPT" | claude --print -)
fi

if [[ -z "$ROWS" ]]; then
  echo "  ✗ Claude returned empty output"
  exit 1
fi

ROWS_CLEAN=$(echo "$ROWS" | grep '^T[0-9]')

# Post-process: replace column 5 slugs with canonical XLSX slugs where titles match
ROWS_CLEAN=$(python3 - "$REPO_ROOT/input/$SITE_SLUG/" <<PYEOF
import sys, os, re, glob

base = sys.argv[1]
rows_raw = """$ROWS_CLEAN"""

# Load XLSX ticket article slugs (title → slug)
xlsx_files = [f for f in glob.glob(os.path.join(base, '*.xlsx')) if not f.endswith('.bak')]
xlsx_map = {}  # article_title_words → slug
if xlsx_files:
    try:
        import openpyxl
        wb = openpyxl.load_workbook(xlsx_files[0])
        in_tt = False
        for sheet in wb.worksheets:
            for row in sheet.iter_rows(values_only=True):
                c0 = str(row[0]).strip() if row[0] else ''
                if 'Tickets' in c0 and '\n' in c0:
                    in_tt = True
                elif '\n' in c0 and in_tt:
                    in_tt = False
                if not in_tt:
                    continue
                slug_cell = str(row[3]).strip() if len(row) > 3 and row[3] else ''
                title_cell = str(row[2]).strip() if len(row) > 2 and row[2] else ''
                if slug_cell.startswith('/tickets/') and title_cell and title_cell != 'Article Title':
                    leaf = slug_cell.strip('/').split('/')[-1]
                    xlsx_map[title_cell] = leaf
    except Exception as e:
        pass

def _words(text):
    stop = {'the','a','an','and','or','of','to','in','for','with','from','by','at','on','is','it','amp','prague','castle'}
    return set(w for w in re.sub(r'[^a-z\s]', '', text.lower()).split() if w not in stop and len(w) > 2)

def best_xlsx_slug(ticket_title, used):
    tw = _words(ticket_title)
    best_slug, best_score = None, 0
    for art_title, slug in xlsx_map.items():
        if slug in used:
            continue
        score = len(tw & _words(art_title))
        if score > best_score:
            best_score, best_slug = score, slug
    return best_slug if best_score >= 2 else None

# Deduplicate rows by URL (docx often has two tables with the same tickets)
seen_urls = set()
deduped = []
for line in rows_raw.strip().splitlines():
    if not line.strip() or not line.startswith('T'):
        continue
    parts = [p.strip() for p in line.split('|')]
    url = parts[2].split('?')[0].rstrip('/') if len(parts) >= 3 else ''
    if url and url not in seen_urls:
        seen_urls.add(url)
        deduped.append(parts)

# Renumber T1, T2, ... after dedup
for i, parts in enumerate(deduped, 1):
    parts[0] = f'T{i}'

# Replace column 5 slugs with canonical XLSX slugs (no collision)
fixed = 0
used_slugs = set()
out_rows = []
for parts in deduped:
    if len(parts) >= 5:
        title = parts[1]
        canonical = best_xlsx_slug(title, used_slugs)
        if canonical:
            used_slugs.add(canonical)
            old_slug = parts[4].strip('/').split('/')[-1]
            if old_slug != canonical:
                parts[4] = f' /tickets/{canonical}/'
                fixed += 1
    out_rows.append(' | '.join(parts))

if fixed:
    print(f"  ✓ {fixed} slug(s) corrected to match XLSX", file=sys.stderr)
print('\n'.join(out_rows))
PYEOF
)

{
  echo "$SITE_HEADER"
  echo ""
  echo "$ROWS_CLEAN"
} > "$OUTPUT"

COUNT=$(grep -c '^T[0-9]' "$OUTPUT" || true)
echo "  ✓ Written ${COUNT} tickets to tickets.md"
echo ""
grep '^T[0-9]' "$OUTPUT" | awk -F'|' '{printf "    %s |%s\n", $1, $2}'

echo ""
echo "========================================================="
echo "  Done — review input/$SITE_SLUG/tickets.md before proceeding"
echo "========================================================="
