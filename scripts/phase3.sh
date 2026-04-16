#!/usr/bin/env zsh
set -euo pipefail
# ── Phase 3: WordPress Publishing ─────────────────────────────────────────────
# Publishes all generated HTML to WordPress.
#
# Usage: ./scripts/phase3.sh <site-slug>
#
# Steps:
#   1. Pre-flight: verify url-registry.json exists
#   2. Re-run link validation (gate)
#   3. Configure WordPress (permalinks, categories via SSH)
#   4. Publish all pages and articles
#   5. Post-publish verification
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug>"
  exit 1
fi

SITE_SLUG="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "Error: .env not found at $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# Load site-specific .env overrides
SITE_ENV="$REPO_ROOT/input/$SITE_SLUG/.env"
if [[ -f "$SITE_ENV" ]]; then
  set -a; source "$SITE_ENV"; set +a
  echo "  ✓ Loaded per-site config: input/$SITE_SLUG/.env"
fi

# Export SITE_SLUG so child scripts (configure-categories.sh etc.) can read it
export SITE_SLUG
export CONTENT_SITE_SLUG="$SITE_SLUG"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Phase 3 — WordPress Publishing: $SITE_SLUG"
echo "  Site: ${WP_SITE_URL:-<not set>}"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 1: Pre-flight — verify registry exists ───────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 1 — Pre-flight checks"
echo "────────────────────────────────────────────────────────────────────────────"

REGISTRY_FILE="$REPO_ROOT/output/$SITE_SLUG/url-registry.json"
if [[ ! -f "$REGISTRY_FILE" ]]; then
  echo "  ✗ url-registry.json not found: $REGISTRY_FILE"
  echo "  Run phase2.sh first: ./scripts/phase2.sh $SITE_SLUG"
  exit 1
fi
echo "  ✓ url-registry.json found"

# Check registry freshness vs XLSX
XLSX_FILE=$(ls "$REPO_ROOT/input/$SITE_SLUG/"*.xlsx 2>/dev/null | head -1)
if [[ -n "$XLSX_FILE" ]]; then
  if [[ "$XLSX_FILE" -nt "$REGISTRY_FILE" ]]; then
    echo ""
    echo "  ⚠  XLSX is newer than url-registry.json."
    echo "  XLSX:     $XLSX_FILE"
    echo "  Registry: $REGISTRY_FILE"
    echo ""
    printf "  Continue anyway? [y/N] "
    read -r _CONFIRM
    if [[ ! "$_CONFIRM" =~ ^[Yy]$ ]]; then
      echo "  Aborted. Run './scripts/phase2.sh $SITE_SLUG' to rebuild registry."
      exit 1
    fi
  else
    echo "  ✓ Registry is up to date"
  fi
fi

# ── Step 2: Validate internal links (gate) ───────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 2 — Validate internal links"
echo "────────────────────────────────────────────────────────────────────────────"
python3 "$SCRIPT_DIR/content/validate-links.py" "$SITE_SLUG"
if [[ $? -ne 0 ]]; then
  echo ""
  echo "  ✗ Link validation failed. Fix broken links before publishing."
  echo "  Tip: run 'python3 scripts/content/validate-links.py $SITE_SLUG' for full report"
  exit 1
fi
echo "  ✓ All internal links valid"

# ── Step 3: Configure WordPress ───────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 3 — Configure WordPress (permalinks + categories)"
echo "────────────────────────────────────────────────────────────────────────────"

"$SCRIPT_DIR/base/configure-permalinks.sh" \
  || { echo "  ✗ configure-permalinks.sh failed"; exit 1; }
echo "  ✓ Permalinks configured"

"$SCRIPT_DIR/base/configure-categories.sh" \
  || { echo "  ✗ configure-categories.sh failed"; exit 1; }
echo "  ✓ Categories configured"

# ── Step 4: Publish all pages and articles ────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 4 — Publish to WordPress"
echo "────────────────────────────────────────────────────────────────────────────"
"$SCRIPT_DIR/content/publish-to-wordpress.sh" "$SITE_SLUG" \
  || { echo "  ✗ publish-to-wordpress.sh failed"; exit 1; }

# ── Step 5: Clear WordPress cache ────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 5 — Clear WordPress cache"
echo "────────────────────────────────────────────────────────────────────────────"

SSH_CMD="ssh -i ${SSH_KEY_PATH:-~/.ssh/id_rsa_bluehost2} -o StrictHostKeyChecking=no ${BLUEHOST_USER}@${BLUEHOST_HOST}"
WP_PATH="/home1/${BLUEHOST_USER}/public_html/${WP_SITE_DIR:-website_unknown}"

$SSH_CMD python3 << CACHEOF
import subprocess, shutil, os
wp_path = "$WP_PATH"
for cmd in ["cache flush", "transient delete --all", "rewrite flush"]:
    r = subprocess.run(f"wp {cmd} --path={wp_path}", shell=True, capture_output=True, text=True)
    print(f"  wp {cmd}: {r.stdout.strip()}")
for d in [f"{wp_path}/wp-content/cache/wp-rocket", f"{wp_path}/wp-content/cache/min"]:
    if os.path.isdir(d):
        shutil.rmtree(d)
        os.makedirs(d)
        print(f"  Cleared {d.split('cache/')[1]}/")
CACHEOF
echo "  ✓ Cache cleared"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  ✓ Phase 3 complete — Site published: ${WP_SITE_URL:-$SITE_SLUG}"
echo "════════════════════════════════════════════════════════════════════════════"
