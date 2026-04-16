#!/bin/bash
set -euo pipefail

# Precise Card Image Update - Fixed Version
# Usage: ./scripts/base/15-precise-card-image-update-fixed.sh <hostname>

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

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

# Function to update a specific page
update_page_cards() {
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

    echo \"Page ID: \$page_id\"
    echo \"Building post URL to image mappings...\"

    # Get all unique post URLs from the page
    local page_content=\$(wp post get \$page_id --field=post_content)
    local post_urls=\$(echo \"\$page_content\" | grep -oE 'href=\"https://[^\"]+/[^/]+/[^/\"]+\"' | sed 's/href=\"//g' | sed 's/\"//g' | grep -v getyourguide | grep -v tiqets | grep -v viator | sort -u)

    # Build mappings one by one and update content
    local updated_content=\"\$page_content\"
    local update_count=0

    while IFS= read -r post_url; do
        if [[ -n \"\$post_url\" ]]; then
            local post_slug=\$(echo \"\$post_url\" | sed 's|.*/||')
            local post_id_found=\$(wp post list --post_type=post --name=\$post_slug --format=ids | head -1)

            if [[ -n \"\$post_id_found\" ]]; then
                local post_title=\$(wp post get \$post_id_found --field=post_title | sed 's/&amp;/\&/g' | tr -d '\"')
                local thumbnail_id=\$(wp post meta get \$post_id_found '_thumbnail_id' 2>/dev/null || echo '')

                if [[ -n \"\$thumbnail_id\" ]]; then
                    local image_url=\$(wp post get \$thumbnail_id --field=guid 2>/dev/null || echo '')

                    if [[ -n \"\$image_url\" ]]; then
                        echo \"  📍 \$post_slug → \$(basename \"\$image_url\")\"

                        # Create a temporary file to work with the content safely
                        local temp_content_file=\"/tmp/page_content_\${page_id}.html\"
                        echo \"\$updated_content\" > \"\$temp_content_file\"

                        # Use sed to replace placeholder images in cards that contain this specific URL
                        # First, find cards that contain our URL and mark them
                        awk -v url=\"\$post_url\" -v new_img=\"\$image_url\" '
                        BEGIN { in_card = 0; card_content = \"\"; found_url = 0 }
                        /<div class=\"att-article-card\">/ {
                            in_card = 1;
                            card_content = \$0 \"\\n\";
                            found_url = 0;
                            next;
                        }
                        in_card && \$0 ~ url { found_url = 1 }
                        in_card {
                            card_content = card_content \$0 \"\\n\";
                            if (\$0 ~ /<\\/div>$/ && card_content ~ /<div class=\"att-article-card__body\">/) {
                                # End of card found
                                if (found_url) {
                                    # This card contains our URL, replace its placeholder image
                                    gsub(/src=\"data:image\/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==\"/, \"src=\\\"\" new_img \"\\\"\", card_content);
                                    # Also replace visitor guide image if its not the visitor guide post
                                    if (url !~ /visitor-guide/) {
                                        gsub(/src=\"https:\/\/operagarnier-guide\.com\/wp-content\/uploads\/2026\/04\/Opera-Garnier-visitor-guide\.avif\"/, \"src=\\\"\" new_img \"\\\"\", card_content);
                                    }
                                }
                                printf \"%s\", card_content;
                                in_card = 0;
                                card_content = \"\";
                                next;
                            }
                        }
                        !in_card { print }
                        ' \"\$temp_content_file\" > \"\$temp_content_file.new\"

                        mv \"\$temp_content_file.new\" \"\$temp_content_file\"
                        updated_content=\$(cat \"\$temp_content_file\")
                        rm -f \"\$temp_content_file\"

                        ((update_count++))
                    else
                        echo \"  ⚠️  No image found for: \$post_slug\"
                    fi
                else
                    echo \"  ⚠️  No thumbnail for: \$post_slug\"
                fi
            else
                echo \"  ⚠️  Post not found: \$post_slug\"
            fi
        fi
    done <<< \"\$post_urls\"

    echo \"\"
    echo \"Processed \$update_count post URLs\"

    # Update the page content
    if [[ \"\$updated_content\" != \"\$page_content\" ]]; then
        echo \"\$updated_content\" | wp post update \$page_id --post_content --stdin
        echo \"✅ Updated \$page_title page with \$update_count post-specific images\"
    else
        echo \"ℹ️  No changes needed for \$page_title page\"
    fi

    echo ''
}

# Update all three L1 pages
update_page_cards 'plan-your-visit' 'Plan Your Visit'
update_page_cards 'tickets-tours' 'Tickets & Tours'
update_page_cards 'what-to-see' 'What to See'

echo '════════════════════════════════════════════'
echo '🧹 Clearing Cache'
echo '════════════════════════════════════════════'
wp cache flush >/dev/null 2>&1
wp transient delete --all >/dev/null 2>&1
wp rewrite flush >/dev/null 2>&1

echo ''
echo '✅ Precise card image update completed for $HOSTNAME!'
"

echo ""
echo "🎯 Precise card image update completed!"
echo ""
echo "📸 Each card should now show its specific post's hero image:"
echo "   • Plan Your Visit: https://$HOSTNAME/plan-your-visit/"
echo "   • Tickets & Tours: https://$HOSTNAME/tickets-tours/"
echo "   • What to See: https://$HOSTNAME/what-to-see/"