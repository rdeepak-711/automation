#!/usr/bin/env bash
# Audit Step 1: Page Inventory
# Fetches all published posts+pages with title, slug, category, featured image URL
# Output: JSON → output/audit/01-inventory-<hostname>.json
# Usage: ./01-page-inventory.sh [hostname]

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOSTNAME="${1:-topkapipalace-guide.com}"
WP_PATH="$(resolve_wp_path "$HOSTNAME")"
[[ -z "$WP_PATH" ]] && echo "Unknown hostname: $HOSTNAME" >&2 && exit 1

OUT="$(save_output "01-inventory" "$HOSTNAME" "json")"

echo "=== Page Inventory: $HOSTNAME ===" >&2
echo "WP path : $WP_PATH" >&2
echo "Output  : $OUT" >&2
echo "" >&2

# Single-round-trip PHP eval: fetch all posts + pages in one call
PHP_SCRIPT=$(cat <<'PHPEOF'
<?php
$posts = get_posts(['post_type'=>'post','post_status'=>'publish','numberposts'=>-1,'orderby'=>'title','order'=>'ASC']);
$pages = get_posts(['post_type'=>'page','post_status'=>'publish','numberposts'=>-1,'orderby'=>'title','order'=>'ASC']);

$out = ['posts'=>[],'pages'=>[]];

foreach ($posts as $p) {
    $cats     = get_the_terms($p->ID,'category') ?: [];
    $thumb_id = get_post_thumbnail_id($p->ID);
    $thumb    = $thumb_id ? wp_get_attachment_image_url($thumb_id,'medium_large') : null;
    $seo_title = get_post_meta($p->ID, 'rank_math_title', true) ?: null;
    $seo_desc  = get_post_meta($p->ID, 'rank_math_description', true) ?: null;
    $out['posts'][] = [
        'id'        => $p->ID,
        'slug'      => $p->post_name,
        'title'     => $p->post_title,
        'seo_title' => $seo_title,
        'seo_desc'  => $seo_desc,
        'category'  => array_values(array_map(fn($c)=>$c->slug, $cats)),
        'cat_names' => array_values(array_map(fn($c)=>$c->name, $cats)),
        'image'     => $thumb,
        'has_image' => (bool)$thumb,
    ];
}
foreach ($pages as $p) {
    $thumb_id = get_post_thumbnail_id($p->ID);
    $thumb    = $thumb_id ? wp_get_attachment_image_url($thumb_id,'medium_large') : null;
    $out['pages'][] = [
        'id'        => $p->ID,
        'slug'      => $p->post_name,
        'title'     => $p->post_title,
        'image'     => $thumb,
        'has_image' => (bool)$thumb,
    ];
}

$out['summary'] = [
    'total_posts'         => count($out['posts']),
    'total_pages'         => count($out['pages']),
    'posts_missing_image' => count(array_filter($out['posts'], fn($p)=>!$p['has_image'])),
    'pages_missing_image' => count(array_filter($out['pages'], fn($p)=>!$p['has_image'])),
];

echo json_encode($out, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
PHPEOF
)

# Upload + run
echo "$PHP_SCRIPT" | ssh_run "cat > /tmp/audit_inventory.php"
ssh_run "wp eval-file /tmp/audit_inventory.php --path=$WP_PATH" | tee "$OUT"

echo "" >&2
echo "=== Summary ===" >&2
python3 - "$OUT" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
s = d['summary']
print(f"Posts : {s['total_posts']} published  ({s['posts_missing_image']} missing featured image)")
print(f"Pages : {s['total_pages']} published  ({s['pages_missing_image']} missing featured image)")
print()
cats = {}
for p in d['posts']:
    for c in p['category']:
        cats[c] = cats.get(c, 0) + 1
print("Posts by category:")
for c, n in sorted(cats.items(), key=lambda x: -x[1]):
    print(f"  {c:<35} {n}")
PYEOF
