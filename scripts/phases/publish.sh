#!/usr/bin/env zsh
# publish.sh — Phase 3: Publish to WordPress (Steps 24–26)
# Called from main.sh or directly: ./scripts/phases/publish.sh
set -euo pipefail

PHASE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PHASE_SCRIPT_DIR/../.." && pwd)"
source "$PHASE_SCRIPT_DIR/common.sh"

CONTENT_SITE_SLUG="${CONTENT_SITE_SLUG:-}"
if [[ -z "$CONTENT_SITE_SLUG" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi

load_env "$CONTENT_SITE_SLUG"

SITE_HOST="${WP_SITE_URL:-default}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"
mkdir -p "$REPO_ROOT/state"
export STATE_FILE="$REPO_ROOT/state/.setup-state-${SITE_HOST}"

# Route SSH to correct server based on WP_SERVER in site .env
if [[ "${WP_SERVER:-1}" == "2" ]]; then
  export WP_SSH_HOST="${WP_SSH_HOST2:-}"
  export WP_SSH_USER="${WP_SSH_USER2:-}"
  export WP_SSH_KEY="${WP_SSH_KEY2:-}"
  echo "  → Using Server 2 (${WP_SSH_HOST})"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Publish Phase — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 24: Publish to WordPress ────────────────────────────────────────────
if prompt_step 24 "Publish to WordPress" \
    "Publishes all generated HTML (L2 articles + L1 pages + homepage + About Us + Contact Us)." \
    "publish_wp_done"; then
  "$REPO_ROOT/scripts/content/publish-to-wordpress.sh" "$CONTENT_SITE_SLUG" --status publish
  mark_done "publish_wp_done"
else
  echo "  Skipped."
fi

# ── Step 25: Fetch GYG Images ────────────────────────────────────────────────
if prompt_step 25 "Fetch GYG Images" \
    "Downloads tour photos from the GYG API, converts to avif, writes manifest.json." \
    "fetch_gyg_images_done"; then
  _ATTRACTION="${SITE_NAME:-}"
  if [[ -z "$_ATTRACTION" ]]; then
    # Suggest from slug, let user confirm/override
    _SUGGESTED=$(echo "$CONTENT_SITE_SLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
    printf "  Attraction name for GYG search [%s]: " "$_SUGGESTED"
    read -r _INPUT
    _ATTRACTION="${_INPUT:-$_SUGGESTED}"
  fi
  echo "  Attraction: $_ATTRACTION"
  "$REPO_ROOT/scripts/fetch-gyg-images.sh" "$CONTENT_SITE_SLUG" "$_ATTRACTION"
  mark_done "fetch_gyg_images_done"
else
  echo "  Skipped."
fi

# ── Step 26: Clear WP Cache ──────────────────────────────────────────────────
if prompt_step 26 "Clear WP Cache" \
    "Clears WP Rocket page cache and WP object cache via SSH after publishing." \
    "clear_cache_done"; then
  echo "  Clearing caches on ${WP_SSH_HOST}..."
  _WP_KEY="${WP_SSH_KEY/#\~/$HOME}"
  ssh -i "$_WP_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    -o BatchMode=yes "${WP_SSH_USER}@${WP_SSH_HOST}" bash << SSHEOF
wp cache flush --path="${WP_PATH}" 2>/dev/null && echo "  ✓ WP object cache flushed" || true
wp transient delete --all --path="${WP_PATH}" 2>/dev/null && echo "  ✓ Transients deleted" || true
wp rewrite flush --path="${WP_PATH}" 2>/dev/null && echo "  ✓ Rewrite rules flushed" || true
wp eval 'if(function_exists("rocket_clean_domain")){rocket_clean_domain(); echo "  ✓ WP Rocket domain cache purged\n";}
         if(function_exists("rocket_clean_minify")){rocket_clean_minify(); echo "  ✓ WP Rocket minified assets purged\n";}
         opcache_reset(); echo "  ✓ OPcache reset\n";' \
  --path="${WP_PATH}" 2>/dev/null || true
_COUNT=\$(find "${WP_PATH}/wp-content/cache/" -name "*.html" -o -name "*.html.gz" 2>/dev/null | wc -l | tr -d ' ')
find "${WP_PATH}/wp-content/cache/" -name "*.html" -delete 2>/dev/null || true
find "${WP_PATH}/wp-content/cache/" -name "*.html.gz" -delete 2>/dev/null || true
echo "  ✓ Deleted \${_COUNT} cached HTML files"
SSHEOF
  mark_done "clear_cache_done"
  echo "  ✓ Cache cleared"
else
  echo "  Skipped."
fi

# ── Step 27: Configure Menu + Footer GP Elements ─────────────────────────────
if prompt_step 27 "Configure Menu + Footer GP Elements" \
    "Generates dynamic menu (all published articles) and footer, deploys as GP Elements via SSH. Also applies Additional CSS." \
    "configure_menu_footer_done"; then
  python3 "$REPO_ROOT/scripts/wordpress/configure-gp-menu-footer.py" \
    --site-slug "$CONTENT_SITE_SLUG" \
    --wp-path "${WP_PATH:-}"
  echo "  Applying Additional CSS..."
  "$REPO_ROOT/scripts/wordpress/configure-additional-css.sh" "${WP_PATH:-}"
  mark_done "configure_menu_footer_done"
else
  echo "  Skipped."
fi

# ── Step 28: Post-publish audit ──────────────────────────────────────────────
if prompt_step 28 "Post-publish audit" \
    "Checks menu/footer/about-us/contact-us are present; syncs card images from WP featured images." \
    "post_publish_audit_done"; then
  "$REPO_ROOT/scripts/audit/post-publish.sh" "$CONTENT_SITE_SLUG"
  mark_done "post_publish_audit_done"
else
  echo "  Skipped."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Publish phase complete — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"
