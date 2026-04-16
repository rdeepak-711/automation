#!/usr/bin/env zsh
set -euo pipefail

# ── generate-l2-plan-your-visit.sh ───────────────────────────────────────────
# Simple Plan Your Visit article generator.
# Reads article list from TSV, builds prompt, calls claude -p, saves .md.
#
# Usage:
#   ./scripts/content/generate-l2-plan-your-visit.sh <site-slug> --list
#   ./scripts/content/generate-l2-plan-your-visit.sh <site-slug> --articles 1,3
#   ./scripts/content/generate-l2-plan-your-visit.sh <site-slug> --all
#   ./scripts/content/generate-l2-plan-your-visit.sh <site-slug> --all --force

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# ── Paths ────────────────────────────────────────────────────────────────────
TSV="$REPO_ROOT/config/${SITE_SLUG}-pages.tsv"
BLUEPRINT="$REPO_ROOT/output/${SITE_SLUG}/00-blueprint/blueprint.md"
STAGING="$REPO_ROOT/output/${SITE_SLUG}/03-articles/plan-your-visit"

[[ -f "$TSV" ]]       || { echo "Error: TSV not found: $TSV"; exit 1; }
[[ -f "$BLUEPRINT" ]] || { echo "Error: Blueprint not found: $BLUEPRINT"; exit 1; }

# ── Read site config via shared helpers ──────────────────────────────────────
BLUEPRINT_FILE="$BLUEPRINT"
TSV_FILE="$TSV"
DESIGN_CONFIG="$REPO_ROOT/output/${SITE_SLUG}/04-design-config.md"
TEMPLATE=""
source "$SCRIPT_DIR/lib-l2-helpers.sh"
read_blueprint_common
load_cross_silo_articles
SITE_NAME="$ATTRACTION_NAME"

echo "=========================================================" >&2
echo "  Plan Your Visit Generator — $SITE_SLUG" >&2
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

# ── Collect plan-your-visit articles from TSV ────────────────────────────────
typeset -a A_TITLES A_SLUGS A_KEYWORDS A_WORDS A_INTENTS A_URLS
ARTICLE_COUNT=0

while IFS=$'\t' read -r title url_slug category page_type intent primary_keyword word_count seo_title; do
  [[ "$title" == "title" ]]              && continue
  [[ "$category" != "plan-your-visit" ]]         && continue
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

[[ "$ARTICLE_COUNT" -eq 0 ]] && { echo "No plan-your-visit articles in TSV." >&2; exit 1; }

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

  # Build siblings list (all PYV articles except this one)
  local siblings=""
  for j in $(seq 1 $ARTICLE_COUNT); do
    [[ $j -ne $idx ]] && siblings+="- ${A_URLS[$j]} — ${A_TITLES[$j]}
"
  done

  local related_articles_block
  related_articles_block=$(build_related_articles_block "plan-your-visit" "$idx")

  # ── Build the prompt ───────────────────────────────────────────────────
  local prompt="We have a website called https://${SITE_DOMAIN}

Some of the important pages on the site are:
${ALL_PAGES}

Now I want to write a Plan Your Visit article for this site.

THIS ARTICLE:
- Title: ${title}
- URL: ${url}
- Primary keyword: \"${keyword}\"
- Target word count: ${words}
- Search intent: ${intent}

OTHER PLAN YOUR VISIT ARTICLES (interlink to these):
${siblings}

TICKET/TOUR AFFILIATE LINKS (integrate these throughout the article):
${TICKET_LINKS}

Before writing, fetch the official website (${OFFICIAL_WEBSITE}) and its visitor information / \"prepare your arrival\" pages to verify all facts — opening hours, prices, closure days, services, policies, transport, accessibility. Search 2–3 additional reputable sources to cross-reference.

STRICT ACCURACY: Never write a specific number (time, price, distance, percentage) that you did not confirm from official sources. \"Typically X\" or \"approximately X\" does NOT make a fabricated number acceptable. If you cannot confirm a figure, write: \"check the [official website](${OFFICIAL_WEBSITE}) for current details.\"

MANDATORY REPORTING: You MUST state every fact you DID confirm. Do not strip confirmed facts to play it safe. An opening hours article without hours, or a transport article without metro line numbers, is a failure. State what you confirmed. Flag what you couldn't. Never fabricate. Never omit confirmed data. If official pages contradict each other, note the discrepancy in the article and link to the official site as the definitive source.

Every article you write must interlink to other appropriate articles on the site. All internal interlinking must be dofollow and open in same window. While writing, add secondary keywords and LSI keywords within the article as appropriate. You have to integrate the ticket links — integrate them wherever possible and appropriate. These ticket links must open in a new window, should be nofollow and sponsored. This writing needs to be done with SEO, AEO, and GEO in mind. Also, add the AEO Answer block just before the article's introduction, and then under H2s wherever appropriate. If hours, prices, or schedules vary by season, present them in a clear table — not buried in prose.

${related_articles_block}

Output ONLY a Markdown document: YAML frontmatter first (between --- lines), then the article body.
No preamble, no explanation — output must start with ---.

FRONTMATTER (scalars only, always quoted):
---
seo_title: \"max 60 chars, primary keyword near front\"
meta_description: \"max 155 chars, compelling, includes keyword\"
article_url: \"${url}\"
primary_keyword: \"${keyword}\"
slug: \"${slug}\"
silo: \"plan-your-visit\"
---

The category is \"Plan Your Visit\" (hub URL: https://${SITE_DOMAIN}/plan-your-visit/). Create the URLs and interlinking accordingly.

Use ${CONTENT_YEAR} dates and facts throughout. Target ${words} words."

  # ── Call claude ─────────────────────────────────────────────────────────
  mkdir -p "$STAGING"
  echo "  Calling claude -p ..." >&2

  echo "$prompt" | claude -p --dangerously-skip-permissions > "$outfile" 2>/dev/null

  if [[ ! -f "$outfile" || ! -s "$outfile" ]]; then
    echo "  ✗ Failed: no output for $title" >&2
    rm -f "$outfile"
    return 1
  fi

  # Strip any preamble (research reasoning) output before the YAML frontmatter
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