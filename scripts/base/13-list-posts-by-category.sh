#!/bin/bash
set -euo pipefail

# List All Posts by Category with Hero Images
# Usage: ./scripts/base/13-list-posts-by-category.sh <hostname>

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
echo "📋 Listing all posts by category with their hero images..."

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

echo '=== All Categories and Their Posts ==='
echo ''

# Get all categories
CATEGORIES=\$(wp term list category --format=csv --fields=term_id,name,slug | tail -n +2)

while IFS=',' read -r cat_id cat_name cat_slug; do
    echo \"📁 Category: \$cat_name (slug: \$cat_slug, ID: \$cat_id)\"
    echo \"$([[ '\$cat_slug' == 'plan-your-visit' ]] && echo '   → L1 Page: https://$HOSTNAME/plan-your-visit/')\"
    echo \"$([[ '\$cat_slug' == 'tickets-tours' ]] && echo '   → L1 Page: https://$HOSTNAME/tickets-tours/')\"
    echo \"$([[ '\$cat_slug' == 'what-to-see' ]] && echo '   → L1 Page: https://$HOSTNAME/what-to-see/')\"
    echo ''

    # Get all posts in this category
    POSTS=\$(wp post list --post_type=post --category=\$cat_id --format=csv --fields=ID,post_title,post_name,post_date | tail -n +2)

    if [[ -n \"\$POSTS\" ]]; then
        echo '   Posts in this category:'
        while IFS=',' read -r post_id post_title post_slug post_date; do
            # Get featured image
            THUMBNAIL_ID=\$(wp post meta get \$post_id '_thumbnail_id' 2>/dev/null || echo '')
            if [[ -n \"\$THUMBNAIL_ID\" ]]; then
                IMAGE_URL=\$(wp post get \$THUMBNAIL_ID --field=guid 2>/dev/null || echo 'No image')
                IMAGE_FILENAME=\$(basename \"\$IMAGE_URL\" 2>/dev/null || echo 'No image')
            else
                IMAGE_URL='No featured image'
                IMAGE_FILENAME='No image'
            fi

            echo \"   ├─ ID: \$post_id | \$post_title\"
            echo \"   │  URL: https://$HOSTNAME/\$cat_slug/\$post_slug/\"
            echo \"   │  Hero Image: \$IMAGE_FILENAME\"
            echo \"   │  Full Image URL: \$IMAGE_URL\"
            echo \"   │  Date: \$post_date\"
            echo \"   │\"
        done <<< \"\$POSTS\"
    else
        echo '   └─ No posts in this category'
    fi

    echo ''
    echo '─────────────────────────────────────────────'
    echo ''
done <<< \"\$CATEGORIES\"

echo ''
echo '=== Summary ==='
TOTAL_POSTS=\$(wp post list --post_type=post --format=count)
POSTS_WITH_IMAGES=\$(wp post list --post_type=post --meta_key=_thumbnail_id --format=count)
POSTS_WITHOUT_IMAGES=\$((TOTAL_POSTS - POSTS_WITH_IMAGES))

echo \"Total posts: \$TOTAL_POSTS\"
echo \"Posts with featured images: \$POSTS_WITH_IMAGES\"
echo \"Posts without featured images: \$POSTS_WITHOUT_IMAGES\"
"

echo "✅ Post listing completed for $HOSTNAME"