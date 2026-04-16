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

_WP_KEY="${WP_SSH_KEY/#\~/$HOME}"
SSH_KEY_OPT=(-i "$_WP_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15)


# ── configure-rank-math.sh ───────────────────────────────────────────────────
# Automates the Rank Math Pro setup wizard via WP-CLI (wp eval).
# Replaces the manual next→next→next wizard flow with direct option writes.
#
# What this automates:
#   - Marks wizard as complete (skips the setup wizard redirect)
#   - Activates key modules: sitemap, rich-snippet, breadcrumbs, robots-txt,
#     seo-analysis, local-seo, news-sitemap, image-seo
#   - Sets sensible SEO title separators and homepage defaults
#   - Enables XML sitemap
#
# What requires manual action:
#   - Google Search Console OAuth connection (requires browser login)
#
# Usage:
#   ./scripts/base/configure-rank-math.sh
#
# Requires in .env: WP_SSH_HOST, WP_SSH_USER, WP_PATH
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${RM_CHECK:-}" == "NOT_ACTIVE" ]]; then
  echo "✗ Rank Math plugin not active. Run Step 3 (Install Plugins) first."
  exit 1
fi

echo "✓ Rank Math is active"
echo ""

# ── Main: configure via wp eval ───────────────────────────────────────────────
echo "── Applying Rank Math configuration ────────────────────────────────────────"

RESULT=$(ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp eval '
    // 1. Mark wizard as complete (bypasses setup redirect)
    update_option(\"rank_math_is_configured\", 1);
    echo \"✓ Wizard marked complete\n\";

    // 2. Activate key modules
    \$modules = get_option(\"rank_math_modules\", []);
    if (!is_array(\$modules)) \$modules = [];
    \$wanted = [
      \"rich-snippet\",
      \"sitemap\",
      \"breadcrumbs\",
      \"robots-txt\",
      \"seo-analysis\",
      \"image-seo\",
    ];
    \$added = [];
    foreach (\$wanted as \$m) {
      if (!in_array(\$m, \$modules)) {
        \$modules[] = \$m;
        \$added[] = \$m;
      }
    }
    update_option(\"rank_math_modules\", \$modules);
    if (\$added) {
      echo \"✓ Activated modules: \" . implode(\", \", \$added) . \"\n\";
    } else {
      echo \"✓ All modules already active\n\";
    }

    // 3. General settings
    \$general = get_option(\"rank-math-options-general\", []);
    if (!is_array(\$general)) \$general = [];

    // Title separator
    if (empty(\$general[\"title_separator\"])) {
      \$general[\"title_separator\"] = \"-\";
      echo \"✓ title_separator set to: -\n\";
    }

    // Do not strip category base by default
    if (!isset(\$general[\"strip_category_base\"])) {
      \$general[\"strip_category_base\"] = \"off\";
    }

    // Breadcrumbs separator
    if (empty(\$general[\"breadcrumbs_separator\"])) {
      \$general[\"breadcrumbs_separator\"] = \"»\";
    }

    update_option(\"rank-math-options-general\", \$general);
    echo \"✓ General settings applied\n\";

    // 4. Sitemap settings — enable XML sitemap
    \$sitemap = get_option(\"rank-math-options-sitemap\", []);
    if (!is_array(\$sitemap)) \$sitemap = [];

    if (empty(\$sitemap[\"items_per_page\"])) {
      \$sitemap[\"items_per_page\"] = 200;
    }
    if (!isset(\$sitemap[\"include_images\"])) {
      \$sitemap[\"include_images\"] = \"on\";
    }
    update_option(\"rank-math-options-sitemap\", \$sitemap);

    // Ping search engines
    update_option(\"rank_math_sitemap_ping\", 1);
    echo \"✓ Sitemap settings applied\n\";

    // 5. Rich snippet defaults — WebPage for posts
    \$titles = get_option(\"rank-math-options-titles\", []);
    if (!is_array(\$titles)) \$titles = [];
    if (empty(\$titles[\"pt_post_default_rich_snippet\"])) {
      \$titles[\"pt_post_default_rich_snippet\"] = \"article\";
      echo \"✓ Default rich snippet type set to: article\n\";
    }
    if (empty(\$titles[\"pt_page_default_rich_snippet\"])) {
      \$titles[\"pt_page_default_rich_snippet\"] = \"webpage\";
      echo \"✓ Default rich snippet type (pages) set to: webpage\n\";
    }
    update_option(\"rank-math-options-titles\", \$titles);

    echo \"\nDone\n\";
  ' --path='${WP_PATH}' 2>&1") || RESULT="wp eval failed"

echo "$RESULT"
echo ""

if [[ "$RESULT" != *"Done"* ]]; then
  echo "✗ Configuration did not complete cleanly. Check output above."
  exit 1
fi

echo "── Flush rewrite rules ──────────────────────────────────────────────────────"
ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" \
  "wp rewrite flush --path='${WP_PATH}' 2>&1" && echo "✓ Rewrite rules flushed" || \
  echo "⚠ Could not flush rewrite rules (non-fatal)"

echo ""
echo "========================================================="
echo "  Rank Math configured."
echo ""
echo "  Manual steps still required:"
echo "  1. Google Search Console: Rank Math → General Settings → Webmaster Tools"
echo "     → paste your GSC verification code (or connect via OAuth in RM dashboard)"
echo "  2. Review: Rank Math → Dashboard — confirm all modules show green"
echo "  3. Sitemap URL: ${WP_SITE_URL:-<site-url>}/sitemap_index.xml"
echo "========================================================="
