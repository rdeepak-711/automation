#!/usr/bin/env zsh
set -euo pipefail

# Deploy Templates (Footer, Author Box CSS)
# Usage: ./scripts/base/10-deploy-templates.sh <hostname> <site_slug> <attraction_name> <accent_color>

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <hostname> <site_slug> <attraction_name> <accent_color>"
    echo "Example: $0 operagarnier-guide.com operagarnier-guide Opera Garnier #c4956c"
    exit 1
fi

HOSTNAME="$1"
SITE_SLUG="$2"
ATTRACTION_NAME="$3"
ACCENT_COLOR="$4"

# Load WP_PATH from site .env
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -f "$SCRIPT_DIR/input/$SITE_SLUG/.env" ]]; then
  set -a; source "$SCRIPT_DIR/input/$SITE_SLUG/.env"; set +a
fi

# Build SSH key options from env var (arrays can't be exported across processes)
SSH_KEY_OPTS=()
[[ -n "${WP_SSH_KEY:-}" ]] && SSH_KEY_OPTS=(-i "${WP_SSH_KEY/#\~/$HOME}" -o IdentitiesOnly=yes)
SSH_KEY_OPTS+=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)

# Extract RGB values from hex color (remove # and convert to RGB)
ACCENT_HEX="${ACCENT_COLOR#\#}"
ACCENT_R=$((16#${ACCENT_HEX:0:2}))
ACCENT_G=$((16#${ACCENT_HEX:2:2}))
ACCENT_B=$((16#${ACCENT_HEX:4:2}))
ACCENT_COLOR_RGB="${ACCENT_R},${ACCENT_G},${ACCENT_B}"
ACCENT_COLOR_RGBA_25="rgba(${ACCENT_R},${ACCENT_G},${ACCENT_B},.25)"
ACCENT_COLOR_RGBA_55="rgba(${ACCENT_R},${ACCENT_G},${ACCENT_B},.55)"

# Create accent color variations
case "$ACCENT_COLOR" in
    "#ff0000") # Red (Auschwitz)
        ACCENT_COLOR_BG_LIGHT="#fff5f5"
        ACCENT_COLOR_BG_LIGHTER="#ffe5e5"
        ACCENT_COLOR_DARK="#cc0000"
        SITE_THEME="Auschwitz"
        ;;
    "#c4956c") # Gold (Opera Garnier)
        ACCENT_COLOR_BG_LIGHT="#fef7f0"
        ACCENT_COLOR_BG_LIGHTER="#fef1e6"
        ACCENT_COLOR_DARK="#8b6914"
        SITE_THEME="Opera Garnier"
        ;;
    *) # Default (generic)
        ACCENT_COLOR_BG_LIGHT="#f8fafc"
        ACCENT_COLOR_BG_LIGHTER="#f1f5f9"
        ACCENT_COLOR_DARK="$(echo "$ACCENT_COLOR" | sed 's/#/#80/')" # Darker version
        SITE_THEME="Generic"
        ;;
esac

SITE_URL="https://${HOSTNAME}"
SITE_NAME=$(echo "$HOSTNAME" | sed 's/-guide\.com$//' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')
ATTRACTION_SLUG=$(echo "$ATTRACTION_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')

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

# Function to substitute template variables (sed-based, compatible with bash 3.2)
substitute_template() {
    echo "$1" \
      | sed "s|{{SITE_URL}}|${SITE_URL}|g" \
      | sed "s|{{SITE_NAME}}|${SITE_NAME}|g" \
      | sed "s|{{SITE_SLUG}}|${SITE_SLUG}|g" \
      | sed "s|{{ATTRACTION_NAME}}|${ATTRACTION_NAME}|g" \
      | sed "s|{{ATTRACTION_SLUG}}|${ATTRACTION_SLUG}|g" \
      | sed "s|{{ACCENT_COLOR}}|${ACCENT_COLOR}|g" \
      | sed "s|{{ACCENT_COLOR_RGB}}|${ACCENT_COLOR_RGB}|g" \
      | sed "s|{{ACCENT_COLOR_RGBA_25}}|${ACCENT_COLOR_RGBA_25}|g" \
      | sed "s|{{ACCENT_COLOR_RGBA_55}}|${ACCENT_COLOR_RGBA_55}|g" \
      | sed "s|{{ACCENT_COLOR_BG_LIGHT}}|${ACCENT_COLOR_BG_LIGHT}|g" \
      | sed "s|{{ACCENT_COLOR_BG_LIGHTER}}|${ACCENT_COLOR_BG_LIGHTER}|g" \
      | sed "s|{{ACCENT_COLOR_DARK}}|${ACCENT_COLOR_DARK}|g" \
      | sed "s|{{SITE_THEME}}|${SITE_THEME}|g"
}

echo "🚀 Deploying templates for $HOSTNAME..."

# 1. Deploy Footer Element
echo "📄 Deploying Footer element..."
FOOTER_TEMPLATE=$(cat "templates/footer-template.html")
FOOTER_CONTENT=$(substitute_template "$FOOTER_TEMPLATE")

# Write content to a temp file and SCP it — avoids shell escaping + newline corruption
_FOOTER_TMP=$(mktemp /tmp/footer_content_XXXXXX)
printf '%s' "$FOOTER_CONTENT" > "$_FOOTER_TMP"
_FOOTER_REMOTE="/tmp/footer_deploy_$$.html"
scp "${SSH_KEY_OPTS[@]}" "$_FOOTER_TMP" "${BLUEHOST_USER}@${BLUEHOST_HOST}:${_FOOTER_REMOTE}" 2>/dev/null
rm -f "$_FOOTER_TMP"

# Deploy via PHP eval-file — correct hook, array display conditions, no newline corruption
_FOOTER_PHP=$(mktemp /tmp/footer_php_XXXXXX)
cat > "$_FOOTER_PHP" << PHPEOF
<?php
\$content = file_get_contents('${_FOOTER_REMOTE}');
\$existing = get_posts(['post_type'=>'gp_elements','name'=>'footer','post_status'=>'any','numberposts'=>1]);
if (\$existing) {
    \$id = \$existing[0]->ID;
    update_post_meta(\$id, '_generate_element_content', \$content);
    echo "Updated Footer element (ID: \$id)\n";
} else {
    \$id = wp_insert_post(['post_type'=>'gp_elements','post_title'=>'Footer','post_name'=>'footer','post_status'=>'publish']);
    update_post_meta(\$id, '_generate_element_type',              'hook');
    update_post_meta(\$id, '_generate_hook',                      'generate_footer');
    update_post_meta(\$id, '_generate_hook_priority',             10);
    update_post_meta(\$id, '_generate_element_display_conditions', [['rule'=>'general:site','object'=>'0']]);
    update_post_meta(\$id, '_generate_element_content',           \$content);
    echo "Created Footer element (ID: \$id)\n";
}
unlink('${_FOOTER_REMOTE}');
PHPEOF
_FOOTER_PHP_REMOTE="/tmp/footer_php_$$.php"
scp "${SSH_KEY_OPTS[@]}" "$_FOOTER_PHP" "${BLUEHOST_USER}@${BLUEHOST_HOST}:${_FOOTER_PHP_REMOTE}" 2>/dev/null
rm -f "$_FOOTER_PHP"
ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" \
    "wp eval-file '${_FOOTER_PHP_REMOTE}' --path='${WP_PATH}' 2>&1; rm -f '${_FOOTER_PHP_REMOTE}'"

# 2. Deploy Author Box CSS via SCP + eval-file (avoids shell quoting issues)
echo "🎨 Deploying Author Box CSS..."
CSS_TEMPLATE=$(cat "templates/author-box-css-template.css")
CSS_CONTENT=$(substitute_template "$CSS_TEMPLATE")

_CSS_TMP=$(mktemp /tmp/author_css_XXXXXX)
printf '%s' "$CSS_CONTENT" > "$_CSS_TMP"
_CSS_REMOTE="/tmp/author_css_$$.txt"
scp "${SSH_KEY_OPTS[@]}" "$_CSS_TMP" "${BLUEHOST_USER}@${BLUEHOST_HOST}:${_CSS_REMOTE}" 2>/dev/null
rm -f "$_CSS_TMP"

_CSS_PHP=$(mktemp /tmp/author_css_php_XXXXXX)
cat > "$_CSS_PHP" << PHPEOF
<?php
\$new_css = file_get_contents('${_CSS_REMOTE}');
\$existing = get_theme_mod('custom_css', '');
if (strpos(\$existing, 'Author Box (GenerateBlocks)') !== false) {
    // Replace existing block: from marker to .site-info { display: none; } (inclusive)
    \$pattern = '/\/\* ========= Author Box \(GenerateBlocks\).*\.site-info\s*\{[^}]*\}/s';
    \$existing = preg_replace(\$pattern, '', \$existing);
    echo "📝 Replacing existing Author Box CSS\n";
} else {
    echo "🎨 Adding Author Box CSS to Additional CSS\n";
}
\$final = trim(\$existing) . "\n\n" . \$new_css;
set_theme_mod('custom_css', \$final);
echo "Done\n";
unlink('${_CSS_REMOTE}');
PHPEOF
_CSS_PHP_REMOTE="/tmp/author_css_php_$$.php"
scp "${SSH_KEY_OPTS[@]}" "$_CSS_PHP" "${BLUEHOST_USER}@${BLUEHOST_HOST}:${_CSS_PHP_REMOTE}" 2>/dev/null
rm -f "$_CSS_PHP"
ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" \
    "wp eval-file '${_CSS_PHP_REMOTE}' --path='${WP_PATH}' 2>&1; rm -f '${_CSS_PHP_REMOTE}'"

# 3. Clear cache
echo "🧹 Clearing cache..."
ssh "${SSH_KEY_OPTS[@]}" "${BLUEHOST_USER}@${BLUEHOST_HOST}" "
wp cache flush --path='${WP_PATH}' 2>/dev/null || true
wp transient delete --all --path='${WP_PATH}' 2>/dev/null || true
wp rewrite flush --path='${WP_PATH}' 2>/dev/null || true
wp eval 'if(function_exists(\"rocket_clean_domain\")){rocket_clean_domain();}
         if(function_exists(\"rocket_clean_minify\")){rocket_clean_minify();}
         opcache_reset();
         echo \"WP Rocket + OPcache cleared\n\";' \
    --path='${WP_PATH}' 2>/dev/null || true
find '${WP_PATH}/wp-content/cache/' -name '*.html' -o -name '*.html.gz' 2>/dev/null | xargs rm -f 2>/dev/null || true
"

echo "✅ Template deployment completed for $HOSTNAME!"
echo ""
echo "🎯 Templates deployed:"
echo "   • Footer element with social links"
echo "   • Author Box CSS with $SITE_THEME theme colors"
echo ""
echo "🌐 Site is ready at: $SITE_URL"