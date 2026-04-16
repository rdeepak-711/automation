#!/usr/bin/env zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# Preserve SSH vars set by parent (active server selection from main.sh)
_SAVED_SSH_HOST="${WP_SSH_HOST:-}"
_SAVED_SSH_USER="${WP_SSH_USER:-}"
_SAVED_SSH_KEY="${WP_SSH_KEY:-}"

# Load root .env if present
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
# Load site-specific .env (overrides root — WP_SITE_URL, WP_USER, WP_PASS, WP_PATH live here)
_SLUG="${CONTENT_SITE_SLUG:-${SITE_SLUG:-}}"
if [[ -n "$_SLUG" && -f "$SCRIPT_DIR/input/$_SLUG/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/input/$_SLUG/.env"
  set +a
fi

# Restore SSH vars — parent's active server takes precedence over .env
[[ -n "$_SAVED_SSH_HOST" ]] && WP_SSH_HOST="$_SAVED_SSH_HOST"
[[ -n "$_SAVED_SSH_USER" ]] && WP_SSH_USER="$_SAVED_SSH_USER"
[[ -n "$_SAVED_SSH_KEY" ]] && WP_SSH_KEY="$_SAVED_SSH_KEY"


[[ $# -ge 1 ]] && WP_SITE_URL="$1"
[[ $# -ge 2 ]] && WP_USER="$2"
[[ $# -ge 3 ]] && WP_PASS="$3"

if [[ -z "${WP_SITE_URL:-}" || -z "${WP_USER:-}" || -z "${WP_PASS:-}" ]]; then
  echo "Error: Missing credentials."
  echo "  Option 1: Create .env with WP_SITE_URL, WP_USER, WP_PASS"
  echo "  Option 2: $0 <site-url> <username> <app-password>"
  exit 1
fi

# ── Phase 2: curl pre-flight ──────────────────────────────────────────────────
echo "Verifying credentials..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 10 --max-time 30 \
  -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/users/me/")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: WordPress authentication failed (HTTP $HTTP_CODE)."
  echo "  - Check WP_SITE_URL, WP_USER, and WP_PASS in .env"
  echo "  - WP_PASS must be an Application Password (Users → Profile → Application Passwords)"
  echo "  - The authenticated user must have the Administrator role"
  echo "  - Application Passwords require HTTPS"
  exit 1
fi
echo "Credentials verified."

# ── SSH multiplexed setup + WP_PATH auto-discovery ───────────────────────────
SSH_OK=false
SSH_KEY_OPT=()
SSH_CTL="${SSH_CONTROL_PATH:-/tmp/wp-ssh-ctl-$$}"

if [[ -n "${WP_SSH_HOST:-}" && -n "${WP_SSH_USER:-}" ]]; then
  SSH_KEY_OPT=(-i "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
               -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
               -o ConnectTimeout=15
               -o ControlMaster=auto
               -o ControlPath="$SSH_CTL"
               -o ControlPersist=120)
  echo "Verifying SSH + WP-CLI..."

  if [[ -z "${WP_PATH:-}" ]]; then
    echo "  WP_PATH not set — searching for WordPress install matching $WP_SITE_URL ..."
    SITE_HOST="${WP_SITE_URL#https://}"
    SITE_HOST="${SITE_HOST#http://}"
    SITE_HOST="${SITE_HOST%%/*}"
    SEARCH_ROOT="/home1/${WP_SSH_USER}/public_html"
    WP_PATH=$(ssh "${SSH_KEY_OPT[@]}" \
      "${WP_SSH_USER}@${WP_SSH_HOST}" "
        for d in ${SEARCH_ROOT}/website_*/; do
          url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || continue
          if [[ \"\$url\" == *\"${SITE_HOST}\"* ]]; then
            echo \"\$d\"
            break
          fi
        done
      " 2>/dev/null) || WP_PATH=""
    WP_PATH="${WP_PATH%/}"
    if [[ -n "$WP_PATH" ]]; then
      echo "  Found WordPress at: $WP_PATH"
    else
      echo "  WARNING: Could not find a WordPress install matching $WP_SITE_URL"
      echo "  Set WP_PATH manually in .env to fix this"
    fi
  fi

  if [[ -n "${WP_PATH:-}" ]]; then
    SSH_TEST=$(ssh "${SSH_KEY_OPT[@]}" \
      "${WP_SSH_USER}@${WP_SSH_HOST}" "wp --version --path='${WP_PATH}' 2>&1") && SSH_OK=true || true
    if $SSH_OK; then
      echo "  SSH + WP-CLI verified: $SSH_TEST"
    else
      echo "  ERROR: SSH connection or WP-CLI failed."
      echo "  This script requires WP-CLI access — no REST fallback available."
      exit 1
    fi
  else
    echo "  ERROR: WP_PATH could not be determined — cannot proceed without SSH + WP-CLI."
    exit 1
  fi
else
  echo "  ERROR: WP_SSH_HOST / WP_SSH_USER not set in .env — cannot proceed without SSH + WP-CLI."
  echo ""
  echo "  Apply these settings manually in WP Admin:"
  echo ""
  echo "  Appearance → GP Premium → Layout → Container"
  echo "    Container Width:   ${CONTAINER_WIDTH}"
  echo "    Content Layout:    One Container"
  echo "    Container Padding: Top 10 / Right 0 / Bottom 40 / Left 0"
  echo "    Mobile Padding:    Top 30 / Right 0 / Bottom 30 / Left 0"
  echo ""
  echo "  Appearance → GP Premium → Layout → Header"
  echo "    Header Layout:    Contained"
  echo "    Header Alignment: Left"
  echo "    Header Padding:   Top 15 / Right 20 / Bottom 10 / Left 10"
  echo "    Mobile Header:    Enable"
  echo ""
  echo "  Appearance → GP Premium → Layout → Off Canvas Panel"
  echo "    Slideout Menu:    Mobile Only"
  echo ""
  echo "  Appearance → GP Premium → Layout → Sidebars"
  echo "    Default Layout (layout_setting):      No Sidebar"
  echo "    Blog Layout (blog_layout_setting):     No Sidebar"
  echo "    Single Layout (single_layout_setting): No Sidebar"
  echo ""
  echo "  Appearance → GP Premium → Layout → Blog → Archives"
  echo "    Content Type:        Excerpt"
  echo "    Word Count:          55"
  echo "    Read More Label:     Read More"
  echo "    Display Post Author: ✓ (checked)"
  echo "    Display Post Date:   ✓ (checked)"
  echo "    Post Categories:     unchecked"
  echo "    Post Tags:           unchecked"
  echo "    Post Comments:       unchecked"
  echo ""
  echo "  Appearance → GP Premium → Layout → Blog → Single"
  echo "    Display Post Categories: ✓ (checked)"
  echo "    Display Post Tags:       ✓ (checked)"
  echo "    Post Author:             unchecked"
  echo "    Post Date:               unchecked"
  echo "    Post Comments:           unchecked"
  exit 1
fi

# ── Phase 3: Read configurable layout values from env (with defaults) ─────────
CONTAINER_WIDTH=$(( ${CONTAINER_WIDTH:-1365} + 0 ))  # px — set in .env to override

# ── Phase 4: Single WP-CLI SSH wp eval round-trip ────────────────────────────
echo ""
echo "── Applying GeneratePress layout settings ──────────────────────────────────"

RESULT=$(ssh "${SSH_KEY_OPT[@]}" \
  "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp eval '
    // 1. generate_settings — container, header, sidebars
    \$gs = (array) get_option(\"generate_settings\", []);
    \$gs[\"container_width\"]          = ${CONTAINER_WIDTH};
    \$gs[\"content_layout_setting\"]   = \"one-container\";
    \$gs[\"container_alignment\"]      = \"text\";
    \$gs[\"header_layout_setting\"]    = \"contained-header\";
    \$gs[\"header_inner_width\"]       = \"contained\";
    \$gs[\"header_alignment_setting\"] = \"left\";
    \$gs[\"layout_setting\"]           = \"no-sidebar\";
    \$gs[\"blog_layout_setting\"]      = \"no-sidebar\";
    \$gs[\"single_layout_setting\"]    = \"no-sidebar\";
    // Blog — Archives
    \$gs[\"post_content\"]    = \"excerpt\";
    \$gs[\"excerpt_length\"]  = 55;
    \$gs[\"read_more_text\"]  = \"Read More\";
    \$gs[\"post_author\"]     = 1;     // checked
    \$gs[\"post_date\"]       = 1;     // checked
    \$gs[\"post_categories\"] = false; // unchecked
    \$gs[\"post_tags\"]       = false; // unchecked
    \$gs[\"post_comments\"]   = false; // unchecked
    // Blog — Single
    \$gs[\"single_post_categories\"] = 1;     // checked
    \$gs[\"single_post_tags\"]       = 1;     // checked
    \$gs[\"single_post_author\"]     = false; // unchecked
    \$gs[\"single_post_date\"]       = false; // unchecked
    \$gs[\"single_post_comments\"]   = false; // unchecked
    update_option(\"generate_settings\", \$gs);
    echo \"generate_settings updated\n\";

    // 2. generate_spacing_settings — container + header padding
    \$ss = (array) get_option(\"generate_spacing_settings\", []);
    \$ss[\"separator\"]                 = \"20\";
    \$ss[\"content_element_separator\"] = \"2.4\";
    \$ss[\"content_top\"]               = \"10\";
    \$ss[\"content_right\"]             = \"0\";
    \$ss[\"content_bottom\"]            = \"40\";
    \$ss[\"content_left\"]              = \"0\";
    \$ss[\"mobile_content_top\"]        = \"30\";
    \$ss[\"mobile_content_right\"]      = \"0\";
    \$ss[\"mobile_content_bottom\"]     = \"30\";
    \$ss[\"mobile_content_left\"]       = \"0\";
    \$ss[\"header_top\"]                = \"15\";
    \$ss[\"header_right\"]              = \"20\";
    \$ss[\"header_bottom\"]             = \"10\";
    \$ss[\"header_left\"]               = \"10\";
    update_option(\"generate_spacing_settings\", \$ss);
    echo \"generate_spacing_settings updated\n\";

    // 3. generate_menu_plus_settings — mobile header, off-canvas, sticky
    \$mp = (array) get_option(\"generate_menu_plus_settings\", []);
    \$mp[\"mobile_header\"]          = \"enable\";
    \$mp[\"mobile_header_branding\"] = \"logo\";
    \$mp[\"sticky_menu\"]            = \"false\";
    \$mp[\"slideout_menu\"]          = \"mobile\";
    update_option(\"generate_menu_plus_settings\", \$mp);
    echo \"generate_menu_plus_settings updated\n\";

    // 4. generate_blog_settings — GP Premium Blog module (Archives + Single meta)
    \$bl = (array) get_option(\"generate_blog_settings\", []);
    \$bl[\"author\"]            = true;  // Archives: Display Post Author (checked)
    \$bl[\"date\"]              = true;  // Archives: Display Post Date (checked)
    \$bl[\"categories\"]        = false; // Archives: Display Post Categories (unchecked)
    \$bl[\"tags\"]              = false; // Archives: Display Post Tags (unchecked)
    \$bl[\"comments\"]          = false; // Archives: Display Comment Count (unchecked)
    \$bl[\"single_categories\"] = true;  // Single: Display Post Categories (checked)
    \$bl[\"single_tags\"]       = true;  // Single: Display Post Tags (checked)
    \$bl[\"single_author\"]     = false; // Single: Display Post Author (unchecked)
    \$bl[\"single_date\"]       = false; // Single: Display Post Date (unchecked)
    \$bl[\"single_post_navigation\"] = false; // Single: Display Post Navigation (unchecked)
    update_option(\"generate_blog_settings\", \$bl);
    echo \"generate_blog_settings updated\n\";

    // 5. Disable Elements on all posts — hide Content Title + Featured Image
    \$posts = get_posts([\"post_type\" => [\"post\", \"page\"], \"posts_per_page\" => -1, \"post_status\" => \"any\", \"fields\" => \"ids\"]);
    \$count = 0;
    foreach (\$posts as \$pid) {
      update_post_meta(\$pid, \"_generate-disable-headline\", \"true\");
      update_post_meta(\$pid, \"_generate-disable-post-image\", \"true\");
      \$count++;
    }
    echo \"Disabled headline + featured image on \$count posts/pages\n\";

    echo \"Done\n\";
  ' --path='${WP_PATH}' 2>&1") || RESULT="failed"

if [[ "$RESULT" == *"Done"* ]]; then
  echo "  $RESULT"
  echo ""
  echo "Verify in WP Admin → Appearance → GP Premium → Layout:"
  echo "  Container:        Width ${CONTAINER_WIDTH}px, Content Layout: One Container, Padding: 10/0/40/0, Mobile: 30/0/30/0"
  echo "  Header:           Contained, Left aligned, Padding: 15/20/10/10, Mobile Header: On"
  echo "  Off Canvas Panel: Mobile Only"
  echo "  Sidebars:         All three set to No Sidebar"
  echo "  Blog → Archives:  Excerpt / 55 words / 'Read More' / Author ✓ Date ✓"
  echo "  Blog → Single:    Categories ✓ Tags ✓"
  echo "  Disable Elements: Content Title ✗ Featured Image ✗ (all posts)"
else
  echo "  ERROR: wp eval returned unexpected output:"
  echo "  $RESULT"
  exit 1
fi

echo ""
echo "Layout configuration complete."
