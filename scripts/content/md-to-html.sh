#!/usr/bin/env zsh
set -euo pipefail
setopt extendedglob

# ── md-to-html.sh ─────────────────────────────────────────────────────────────
# Convert a markdown article file to fully populated HTML using Claude sonnet-4-6.
# Reads the article .md and the HTML template; outputs a standalone HTML file.
#
# Usage:
#   ./scripts/content/md-to-html.sh <site-slug> <md-file> [--accent-color #xxxxxx] [--force]
#
# Examples:
#   ./scripts/content/md-to-html.sh opera-garnier input/opera-garnier/tickets-and-tours/opera-garnier-entry-ticket.md
#   ./scripts/content/md-to-html.sh opera-garnier input/opera-garnier/plan-your-visit/opening-hours.md --accent-color '#C41E3A'
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <site-slug> <md-file> [--accent-color #xxxxxx] [--force]"
  exit 1
fi

SITE_SLUG="$1"
MD_FILE="$2"
shift 2

ACCENT_COLOR=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accent-color) ACCENT_COLOR="$2"; shift 2 ;;
    --force)        FORCE=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load .env for model config
ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
CLAUDE_MODEL="${CLAUDE_ARTICLE_MODEL:-claude-sonnet-4-6}"

TEMPLATE="$REPO_ROOT/docs/Four Pages/attraction-individual-article-template.html"

[[ -f "$MD_FILE" ]]   || { echo "Error: Markdown file not found: $MD_FILE"; exit 1; }
[[ -f "$TEMPLATE" ]]  || { echo "Error: Template not found: $TEMPLATE"; exit 1; }

# ── Determine silo from directory name ───────────────────────────────────────
SILO=$(basename "$(dirname "$MD_FILE")")
case "$SILO" in
  tickets-and-tours|tickets-tours|plan-your-visit|what-to-see) ;;
  *) echo "Error: Parent folder must be tickets-and-tours, tickets-tours, plan-your-visit, or what-to-see (got: $SILO)"; exit 1 ;;
esac

# ── Derive slug and output path ───────────────────────────────────────────────
SLUG=$(basename "$MD_FILE" .md)
# Strip article prefix variants to get the bare XLSX slug:
#   article-12-entry-tickets  → entry-tickets   (blue-mosque style)
#   article16_van-gogh-entry  → van-gogh-entry  (van-gogh style)
#   01-what-is-auschwitz      → what-is-auschwitz
SLUG=$(echo "$SLUG" | sed 's/^article-[0-9]*-//; s/^article[0-9]*_//; s/^[0-9]*-//')
# Look up XLSX slug to use as campaign slug (XLSX col 5 = article_slug)
_XLSX_FILE=$(echo "$REPO_ROOT/input/$SITE_SLUG/"*.xlsx 2>/dev/null | head -1)
if [[ -f "$_XLSX_FILE" ]]; then
  _XLSX_SLUG=$(python3 -c "
import openpyxl, sys
wb = openpyxl.load_workbook('$_XLSX_FILE')
ws = wb.active
slug = '$SLUG'
for row in ws.iter_rows(values_only=True):
    if row[0] == '#' or row[0] is None: continue
    if str(row[4]).strip() == slug:
        print(slug)
        break
" 2>/dev/null)
  [[ -n "$_XLSX_SLUG" ]] && SLUG="$_XLSX_SLUG"
fi
OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l2-articles/$SILO"
OUTPUT_FILE="$OUTPUT_DIR/${SLUG}.html"

mkdir -p "$OUTPUT_DIR"

if [[ -f "$OUTPUT_FILE" && "$FORCE" == "false" ]]; then
  echo "⏭  Already exists: $OUTPUT_FILE"
  echo "   Use --force to overwrite."
  exit 0
fi

# ── Resolve accent color ──────────────────────────────────────────────────────
if [[ -z "$ACCENT_COLOR" ]]; then
  DESIGN_CONFIG="$REPO_ROOT/output/$SITE_SLUG/04-design-config/design-config.md"
  if [[ -f "$DESIGN_CONFIG" ]]; then
    _ac=$(grep "^ACCENT_COLOR:" "$DESIGN_CONFIG" | sed 's/ACCENT_COLOR: *//' | tr -d '[:space:]')
    [[ -n "$_ac" ]] && ACCENT_COLOR="$_ac"
  fi
fi
[[ -z "$ACCENT_COLOR" ]] && ACCENT_COLOR="#ff0000"

echo "========================================================="
echo "  md-to-html — $SITE_SLUG"
echo "  Input:  $MD_FILE"
echo "  Silo:   $SILO"
echo "  Accent: $ACCENT_COLOR"
echo "  Output: $OUTPUT_FILE"
echo "========================================================="

# ── Pre-build CSS block with accent color ────────────────────────────────────
CSS_BLOCK=$(python3 -c "
import re, sys

def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def rgb_to_hex(r, g, b):
    return '#{:02x}{:02x}{:02x}'.format(int(r), int(g), int(b))

def tint(r, g, b, factor=0.85):
    return (r + (255 - r) * factor, g + (255 - g) * factor, b + (255 - b) * factor)

def shade(r, g, b, factor=0.75):
    return (r * factor, g * factor, b * factor)

accent = '${ACCENT_COLOR}'
r, g, b = hex_to_rgb(accent)
accent_light = rgb_to_hex(*tint(r, g, b, 0.85))
accent_dark  = rgb_to_hex(*shade(r, g, b, 0.75))

content = open(sys.argv[1]).read()
m = re.search(r'<style>.*?</style>', content, re.DOTALL)
if not m:
    print(''); sys.exit(1)
css = m.group(0)
css = css.replace('--accent: #ff0000', '--accent: ' + accent)
css = css.replace('--accent-light: #ffe5e5', '--accent-light: ' + accent_light)
css = css.replace('--accent-dark: #cc0000', '--accent-dark: ' + accent_dark)
print(css)
" "$TEMPLATE")

# ── Campaign ID detection ─────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# If MD already has non-empty cmp= values, campaign IDs are already present
_HAS_CMP=$(grep -oE 'cmp=[^&" ]+' "$MD_FILE" 2>/dev/null | head -1 || true)
if [[ -n "$_HAS_CMP" ]]; then
  _NEEDS_CAMPAIGN=false
  CAMPAIGN_ID=""
else
  _NEEDS_CAMPAIGN=true
  CAMPAIGN_ID="${CAMPAIGN_PREFIX:-$SITE_SLUG}-${SLUG}"
fi

# ── Rewrite ## Top Tickets based on tickets.md + TOP_TICKET_INDEXES ──────────
TOP_TICKETS_JSON=$(mktemp /tmp/top-tickets-XXXXXX)
export TOP_TICKETS_JSON
TICKETS_MD="$REPO_ROOT/input/$SITE_SLUG/tickets.md"
if [[ -f "$TICKETS_MD" ]]; then
  MD_CONTENT=$(python3 - "$MD_FILE" "$TICKETS_MD" "$SILO" "${TOP_TICKET_INDEXES:-1,2}" "${CAMPAIGN_PREFIX:-$SITE_SLUG}" "$SLUG" << 'TOP_TICKETS_PYEOF'
import sys, re
from urllib.parse import urlparse, urlencode, parse_qs, urlunparse

md_path, tickets_path, silo, indexes_str, campaign_prefix, slug = sys.argv[1:]

# Parse tickets.md: T1 | Title | URL | Partner ref | /path/
tickets = []
for line in open(tickets_path):
    line = line.strip()
    if not re.match(r'T\d+', line): continue
    parts = [p.strip() for p in line.split('|')]
    if len(parts) >= 3:
        tickets.append({'idx': int(re.match(r'T(\d+)', parts[0]).group(1)),
                        'title': parts[1], 'url': parts[2]})

def aff_url(raw_url, cmp_id):
    parsed = urlparse(raw_url)
    host = parsed.hostname or ''
    params = parse_qs(parsed.query, keep_blank_values=True)
    for k in list(params): params.pop(k)
    if 'getyourguide.com' in host:
        params['partner_id'] = ['9BAL9K3']; params['cmp'] = [cmp_id]
    elif 'tiqets.com' in host:
        params['partner'] = ['thebettervacation']; params['tq_campaign'] = [cmp_id]
    elif 'viator.com' in host:
        params['pid'] = ['P00038490']; params['mcid'] = ['42383']
        params['medium'] = ['link']; params['campaign'] = [cmp_id]
    q = urlencode({k: v[0] for k, v in params.items()})
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, '', q, ''))

# Core top ticket indexes (1-based)
core_idxs = [int(i.strip()) for i in indexes_str.split(',') if i.strip().isdigit()]
core_tickets = [t for t in tickets if t['idx'] in core_idxs]

# Read article title from frontmatter
content = open(md_path).read()
title_m = re.search(r'^title:\s*["\']?(.+?)["\']?\s*$', content, re.MULTILINE | re.IGNORECASE)
article_title = title_m.group(1).strip() if title_m else ''

# Also check SEO Title
if not article_title:
    seo_m = re.search(r'^SEO Title:\s*(.+)', content, re.MULTILINE | re.IGNORECASE)
    article_title = seo_m.group(1).strip() if seo_m else ''

# Determine self_ticket: article maps to one specific ticket in tickets.md
# Pass 0 (most reliable): product ID match — extract GYG/Tiqets/Viator IDs from
# article's Top Tickets URLs and match against tickets.md URLs
def extract_pid(url):
    m = re.search(r'-t(\d+)/?', url)
    if m: return ('gyg', m.group(1))
    m = re.search(r'-p(\d+)', url, re.IGNORECASE)
    if m: return ('tiq', m.group(1))
    m = re.search(r'/tours/[^/]+/([^/]+)', url)
    if m: return ('via', m.group(1))
    return None

md_urls = re.findall(r'\]\((https?://[^\)]+)\)', content)
md_pids  = {extract_pid(u) for u in md_urls if extract_pid(u)}
ticket_pids = {extract_pid(t['url']): t for t in tickets if extract_pid(t['url'])}

self_ticket = None
if 'ticket' in silo.lower() or 'tour' in silo.lower():
    # Pass 0: product ID match (most reliable — title can differ between MD and tickets.md)
    for pid in md_pids:
        if pid in ticket_pids:
            self_ticket = ticket_pids[pid]
            break
    # Pass 1: exact title match
    if not self_ticket:
        at = article_title.lower().strip()
        for t in tickets:
            if at == t['title'].lower().strip():
                self_ticket = t
                break
    # Pass 2: substring title match
    if not self_ticket:
        at = article_title.lower().strip()
        for t in tickets:
            tt = t['title'].lower().strip()
            if at in tt or tt in at:
                self_ticket = t
                break

# Build top tickets list
cmp_base = f"{campaign_prefix}-{slug}-top"
top_links = []

# Priority 1: parse Top Tickets or Book This Tour from MD (## heading or **bold**)
import json, os
md_tt_section = re.search(r'(?:## |\*\*)(?:Top Tickets|Book This Tour)(?:\*\*)?\s*\n((?:\n?- .+\n)*)', content)
if md_tt_section:
    for m in re.finditer(r'- \[(.+?)\]\((.+?)\)', md_tt_section.group(1)):
        title, url = m.group(1), m.group(2)
        # Ensure -top suffix on campaign
        if '-top' not in url:
            for param in ['cmp=', 'campaign=', 'tq_campaign=']:
                if param in url:
                    url = re.sub(f'({param}[^&"]+)', r'\1-top', url)
                    break
        top_links.append((title, url))

# Priority 2: fall back to tickets.md if MD has no Top Tickets section
if not top_links:
    if self_ticket:
        top_links.append((self_ticket['title'], aff_url(self_ticket['url'], cmp_base)))
        for ct in core_tickets:
            if ct['idx'] != self_ticket['idx']:
                top_links.append((ct['title'], aff_url(ct['url'], cmp_base)))
    else:
        for ct in core_tickets:
            top_links.append((ct['title'], aff_url(ct['url'], cmp_base)))

# Save top ticket links to temp file for post-processing injection
tt_data = [{'title': t, 'url': u} for t, u in top_links]
# Determine label based on section name in MD (## heading or **bold** format)
md_tt_h2 = re.search(r'^## (Top Tickets|Book This Tour)', content, re.MULTILINE)
md_tt_bold = re.search(r'^\*\*(Top Tickets|Book This Tour)\*\*', content, re.MULTILINE)
md_tt_header = md_tt_h2 or md_tt_bold
if md_tt_header:
    tt_label = md_tt_header.group(1)
elif self_ticket:
    tt_label = "Book This Tour"
else:
    tt_label = "Top Tickets"
tt_json = json.dumps({'label': tt_label, 'links': tt_data})
tt_tmp = os.environ.get('TOP_TICKETS_JSON', '/tmp/top-tickets-data.json')
with open(tt_tmp, 'w') as f:
    f.write(tt_json)

# Strip ## Top Tickets / ## Book This Tour from content — bar injected in post-processing
content = re.sub(r'## Top Tickets\s*\n(?:- .+\n)*\n?', '\n', content)
content = re.sub(r'## Book This Tour\s*\n(?:- .+\n)*\n?', '\n', content)
# Strip **Top Tickets** / **Book This Tour** bold format too
content = re.sub(r'\*\*Top Tickets\*\*\s*\n(?:\n?- .+\n)*\n?', '\n', content)
content = re.sub(r'\*\*Book This Tour\*\*\s*\n(?:\n?- .+\n)*\n?', '\n', content)

sys.stdout.write(content)
TOP_TICKETS_PYEOF
)
else
  MD_CONTENT=$(cat "$MD_FILE")
fi

# ── Rewrite absolute internal links to relative paths ────────────────────────
REGISTRY_FILE="$REPO_ROOT/output/$SITE_SLUG/url-registry.json"
if [[ ! -f "$REGISTRY_FILE" ]]; then
  echo "  url-registry.json missing — generating..."
  python3 "$REPO_ROOT/scripts/content/build-url-registry.py" "$SITE_SLUG" \
    && echo "  ✓ url-registry.json generated" \
    || echo "  ⚠ url-registry.json generation failed — internal links will stay absolute"
fi
_LINK_PY=$(mktemp /tmp/link-rewrite-XXXXXX)
cat > "$_LINK_PY" << 'LINK_REWRITE_PYEOF'
import sys, re, json, os

site_slug, registry_path = sys.argv[1], sys.argv[2]
content = sys.stdin.read()

registry_pages = {}
if os.path.exists(registry_path):
    try:
        reg = json.load(open(registry_path))
        registry_pages = reg.get('pages', {})
        domain = reg.get('domain', '')
    except Exception:
        domain = ''
else:
    domain = ''
    cfg_path = os.path.join(os.path.dirname(registry_path), '..', '..', 'input', site_slug, 'homepage-config.json')
    if os.path.exists(cfg_path):
        try:
            domain = json.load(open(cfg_path)).get('domain', '')
        except Exception:
            pass

if domain:
    pattern = re.compile(r'https://(?:www\.)?' + re.escape(domain) + r'(/[^\s\)\]"\']*)')

    def rewrite_url(m):
        path = m.group(1)
        if path and not path.endswith('/') and '.' not in path.split('/')[-1]:
            path = path + '/'
        norm = '/' + path.strip('/') + '/'
        if registry_pages and norm not in registry_pages and norm != '/':
            print(f"  ⚠ Link target not in registry: {norm}", file=sys.stderr)
        return path

    content = pattern.sub(rewrite_url, content)

sys.stdout.write(content)
LINK_REWRITE_PYEOF
MD_CONTENT=$(echo "$MD_CONTENT" | python3 "$_LINK_PY" "$SITE_SLUG" "$REGISTRY_FILE")
rm -f "$_LINK_PY"

# ── Convert [CTA: "label" → url] markers to raw HTML buttons ─────────────────
# These inline CTA markers (one per ticket section) must appear at exact positions.
# Convert before sending to Claude so it passes them through as raw HTML.
_CTA_TMP=$(mktemp /tmp/cta-convert-XXXXXX)
echo "$MD_CONTENT" > "$_CTA_TMP"
MD_CONTENT=$(python3 - "$_CTA_TMP" << 'CTA_PYEOF'
import sys, re

content = open(sys.argv[1], encoding='utf-8').read()

def make_btn(m):
    label = m.group(1).strip()
    url   = m.group(2).strip()
    # Use att-buy-now-btn-inline so post-processing strip (which removes
    # att-buy-now-btn) doesn't kill these; renamed back after strip runs.
    return (
        f'\n<a\n  href="{url}"\n  class="att-buy-now-btn-inline"\n'
        f'  rel="nofollow sponsored"\n  target="_blank"\n>{label}</a>\n'
    )

# Match: `[CTA — "label" → url]` or [CTA: "label" → url]  (backtick-wrapped or plain, em-dash or colon)
content = re.sub(
    r'`?\[CTA\s*(?:—|-|:)\s*"([^"]+)"\s*(?:→|→|->)\s*([^\]`]+)\]`?',
    make_btn,
    content
)
sys.stdout.write(content)
CTA_PYEOF
)
rm -f "$_CTA_TMP"

# ── Strip ## Book This Tour / ## Buy This Ticket block from MD ────────────────
# These H2 blocks confuse the converter — it mistakes them for the article end
# and skips the rest of the body. CTA buttons are handled by fix-cta-buttons.py.
_STRIP_TMP=$(mktemp /tmp/strip-book-XXXXXX)
echo "$MD_CONTENT" > "$_STRIP_TMP"
MD_CONTENT=$(python3 - "$_STRIP_TMP" << 'STRIP_BOOK_PYEOF'
import sys, re
content = open(sys.argv[1], encoding='utf-8').read()
content = re.sub(
    r'\n## (?:Book This Tour|Buy This Ticket|Book This Ticket)\n(?:(?!## ).*\n)*',
    '\n',
    content
)
# Also strip Top Tickets — the bar is injected in post-processing (## or **bold**)
content = re.sub(
    r'\n## Top Tickets\s*\n(?:- .+\n)*\n?',
    '\n',
    content
)
content = re.sub(
    r'\n\*\*Top Tickets\*\*\s*\n(?:\n?- .+\n)*\n?',
    '\n',
    content
)
print(content, end='')
STRIP_BOOK_PYEOF
)
rm -f "$_STRIP_TMP"

# ── Build the prompt ──────────────────────────────────────────────────────────
EXAMPLE_MD=$(cat "$REPO_ROOT/docs/Four Pages/attraction-individual-article-template.md")
EXAMPLE_HTML=$(cat "$REPO_ROOT/docs/Four Pages/attraction-individual-article-template.html")

TMP_PROMPT=$(mktemp /tmp/md-to-html-XXXXXX)
trap 'rm -f "$TMP_PROMPT"' EXIT

cat > "$TMP_PROMPT" << 'PROMPT_BOUNDARY'
Convert a Markdown travel article into HTML, matching the exact structure and class names shown in the example below.

**Do NOT output any <style>, CSS, <!DOCTYPE>, <html>, <head>, or <body>.** Output only the SEO comment + the `<div class="att-article-page">` structure.

## Key rules (not inferable from example alone)

PROMPT_BOUNDARY

if [[ "$_NEEDS_CAMPAIGN" == "true" ]]; then
  cat >> "$TMP_PROMPT" << PROMPT_BOUNDARY
1. **Affiliate links — partner params + campaign ID:** If a \`getyourguide.com\` link has no \`partner_id\`, append \`?partner_id=9BAL9K3&cmp=CAMPAIGN_ID_PLACEHOLDER\`. For \`tiqets.com\`: \`?partner=thebettervacation&tq_campaign=CAMPAIGN_ID_PLACEHOLDER\`. For \`viator.com\`: \`?pid=P00038490&mcid=42383&medium=link&campaign=CAMPAIGN_ID_PLACEHOLDER\`. If a link already has these params, leave them. Fill any empty \`cmp=\`, \`tq_campaign=\`, or \`campaign=\` with \`CAMPAIGN_ID_PLACEHOLDER\`.
PROMPT_BOUNDARY
else
  cat >> "$TMP_PROMPT" << 'PROMPT_BOUNDARY'
1. **Affiliate links:** All affiliate links already have partner IDs and campaign IDs in the source. Leave all URLs exactly as written — do not add, modify, or remove any query parameters.
PROMPT_BOUNDARY
fi

cat >> "$TMP_PROMPT" << 'PROMPT_BOUNDARY'
2. **CTA buttons:** Do NOT output any `att-buy-now-btn` buttons — these are injected in post-processing.
3. **Top Tickets bar:** Do NOT output any `att-top-tickets` bar — this is injected in post-processing. If the MD has a `## Top Tickets` or `## Book This Tour` section, skip it entirely.
4. **No provider names** in body text (GetYourGuide, Tiqets, Viator) — use generic text.
5. **FAQ section:** If the MD contains a `## Frequently Asked Questions` section with Q&A pairs, convert them to `<details class="att-faq-details"><summary class="att-faq-summary">Question</summary><div class="att-faq-content"><p>Answer</p></div></details>` inside `<div class="att-faq">`. If the MD has fewer than 4 FAQ questions (or none at all), generate 5 relevant, practical FAQ Q&A pairs yourself based on the article content. Always generate a `<script type="application/ld+json">` FAQPage schema from all FAQ Q&A pairs. Place the `<script>` tag at the very end of the output — after the related articles section and after all closing `</div>` tags. It must be the last element in the file.
6. **Images:** Always use the 1×1 base64 GIF placeholder, never a real URL.
7. **AEO blocks:** Convert `> **Label:**` blockquotes to `<div class="att-aeo-block"><p class="att-aeo-block__a">...</p></div>`.
8. **CTA buttons:** Any raw HTML `<a class="att-buy-now-btn-inline" ...>` element in the source → output it exactly as-is, preserving all attributes and the class name. Do NOT wrap in `<p>` tags. Do NOT convert to a regular link.
9. **YAML frontmatter:** Extract `SEO Title`, `Meta Description`, `URL` from the frontmatter and output this exact SEO comment format at the very top (before any HTML):
    ```
    <!-- SEO
    title: {SEO Title value}
    description: {Meta Description value}
    canonical: {URL value}
    -->
    ```
    Omit the frontmatter block itself from the HTML body. Do NOT output `<p class="att-article-header__subtitle">` at all — no subtitle element anywhere in the HTML.
10. **Related Articles:** Extract links into `<div class="att-related"><ul class="att-related__list">`. Strip description text after `—`.
11. Use HTML entities: `&mdash;` `&rsquo;` `&amp;` etc. Keep Polish characters as UTF-8.
12. **Tables:** Always wrap every `<table>` in `<div class="att-table-wrapper"><table class="att-price-table">...</table></div>`. Never output a bare `<table>` tag.

---

## EXAMPLE INPUT (Markdown)

PROMPT_BOUNDARY

echo "$EXAMPLE_MD" >> "$TMP_PROMPT"

cat >> "$TMP_PROMPT" << 'PROMPT_BOUNDARY'

## EXAMPLE OUTPUT (HTML — this is what you must produce)

PROMPT_BOUNDARY

echo "$EXAMPLE_HTML" >> "$TMP_PROMPT"

cat >> "$TMP_PROMPT" << 'PROMPT_BOUNDARY'

---

Now convert this new article using the exact same structure and classes:

## ARTICLE TO CONVERT

PROMPT_BOUNDARY

echo "$MD_CONTENT" >> "$TMP_PROMPT"

# ── Inject campaign ID if needed ─────────────────────────────────────────────
if [[ "$_NEEDS_CAMPAIGN" == "true" ]]; then
  sed -i '' "s/CAMPAIGN_ID_PLACEHOLDER/${CAMPAIGN_ID}/g" "$TMP_PROMPT"
fi

# ── Call Claude (with retry on truncated output) ──────────────────────────────
_is_valid_html() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local sz; sz=$(wc -c < "$f" | tr -d ' ')
  [[ "$sz" -ge 15000 ]] || { echo "  ⚠ Output too small (${sz} bytes — truncated?)"; return 1; }
  grep -q 'att-article-page' "$f" || { echo "  ⚠ Missing att-article-page structure"; return 1; }
  return 0
}

_TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then _TIMEOUT_CMD="gtimeout ${CLAUDE_TIMEOUT_SECS:-300}"
elif command -v timeout &>/dev/null; then _TIMEOUT_CMD="timeout ${CLAUDE_TIMEOUT_SECS:-300}"; fi

_MAX_ATTEMPTS=3
_ATTEMPT=0
_CLAUDE_EXIT=1
while [[ $_ATTEMPT -lt $_MAX_ATTEMPTS ]]; do
  _ATTEMPT=$(( _ATTEMPT + 1 ))
  [[ $_ATTEMPT -gt 1 ]] && echo "  ↺ Retry attempt $_ATTEMPT of $_MAX_ATTEMPTS..."
  echo "  Calling Claude ${CLAUDE_MODEL}..."

  _HB_START=$SECONDS
  ( while true; do
      sleep 5
      printf "    ⏱  %ds elapsed...\n" "$(( SECONDS - _HB_START ))" >&2
    done ) &
  _HB_PID=$!

  $_TIMEOUT_CMD claude -p --model "$CLAUDE_MODEL" --output-format text < "$TMP_PROMPT" > "$OUTPUT_FILE"
  _CLAUDE_EXIT=$?
  [[ $_CLAUDE_EXIT -eq 124 ]] && echo "✗ Claude timed out after ${CLAUDE_TIMEOUT_SECS:-300}s"

  kill "$_HB_PID" 2>/dev/null; wait "$_HB_PID" 2>/dev/null || true
  printf "    ✓ Claude finished in %ds\n" "$(( SECONDS - _HB_START ))"

  if [[ $_CLAUDE_EXIT -ne 0 ]]; then
    echo "  ✗ Claude exited with code $_CLAUDE_EXIT"
    rm -f "$OUTPUT_FILE"
    [[ $_ATTEMPT -lt $_MAX_ATTEMPTS ]] && continue || exit 1
  fi

  if _is_valid_html "$OUTPUT_FILE"; then
    break
  else
    rm -f "$OUTPUT_FILE"
    [[ $_ATTEMPT -lt $_MAX_ATTEMPTS ]] || { echo "✗ Failed after $_MAX_ATTEMPTS attempts"; exit 1; }
  fi
done

# ── Inject CSS block between SEO comment and HTML body ───────────────────────
# Claude outputs: <!-- SEO ... --> then <div class="att-article-page">
# We insert the pre-built <style> block between them.
python3 - "$OUTPUT_FILE" "$CSS_BLOCK" << 'PYEOF'
import re, sys
path = sys.argv[1]
css_block = sys.argv[2]
content = open(path).read()

# Strip markdown code fences Claude may have wrapped output in
content = re.sub(r'^```html\s*', '', content)
content = re.sub(r'```\s*$', '', content)

# Strip leading empty <p> tags before the article div
content = re.sub(r'^(\s*<p>\s*</p>\s*)+', '', content)

# Strip any <style> block Claude may have output despite instructions
content = re.sub(r'<style>.*?</style>\s*', '', content, flags=re.DOTALL)

# Strip subtitle element (meta description must not appear as visible text)
content = re.sub(r'\s*<p class="att-article-header__subtitle">.*?</p>', '', content, flags=re.DOTALL)

# Strip any top-tickets bar and buy-now buttons Claude may have output
# These are injected reliably in post-processing with correct labels and links
content = re.sub(r'\s*<!-- [─━]+ TOP TICKETS[^>]*-->\s*', '', content)
content = re.sub(r'<div class="att-top-tickets">[\s\S]*?</ul>\s*</div>', '', content)
content = re.sub(r'\s*<a[^>]*class="att-buy-now-btn"[^>]*>.*?</a>\s*', '', content, flags=re.DOTALL)

# Strip onclick from FAQ buttons — conflicts with addEventListener in script block
# (inline onclick fires first, toggles open, then JS listener sees wasOpen=true and removes it)
content = re.sub(r'(<button[^>]*att-faq-item__q[^>]*)\s+onclick="[^"]*"', r'\1', content)

# Strip trailing garbage after outermost </div>
matches = list(re.finditer(r'^</div>', content, re.MULTILINE))
if matches:
    end = matches[-1].end()
    content = content[:end] + '\n'

# Insert CSS between SEO comment and the <div>
pos = content.find('<div')
if pos > 0:
    content = content[:pos] + '\n' + css_block + '\n\n' + content[pos:]

# Rename inline CTA buttons back to the real class (survived the strip above)
content = content.replace('class="att-buy-now-btn-inline"', 'class="att-buy-now-btn"')

open(path, 'w').write(content)
PYEOF

# ── Post-process: inject top-tickets bar ───────────────────────────────────────
if [[ -f "$TOP_TICKETS_JSON" && -s "$TOP_TICKETS_JSON" ]]; then
  python3 - "$OUTPUT_FILE" "$TOP_TICKETS_JSON" << 'INJECT_TT_PYEOF'
import sys, re, json

html_path, tt_path = sys.argv[1], sys.argv[2]
content = open(html_path, encoding='utf-8').read()
tt = json.load(open(tt_path))
links = tt.get('links', [])
label = tt.get('label', 'Top Tickets')

if not links:
    sys.exit(0)

# Claude's bar and buttons are already stripped in the CSS injection step above

# Build the HTML bar
arrow = '<svg class="att-top-tickets__arrow" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6h7M6.5 3L9.5 6L6.5 9" /></svg>'
lis = ''
for lnk in links:
    lis += f'          <li><a href="{lnk["url"]}" rel="nofollow sponsored" target="_blank">{lnk["title"]}{arrow}</a></li>\n'

bar = f'''      <!-- ─── TOP TICKETS BAR ─── -->
      <div class="att-top-tickets">
        <p class="att-top-tickets__label">{label}</p>
        <ul class="att-top-tickets__list">
{lis}        </ul>
      </div>
'''

# Insert after intro paragraph(s), before first <h2>
m = re.search(r'(</p>\s*\n)', content[content.find('att-article-body'):])
if m:
    # Find position relative to full content
    body_start = content.find('att-article-body')
    # Find first <h2> after body start
    h2_match = re.search(r'\s*<h2', content[body_start:])
    if h2_match:
        insert_pos = body_start + h2_match.start()
        content = content[:insert_pos] + '\n' + bar + '\n' + content[insert_pos:]

open(html_path, 'w').write(content)
INJECT_TT_PYEOF
fi

# ── Post-process: inject CTA button for ticket/tour articles ──────────────────
# Only for tickets-tours silo. One button after What's Included, or after first list.
if [[ "$SILO" == "tickets-tours" || "$SILO" == "tickets-and-tours" ]] && [[ -f "$TOP_TICKETS_JSON" && -s "$TOP_TICKETS_JSON" ]]; then
  python3 - "$OUTPUT_FILE" "$TOP_TICKETS_JSON" "$MD_FILE" << 'INJECT_CTA_PYEOF'
import sys, re, json

html_path, tt_path, md_path = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(html_path, encoding='utf-8').read()
tt = json.load(open(tt_path))
md = open(md_path, encoding='utf-8').read()

# Skip if CTA button already exists
if 'class="att-buy-now-btn"' in content:
    sys.exit(0)

# Get article title from MD
title_m = re.search(r'^# (.+)', md, re.MULTILINE)
title = title_m.group(1).strip() if title_m else ''

# Classify: combo > tour > ticket
t_lower = title.lower()
if 'combo' in t_lower:
    btn_label = 'Book This Combo'
elif any(w in t_lower for w in ['tour', 'trip', 'photoshoot', 'experience', 'zipline', 'bike']):
    btn_label = 'Book This Tour'
elif any(w in t_lower for w in ['ticket', 'pass', 'admission']):
    btn_label = 'Buy This Ticket'
else:
    btn_label = 'Book This Tour'

# Get the primary URL — self ticket URL if available, else first link
links = tt.get('links', [])
if not links:
    sys.exit(0)

# Self-ticket already resolved in TOP_TICKETS_PYEOF and stored as links[0] in JSON.
# Strip -top suffix (top-tickets bar uses it; CTA button should not).
url = re.sub(r'-top([&"\'>\s]|$)', r'\1', links[0]['url'])

# Build button HTML
btn_html = (
    f'\n      <a\n        href="{url}"\n        class="att-buy-now-btn"\n'
    f'        rel="nofollow sponsored"\n        target="_blank"\n'
    f'      >{btn_label}</a>\n'
)

# Placement priority list — try each pattern, use first match
# 1. After What's Included / Covers section
# 2. After decision-point sections (informational articles)
# 3. Before FAQ section (last resort)
placement_patterns = [
    # Ticket/tour articles: after What Is/What's Included section (ul or table or p)
    r"(<h2[^>]*>(?:What(?:&rsquo;|'|&#8217;|\u2019)?s Included|What Is Included|What the .+? Covers|Included in .+?|What(?:&rsquo;|')?s in (?:the )?(?:ticket|tour|package))</h2>.*?(?:</ul>|</table>|</p>)\s*)",
    # Informational: after buying/booking/comparison sections
    r"(<h2[^>]*>(?:Where to Buy|Method 1|Buy Online|Available .+? Options|Side-by-Side Comparison|How to Book)[^<]*</h2>.*?(?:</ul>|</p>)\s*)",
    # Last resort: before FAQ
    r"()(\s*<div class=\"att-faq\">)",
]

inserted = False
for pat in placement_patterns:
    m = re.search(pat, content, re.DOTALL | re.IGNORECASE)
    if m:
        insert_pos = m.end(1) if m.lastindex and m.lastindex >= 1 else m.start()
        content = content[:insert_pos] + btn_html + content[insert_pos:]
        inserted = True
        break

if inserted:
    open(html_path, 'w').write(content)

INJECT_CTA_PYEOF
fi

rm -f "$TOP_TICKETS_JSON"

# ── Post-process: ensure all internal links are relative ─────────────────────
if [[ -f "$REGISTRY_FILE" ]]; then
  python3 - "$OUTPUT_FILE" "$REGISTRY_FILE" << 'REL_LINKS_PYEOF'
import re, sys, json

html_path, registry_path = sys.argv[1], sys.argv[2]
content = open(html_path).read()
reg = json.load(open(registry_path))
domain = reg.get('domain', '')
if domain:
    # Strip www. + domain from all href/src attributes
    content = re.sub(r'https://(?:www\.)?' + re.escape(domain) + r'(/[^"\'>\s]*)', r'\1', content)
open(html_path, 'w').write(content)
REL_LINKS_PYEOF
fi

SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
echo "✓ Done: $OUTPUT_FILE ($SIZE bytes)"
