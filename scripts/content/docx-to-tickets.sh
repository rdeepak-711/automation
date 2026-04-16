#!/usr/bin/env zsh
set -euo pipefail

# ── docx-to-tickets.sh ────────────────────────────────────────────────────────
# Converts a tickets.docx file to tickets.md format.
#
# tickets.docx format (one ticket per line, either):
#   URL - Title
#   Title - URL
#   URL | Title
#   Or just a URL (title extracted from URL path)
#
# Output tickets.md format:
#   T1 | Title | URL | GYG/Tiqets/Viator ref | /tickets/<slug>/
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

python3 - "$DOCX" "$OUTPUT" "$SITE_SLUG" << 'PYEOF'
import sys, re
import docx

DOCX_PATH, OUTPUT_PATH, SITE_SLUG = sys.argv[1], sys.argv[2], sys.argv[3]

def partner_ref(url):
    """Extract partner reference from URL."""
    if 'getyourguide.com' in url:
        m = re.search(r'-t(\d+)/?', url)
        return f"GYG t{m.group(1)}" if m else "GYG"
    elif 'tiqets.com' in url:
        m = re.search(r'-p(\d+)/?', url)
        return f"Tiqets p{m.group(1)}" if m else "Tiqets"
    elif 'viator.com' in url:
        m = re.search(r'/([A-Z0-9]+-\d+[A-Z]\d+)/?', url)
        return f"Viator {m.group(1)}" if m else "Viator"
    return "Partner"

def title_to_slug(title):
    """Convert title to URL slug."""
    slug = title.lower().strip()
    slug = re.sub(r'[^\w\s-]', '', slug)
    slug = re.sub(r'[\s_]+', '-', slug)
    slug = re.sub(r'-+', '-', slug).strip('-')
    return slug[:60]

def parse_line(line):
    """Parse a line into (title, url). Handles: URL - Title, Title - URL, URL | Title."""
    line = line.strip()
    if not line:
        return None

    # Find URL in line
    url_match = re.search(r'https?://\S+', line)
    if not url_match:
        return None

    url = url_match.group(0).rstrip('.,)')
    rest = line.replace(url, '').strip(' -|').strip()

    if rest:
        title = rest.title() if rest == rest.lower() else rest
    else:
        # Derive title from URL path
        path = re.sub(r'https?://[^/]+', '', url).strip('/')
        parts = path.split('/')
        slug_part = parts[-1] if parts[-1] else (parts[-2] if len(parts) > 1 else parts[0])
        slug_part = re.sub(r'-t\d+$', '', slug_part)
        title = slug_part.replace('-', ' ').title()

    return title.strip(), url.strip()

doc = docx.Document(DOCX_PATH)
tickets = []

# Extract from paragraphs
for para in doc.paragraphs:
    result = parse_line(para.text)
    if result:
        tickets.append(result)

# Extract from tables if any
for table in doc.tables:
    for row in table.rows:
        for cell in row.cells:
            result = parse_line(cell.text)
            if result and result not in tickets:
                tickets.append(result)

if not tickets:
    print("  ✗ No ticket URLs found in docx")
    sys.exit(1)

# Determine silo base path from site slug
# tickets always go under /tickets/
lines = []
for i, (title, url) in enumerate(tickets, 1):
    ref = partner_ref(url)
    slug = title_to_slug(title)
    l2 = f"/tickets/{slug}/"
    lines.append(f"T{i} | {title} | {url} | {ref} | {l2}")

with open(OUTPUT_PATH, 'w') as f:
    f.write(f"# {SITE_SLUG.replace('-', ' ').title()} Tickets\n\n")
    f.write('\n'.join(lines) + '\n')

print(f"  ✓ Written {len(tickets)} tickets to tickets.md")
for i, (title, url) in enumerate(tickets, 1):
    print(f"    T{i}: {title[:60]}")
PYEOF

echo ""
echo "========================================================="
echo "  Done — review input/$SITE_SLUG/tickets.md before proceeding"
echo "========================================================="
