#!/usr/bin/env bash
set -euo pipefail

SITE="${1:?Usage: generate-l1-tickets-tours.sh <site-slug> [--force]}"
shift || true

cd "$(dirname "$0")/../../.."

python3 -m scripts.content.l1.assembler.tickets_tours "$SITE" "$@"
