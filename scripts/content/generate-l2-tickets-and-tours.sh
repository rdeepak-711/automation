#!/usr/bin/env zsh
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH"

# ── L2 Tickets & Tours — Content Generator ───────────────────────────────────
# Generates tickets-and-tours markdown content files (Stage 1 of two-stage pipeline).
# Called by generate-l2-articles.sh which handles HTML conversion (Stage 2).
#
# Usage:
#   ./scripts/content/generate-l2-tickets-and-tours.sh <site-slug> [options]
#
# Options:
#   --list                   Show ticket list only, no generation
#   --ticket 1,2,3           Generate specific tickets by number
#   --all                    Generate all tickets
#   --force                  Overwrite existing staging .md files
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--list] [--ticket N|--all] [--force]"
  exit 1
fi

SITE_SLUG="$1"; shift

MODE="all"
TICKET_NUM=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)   MODE="list";   shift ;;
    --ticket) MODE="single"; TICKET_NUM="$2"; shift 2 ;;
    --all)    MODE="all";    shift ;;
    --force)  FORCE=true;    shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

ENGINE="${AI_ENGINE:-claude}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ -f "$SCRIPT_DIR/lib-l2-helpers.sh" ]] && source "$SCRIPT_DIR/lib-l2-helpers.sh"

# ── Affiliate link builder (partner params + campaign ID) ─────────────────────
# Usage: build_affiliate_link <raw_url> <campaign_id>
build_affiliate_link() {
  local url="$1" cmp="$2"
  python3 - "$url" "$cmp" <<'PYEOF'
import sys
from urllib.parse import urlparse, urlencode, urlunparse, parse_qs

url, cmp_id = sys.argv[1], sys.argv[2]
parsed = urlparse(url)
host = parsed.hostname or ''
params = {}
if 'getyourguide.com' in host:
    params['partner_id'] = '9BAL9K3'
    params['cmp'] = cmp_id
elif 'tiqets.com' in host:
    params['partner'] = 'thebettervacation'
    params['tq_campaign'] = cmp_id
elif 'viator.com' in host:
    params['pid'] = 'P00038490'
    params['mcid'] = '42383'
    params['medium'] = 'link'
    params['campaign'] = cmp_id
q = urlencode(params)
print(urlunparse((parsed.scheme, parsed.netloc, parsed.path, '', q, '')))
PYEOF
}

BLUEPRINT_FILE="$REPO_ROOT/output/$SITE_SLUG/00-blueprint/blueprint.md"
DESIGN_CONFIG="$REPO_ROOT/output/$SITE_SLUG/04-design-config/design-config.md"
STAGING_DIR="$REPO_ROOT/output/$SITE_SLUG/03-articles/tickets-and-tours"
TSV_FILE="$REPO_ROOT/config/${SITE_SLUG}-pages.tsv"

[[ -f "$BLUEPRINT_FILE" ]] || { echo "Error: Not found: $BLUEPRINT_FILE"; exit 1; }

# ── Load config via shared helpers ───────────────────────────────────────────

read_blueprint_common
read_design_config
load_tsv_page_map
load_cross_silo_articles

# ── Parse products from blueprint Section D ───────────────────────────────────

PRODUCTS_TSV=$(awk '
  BEGIN {
    in_sec=0
    name=""; label=""; partner=""; link=""; price=""; priority="99"
    included=""; not_included=""; best_for=""; selling_point=""
  }
  /^## Section D/ { in_sec=1; next }
  /^## Section [^D]/ && in_sec { exit }
  in_sec && /^### Product [0-9]/ {
    if (name != "") print name "\t" label "\t" partner "\t" link "\t" price "\t" priority "\t" included "\t" not_included "\t" best_for "\t" selling_point
    name=""; label=""; partner=""; link=""; price=""; priority="99"
    included=""; not_included=""; best_for=""; selling_point=""
    next
  }
  in_sec && /^\|/ {
    n = split($0, p, "|")
    if (n < 3) next
    k = p[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
    v = p[3]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
    if      (k == "Product Name")              name          = v
    else if (k == "Short Label (for buttons)") label         = v
    else if (k == "Affiliate Partner")         partner       = v
    else if (k == "Affiliate Link")            link          = v
    else if (k == "Price (adult)")             price         = v
    else if (k == "Priority")                  priority      = v
    else if (k == "What'\''s Included")        included      = v
    else if (k == "What'\''s NOT Included")    not_included  = v
    else if (k == "Best For")                  best_for      = v
    else if (k == "Key Selling Point")         selling_point = v
  }
  END { if (name != "") print name "\t" label "\t" partner "\t" link "\t" price "\t" priority "\t" included "\t" not_included "\t" best_for "\t" selling_point }
' "$BLUEPRINT_FILE")

PRODUCT_COUNT=$(echo "$PRODUCTS_TSV" | grep -c . || true)
[[ "$PRODUCT_COUNT" -eq 0 ]] && { echo "Error: No products found in blueprint Section D"; exit 1; }

typeset -a P_SLUGS P_LABELS P_PRICES P_LINKS P_PARTNERS P_NAMES P_CAMPAIGN_LINKS
typeset -a P_INCLUDED P_NOT_INCLUDED P_BEST_FOR P_SELLING_POINT

# ── Load slug map from XLSX (title → article_slug, full_url) ─────────────────
# XLSX columns: #, title, category, category_slug, article_slug, full_url
XLSX_FILE=$(echo "$REPO_ROOT/input/$SITE_SLUG/"*.xlsx 2>/dev/null | head -1)
declare -A XLSX_SLUG_MAP XLSX_URL_MAP
if [[ -f "$XLSX_FILE" ]]; then
  while IFS=$'\t' read -r _title _slug _url; do
    XLSX_SLUG_MAP["$_title"]="$_slug"
    XLSX_URL_MAP["$_title"]="$_url"
  done < <(python3 - <<PYEOF
import openpyxl, sys
wb = openpyxl.load_workbook('$XLSX_FILE')
ws = wb.active
for row in ws.iter_rows(values_only=True):
    if row[0] == '#' or row[0] is None: continue
    title = str(row[1] or '').strip()
    slug  = str(row[4] or '').strip()
    url   = str(row[5] or '').strip()
    if title and slug:
        print(f"{title}\t{slug}\t{url}")
PYEOF
  )
fi

IDX=0
while IFS=$'\t' read -r p_name p_label p_partner p_link p_price p_priority p_included p_not_included p_best_for p_selling_point; do
  IDX=$((IDX + 1))
  P_NAMES[$IDX]="$p_name"
  P_LABELS[$IDX]="$p_label"
  P_PARTNERS[$IDX]="$p_partner"
  P_LINKS[$IDX]="$p_link"
  P_PRICES[$IDX]="$p_price"
  P_INCLUDED[$IDX]="$p_included"
  P_NOT_INCLUDED[$IDX]="$p_not_included"
  P_BEST_FOR[$IDX]="$p_best_for"
  P_SELLING_POINT[$IDX]="$p_selling_point"
  # Use XLSX slug if available (matched by product name), fall back to make_slug
  if [[ -n "${XLSX_SLUG_MAP[$p_name]+x}" ]]; then
    P_SLUGS[$IDX]="${XLSX_SLUG_MAP[$p_name]}"
  else
    P_SLUGS[$IDX]=$(make_slug "$p_label")
  fi
  # Build full campaign-tagged affiliate link once; reused in list, prompt, and output
  P_CAMPAIGN_LINKS[$IDX]=$(build_affiliate_link "$p_link" "${CAMPAIGN_PREFIX:-$SITE_SLUG}-${P_SLUGS[$IDX]}")
done <<< "$PRODUCTS_TSV"

# ── Look up each product's canonical URL from XLSX or TSV ────────────────────

typeset -a P_TSV_KEYWORDS P_TSV_URLS
for _idx in $(seq 1 $IDX); do
  _p_name="${P_NAMES[$_idx]}"
  _match=""
  # Prefer XLSX URL (direct, accurate)
  if [[ -n "${XLSX_URL_MAP[$_p_name]+x}" ]]; then
    P_TSV_URLS[$_idx]="${XLSX_URL_MAP[$_p_name]}"
    P_TSV_KEYWORDS[$_idx]=""
  elif [[ -f "$TSV_FILE" ]]; then
    _slug="${P_SLUGS[$_idx]}"
    _match=$(awk -F'\t' -v slug="$_slug" '
      NR==1 { next }
      $2 ~ ("/"slug"/$") { print $2 "\t" $6; exit }
    ' "$TSV_FILE")
    if [[ -n "$_match" ]]; then
      P_TSV_URLS[$_idx]="https://${SITE_DOMAIN}$(echo "$_match" | cut -f1)"
      P_TSV_KEYWORDS[$_idx]="$(echo "$_match" | cut -f2)"
    else
      P_TSV_URLS[$_idx]="https://${SITE_DOMAIN}/tickets/${P_SLUGS[$_idx]}/"
      P_TSV_KEYWORDS[$_idx]=""
    fi
  else
    P_TSV_URLS[$_idx]="https://${SITE_DOMAIN}/tickets/${P_SLUGS[$_idx]}/"
    P_TSV_KEYWORDS[$_idx]=""
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
#  MODE: --list  (default)
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$MODE" == "list" ]]; then
  echo "========================================================="
  echo "  L2 Tickets & Tours Content Generator — $SITE_SLUG"
  echo "  Engine: $ENGINE  |  Force: $FORCE"
  echo "========================================================="
  echo "── Phase 1: Reading product catalog from blueprint ─────────────────────"
  echo "  Found ${PRODUCT_COUNT} ticket(s):"
  echo ""

  for i in $(seq 1 $PRODUCT_COUNT); do
    printf "  %d. %s (%s)\n"      "$i" "${P_NAMES[$i]}" "${P_PRICES[$i]}"
    printf "     Slug:     %s\n"  "${P_SLUGS[$i]}"
    printf "     URL:      %s\n"  "${P_TSV_URLS[$i]}"
    printf "     Staging:  output/%s/staging/articles/tickets-and-tours/%s.md\n" "$SITE_SLUG" "${P_SLUGS[$i]}"
    printf "     Campaign: %s-%s\n" "${CAMPAIGN_PREFIX:-$SITE_SLUG}" "${P_SLUGS[$i]}"
    printf "     Link:     %s\n"  "${P_CAMPAIGN_LINKS[$i]}"
    echo ""
  done

  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
#  Generate article for a single ticket
# ═════════════════════════════════════════════════════════════════════════════

generate_ticket_article() {
  local idx="$1"
  local slug="${P_SLUGS[$idx]}"
  local name="${P_NAMES[$idx]}"
  local label="${P_LABELS[$idx]}"
  local price="${P_PRICES[$idx]}"
  local campaign_link="${P_CAMPAIGN_LINKS[$idx]}"
  local article_url="${P_TSV_URLS[$idx]}"
  local primary_keyword="${P_TSV_KEYWORDS[$idx]}"
  [[ -z "$primary_keyword" ]] && primary_keyword="$(echo "$slug" | tr '-' ' ')"
  local page_link top_link all_pages_block
  local staging_file="$STAGING_DIR/${slug}.md"
    if [[ -f "$staging_file" && "$FORCE" == "false" ]]; then
      echo "  ↷ Skipping (exists): $staging_file" >&2
      echo "$staging_file"
      return 0
    fi
    echo "── Generating content: $idx/$PRODUCT_COUNT: $name ──" >&2

    # Build context blocks
    local ticket_links_block="" interlink_block=""
    for j in $(seq 1 $PRODUCT_COUNT); do
      page_link=$(build_affiliate_link "${P_LINKS[$j]}" "${CAMPAIGN_PREFIX:-$SITE_SLUG}-${slug}")
      ticket_links_block+="${page_link} — ${P_NAMES[$j]} (${P_PRICES[$j]})
  Included: ${P_INCLUDED[$j]}
  Not included: ${P_NOT_INCLUDED[$j]}
  Best for: ${P_BEST_FOR[$j]}
"
    done
    all_pages_block=""
    for p in $(seq 1 $TSV_PAGE_COUNT); do
      all_pages_block+="${TSV_URLS[$p]} — ${TSV_TITLES[$p]} [${TSV_CATEGORIES[$p]}/${TSV_PAGETYPES[$p]}]
"
    done
    for j in $(seq 1 $PRODUCT_COUNT); do
      [[ $j -ne $idx ]] && interlink_block+="${P_TSV_URLS[$j]} — ${P_NAMES[$j]}
"
    done

    local related_articles_block
    related_articles_block=$(build_related_articles_block "tickets-and-tours" "$idx")

    local top_tickets_content=""
    local count=0
    for j in $(seq 1 $PRODUCT_COUNT); do
      if [[ $j -ne $idx && $count -lt 3 ]]; then
        top_link=$(build_affiliate_link "${P_LINKS[$j]}" "${CAMPAIGN_PREFIX:-$SITE_SLUG}-${slug}-top")
        top_tickets_content+="${P_LABELS[$j]} | ${top_link}
"
        count=$((count + 1))
      fi
    done

    local content_prompt
    content_prompt=$(cat <<CONTENT_EOF
Write a ticket/tour article for a travel affiliate website.
Output ONLY a Markdown document: YAML frontmatter first (between --- lines), then the article body.
No preamble, no explanation — output must start with ---.

BEFORE WRITING: Use WebFetch to fetch the primary affiliate link (${campaign_link}) and extract exact
details: duration, group size, languages, cancellation policy, highlights, and any specifics not below.

STRICT ACCURACY RULE:
NEVER write a specific number (time, price, percentage, count) that you did not find on the fetched page.
This includes "typically X" or "approximately X" — hedging does NOT make a fabricated number acceptable.
If you don't have the confirmed figure, write: "check the booking page for current details"

=== OUTPUT FORMAT ===
FRONTMATTER (scalars only, always quoted):
---
seo_title: "[max 60 chars, primary keyword near front]"
meta_description: "[max 155 chars, compelling, includes keyword]"
article_url: "${article_url}"
primary_keyword: "${primary_keyword}"
slug: "${slug}"
silo: "tickets-and-tours"
---

BODY MARKERS:
[AEO] — place on its own line immediately before a 40–80 word paragraph directly answering a visitor question.
  Add one before the intro and under relevant H2s (e.g. "Is it worth it?", "What's included?").
[TIP: your tip text] — insider tip (single line)
[TOP_TICKET: Label | URL] — one per top-ticket entry (output 3, one line each, using -top campaign URLs)
[TICKET_PRICE: ${price}] — marks the price display (place after What's Included heading)
[BOOK_BTN: ${label} | ${campaign_link}] — marks the book-now button (place immediately after TICKET_PRICE)
[END_CTA: ${label} | ${campaign_link}] — end-of-article CTA (place before FAQ)

H2 ORDER (mandatory, in this exact order):
1. What's Included
2. What's Not Included
3. Who Should Buy This Ticket
4. [free sections: How to Book, Is It Worth It, Before You Arrive, Tips, etc.]
5. How It Compares (optional comparison table — if meaningful alternatives exist)
6. Frequently Asked Questions

FAQ:
## Frequently Asked Questions
**Q: Question?**
**A:** Answer.
(7–8 questions specific to this ticket)

${related_articles_block}

=== SITE ===
Website: https://${SITE_DOMAIN}
Attraction: ${ATTRACTION_NAME}
Location: ${CITY_REGION}
Plan Your Visit hub: ${PYV_HUB_URL}
Tickets & Tours hub: ${TICKETS_HUB_URL}
What to See hub: ${WHATTOSEE_HUB_URL}
Content year: ${CONTENT_YEAR}
Currency: ${CURRENCY}
Description: ${SITE_DESCRIPTION}
Angle: ${SITE_ANGLE}
Discount categories: ${DISCOUNT_CATEGORIES}

=== BRAND VOICE ===
Personality: ${BRAND_PERSONALITY}
Tone: ${BRAND_TONE}
Avoid: ${BRAND_AVOID}
Refer to attraction as: ${ATTRACTION_REF}

=== THIS ARTICLE ===
Product: ${name}
Short label: ${label}
Price: ${price}
Article URL: ${article_url}
Primary affiliate link: ${campaign_link}
What's included: ${P_INCLUDED[$idx]}
What's NOT included: ${P_NOT_INCLUDED[$idx]}
Best for: ${P_BEST_FOR[$idx]}
Key selling point: ${P_SELLING_POINT[$idx]}

=== ALL TICKET & TOUR LINKS ===
${ticket_links_block}

=== ALL SITE PAGES ===
${all_pages_block}

=== SIBLING TICKET ARTICLES ===
${interlink_block}

=== TOP TICKETS BAR (output as [TOP_TICKET: Label | URL] markers, 3 entries) ===
${top_tickets_content}

=== WRITING RULES ===
- Use "${primary_keyword}" in the H1, first paragraph, and at least 2 H2s.
  Use natural variations of the keyword elsewhere — do NOT force the exact phrase repeatedly.
- Add secondary keywords and LSI keywords naturally throughout the article
- 1500–2000 words; use ${CONTENT_YEAR} prices and dates throughout
- Write with SEO, AEO, and GEO in mind — factual, specific, cite-worthy sentences
- Add an [AEO] block just before the introduction, and under H2s where appropriate
- Link to other pages from ALL SITE PAGES — internal links must be dofollow and open in a new window
- Link to Tickets hub (${TICKETS_HUB_URL}) and Plan Your Visit hub (${PYV_HUB_URL}) at least once each
- Integrate ticket links wherever appropriate — nofollow sponsored, open in a new window; max 3, min 200 words apart
- Every section must add real value — no filler. If a topic doesn't justify 100+ words, link to the relevant page instead
- NEVER write a specific number (time, price, count, duration) you did not find on the fetched page.
  "Typically" or "approximately" does NOT make an unverified number acceptable.
  Instead write: "check the booking page for current details"
CONTENT_EOF
)

    mkdir -p "$STAGING_DIR"
    echo "  Calling $ENGINE CLI (content-only, WebFetch enabled)..." >&2
    run_ai_prompt "$content_prompt" "$staging_file" "WebFetch"

    if [[ ! -f "$staging_file" || ! -s "$staging_file" ]]; then
      echo "  ✗ Error: No content generated for $name" >&2
      rm -f "$staging_file"
      return 1
    fi

    local wc_out; wc_out=$(wc -w < "$staging_file" | tr -d ' ')
    echo "  ✓ Saved: $staging_file ($wc_out words)" >&2
    echo "$staging_file"
}


# ═════════════════════════════════════════════════════════════════════════════
#  MODE: --ticket N
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$MODE" == "single" ]]; then
  # Support comma-separated list: --ticket 3,4,5 or --ticket 3
  typeset -a TICKET_NUMS
  IFS=',' read -rA TICKET_NUMS <<< "$TICKET_NUM"

  for t in "${TICKET_NUMS[@]}"; do
    if [[ -z "$t" || "$t" -lt 1 || "$t" -gt "$PRODUCT_COUNT" ]]; then
      echo "Error: --ticket value '$t' must be between 1 and $PRODUCT_COUNT"
      exit 1
    fi
  done

  echo "========================================================="
  echo "  L2 Tickets & Tours Content Generator — $SITE_SLUG"
  echo "  Engine: $ENGINE  |  Force: $FORCE"
  echo "========================================================="
  echo "── Phase 2: Generating ${#TICKET_NUMS[@]} content file(s) ─────────────────────────────"
  echo ""

  SUCCESS=0; FAIL=0
  for t in "${TICKET_NUMS[@]}"; do
    if generate_ticket_article "$t"; then
      SUCCESS=$((SUCCESS + 1))
    else
      FAIL=$((FAIL + 1))
    fi
    echo ""
  done

  if [[ ${#TICKET_NUMS[@]} -gt 1 ]]; then
    echo "========================================================="
    echo "  Results: $SUCCESS succeeded, $FAIL failed"
    echo "========================================================="
  fi
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
#  MODE: --all
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$MODE" == "all" ]]; then
  echo "========================================================="
  echo "  L2 Tickets & Tours Content Generator — $SITE_SLUG"
  echo "  Engine: $ENGINE  |  Force: $FORCE"
  echo "========================================================="
  echo "── Phase 1: Reading product catalog from blueprint ─────────────────────"
  echo "  Found ${PRODUCT_COUNT} ticket(s)"
  echo "── Phase 2: Generating content ─────────────────────────────────────────"
  echo ""

  SUCCESS=0
  FAIL=0

  for i in $(seq 1 $PRODUCT_COUNT); do
    if generate_ticket_article "$i"; then
      SUCCESS=$((SUCCESS + 1))
    else
      FAIL=$((FAIL + 1))
    fi
    echo ""
  done

  echo "========================================================="
  echo "  Results: $SUCCESS succeeded, $FAIL failed"
  echo "========================================================="
  exit 0
fi
