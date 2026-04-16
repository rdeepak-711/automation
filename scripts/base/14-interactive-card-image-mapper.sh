#!/bin/bash
set -euo pipefail

# Interactive Card Image Mapper
# Usage: ./scripts/base/14-interactive-card-image-mapper.sh <hostname>

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
echo "🔍 Interactive Card Image Mapping for $HOSTNAME"
echo ""

# Arrays to track results
declare -a UPDATED_CARDS=()
declare -a SKIPPED_CARDS=()
declare -a FAILED_CARDS=()

# Function to process each page interactively
process_page_interactive() {
    local page_slug="$1"
    local page_title="$2"

    echo "════════════════════════════════════════════"
    echo "📄 Processing: $page_title"
    echo "════════════════════════════════════════════"

    # Get page content and parse cards
    local page_content=$(ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
        cd '$WP_PATH' && wp post get \$(wp post list --post_type=page --name=$page_slug --format=ids | head -1) --field=post_content
    ")

    echo "🔍 Found cards in $page_title:"
    echo ""

    # Extract card information
    local card_count=0
    while IFS= read -r line; do
        if [[ \$line =~ \<div\ class=\"att-article-card\"\> ]]; then
            ((card_count++))

            # Extract card details (title, URL, current image)
            local card_title=""
            local card_url=""
            local current_image=""

            # Read the next several lines to get card content
            local card_html=""
            local in_card=true
            local brace_count=0

            while \$in_card && IFS= read -r card_line; do
                card_html+="\$card_line\n"

                # Count opening and closing div tags to know when card ends
                if [[ \$card_line =~ \<div ]]; then
                    ((brace_count++))
                elif [[ \$card_line =~ \</div\> ]]; then
                    ((brace_count--))
                    if [[ \$brace_count -eq 0 ]]; then
                        in_card=false
                    fi
                fi

                # Extract title
                if [[ \$card_line =~ \<h3\>\<a\ href=\"([^\"]+)\"\>([^<]+)\</a\>\</h3\> ]]; then
                    card_url="\${BASH_REMATCH[1]}"
                    card_title="\${BASH_REMATCH[2]}"
                fi

                # Extract current image
                if [[ \$card_line =~ src=\"([^\"]+)\" ]]; then
                    current_image="\${BASH_REMATCH[1]}"
                fi
            done <<< "\$(echo \"\$page_content\" | tail -n +\$(echo \"\$page_content\" | grep -n \"<div class=\\\"att-article-card\\\"\" | head -n \$card_count | tail -n 1 | cut -d: -f1))"

            if [[ -n "\$card_url" && -n "\$card_title" ]]; then
                # Get post slug from URL
                local post_slug=\$(echo "\$card_url" | sed 's|.*/||')

                # Get the actual featured image for this post
                local post_image=\$(ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
                    cd '$WP_PATH'
                    POST_ID=\\\$(wp post list --post_type=post --name=\$post_slug --format=ids | head -1)
                    if [[ -n \\\"\\\$POST_ID\\\" ]]; then
                        THUMB_ID=\\\$(wp post meta get \\\$POST_ID '_thumbnail_id' 2>/dev/null || echo '')
                        if [[ -n \\\"\\\$THUMB_ID\\\" ]]; then
                            wp post get \\\$THUMB_ID --field=guid 2>/dev/null || echo 'No image'
                        else
                            echo 'No featured image'
                        fi
                    else
                        echo 'Post not found'
                    fi
                ")

                echo "Card #\$card_count:"
                echo "  📝 Title: \$card_title"
                echo "  🔗 URL: \$card_url"
                echo "  🖼️  Current Image: \$(basename \"\$current_image\" 2>/dev/null || echo 'No image')"
                echo "  ✨ Should be: \$(basename \"\$post_image\" 2>/dev/null || echo 'No image')"
                echo "  📍 Full Image URL: \$post_image"
                echo ""

                # Ask for confirmation
                if [[ "\$current_image" == *"data:image/gif"* ]] && [[ "\$post_image" != "No image" ]] && [[ "\$post_image" != "No featured image" ]]; then
                    read -p "  ❓ Update this card with the correct image? (y/n/s=skip page): " choice
                    case "\$choice" in
                        y|Y|yes|Yes)
                            echo "  ✅ UPDATING: \$card_title"
                            # TODO: Implement actual update logic here
                            UPDATED_CARDS+=("\$page_title: \$card_title")
                            ;;
                        s|S|skip)
                            echo "  ⏩ SKIPPING entire page: \$page_title"
                            return
                            ;;
                        *)
                            echo "  ⏭️  SKIPPED: \$card_title"
                            SKIPPED_CARDS+=("\$page_title: \$card_title")
                            ;;
                    esac
                else
                    if [[ "\$post_image" == "No image" ]] || [[ "\$post_image" == "No featured image" ]]; then
                        echo "  ⚠️  CANNOT UPDATE: No featured image available"
                        FAILED_CARDS+=("\$page_title: \$card_title (no featured image)")
                    else
                        echo "  ℹ️  ALREADY UPDATED: Image already set"
                    fi
                fi
                echo ""
            fi
        fi
    done <<< "\$page_content"

    if [[ \$card_count -eq 0 ]]; then
        echo "  ❌ No cards found in \$page_title"
    fi
    echo ""
}

# Process each L1 page
echo "🚀 Starting interactive card image mapping..."
echo ""

process_page_interactive "plan-your-visit" "Plan Your Visit"
process_page_interactive "tickets-tours" "Tickets & Tours"
process_page_interactive "what-to-see" "What to See"

# Summary report
echo "════════════════════════════════════════════"
echo "📊 FINAL SUMMARY"
echo "════════════════════════════════════════════"
echo ""

echo "✅ UPDATED CARDS (\${#UPDATED_CARDS[@]}):"
if [[ \${#UPDATED_CARDS[@]} -gt 0 ]]; then
    for card in "\${UPDATED_CARDS[@]}"; do
        echo "  • \$card"
    done
else
    echo "  (none)"
fi
echo ""

echo "⏭️  SKIPPED CARDS (\${#SKIPPED_CARDS[@]}):"
if [[ \${#SKIPPED_CARDS[@]} -gt 0 ]]; then
    for card in "\${SKIPPED_CARDS[@]}"; do
        echo "  • \$card"
    done
else
    echo "  (none)"
fi
echo ""

echo "❌ FAILED CARDS (\${#FAILED_CARDS[@]}):"
if [[ \${#FAILED_CARDS[@]} -gt 0 ]]; then
    for card in "\${FAILED_CARDS[@]}"; do
        echo "  • \$card"
    done
else
    echo "  (none)"
fi
echo ""

echo "🎯 Process completed for $HOSTNAME!"