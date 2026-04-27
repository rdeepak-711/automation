#!/usr/bin/env bash
# fix-css-arrow.sh — Fix CSS bullet arrow on L1 pages
#
# Problem: content:'2192' renders as literal text instead of → arrow.
# Fix:     content:'2192' → content:'\2192' (add backslash for CSS unicode escape)
#
# Affects: plan-your-visit (.att-practical-card ul li::before)
#          tickets         (inline style block)
#          what-to-see     (.att-guide-card ul li::before)
#
# Usage:
#   ./scripts/audit/fix-css-arrow.sh <hostname>
#
# Example:
#   ./scripts/audit/fix-css-arrow.sh pyramidsofgiza-guide.com

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

HOSTNAME="${1:-}"
[[ -z "$HOSTNAME" ]] && { echo "Usage: $0 <hostname>"; exit 1; }

WP_PATH="$(resolve_wp_path "$HOSTNAME")"
[[ -z "$WP_PATH" ]] && { echo "ERROR: unknown hostname '$HOSTNAME'"; exit 1; }

echo "Host:    $HOSTNAME"
echo "WP path: $WP_PATH"
echo ""

PHP_FILE="$(mktemp /tmp/fix_css_arrow_XXXXX.php)"
trap 'rm -f "$PHP_FILE"' EXIT

cat > "$PHP_FILE" << 'PHPEOF'
<?php
// Must use $wpdb->update directly — wp_update_post strips backslashes from CSS content
global $wpdb;
$slugs = ['plan-your-visit', 'tickets', 'what-to-see'];

foreach ($slugs as $slug) {
    $pg = get_posts(['post_type'=>'page','name'=>$slug,'numberposts'=>1])[0] ?? null;
    if (!$pg) { echo "$slug: NOT FOUND\n"; continue; }

    $raw = $wpdb->get_var("SELECT post_content FROM $wpdb->posts WHERE ID = " . $pg->ID);
    $new = str_replace("content:'2192'",  "content:'\\2192'",  $raw);
    $new = str_replace("content: '2192'", "content: '\\2192'", $new);

    if ($new === $raw) {
        echo "$slug: no match — already fixed or pattern not found\n";
        continue;
    }

    $wpdb->update($wpdb->posts, ['post_content' => $new], ['ID' => $pg->ID]);
    echo "$slug: OK — fixed\n";
}
PHPEOF

ssh_upload "$PHP_FILE" "/tmp/fix_css_arrow.php"
wp_run "$WP_PATH" eval-file /tmp/fix_css_arrow.php
ssh_run "rm -f /tmp/fix_css_arrow.php"

echo ""
echo "Done. Hard-refresh site to verify arrows render correctly."
