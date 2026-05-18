<?php
/**
 * GP Typography Manager — Desktop breakpoint
 * Sets Body, H1, H2, H3, H4 typography via generate_settings + generate_typography
 * Run via: wp eval-file /tmp/gp_typo_manager_NNN.php --path=/wp/path
 *
 * Template placeholders substituted by configure-typography.sh before deploy:
 *   {{FONT_NAME}}          — e.g. Karla
 *   {{BODY_FONT_SIZE}}     — e.g. 18  (px, integer)
 *   {{BODY_LINE_HEIGHT}}   — e.g. 1.6
 *   {{PARAGRAPH_MARGIN}}   — e.g. 1.5 (em)
 *   {{H1_FONT_SIZE}}       — e.g. 35  (px, integer)
 *   {{H2_FONT_SIZE}}       — e.g. 32  (px, integer)
 *   {{H3_FONT_SIZE}}       — e.g. 28  (px, integer)
 *   {{H4_FONT_SIZE}}       — e.g. 24  (px, integer)
 */

// ── Part 1: generate_settings (legacy flat options) ──────────────────────────
$existing_settings = get_option( 'generate_settings', [] );
if ( ! is_array( $existing_settings ) ) {
  $existing_settings = [];
}

$updates = [
  // Body
  'font_body'            => '{{FONT_NAME}}',
  'body_font_weight'     => 'normal',
  'body_font_transform'  => 'none',
  'body_font_style'      => 'normal',
  'body_font_decoration' => '',
  'body_font_size'       => '{{BODY_FONT_SIZE}}',
  'body_line_height'     => '{{BODY_LINE_HEIGHT}}',
  'body_letter_spacing'  => '0',
  'paragraph_margin'     => '{{PARAGRAPH_MARGIN}}',
  // H1
  'font_heading_1'       => '{{FONT_NAME}}',
  'heading_1_weight'     => 'bold',
  'heading_1_transform'  => '',
  'heading_1_style'      => '',
  'heading_1_decoration' => '',
  'heading_1_font_size'  => '{{H1_FONT_SIZE}}',
  'h1_line_height'       => '1.2',
  'h1_letter_spacing'    => '',
  'h1_margin_bottom'     => '20',
  // H2
  'font_heading_2'       => '{{FONT_NAME}}',
  'heading_2_weight'     => 'bold',
  'heading_2_transform'  => '',
  'heading_2_style'      => '',
  'heading_2_decoration' => '',
  'heading_2_font_size'  => '{{H2_FONT_SIZE}}',
  'h2_line_height'       => '1.2',
  'h2_letter_spacing'    => '',
  'h2_margin_bottom'     => '20',
  // H3
  'font_heading_3'       => '{{FONT_NAME}}',
  'heading_3_weight'     => 'bold',
  'heading_3_transform'  => '',
  'heading_3_style'      => 'normal',
  'heading_3_decoration' => '',
  'heading_3_font_size'  => '{{H3_FONT_SIZE}}',
  'h3_line_height'       => '1.2',
  'h3_letter_spacing'    => '',
  'h3_margin_bottom'     => '20',
  // H4
  'font_heading_4'       => '{{FONT_NAME}}',
  'heading_4_weight'     => 'bold',
  'heading_4_transform'  => '',
  'heading_4_style'      => '',
  'heading_4_decoration' => '',
  'heading_4_font_size'  => '{{H4_FONT_SIZE}}',
  'h4_line_height'       => '1.2',
  'h4_letter_spacing'    => '',
  'h4_margin_bottom'     => '20',
];

$merged_settings = array_merge( $existing_settings, $updates );
update_option( 'generate_settings', $merged_settings );
echo "generate_settings updated (" . count( $updates ) . " keys)\n";

// ── Part 2: generate_typography (stored as generate_settings['typography']) ───
// Clean up stale theme_mod from previous incorrect attempt
remove_theme_mod( 'generate_typography' );

$existing_settings = get_option( 'generate_settings', [] );
if ( ! is_array( $existing_settings ) ) {
  $existing_settings = [];
}

// Index existing typography entries by selector
$existing_typo = isset( $existing_settings['typography'] ) && is_array( $existing_settings['typography'] )
  ? $existing_settings['typography']
  : [];

$indexed = [];
foreach ( $existing_typo as $entry ) {
  if ( isset( $entry['selector'] ) ) {
    $indexed[ $entry['selector'] ] = $entry;
  }
}

$new_entries = [
  'body' => [
    'selector'            => 'body',
    'fontFamily'          => 'inherit',
    'fontWeight'          => 'normal',
    'fontStyle'           => 'normal',
    'textTransform'       => 'normal',
    'textDecoration'      => '',
    'fontSize'            => '{{BODY_FONT_SIZE}}px',
    'fontSizeUnit'        => 'px',
    'fontSizeTablet'      => '',
    'fontSizeMobile'      => '',
    'lineHeight'          => '{{BODY_LINE_HEIGHT}}em',
    'lineHeightUnit'      => 'em',
    'lineHeightTablet'    => '',
    'lineHeightMobile'    => '',
    'letterSpacing'       => '0px',
    'letterSpacingUnit'   => 'px',
    'letterSpacingTablet' => '',
    'letterSpacingMobile' => '',
    'marginBottom'        => '{{PARAGRAPH_MARGIN}}em',
    'marginBottomUnit'    => 'em',
    'marginBottomTablet'  => '',
    'marginBottomMobile'  => '',
    'module'              => 'core',
    'group'               => 'base',
  ],
  'h1' => [
    'selector'            => 'h1',
    'fontFamily'          => 'inherit',
    'fontWeight'          => 'bold',
    'fontStyle'           => '',
    'textTransform'       => '',
    'textDecoration'      => '',
    'fontSize'            => '{{H1_FONT_SIZE}}px',
    'fontSizeUnit'        => 'px',
    'fontSizeTablet'      => '',
    'fontSizeMobile'      => '',
    'lineHeight'          => '1.2em',
    'lineHeightUnit'      => 'em',
    'lineHeightTablet'    => '',
    'lineHeightMobile'    => '',
    'letterSpacing'       => '',
    'letterSpacingUnit'   => 'px',
    'letterSpacingTablet' => '',
    'letterSpacingMobile' => '',
    'marginBottom'        => '20px',
    'marginBottomUnit'    => 'px',
    'marginBottomTablet'  => '',
    'marginBottomMobile'  => '',
    'module'              => 'core',
    'group'               => 'content',
  ],
  'h2' => [
    'selector'            => 'h2',
    'fontFamily'          => 'inherit',
    'fontWeight'          => 'bold',
    'fontStyle'           => '',
    'textTransform'       => '',
    'textDecoration'      => '',
    'fontSize'            => '{{H2_FONT_SIZE}}px',
    'fontSizeUnit'        => 'px',
    'fontSizeTablet'      => '',
    'fontSizeMobile'      => '',
    'lineHeight'          => '1.2em',
    'lineHeightUnit'      => 'em',
    'lineHeightTablet'    => '',
    'lineHeightMobile'    => '',
    'letterSpacing'       => '',
    'letterSpacingUnit'   => 'px',
    'letterSpacingTablet' => '',
    'letterSpacingMobile' => '',
    'marginBottom'        => '20px',
    'marginBottomUnit'    => 'px',
    'marginBottomTablet'  => '',
    'marginBottomMobile'  => '',
    'module'              => 'core',
    'group'               => 'content',
  ],
  'h3' => [
    'selector'            => 'h3',
    'fontFamily'          => 'inherit',
    'fontWeight'          => 'bold',
    'fontStyle'           => 'normal',
    'textTransform'       => '',
    'textDecoration'      => '',
    'fontSize'            => '{{H3_FONT_SIZE}}px',
    'fontSizeUnit'        => 'px',
    'fontSizeTablet'      => '',
    'fontSizeMobile'      => '',
    'lineHeight'          => '1.2em',
    'lineHeightUnit'      => 'em',
    'lineHeightTablet'    => '',
    'lineHeightMobile'    => '',
    'letterSpacing'       => '',
    'letterSpacingUnit'   => 'px',
    'letterSpacingTablet' => '',
    'letterSpacingMobile' => '',
    'marginBottom'        => '20px',
    'marginBottomUnit'    => 'px',
    'marginBottomTablet'  => '',
    'marginBottomMobile'  => '',
    'module'              => 'core',
    'group'               => 'content',
  ],
  'h4' => [
    'selector'            => 'h4',
    'fontFamily'          => 'inherit',
    'fontWeight'          => 'bold',
    'fontStyle'           => '',
    'textTransform'       => '',
    'textDecoration'      => '',
    'fontSize'            => '{{H4_FONT_SIZE}}px',
    'fontSizeUnit'        => 'px',
    'fontSizeTablet'      => '',
    'fontSizeMobile'      => '',
    'lineHeight'          => '1.2em',
    'lineHeightUnit'      => 'em',
    'lineHeightTablet'    => '',
    'lineHeightMobile'    => '',
    'letterSpacing'       => '',
    'letterSpacingUnit'   => 'px',
    'letterSpacingTablet' => '',
    'letterSpacingMobile' => '',
    'marginBottom'        => '20px',
    'marginBottomUnit'    => 'px',
    'marginBottomTablet'  => '',
    'marginBottomMobile'  => '',
    'module'              => 'core',
    'group'               => 'content',
  ],
];

foreach ( $new_entries as $sel => $entry ) {
  $indexed[ $sel ] = $entry;
}

$existing_settings['typography'] = array_values( $indexed );
update_option( 'generate_settings', $existing_settings );
echo "generate_settings[typography] updated (" . count( $new_entries ) . " elements)\n";

// ── Part 3: CSS cache bust ────────────────────────────────────────────────────
delete_transient( 'generate_dynamic_css' );
if ( function_exists( 'generate_update_dynamic_css' ) ) {
  generate_update_dynamic_css();
  echo "Dynamic CSS regenerated\n";
}

echo "Done\n";
