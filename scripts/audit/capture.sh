#!/usr/bin/env bash
# Layer 1: CAPTURE — fat site snapshot in one SSH round-trip
# Grabs: posts, pages, full content, all meta, WP options, GP elements, custom_css
# Pre-computes: link arrays (internal/absolute/affiliate/external) + flags per post
# Output: output/audit/snapshots/<hostname>-<date>.json + -latest.json symlink
# Usage: ./capture.sh [hostname]

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOSTNAME="${1:-plitvicelakes-guide.com}"
WP_PATH="$(resolve_wp_path "$HOSTNAME")"
[[ -z "$WP_PATH" ]] && echo "Unknown hostname: $HOSTNAME" >&2 && exit 1

STAMP="$(date +%Y%m%d-%H%M%S)"
SNAP_DIR="$OUTPUT_DIR/snapshots"
mkdir -p "$SNAP_DIR"

OUT="$SNAP_DIR/${HOSTNAME}-${STAMP}.json"
LATEST="$SNAP_DIR/${HOSTNAME}-latest.json"

echo "=== CAPTURE: $HOSTNAME ===" >&2
echo "WP path : $WP_PATH" >&2
echo "Output  : $OUT" >&2

# PHP snapshot. __HOSTNAME__ token replaced below with actual hostname.
PHP_SCRIPT=$(cat <<'PHPEOF'
<?php
$HOSTNAME = '__HOSTNAME__';

function extract_links($content, $hostname) {
    $result = [
        'internal_relative' => [],
        'internal_absolute' => [],
        'affiliate'         => [],
        'external'          => [],
    ];
    preg_match_all('/href="([^"]+)"/i', $content, $matches);
    $host_quoted = preg_quote($hostname, '#');
    foreach ($matches[1] as $href) {
        if (stripos($href, 'getyourguide.com') !== false
            || stripos($href, 'tiqets.com') !== false
            || stripos($href, 'viator.com') !== false) {
            $result['affiliate'][] = $href;
        } elseif (preg_match('#^https?://(?:www\.)?' . $host_quoted . '#i', $href)) {
            $result['internal_absolute'][] = $href;
        } elseif (stripos($href, 'http') === 0) {
            $result['external'][] = $href;
        } elseif (strpos($href, '/') === 0) {
            $result['internal_relative'][] = $href;
        }
    }
    foreach ($result as $k => $v) {
        $result[$k] = array_values(array_unique($v));
    }
    return $result;
}

function compute_flags($content, $hostname) {
    $host_quoted = preg_quote($hostname, '#');
    return [
        'has_backtick_html'    => strpos($content, '```html') !== false,
        'has_padding_40'       => strpos($content, 'padding: 40px 0 0 0') !== false,
        'has_padding_24'       => strpos($content, 'padding: 24px 0 0 0') !== false,
        'has_placeholder_gif'  => strpos($content, 'data:image/gif;base64') !== false,
        'has_absolute_urls'    => (bool) preg_match('#https?://(?:www\.)?' . $host_quoted . '#i', $content),
        'has_faq_onclick'      => (bool) preg_match('/class="att-faq-item__q"[^>]*onclick=/i', $content),
    ];
}

function collect_items($type, $hostname) {
    $items = get_posts([
        'post_type'   => $type,
        'post_status' => 'publish',
        'numberposts' => -1,
        'orderby'     => 'title',
        'order'       => 'ASC',
    ]);
    $out = [];
    foreach ($items as $p) {
        $thumb_id   = get_post_thumbnail_id($p->ID);
        $thumb_url  = $thumb_id ? wp_get_attachment_image_url($thumb_id, 'medium_large') : null;
        $thumb_meta = $thumb_id ? wp_get_attachment_metadata($thumb_id) : null;
        $cats = [];
        foreach (get_the_terms($p->ID, 'category') ?: [] as $c) {
            $cats[] = ['id' => (int)$c->term_id, 'slug' => $c->slug, 'name' => $c->name];
        }
        $out[] = [
            'id'             => (int) $p->ID,
            'slug'           => $p->post_name,
            'title'          => $p->post_title,
            'post_type'      => $p->post_type,
            'status'         => $p->post_status,
            'date'           => $p->post_date,
            'modified'       => $p->post_modified,
            'word_count'     => str_word_count(strip_tags($p->post_content)),
            'content'        => $p->post_content,
            'categories'     => $cats,
            'featured_image' => $thumb_id ? [
                'id'     => (int) $thumb_id,
                'url'    => $thumb_url,
                'width'  => $thumb_meta['width']  ?? null,
                'height' => $thumb_meta['height'] ?? null,
            ] : null,
            'meta' => [
                'rank_math_title'         => get_post_meta($p->ID, 'rank_math_title', true) ?: null,
                'rank_math_description'   => get_post_meta($p->ID, 'rank_math_description', true) ?: null,
                'rank_math_canonical_url' => get_post_meta($p->ID, 'rank_math_canonical_url', true) ?: null,
                'rank_math_robots'        => get_post_meta($p->ID, 'rank_math_robots', true) ?: null,
            ],
            'links' => extract_links($p->post_content, $hostname),
            'flags' => compute_flags($p->post_content, $hostname),
        ];
    }
    return $out;
}

// Site-wide options
$custom_css_post = wp_get_custom_css_post();
$site = [
    'hostname'            => $HOSTNAME,
    'blogname'            => get_option('blogname'),
    'blogdescription'     => get_option('blogdescription'),
    'home'                => get_option('home'),
    'siteurl'             => get_option('siteurl'),
    'permalink_structure' => get_option('permalink_structure'),
    'site_icon'           => (int) get_option('site_icon'),
    'custom_css'          => $custom_css_post ? $custom_css_post->post_content : '',
    'options'             => [
        'generate_spacing_settings'    => get_option('generate_spacing_settings'),
        'generate_menu_plus_settings'  => get_option('generate_menu_plus_settings'),
        'generate_settings'            => get_option('generate_settings'),
        'wp_rocket_settings'           => get_option('wp_rocket_settings'),
    ],
    'active_plugins' => get_option('active_plugins', []),
];

// Categories
$categories = [];
foreach (get_categories(['hide_empty' => false]) as $cat) {
    $categories[] = [
        'id'    => (int) $cat->term_id,
        'slug'  => $cat->slug,
        'name'  => $cat->name,
        'count' => (int) $cat->count,
    ];
}

// GP Elements (menu, footer, hooks, etc)
$gp_elements = [];
foreach (get_posts(['post_type' => 'gp_elements', 'post_status' => 'publish', 'numberposts' => -1]) as $el) {
    $gp_elements[] = [
        'id'      => (int) $el->ID,
        'title'   => $el->post_title,
        'hook'    => get_post_meta($el->ID, '_generate_hook', true),
        'type'    => get_post_meta($el->ID, '_generate_element_type', true),
        'content' => get_post_meta($el->ID, '_generate_element_content', true) ?: $el->post_content,
    ];
}

$posts = collect_items('post', $HOSTNAME);
$pages = collect_items('page', $HOSTNAME);

// Summary for quick CLI readout
$summary = [
    'captured_at'         => date('c'),
    'total_posts'         => count($posts),
    'total_pages'         => count($pages),
    'posts_by_category'   => [],
    'posts_missing_image' => count(array_filter($posts, fn($p)=>$p['featured_image']===null)),
    'pages_missing_image' => count(array_filter($pages, fn($p)=>$p['featured_image']===null)),
    'posts_with_flags'    => [
        'backtick_html'   => count(array_filter($posts, fn($p)=>$p['flags']['has_backtick_html'])),
        'padding_40'      => count(array_filter($posts, fn($p)=>$p['flags']['has_padding_40'])),
        'placeholder_gif' => count(array_filter($posts, fn($p)=>$p['flags']['has_placeholder_gif'])),
        'absolute_urls'   => count(array_filter($posts, fn($p)=>$p['flags']['has_absolute_urls'])),
        'faq_onclick'     => count(array_filter($posts, fn($p)=>$p['flags']['has_faq_onclick'])),
    ],
];
foreach ($posts as $p) {
    foreach ($p['categories'] as $c) {
        $slug = $c['slug'];
        $summary['posts_by_category'][$slug] = ($summary['posts_by_category'][$slug] ?? 0) + 1;
    }
}

echo json_encode([
    'site'        => $site,
    'categories'  => $categories,
    'gp_elements' => $gp_elements,
    'posts'       => $posts,
    'pages'       => $pages,
    'summary'     => $summary,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
PHPEOF
)

# Substitute hostname token
PHP_SCRIPT="${PHP_SCRIPT//__HOSTNAME__/$HOSTNAME}"

# Upload + run
echo "$PHP_SCRIPT" | ssh_run "cat > /tmp/audit_capture.php"
ssh_run "wp eval-file /tmp/audit_capture.php --path=$WP_PATH --skip-themes --skip-plugins=wp-rocket" > "$OUT"

# Validate: JSON must parse
if ! python3 -c "import json; json.load(open('$OUT'))" 2>/dev/null; then
  echo "ERROR: snapshot is not valid JSON — $OUT" >&2
  head -5 "$OUT" >&2
  exit 1
fi

# Update latest symlink
ln -sfn "$(basename "$OUT")" "$LATEST"

# Summary to stderr
python3 - "$OUT" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
s = d['summary']
print(f"\nSnapshot captured: {s['captured_at']}", file=sys.stderr)
print(f"Posts : {s['total_posts']} ({s['posts_missing_image']} missing image)", file=sys.stderr)
print(f"Pages : {s['total_pages']} ({s['pages_missing_image']} missing image)", file=sys.stderr)
print(f"Categories: {len(d['categories'])}", file=sys.stderr)
print(f"GP Elements: {len(d['gp_elements'])}", file=sys.stderr)
print(f"\nPosts by category:", file=sys.stderr)
for c, n in sorted(s['posts_by_category'].items(), key=lambda x: -x[1]):
    print(f"  {c:<30} {n}", file=sys.stderr)
print(f"\nContent flags (# posts with):", file=sys.stderr)
for flag, n in s['posts_with_flags'].items():
    marker = '!' if n > 0 else ' '
    print(f"  [{marker}] {flag:<20} {n}", file=sys.stderr)
PYEOF

echo "" >&2
echo "Snapshot: $OUT" >&2
echo "Latest  : $LATEST" >&2
