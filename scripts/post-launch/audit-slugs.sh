#!/usr/bin/env bash
set -euo pipefail

# Audit (and optionally fix) WordPress post slugs against the site's XLSX.
#
# Usage:
#   ./scripts/post-launch/audit-slugs.sh <hostname> [--fix]
#
# Examples:
#   ./scripts/post-launch/audit-slugs.sh mezquita-catedral-cordoba.com
#   ./scripts/post-launch/audit-slugs.sh mezquita-catedral-cordoba.com --fix
#
# --fix renames mismatched WP slugs to match the XLSX and search-replaces
# all internal URLs across the entire database.
#
# Env vars (from input/<site>/.env or parent shell):
#   WP_SSH_HOST, WP_SSH_USER, WP_SSH_KEY, WP_PATH (optional — auto-discovered)

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname> [--fix]"
    exit 1
fi

HOSTNAME="$1"
FIX_FLAG="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY_SCRIPT="$SCRIPT_DIR/audit-slugs.py"

# ── Resolve input dir and XLSX ────────────────────────────────────────────────
# Derive input folder name from hostname: strip TLD + common suffixes
SITE_KEY=$(echo "$HOSTNAME" | sed 's/\.[^.]*$//' | sed 's/-guide$//' | sed 's/\.com$//' | sed 's/\.org$//' | sed 's/\.co$//')

INPUT_DIR=""
# Try progressively looser matches: exact key, hostname contains dirname, dirname contained in hostname
for d in "$ROOT_DIR/input"/*/; do
    dname=$(basename "$d")
    [[ "$dname" == "$SITE_KEY" ]]       && { INPUT_DIR="$d"; break; }
    [[ "$HOSTNAME" == *"$dname"* ]]     && { INPUT_DIR="$d"; break; }
    [[ "$dname" == *"$SITE_KEY"* ]]     && { INPUT_DIR="$d"; break; }
    # Also match if all words in dirname appear in hostname (e.g. mezquita-cordoba ⊂ mezquita-catedral-cordoba)
    _match=1
    IFS='-' read -ra _words <<< "$dname"
    for _w in "${_words[@]}"; do
        [[ "$HOSTNAME" == *"$_w"* ]] || { _match=0; break; }
    done
    [[ "$_match" == 1 ]] && { INPUT_DIR="$d"; break; }
done

if [[ -z "$INPUT_DIR" ]]; then
    echo "❌ Could not find input directory for $HOSTNAME (looked for key: $SITE_KEY)"
    echo "   Available: $(ls "$ROOT_DIR/input/")"
    exit 1
fi

XLSX_PATH=$(find "$INPUT_DIR" -maxdepth 1 -name "*.xlsx" | head -1)
if [[ -z "$XLSX_PATH" ]]; then
    echo "❌ No XLSX file found in $INPUT_DIR"
    exit 1
fi

echo "📄 XLSX: $XLSX_PATH"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$INPUT_DIR/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# Map WP_SERVER env var to SSH credentials
if [[ -z "${WP_SSH_USER:-}" ]]; then
    case "${WP_SERVER:-}" in
        1) WP_SSH_USER="kzrmeomy"; WP_SSH_HOST="50.6.109.30";  WP_SSH_KEY="~/.ssh/id_rsa_bluehost_old" ;;
        2) WP_SSH_USER="dpskbcmy"; WP_SSH_HOST="50.6.155.174"; WP_SSH_KEY="~/.ssh/id_rsa_bluehost2"    ;;
        *) echo "❌ WP_SERVER not set in .env (expected 1 or 2)"; exit 1 ;;
    esac
fi

# WP_PATH may come from .env directly
WP_PATH="${WP_PATH:-}"

# ── SSH setup ─────────────────────────────────────────────────────────────────
SSH_KEY_OPTS=()
if [[ -n "${WP_SSH_KEY:-}" ]]; then
    _KEY="${WP_SSH_KEY/#\~/$HOME}"
    SSH_KEY_OPTS=(-i "$_KEY" -o IdentitiesOnly=yes)
fi
SSH_KEY_OPTS+=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)

_SSH() { SSH_AUTH_SOCK="" ssh "${SSH_KEY_OPTS[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "$@"; }
_SCP() { SSH_AUTH_SOCK="" scp "${SSH_KEY_OPTS[@]}" "$@"; }

# ── Discover WP_PATH if not set ───────────────────────────────────────────────
if [[ -z "$WP_PATH" ]]; then
    echo "Discovering WP path for $HOSTNAME..."
    WP_PATH=$(_SSH \
        "for d in /home*/${WP_SSH_USER}/public_html/website_*/; do \
             wp option get siteurl --path=\"\$d\" 2>/dev/null | grep -q '$HOSTNAME' && echo \"\$d\" && break; \
         done" 2>/dev/null | tr -d '\n' | sed 's|/$||')
fi

if [[ -z "$WP_PATH" ]]; then
    echo "❌ Could not find WordPress installation for $HOSTNAME"
    exit 1
fi

echo "📍 WP path: $WP_PATH"
echo ""

# ── Upload and run ────────────────────────────────────────────────────────────
_SCP "$PY_SCRIPT"  "${WP_SSH_USER}@${WP_SSH_HOST}:/tmp/audit-slugs.py"
_SCP "$XLSX_PATH"  "${WP_SSH_USER}@${WP_SSH_HOST}:/tmp/audit-slugs.xlsx"

_SSH "python3 /tmp/audit-slugs.py '$WP_PATH' /tmp/audit-slugs.xlsx ${FIX_FLAG}; \
      rm -f /tmp/audit-slugs.py /tmp/audit-slugs.xlsx"

echo ""
echo "✅ Done for $HOSTNAME"
