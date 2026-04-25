#!/usr/bin/env bash
set -euo pipefail

# Add Firestorm Additional CSS to a live WordPress site over SSH + WP-CLI.
# Writes into WordPress Customizer "Additional CSS" storage for active theme.
#
# Usage:
#   WP_SSH_HOST=50.6.155.174 WP_SSH_USER=dpskbcmy WP_SSH_KEY=~/.ssh/id_rsa_bluehost2 \
#     ./scripts/base/configure-additional-css.sh /home1/dpskbcmy/public_html/website_topkapi
#
# Required env:
#   WP_SSH_HOST, WP_SSH_USER
# Optional env:
#   WP_SSH_KEY

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <wp_path>"
    exit 1
fi

WP_PATH="${1%/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Preserve SSH vars passed by caller before loading .env.
_SAVED_HOST="${WP_SSH_HOST:-}"
_SAVED_USER="${WP_SSH_USER:-}"
_SAVED_KEY="${WP_SSH_KEY:-}"

ENV_FILE="$SCRIPT_DIR/../../.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

[[ -n "$_SAVED_HOST" ]] && WP_SSH_HOST="$_SAVED_HOST"
[[ -n "$_SAVED_USER" ]] && WP_SSH_USER="$_SAVED_USER"
[[ -n "$_SAVED_KEY"  ]] && WP_SSH_KEY="$_SAVED_KEY"

[[ -n "${WP_SSH_HOST:-}" ]] || { echo "ERROR: WP_SSH_HOST not set"; exit 1; }
[[ -n "${WP_SSH_USER:-}" ]] || { echo "ERROR: WP_SSH_USER not set"; exit 1; }

SSH_KEY_OPTS=()
if [[ -n "${WP_SSH_KEY:-}" ]]; then
    _KEY="${WP_SSH_KEY/#\~/$HOME}"
    SSH_KEY_OPTS=(-i "$_KEY" -o IdentitiesOnly=yes)
fi
SSH_KEY_OPTS+=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)

_SSH_PREFIX="SSH_AUTH_SOCK="  # always clear agent to prevent cPHulk/CSF port-22 blocks from wrong-key failures

_SSH() { env ${_SSH_PREFIX} ssh "${SSH_KEY_OPTS[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "$@"; }
_SCP() { env ${_SSH_PREFIX} scp "${SSH_KEY_OPTS[@]}" "$@"; }

PHP_LOCAL="$(mktemp)"
trap 'rm -f "$PHP_LOCAL"' EXIT

cat > "$PHP_LOCAL" <<'PHP'
<?php
$start = '/* BEGIN FIRESTORM ADDITIONAL CSS */';
$end   = '/* END FIRESTORM ADDITIONAL CSS */';
$block = <<<'CSS'
/* BEGIN FIRESTORM ADDITIONAL CSS */
/* ========= Author Box (GenerateBlocks) ========= */
.gb-container-9f3e5cb3{
  background:#fff;
  border:1px solid #e5e7eb;
  border-left:6px solid #ff0000;
  border-radius:18px;
  padding:22px 22px 18px;
  box-shadow:0 14px 34px rgba(15,23,42,.08);
}

/* --- MAIN LAYOUT FIX (prevents avatar slice + aligns sections) --- */
.gb-grid-wrapper-8e06dcf5{
  display:grid !important;
  grid-template-columns: 96px minmax(0,1fr);
  grid-template-areas:
    "avatar header"
    "bio bio";
  column-gap:22px;
  row-gap:14px;
  align-items:start;
}

/* Reset GB column widths/flex that can squeeze content */
.gb-grid-column-8ef3038b,
.gb-grid-column-8eee357e,
.gb-grid-column-d53bcd84{
  width:auto !important;
  max-width:none !important;
  flex:initial !important;
  min-width:0 !important;
}

.gb-grid-column-8ef3038b{ grid-area: avatar; }
.gb-grid-column-8eee357e{ grid-area: header; }
.gb-grid-column-d53bcd84{ grid-area: bio; }

/* --- AVATAR: force stable box so it never collapses --- */
.gb-container-8ef3038b{
  width:96px !important;
  min-width:96px !important;
}

.gb-container-8ef3038b img.avatar{
  display:block;
  width:86px !important;
  height:86px !important;
  border-radius:999px !important;
  object-fit:cover;
  border:none !important;
  outline:none !important;
  box-shadow:0 10px 24px rgba(0,0,0,.12);
}

/* --- HEADER ROW: label left, socials right --- */
.gb-grid-wrapper-8542265a{
  display:flex !important;
  align-items:center;
  justify-content:space-between;
  gap:14px;
  margin:2px 0 10px;
}

.gb-grid-column-1e018880,
.gb-grid-column-bd08faf2{
  width:auto !important;
  max-width:none !important;
  flex:initial !important;
}

.gb-headline-f9092970{
  font-size:.82rem;
  letter-spacing:.08em;
  text-transform:uppercase;
  color:#6b7280;
  margin:0;
}

/* Social icons */
.gb-container-bd08faf2{
  display:flex;
  align-items:center;
  justify-content:flex-end;
  gap:10px;
  flex-wrap:wrap;
}

.gb-container-bd08faf2 a.gb-button{
  width:40px;
  height:40px;
  padding:0 !important;
  border-radius:999px !important;
  background:#ffffff !important;
  border:none !important;
  color:#ff0000 !important;
  display:inline-flex;
  align-items:center;
  justify-content:center;
  box-shadow:none !important;
  transition:transform .15s ease, background .15s ease, color .15s ease;
}

.gb-container-bd08faf2 a.gb-button:hover{
  background:#ff0000 !important;
  color:#ffffff !important;
  transform:translateY(-1px);
  box-shadow:none !important;
}

.gb-container-bd08faf2 a.gb-button:focus,
.gb-container-bd08faf2 a.gb-button:focus-visible{
  box-shadow:none !important;
  outline:none !important;
}

.gb-container-bd08faf2 a.gb-button svg{
  width:18px;
  height:18px;
}

/* Author name */
.gb-headline-e4d2243d{
  margin:0;
}

.gb-headline-e4d2243d a{
  color:#111827;
  text-decoration:none;
  font-weight:800;
  font-size:1.55rem;
  line-height:1.15;
  border-bottom:3px solid rgba(255,0,0,.25);
  padding-bottom:2px;
}

.gb-headline-e4d2243d a:hover{
  border-bottom-color:rgba(255,0,0,.55);
}

/* Bio block */
.gb-headline-27ec0f85{
  background:transparent !important;
  border:none !important;
  border-radius:0 !important;
  padding:0 !important;
  color:#374151;
  font-size:.98rem;
  line-height:1.75;
  margin:0;
}

/* --- MOBILE --- */
@media (max-width:820px){
  .gb-grid-wrapper-8e06dcf5{
    grid-template-columns:1fr;
    grid-template-areas:
      "avatar"
      "header"
      "bio";
    row-gap:14px;
  }

  .gb-container-8ef3038b{
    width:100% !important;
    min-width:0 !important;
    display:flex;
    justify-content:center;
  }

  .gb-grid-wrapper-8542265a{
    flex-direction:column;
    align-items:flex-start;
    gap:10px;
  }

  .gb-container-bd08faf2{
    justify-content:flex-start;
  }
}

.site-info {
  display:none;
}

/* Main sticky banner container */
.sticky-reserve-banner {
  position:fixed !important;
  bottom:0 !important;
  left:0 !important;
  right:0 !important;
  z-index:99999 !important;
  background:#ffffff !important;
  border-top:1px solid #e9ecef !important;
  padding:15px 20px !important;
  box-shadow:0 -2px 15px rgba(0, 0, 0, 0.15) !important;
  width:100% !important;
  box-sizing:border-box !important;
}

/* Reserve button styling */
.sticky-reserve-button {
  display:flex !important;
  align-items:center !important;
  justify-content:center !important;
  width:100% !important;
  max-width:500px !important;
  margin:0 auto !important;
  padding:14px 24px !important;
  background:linear-gradient(135deg, #ff0000, #ff0000) !important;
  color:#ffffff !important;
  text-decoration:none !important;
  text-align:center !important;
  border-radius:25px !important;
  font-size:16px !important;
  font-weight:600 !important;
  transition:all 0.3s ease !important;
  border:none !important;
  cursor:pointer !important;
  gap:8px !important;
  box-shadow:0 4px 15px rgba(255, 0, 0, 0.3) !important;
}

.sticky-reserve-button:hover {
  background:linear-gradient(135deg, #ff0000, #ff0000) !important;
  color:#ffffff !important;
  text-decoration:none !important;
  transform:translateY(-2px) !important;
  box-shadow:0 6px 20px rgba(255, 0, 0, 0.4) !important;
}

/* Hand icon styling */
.reserve-icon {
  width:20px !important;
  height:20px !important;
  flex-shrink:0 !important;
}

body {
  padding-bottom:85px !important;
}

@media (max-width:768px) {
  .sticky-reserve-banner {
    padding:12px 15px !important;
  }

  .sticky-reserve-button {
    font-size:14px !important;
    padding:12px 20px !important;
    border-radius:20px !important;
  }

  .reserve-icon {
    width:18px !important;
    height:18px !important;
  }

  body {
    padding-bottom:90px !important;
  }
}

/* Enhanced sticky banner with stronger positioning */
.sticky-reserve-banner {
  position:fixed !important;
  bottom:0 !important;
  left:0 !important;
  right:0 !important;
  z-index:999999 !important;
  background:#ffffff !important;
  border-top:1px solid #e9ecef !important;
  padding:15px 20px 15px !important;
  box-shadow:0 -2px 15px rgba(0, 0, 0, 0.15) !important;
  width:100% !important;
  box-sizing:border-box !important;
  transform:none !important;
  will-change:auto !important;
}

/* Override any parent container issues */
body .sticky-reserve-banner {
  position:fixed !important;
  bottom:0 !important;
  left:0 !important;
  right:0 !important;
  z-index:9999 !important;
}

/* Ensure parent containers don't interfere */
.sticky-reserve-banner * {
  transform:none !important;
}

/* Prevent browser/theme underlines on ticket buttons and affiliate links */
.att-compare-table a.att-table-btn,
a.att-buy-now-btn,
.att-top-tickets a,
.att-ticket__more { text-decoration: none !important; }

/* Buy Now button */
a.att-buy-now-btn {
  display: inline-block !important;
  background-color: #ff0000 !important;
  color: #ffffff !important;
  padding: 12px 28px !important;
  border-radius: 8px !important;
  font-weight: 700 !important;
  font-size: 16px !important;
  text-decoration: none !important;
  margin: 32px 0 8px 0 !important;
  transition: background-color 0.2s ease !important;
}
a.att-buy-now-btn:hover {
  background-color: #bf0000 !important;
  color: #ffffff !important;
  text-decoration: none !important;
}

/* Article container width — override GP theme */
.att-article-page .att-container {
  width: 75% !important;
  max-width: none !important;
  margin-left: auto !important;
  margin-right: auto !important;
}
@media (min-width: 769px) and (max-width: 1199px) {
  .att-article-page .att-container { width: 85% !important; }
}
@media (max-width: 768px) {
  .att-article-page .att-container { width: 95% !important; }
}
/* END FIRESTORM ADDITIONAL CSS */
CSS;

$stylesheet = get_option('stylesheet');
$existing_id = (int) get_theme_mod('custom_css_post_id');
$current = '';
$id = 0;

if ($existing_id > 0 && get_post($existing_id)) {
    $id = $existing_id;
    $current = (string) get_post_field('post_content', $id);
} else {
    $found = get_posts([
        'post_type' => 'custom_css',
        'post_status' => 'any',
        'name' => $stylesheet,
        'posts_per_page' => 1,
        'fields' => 'ids',
    ]);
    if (!empty($found)) {
        $id = (int) $found[0];
        $current = (string) get_post_field('post_content', $id);
    }
}

$backup_file = '/tmp/additional-css-backup-' . date('Ymd-His') . '.css';
file_put_contents($backup_file, $current);

$pattern = '/' . preg_quote($start, '/') . '.*?' . preg_quote($end, '/') . '\s*/s';
if (preg_match($pattern, $current)) {
    $updated = preg_replace($pattern, $block . "\n", $current, 1);
    $mode = 'replaced';
} else {
    $updated = trim($current);
    if ($updated !== '') {
        $updated .= "\n\n";
    }
    $updated .= $block . "\n";
    $mode = 'appended';
}

if ($id > 0) {
    wp_update_post([
        'ID' => $id,
        'post_content' => $updated,
        'post_status' => 'publish',
    ]);
} else {
    $id = wp_insert_post([
        'post_type' => 'custom_css',
        'post_status' => 'publish',
        'post_title' => sprintf('Additional CSS (%s)', $stylesheet),
        'post_name' => $stylesheet,
        'post_content' => $updated,
    ]);
    if (is_wp_error($id)) {
        fwrite(STDERR, 'ERROR:' . $id->get_error_message() . PHP_EOL);
        exit(1);
    }
}

set_theme_mod('custom_css_post_id', (int) $id);
$saved = (string) get_post_field('post_content', $id);

echo 'CUSTOM_CSS_ID:' . $id . PHP_EOL;
echo 'THEME_MOD:' . get_theme_mod('custom_css_post_id') . PHP_EOL;
echo 'MODE:' . $mode . PHP_EOL;
echo 'BACKUP:' . $backup_file . PHP_EOL;
echo 'MARKER:' . (strpos($saved, $start) !== false ? 'present' : 'missing') . PHP_EOL;
echo 'SITE_INFO:' . (strpos($saved, '.site-info') !== false ? 'present' : 'missing') . PHP_EOL;
echo 'AUTHOR_BOX:' . (strpos($saved, 'Author Box (GenerateBlocks)') !== false ? 'present' : 'missing') . PHP_EOL;
PHP

REMOTE_PHP="/tmp/configure-additional-css.php"

echo "Uploading script..."
_SCP "$PHP_LOCAL" "${WP_SSH_USER}@${WP_SSH_HOST}:$REMOTE_PHP"

echo "Applying Additional CSS..."
_SSH "wp eval-file '$REMOTE_PHP' --path='$WP_PATH'; rm -f '$REMOTE_PHP'"

echo "Done."
