#!/usr/bin/env zsh
set -euo pipefail

# ── Fetch GYG Tour Images ───────────────────────────────────────────────────
# Downloads tour photos from the GetYourGuide API, converts to avif,
# and writes a manifest.json mapping tours to local image files.
#
# Usage:
#   ./scripts/fetch-gyg-images.sh <site-slug> "<attraction-name>" [--alias "Name"] [--force]
#
# Requires:
#   GYG_API_KEY in .env or environment
#   python3 with requests + Pillow

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env
ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

if [[ -z "${GYG_API_KEY:-}" ]]; then
  echo "Error: GYG_API_KEY not set. Add it to .env or export it."
  exit 1
fi

export GYG_API_KEY
exec python3 "$SCRIPT_DIR/fetch-gyg-images.py" "$@"
