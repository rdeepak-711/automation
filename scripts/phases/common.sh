#!/usr/bin/env zsh
# common.sh — Shared helpers for all phase scripts.
# Source this file from a phase script after setting REPO_ROOT:
#   REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
#   source "$REPO_ROOT/scripts/phases/common.sh"

# ── Env loading ───────────────────────────────────────────────────────────────
load_env() {
  local site_slug="$1"
  local root_env="$REPO_ROOT/.env"
  local site_env="$REPO_ROOT/input/$site_slug/.env"
  [[ -f "$root_env" ]] && { set -a; source "$root_env"; set +a; }
  if [[ -f "$site_env" ]]; then
    set -a; source "$site_env"; set +a
    echo "  ✓ Loaded per-site config: input/$site_slug/.env"
  else
    echo ""
    echo "  No per-site .env found. Enter site-specific details:"
    mkdir -p "$REPO_ROOT/input/$site_slug"
    printf "  Site URL (e.g. https://hagiasophia-guide.com): "
    read -r _SITE_URL
    printf "  Campaign prefix (e.g. hagia-sophia, auschwitz, msm): "
    read -r _CAMPAIGN_PREFIX
    printf "  GA4 Measurement ID (e.g. G-XXXXXXXXXX): "
    read -r _GA4_ID
    printf "  Favicon URL (full URL to uploaded PNG): "
    read -r _FAVICON_URL
    cat > "$site_env" << SITEENV
WP_SITE_URL=${_SITE_URL}
CAMPAIGN_PREFIX=${_CAMPAIGN_PREFIX}
GA4_MEASUREMENT_ID=${_GA4_ID}
FAVICON_URL=${_FAVICON_URL}
logo_path=input/${site_slug}/images/logo.png
favicon_path=input/${site_slug}/images/favicon.png
SITEENV
    set -a; source "$site_env"; set +a
    echo "  ✓ Saved and loaded: input/$site_slug/.env"
  fi
}

# ── State tracking ────────────────────────────────────────────────────────────
# STATE_FILE must be exported before these are called.
step_done() { [[ -f "$STATE_FILE" ]] && grep -qF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { echo "$1" >> "$STATE_FILE"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
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
preflight_check() {
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

# ── SSH ControlMaster ─────────────────────────────────────────────────────────
# After calling ssh_connect, SSH_KEY_OPT and SSH_CONTROL_PATH are exported.
ssh_connect() {
  export SSH_CONTROL_PATH="/tmp/wp-ssh-main-$$"
  ssh -i "$WP_SSH_KEY" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600 \
    -N -f "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null \
    && echo "  ✓ SSH multiplexed connection established" \
    || echo "  ⚠ SSH multiplexing failed — scripts will fall back to individual connections"
  export SSH_KEY_OPT="-i ${WP_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=${SSH_CONTROL_PATH}"
  trap '[[ -n "${SSH_CONTROL_PATH:-}" ]] && ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null; true' EXIT
}
