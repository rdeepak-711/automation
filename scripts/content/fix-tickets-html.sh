#!/usr/bin/env zsh
set -euo pipefail

# ── fix-tickets-html.sh ─────────────────────────────────────────────────────
# Fixes existing tickets-tours HTML articles:
#   1. Injects top tickets bar from MD (titles + links from MD, not tickets.md)
#   2. Injects CTA button (after What's Included or after first H2)
#   3. Rewrites absolute internal links to relative
#
# Usage:
#   ./scripts/content/fix-tickets-html.sh <site-slug>
#   ./scripts/content/fix-tickets-html.sh <site-slug> --slug entry-ticket
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug> [--slug <slug>]"; exit 1; }

SITE_SLUG="$1"; shift
FILTER_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) FILTER_SLUG="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

INPUT_DIR="$REPO_ROOT/input/$SITE_SLUG"
OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l2-articles/tickets-tours"
REGISTRY="$REPO_ROOT/output/$SITE_SLUG/url-registry.json"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Fix Tickets HTML — $SITE_SLUG"
echo "════════════════════════════════════════════════════════════════"

fixed=0

for md_file in "$INPUT_DIR/tickets-tours"/*.md; do
  [[ ! -f "$md_file" ]] && continue
  slug=$(basename "$md_file" .md | sed 's/^article[0-9]*_//')
  [[ -n "$FILTER_SLUG" && "$slug" != "$FILTER_SLUG" ]] && continue

  html_file="$OUTPUT_DIR/$slug.html"
  [[ ! -f "$html_file" ]] && { echo "  ⚠  $slug — no HTML"; continue; }

  python3 - "$html_file" "$md_file" "$REGISTRY" "$SITE_SLUG" "${CAMPAIGN_PREFIX:-$SITE_SLUG}" "$slug" << 'PYEOF'
import sys, re, json, os

html_path, md_path, registry_path, site_slug, campaign_prefix, slug = sys.argv[1:]
content = open(html_path, encoding='utf-8').read()
md = open(md_path, encoding='utf-8').read()

# ═══ 1. ABSOLUTE LINKS → RELATIVE ═══════════════════════════════════════════
if os.path.exists(registry_path):
    reg = json.load(open(registry_path))
    domain = reg.get('domain', '')
    if domain:
        content = re.sub(r'https://(?:www\.)?' + re.escape(domain) + r'(/[^"\'>\s]*)', r'\1', content)

# ═══ 2. TOP TICKETS BAR ═════════════════════════════════════════════════════
# Strip existing bar if any
content = re.sub(r'<div class="att-top-tickets">[\s\S]*?</ul>\s*</div>', '', content)
content = re.sub(r'\s*<!-- [─━]+ TOP TICKETS[^>]*-->\s*', '', content)

def fix_campaign(url, slug, suffix=''):
    """Rewrite campaign ID to {campaign_prefix}-{slug}{suffix}"""
    target_cmp = f"{campaign_prefix}-{slug}{suffix}"
    for param in ['cmp=', 'campaign=', 'tq_campaign=']:
        if param in url:
            url = re.sub(f'{param}[^&"]+', f'{param}{target_cmp}', url)
            return url
    # No campaign param — add one
    if 'getyourguide.com' in url:
        url += f'&cmp={target_cmp}' if '?' in url else f'?cmp={target_cmp}'
    elif 'viator.com' in url:
        url += f'&campaign={target_cmp}' if '?' in url else f'?campaign={target_cmp}'
    elif 'tiqets.com' in url:
        url += f'&tq_campaign={target_cmp}' if '?' in url else f'?tq_campaign={target_cmp}'
    return url

# Parse from MD
tt_match = re.search(r'## (Top Tickets|Book This Tour)\s*\n((?:- .+\n)*)', md)
if tt_match:
    tt_label = tt_match.group(1)
    tt_links = []
    for m in re.finditer(r'- \[(.+?)\]\((.+?)\)', tt_match.group(2)):
        title, url = m.group(1), m.group(2)
        url = fix_campaign(url, slug, '-top')
        tt_links.append((title, url))

    if tt_links:
        arrow = '<svg class="att-top-tickets__arrow" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6h7M6.5 3L9.5 6L6.5 9" /></svg>'
        lis = ''
        for title, url in tt_links:
            lis += f'          <li><a href="{url}" rel="nofollow sponsored" target="_blank">{title}{arrow}</a></li>\n'

        bar = f'''      <!-- ─── TOP TICKETS BAR ─── -->
      <div class="att-top-tickets">
        <p class="att-top-tickets__label">{tt_label}</p>
        <ul class="att-top-tickets__list">
{lis}        </ul>
      </div>
'''
        # Insert before first <h2> in article body
        body_start = content.find('att-article-body')
        if body_start >= 0:
            h2_match = re.search(r'\s*<h2', content[body_start:])
            if h2_match:
                pos = body_start + h2_match.start()
                content = content[:pos] + '\n' + bar + '\n' + content[pos:]

# ═══ 3. CTA BUTTON ══════════════════════════════════════════════════════════
# Strip existing
content = re.sub(r'\s*<a[^>]*class="att-buy-now-btn"[^>]*>.*?</a>\s*', '', content, flags=re.DOTALL)

# Get title for label classification
title_m = re.search(r'^# (.+)', md, re.MULTILINE)
title = title_m.group(1).strip() if title_m else slug
t_lower = title.lower()

if 'combo' in t_lower:
    btn_label = 'Book This Combo'
elif any(w in t_lower for w in ['tour', 'trip', 'photoshoot', 'experience', 'zipline', 'bike', 'camel', 'horse', 'show', 'access', 'viewing', 'transfer']):
    btn_label = 'Book This Tour'
elif any(w in t_lower for w in ['ticket', 'pass', 'admission', 'entry']):
    btn_label = 'Buy This Ticket'
else:
    btn_label = 'Book This Tour'

# URL from first top ticket link with correct campaign (no -top)
cta_url = None
if tt_match:
    first_link = re.search(r'- \[.+?\]\((.+?)\)', tt_match.group(2))
    if first_link:
        cta_url = fix_campaign(first_link.group(1), slug, '')

if cta_url:
    btn_html = (
        f'\n      <a\n        href="{cta_url}"\n        class="att-buy-now-btn"\n'
        f'        rel="nofollow sponsored"\n        target="_blank"\n'
        f'      >{btn_label}</a>\n'
    )

    # Priority 1: After What's Included
    inc_pat = r"(<h2[^>]*>(?:What(?:&rsquo;|'|&#8217;|\u2019)?s (?:Included|Typically Included)|What (?:Is|Does)(?: the)?(?: Tour)? Include[^<]*|What the .+? (?:Covers|Includes)|Included in .+?)[^<]*</h2>.*?</ul>)"
    m = re.search(inc_pat, content, re.DOTALL | re.IGNORECASE)

    if m:
        pos = m.end()
        content = content[:pos] + btn_html + content[pos:]
    else:
        # Priority 2: After first H2 section
        body_start = content.find('att-article-body')
        if body_start >= 0:
            first_h2 = re.search(r'<h2[^>]*>[^<]+</h2>', content[body_start:])
            if first_h2:
                abs_start = body_start + first_h2.end()
                next_sec = re.search(r'\s*(?=<h2|<div class="att-faq")', content[abs_start:])
                if next_sec:
                    pos = abs_start + next_sec.start()
                    content = content[:pos] + btn_html + content[pos:]

open(html_path, 'w').write(content)

# Report
tt_count = content.count('class="att-top-tickets">')
cta_count = len(re.findall(r'<a[^>]*att-buy-now-btn', content))
abs_count = len(re.findall(r'href="https://.*' + re.escape(site_slug), content))
print(f'  ✓ {slug}: tt={tt_count} cta={cta_count} abs={abs_count}')
PYEOF

  fixed=$((fixed + 1))
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Done: $fixed fixed"
echo "════════════════════════════════════════════════════════════════"
