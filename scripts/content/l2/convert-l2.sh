#!/usr/bin/env bash
# convert-l2.sh — thin shell wrapper for the L2 article batch converter
#
# Usage:
#   ./scripts/l2/convert-l2.sh <site-slug> [--force] [--workers N] [--silo <silo>]
#
# Examples:
#   ./scripts/l2/convert-l2.sh hagia-sofia
#   ./scripts/l2/convert-l2.sh auschwitz --force
#   ./scripts/l2/convert-l2.sh plitvice-lakes --silo tickets-tours --workers 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--force] [--workers N] [--silo <silo>]" >&2
  exit 1
fi

cd "$REPO_ROOT"
exec python3 -m scripts.l2.batch "$@"
