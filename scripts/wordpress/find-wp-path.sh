#!/usr/bin/env zsh
set -euo pipefail
# Finds all WordPress installs on the server, prints their siteurl + path,
# and optionally writes WP_PATH to .env for the matched site.
# Tries Server 2 (new) first; falls back to Server 1 (old) if WP_PATH not found.
# Usage: ./scripts/find-wp-path.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

if [[ -z "${WP_SSH_HOST:-}" || -z "${WP_SSH_USER:-}" ]]; then
  echo "Error: WP_SSH_HOST and WP_SSH_USER must be set in .env"
  exit 1
fi

# ── Try a server: scan all WP installs, return output ────────────────────────
scan_server() {
  local host="$1" user="$2" key="$3"
  local ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)
  local search_root="/home1/${user}/public_html"
  ssh "${ssh_opts[@]}" "${user}@${host}" "
    # Check root public_html first (primary domain)
    url=\$(wp option get siteurl --path=\"${search_root}\" 2>/dev/null) && \
      printf '%-55s %s\n' \"\$url\" \"${search_root}/\"
    # Check website_* subdirs (addon domains)
    for d in ${search_root}/website_*/; do
      url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || continue
      printf '%-55s %s\n' \"\$url\" \"\$d\"
    done
  " 2>/dev/null || true
}

# ── Find WP_PATH on a given server ───────────────────────────────────────────
find_path_on_server() {
  local host="$1" user="$2" key="$3" site_host="$4"
  local ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)
  local search_root="/home1/${user}/public_html"
  ssh "${ssh_opts[@]}" "${user}@${host}" "
    # Check root public_html first (primary domain)
    url=\$(wp option get siteurl --path=\"${search_root}\" 2>/dev/null) || true
    if [[ \"\$url\" == *\"${site_host}\"* ]]; then
      echo \"${search_root}/\"
      exit 0
    fi
    # Check website_* subdirs (addon domains)
    for d in ${search_root}/website_*/; do
      url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || continue
      if [[ \"\$url\" == *\"${site_host}\"* ]]; then
        echo \"\$d\"
        break
      fi
    done
  " 2>/dev/null || true
}

# ── Resolve active server: try Server 2 first, fall back to Server 1 ─────────
resolve_active_server() {
  local site_host="$1"

  # Server 2 (new)
  if [[ -n "${WP_SSH_HOST2:-}" && -n "${WP_SSH_USER2:-}" ]]; then
    local key2="${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}"
    echo "  Trying new server (${WP_SSH_HOST2})..."
    local found
    found=$(find_path_on_server "$WP_SSH_HOST2" "$WP_SSH_USER2" "$key2" "$site_host")
    found="${found%/}"
    if [[ -n "$found" ]]; then
      echo "  ✓ Found on new server: $found"
      export WP_SSH_HOST="$WP_SSH_HOST2"
      export WP_SSH_USER="$WP_SSH_USER2"
      export WP_SSH_KEY="$key2"
      export WP_PATH="$found"
      export _ACTIVE_SERVER=2
      return
    fi
    echo "  Not found on new server — trying old server (${WP_SSH_HOST})..."
  fi

  # Server 1 (old fallback)
  local key1="${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
  local found
  found=$(find_path_on_server "$WP_SSH_HOST" "$WP_SSH_USER" "$key1" "$site_host")
  found="${found%/}"
  if [[ -n "$found" ]]; then
    echo "  ✓ Found on old server: $found"
    export WP_SSH_KEY="${key1}"
    export WP_PATH="$found"
    export _ACTIVE_SERVER=1
  else
    echo "  WARNING: WP_PATH not found on either server."
    export _ACTIVE_SERVER=0
  fi
}

# ── Print all installs from the active/resolved server ───────────────────────
SITE_HOST=""
if [[ -n "${WP_SITE_URL:-}" ]]; then
  SITE_HOST="${WP_SITE_URL#https://}"
  SITE_HOST="${SITE_HOST#http://}"
  SITE_HOST="${SITE_HOST%%/*}"
fi

echo ""
if [[ -n "$SITE_HOST" ]]; then
  echo "Resolving active server for ${WP_SITE_URL}..."
  resolve_active_server "$SITE_HOST"
  echo ""
fi

ACTIVE_HOST="${WP_SSH_HOST}"
ACTIVE_USER="${WP_SSH_USER}"
ACTIVE_KEY="${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"

echo "Scanning WordPress installs on ${ACTIVE_HOST} (user: ${ACTIVE_USER})..."
echo ""
SCAN_OUTPUT=$(scan_server "$ACTIVE_HOST" "$ACTIVE_USER" "$ACTIVE_KEY")
echo "$SCAN_OUTPUT"

# ── Write WP_PATH to site-specific .env ──────────────────────────────────────
if [[ -n "$SITE_HOST" && -n "${WP_PATH:-}" ]]; then
  echo ""
  echo "Matched path for ${WP_SITE_URL}: ${WP_PATH}"
  _SLUG="${CONTENT_SITE_SLUG:-${SITE_SLUG:-}}"
  _SITE_ENV="$SCRIPT_DIR/input/$_SLUG/.env"
  if [[ -n "$_SLUG" && -f "$_SITE_ENV" ]]; then
    if grep -q "^WP_PATH=" "$_SITE_ENV" 2>/dev/null; then
      sed -i '' "s|^WP_PATH=.*|WP_PATH=${WP_PATH}|" "$_SITE_ENV"
    else
      echo "WP_PATH=${WP_PATH}" >> "$_SITE_ENV"
    fi
    echo "  WP_PATH written to input/$_SLUG/.env"
  fi
fi
