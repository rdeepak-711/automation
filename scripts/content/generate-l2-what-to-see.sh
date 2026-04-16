#!/usr/bin/env zsh
set -euo pipefail

# ── L2: What to See Article Generator ─────────────────────────────────────
# Generates what-to-see articles as Markdown with YAML frontmatter.
# Related Articles section is NOT included — injected in a second pass
# by assign-related-articles.sh after all hubs are generated.
#
# Usage:
#   ./scripts/content/generate-l2-what-to-see.sh <site-slug> [--list]
#   ./scripts/content/generate-l2-what-to-see.sh <site-slug> --articles 1,3
#   ./scripts/content/generate-l2-what-to-see.sh <site-slug> --all [--force]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--list|--articles 1,2,3|--all] [--force]"
  exit 1
fi

SITE_SLUG="$1"; shift
MODE="list"; ARTICLES_ARG=""; FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)     MODE="list";   shift ;;
    --articles) MODE="single"; ARTICLES_ARG="$2"; shift 2 ;;
    --all)      MODE="all";    shift ;;
    --force)    FORCE=true;    shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TSV="$REPO_ROOT/config/${SITE_SLUG}-pages.tsv"
BLUEPRINT="$REPO_ROOT/output/${SITE_SLUG}/00-blueprint/blueprint.md"
ARCHITECTURE="$REPO_ROOT/output/${SITE_SLUG}/01-architecture/architecture.md"
STAGING="$REPO_ROOT/output/${SITE_SLUG}/03-articles/what-to-see"

[[ -f "$TSV" ]]          || { echo "Error: TSV not found: $TSV"; exit 1; }
[[ -f "$BLUEPRINT" ]]    || { echo "Error: Blueprint not found: $BLUEPRINT"; exit 1; }
[[ -f "$ARCHITECTURE" ]] || { echo "Error: Architecture not found: $ARCHITECTURE"; exit 1; }

# ── Read site config via shared helpers ──────────────────────────────────────
BLUEPRINT_FILE="$BLUEPRINT"
TSV_FILE="$TSV"
DESIGN_CONFIG="$REPO_ROOT/output/${SITE_SLUG}/04-design-config/design-config.md"
TEMPLATE=""
source "$SCRIPT_DIR/lib-l2-helpers.sh"
read_blueprint_common
load_cross_silo_articles
SITE_NAME="$ATTRACTION_NAME"

echo "=========================================================" >&2
echo "  What to See Generator — $SITE_SLUG" >&2
echo "  Site: $SITE_NAME ($SITE_DOMAIN)" >&2
echo "  Mode: $MODE | Force: $FORCE" >&2
echo "=========================================================" >&2
echo "" >&2

# ── Collect all site pages from TSV (for interlinking) ───────────────────────
ALL_PAGES=""
while IFS=$'\t' read -r title url_slug category page_type intent primary_keyword word_count seo_title; do
  [[ "$title" == "title" ]] && continue
  ALL_PAGES+="- https://${SITE_DOMAIN}${url_slug} — ${title} [${category}]
"
done < "$TSV"

# ── Collect ticket affiliate links from blueprint Section D ──────────────────
TICKET_LINKS=""
for pnum in 1 2 3 4 5 6 7 8; do
  _d=$(awk -v pn="$pnum" '
    /^## Section D/ { in_sec=1; next }
    /^## Section [^D]/ && in_sec { exit }
    in_sec && $0 ~ "^### Product " pn "$" { in_p=1; next }
    in_p && /^### Product / { exit }
    in_p && /^\|/ {
      n = split($0, p, "|")
      if (n < 3) next
      k = p[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      v = p[3]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == "Short Label (for buttons)") print "LABEL=" v
      if (k == "Affiliate Link")            print "LINK=" v
      if (k == "Price (adult)")             print "PRICE=" v
    }
  ' "$BLUEPRINT" 2>/dev/null)
  _lbl=$(echo "$_d" | grep "^LABEL=" | sed 's/^LABEL=//')
  _lnk=$(echo "$_d" | grep "^LINK="  | sed 's/^LINK=//')
  _prc=$(echo "$_d" | grep "^PRICE=" | sed 's/^PRICE=//')
  [[ -z "$_lbl" ]] && continue
  TICKET_LINKS+="- ${_lnk} — ${_lbl} (${_prc})
"
done

# ── Collect what-to-see articles from TSV ────────────────────────────────────
typeset -a A_TITLES A_SLUGS A_KEYWORDS A_WORDS A_INTENTS A_URLS
ARTICLE_COUNT=0

while IFS=$'\t' read -r title url_slug category page_type intent primary_keyword word_count seo_title; do
  [[ "$title" == "title" ]]                && continue
  [[ "$category" != "what-to-see" ]]       && continue
  [[ "$page_type" != "standard-content" && "$page_type" != "article" ]] && continue

  ARTICLE_COUNT=$((ARTICLE_COUNT + 1))
  _slug="${url_slug%/}"; _slug="${_slug##*/}"
  A_TITLES[$ARTICLE_COUNT]="$title"
  A_SLUGS[$ARTICLE_COUNT]="$_slug"
  A_KEYWORDS[$ARTICLE_COUNT]="$primary_keyword"
  A_WORDS[$ARTICLE_COUNT]="$word_count"
  A_INTENTS[$ARTICLE_COUNT]="$intent"
  A_URLS[$ARTICLE_COUNT]="https://${SITE_DOMAIN}${url_slug}"
done < "$TSV"

[[ "$ARTICLE_COUNT" -eq 0 ]] && { echo "No what-to-see articles in TSV." >&2; exit 1; }

# ── Show article list ────────────────────────────────────────────────────────
echo "  Articles ($ARTICLE_COUNT):" >&2
echo "" >&2
for i in $(seq 1 $ARTICLE_COUNT); do
  printf "  %2d. %s\n" "$i" "${A_TITLES[$i]}" >&2
  printf "      %s  [%s words]\n" "${A_URLS[$i]}" "${A_WORDS[$i]}" >&2
  echo "" >&2
done

[[ "$MODE" == "list" ]] && exit 0

# ══════════════════════════════════════════════════════════════════════════════
# Generate articles
# ══════════════════════════════════════════════════════════════════════════════

generate_article() {
  local idx="$1"
  local title="${A_TITLES[$idx]}"
  local slug="${A_SLUGS[$idx]}"
  local keyword="${A_KEYWORDS[$idx]}"
  local words="${A_WORDS[$idx]}"
  local intent="${A_INTENTS[$idx]}"
  local url="${A_URLS[$idx]}"
  local outfile="$STAGING/${slug}.md"

  if [[ -f "$outfile" && "$FORCE" == "false" ]]; then
    echo "  ⏭  Skipping (exists): $outfile" >&2
    echo "$outfile"
    return 0
  fi

  echo "── Generating: $title ──" >&2

  # Build siblings list (all WTS articles except this one)
  local siblings=""
  for j in $(seq 1 $ARTICLE_COUNT); do
    [[ $j -ne $idx ]] && siblings+="- ${A_URLS[$j]} — ${A_TITLES[$j]}
"
  done

  local related_articles_block
  related_articles_block=$(build_related_articles_block "what-to-see" "$idx")

  local prompt="We have a website called https://${SITE_DOMAIN} about ${ATTRACTION_NAME} in ${CITY_REGION}.

=== SITE IDENTITY ===
Attraction: ${ATTRACTION_NAME}
Location: ${CITY_REGION}
Official website: ${OFFICIAL_WEBSITE}
Year: ${CONTENT_YEAR}
Currency: ${CURRENCY}
Site description: ${SITE_DESCRIPTION}
Unique angle: ${SITE_ANGLE}

=== BRAND VOICE ===
Personality: ${BRAND_PERSONALITY}
Tone: ${BRAND_TONE}
Avoid: ${BRAND_AVOID}
Refer to attraction as: ${ATTRACTION_REF}

=== ALL SITE PAGES (for internal linking) ===
${ALL_PAGES}

=== TICKET/TOUR AFFILIATE LINKS (integrate throughout article) ===
${TICKET_LINKS}

=== OTHER WHAT TO SEE ARTICLES (interlink to these) ===
${siblings}

=== THIS ARTICLE ===
Title: ${title}
URL: ${url}
Primary keyword: \"${keyword}\"
Target word count: ${words}
Search intent: ${intent}
Silo: what-to-see (hub URL: https://${SITE_DOMAIN}/what-to-see/)

=== RESEARCH INSTRUCTIONS ===
Before writing, fetch the official website (${OFFICIAL_WEBSITE}) to verify:
- Exact location of this feature within the building (floor, wing, room name)
- Photography rules for this specific area
- Which ticket types give access
- Any historical facts about this specific area

STRICT ACCURACY: Never write a specific number (dimension, visitor count, date) you did not confirm from official sources.
If you cannot confirm a figure, write: \"check the official website for current details.\"

=== ARTICLE STRUCTURE (mandatory H2 order) ===
1. What Is [Feature]? — overview with historical context
2. What You'll See — specific visual description with sensory details (colours, light, scale)
3. Where to Find It — exact location in building (floor, wing, direction from entrance)
4. Photography — what's allowed, best angle, best time for light
5. [Additional sections as appropriate: history, significance, tips]
6. Frequently Asked Questions (6-7 Q&As, specific to this area)

=== MANDATORY RULES ===
- SENSORY DEPTH: Each major section must include ONE vivid sensory detail (what you see, hear, the scale, the light)
- HISTORICAL CONTEXT: Each major section needs ONE historical fact or anecdote
- PRECISION: State floor number, wing name, room name, or navigation from entrance
- PROBLEM-SOLVER OPENING: Open by naming the visitor's pain point for this topic
  (\"Can I see this without upgrading my ticket?\" / \"Is it worth my limited time?\")
  Do NOT open with a history lesson or generic welcome
- AEO BLOCKS: Add [AEO] marker on its own line before the intro paragraph, and after any H2 phrased as a question
  Format: 40-80 word self-contained paragraph answering a specific visitor question. Include location + ticket access + one specific data point.
- TICKET INTEGRATION: Integrate ticket links where relevant (nofollow sponsored, new tab, max 3, 200+ words apart)
- INTERNAL LINKS: Link to other what-to-see articles + plan-your-visit + tickets hub (dofollow, same tab, 4-6 per article)

=== BANNED PHRASES ===
\"Must-visit\" | \"Nestled in\" | \"Hidden gem\" | \"Breathtaking\" | \"Steeped in history\"
\"Whether you're a X or a Y\" | \"There's something for everyone\" | \"Embark on a journey\"
\"In this article, we'll cover\" | \"Without further ado\"

${related_articles_block}

=== OUTPUT FORMAT ===
Output ONLY a Markdown document: YAML frontmatter first (between --- lines), then the article body.
No preamble, no explanation — output must start with ---.

FRONTMATTER (scalars only, always quoted):
---
seo_title: \"max 60 chars, primary keyword near front\"
meta_description: \"max 155 chars, compelling, includes keyword\"
article_url: \"${url}\"
primary_keyword: \"${keyword}\"
slug: \"${slug}\"
silo: \"what-to-see\"
---

Use ${CONTENT_YEAR} facts throughout. Target ${words} words.
Images: use placeholder [IMAGE: description | alt text | caption]"

  mkdir -p "$STAGING"
  echo "  Calling claude -p ..." >&2

  echo "$prompt" | claude -p --dangerously-skip-permissions > "$outfile" 2>/dev/null

  if [[ ! -f "$outfile" || ! -s "$outfile" ]]; then
    echo "  ✗ Failed: no output for $title" >&2
    rm -f "$outfile"
    return 1
  fi

  # Strip any preamble before the YAML frontmatter
  if ! head -1 "$outfile" | grep -q '^---$'; then
    awk '/^---$/{found=1} found{print}' "$outfile" > "${outfile}.tmp"
    if [[ -s "${outfile}.tmp" ]]; then
      mv "${outfile}.tmp" "$outfile"
    else
      rm -f "${outfile}.tmp"
      echo "  ✗ Error: no YAML frontmatter found in output for $title" >&2
      rm -f "$outfile"
      return 1
    fi
  fi

  local wc; wc=$(wc -w < "$outfile" | tr -d ' ')
  echo "  ✓ Saved: $outfile ($wc words)" >&2
  echo "$outfile"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
typeset -A GEN_SET
if [[ "$MODE" == "all" ]]; then
  for i in $(seq 1 $ARTICLE_COUNT); do GEN_SET[$i]=1; done
elif [[ "$MODE" == "single" ]]; then
  IFS=',' read -rA _sel <<< "$ARTICLES_ARG"
  for n in "${_sel[@]}"; do
    n=$(echo "$n" | tr -d ' ')
    if [[ "$n" -ge 1 && "$n" -le "$ARTICLE_COUNT" ]] 2>/dev/null; then
      GEN_SET[$n]=1
    else
      echo "  Warning: index '$n' out of range (1–$ARTICLE_COUNT)" >&2
    fi
  done
fi

echo "" >&2
SUCCESS=0; FAIL=0
for idx in $(echo "${(k)GEN_SET[@]}" | tr ' ' '\n' | sort -n); do
  if generate_article "$idx"; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  echo "" >&2
done

echo "=========================================================" >&2
echo "  Done: $SUCCESS succeeded, $FAIL failed" >&2
echo "  Output: $STAGING/" >&2
echo "=========================================================" >&2
