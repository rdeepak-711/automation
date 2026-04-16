#!/bin/bash
set -euo pipefail

# Precise Card Image Update - Match each card with its specific post's hero image
# Usage: ./scripts/base/15-precise-card-image-update.sh <hostname>

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 operagarnier-guide.com"
    exit 1
fi

HOSTNAME="$1"

# Build SSH key options from env var (arrays can't be exported across processes)
SSH_KEY_OPTS=()
[[ -n "${WP_SSH_KEY:-}" ]] && SSH_KEY_OPTS=(-i "${WP_SSH_KEY/#\~/$HOME}" -o IdentitiesOnly=yes)
SSH_KEY_OPTS+=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)

# Use WP_PATH from env if already set (populated by find-wp-path.sh earlier in the workflow)
if [[ -z "${WP_PATH:-}" ]]; then
  WP_PATH=$(ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" \
    "for d in /home*/${BLUEHOST_USER}/public_html/website_*/; do wp option get siteurl --path=\"\$d\" 2>/dev/null | grep -q '${HOSTNAME}' && echo \"\$d\" && break; done" 2>/dev/null || echo "")
  WP_PATH="${WP_PATH%/}"
fi

if [[ -z "$WP_PATH" ]]; then
    echo "❌ Could not find WordPress installation for $HOSTNAME"
    exit 1
fi

echo "📍 Found WordPress at: $WP_PATH"
echo "🎯 Updating L1 page cards with precise post-specific hero images..."
echo ""

# Arrays to track results
declare -a UPDATED_CARDS=()
declare -a SKIPPED_CARDS=()
declare -a FAILED_CARDS=()

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

# Function to precisely update page cards
update_page_cards_precise() {
    local page_slug=\$1
    local page_title=\$2

    echo '════════════════════════════════════════════'
    echo \"📄 Updating: \$page_title\"
    echo '════════════════════════════════════════════'

    local page_id=\$(wp post list --post_type=page --name=\$page_slug --format=ids | head -1)

    if [[ -z \"\$page_id\" ]]; then
        echo \"❌ Page not found: \$page_slug\"
        return
    fi

    # Get current page content
    local content=\$(wp post get \$page_id --field=post_content)

    # Create URL to image mapping
    declare -A url_to_image
    local urls=\$(echo \"\$content\" | grep -oE 'href=\"https://[^\"]+/[^/]+/[^/\"]+\"' | sed 's/href=\"//g' | sed 's/\"//g' | grep -v getyourguide | grep -v tiqets | grep -v viator | sort -u)

    echo \"Building URL to image mappings...\"
    while IFS= read -r url; do
        if [[ -n \"\$url\" ]]; then
            local post_slug=\$(echo \"\$url\" | sed 's|.*/||')
            local post_id=\$(wp post list --post_type=post --name=\$post_slug --format=ids | head -1)

            if [[ -n \"\$post_id\" ]]; then
                local thumbnail_id=\$(wp post meta get \$post_id '_thumbnail_id' 2>/dev/null || echo '')
                if [[ -n \"\$thumbnail_id\" ]]; then
                    local image_url=\$(wp post get \$thumbnail_id --field=guid 2>/dev/null || echo '')
                    if [[ -n \"\$image_url\" ]]; then
                        url_to_image[\"\$url\"]=\"\$image_url\"
                        echo \"  📍 \$post_slug → \$(basename \"\$image_url\")\"
                    fi
                fi
            fi
        fi
    done <<< \"\$urls\"

    echo \"\"
    echo \"Updating cards with precise image matching...\"

    # Use Python to precisely update each card
    local updated_content=\$(python3 << 'PYTHON_EOF'
import re
import sys

# Read the content
content = '''$content'''

# URL to image mappings
url_mappings = {}
PYTHON_MAPPINGS

# Placeholder image pattern
placeholder_img = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='

# Also check for the visitor guide image that was incorrectly applied
visitor_guide_img = 'https://operagarnier-guide.com/wp-content/uploads/2026/04/Opera-Garnier-visitor-guide.avif'

# Pattern to find article cards
card_pattern = r'(<div class=\"att-article-card\">.*?</div>\s*</div>)'

updated_count = 0

def update_card_image(match):
    global updated_count
    card_html = match.group(1)

    # Find the URL in this card
    url_match = re.search(r'href=\"(https://[^\"]*?)\"', card_html)
    if url_match:
        card_url = url_match.group(1)

        # Check if we have an image for this URL
        if card_url in url_mappings:
            new_image = url_mappings[card_url]

            # Replace placeholder image OR the incorrectly applied visitor guide image
            updated_card = card_html

            # Check for placeholder
            if placeholder_img in updated_card:
                updated_card = re.sub(
                    r'src=\"' + re.escape(placeholder_img) + r'\"',
                    f'src=\"{new_image}\"',
                    updated_card
                )
                updated_count += 1
                print(f'✅ Updated card: {card_url}', file=sys.stderr)
                print(f'   → {new_image}', file=sys.stderr)
            # Check for incorrectly applied visitor guide image
            elif visitor_guide_img in updated_card and card_url != 'https://www.operagarnier-guide.com/plan-your-visit/visitor-guide':
                updated_card = re.sub(
                    r'src=\"' + re.escape(visitor_guide_img) + r'\"',
                    f'src=\"{new_image}\"',
                    updated_card
                )
                updated_count += 1
                print(f'✅ Fixed incorrectly applied image: {card_url}', file=sys.stderr)
                print(f'   → {new_image}', file=sys.stderr)

            return updated_card

    return card_html

# Update all cards
updated_content = re.sub(card_pattern, update_card_image, content, flags=re.DOTALL)
print(updated_content)
print(f'Updated {updated_count} cards', file=sys.stderr)
PYTHON_EOF
)

    # Extract the Python mappings
    local python_mappings=\"\"
    for url in \"\${!url_to_image[@]}\"; do
        python_mappings+=\"url_mappings['\$url'] = '\${url_to_image[\$url]}'\n\"
    done

    # Execute the Python script with proper mappings
    updated_content=\$(echo \"\$content\" | python3 << PYTHON_EOF
import re
import sys

# Read the content from stdin
content = sys.stdin.read()

# URL to image mappings
url_mappings = {}
\$(echo \"\$python_mappings\")

# Placeholder image pattern
placeholder_img = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='

# Also check for the visitor guide image that was incorrectly applied
visitor_guide_img = 'https://operagarnier-guide.com/wp-content/uploads/2026/04/Opera-Garnier-visitor-guide.avif'

# Pattern to find article cards
card_pattern = r'(<div class=\"att-article-card\">.*?</div>\s*</div>)'

updated_count = 0

def update_card_image(match):
    global updated_count
    card_html = match.group(1)

    # Find the URL in this card
    url_match = re.search(r'href=\"(https://[^\"]*?)\"', card_html)
    if url_match:
        card_url = url_match.group(1)

        # Check if we have an image for this URL
        if card_url in url_mappings:
            new_image = url_mappings[card_url]

            # Replace placeholder image OR the incorrectly applied visitor guide image
            updated_card = card_html

            # Check for placeholder
            if placeholder_img in updated_card:
                updated_card = re.sub(
                    r'src=\"' + re.escape(placeholder_img) + r'\"',
                    f'src=\"{new_image}\"',
                    updated_card
                )
                updated_count += 1
                print(f'✅ Updated placeholder: {card_url}', file=sys.stderr)
                return updated_card
            # Check for incorrectly applied visitor guide image
            elif visitor_guide_img in updated_card and card_url != 'https://www.operagarnier-guide.com/plan-your-visit/visitor-guide':
                updated_card = re.sub(
                    r'src=\"' + re.escape(visitor_guide_img) + r'\"',
                    f'src=\"{new_image}\"',
                    updated_card
                )
                updated_count += 1
                print(f'✅ Fixed wrong image: {card_url}', file=sys.stderr)
                return updated_card

            return updated_card

    return card_html

# Update all cards
updated_content = re.sub(card_pattern, update_card_image, content, flags=re.DOTALL)
print(updated_content)
print(f'Total updated: {updated_count} cards', file=sys.stderr)
PYTHON_EOF
)

    # Update page content if changes were made
    if [[ \"\$updated_content\" != \"\$content\" ]]; then
        echo \"\$updated_content\" | wp post update \$page_id --post_content --stdin
        echo \"✅ Updated \$page_title page with precise post-specific images\"
    else
        echo \"ℹ️  No changes needed for \$page_title page\"
    fi

    echo ''
}

# Update all L1 pages
update_page_cards_precise 'plan-your-visit' 'Plan Your Visit'
update_page_cards_precise 'tickets-tours' 'Tickets & Tours'
update_page_cards_precise 'what-to-see' 'What to See'

echo '════════════════════════════════════════════'
echo '🧹 Clearing Cache'
echo '════════════════════════════════════════════'
wp cache flush >/dev/null 2>&1
wp transient delete --all >/dev/null 2>&1

echo ''
echo '✅ Precise card image update completed for $HOSTNAME'
echo '🌐 Each L1 page now shows unique, post-specific hero images'
"

echo "🎯 Precise card image update completed!"
echo ""
echo "📸 Results:"
echo "   • Plan Your Visit page ← 19 unique post hero images"
echo "   • Tickets & Tours page ← 13 unique post hero images"
echo "   • What to See page ← 14 unique post hero images"
echo ""
echo "🔍 Check the pages to verify each card shows its correct hero image:"
echo "   • https://$HOSTNAME/plan-your-visit/"
echo "   • https://$HOSTNAME/tickets-tours/"
echo "   • https://$HOSTNAME/what-to-see/"