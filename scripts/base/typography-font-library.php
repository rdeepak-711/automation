<?php
/**
 * GP Font Library — Add {{FONT_NAME}} (Google font, all weights + italics)
 * Run via: wp eval-file /tmp/gp_typography_NNN.php --path=/wp/path
 *
 * Template placeholders substituted by configure-typography.sh before deploy:
 *   {{FONT_NAME}}   — e.g. Karla
 *   {{FONT_SLUG}}   — e.g. karla
 *   {{CSS_VARIABLE}} — e.g. --gp-font--karla
 *   {{GF_URL}}      — Google Fonts CSS2 URL for this font
 */

// Activate font library module if not already active
if ( 'activated' !== get_option( 'generate_package_font_library' ) ) {
  update_option( 'generate_package_font_library', 'activated' );
  echo "Font library module activated\n";
}

// Manually load font library classes (plugin init already ran, module wasn't active then)
if ( ! class_exists( 'GeneratePress_Pro_Font_Library' ) ) {
  $gp_dir = WP_PLUGIN_DIR . '/gp-premium/';
  $files  = [
    'inc/class-singleton.php',
    'font-library/class-font-library.php',
    'font-library/class-font-library-optimize.php',
  ];
  foreach ( $files as $f ) {
    if ( file_exists( $gp_dir . $f ) ) {
      require_once $gp_dir . $f;
    }
  }
  echo "Font library classes loaded manually\n";
}

$font_name     = '{{FONT_NAME}}';
$font_slug     = '{{FONT_SLUG}}';
$font_fallback = 'sans-serif';
$font_display  = 'auto';
$css_variable  = '{{CSS_VARIABLE}}';

// Variants requested: 200,300,regular,500,600,700,800 + italic versions
$selected = [
  ['weight' => '200', 'style' => 'normal'],
  ['weight' => '300', 'style' => 'normal'],
  ['weight' => '400', 'style' => 'normal'],
  ['weight' => '500', 'style' => 'normal'],
  ['weight' => '600', 'style' => 'normal'],
  ['weight' => '700', 'style' => 'normal'],
  ['weight' => '800', 'style' => 'normal'],
  ['weight' => '200', 'style' => 'italic'],
  ['weight' => '300', 'style' => 'italic'],
  ['weight' => '400', 'style' => 'italic'],
  ['weight' => '500', 'style' => 'italic'],
  ['weight' => '600', 'style' => 'italic'],
  ['weight' => '700', 'style' => 'italic'],
  ['weight' => '800', 'style' => 'italic'],
];

// Fetch Google Fonts CSS2 for this font
$gf_url = '{{GF_URL}}';

echo "Fetching Google Fonts CSS...\n";
$resp = wp_remote_get( $gf_url, [
  'user-agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0',
  'timeout'    => 20,
]);
if ( is_wp_error( $resp ) ) {
  echo "ERROR fetching Google Fonts: " . $resp->get_error_message() . "\n";
  exit(1);
}
$http_code = wp_remote_retrieve_response_code( $resp );
$css_body  = wp_remote_retrieve_body( $resp );
if ( 200 !== (int) $http_code ) {
  echo "ERROR: Google Fonts returned HTTP $http_code\n";
  exit(1);
}
echo "Fetched " . strlen( $css_body ) . " bytes (HTTP $http_code)\n";

// Parse @font-face blocks — keep LAST per weight+style (= basic Latin subset)
preg_match_all( '/@font-face\s*\{([^}]+)\}/s', $css_body, $m );
$by_key = [];
foreach ( $m[1] as $block ) {
  if ( ! preg_match( '/font-weight:\s*(\d+)/', $block, $wm ) ) continue;
  if ( ! preg_match( '/font-style:\s*(\w+)/',  $block, $sm ) ) continue;
  if ( ! preg_match( "/src:[^;]*url\(['\"]?([^'\")\s]+)['\"]?\)[^;]*format\(['\"]woff2['\"]?\)/", $block, $src ) ) continue;
  $by_key[ $wm[1] . '_' . $sm[1] ] = [ 'weight' => $wm[1], 'style' => $sm[1], 'src' => $src[1] ];
}
echo "Parsed " . count( $by_key ) . " unique weight/style variants\n";
if ( empty( $by_key ) ) { echo "ERROR: Could not parse @font-face blocks\n"; exit(1); }

// Build variant objects for storage
$variants = [];
foreach ( $selected as $sel ) {
  $key = $sel['weight'] . '_' . $sel['style'];
  if ( ! isset( $by_key[ $key ] ) ) { echo "WARNING: missing src for {$sel['weight']}/{$sel['style']}\n"; continue; }
  $d = $by_key[ $key ];
  if ( '400' === $d['weight'] && 'normal' === $d['style'] ) { $name = 'Regular'; }
  elseif ( '400' === $d['weight'] && 'italic' === $d['style'] ) { $name = 'Italic'; }
  else { $name = $d['weight'] . ' ' . ucfirst( $d['style'] ); }
  $variants[] = [
    'fontFamily' => $font_name,
    'fontWeight' => $d['weight'],
    'fontStyle'  => $d['style'],
    'src'        => $d['src'],
    'name'       => $name,
    'isVariable' => false,
    'source'     => 'google',
    'disabled'   => false,
    'preview'    => '',
  ];
}
echo "Prepared " . count( $variants ) . " variants for storage\n";

// Create or update gp_font CPT post
$existing = get_posts([
  'post_type'     => 'gp_font',
  'name'          => $font_slug,
  'post_status'   => 'any',
  'numberposts'   => 1,
  'no_found_rows' => true,
]);
if ( $existing ) {
  $post_id = $existing[0]->ID;
  echo "Using existing gp_font post (ID: $post_id)\n";
} else {
  $post_id = wp_insert_post([
    'post_title'  => $font_name,
    'post_name'   => $font_slug,
    'post_type'   => 'gp_font',
    'post_status' => 'publish',
  ], true);
  if ( is_wp_error( $post_id ) ) { echo "ERROR: " . $post_id->get_error_message() . "\n"; exit(1); }
  echo "Created gp_font post (ID: $post_id)\n";
}

// Save meta
update_post_meta( $post_id, 'gp_font_source',       'google' );
update_post_meta( $post_id, 'gp_font_display',      $font_display );
update_post_meta( $post_id, 'gp_font_fallback',     $font_fallback );
update_post_meta( $post_id, 'gp_font_variable',     $css_variable );
update_post_meta( $post_id, 'gp_font_family_alias', '' );
update_post_meta( $post_id, 'gp_font_variants',     $variants );
echo "Meta saved: source=google display=$font_display fallback=$font_fallback\n";
echo "CSS variable: $css_variable\n";

// Enable Google Fonts API in font library settings
$lib = get_option( 'gp_font_library_settings', [] );
$lib['google_gdpr'] = true;
update_option( 'gp_font_library_settings', $lib );
echo "gp_font_library_settings[google_gdpr] = true\n";

// Trigger CSS file rebuild by re-saving post (fires save_post_gp_font hook)
remove_action( 'save_post_gp_font', 'build_css_file' ); // prevent double-hook if any
wp_update_post( [ 'ID' => $post_id, 'post_status' => 'publish' ] );

// Also call directly in case the static hook didn't fire from eval-file context
if ( class_exists( 'GeneratePress_Pro_Font_Library' ) ) {
  $css_result = GeneratePress_Pro_Font_Library::build_css_file();
  if ( is_wp_error( $css_result ) ) {
    echo "WARNING: build_css_file failed: " . $css_result->get_error_message() . "\n";
  } else {
    echo "fonts.css rebuilt: $css_result\n";
  }
} else {
  echo "WARNING: GeneratePress_Pro_Font_Library class not available\n";
}

echo "Done\n";
