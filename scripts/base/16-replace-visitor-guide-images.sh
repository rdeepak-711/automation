#!/bin/bash
set -euo pipefail

# Replace Visitor Guide Images with Correct Post-Specific Images
# Usage: ./scripts/base/16-replace-visitor-guide-images.sh <hostname>

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
echo "🔄 Replacing visitor guide images with correct post-specific hero images..."
echo ""

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

# Function to replace images for a specific page
replace_page_images() {
    local page_slug=\$1
    local page_title=\$2

    echo '════════════════════════════════════════════'
    echo \"📄 Processing: \$page_title\"
    echo '════════════════════════════════════════════'

    local page_id=\$(wp post list --post_type=page --name=\$page_slug --format=ids | head -1)

    if [[ -z \"\$page_id\" ]]; then
        echo \"❌ Page not found: \$page_slug\"
        return
    fi

    echo \"Page ID: \$page_id\"

    # Get current page content
    local content=\$(wp post get \$page_id --field=post_content)
    local updated_content=\"\$content\"

    # Extract all post URLs and get their correct images
    local post_urls=\$(echo \"\$content\" | grep -oE 'href=\"https://[^\"]+/[^/]+/[^/\"]+\"' | sed 's/href=\"//g' | sed 's/\"//g' | grep -v getyourguide | grep -v tiqets | grep -v viator)

    local replacement_count=0

    echo \"Processing post URLs and their correct images:\"

    while IFS= read -r post_url; do
        if [[ -n \"\$post_url\" ]]; then
            local post_slug=\$(echo \"\$post_url\" | sed 's|.*/||')
            local post_id_found=\$(wp post list --post_type=post --name=\$post_slug --format=ids | head -1)

            if [[ -n \"\$post_id_found\" ]]; then
                local post_title_clean=\$(wp post get \$post_id_found --field=post_title | sed 's/&amp;/\&/g')
                local thumbnail_id=\$(wp post meta get \$post_id_found '_thumbnail_id' 2>/dev/null || echo '')

                if [[ -n \"\$thumbnail_id\" ]]; then
                    local correct_image_url=\$(wp post get \$thumbnail_id --field=guid 2>/dev/null || echo '')

                    if [[ -n \"\$correct_image_url\" ]]; then
                        echo \"  📍 \$post_slug → \$(basename \"\$correct_image_url\")\"

                        # Create a pattern that matches the card containing this specific URL
                        # and replace its image with the correct one

                        # Use a more targeted approach: find the specific card with this URL and replace its image
                        local temp_file=\"/tmp/replace_\${page_id}_\${post_slug}.html\"
                        echo \"\$updated_content\" > \"\$temp_file\"

                        # Use awk to precisely target the card with this URL
                        awk -v post_url=\"\$post_url\" -v correct_img=\"\$correct_image_url\" '
                        BEGIN {
                            in_target_card = 0
                            card_buffer = \"\"
                            visitor_guide_img = \"https://operagarnier-guide.com/wp-content/uploads/2026/04/Opera-Garnier-visitor-guide.avif\"
                        }
                        /<div class=\"att-article-card\">/ {
                            in_target_card = 1
                            card_buffer = \$0 \"\\n\"
                            next
                        }
                        in_target_card {
                            card_buffer = card_buffer \$0 \"\\n\"
                            if (\$0 ~ /<\\/div>$/ && card_buffer ~ /<div class=\"att-article-card__body\">/) {
                                # End of card - check if this card contains our URL
                                if (card_buffer ~ post_url) {
                                    # This is our target card - replace the visitor guide image
                                    gsub(visitor_guide_img, correct_img, card_buffer)
                                    # Also replace any placeholder images just in case
                                    gsub(/data:image\/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==/, correct_img, card_buffer)
                                }
                                printf \"%s\", card_buffer
                                in_target_card = 0
                                card_buffer = \"\"
                                next
                            }
                        }
                        !in_target_card { print }
                        ' \"\$temp_file\" > \"\$temp_file.new\"

                        mv \"\$temp_file.new\" \"\$temp_file\"
                        updated_content=\$(cat \"\$temp_file\")
                        rm -f \"\$temp_file\"

                        ((replacement_count++))
                    else
                        echo \"  ⚠️  No image URL found for: \$post_slug\"
                    fi
                else
                    echo \"  ⚠️  No thumbnail ID for: \$post_slug\"
                fi
            else
                echo \"  ⚠️  Post not found: \$post_slug\"
            fi
        fi
    done <<< \"\$post_urls\"

    echo \"\"

    # Update the page if changes were made
    if [[ \"\$updated_content\" != \"\$content\" ]]; then
        echo \"\$updated_content\" | wp post update \$page_id --post_content --stdin
        echo \"✅ Updated \$page_title with \$replacement_count post-specific images\"
    else
        echo \"ℹ️  No changes made to \$page_title (processed \$replacement_count URLs)\"
    fi

    echo \"\"
}

# Process all L1 pages
replace_page_images 'plan-your-visit' 'Plan Your Visit'
replace_page_images 'tickets-tours' 'Tickets & Tours'
replace_page_images 'what-to-see' 'What to See'

echo '════════════════════════════════════════════'
echo '🧹 Clearing Cache'
echo '════════════════════════════════════════════'
wp cache flush >/dev/null 2>&1
wp transient delete --all >/dev/null 2>&1

echo ''
echo '✅ Image replacement completed for $HOSTNAME!'
echo ''
echo '🎯 Results: Each card now shows its specific post hero image'
echo '📸 Verify the changes at:'
echo '   • https://$HOSTNAME/plan-your-visit/'
echo '   • https://$HOSTNAME/tickets-tours/'
echo '   • https://$HOSTNAME/what-to-see/'
"