#!/usr/bin/env zsh
set -euo pipefail

# ── generate-configs.sh ───────────────────────────────────────────────────────
# Generates homepage-config.json and l1-config.json for a site using Claude.
# Makes two separate Claude calls (one per file) to keep prompts small and fast.
#
# Usage: ./scripts/content/generate-configs.sh <site-slug>
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug>"; exit 1; }

SITE_SLUG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
SITE_ENV="$SCRIPT_DIR/input/$SITE_SLUG/.env"
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

TICKETS_FILE="$SCRIPT_DIR/input/$SITE_SLUG/tickets.md"
EXAMPLE_HOMEPAGE="$SCRIPT_DIR/input/homepage-config.template.json"
EXAMPLE_L1="$SCRIPT_DIR/input/l1-config.template.json"
OUTPUT_HOMEPAGE="$SCRIPT_DIR/input/$SITE_SLUG/homepage-config.json"
OUTPUT_L1="$SCRIPT_DIR/input/$SITE_SLUG/l1-config.json"

[[ -f "$TICKETS_FILE" ]] || { echo "Error: tickets.md not found at $TICKETS_FILE"; exit 1; }
[[ -f "$EXAMPLE_HOMEPAGE" ]] || { echo "Error: homepage-config.template.json not found"; exit 1; }
[[ -f "$EXAMPLE_L1" ]] || { echo "Error: l1-config.template.json not found"; exit 1; }

echo "========================================================="
echo "  Generate Configs — $SITE_SLUG"
echo "  Tickets: $TICKETS_FILE"
echo "  Output:  $OUTPUT_HOMEPAGE"
echo "           $OUTPUT_L1"
echo "========================================================="

# ── Read inputs ───────────────────────────────────────────────────────────────
TICKETS_CONTENT=$(cat "$TICKETS_FILE")
EXAMPLE_HP=$(cat "$EXAMPLE_HOMEPAGE")
EXAMPLE_L1_CONTENT=$(cat "$EXAMPLE_L1")
SITE_URL="${WP_SITE_URL:-https://${SITE_SLUG}-guide.com}"
CAMPAIGN_PREFIX="${CAMPAIGN_PREFIX:-$SITE_SLUG}"

# CURRENCY: read from .env if set, otherwise let Claude determine from attraction location.
# To override: add CURRENCY=€ (or zł, $, £, ₺, etc.) to the site's .env
if [[ -n "${CURRENCY:-}" ]]; then
  CURRENCY_RULE="- \"currency\": \"${CURRENCY}\" — use this exact symbol"
else
  CURRENCY_RULE='- "currency": use the correct local or tourist-facing currency symbol for this attraction (e.g. € for Europe, zł for Poland, $ for USD-priced tours, £ for UK, ₺ for Turkey, ₹ for India). Use the symbol only, not the code.'
fi

# ── Read article slugs from xlsx (canonical IA source) ────────────────────────
# Falls back to silo folders if xlsx is missing or unreadable.
IA_SLUGS=$(python3 - "$SCRIPT_DIR/input/$SITE_SLUG/" << 'PYEOF'
import sys, os, re, glob

base = sys.argv[1]

SILO_LABELS = {
    'Tickets & Tours':  'Tickets & Tours',
    'Tickets and Tours': 'Tickets & Tours',
    'Plan Your Visit':  'Plan Your Visit',
    'What To See':      'What To See',
    'What to See':      'What To See',
}

def slugs_from_xlsx(base):
    xlsx_files = [f for f in glob.glob(os.path.join(base, '*.xlsx')) if not f.endswith('.bak')]
    if not xlsx_files:
        return None
    try:
        import openpyxl
        wb = openpyxl.load_workbook(xlsx_files[0])
        silos = {}  # label -> [slug, ...]
        for sheet in wb.worksheets:
            # Multi-sheet format: sheet name is silo name
            sheet_label = SILO_LABELS.get(sheet.title)
            current_silo = sheet_label  # may be None for unrecognised sheets
            for row in sheet.iter_rows(values_only=True):
                col0 = str(row[0]).strip() if row[0] else ''
                # Single-sheet format: col0 = "Silo Name\n/silo-path/"
                if col0 and '\n' in col0:
                    silo_name = col0.split('\n')[0].strip()
                    current_silo = SILO_LABELS.get(silo_name)
                elif col0 and col0 in SILO_LABELS:
                    current_silo = SILO_LABELS[col0]
                if not current_silo:
                    continue
                slug_cell = str(row[3]).strip() if len(row) > 3 and row[3] else ''
                if not slug_cell or slug_cell == 'URL Slug' or not slug_cell.startswith('/'):
                    continue
                leaf = slug_cell.strip('/').split('/')[-1]
                if leaf:
                    silos.setdefault(current_silo, []).append(leaf)
        return silos if silos else None
    except Exception as e:
        return None

def slugs_from_folders(base):
    silo_map = {
        'Tickets & Tours': 'tickets-tours',
        'Plan Your Visit': 'plan-your-visit',
        'What To See':     'what-to-see',
    }
    result = {}
    for label, folder in silo_map.items():
        path = os.path.join(base, folder)
        if not os.path.isdir(path):
            continue
        files = sorted(glob.glob(os.path.join(path, '*.md')))
        slugs = []
        for f in files:
            name = os.path.splitext(os.path.basename(f))[0]
            slug = re.sub(r'^article-?\d+[-_]', '', name)
            if slug:
                slugs.append(slug)
        if slugs:
            result[label] = slugs
    return result or None

silos = slugs_from_xlsx(base) or slugs_from_folders(base)
if not silos:
    print('')
    sys.exit(0)

lines = []
for label in ['Tickets & Tours', 'Plan Your Visit', 'What To See']:
    if label not in silos:
        continue
    lines.append(f'[{label}]')
    for slug in silos[label]:
        lines.append(f'  {slug}')
    lines.append('')
print('\n'.join(lines))
PYEOF
)

# ── Helper: call Claude with cache ────────────────────────────────────────────
# Usage: _claude_cached <cache-file> <prompt-file> <output-file>
_claude_cached() {
  local cache="$1" prompt_file="$2" out="$3"
  if [[ -f "$cache" ]]; then
    echo "  ✓ Using cached response (delete $(basename "$cache") to re-call)"
    cp "$cache" "$out"
    return 0
  fi
  echo "  Calling Claude..."
  local start=$SECONDS
  ( while true; do sleep 5; printf "    ⏱  %ds elapsed...\n" "$(( SECONDS - start ))" >&2; done ) &
  local hb_pid=$!
  claude -p --model claude-haiku-4-5-20251001 --output-format text < "$prompt_file" > "$out" &
  local claude_pid=$!
  local elapsed=0
  while kill -0 "$claude_pid" 2>/dev/null; do
    sleep 5; elapsed=$(( elapsed + 5 ))
    if [[ $elapsed -ge 120 ]]; then
      kill "$claude_pid" 2>/dev/null
      kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true
      echo "✗ Claude timed out after 120s"; return 1
    fi
  done
  wait "$claude_pid" 2>/dev/null || true
  local exit_code=$?
  kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true
  printf "    ✓ Claude finished in %ds\n" "$(( SECONDS - start ))"
  [[ $exit_code -eq 0 ]] || { echo "✗ Claude error (exit $exit_code)"; return 1; }
  cp "$out" "$cache"
  echo "  ✓ Response cached to $(basename "$cache")"
}

# ── Helper: extract JSON from Claude output ───────────────────────────────────
_extract_json() {
  local in_file="$1" out_file="$2" label="$3"
  python3 - "$in_file" "$out_file" "$label" << 'PYEOF'
import sys, json, re

raw = open(sys.argv[1]).read().strip()
label = sys.argv[3]

# Strip markdown fences
lines = raw.split('\n')
if lines[0].startswith('```'):
    lines = lines[1:]
if lines and lines[-1].strip() == '```':
    lines = lines[:-1]
raw = '\n'.join(lines).strip()

# Strip preamble before first { and trailing text after last }
brace = raw.find('{')
if brace > 0:
    raw = raw[brace:]
rbrace = raw.rfind('}')
if rbrace >= 0 and rbrace < len(raw) - 1:
    raw = raw[:rbrace+1]
raw = raw.strip()

def repair_json(s):
    def _fix_surrogate(m):
        return m.group(0) if len(m.group(0)) == 12 else r'\ufffd'
    s = re.sub(r'\\u[dD][89aAbB][0-9a-fA-F]{2}(?:\\u[dD][cCdDeEfF][0-9a-fA-F]{2})?|\\u[dD][cCdDeEfF][0-9a-fA-F]{2}', _fix_surrogate, s)
    s = re.sub(r'\\u[0-9a-fA-F]{1,3}(?![0-9a-fA-F])', r'\\ufffd', s)
    s = s.replace('\u201c', '"').replace('\u201d', '"')
    s = s.replace('\u2018', "'").replace('\u2019', "'")
    s = re.sub(r',\s*([}\]])', r'\1', s)
    s = re.sub(r'}\s*\n(\s*)"', r'},\n\1"', s)
    return s

def try_parse(s):
    try:
        return json.loads(s), None
    except json.JSONDecodeError as e:
        return None, e

parsed, err = try_parse(raw)
if parsed is None:
    if err and 'Extra data' in str(err):
        raw = raw[:err.pos].strip()
        parsed, err = try_parse(raw)
    if parsed is None:
        raw = repair_json(raw)
        parsed, err = try_parse(raw)
        if parsed is None and err and 'Extra data' in str(err):
            raw = raw[:err.pos].strip()
            parsed, err = try_parse(raw)
if parsed is None:
    pos = err.pos if hasattr(err, 'pos') else 0
    ctx = raw[max(0, pos-80):pos+80]
    print(f"  ✗ JSON parse error for {label}: {err}")
    print(f"  Context: ...{ctx!r}...")
    sys.exit(1)

with open(sys.argv[2], 'w') as f:
    json.dump(parsed, f, indent=2, ensure_ascii=False)
print(f"  ✓ Written: {sys.argv[2]} ({len(raw)} bytes)")
PYEOF
}

# ══════════════════════════════════════════════════════════════════════════════
# CALL 1 — homepage-config.json
# ══════════════════════════════════════════════════════════════════════════════
echo ""
if [[ -f "$OUTPUT_HOMEPAGE" ]]; then
  echo "  [1/2] homepage-config.json already exists — skipping."
else
echo "  [1/2] Generating homepage-config.json..."

CACHE_HP="$SCRIPT_DIR/input/$SITE_SLUG/.cache-homepage-config.txt"
TMP_PROMPT_HP=$(mktemp /tmp/gen-hp-XXXXXX)
TMP_OUT_HP=$(mktemp /tmp/gen-hp-out-XXXXXX)
trap 'rm -f "$TMP_PROMPT_HP" "$TMP_OUT_HP"' EXIT

cat > "$TMP_PROMPT_HP" << PROMPT_HP
Your entire response must be a single valid JSON object — nothing else. No explanation, no markdown, no preamble. Start your response with { and end with }.

Generate homepage-config.json for the travel attraction website: ${SITE_URL}

Site slug: ${SITE_SLUG}
Campaign prefix: ${CAMPAIGN_PREFIX}
GYG Partner ID: 9BAL9K3

## TICKETS
${TICKETS_CONTENT}

## ARTICLE SLUGS (exact — use these, do not invent)
${IA_SLUGS}

## RULES
- Do NOT include a "tickets" array
- "domain": "${SITE_URL#https://}"
- "cmp": "${CAMPAIGN_PREFIX}-home"
- "cta_url": top GYG ticket URL from TICKETS with partner_id=9BAL9K3&cmp=${CAMPAIGN_PREFIX}-home
- ${CURRENCY_RULE}
- plan_your_visit: pick 6 slugs from [Plan Your Visit] above — URL format /plan-your-visit/<slug>/
- what_to_see: pick 6 slugs from [What To See] above — URL format /what-to-see/<slug>/
- NEVER invent slugs — only use slugs listed in ARTICLE SLUGS above
- tips: 5 practical visitor tips with emoji icons
- faqs: 8 common visitor questions and answers
- "accent_color": always use exactly "#ff0000"
- Use &amp; for &, &mdash; for —, &ndash; for –, &rsquo; for ', &lsquo; for ' in all display text

## EXAMPLE (match this structure exactly):
${EXAMPLE_HP}
PROMPT_HP

_claude_cached "$CACHE_HP" "$TMP_PROMPT_HP" "$TMP_OUT_HP"
_extract_json "$TMP_OUT_HP" "$OUTPUT_HOMEPAGE" "homepage-config.json"
rm -f "$CACHE_HP"
fi  # end homepage skip

# ══════════════════════════════════════════════════════════════════════════════
# CALLS 2-4 — l1-config.json (one call per page, then combine)
# ══════════════════════════════════════════════════════════════════════════════

# Extract one page block from the example l1-config to use as a per-call example
L1_PAGE_EXAMPLE=$(python3 - "$EXAMPLE_L1" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    cfg = json.load(f)
pages = cfg.get("pages", {})
if pages:
    first_key = list(pages.keys())[0]
    print(json.dumps({first_key: pages[first_key]}, indent=2))
PYEOF
)

# Top-level l1 fields (non-page)
L1_TOP_FIELDS=$(python3 - "$EXAMPLE_L1" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    cfg = json.load(f)
top = {k: v for k, v in cfg.items() if k != "pages"}
print(json.dumps(top, indent=2))
PYEOF
)

_gen_l1_page() {
  local page_display="$1" page_slug="$2" page_template="$3" cache_key="$4"
  echo ""
  echo "  [${cache_key}/4] Generating l1 page: ${page_display}..."

  local cache="$SCRIPT_DIR/input/$SITE_SLUG/.cache-l1-${page_slug}.txt"
  local tmp_prompt tmp_out
  tmp_prompt=$(mktemp /tmp/gen-l1-${page_slug}-XXXXXX)
  tmp_out=$(mktemp /tmp/gen-l1-${page_slug}-out-XXXXXX)

  cat > "$tmp_prompt" << PAGE_PROMPT
Your entire response must be a single valid JSON object — nothing else. No explanation, no markdown, no preamble. Start with { and end with }.

Generate the "${page_display}" page object for l1-config.json.
The JSON must be: {"${page_display}": { ... all fields ... }}

Site: ${SITE_URL}
Campaign prefix: ${CAMPAIGN_PREFIX}
GYG Partner ID: 9BAL9K3
Page slug: ${page_slug}
Page template: ${page_template}

## TICKETS
${TICKETS_CONTENT}

## ARTICLE SLUGS (exact — use these, do not invent)
${IA_SLUGS}

## RULES
- slug: "${page_slug}"
- rc: "${page_display}"
- template: "${page_template}"
- cta1: actual GYG URL with partner_id=9BAL9K3&cmp=${CAMPAIGN_PREFIX}-${page_slug}
- cta2: second best GYG URL with same params
- tips: 4 items as arrays [label, text]
- xlinks: 2 items as arrays [title, url, desc, cta_label] — link to the OTHER two L1 pages using exact slugs: /tickets/, /plan-your-visit/, /what-to-see/
- faqs: 5 Q&A pairs as arrays [question, answer]
- All other fields: seo_t, seo_d, badge, h1, desc, cta_h, cta_d, cta_b
- explore_label: "Continue exploring {attraction name}." — use the actual attraction name (e.g. "Continue exploring Park Güell.")
- Use &amp; for &, &mdash; for —, &ndash; for –, &rsquo; for ', &lsquo; for ' in all display text

## EXAMPLE page structure:
${L1_PAGE_EXAMPLE}
PAGE_PROMPT

  _claude_cached "$cache" "$tmp_prompt" "$tmp_out"

  # Extract just the page object value (strip outer wrapper key)
  python3 - "$tmp_out" "$page_display" >> "$SCRIPT_DIR/input/$SITE_SLUG/.l1-pages-combined.json.tmp" << 'PYEOF'
import sys, json, re

raw = open(sys.argv[1]).read().strip()
page_display = sys.argv[2]

# Strip fences and preamble
lines = raw.split('\n')
if lines[0].startswith('```'): lines = lines[1:]
if lines and lines[-1].strip() == '```': lines = lines[:-1]
raw = '\n'.join(lines).strip()
brace = raw.find('{')
if brace > 0: raw = raw[brace:]
rbrace = raw.rfind('}')
if rbrace >= 0 and rbrace < len(raw) - 1: raw = raw[:rbrace+1]

def repair_json(s):
    def _fix_surrogate(m):
        return m.group(0) if len(m.group(0)) == 12 else r'\ufffd'
    s = re.sub(r'\\u[dD][89aAbB][0-9a-fA-F]{2}(?:\\u[dD][cCdDeEfF][0-9a-fA-F]{2})?|\\u[dD][cCdDeEfF][0-9a-fA-F]{2}', _fix_surrogate, s)
    s = re.sub(r'\\u[0-9a-fA-F]{1,3}(?![0-9a-fA-F])', r'\\ufffd', s)
    s = s.replace('\u201c', '"').replace('\u201d', '"')
    s = s.replace('\u2018', "'").replace('\u2019', "'")
    s = re.sub(r',\s*([}\]])', r'\1', s)
    s = re.sub(r'}\s*\n(\s*)"', r'},\n\1"', s)
    return s

def try_parse(s):
    try:
        return json.loads(s), None
    except json.JSONDecodeError as e:
        return None, e

raw = raw.strip()
parsed, err = try_parse(raw)
if parsed is None:
    # Extra data: truncate at error position
    if err and 'Extra data' in str(err):
        raw = raw[:err.pos].strip()
        parsed, err = try_parse(raw)
    # Other errors: try repair
    if parsed is None:
        raw = repair_json(raw)
        parsed, err = try_parse(raw)
        if parsed is None and err and 'Extra data' in str(err):
            raw = raw[:err.pos].strip()
            parsed, err = try_parse(raw)
if parsed is None:
    pos = err.pos if hasattr(err, 'pos') else 0
    ctx = raw[max(0, pos-80):pos+80]
    print(f"ERROR:{err} | context: ...{ctx!r}...", file=sys.stderr)
    sys.exit(1)

# Unwrap if wrapped in {"PageName": {...}}
if page_display in parsed and isinstance(parsed[page_display], dict):
    parsed = parsed[page_display]
print(json.dumps({page_display: parsed}))
PYEOF

  rm -f "$cache" "$tmp_prompt" "$tmp_out"
}

# Generate top-level fields first
GYG_URL=$(python3 - "$TICKETS_FILE" "$CAMPAIGN_PREFIX" << 'PYEOF'
import sys, re
tickets = open(sys.argv[1]).read()
prefix = sys.argv[2]
m = re.search(r'https://www\.getyourguide\.com/[^\s|]+', tickets)
url = m.group(0).split('?')[0] if m else 'https://www.getyourguide.com/istanbul-l56/'
print(f"{url}?partner_id=9BAL9K3&cmp={prefix}-home")
PYEOF
)

rm -f "$SCRIPT_DIR/input/$SITE_SLUG/.l1-pages-combined.json.tmp"

_gen_l1_page "Tickets & Tours"  "tickets"        "tickets-tours"    "2"
_gen_l1_page "Plan Your Visit"  "plan-your-visit" "plan-your-visit"  "3"
_gen_l1_page "What To See"      "what-to-see"     "what-to-see"      "4"

# Combine all 3 pages into final l1-config.json
python3 - "$SCRIPT_DIR/input/$SITE_SLUG/.l1-pages-combined.json.tmp" "$OUTPUT_L1" "$SITE_URL" "$CAMPAIGN_PREFIX" "$GYG_URL" << 'PYEOF'
import sys, json

pages_file = sys.argv[1]
out_path   = sys.argv[2]
site_url   = sys.argv[3]
prefix     = sys.argv[4]
gyg_url    = sys.argv[5]

pages = {}
with open(pages_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
            pages.update(obj)
        except json.JSONDecodeError as e:
            print(f"  ✗ Failed to parse page line: {e}")
            sys.exit(1)

import re as _re
# Extract explore_label from whichever page Claude set it on (first found wins)
explore_label = next(
    (p.get("explore_label") for p in pages.values() if p.get("explore_label")),
    "Continue exploring."
)
l1 = {
    "domain": _re.sub(r'^https?://', '', site_url),
    "gyg_url": gyg_url,
    "explore_label": explore_label,
    "pages": pages
}

with open(out_path, 'w') as f:
    json.dump(l1, f, indent=2, ensure_ascii=False)
print(f"  ✓ Written: {out_path} ({len(pages)} pages)")
PYEOF

rm -f "$SCRIPT_DIR/input/$SITE_SLUG/.l1-pages-combined.json.tmp"

# ── Post-process l1-config.json: inject all article slugs from xlsx ───────────
# PYV page  → article_slugs: [all slugs]
# WTS page  → article_slugs: [all slugs]
# T&T page  → article_slugs: [{slug, ticket_url, ticket_title}] — ticket fields
#             null for generic articles, matched by title overlap for reviews
python3 - "$OUTPUT_L1" "$SCRIPT_DIR/input/$SITE_SLUG/" "$TICKETS_FILE" << 'PYEOF'
import sys, json, re, glob, os

l1_path    = sys.argv[1]
base       = sys.argv[2]
tickets_md = sys.argv[3]

# ── Load xlsx slugs ────────────────────────────────────────────────────────────
TT_LABELS = {'Tickets & Tours', 'Tickets and Tours'}
PYV_LABELS = {'Plan Your Visit'}
WTS_LABELS = {'What To See', 'What to See'}

xlsx_files = [f for f in glob.glob(os.path.join(base, '*.xlsx')) if not f.endswith('.bak')]
tt_slugs, pyv_slugs, wts_slugs = [], [], []

if xlsx_files:
    try:
        import openpyxl
        wb = openpyxl.load_workbook(xlsx_files[0])
        current = None
        for sheet in wb.worksheets:
            for row in sheet.iter_rows(values_only=True):
                c0 = str(row[0]).strip() if row[0] else ''
                if '\n' in c0:
                    label = c0.split('\n')[0].strip()
                    if label in TT_LABELS:   current = 'tt'
                    elif label in PYV_LABELS: current = 'pyv'
                    elif label in WTS_LABELS: current = 'wts'
                    else: current = None
                slug = str(row[3]).strip() if len(row) > 3 and row[3] else ''
                if not slug.startswith('/') or slug == '/': continue
                leaf = slug.strip('/').split('/')[-1]
                if current == 'tt':
                    tt_slugs.append(leaf)
                elif current == 'pyv':
                    pyv_slugs.append(leaf)
                elif current == 'wts':
                    wts_slugs.append(leaf)
    except Exception as e:
        print(f"  ⚠ XLSX read failed: {e}")
        sys.exit(0)

# ── Load tickets.md ────────────────────────────────────────────────────────────
tickets = []
for line in open(tickets_md):
    line = line.strip()
    if not line.startswith('T') or '|' not in line: continue
    parts = [p.strip() for p in line.split('|')]
    if len(parts) >= 3:
        # Column 5 (index 4) = explicit article slug path e.g. /tickets/entry-ticket/
        article_slug = None
        if len(parts) >= 5 and parts[4].startswith('/'):
            article_slug = parts[4].strip('/').split('/')[-1]
        tickets.append({'title': parts[1], 'url': parts[2], 'article_slug': article_slug})

# ── Word tokeniser (fallback only) ───────────────────────────────────────────
def _words(text):
    stop = {'the','a','an','and','or','of','to','in','for','with','from','by','at','on','is','it','amp'}
    return set(w for w in re.sub(r'[^a-z\s]', '', text.lower()).split() if w not in stop and len(w) > 2)

# ── Build article→ticket map ──────────────────────────────────────────────────
# Pass 1: direct slug match from tickets.md column 5 (canonical)
article_to_ticket = {}
for t in tickets:
    slug = t.get('article_slug')
    if slug and slug in tt_slugs and slug not in article_to_ticket:
        article_to_ticket[slug] = t

# Pass 2: word-overlap fallback for tickets without an explicit slug
for t in tickets:
    slug = t.get('article_slug')
    if slug and slug in article_to_ticket:
        continue  # already matched via column 5
    tw = _words(t['title'])
    best_slug, best_score = None, 0
    for art_slug in tt_slugs:
        if art_slug in article_to_ticket:
            continue  # already claimed
        score = len(tw & _words(art_slug.replace('-', ' ')))
        if score > best_score:
            best_score, best_slug = score, art_slug
    if best_slug and best_score >= 2:
        article_to_ticket[best_slug] = t

# ── Build T&T article_slugs with ticket match ──────────────────────────────────
tt_article_slugs = []
for slug in tt_slugs:
    matched = article_to_ticket.get(slug)
    tt_article_slugs.append({
        'slug': slug,
        'ticket_url': matched['url'] if matched else None,
        'ticket_title': matched['title'] if matched else None,
    })

# ── Inject into l1-config.json ─────────────────────────────────────────────────
l1 = json.load(open(l1_path))
PAGE_MAP = {
    'Tickets & Tours':  ('tt',  tt_article_slugs),
    'Plan Your Visit':  ('pyv', [{'slug': s} for s in pyv_slugs]),
    'What To See':      ('wts', [{'slug': s} for s in wts_slugs]),
}
for page_name, (_, slugs) in PAGE_MAP.items():
    if page_name in l1.get('pages', {}) and slugs:
        l1['pages'][page_name]['article_slugs'] = slugs

with open(l1_path, 'w') as f:
    json.dump(l1, f, indent=2, ensure_ascii=False)

print(f"  ✓ article_slugs injected → T&T: {len(tt_article_slugs)}, PYV: {len(pyv_slugs)}, WTS: {len(wts_slugs)}")
PYEOF

# ── Fetch ticket prices via web search ────────────────────────────────────────
python3 - "$OUTPUT_HOMEPAGE" "${AI_ENGINE:-claude}" << 'PYEOF'
import sys, json, subprocess, re

cfg_path = sys.argv[1]
ai_engine = sys.argv[2] if len(sys.argv) > 2 else "claude"

with open(cfg_path) as f:
    cfg = json.load(f)

tickets = cfg.get("tickets", [])
if not tickets:
    print("  No tickets array — skipping price fetch.")
    sys.exit(0)

attraction = cfg.get("domain", "").replace("-guide.com", "").replace("-", " ").title()
currency = cfg.get("currency", "€")
ticket_list = "\n".join(f"- {t['title']}" for t in tickets)

prompt = f"""Search the web for current {currency} ticket prices for: {attraction}

Ticket types to price:
{ticket_list}

Return a JSON object mapping exact ticket title to current adult price string (e.g. "{currency}15" or "{currency}5-20").
Only include tickets you found real prices for. Return ONLY valid JSON, no other text.
Example: {{"Ticket Title": "{currency}15", "Other Ticket": "{currency}20-30"}}"""

try:
    result = subprocess.run(
        [ai_engine, "--print", "--no-markdown", prompt] if ai_engine == "gemini"
        else ["claude", "--print", "--no-markdown", prompt],
        capture_output=True, text=True, timeout=60
    )
    output = result.stdout.strip()
    m = re.search(r'\{[^{}]+\}', output, re.DOTALL)
    if m:
        prices = json.loads(m.group(0))
        updated = 0
        for t in tickets:
            price = prices.get(t["title"])
            if price:
                t["price"] = str(price)
                print(f"  ✓ {t['title'][:50]} → {price}")
                updated += 1
        with open(cfg_path, "w") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"  Updated {updated}/{len(tickets)} ticket prices.")
    else:
        print("  Price search returned no parseable data — prices skipped.")
except Exception as e:
    print(f"  ⚠ Price fetch failed: {e} — prices skipped.")
PYEOF

# ── Write ACCENT_COLOR back to site .env so L2 assembler picks it up ─────────
ACCENT_COLOR=$(python3 -c "
import json, sys
cfg = json.load(open('$OUTPUT_HOMEPAGE'))
print(cfg.get('accent_color', ''))
" 2>/dev/null)

if [[ -n "$ACCENT_COLOR" ]]; then
  SITE_ENV_FILE="$SCRIPT_DIR/input/$SITE_SLUG/.env"
  if grep -q "^ACCENT_COLOR=" "$SITE_ENV_FILE" 2>/dev/null; then
    sed -i '' "s|^ACCENT_COLOR=.*|ACCENT_COLOR=$ACCENT_COLOR|" "$SITE_ENV_FILE"
  else
    # Ensure file ends with newline before appending
    [[ -s "$SITE_ENV_FILE" ]] && [[ "$(tail -c1 "$SITE_ENV_FILE" | wc -l)" -eq 0 ]] && echo "" >> "$SITE_ENV_FILE"
    echo "ACCENT_COLOR=$ACCENT_COLOR" >> "$SITE_ENV_FILE"
  fi
  echo "  ACCENT_COLOR=$ACCENT_COLOR written to input/$SITE_SLUG/.env"
fi

echo ""
echo "✓ Done. Both configs generated."
echo "  homepage-config.json → $OUTPUT_HOMEPAGE"
echo "  l1-config.json       → $OUTPUT_L1"
