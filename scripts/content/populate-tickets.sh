#!/usr/bin/env zsh
set -euo pipefail
# ── populate-tickets.sh ───────────────────────────────────────────────────────
# Parses tickets.md and populates the tickets[] array in homepage-config.json.
# Each ticket gets: title, url, tag, price, bullets, duration, lang, l2, desc
# Generated fields (tag, price, bullets, duration, lang, desc) come from Claude.
# Already-populated tickets are skipped (idempotent).
#
# Usage: ./scripts/content/populate-tickets.sh <site-slug>
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug>"
  exit 1
fi

SITE_SLUG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TICKETS_FILE="$SCRIPT_DIR/input/$SITE_SLUG/tickets.md"
HP_CONFIG="$SCRIPT_DIR/input/$SITE_SLUG/homepage-config.json"
SITE_ENV="$SCRIPT_DIR/input/$SITE_SLUG/.env"

[[ -f "$TICKETS_FILE" ]] || { echo "ERROR: tickets.md not found: $TICKETS_FILE"; exit 1; }
[[ -f "$HP_CONFIG"    ]] || { echo "ERROR: homepage-config.json not found: $HP_CONFIG"; exit 1; }
[[ -f "$SITE_ENV"     ]] && { set -a; source "$SITE_ENV"; set +a; }

# Check if tickets already populated
EXISTING_COUNT=$(python3 -c "
import json
hc = json.load(open('$HP_CONFIG'))
t = hc.get('tickets', [])
# Only count tickets with desc (fully populated)
print(sum(1 for x in t if x.get('desc')))
" 2>/dev/null || echo "0")

if [[ "$EXISTING_COUNT" -gt 0 ]]; then
  echo "  ✓ tickets[] already populated ($EXISTING_COUNT entries with desc) — skipping."
  echo "  Use --force to repopulate."
  [[ "${2:-}" == "--force" ]] || exit 0
fi

echo "  Parsing tickets.md..."
TICKETS_RAW=$(grep -v '^#' "$TICKETS_FILE" | grep -v '^$' | grep '|' | grep -v 'Red Button')
TICKET_COUNT=$(echo "$TICKETS_RAW" | wc -l | tr -d ' ')
echo "  Found $TICKET_COUNT tickets"

SITE_URL="${WP_SITE_URL:-}"
CAMPAIGN="${CAMPAIGN_PREFIX:-}"
CURRENCY=$(python3 -c "import json; print(json.load(open('$HP_CONFIG')).get('currency','€'))" 2>/dev/null || echo "€")

# Build prompt
TMP_PROMPT=$(mktemp /tmp/populate-tickets-prompt-XXXXXX)
trap 'rm -f "$TMP_PROMPT"' EXIT

cat > "$TMP_PROMPT" << PROMPT_EOF
You are building ticket card data for a travel website.

Site URL: ${SITE_URL}
Campaign prefix: ${CAMPAIGN}
Currency: ${CURRENCY}

## TICKETS (pipe-delimited: ID | Title | Booking URL | Partner | /l2-slug/)

${TICKETS_RAW}

## TASK

For EACH ticket line above (skip lines starting with # or blank lines), output one JSON object:

- "title": exact text from column 2
- "url": exact URL from column 3 (verbatim, no changes)
- "tag": 1-3 word label — pick from: "Best Seller", "Popular", "Skip the Line", "Guided Tour", "Private Tour", "Small Group", "Combo Deal", "Audio Guide", "Recommended"
- "price": realistic starting price string e.g. "From ${CURRENCY}25" — research the attraction type
- "bullets": array of exactly 3 short benefits (8 words max each), e.g. ["Skip the entry queue", "Expert local guide included", "Small group of max 12"]
- "duration": realistic duration string e.g. "1.5 hours", "2-3 hours", "Half day"
- "lang": language(s) offered e.g. "English", "English & Spanish", "Multilingual"
- "l2": the path from column 5 — strip leading and trailing slashes, keep only the slug portion e.g. "/tickets/blue-mosque-guided-tour/" becomes "blue-mosque-guided-tour"
- "desc": 1 sentence (20-30 words) plain text description of what the visitor gets — no marketing fluff, no HTML

Output ONLY a valid JSON array — one object per ticket in order.
No markdown fences, no explanation, no comments.
PROMPT_EOF

echo "  Calling Claude to generate ticket data..."
TMP_OUT=$(mktemp /tmp/populate-tickets-out-XXXXXX)
claude --print -p "$(cat "$TMP_PROMPT")" > "$TMP_OUT" 2>/dev/null || {
  echo "  ERROR: Claude call failed"
  rm -f "$TMP_OUT"
  exit 1
}

# Merge into homepage-config.json
python3 - "$TMP_OUT" "$HP_CONFIG" << 'PYEOF'
import sys, json, re

raw = open(sys.argv[1]).read().strip()
# Strip markdown fences if present
raw = re.sub(r'^```[a-z]*\n?', '', raw, flags=re.MULTILINE)
raw = re.sub(r'\n?```$', '', raw, flags=re.MULTILINE)
raw = raw.strip()

try:
    tickets = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"  ERROR: Could not parse Claude output as JSON: {e}")
    print(f"  Output was: {raw[:300]}")
    sys.exit(1)

config = json.load(open(sys.argv[2]))
config['tickets'] = tickets

with open(sys.argv[2], 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print(f"  ✓ Wrote {len(tickets)} tickets to homepage-config.json")
for t in tickets:
    print(f"    {t.get('title','?')[:55]} → l2: {t.get('l2','?')}")
PYEOF

rm -f "$TMP_OUT"
echo "  ✓ Done — homepage-config.json updated"
