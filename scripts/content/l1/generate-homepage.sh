#!/usr/bin/env zsh
set -euo pipefail

# ── L0: Homepage Generator ────────────────────────────────────────────────────
# Thin wrapper — delegates to scripts/content/l1/assembler/homepage.py
#
# Usage:
#   ./scripts/content/generate-homepage.sh <site-slug> [--force]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--force]"
  echo "Example: $0 amsterdam-canal-cruise"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$REPO_ROOT" && python3 -m scripts.content.l1.assembler.homepage "$@"
