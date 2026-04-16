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

# ── Read IA xlsx for article slugs ────────────────────────────────────────────
IA_SLUGS=$(python3 - "$SCRIPT_DIR/input/$SITE_SLUG/" << 'PYEOF'
import sys, glob
folder = sys.argv[1]
files = glob.glob(folder + '*.xlsx')
if not files:
    print('')
    sys.exit(0)
try:
    import openpyxl
    wb = openpyxl.load_workbook(files[0])
    ws = wb.active
    rows = []
    for row in ws.iter_rows(values_only=True):
        if any(c for c in row):
            rows.append(' | '.join(str(c) if c else '' for c in row[:5]))
    print('\n'.join(rows[:30]))
except:
    print('')
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

## IA OVERVIEW (article slugs)
${IA_SLUGS}

## RULES
- Do NOT include a "tickets" array
- "domain": "${SITE_URL#https://}"
- "cmp": "${CAMPAIGN_PREFIX}-home"
- "cta_url": top GYG ticket URL from TICKETS with partner_id=9BAL9K3&cmp=${CAMPAIGN_PREFIX}-home
- plan_your_visit: 3 articles from Plan Your Visit silo (use slugs from IA OVERVIEW)
- what_to_see: 3 articles from What to See silo (use slugs from IA OVERVIEW)
- tips: 5 practical visitor tips with emoji icons
- faqs: 8 common visitor questions and answers
- Use &amp; for &, &mdash; for —, &rsquo; for apostrophes in display text

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

## IA OVERVIEW (article slugs)
${IA_SLUGS}

## RULES
- slug: "${page_slug}"
- rc: "${page_display}"
- template: "${page_template}"
- cta1: actual GYG URL with partner_id=9BAL9K3&cmp=${CAMPAIGN_PREFIX}-${page_slug}
- cta2: second best GYG URL with same params
- tips: 4 items as arrays [label, text]
- xlinks: 2 items as arrays [title, url, desc, cta_label] — link to the OTHER two pages
- faqs: 5 Q&A pairs as arrays [question, answer]
- All other fields: seo_t, seo_d, badge, h1, desc, cta_h, cta_d, cta_b, explore_label: "Continue exploring."

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

l1 = {
    "domain": site_url.lstrip("https://").lstrip("http://"),
    "gyg_url": gyg_url,
    "explore_label": "Continue exploring.",
    "pages": pages
}

with open(out_path, 'w') as f:
    json.dump(l1, f, indent=2, ensure_ascii=False)
print(f"  ✓ Written: {out_path} ({len(pages)} pages)")
PYEOF

rm -f "$SCRIPT_DIR/input/$SITE_SLUG/.l1-pages-combined.json.tmp"

# ── Fetch GYG prices ──────────────────────────────────────────────────────────
if [[ -n "${GYG_API_KEY:-}" ]]; then
  echo ""
  echo "  Fetching GYG prices via API..."
  python3 - "$OUTPUT_HOMEPAGE" "$GYG_API_KEY" << 'PYEOF'
import sys, json, re, time, urllib.request

cfg_path = sys.argv[1]
api_key  = sys.argv[2]

with open(cfg_path) as f:
    cfg = json.load(f)

tickets = cfg.get("tickets", [])
if not tickets:
    print("  No tickets array — skipping price fetch.")
    sys.exit(0)

updated = 0
for t in tickets:
    url = t.get("url", "")
    m = re.search(r'-t(\d+)', url)
    if not m:
        continue
    tour_id = m.group(1)
    api_url = f"https://api.getyourguide.com/1/tours/{tour_id}?cnt_language=en&currency=EUR"
    req = urllib.request.Request(api_url, headers={"X-ACCESS-TOKEN": api_key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
        tours = data.get("data", {}).get("tours", [])
        if tours:
            amount = tours[0].get("price", {}).get("values", {}).get("amount", "")
            if amount:
                price_str = f"€{amount:.2f}".rstrip("0").rstrip(".")
                t["price"]    = price_str
                t["currency"] = "EUR"
                print(f"  ✓ {t['title'][:50]} → {price_str}")
                updated += 1
    except Exception as e:
        print(f"  ⚠ tour: {e}")
    time.sleep(0.3)

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f"  Updated {updated}/{len(tickets)} ticket prices.")
PYEOF
fi

echo ""
echo "✓ Done. Both configs generated."
echo "  homepage-config.json → $OUTPUT_HOMEPAGE"
echo "  l1-config.json       → $OUTPUT_L1"
