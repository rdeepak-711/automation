#!/bin/bash
set -euo pipefail

# Update L1 Page Card Images with Post Hero Images
# Usage: ./scripts/base/12-update-l1-card-images.sh <hostname>

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
echo "🖼️  Updating L1 page card images with post hero images..."

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

# Function to extract and update card images in page content
update_page_card_images() {
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
    local post_urls=\$(echo \"\$content\" | grep -oE 'href=\"https://[^\"]+/[^/]+/[^/\"]+\"' | sed 's/href=\"//g' | sed 's/\"//g')

    echo \"Found post URLs in \$page_name:\"
    echo \"\$post_urls\"
    echo ''

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

                    # Find the card containing this URL and update its image
                    # Look for the card structure and replace the placeholder image
                    local search_pattern=\"<div class=\\\"att-article-card\\\">.*?<img class=\\\"att-article-card__img\\\" src=\\\"[^\\\"]*\\\" alt=\\\"[^\\\"]*\\\" />.*?<a href=\\\"\$url\\\"\"

                    # Use sed to replace placeholder image with actual image URL
                    # This is a simplified approach - we'll replace all placeholder images sequentially
                    updated_content=\$(echo \"\$updated_content\" | sed \"s|src=\\\"data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==\\\"|src=\\\"\$image_url\\\"|1\")
                else
                    echo \"⚠️  No featured image found for post: \$post_slug\"
                fi
            else
                echo \"⚠️  Post not found for URL: \$url\"
            fi
        fi
    done <<< \"\$post_urls\"

    # Update page content if changes were made
    if [[ \"\$updated_content\" != \"\$content\" ]]; then
        wp post update \$page_id --post_content=\"\$updated_content\"
        echo \"✅ Updated \$page_name page with real post images\"
    else
        echo \"ℹ️  No images updated for \$page_name page\"
    fi

    echo ''
}

# Update all L1 pages
update_page_card_images \$PLAN_PAGE \"Plan Your Visit\"
update_page_card_images \$TICKETS_PAGE \"Tickets & Tours\"
update_page_card_images \$SEE_PAGE \"What to See\"

echo '=== Clearing Cache ==='
wp cache flush >/dev/null 2>&1
wp transient delete --all >/dev/null 2>&1

echo \"✅ L1 page card image update completed for $HOSTNAME\"
echo \"🌐 All L1 pages now show real hero images from their linked posts\"
"

echo "🎯 Card image update completed!"
echo ""
echo "📸 Updated pages:"
echo "   • Plan Your Visit page ← Real post hero images"
echo "   • Tickets & Tours page ← Real post hero images"
echo "   • What to See page ← Real post hero images"