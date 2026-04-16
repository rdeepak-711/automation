#!/bin/bash
set -euo pipefail

# Show Card to Image Mappings
# Usage: ./scripts/base/14-show-card-mappings.sh <hostname>

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
echo "🔍 Showing Card to Image Mappings for $HOSTNAME"
echo ""

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

# Function to show mappings for a page
show_page_mappings() {
    local page_slug=\$1
    local page_title=\$2

    echo '════════════════════════════════════════════'
    echo \"📄 \$page_title Page\"
    echo '════════════════════════════════════════════'

    local page_id=\$(wp post list --post_type=page --name=\$page_slug --format=ids | head -1)

    if [[ -z \"\$page_id\" ]]; then
        echo \"❌ Page not found: \$page_slug\"
        return
    fi

    echo \"Page ID: \$page_id\"
    echo \"Page URL: https://$HOSTNAME/\$page_slug/\"
    echo ''

    # Extract all article card URLs from page content
    local content=\$(wp post get \$page_id --field=post_content)
    local urls=\$(echo \"\$content\" | grep -oE 'href=\"https://[^\"]+/[^/]+/[^/\"]+\"' | sed 's/href=\"//g' | sed 's/\"//g' | grep -v getyourguide | sort -u)

    local card_num=1
    while IFS= read -r url; do
        if [[ -n \"\$url\" ]]; then
            local post_slug=\$(echo \"\$url\" | sed 's|.*/||')

            # Get post details
            local post_id=\$(wp post list --post_type=post --name=\$post_slug --format=ids | head -1)

            if [[ -n \"\$post_id\" ]]; then
                local post_title=\$(wp post get \$post_id --field=post_title | sed 's/&amp;/\&/g')
                local thumbnail_id=\$(wp post meta get \$post_id '_thumbnail_id' 2>/dev/null || echo '')

                if [[ -n \"\$thumbnail_id\" ]]; then
                    local image_url=\$(wp post get \$thumbnail_id --field=guid 2>/dev/null || echo 'No image')
                    local image_filename=\$(basename \"\$image_url\" 2>/dev/null || echo 'No image')
                else
                    local image_url='No featured image'
                    local image_filename='No image'
                fi

                echo \"Card #\$card_num:\"
                echo \"  📝 Title: \$post_title\"
                echo \"  🔗 Post URL: \$url\"
                echo \"  🆔 Post ID: \$post_id\"
                echo \"  🖼️  Hero Image: \$image_filename\"
                echo \"  📸 Full URL: \$image_url\"
                echo ''

                ((card_num++))
            else
                echo \"Card #\$card_num:\"
                echo \"  ❌ Post not found for URL: \$url\"
                echo \"  🔗 URL: \$url\"
                echo ''
                ((card_num++))
            fi
        fi
    done <<< \"\$urls\"

    if [[ \$card_num -eq 1 ]]; then
        echo '❌ No article cards found in this page'
    else
        echo \"✅ Found \$((card_num-1)) article cards\"
    fi
    echo ''
}

# Show mappings for all L1 pages
show_page_mappings 'plan-your-visit' 'Plan Your Visit'
show_page_mappings 'tickets-tours' 'Tickets & Tours'
show_page_mappings 'what-to-see' 'What to See'

echo '════════════════════════════════════════════'
echo '📊 SUMMARY'
echo '════════════════════════════════════════════'
echo ''
echo 'This shows which hero image should be used for each article card.'
echo 'Each card will get the featured image from its corresponding post.'
echo ''
echo 'Next steps:'
echo '1. Review the mappings above'
echo '2. Confirm if the image assignments look correct'
echo '3. Run the update script to apply the changes'
"

echo "✅ Card mappings displayed for $HOSTNAME"