#!/usr/bin/env zsh
# audit.sh — Phase 4: Audit wrapper
# Sources common.sh for env loading, then delegates to scripts/audit/audit.sh
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
export CONTENT_SITE_SLUG

exec "$REPO_ROOT/scripts/audit/audit.sh" "$@"
