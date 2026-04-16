#!/usr/bin/env zsh
set -euo pipefail

# ── inject-cta.sh ───────────────────────────────────────────────────────────
# Injects CTA button into tickets-tours HTML articles.
# Places after What's Included / Covers section, or fallback placement.
# Skips articles that already have a CTA button.
#
# Usage:
#   ./scripts/content/inject-cta.sh <site-slug>
#   ./scripts/content/inject-cta.sh <site-slug> --force
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug> [--force]"; exit 1; }

SITE_SLUG="$1"; shift
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

INPUT_DIR="$REPO_ROOT/input/$SITE_SLUG"
OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l2-articles"
TICKETS_MD="$INPUT_DIR/tickets.md"

[[ ! -f "$TICKETS_MD" ]] && { echo "Error: tickets.md not found"; exit 1; }

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Inject CTA Buttons — $SITE_SLUG (tickets-tours only)"
echo "════════════════════════════════════════════════════════════════"

injected=0
skipped=0

for md_file in "$INPUT_DIR/tickets-tours"/*.md; do
  [[ ! -f "$md_file" ]] && continue

  slug=$(basename "$md_file" .md | sed 's/^article[0-9]*_//')
  html_file="$OUTPUT_DIR/tickets-tours/$slug.html"
  [[ ! -f "$html_file" ]] && { echo "  ⚠  $slug — no HTML"; continue; }

  # Skip if CTA exists
  has_cta=$(grep -c '<a[^>]*att-buy-now-btn' "$html_file" 2>/dev/null || true)
  has_cta=$(echo "$has_cta" | tr -d '[:space:]')
  if [[ "$has_cta" -gt 0 && "$FORCE" == "false" ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  python3 - "$html_file" "$md_file" "$TICKETS_MD" "${CAMPAIGN_PREFIX:-$SITE_SLUG}" "$slug" "${TOP_TICKET_INDEXES:-1,2}" << 'PYEOF'
import sys, re, json
from urllib.parse import urlparse, urlencode, parse_qs, urlunparse

html_path, md_path, tickets_path, campaign_prefix, slug, indexes_str = sys.argv[1:]

content = open(html_path, encoding='utf-8').read()
md = open(md_path, encoding='utf-8').read()

# Strip existing CTA buttons if --force
content = re.sub(r'\s*<a[^>]*class="att-buy-now-btn"[^>]*>.*?</a>\s*', '', content, flags=re.DOTALL)

# Parse tickets.md
tickets = []
for line in open(tickets_path):
    line = line.strip()
    m = re.match(r'T(\d+)', line)
    if not m: continue
    parts = [p.strip() for p in line.split('|')]
    if len(parts) >= 3:
        tickets.append({'idx': int(m.group(1)), 'title': parts[1], 'url': parts[2]})

def aff_url(raw_url, cmp_id):
    parsed = urlparse(raw_url)
    host = parsed.hostname or ''
    params = {}
    if 'getyourguide.com' in host:
        params = {'partner_id': '9BAL9K3', 'cmp': cmp_id}
    elif 'viator.com' in host:
        params = {'pid': 'P00038490', 'mcid': '42383', 'medium': 'link', 'campaign': cmp_id}
    elif 'tiqets.com' in host:
        params = {'partner': 'thebettervacation', 'tq_campaign': cmp_id}
    q = urlencode(params)
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, '', q, ''))

# Get article title
title_m = re.search(r'^# (.+)', md, re.MULTILINE)
title = title_m.group(1).strip() if title_m else slug

# Classify
t_lower = title.lower()
if 'combo' in t_lower:
    btn_label = 'Book This Combo'
elif any(w in t_lower for w in ['tour', 'trip', 'photoshoot', 'experience', 'zipline', 'bike', 'camel', 'horse', 'show']):
    btn_label = 'Book This Tour'
elif any(w in t_lower for w in ['ticket', 'pass', 'admission', 'entry']):
    btn_label = 'Buy This Ticket'
else:
    btn_label = 'Book This Tour'

# Find matching ticket URL
cmp_id = f"{campaign_prefix}-{slug}"
self_ticket = None

# Try SEO title match
seo_m = re.search(r'^\*\*SEO Title:\*\*\s*(.+)', md, re.MULTILINE)
article_title = seo_m.group(1).strip().lower() if seo_m else title.lower()

for t in tickets:
    tt = t['title'].lower().strip()
    if article_title == tt or article_title in tt or tt in article_title:
        self_ticket = t
        break

if self_ticket:
    url = aff_url(self_ticket['url'], cmp_id)
else:
    # Use first core ticket
    core_idxs = [int(i.strip()) for i in indexes_str.split(',') if i.strip().isdigit()]
    core = [t for t in tickets if t['idx'] in core_idxs]
    url = aff_url(core[0]['url'], cmp_id) if core else None

if not url:
    sys.exit(1)

btn_html = (
    f'\n      <a\n        href="{url}"\n        class="att-buy-now-btn"\n'
    f'        rel="nofollow sponsored"\n        target="_blank"\n'
    f'      >{btn_label}</a>\n'
)

# Placement priority
# 1. After What's Included / Covers / Typically Included section </ul>
pattern1 = r"(<h2[^>]*>(?:What(?:&rsquo;|'|&#8217;|\u2019)?s (?:Included|Typically Included)|What the .+? (?:Covers|Includes)|Included in .+?)[^<]*</h2>.*?</ul>)"
m = re.search(pattern1, content, re.DOTALL | re.IGNORECASE)

inserted = False
if m:
    insert_pos = m.end()
    content = content[:insert_pos] + btn_html + content[insert_pos:]
    inserted = True
else:
    # 2. Fallback: after first H2 section (section right after top tickets)
    # Find first <h2> in article body, then find end of that section (next <h2> or <div class="att-faq">)
    body_start = content.find('att-article-body')
    if body_start >= 0:
        first_h2 = re.search(r'<h2[^>]*>[^<]+</h2>', content[body_start:])
        if first_h2:
            abs_start = body_start + first_h2.end()
            # Find next H2 or FAQ div
            next_section = re.search(r'\s*(?=<h2|<div class="att-faq")', content[abs_start:])
            if next_section:
                insert_pos = abs_start + next_section.start()
                content = content[:insert_pos] + btn_html + content[insert_pos:]
                inserted = True

if inserted:
    open(html_path, 'w').write(content)
    print(f'  ✓ {slug}: "{btn_label}"')
else:
    print(f'  ✗ {slug}: no insertion point found')
    sys.exit(1)
PYEOF

  injected=$((injected + 1))
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Done: $injected injected | $skipped skipped (already have CTA)"
echo "════════════════════════════════════════════════════════════════"
