#!/usr/bin/env zsh
set -euo pipefail

# ── post-publish.sh ───────────────────────────────────────────────────────────
# Post-publish audit: (A) presence check + (B) typography fonts + (C) additional CSS + (D) card image sync
#
# Usage:
#   ./scripts/audit/post-publish.sh <site-slug>
#   ./scripts/audit/post-publish.sh <site-slug> --only presence
#   ./scripts/audit/post-publish.sh <site-slug> --only fonts
#   ./scripts/audit/post-publish.sh <site-slug> --only css
#   ./scripts/audit/post-publish.sh <site-slug> --only images
#   ./scripts/audit/post-publish.sh <site-slug> --dry-run

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--only presence|images] [--dry-run]"
  exit 1
fi

SITE_SLUG="$1"; shift
ONLY=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)    ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── Env loading ───────────────────────────────────────────────────────────────
# Preserve any SSH vars already exported by a parent process (e.g. main.sh)
_PRE_SSH_HOST="${WP_SSH_HOST:-}"
_PRE_SSH_USER="${WP_SSH_USER:-}"
_PRE_SSH_KEY="${WP_SSH_KEY:-}"

[[ -f "$REPO_ROOT/.env" ]] && { set -a; source "$REPO_ROOT/.env"; set +a; }
[[ -f "$REPO_ROOT/input/$SITE_SLUG/.env" ]] && { set -a; source "$REPO_ROOT/input/$SITE_SLUG/.env"; set +a; }

# WP_SERVER=2 overrides to server-2 credentials
if [[ "${WP_SERVER:-}" == "2" ]]; then
  export WP_SSH_HOST="${WP_SSH_HOST2:-$WP_SSH_HOST}"
  export WP_SSH_USER="${WP_SSH_USER2:-$WP_SSH_USER}"
  export WP_SSH_KEY="${WP_SSH_KEY2:-$WP_SSH_KEY}"
elif [[ -n "$_PRE_SSH_HOST" ]]; then
  export WP_SSH_HOST="$_PRE_SSH_HOST"
  export WP_SSH_USER="$_PRE_SSH_USER"
  export WP_SSH_KEY="$_PRE_SSH_KEY"
fi

[[ -n "${WP_SSH_HOST:-}" ]] || { echo "ERROR: WP_SSH_HOST not set"; exit 1; }
[[ -n "${WP_SSH_USER:-}" ]] || { echo "ERROR: WP_SSH_USER not set"; exit 1; }
[[ -n "${WP_PATH:-}"    ]] || { echo "ERROR: WP_PATH not set"; exit 1; }

# ── SSH ControlMaster ─────────────────────────────────────────────────────────
SSH_CTL="/tmp/post-publish-ctl-$$"
_WP_KEY="${WP_SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-i "$_WP_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
           -o ConnectTimeout=15 -o ControlMaster=auto
           -o ControlPath="$SSH_CTL" -o ControlPersist=120)
ssh "${SSH_OPTS[@]}" -N -f "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null && true || true
trap 'ssh -O exit -o ControlPath="$SSH_CTL" "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null || true' EXIT

# Hard connectivity check — bail out before doing anything if SSH is down
if ! ssh "${SSH_OPTS[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "echo ok" </dev/null 2>/dev/null | grep -q "ok"; then
  echo "  ✗ Cannot connect to ${WP_SSH_HOST} via SSH"
  echo "    Check: server is up, port 22 is open, key is correct"
  exit 1
fi
echo "  ✓ SSH connected to ${WP_SSH_HOST}"

_ssh() { ssh "${SSH_OPTS[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "$1" </dev/null 2>/dev/null || true; }

echo ""
echo "════════════════════════════════════════════════════════"
printf "  Post-publish audit — %s\n" "$SITE_SLUG"
[[ "$DRY_RUN" == true ]] && echo "  [DRY RUN — no writes]"
echo "════════════════════════════════════════════════════════"

# ── Sub-task A: Presence check + remediate ────────────────────────────────────
run_presence_check() {
  echo ""
  echo "  ── Sub-task A: Presence check ──"

  local _need_gp=false

  # GP Elements: Menu + Footer
  local _menu_id _footer_id
  _menu_id=$(_ssh "wp post list --post_type=gp_elements --name=Menu --fields=ID --format=csv --path='${WP_PATH}' 2>/dev/null | tail -1")
  _footer_id=$(_ssh "wp post list --post_type=gp_elements --name=Footer --fields=ID --format=csv --path='${WP_PATH}' 2>/dev/null | tail -1")

  if [[ "$_menu_id" =~ ^[0-9]+$ ]]; then
    echo "  ✓ GP Element \"Menu\" present (id=$_menu_id)"
  else
    echo "  ✗ GP Element \"Menu\" missing"; _need_gp=true
  fi

  if [[ "$_footer_id" =~ ^[0-9]+$ ]]; then
    echo "  ✓ GP Element \"Footer\" present (id=$_footer_id)"
  else
    echo "  ✗ GP Element \"Footer\" missing"; _need_gp=true
  fi

  if [[ "$_need_gp" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "  [dry-run] configure-gp-menu-footer.py --site-slug $SITE_SLUG --wp-path ${WP_PATH}"
    else
      echo "  → Running configure-gp-menu-footer.py..."
      python3 "$REPO_ROOT/scripts/wordpress/configure-gp-menu-footer.py" \
        --site-slug "$SITE_SLUG" --wp-path "${WP_PATH}"
      echo "  ✓ GP Elements created"
    fi
  fi

  # about-us
  local _about_id
  _about_id=$(_ssh "wp post list --post_type=page --name=about-us --fields=ID --format=csv --path='${WP_PATH}' 2>/dev/null | tail -1")
  if [[ "$_about_id" =~ ^[0-9]+$ ]]; then
    echo "  ✓ Page \"about-us\" present (id=$_about_id)"
  else
    echo "  ✗ Page \"about-us\" missing"
    if [[ "$DRY_RUN" == true ]]; then
      echo "  [dry-run] publish-to-wordpress.sh $SITE_SLUG --only about-us"
    else
      echo "  → Publishing about-us from template..."
      "$REPO_ROOT/scripts/content/publish-to-wordpress.sh" "$SITE_SLUG" --only about-us --status publish
      echo "  ✓ Page \"about-us\" created"
    fi
  fi

  # contact-us
  local _contact_id
  _contact_id=$(_ssh "wp post list --post_type=page --name=contact-us --fields=ID --format=csv --path='${WP_PATH}' 2>/dev/null | tail -1")
  if [[ "$_contact_id" =~ ^[0-9]+$ ]]; then
    echo "  ✓ Page \"contact-us\" present (id=$_contact_id)"
  else
    echo "  ✗ Page \"contact-us\" missing"
    if [[ "$DRY_RUN" == true ]]; then
      echo "  [dry-run] publish-to-wordpress.sh $SITE_SLUG --only contact-us"
    else
      echo "  → Publishing contact-us from template..."
      "$REPO_ROOT/scripts/content/publish-to-wordpress.sh" "$SITE_SLUG" --only contact-us --status publish
      echo "  ✓ Page \"contact-us\" created"
    fi
  fi
}

# ── Sub-task B: Typography fonts ─────────────────────────────────────────────
run_typography() {
  echo ""
  echo "  ── Sub-task B: Typography fonts ──"
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] configure-typography.sh (Source Sans 3 + Playfair Display)"
    return
  fi
  # Load Source Sans 3 as body font
  WP_SSH_HOST="${WP_SSH_HOST}" \
  WP_SSH_USER="${WP_SSH_USER}" \
  WP_SSH_KEY="${_WP_KEY}" \
  CONTENT_SITE_SLUG="${SITE_SLUG}" \
  FONT_NAME="Source Sans 3" \
    zsh "$REPO_ROOT/scripts/wordpress/configure-typography.sh" 2>&1 | grep -E 'Done|Error|Font:|font_body|WARNING' || true

  # Load Playfair Display for headings
  WP_SSH_HOST="${WP_SSH_HOST}" \
  WP_SSH_USER="${WP_SSH_USER}" \
  WP_SSH_KEY="${_WP_KEY}" \
  CONTENT_SITE_SLUG="${SITE_SLUG}" \
  FONT_NAME="Playfair Display" \
    zsh "$REPO_ROOT/scripts/wordpress/configure-typography.sh" 2>&1 | grep -E 'Done|Error|Font:|WARNING' || true

  # Restore font_body to Source Sans 3 (second run overwrites it)
  local _fix
  _fix=$(ssh -i "${_WP_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "${WP_SSH_USER}@${WP_SSH_HOST}" \
    "wp eval '\$gs=(array)get_option(\"generate_settings\",[]);\$gs[\"font_body\"]=\"Source Sans 3\";update_option(\"generate_settings\",\$gs);echo \"ok\";' \
      --path='${WP_PATH}' 2>/dev/null") || true
  [[ "$_fix" == "ok" ]] && echo "  ✓ Fonts loaded: Source Sans 3 (body) + Playfair Display (headings)" \
                         || echo "  ✗ font_body restore failed"
}

# ── Sub-task C: Additional CSS ───────────────────────────────────────────────
run_additional_css() {
  echo ""
  echo "  ── Sub-task C: Additional CSS ──"
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] configure-additional-css.sh ${WP_PATH}"
    return
  fi
  WP_SSH_HOST="${WP_SSH_HOST}" \
  WP_SSH_USER="${WP_SSH_USER}" \
  WP_SSH_KEY="${_WP_KEY}" \
    bash "$REPO_ROOT/scripts/wordpress/configure-additional-css.sh" "${WP_PATH}"
}

# ── Sub-task D: Card image sync ───────────────────────────────────────────────
run_image_sync() {
  echo ""
  echo "  ── Sub-task D: Card image sync ──"
  local _dry_flag=""
  [[ "$DRY_RUN" == true ]] && _dry_flag="--dry-run"
  python3 "$REPO_ROOT/scripts/audit/post-publish-images.py" \
    --site-slug "$SITE_SLUG" \
    --wp-path "${WP_PATH}" \
    --wp-ssh-host "${WP_SSH_HOST}" \
    --wp-ssh-user "${WP_SSH_USER}" \
    --wp-ssh-key "$_WP_KEY" \
    --ssh-ctl "$SSH_CTL" \
    ${_dry_flag:+"$_dry_flag"}
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${ONLY:-all}" in
  presence) run_presence_check ;;
  fonts)    run_typography ;;
  css)      run_additional_css ;;
  images)   run_image_sync ;;
  both)     run_presence_check; run_typography; run_additional_css; run_image_sync ;;
  all)      run_presence_check; run_typography; run_additional_css; run_image_sync ;;
  *) echo "Unknown --only value: $ONLY (expected presence|fonts|css|images)"; exit 1 ;;
esac

echo ""
echo "════════════════════════════════════════════════════════"
printf "  Post-publish audit complete — %s\n" "$SITE_SLUG"
echo "════════════════════════════════════════════════════════"
