#!/usr/bin/env zsh
# main.sh — Auto Create Site orchestrator
# Prompts for site slug, loads env, shows phase menu (or accepts $1 argument).
#
# Usage:
#   ./main.sh                  # interactive menu
#   ./main.sh wordpress        # jump to wordpress phase (Steps 0–15)
#   ./main.sh content          # jump to content phase (Steps 16–23)
#   ./main.sh publish          # jump to publish phase (Steps 24–26)
#   ./main.sh audit            # audit any live site
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Site slug ─────────────────────────────────────────────────────────────────
PHASE="${1:-}"

if [[ -z "${CONTENT_SITE_SLUG:-}" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi
export CONTENT_SITE_SLUG

# ── Load envs (for banner only — phase scripts reload them) ───────────────────
ROOT_ENV="$SCRIPT_DIR/.env"
SITE_ENV="$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/.env"
[[ -f "$ROOT_ENV" ]] && { set -a; source "$ROOT_ENV"; set +a; }
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

SITE_HOST="${WP_SITE_URL:-$CONTENT_SITE_SLUG}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Auto Create Site — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Phase selection ───────────────────────────────────────────────────────────
if [[ -z "$PHASE" ]]; then
  echo ""
  echo "  Select a phase:"
  echo "    [1] wordpress  — Steps 0–15: WP install + config"
  echo "    [2] content    — Steps 16–23: tickets, MD→HTML, L1, homepage"
  echo "    [3] publish    — Steps 24–28: REST publish + images + cache + menu + audit"
  echo "    [4] audit      — Audit any live site"
  echo ""
  printf "  Enter 1–4 (or phase name): "
  read -r _INPUT
  case "$_INPUT" in
    1|wordpress) PHASE="wordpress" ;;
    2|content)   PHASE="content"   ;;
    3|publish)   PHASE="publish"   ;;
    4|audit)     PHASE="audit"     ;;
    *) echo "  Unknown phase: $_INPUT"; exit 1 ;;
  esac
fi

# ── Phase chain ───────────────────────────────────────────────────────────────
_NEXT_PHASE() {
  case "$1" in
    wordpress) echo "content"  ;;
    content)   echo "publish"  ;;
    *)         echo ""         ;;
  esac
}

# ── Dispatch (loop through phases) ────────────────────────────────────────────
while [[ -n "$PHASE" ]]; do
  PHASE_SCRIPT="$SCRIPT_DIR/scripts/phases/${PHASE}.sh"
  if [[ ! -f "$PHASE_SCRIPT" ]]; then
    echo "  ERROR: Phase script not found: $PHASE_SCRIPT"
    exit 1
  fi

  "$PHASE_SCRIPT" "${@:2}"

  NEXT=$(_NEXT_PHASE "$PHASE")
  if [[ -z "$NEXT" ]]; then
    break
  fi

  echo ""
  printf "  Continue to %s phase? (Y/n): " "$NEXT"
  read -r _CONT
  case "${_CONT:-y}" in
    y|Y|"") PHASE="$NEXT" ;;
    *)      break ;;
  esac
done
