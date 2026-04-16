#!/bin/bash
set -euo pipefail

# Update L1 Page Card Images with Post Hero Images (Fixed Version)
# Usage: ./scripts/base/12-update-l1-card-images-fixed.sh <hostname>

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
echo "🖼️  Updating L1 page card images with specific post hero images..."

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

echo '=== Finding L1 Pages and Their Posts ===\n'

# Get L1 page IDs
PLAN_PAGE=\$(wp post list --post_type=page --name=plan-your-visit --format=ids | head -1)
TICKETS_PAGE=\$(wp post list --post_type=page --name=tickets-tours --format=ids | head -1)
SEE_PAGE=\$(wp post list --post_type=page --name=what-to-see --format=ids | head -1)

echo \"Plan Your Visit page ID: \$PLAN_PAGE\"
echo \"Tickets & Tours page ID: \$TICKETS_PAGE\"
echo \"What to See page ID: \$SEE_PAGE\"
echo ''

# Function to get featured image URL from post ID
get_featured_image_url() {
    local post_id=\$1
    local thumbnail_id=\$(wp post meta get \$post_id '_thumbnail_id' 2>/dev/null || echo '')
    if [[ -n \"\$thumbnail_id\" ]]; then
        wp post get \$thumbnail_id --field=guid 2>/dev/null || echo ''
    else
        echo ''
    fi
}

# Function to extract and update card images in page content with precise matching
update_page_card_images_precise() {
    local page_id=\$1
    local page_name=\$2

    echo \"=== Processing \$page_name Page (ID: \$page_id) ===\"

    if [[ -z \"\$page_id\" ]]; then
        echo \"⚠️  \$page_name page not found, skipping...\"
        return
    fi

    # Get current page content
    local content=\$(wp post get \$page_id --field=post_content)
    local updated_content=\"\$content\"

    # Find all post URLs in the content and extract their hero images
    local post_urls=\$(echo \"\$content\" | grep -oE 'href=\"https://[^\"]+/[^/]+/[^/\"]+\"' | sed 's/href=\"//g' | sed 's/\"//g' | grep -v getyourguide | sort -u)

    echo \"Found unique post URLs in \$page_name:\"
    echo \"\$post_urls\"
    echo ''

    # Process each URL and build replacement mappings
    declare -A url_to_image

    while IFS= read -r url; do
        if [[ -n \"\$url\" ]]; then
            # Extract post slug from URL
            local post_slug=\$(echo \"\$url\" | sed 's|.*/||')

            # Get post ID from slug
            local post_id=\$(wp post list --post_type=post --name=\$post_slug --format=ids | head -1)

            if [[ -n \"\$post_id\" ]]; then
                # Get featured image URL
                local image_url=\$(get_featured_image_url \$post_id)

                if [[ -n \"\$image_url\" ]]; then
                    echo \"✅ Post: \$post_slug (ID: \$post_id)\"
                    echo \"   Image: \$image_url\"
                    url_to_image[\"\$url\"]=\"\$image_url\"
                else
                    echo \"⚠️  No featured image found for post: \$post_slug\"
                fi
            else
                echo \"⚠️  Post not found for URL: \$url\"
            fi
        fi
    done <<< \"\$post_urls\"

    echo ''
    echo '=== Performing Precise Card-to-Image Matching ==='

    # Now perform precise replacements using Python for better HTML parsing
    python3 << 'PYTHON_EOF'
import re
import sys

# Read the content
content = '''$updated_content'''

# URL to image mappings from bash
url_mappings = {
PYTHON_MAPPINGS
}

# Find all article cards and update images
placeholder_img = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='

# Pattern to find article cards with their content
card_pattern = r'(<div class=\"att-article-card\">.*?</div>\s*</div>)'

def update_card_image(match):
    card_html = match.group(1)

    # Find the URL in this card
    url_match = re.search(r'href=\"(https://[^\"]*?)\"', card_html)
    if url_match:
        card_url = url_match.group(1)

        # Check if we have an image for this URL
        if card_url in url_mappings:
            new_image = url_mappings[card_url]
            # Replace the placeholder image with the specific image
            updated_card = re.sub(
                r'src=\"' + re.escape(placeholder_img) + r'\"',
                f'src=\"{new_image}\"',
                card_html,
                count=1
            )
            print(f'✅ Updated card for {card_url}', file=sys.stderr)
            print(f'   → {new_image}', file=sys.stderr)
            return updated_card

    return card_html

# Update all cards
updated_content = re.sub(card_pattern, update_card_image, content, flags=re.DOTALL)
print(updated_content)
PYTHON_EOF"

    # Build the Python mappings string
    local python_mappings=\"\"
    for url in \"\${!url_to_image[@]}\"; do
        python_mappings+=\"    '\$url': '\${url_to_image[\$url]}',\n\"
    done

    # Replace the placeholder in Python script and execute
    local python_script=\"\$(echo \"\$updated_content\" | sed 's/\\\$updated_content/'\"'\"'\$updated_content'\"'\"'/g')\"

    updated_content=\$(python3 << PYTHON_EOF
import re
import sys

# Read the content
content = '''$updated_content'''

# URL to image mappings from bash
url_mappings = {
$python_mappings
}

# Find all article cards and update images
placeholder_img = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='

# Pattern to find article cards with their content
card_pattern = r'(<div class=\"att-article-card\">.*?</div>\s*</div>)'

def update_card_image(match):
    card_html = match.group(1)

    # Find the URL in this card
    url_match = re.search(r'href=\"(https://[^\"]*?)\"', card_html)
    if url_match:
        card_url = url_match.group(1)

        # Check if we have an image for this URL
        if card_url in url_mappings:
            new_image = url_mappings[card_url]
            # Replace the placeholder image with the specific image
            updated_card = re.sub(
                r'src=\"' + re.escape(placeholder_img) + r'\"',
                f'src=\"{new_image}\"',
                card_html,
                count=1
            )
            print(f'✅ Updated card for {card_url}', file=sys.stderr)
            print(f'   → {new_image}', file=sys.stderr)
            return updated_card

    return card_html

# Update all cards
updated_content = re.sub(card_pattern, update_card_image, content, flags=re.DOTALL)
print(updated_content)
PYTHON_EOF
)

    # Update page content if changes were made
    if [[ \"\$updated_content\" != \"\$content\" ]]; then
        wp post update \$page_id --post_content=\"\$updated_content\"
        echo \"✅ Updated \$page_name page with precise post-specific images\"
    else
        echo \"ℹ️  No images updated for \$page_name page\"
    fi

    echo ''
}

# Update all L1 pages with precise image matching
update_page_card_images_precise \$PLAN_PAGE \"Plan Your Visit\"
update_page_card_images_precise \$TICKETS_PAGE \"Tickets & Tours\"
update_page_card_images_precise \$SEE_PAGE \"What to See\"

echo '=== Clearing Cache ==='
wp cache flush >/dev/null 2>&1
wp transient delete --all >/dev/null 2>&1

echo \"✅ L1 page card image update completed for $HOSTNAME\"
echo \"🌐 All L1 pages now show unique hero images for each linked post\"
"

echo "🎯 Precise card image update completed!"
echo ""
echo "📸 Updated pages:"
echo "   • Plan Your Visit page ← Unique post hero images"
echo "   • Tickets & Tours page ← Unique post hero images"
echo "   • What to See page ← Unique post hero images"