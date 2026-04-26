#!/usr/bin/env zsh
# wordpress.sh — Phase 1: WordPress setup (Steps 0–15)
# Called from main.sh or directly: ./scripts/phases/wordpress.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/scripts/phases/common.sh"

# ── Site slug ─────────────────────────────────────────────────────────────────
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

SITE_NOT_READY=false
for arg in "$@"; do
  [[ "$arg" == "--site-not-ready" ]] && SITE_NOT_READY=true
done

if [[ "$SITE_NOT_READY" == "false" ]]; then
  preflight_check
  [[ -n "${WP_SSH_HOST2:-}" ]] && _check_one_key "${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}" "WP_SSH_KEY2"
  [[ -n "${WP_SSH_HOST:-}" ]]  && _check_one_key "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}" "WP_SSH_KEY"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
if [[ "$SITE_NOT_READY" == "true" ]]; then
  echo "  WordPress Phase — ${SITE_HOST} [CONTENT ONLY — no WP push]"
else
  echo "  WordPress Phase — ${SITE_HOST}"
fi
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 0: Site setup ────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0 — Site Setup"
echo "────────────────────────────────────────────────────────────────────────────"

if [[ "$SITE_NOT_READY" == "false" ]]; then
  echo ""
  echo "  Which server is this site on?"
  printf "    [1] New server: %s@%s\n" "${WP_SSH_USER2:-?}" "${WP_SSH_HOST2:-?}"
  printf "    [2] Old server: %s@%s\n" "${WP_SSH_USER:-?}" "${WP_SSH_HOST:-?}"
  printf "  Enter 1 or 2: "
  read -r _SRV
  if [[ "$_SRV" == "2" ]]; then
    _ACTIVE_HOST="${WP_SSH_HOST}"; _ACTIVE_USER="${WP_SSH_USER}"; _ACTIVE_KEY="${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
    echo "  ✓ Using old server: ${_ACTIVE_USER}@${_ACTIVE_HOST}"
  else
    _ACTIVE_HOST="${WP_SSH_HOST2}"; _ACTIVE_USER="${WP_SSH_USER2}"; _ACTIVE_KEY="${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}"
    echo "  ✓ Using new server: ${_ACTIVE_USER}@${_ACTIVE_HOST}"
  fi
  export WP_SSH_HOST="$_ACTIVE_HOST" WP_SSH_USER="$_ACTIVE_USER" WP_SSH_KEY="$_ACTIVE_KEY"
  ssh_connect
fi

# 0b: Clear stale WP_PATH
if [[ -n "${WP_PATH:-}" ]]; then
  echo ""
  echo "  ⚠ WP_PATH is set to: $WP_PATH (may be from a previous site)"
  printf "  Unset and auto-discover? (Y/n): "
  read -r reply; reply="${reply:-Y}"
  if _is_yes "$reply"; then unset WP_PATH; echo "  ✓ WP_PATH unset."; fi
fi

# 0c: Input folder checklist
echo ""
echo "  Input folder checklist for: $CONTENT_SITE_SLUG"
_INPUT_DIR="$REPO_ROOT/input/$CONTENT_SITE_SLUG"
mkdir -p "$_INPUT_DIR/articles" "$_INPUT_DIR/images"
_check_item() {
  if ls $2 2>/dev/null | grep -q .; then
    printf "  ✓ %-30s %s\n" "$1" "$(ls $2 2>/dev/null | head -1 | xargs basename)"
  else
    printf "  ✗ %-30s MISSING\n" "$1"
  fi
}
_check_item "IA spreadsheet (*.xlsx)"  "$_INPUT_DIR/*.xlsx"
_check_item "tickets.docx or .md"      "$_INPUT_DIR/tickets.*"
_check_item "Article MD files"         "$_INPUT_DIR/articles/*.md"
_check_item "Logo"                     "$_INPUT_DIR/images/logo.png"
_check_item "Favicon"                  "$_INPUT_DIR/images/favicon.png"
echo ""
printf "  Place any missing files above, then press Enter to continue..."
read -r

if [[ "$SITE_NOT_READY" == "true" ]]; then
  echo "  [--site-not-ready] Skipping WordPress setup steps 2–15."
fi

# ── Step 1: Split Articles into Silo Folders ─────────────────────────────────
if prompt_step 1 "Split Articles into Silo Folders" \
    "Moves MD files from articles/ into tickets-tours/, plan-your-visit/, what-to-see/ based on xlsx." \
    "split_articles_done"; then
  _MD_COUNT=$(ls "$_INPUT_DIR/articles/"*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$_MD_COUNT" -gt 0 ]]; then
    _XLSX=$(echo "$_INPUT_DIR"/*.xlsx | tr ' ' '\n' | grep -v '\.bak$' | head -1)
    if [[ -f "$_XLSX" ]]; then
      python3 "$REPO_ROOT/scripts/content/standardize-xlsx.py" "$_XLSX"
    fi
    python3 - "$_INPUT_DIR" << 'PYEOF'
import sys, os, re, glob, shutil, openpyxl

base = sys.argv[1]
xlsx_files = glob.glob(os.path.join(base, '*.xlsx'))
if not xlsx_files:
    print("  ✗ No xlsx found — place xlsx in input folder and re-run.")
    sys.exit(1)

wb = openpyxl.load_workbook(xlsx_files[0])
SILO_MAP = {
    'Tickets & Tours': 'tickets-tours', 'Tickets and Tours': 'tickets-tours',
    'tickets': 'tickets-tours', 'tickets-tours': 'tickets-tours',
    'Plan Your Visit': 'plan-your-visit', 'plan-your-visit': 'plan-your-visit',
    'What To See': 'what-to-see', 'What to See': 'what-to-see', 'what-to-see': 'what-to-see',
}

slug_to_silo = {}
silo_sheets = [s for s in wb.sheetnames if s in SILO_MAP]
if silo_sheets:
    for sheet_name in silo_sheets:
        silo_folder = SILO_MAP[sheet_name]
        ws = wb[sheet_name]
        for row in ws.iter_rows(values_only=True):
            slug_val = row[3] if len(row) > 3 else None
            if not slug_val or not str(slug_val).startswith('/'): continue
            leaf = str(slug_val).strip('/').split('/')[-1]
            if leaf: slug_to_silo[leaf] = silo_folder
else:
    ws = wb.worksheets[0]
    _current_silo = None
    for row in ws.iter_rows(min_row=2, values_only=True):
        col0 = str(row[0]).strip() if row[0] else ''
        if col0 and '\n' in col0:
            silo_name = col0.split('\n')[0].strip()
            _current_silo = SILO_MAP.get(silo_name)
        if not _current_silo:
            continue
        art_slug = str(row[3]).strip() if len(row) > 3 and row[3] else ''
        if not art_slug: continue
        art_slug = art_slug.strip('/').split('/')[-1]
        if art_slug:
            slug_to_silo[art_slug] = _current_silo

print(f"  Loaded {len(slug_to_silo)} slugs from xlsx")

moved, unmatched = 0, []
for md_path in sorted(glob.glob(os.path.join(base, 'articles', '*.md'))):
    fname = os.path.basename(md_path)
    name = os.path.splitext(fname)[0]
    slug = re.sub(r'^(?:article-?\d+[_-]|\d+[-_])', '', name)
    if slug in slug_to_silo:
        os.makedirs(os.path.join(base, slug_to_silo[slug]), exist_ok=True)
        shutil.move(md_path, os.path.join(base, slug_to_silo[slug], fname))
        print(f"  → {slug_to_silo[slug]}/{fname}")
        moved += 1
    else:
        unmatched.append(fname)

print(f"\n  ✓ Moved {moved} files")
if unmatched:
    print(f"  ⚠ {len(unmatched)} unmatched (left in articles/): {', '.join(unmatched)}")
PYEOF
    mark_done "split_articles_done"
  else
    echo "  No MD files in articles/ — nothing to split."
    mark_done "split_articles_done"
  fi
else
  echo "  Skipped."
fi

if [[ "$SITE_NOT_READY" == "false" ]]; then

# ── Steps 2–15: WordPress setup ───────────────────────────────────────────────
if prompt_step 2 "Find WP Path" \
    "Auto-discovers the WordPress install path on the server for this site." \
    "find_wp_path_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/find-wp-path.sh" "$@"
  _SITE_ENV_RELOAD="$REPO_ROOT/input/$CONTENT_SITE_SLUG/.env"
  [[ -f "$_SITE_ENV_RELOAD" ]] && { set -a; source "$_SITE_ENV_RELOAD"; set +a; }
  mark_done "find_wp_path_done"
else
  echo "  Skipped."
fi

if prompt_step 3 "Cleanup" \
    "Removes all plugins (except Bluehost), all pages and posts. Only for a fresh Bluehost site." \
    "cleanup_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/cleanup.sh" "$@"
  mark_done "cleanup_done"
else
  echo "  Skipped."
fi

if prompt_step 4 "Install Plugins & Theme" \
    "Installs GenerateBlocks, GP Premium, WP Rocket, Max Mega Menu, Fluent Forms, Rank Math Pro, and GeneratePress theme." \
    "setup_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/setup.sh" "$@"
  mark_done "setup_done"
else
  echo "  Skipped."
fi

if prompt_step 5 "Configure Permalinks" \
    "Sets permalink structure to /%category%/%postname%/ and flushes rewrite rules." \
    "configure_permalinks_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/configure-permalinks.sh"
  mark_done "configure_permalinks_done"
else
  echo "  Skipped."
fi

if prompt_step 6 "Activate GP Premium" \
    "Stores the license key and activates GP Premium modules via WP-CLI." \
    "gp_premium_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/activate-gp-premium.sh" "$@"
  mark_done "gp_premium_done"
else
  echo "  Skipped."
fi

if prompt_step 7 "Customize Appearance" \
    "Hides site title and tagline, uploads logo and favicon via WP-CLI." \
    "customize_appearance_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/customize-appearance.sh" --site-slug "$CONTENT_SITE_SLUG" "$@"
  mark_done "customize_appearance_done"
else
  echo "  Skipped."
fi

if prompt_step 8 "Configure Layout" \
    "Sets container width, header layout, mobile header, sidebar via WP-CLI." \
    "configure_layout_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/configure-layout.sh" "$@"
  mark_done "configure_layout_done"
else
  echo "  Skipped."
fi

if prompt_step 9 "Configure Colors" \
    "Sets GeneratePress theme colors via WP-CLI." \
    "configure_colors_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/configure-colors.sh" "$@"
  mark_done "configure_colors_done"
else
  echo "  Skipped."
fi

if prompt_step 10 "Configure Typography" \
    "Adds Karla font to GP Font Library via WP-CLI." \
    "configure_typography_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/configure-typography.sh" "$@"
  mark_done "configure_typography_done"
else
  echo "  Skipped."
fi

if prompt_step 11 "Import GP Elements" \
    "Imports GeneratePress Elements (Google Analytics, Author Profile, etc.) via WP-CLI." \
    "import_gp_elements_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/import-gp-elements.sh" --site-slug "$CONTENT_SITE_SLUG" "$@"
  mark_done "import_gp_elements_done"
else
  echo "  Skipped."
fi

if prompt_step 12 "Deploy Templates" \
    "Deploys footer and Author Box CSS with site-specific branding." \
    "deploy_templates_done"; then
  _SITE_HOST_LOCAL="${WP_SITE_URL#https://}"
  _SITE_HOST_LOCAL="${_SITE_HOST_LOCAL#http://}"
  _SITE_HOST_LOCAL="${_SITE_HOST_LOCAL%%/*}"
  _ATTRACTION_NAME=$(echo "$_SITE_HOST_LOCAL" | sed 's/-guide\.com$//' | sed 's/-/ /g' | \
    awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')
  case "$_SITE_HOST_LOCAL" in
    *auschwitz*) _ACCENT_COLOR="#ff0000" ;;
    *opera*)     _ACCENT_COLOR="#c4956c" ;;
    *)           _ACCENT_COLOR="#ff0000" ;;
  esac
  BLUEHOST_USER="$WP_SSH_USER" BLUEHOST_HOST="$WP_SSH_HOST" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/deploy-templates.sh" \
    "$_SITE_HOST_LOCAL" "$CONTENT_SITE_SLUG" "$_ATTRACTION_NAME" "$_ACCENT_COLOR"
  mark_done "deploy_templates_done"
else
  echo "  Skipped."
fi

if prompt_step 13 "Configure Indexing" \
    "Discourages search engine indexing while in development." \
    "settings_indexing_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/settings-indexing.sh" "$@"
  mark_done "settings_indexing_done"
else
  echo "  Skipped."
fi

if prompt_step 14 "Configure Categories" \
    "Creates 3 WordPress post categories (Tickets & Tours, Plan Your Visit, What to See)." \
    "configure_categories_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/configure-categories.sh" "$CONTENT_SITE_SLUG"
  mark_done "configure_categories_done"
else
  echo "  Skipped."
fi

if prompt_step 15 "Configure Rank Math" \
    "Activates Rank Math modules, sets title separator, enables XML sitemap." \
    "configure_rank_math_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/configure-rank-math.sh"
  mark_done "configure_rank_math_done"
else
  echo "  Skipped."
fi

prompt_manual "Go to WP Admin → Rank Math → Dashboard → Connect your account (activates Pro modules)." \
  "rank_math_pro_connected_done"

fi # end SITE_NOT_READY block

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  WordPress phase complete — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"
