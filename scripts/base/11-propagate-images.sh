#!/bin/bash
set -euo pipefail

# Propagate L3 Article Images to L1 Pages
# Usage: ./scripts/base/11-propagate-images.sh <hostname>

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 operagarnier-guide.com"
    exit 1
fi

HOSTNAME="$1"

# Get WP Path for the site
WP_PATH=$(ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "find /home*/${BLUEHOST_USER}/public_html/website_*/ -name wp-config.php -exec grep -l '${HOSTNAME}' {} \; 2>/dev/null | head -1 | xargs dirname" || echo "")

if [[ -z "$WP_PATH" ]]; then
    echo "❌ Could not find WordPress installation for $HOSTNAME"
    exit 1
fi

echo "📍 Found WordPress at: $WP_PATH"
echo "🖼️  Propagating L3 article images to L1 category pages..."

ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
cd '$WP_PATH'

echo '=== Finding Representative Posts for Each Category ==='

# Find representative posts by searching for key terms
echo '1. TICKETS & TOURS category:'
TICKETS_POST=\$(wp post list --post_type=post --s='entry ticket' --format=ids | tr ' ' '\n' | head -1)
if [[ -z \"\$TICKETS_POST\" ]]; then
    TICKETS_POST=\$(wp post list --post_type=post --s='ticket' --format=ids | tr ' ' '\n' | head -1)
fi
echo \"   Representative post: \$TICKETS_POST - \$(wp post get \$TICKETS_POST --field=post_title 2>/dev/null)\"
TICKETS_IMAGE=\$(wp post meta get \$TICKETS_POST '_thumbnail_id' 2>/dev/null || echo '')

echo '2. PLAN YOUR VISIT category:'
PLAN_POST=\$(wp post list --post_type=post --s='best time' --format=ids | tr ' ' '\n' | head -1)
if [[ -z \"\$PLAN_POST\" ]]; then
    PLAN_POST=\$(wp post list --post_type=post --s='opening hours' --format=ids | tr ' ' '\n' | head -1)
fi
echo \"   Representative post: \$PLAN_POST - \$(wp post get \$PLAN_POST --field=post_title 2>/dev/null)\"
PLAN_IMAGE=\$(wp post meta get \$PLAN_POST '_thumbnail_id' 2>/dev/null || echo '')

echo '3. WHAT TO SEE category:'
SEE_POST=\$(wp post list --post_type=post --s='grand staircase' --format=ids | tr ' ' '\n' | head -1)
if [[ -z \"\$SEE_POST\" ]]; then
    SEE_POST=\$(wp post list --post_type=post --s='auditorium' --format=ids | tr ' ' '\n' | head -1)
fi
echo \"   Representative post: \$SEE_POST - \$(wp post get \$SEE_POST --field=post_title 2>/dev/null)\"
SEE_IMAGE=\$(wp post meta get \$SEE_POST '_thumbnail_id' 2>/dev/null || echo '')

echo ''
echo '=== Finding L1 Category Pages ==='
TICKETS_PAGE=\$(wp post list --post_type=page --name=tickets-tours --format=ids | head -1)
PLAN_PAGE=\$(wp post list --post_type=page --name=plan-your-visit --format=ids | head -1)
SEE_PAGE=\$(wp post list --post_type=page --name=what-to-see --format=ids | head -1)

echo \"Tickets & Tours page ID: \$TICKETS_PAGE\"
echo \"Plan Your Visit page ID: \$PLAN_PAGE\"
echo \"What to See page ID: \$SEE_PAGE\"

echo ''
echo '=== Applying Featured Images to L1 Pages ==='

if [[ -n \"\$TICKETS_PAGE\" && -n \"\$TICKETS_IMAGE\" ]]; then
    wp post meta update \$TICKETS_PAGE '_thumbnail_id' \$TICKETS_IMAGE
    echo \"✅ Tickets & Tours page ← Image \$TICKETS_IMAGE\"
fi

if [[ -n \"\$PLAN_PAGE\" && -n \"\$PLAN_IMAGE\" ]]; then
    wp post meta update \$PLAN_PAGE '_thumbnail_id' \$PLAN_IMAGE
    echo \"✅ Plan Your Visit page ← Image \$PLAN_IMAGE\"
fi

if [[ -n \"\$SEE_PAGE\" && -n \"\$SEE_IMAGE\" ]]; then
    wp post meta update \$SEE_PAGE '_thumbnail_id' \$SEE_IMAGE
    echo \"✅ What to See page ← Image \$SEE_IMAGE\"
fi

echo ''
echo '=== Clearing Cache ==='
wp cache flush >/dev/null 2>&1
wp transient delete --all >/dev/null 2>&1

echo \"\"
echo \"✅ Image propagation completed for $HOSTNAME\"
echo \"🌐 L1 pages now have featured images from representative L3 articles\"
"

echo "🎯 Image propagation completed!"
echo ""
echo "📸 Images applied:"
echo "   • Tickets & Tours page ← Entry ticket image"
echo "   • Plan Your Visit page ← Best time/opening hours image"
echo "   • What to See page ← Grand staircase/auditorium image"