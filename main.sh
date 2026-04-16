#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Flags ─────────────────────────────────────────────────────────────────────
SITE_NOT_READY=false
for arg in "$@"; do
  [[ "$arg" == "--site-not-ready" ]] && SITE_NOT_READY=true
done

# ── Ask for site slug first — needed to load per-site .env ───────────────────
echo ""
printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
read -r CONTENT_SITE_SLUG

# Load root .env first, then per-site .env overrides
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
SITE_ENV="$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/.env"
if [[ -f "$SITE_ENV" ]]; then
  set -a; source "$SITE_ENV"; set +a
  echo "  ✓ Loaded per-site config: input/$CONTENT_SITE_SLUG/.env"
else
  echo ""
  echo "  No per-site .env found. Enter site-specific details:"
  mkdir -p "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG"
  printf "  Site URL (e.g. https://hagiasophia-guide.com): "
  read -r _SITE_URL
  printf "  Campaign prefix (e.g. hagia-sophia, auschwitz, msm): "
  read -r _CAMPAIGN_PREFIX
  printf "  GA4 Measurement ID (e.g. G-XXXXXXXXXX): "
  read -r _GA4_ID
  printf "  Favicon URL (full URL to uploaded PNG, e.g. https://site.com/wp-content/uploads/.../favicon.png): "
  read -r _FAVICON_URL
  cat > "$SITE_ENV" << SITEENV
WP_SITE_URL=${_SITE_URL}
CAMPAIGN_PREFIX=${_CAMPAIGN_PREFIX}
GA4_MEASUREMENT_ID=${_GA4_ID}
FAVICON_URL=${_FAVICON_URL}
logo_path=input/${CONTENT_SITE_SLUG}/images/logo.png
favicon_path=input/${CONTENT_SITE_SLUG}/images/favicon.png
SITEENV
  set -a; source "$SITE_ENV"; set +a
  echo "  ✓ Saved and loaded: input/$CONTENT_SITE_SLUG/.env"
fi

SITE_HOST="${WP_SITE_URL:-default}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"
mkdir -p "$SCRIPT_DIR/state"
STATE_FILE="$SCRIPT_DIR/state/.setup-state-${SITE_HOST}"

step_done() { [[ -f "$STATE_FILE" ]] && grep -qF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { echo "$1" >> "$STATE_FILE"; }

# Accept: y, Y, yes, 1  → run    |   n, N, no, 0  → skip
_is_yes() { [[ "$1" =~ ^([Yy]([Ee][Ss])?|1)$ ]]; }
_is_no()  { [[ "$1" =~ ^([Nn][Oo]?|0)$       ]]; }

prompt_step() {
  local num="$1" name="$2" desc="$3" key="$4"
  local reply
  echo ""
  echo "────────────────────────────────────────────────────────────────────────────"
  printf "  Step %s — %s\n" "$num" "$name"
  printf "  %s\n" "$desc"
  if step_done "$key"; then
    echo "  [already done — logged in $(basename "$STATE_FILE")]"
    printf "  Run again? (y/N): "
    read -r reply; reply="${reply:-N}"
  else
    printf "  Run this step? (Y/n): "
    read -r reply; reply="${reply:-Y}"
  fi
  _is_yes "$reply"
}

prompt_manual() {
  local msg="$1" key="$2"
  if step_done "$key"; then return 0; fi
  echo ""
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "  Manual — $msg"
  echo "────────────────────────────────────────────────────────────────────────────"
  local reply
  printf "  Done? (Y/n): "
  read -r reply; reply="${reply:-Y}"
  if _is_yes "$reply"; then
    mark_done "$key"
    echo "  ✓ Marked done."
  fi
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
_preflight_check() {
  local required_vars=(WP_SITE_URL WP_USER WP_PASS GA4_MEASUREMENT_ID GeneratePress_license_key)
  if [[ -z "${WP_SSH_HOST:-}" && -z "${WP_SSH_HOST2:-}" ]]; then
    echo "ERROR: No SSH server configured. Set WP_SSH_HOST or WP_SSH_HOST2 in .env."
    exit 1
  fi
  local missing=()
  for var in "${required_vars[@]}"; do
    [[ -n "${(P)var:-}" ]] || missing+=("$var")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required .env vars: ${missing[*]}"
    echo "  Fill in root .env and/or input/$CONTENT_SITE_SLUG/.env"
    exit 1
  fi
  echo "  ✓ Config validated"
}

_check_one_key() {
  local key_path="$1" label="$2"
  if [[ ! -f "$key_path" ]]; then
    echo "ERROR: SSH key not found at $key_path ($label)"; exit 1
  fi
  local perms
  perms=$(stat -f "%OLp" "$key_path" 2>/dev/null || stat -c "%a" "$key_path" 2>/dev/null || echo "unknown")
  if [[ "$perms" != "600" && "$perms" != "unknown" ]]; then
    echo "WARN: SSH key $key_path permissions are $perms — fix with: chmod 600 $key_path"
  fi
  if ! ssh-keygen -y -f "$key_path" < /dev/null >/dev/null 2>&1; then
    echo "ERROR: SSH key $key_path requires a passphrase. Run: ssh-add $key_path"; exit 1
  fi
  echo "  ✓ SSH key OK: $key_path"
}

if [[ "$SITE_NOT_READY" == "false" ]]; then
  _preflight_check
  [[ -n "${WP_SSH_HOST2:-}" ]] && _check_one_key "${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}" "WP_SSH_KEY2"
  [[ -n "${WP_SSH_HOST:-}" ]]  && _check_one_key "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}" "WP_SSH_KEY"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
if [[ "$SITE_NOT_READY" == "true" ]]; then
  echo "  Auto Create Site — ${SITE_HOST} [CONTENT ONLY — no WP push]"
else
  echo "  Auto Create Site — ${SITE_HOST}"
fi
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 0: Site setup ────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0 — Site Setup"
echo "────────────────────────────────────────────────────────────────────────────"

# 0a: Choose server (skip in --site-not-ready mode)
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
  # Keep active server selection in memory only — don't overwrite .env
  export WP_SSH_HOST="$_ACTIVE_HOST" WP_SSH_USER="$_ACTIVE_USER" WP_SSH_KEY="$_ACTIVE_KEY"

  # ── SSH ControlMaster — one persistent connection for all child scripts ──────
  # Avoids Bluehost fail2ban blocking rapid SSH reconnections.
  export SSH_CONTROL_PATH="/tmp/wp-ssh-main-$$"
  ssh -i "$WP_SSH_KEY" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600 \
    -N -f "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null \
    && echo "  ✓ SSH multiplexed connection established" \
    || echo "  ⚠ SSH multiplexing failed — scripts will fall back to individual connections"
  trap '[[ -n "${SSH_CONTROL_PATH:-}" ]] && ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null; true' EXIT
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
_INPUT_DIR="$SCRIPT_DIR/input/$CONTENT_SITE_SLUG"
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
  echo "  [--site-not-ready] Skipping WordPress setup steps 2–14."
fi

# ── Step 1: Split Articles into Silo Folders ─────────────────────────────────
if prompt_step 1 "Split Articles into Silo Folders" \
    "Moves MD files from articles/ into tickets-tours/, plan-your-visit/, what-to-see/ based on xlsx." \
    "split_articles_done"; then
  _MD_COUNT=$(ls "$_INPUT_DIR/articles/"*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$_MD_COUNT" -gt 0 ]]; then
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

# Detect format: per-silo sheets vs master sheet
silo_sheets = [s for s in wb.sheetnames if s in SILO_MAP]
if silo_sheets:
    # Per-silo format: each sheet is a category, slug in col 3 as /silo/slug/
    for sheet_name in silo_sheets:
        silo_folder = SILO_MAP[sheet_name]
        ws = wb[sheet_name]
        for row in ws.iter_rows(values_only=True):
            slug_val = row[3] if len(row) > 3 else None
            if not slug_val or not str(slug_val).startswith('/'): continue
            leaf = str(slug_val).strip('/').split('/')[-1]
            if leaf: slug_to_silo[leaf] = silo_folder
else:
    # Standard 7-col master sheet: col0=silo-header(has \n) or blank,
    # col1=cat_id, col2=title, col3=url_slug, col4=keyword...
    ws = wb.worksheets[0]
    _current_silo = None
    for row in ws.iter_rows(min_row=2, values_only=True):
        col0 = str(row[0]).strip() if row[0] else ''
        # Silo-header row: col0 contains newline e.g. "Tickets & Tours\n/tickets/"
        if col0 and '\n' in col0:
            silo_name = col0.split('\n')[0].strip()
            _current_silo = SILO_MAP.get(silo_name)
            continue
        if not _current_silo:
            continue
        art_slug = str(row[3]).strip() if len(row) > 3 and row[3] else ''
        if not art_slug: continue
        # Normalize: strip leading/trailing slashes, take leaf segment
        art_slug = art_slug.strip('/').split('/')[-1]
        if art_slug:
            slug_to_silo[art_slug] = _current_silo

print(f"  Loaded {len(slug_to_silo)} slugs from xlsx")

moved, unmatched = 0, []
for md_path in sorted(glob.glob(os.path.join(base, 'articles', '*.md'))):
    fname = os.path.basename(md_path)
    name = os.path.splitext(fname)[0]
    # Strip leading patterns: "27-slug", "article27_slug", "article27-slug", "article-27-slug"
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

# ── Step 2: Find WP Path ──────────────────────────────────────────────────────
if prompt_step 2 "Find WP Path" \
    "Auto-discovers the WordPress install path on the server for this site." \
    "find_wp_path_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/find-wp-path.sh" "$@"

  # Re-source site .env so WP_PATH written by find-wp-path.sh is available here
  _SITE_ENV_RELOAD="$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/.env"
  [[ -f "$_SITE_ENV_RELOAD" ]] && { set -a; source "$_SITE_ENV_RELOAD"; set +a; }

  if [[ -z "${WP_PATH:-}" ]]; then
    echo "  Auto-discovering WP_PATH for ${WP_SITE_URL}..."
    SITE_HOST_FOR_SEARCH="${WP_SITE_URL#https://}"; SITE_HOST_FOR_SEARCH="${SITE_HOST_FOR_SEARCH#http://}"; SITE_HOST_FOR_SEARCH="${SITE_HOST_FOR_SEARCH%%/*}"

    _try_find_wp_path() {
      local host="$1" user="$2" key="$3" site_host="$4"
      ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${user}@${host}" "
        root=/home1/${user}/public_html
        url=\$(wp option get siteurl --path=\"\$root\" 2>/dev/null) || true
        [[ \"\$url\" == *\"${site_host}\"* ]] && echo \"\$root/\" && exit 0
        for d in \$root/website_*/; do
          url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || continue
          [[ \"\$url\" == *\"${site_host}\"* ]] && echo \"\$d\" && break
        done
      " 2>/dev/null || true
    }

    WP_PATH_FOUND=""
    if [[ -n "${WP_SSH_HOST2:-}" ]]; then
      echo "  → Trying new server (${WP_SSH_HOST2})..."
      WP_PATH_FOUND=$(_try_find_wp_path "$WP_SSH_HOST2" "$WP_SSH_USER2" "${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}" "$SITE_HOST_FOR_SEARCH")
      WP_PATH_FOUND="${WP_PATH_FOUND%/}"
      if [[ -n "$WP_PATH_FOUND" ]]; then
        export WP_SSH_HOST="$WP_SSH_HOST2" WP_SSH_USER="$WP_SSH_USER2" WP_SSH_KEY="${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}"
        echo "  ✓ Found on new server"
      fi
    fi
    if [[ -z "$WP_PATH_FOUND" ]]; then
      WP_PATH_FOUND=$(_try_find_wp_path "$WP_SSH_HOST" "$WP_SSH_USER" "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}" "$SITE_HOST_FOR_SEARCH")
      WP_PATH_FOUND="${WP_PATH_FOUND%/}"
      [[ -n "$WP_PATH_FOUND" ]] && echo "  ✓ Found on old server"
    fi

    if [[ -n "$WP_PATH_FOUND" ]]; then
      export WP_PATH="$WP_PATH_FOUND"
      echo "  WP_PATH: $WP_PATH"
      # Persist WP_PATH to site-specific .env so all child scripts pick it up
      _SITE_ENV="$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/.env"
      if grep -q '^WP_PATH=' "$_SITE_ENV" 2>/dev/null; then
        sed -i.bak "s|^WP_PATH=.*|WP_PATH=$WP_PATH|" "$_SITE_ENV" && rm -f "$_SITE_ENV.bak"
      else
        printf "\nWP_PATH=%s\n" "$WP_PATH" >> "$_SITE_ENV"
      fi
    else
      echo "  WARNING: Could not auto-discover WP_PATH. Set it manually in input/$CONTENT_SITE_SLUG/.env."
    fi
  fi
  mark_done "find_wp_path_done"
else
  echo "  Skipped."
fi

# ── Step 3: Cleanup ──────────────────────────────────────────────────────────
if prompt_step 3 "Cleanup" \
    "Removes all plugins (except Bluehost), all pages and posts. Only for a fresh Bluehost site." \
    "cleanup_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/cleanup.sh" "$@"
  mark_done "cleanup_done"
else
  echo "  Skipped."
fi

# ── Step 4: Install Plugins & Theme ──────────────────────────────────────────
if prompt_step 4 "Install Plugins & Theme" \
    "Installs GenerateBlocks, GP Premium, WP Rocket, Max Mega Menu, Fluent Forms, Rank Math Pro, and GeneratePress theme." \
    "setup_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/setup.sh" "$@"
  mark_done "setup_done"
else
  echo "  Skipped."
fi

# ── Step 5: Activate GP Premium ──────────────────────────────────────────────
if prompt_step 5 "Activate GP Premium" \
    "Stores the license key and activates GP Premium modules via WP-CLI." \
    "gp_premium_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/activate-gp-premium.sh" "$@"
  mark_done "gp_premium_done"
else
  echo "  Skipped."
fi

# ── Step 6: Customize Appearance ─────────────────────────────────────────────
if prompt_step 6 "Customize Appearance" \
    "Hides site title and tagline, uploads logo and favicon via WP-CLI." \
    "customize_appearance_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/customize-appearance.sh" --site-slug "$CONTENT_SITE_SLUG" "$@"
  mark_done "customize_appearance_done"
else
  echo "  Skipped."
fi

# ── Step 7: Configure Layout ─────────────────────────────────────────────────
if prompt_step 7 "Configure Layout" \
    "Sets container width, header layout, mobile header, sidebar via WP-CLI." \
    "configure_layout_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/configure-layout.sh" "$@"
  mark_done "configure_layout_done"
else
  echo "  Skipped."
fi

# ── Step 8: Configure Colors ─────────────────────────────────────────────────
if prompt_step 8 "Configure Colors" \
    "Sets GeneratePress theme colors via WP-CLI." \
    "configure_colors_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/configure-colors.sh" "$@"
  mark_done "configure_colors_done"
else
  echo "  Skipped."
fi

# ── Step 9: Configure Typography ─────────────────────────────────────────────
if prompt_step 9 "Configure Typography" \
    "Adds Karla font to GP Font Library via WP-CLI." \
    "configure_typography_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/configure-typography.sh" "$@"
  mark_done "configure_typography_done"
else
  echo "  Skipped."
fi

# ── Step 10: Import GP Elements ──────────────────────────────────────────────
if prompt_step 10 "Import GP Elements" \
    "Imports GeneratePress Elements (Google Analytics, Author Profile, etc.) via WP-CLI." \
    "import_gp_elements_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/import-gp-elements.sh" --site-slug "$CONTENT_SITE_SLUG" "$@"
  mark_done "import_gp_elements_done"
else
  echo "  Skipped."
fi

# ── Step 11: Deploy Templates ────────────────────────────────────────────────
if prompt_step 11 "Deploy Templates" \
    "Deploys footer, About Us, Contact Us pages and Author Box CSS with site-specific branding." \
    "deploy_templates_done"; then

  # Extract site info for template deployment
  SITE_HOST="${WP_SITE_URL#https://}"
  SITE_HOST="${SITE_HOST#http://}"
  SITE_HOST="${SITE_HOST%%/*}"

  # Get attraction name from site host (capitalize and clean)
  ATTRACTION_NAME=$(echo "$SITE_HOST" | sed 's/-guide\.com$//' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')

  # Set accent color based on site
  case "$SITE_HOST" in
    *auschwitz*) ACCENT_COLOR="#ff0000" ;;
    *opera*) ACCENT_COLOR="#c4956c" ;;
    *) ACCENT_COLOR="#ff0000" ;;  # Default red
  esac

  echo "  🎨 Deploying templates with:"
  echo "     Site: $SITE_HOST"
  echo "     Attraction: $ATTRACTION_NAME"
  echo "     Accent Color: $ACCENT_COLOR"

  BLUEHOST_USER="$WP_SSH_USER" BLUEHOST_HOST="$WP_SSH_HOST" WP_SSH_KEY="$WP_SSH_KEY" \
    "$SCRIPT_DIR/scripts/base/10-deploy-templates.sh" "$SITE_HOST" "$CONTENT_SITE_SLUG" "$ATTRACTION_NAME" "$ACCENT_COLOR"
  mark_done "deploy_templates_done"
else
  echo "  Skipped."
fi

# ── Step 12: Configure Permalinks ────────────────────────────────────────────
if prompt_step 12 "Configure Permalinks" \
    "Sets permalink structure to /%category%/%postname%/ and flushes rewrite rules. Must run before Categories and Rank Math." \
    "configure_permalinks_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/configure-permalinks.sh"
  mark_done "configure_permalinks_done"
else
  echo "  Skipped."
fi

# ── Step 13: Configure Indexing ──────────────────────────────────────────────
if prompt_step 13 "Configure Indexing" \
    "Discourages search engine indexing while in development." \
    "settings_indexing_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/settings-indexing.sh" "$@"
  mark_done "settings_indexing_done"
else
  echo "  Skipped."
fi

# ── Step 14: Configure Categories ────────────────────────────────────────────
if prompt_step 14 "Configure Categories" \
    "Creates 3 WordPress post categories (Tickets & Tours, Plan Your Visit, What to See)." \
    "configure_categories_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/configure-categories.sh" "$CONTENT_SITE_SLUG"
  mark_done "configure_categories_done"
else
  echo "  Skipped."
fi

# ── Step 15: Configure Rank Math ─────────────────────────────────────────────
if prompt_step 15 "Configure Rank Math" \
    "Activates Rank Math modules (sitemap, rich snippets, breadcrumbs), sets title separator, enables XML sitemap." \
    "configure_rank_math_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$SCRIPT_DIR/scripts/base/configure-rank-math.sh"
  mark_done "configure_rank_math_done"
else
  echo "  Skipped."
fi

prompt_manual "Go to WP Admin → Rank Math → Dashboard → Connect your account (activates Pro modules)." "rank_math_pro_connected_done"

fi # end --site-not-ready skip block (steps 2–15: WP setup)

# ── Step 16: Convert tickets.docx → tickets.md ───────────────────────────────
if [[ -f "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/tickets.docx" && ! -f "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/tickets.md" ]]; then
  if prompt_step 16 "Convert tickets.docx → tickets.md" \
      "Parses tickets.docx and generates the tickets.md file needed for config generation." \
      "docx_to_tickets_done"; then
    "$SCRIPT_DIR/scripts/content/docx-to-tickets.sh" "$CONTENT_SITE_SLUG"
    echo "  Review input/$CONTENT_SITE_SLUG/tickets.md before continuing."
    mark_done "docx_to_tickets_done"
  else
    echo "  Skipped."
  fi
elif [[ -f "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/tickets.md" ]]; then
  echo "  ✓ tickets.md already exists — skipping docx conversion."
fi

# ── Step 17: Generate Site Configs ───────────────────────────────────────────
if prompt_step 17 "Generate Site Configs" \
    "Generates homepage-config.json and l1-config.json from tickets.md via Claude." \
    "generate_configs_done"; then
  if [[ ! -f "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/tickets.md" ]]; then
    echo "  ERROR: input/$CONTENT_SITE_SLUG/tickets.md not found."
    echo "  Format: T1 | Title | URL | Partner | /l2-slug/"
    exit 1
  fi
  "$SCRIPT_DIR/scripts/content/generate-configs.sh" "$CONTENT_SITE_SLUG" && mark_done "generate_configs_done"
else
  echo "  Skipped."
fi

# ── Step 18: Populate tickets array in homepage-config.json ──────────────────
if prompt_step 18 "Populate Tickets Array" \
    "Parses tickets.md and populates the tickets[] array in homepage-config.json (needed for homepage and L1 tickets page)." \
    "populate_tickets_done"; then
  if [[ ! -f "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/homepage-config.json" ]]; then
    echo "  ERROR: homepage-config.json not found. Run Step 17 first."
    exit 1
  fi
  if [[ ! -f "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/tickets.md" ]]; then
    echo "  ERROR: tickets.md not found."
    exit 1
  fi
  "$SCRIPT_DIR/scripts/content/populate-tickets.sh" "$CONTENT_SITE_SLUG" && mark_done "populate_tickets_done"
else
  echo "  Skipped."
fi

# ── Step 19: Sample MD to HTML (1 per silo) ──────────────────────────────────
if prompt_step 19 "Sample MD to HTML (1 per silo)" \
    "Converts 1 article from each silo to HTML for verification before full batch." \
    "md_to_html_sample_done"; then
  _PIDS=(); _LOGS=()
  for silo in tickets-tours plan-your-visit what-to-see; do
    _FIRST=$(ls "$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/$silo/"*.md 2>/dev/null | head -1)
    if [[ -z "$_FIRST" ]]; then echo "  ⚠ No articles in $silo — skipping"; continue; fi
    _LOG=$(mktemp /tmp/md-sample-XXXXXX)
    _LOGS+=("$silo:$_LOG")
    echo "  → $silo: $(basename "$_FIRST")"
    "$SCRIPT_DIR/scripts/content/md-to-html.sh" "$CONTENT_SITE_SLUG" "$_FIRST" --force > "$_LOG" 2>&1 &
    _PIDS+=($!)
  done
  _HB_START=$SECONDS
  ( while true; do sleep 5; printf "    ⏱  %ds elapsed\n" "$(( SECONDS - _HB_START ))" >&2; done ) &
  _HB_PID=$!
  _SAMPLE_OK=true
  for pid in "${_PIDS[@]}"; do wait "$pid" || _SAMPLE_OK=false; done
  kill "$_HB_PID" 2>/dev/null; wait "$_HB_PID" 2>/dev/null || true
  for entry in "${_LOGS[@]}"; do
    echo ""; echo "  ── ${entry%%:*} ──"; cat "${entry##*:}"; rm -f "${entry##*:}"
  done
  if $_SAMPLE_OK; then
    mark_done "md_to_html_sample_done"
    echo "  ✓ Samples generated. Review output/$CONTENT_SITE_SLUG/l2-articles/ before continuing."
  else
    echo "  ✗ Some samples failed — fix before proceeding."; exit 1
  fi
else
  echo "  Skipped."
fi

# ── Step 20: Convert All MD to HTML ──────────────────────────────────────────
if prompt_step 20 "Convert All MD to HTML" \
    "Converts all markdown articles to HTML using the article template." \
    "md_to_html_done"; then
  "$SCRIPT_DIR/scripts/content/batch-md-to-html.sh" "$CONTENT_SITE_SLUG" && mark_done "md_to_html_done"
else
  echo "  Skipped."
fi

# ── Step 21: Generate L1 Content ─────────────────────────────────────────────
if prompt_step 21 "Generate L1 Content" \
    "Auto-generates article descriptions, practical cards, FAQs, tips, and card tags via Claude." \
    "generate_l1_content_done"; then
  "$SCRIPT_DIR/scripts/content/generate-l1-pages.sh" "$CONTENT_SITE_SLUG" --force && mark_done "generate_l1_content_done"
  echo "  Review l1-config.json before building HTML."
else
  echo "  Skipped."
fi

# ── Step 22: Generate L1 HTML ────────────────────────────────────────────────
if prompt_step 22 "Generate L1 HTML" \
    "Builds 3 L1 category hub pages (Tickets & Tours, Plan Your Visit, What to See) via Claude." \
    "generate_l1_html_done"; then
  "$SCRIPT_DIR/scripts/content/generate-l1-pages.sh" "$CONTENT_SITE_SLUG" --html-only && mark_done "generate_l1_html_done"
else
  echo "  Skipped."
fi

# ── Step 23: Generate Homepage ───────────────────────────────────────────────
if prompt_step 23 "Generate Homepage" \
    "Generates the homepage with ticket cards, highlights, tips, and FAQ from tickets.md." \
    "generate_homepage_done"; then
  "$SCRIPT_DIR/scripts/content/generate-homepage.sh" "$CONTENT_SITE_SLUG" --force && mark_done "generate_homepage_done"
else
  echo "  Skipped."
fi

# ── Step 24: Publish to WordPress (skipped in --site-not-ready) ──────────────
if [[ "$SITE_NOT_READY" == "true" ]]; then
  echo ""
  echo "  [--site-not-ready] Skipping Step 24 (publish to WordPress)."
else
  if prompt_step 24 "Publish to WordPress" \
      "Publishes all generated HTML (L2 articles + L1 pages + homepage) to WordPress." \
      "publish_wp_done"; then
    "$SCRIPT_DIR/scripts/content/publish-to-wordpress.sh" "$CONTENT_SITE_SLUG" --status publish
    mark_done "publish_wp_done"
  else
    echo "  Skipped."
  fi
fi

# ── Step 25: Clear WP Cache ──────────────────────────────────────────────────
if [[ "$SITE_NOT_READY" == "false" ]]; then
  if prompt_step 25 "Clear WP Cache" \
      "Clears WP Rocket page cache and WP object cache via SSH after publishing." \
      "clear_cache_done"; then
    echo "  Clearing caches on ${WP_SSH_HOST}..."
    _WP_KEY="${WP_SSH_KEY/#\~/$HOME}"
    ssh -i "$_WP_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 "${WP_SSH_USER}@${WP_SSH_HOST}" bash << SSHEOF
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
fi

# ── Step 26: Fetch GYG Images ────────────────────────────────────────────────
if prompt_step 26 "Fetch GYG Images (AVIF + WebP)" \
    "Downloads tour photos from GetYourGuide API, converts to WebP + AVIF, writes manifest.json." \
    "fetch_images_done"; then
  printf "  GYG search term for this attraction (e.g. 'Hagia Sophia'): "
  read -r GYG_SEARCH_TERM
  if [[ -z "$GYG_SEARCH_TERM" ]]; then echo "  ERROR: Search term required."; exit 1; fi
  "$SCRIPT_DIR/scripts/fetch-gyg-images.sh" "$CONTENT_SITE_SLUG" "$GYG_SEARCH_TERM" && mark_done "fetch_images_done"
else
  echo "  Skipped."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Done — ${SITE_HOST} (Steps 0–26)"
echo "════════════════════════════════════════════════════════════════════════════"
