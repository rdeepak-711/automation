#!/usr/bin/env zsh
set -euo pipefail

# ── inject-faqs.sh ──────────────────────────────────────────────────────────
# Generates FAQ section via Claude and injects into HTML articles that have
# fewer than 4 FAQs. Skips articles that already have 4+ FAQs.
#
# Usage:
#   ./scripts/content/inject-faqs.sh <site-slug>
#   ./scripts/content/inject-faqs.sh <site-slug> --slug best-time-to-visit
#   ./scripts/content/inject-faqs.sh <site-slug> --force   # regenerate even if 4+ exist
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug> [--slug <slug>] [--force]"; exit 1; }

SITE_SLUG="$1"; shift
FILTER_SLUG=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) FILTER_SLUG="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

CLAUDE_MODEL="${CLAUDE_ARTICLE_MODEL:-claude-sonnet-4-6}"
OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l2-articles"
INPUT_DIR="$REPO_ROOT/input/$SITE_SLUG"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Inject FAQs — $SITE_SLUG"
echo "════════════════════════════════════════════════════════════════"

injected=0
skipped=0
failed=0

for silo in plan-your-visit tickets-tours what-to-see; do
  [[ ! -d "$INPUT_DIR/$silo" ]] && continue

  for md_file in "$INPUT_DIR/$silo"/*.md; do
    [[ ! -f "$md_file" ]] && continue

    slug=$(basename "$md_file" .md | sed 's/^article[0-9]*_//')
    [[ -n "$FILTER_SLUG" && "$slug" != "$FILTER_SLUG" ]] && continue

    html_file="$OUTPUT_DIR/$silo/$slug.html"
    [[ ! -f "$html_file" ]] && { echo "  ⚠  $silo/$slug — no HTML, skipping"; continue; }

    # Count existing FAQs
    faq_count=$(grep -c '<details class="att-faq-details">' "$html_file" 2>/dev/null || true)
    faq_count=${faq_count:-0}
    faq_count=$(echo "$faq_count" | tr -d '[:space:]')

    if [[ "$faq_count" -ge 4 && "$FORCE" == "false" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    echo "  [$silo/$slug] $faq_count FAQs → generating..."

    # Get article title and content summary for context
    title=$(grep '^# ' "$md_file" | head -1 | sed 's/^# //')

    # Build prompt
    TMP_PROMPT=$(mktemp /tmp/faq-prompt-XXXXXX)
    cat > "$TMP_PROMPT" << FAQPROMPT
Generate 5-8 FAQ questions and answers for this travel article (more for content-rich articles, fewer for simpler ones). Output ONLY the HTML — no explanation, no markdown, no code fences.

Article title: $title
Article content:
$(cat "$md_file" | head -100)

Output format — use this EXACT HTML structure:

<div class="att-faq">
  <h2 class="att-faq__title">Frequently Asked Questions</h2>
  <details class="att-faq-details">
    <summary class="att-faq-summary">Question here?</summary>
    <div class="att-faq-content">
      <p>Answer here.</p>
    </div>
  </details>
  <!-- repeat for all 5 questions -->
</div>

<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
    {
      "@type": "Question",
      "name": "Question here?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "Answer here."
      }
    }
  ]
}
</script>

Rules:
- Questions must be practical, specific to the article topic
- Answers 2-3 sentences, include one specific fact/number
- No markdown, no code fences — raw HTML only
- Include the FAQPage JSON-LD schema with all 5 questions
FAQPROMPT

    # Call Claude
    TMP_FAQ=$(mktemp /tmp/faq-output-XXXXXX)
    claude -p --model "$CLAUDE_MODEL" --output-format text < "$TMP_PROMPT" > "$TMP_FAQ" 2>/dev/null

    if [[ ! -s "$TMP_FAQ" ]]; then
      echo "    ✗ Claude returned empty"
      failed=$((failed + 1))
      rm -f "$TMP_PROMPT" "$TMP_FAQ"
      continue
    fi

    # Strip code fences if present
    sed -i '' 's/^```html//; s/^```//' "$TMP_FAQ"

    # Inject into HTML — before Related Articles section, or before closing divs
    python3 - "$html_file" "$TMP_FAQ" << 'PYEOF'
import sys, re

html_path, faq_path = sys.argv[1], sys.argv[2]
content = open(html_path, encoding='utf-8').read()
faq_html = open(faq_path, encoding='utf-8').read().strip()

if not faq_html:
    sys.exit(1)

# Remove any existing FAQ section (if --force and partial FAQ exists)
content = re.sub(r'\s*<div class="att-faq">[\s\S]*?</div>\s*(?=\s*<!--|\s*<div class="att-related"|\s*</div>)', '', content)
# Remove any existing FAQPage JSON-LD
content = re.sub(r'\s*<script type="application/ld\+json">\s*\{[^}]*"@type":\s*"FAQPage"[\s\S]*?</script>', '', content)

# Insert before Related Articles section
related_match = re.search(r'(\s*<!-- ─── RELATED|<div class="att-related")', content)
if related_match:
    pos = related_match.start()
    content = content[:pos] + '\n\n      ' + faq_html + '\n' + content[pos:]
else:
    # Fallback: before last </div>
    last_div = content.rfind('</div>')
    if last_div > 0:
        second_last = content.rfind('</div>', 0, last_div)
        if second_last > 0:
            content = content[:second_last] + '\n\n      ' + faq_html + '\n' + content[second_last:]

open(html_path, 'w').write(content)
PYEOF

    if [[ $? -eq 0 ]]; then
      new_count=$(grep -c '<details class="att-faq-details">' "$html_file" 2>/dev/null || echo 0)
      echo "    ✓ Injected ($new_count FAQs now)"
      injected=$((injected + 1))
    else
      echo "    ✗ Injection failed"
      failed=$((failed + 1))
    fi

    rm -f "$TMP_PROMPT" "$TMP_FAQ"
  done
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Done: $injected injected | $skipped skipped (4+) | $failed failed"
echo "════════════════════════════════════════════════════════════════"
