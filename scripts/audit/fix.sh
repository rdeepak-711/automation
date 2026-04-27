#!/usr/bin/env bash
# fix.sh — 6-batch remediation for any Server 2 WordPress site
#
# Usage:
#   ./fix.sh <hostname> --batch <1-6|name> [--dry-run]
#   ./fix.sh <hostname> --all [--dry-run]   # runs all 6 in order with confirm prompts
#
# Batches:
#   1  / options          — WP options (nav_position_setting, content_top)
#   1b / menu-css         — inject .site-header hide rule into Menu GP element
#   1c / container-width  — fix homepage att-container 74% max-width → 100%
#   2  / absolute-urls    — strip absolute internal URLs from post content
#   3 / broken-crosslinks — rewrite broken slug hrefs using rewrite map
#   4 / padding          — strip "padding: 24px 0 0 0" from post content
#   5 / manifest         — generate slug rename + redirect plan (preview only)
#   6 / images           — upload + assign featured images (if files exist locally)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

DRY_RUN=0
BATCH=""
HOSTNAME=""

# ── arg parsing ────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <hostname> --batch <1-6|name> [--dry-run]" >&2
  echo "       $0 <hostname> --all [--dry-run]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)    BATCH="$2"; shift 2 ;;
    --all)      BATCH="all"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -*)         echo "Unknown flag: $1" >&2; usage ;;
    *)          HOSTNAME="$1"; shift ;;
  esac
done

[[ -z "$HOSTNAME" || -z "$BATCH" ]] && usage

WP_PATH="$(resolve_wp_path "$HOSTNAME")"
if [[ -z "$WP_PATH" ]]; then
  echo "ERROR: unknown hostname '$HOSTNAME'" >&2
  exit 1
fi

# ── resolve latest merged violations + snapshot ────────────────────────────────
VIOL_DIR="$OUTPUT_DIR/violations"
SNAP_DIR="$OUTPUT_DIR/snapshots"

find_latest_merged() {
  local host="$1"
  ls -t "$VIOL_DIR/${host}-"*.merged.json 2>/dev/null | head -1
}

MERGED_FILE="$(find_latest_merged "$HOSTNAME")"
if [[ -z "$MERGED_FILE" ]]; then
  echo "ERROR: no merged violations file for $HOSTNAME in $VIOL_DIR" >&2
  echo "  Run: scripts/audit/audit.sh $HOSTNAME" >&2
  exit 1
fi

SNAP_FILE="$SNAP_DIR/${HOSTNAME}-latest.json"
if [[ ! -f "$SNAP_FILE" ]]; then
  echo "ERROR: snapshot not found at $SNAP_FILE" >&2
  exit 1
fi

echo "" >&2
echo "Host:       $HOSTNAME" >&2
echo "WP path:    $WP_PATH" >&2
echo "Violations: $MERGED_FILE" >&2
echo "Snapshot:   $SNAP_FILE" >&2
echo "Dry run:    $DRY_RUN" >&2
echo "" >&2

# ── helpers ────────────────────────────────────────────────────────────────────
dry_or_run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would run: $*" >&2
  else
    "$@"
  fi
}

confirm_proceed() {
  local msg="$1"
  echo "" >&2
  echo "=== $msg ===" >&2
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

php_eval() {
  local php_file="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would eval PHP: $php_file" >&2
    echo "--- PHP content ---" >&2
    cat "$php_file" >&2
    echo "---" >&2
  else
    ssh_upload "$php_file" "/tmp/fix_batch.php"
    wp_run "$WP_PATH" eval-file /tmp/fix_batch.php
  fi
}

# ── BATCH 1: WP options ────────────────────────────────────────────────────────
batch_1_options() {
  echo "Batch 1: WP options — nav_position_setting=nav-none, content_top=0" >&2

  local count
  count="$(python3 -c "
import json
p = json.load(open('$MERGED_FILE'))
n = sum(1 for v in p['violations'] if v['id'].startswith('option-value-'))
print(n)
")"
  echo "  Option violations in last audit: $count" >&2

  local php_file
  php_file="$(mktemp /tmp/fix_batch1_XXXXX.php)"
  cat > "$php_file" << 'PHPEOF'
<?php
$s = get_option('generate_settings', []);
$s['nav_position_setting'] = 'nav-none';
update_option('generate_settings', $s);
echo "nav_position_setting = nav-none\n";

$s = get_option('generate_spacing_settings', []);
$s['content_top'] = 0;
update_option('generate_spacing_settings', $s);
echo "content_top = 0\n";
PHPEOF

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would eval-file:" >&2
    cat "$php_file" >&2
    rm -f "$php_file"
    return
  fi

  php_eval "$php_file"
  rm -f "$php_file"
  echo "  ✓ nav_position_setting = nav-none" >&2
  echo "  ✓ content_top = 0" >&2

  echo "" >&2
  echo "Batch 1 done. Re-run audit to verify -2 option violations." >&2
}

# ── BATCH 1b: menu CSS — hide native GP header ────────────────────────────────
batch_1b_menu_css() {
  echo "Batch 1b: Menu GP element — inject .site-header { display: none !important }" >&2

  local NEEDLE='body { padding-top: var(--nav-padding-top, 72px); }'
  local INSERT='    .site-header, #site-navigation, #sticky-navigation, #mobile-header { display: none !important; opacity: 0; }'

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would insert .site-header hide rule into Menu GP element CSS" >&2
    return
  fi

  ssh_run "wp eval '
foreach(get_posts([\"post_type\"=>\"gp_elements\",\"numberposts\"=>-1]) as \$e){
  if(\$e->post_title!==\"Menu\") continue;
  \$c = get_post_meta(\$e->ID,\"_generate_element_content\",true);
  if(stripos(\$c,\".site-header\")!==false){ echo \"SKIP: rule already present\\n\"; break; }
  if(strpos(\$c,\"body { padding-top: var(--nav-padding-top, 72px); }\")===false){
    echo \"ERROR: anchor not found in Menu CSS\\n\"; break;
  }
  \$new = str_replace(
    \"body { padding-top: var(--nav-padding-top, 72px); }\",
    \".site-header, #site-navigation, #sticky-navigation, #mobile-header { display: none !important; opacity: 0; }\\n    body { padding-top: var(--nav-padding-top, 72px); }\",
    \$c
  );
  update_post_meta(\$e->ID,\"_generate_element_content\",\$new);
  echo \"OK: inserted site-header hide rule (post ID \".\$e->ID.\")\\n\";
  break;
}
' --path=$WP_PATH --skip-themes --skip-plugins 2>/dev/null"

  echo "  ✓ .site-header hide rule injected" >&2
  echo "" >&2
  echo "Batch 1b done. Hard-refresh site to verify GP header gap gone." >&2
}

# ── BATCH 1c: homepage container width ────────────────────────────────────────
batch_1c_container_width() {
  echo "Batch 1c: homepage .att-container — replace 74%/82%/88% max-width with 100%" >&2

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would regex-replace restrictive att-container CSS in homepage post_content" >&2
    return
  fi

  ssh_run "wp eval '
\$post = get_posts([\"post_type\"=>\"page\",\"name\"=>\"homepage\",\"numberposts\"=>1])[0] ?? null;
if(!isset(\$post)){ echo \"ERROR: homepage page not found\n\"; exit; }
\$c = \$post->post_content;
\$pattern = \"/@media\\\\s*\\\\\(min-width:\\\\s*1280px\\\\\)\\\\s*\\\\\{[^}]+7[0-9]%[^}]+\\\\\}.*?@media\\\\s*\\\\\(max-width:\\\\s*767px\\\\\)\\\\s*\\\\\{[^}]+9[0-9]%[^}]+\\\\\}/s\";
\$replacement = \".att-container { max-width: 100% !important; }\n  @media (max-width: 767px)  { .att-container { padding-left: 16px !important; padding-right: 16px !important; } }\n  @media (min-width: 768px) and (max-width: 1023px) { .att-container { padding-left: 24px !important; padding-right: 24px !important; } }\";
if(!preg_match(\$pattern,\$c)){ echo \"SKIP: no restrictive pattern found\n\"; exit; }
\$updated = preg_replace(\$pattern, \$replacement, \$c);
wp_update_post([\"ID\"=>\$post->ID,\"post_content\"=>\$updated]);
echo \"OK: fixed att-container width on homepage (ID \".\$post->ID.\")\n\";
' --path=$WP_PATH --skip-themes --skip-plugins 2>/dev/null"

  # Flush caches
  ssh_run "wp cache flush --path=$WP_PATH --skip-plugins 2>/dev/null" || true
  ssh_run "wp eval 'if(function_exists(\"rocket_clean_domain\")){ rocket_clean_domain(); echo \"Rocket cleared\n\"; }' --path=$WP_PATH 2>/dev/null" || true

  echo "  ✓ Homepage container width fixed + caches cleared" >&2
  echo "" >&2
  echo "Batch 1c done. Hard-refresh site — content should span full width." >&2
}

# ── BATCH 2: absolute URLs ─────────────────────────────────────────────────────
batch_2_absolute_urls() {
  echo "Batch 2: absolute URLs — strip https://$HOSTNAME/ → /" >&2

  local count
  count="$(python3 -c "
import json
p = json.load(open('$MERGED_FILE'))
n = sum(1 for v in p['violations'] if v['id']=='absolute-internal-links')
print(n)
")"
  echo "  Absolute-URL violations in last audit: $count" >&2

  local escaped_host
  escaped_host="$(echo "$HOSTNAME" | sed 's/\./\\\\./g')"

  local php_file
  php_file="$(mktemp /tmp/fix_b2_XXXXXX.php)"

  cat > "$php_file" << PHPEOF
<?php
\$changed = 0;
\$host_re = '~https?://(?:www\\.)?${escaped_host}/~i';
\$posts = get_posts(['post_type'=>'post','numberposts'=>-1,'post_status'=>'publish']);
foreach (\$posts as \$p) {
    \$new = preg_replace(\$host_re, '/', \$p->post_content);
    if (\$new !== \$p->post_content) {
        wp_update_post(['ID'=>\$p->ID,'post_content'=>\$new]);
        \$changed++;
        echo "  updated post: {\$p->post_name}\n";
    }
}
echo "Batch 2 done. Updated \$changed posts.\n";
PHPEOF

  php_eval "$php_file"
  rm -f "$php_file"

  echo "" >&2
  echo "Batch 2 done. Re-audit to verify absolute-internal-links = 0." >&2
}

# ── BATCH 3: broken crosslinks ─────────────────────────────────────────────────
batch_3_broken_crosslinks() {
  echo "Batch 3: broken crosslinks — build slug rewrite map + patch hrefs" >&2

  local map_file
  map_file="$(mktemp /tmp/fix_b3_map_XXXXXX.json)"

  # Build rewrite map: bad_slug → real_slug (pure Python, no SSH)
  python3 - "$MERGED_FILE" "$SNAP_FILE" "$map_file" << 'PYEOF'
import sys, json

merged_path, snap_path, out_path = sys.argv[1:4]
merged = json.load(open(merged_path))
snap   = json.load(open(snap_path))

# collect unique missing slugs
missing = set()
for v in merged['violations']:
    if v['id'] == 'broken-internal-link':
        ms = v.get('missing_slug', '')
        if ms:
            missing.add(ms)

live_slugs = [p['slug'] for p in snap['posts']] + [p['slug'] for p in snap['pages']]

rewrite_map = {}
skipped = []
for bad in sorted(missing):
    # live slug must contain bad as a token (split on '-')
    bad_tokens = set(bad.split('-'))
    matches = [s for s in live_slugs if bad_tokens.issubset(set(s.split('-')))]
    if len(matches) == 1:
        rewrite_map[bad] = matches[0]
    else:
        skipped.append((bad, matches))

print(f"Rewrite map ({len(rewrite_map)} entries):", file=sys.stderr)
for b, g in sorted(rewrite_map.items()):
    print(f"  {b!r:40s} → {g!r}", file=sys.stderr)

if skipped:
    print(f"\nSkipped (ambiguous or no match):", file=sys.stderr)
    for b, ms in skipped:
        print(f"  {b!r} candidates: {ms}", file=sys.stderr)

json.dump(rewrite_map, open(out_path, 'w'), indent=2)
PYEOF

  local n_map
  n_map="$(python3 -c "import json; print(len(json.load(open('$map_file'))))")"
  echo "  Rewrite map entries: $n_map" >&2

  # Embed map JSON directly into PHP (avoids scp dependency for the map)
  local map_json
  map_json="$(cat "$map_file")"
  rm -f "$map_file"

  local php_file
  php_file="$(mktemp /tmp/fix_b3_XXXXXX.php)"

  cat > "$php_file" << PHPEOF
<?php
\$map_json = <<<'MAPJSON'
${map_json}
MAPJSON;
\$map = json_decode(\$map_json, true);

if (!empty(\$map)) {
    \$changed = 0;
    \$posts = get_posts(['post_type'=>['post','page'],'numberposts'=>-1,'post_status'=>'publish']);
    foreach (\$posts as \$p) {
        \$c = \$p->post_content;
        foreach (\$map as \$bad => \$good) {
            \$c = preg_replace(
                '~href="(/[^"#?]*/?)' . preg_quote(\$bad, '~') . '(/|["\#?])~',
                'href="\$1' . \$good . '\$2',
                \$c
            );
        }
        if (\$c !== \$p->post_content) {
            wp_update_post(['ID'=>\$p->ID,'post_content'=>\$c]);
            \$changed++;
            echo "  updated post: {\$p->post_name}\n";
        }
    }
    echo "Crosslinks patched: \$changed posts.\n";
} else {
    echo "No slug rewrite map — crosslink patch skipped.\n";
}

// Clear rank_math_canonical_url from all posts (always runs)
\$canonical_cleared = 0;
\$all_posts = get_posts(['post_type'=>'post','numberposts'=>-1,'post_status'=>'publish']);
foreach (\$all_posts as \$p) {
    \$val = get_post_meta(\$p->ID, 'rank_math_canonical_url', true);
    if (!empty(\$val)) {
        delete_post_meta(\$p->ID, 'rank_math_canonical_url');
        \$canonical_cleared++;
        echo "  cleared canonical: {\$p->post_name}\n";
    }
}
echo "Canonical URLs cleared: \$canonical_cleared posts.\n";
PHPEOF

  php_eval "$php_file"
  rm -f "$php_file"

  echo "" >&2
  echo "Batch 3 done. Re-audit to verify broken-internal-link = 0." >&2
}

# ── BATCH 4: padding strip ─────────────────────────────────────────────────────
batch_4_padding() {
  echo "Batch 4: padding — strip 'padding: 24px 0 0 0' from post content" >&2

  local count
  count="$(python3 -c "
import json
p = json.load(open('$MERGED_FILE'))
n = sum(1 for v in p['violations'] if v['id']=='padding-24')
print(n)
")"
  echo "  Padding-24 violations in last audit: $count" >&2

  local php_file
  php_file="$(mktemp /tmp/fix_b4_XXXXXX.php)"

  cat > "$php_file" << 'PHPEOF'
<?php
$changed = 0;
$posts = get_posts(['post_type'=>'post','numberposts'=>-1,'post_status'=>'publish']);
foreach ($posts as $p) {
    $new = str_replace('padding: 24px 0 0 0', 'padding: 0', $p->post_content);
    if ($new !== $p->post_content) {
        wp_update_post(['ID'=>$p->ID,'post_content'=>$new]);
        $changed++;
        echo "  updated post: {$p->post_name}\n";
    }
}
echo "Batch 4 done. Updated $changed posts.\n";
PHPEOF

  php_eval "$php_file"
  rm -f "$php_file"

  echo "" >&2
  echo "Batch 4 done. Re-audit to verify padding-24 = 0." >&2
}

# ── BATCH 5: manifest reconciliation ──────────────────────────────────────────
batch_5_manifest() {
  echo "Batch 5: manifest — generate slug rename + redirect plan" >&2

  local out_dir="$OUTPUT_DIR/fix"
  mkdir -p "$out_dir"

  local rename_sh="$out_dir/rename-${HOSTNAME}.sh"
  local redirect_txt="$out_dir/htaccess-redirects-${HOSTNAME}.txt"

  python3 - "$MERGED_FILE" "$SNAP_FILE" "$rename_sh" "$redirect_txt" "$HOSTNAME" "$WP_PATH" << 'PYEOF'
import sys, json

merged_path, snap_path, rename_sh, redirect_txt, hostname, wp_path = sys.argv[1:7]
merged = json.load(open(merged_path))
snap   = json.load(open(snap_path))

# unpublished = in xlsx, not live (short slugs)
unpublished = set(v['target']['slug'] for v in merged['violations'] if v['id']=='manifest-unpublished')
# orphan = live, not in xlsx (long slugs)
orphans     = set(v['target']['slug'] for v in merged['violations'] if v['id']=='manifest-orphan')

# Match: orphan live slug → its short xlsx slug by sub-token containment
rename_map = {}  # live_slug → short_slug
for live in sorted(orphans):
    live_tokens = set(live.split('-'))
    matches = [s for s in unpublished if set(s.split('-')).issubset(live_tokens)]
    if len(matches) == 1:
        rename_map[live] = matches[0]
    else:
        print(f"WARN: no unique match for orphan '{live}' (candidates: {matches})", file=sys.stderr)

# build post id map from snapshot
slug_to_id = {p['slug']: p['id'] for p in snap['posts']}
slug_to_id.update({p['slug']: p['id'] for p in snap['pages']})

lines_sh  = ["#!/usr/bin/env bash", "# Generated by fix.sh batch 5 — review before running", "set -euo pipefail", ""]
lines_redir = ["# Redirect rules for .htaccess (add inside <IfModule mod_rewrite.c> block)", ""]

for live_slug, short_slug in sorted(rename_map.items()):
    post_id = slug_to_id.get(live_slug, '???')
    lines_sh.append(f"# {live_slug} → {short_slug}")
    lines_sh.append(f"wp post update {post_id} --post_name='{short_slug}' --path={wp_path}")
    lines_sh.append("")
    # Build category-agnostic redirect (covers any silo prefix)
    lines_redir.append(f"RewriteRule ^(.+)/{live_slug}/?$ /$1/{short_slug}/ [R=301,L]")

with open(rename_sh, 'w') as f:
    f.write('\n'.join(lines_sh) + '\n')
import os; os.chmod(rename_sh, 0o755)

with open(redirect_txt, 'w') as f:
    f.write('\n'.join(lines_redir) + '\n')

print(f"Rename map ({len(rename_map)} entries):", file=sys.stderr)
for live, short in sorted(rename_map.items()):
    print(f"  {live!r:45s} → {short!r}", file=sys.stderr)
PYEOF

  echo "" >&2
  echo "Batch 5 preview outputs:" >&2
  echo "  Rename script : $rename_sh" >&2
  echo "  Redirect rules: $redirect_txt" >&2
  echo "" >&2
  echo "IMPORTANT: Batch 5 does NOT execute automatically." >&2
  echo "  1. Review $rename_sh" >&2
  echo "  2. Run it: bash $rename_sh" >&2
  echo "  3. Add redirect rules from $redirect_txt to your .htaccess" >&2
  echo "  4. Re-audit to verify manifest violations = 0" >&2
}

# ── BATCH 6: featured images ───────────────────────────────────────────────────
batch_6_images() {
  echo "Batch 6: featured images — upload + assign for missing posts/pages" >&2

  local root_dir="$HERE/../.."
  local input_slug
  input_slug="$(python3 -c "
slugs = {
    'topkapipalace-guide.com':      'topkapi-palace',
    'bluemosque-guide.com':         'blue-mosque',
    'hagiasophia-guide.com':        'hagia-sofia',
    'montsaintmichel-guide.com':    'mont-saint-michel',
    'vangoghmuseum-guide.com':      'van-gogh',
    'plitvicelakes-guide.com':      'plitvice-lakes',
    'angkorwat-guide.com':          'angkor-wat',
}
print(slugs.get('$HOSTNAME', ''))
")"

  if [[ -z "$input_slug" ]]; then
    echo "ERROR: no input_slug mapping for $HOSTNAME" >&2
    return 1
  fi

  local images_dir="$root_dir/input/$input_slug/images"

  echo "" >&2
  echo "Checking missing featured images from audit..." >&2

  python3 - "$MERGED_FILE" "$SNAP_FILE" "$images_dir" << PYEOF
import sys, json, os
from pathlib import Path

merged_path, snap_path, images_dir = sys.argv[1:4]
merged = json.load(open(merged_path))
snap   = json.load(open(snap_path))
images_dir = Path(images_dir)

missing = [(v['target']['type'], v['target']['slug'], v['target']['id'])
           for v in merged['violations'] if v['id'] == 'featured-image-missing']

slug_to_id = {p['slug']: p['id'] for p in snap['posts']}
slug_to_id.update({p['slug']: p['id'] for p in snap['pages']})

print(f"\nMissing featured images ({len(missing)} items):\n")
for kind, slug, pid in sorted(missing):
    # Guess candidate image paths
    candidates = list(images_dir.glob(f"{slug}.*")) + \
                 list(images_dir.glob(f"posts/{slug}.*")) + \
                 list(images_dir.glob(f"pages/{slug}.*"))
    found = [str(c) for c in candidates if c.is_file()]
    if found:
        print(f"  [FOUND] {kind} '{slug}' (id {pid})")
        print(f"          → {found[0]}")
    else:
        print(f"  [MISSING] {kind} '{slug}' (id {pid})")
        print(f"          → place image at: {images_dir}/posts/{slug}.jpg  (or pages/)")
PYEOF

  echo "" >&2
  echo "For each [FOUND] item, fix.sh can auto-upload. For [MISSING], supply the image file first." >&2
  echo "" >&2

  # Auto-upload found images
  python3 - "$MERGED_FILE" "$SNAP_FILE" "$images_dir" "$WP_PATH" "$DRY_RUN" << 'PYEOF2'
import sys, json, subprocess, os
from pathlib import Path

merged_path, snap_path, images_dir, wp_path, dry_run = sys.argv[1:6]
merged = json.load(open(merged_path))
snap   = json.load(open(snap_path))
images_dir = Path(images_dir)
is_dry = dry_run == "1"

SSH_KEY = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
SSH_HOST = "dpskbcmy@50.6.155.174"
SSH_OPTS = ["-i", SSH_KEY, "-o", "StrictHostKeyChecking=no", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=15"]

missing = [(v['target']['type'], v['target']['slug'], v['target']['id'])
           for v in merged['violations'] if v['id'] == 'featured-image-missing']

for kind, slug, pid in sorted(missing):
    candidates = list(images_dir.glob(f"{slug}.*")) + \
                 list(images_dir.glob(f"posts/{slug}.*")) + \
                 list(images_dir.glob(f"pages/{slug}.*"))
    found = [c for c in candidates if c.is_file()]
    if not found:
        continue

    img_path = str(found[0])
    remote_tmp = f"/tmp/feat_{slug}{found[0].suffix}"

    print(f"  Uploading {img_path} → {remote_tmp}")
    if is_dry:
        print(f"    [DRY-RUN] scp {img_path} {SSH_HOST}:{remote_tmp}")
        print(f"    [DRY-RUN] wp media import {remote_tmp} --post_id={pid} --featured_image --path={wp_path}")
        continue

    # Upload
    subprocess.run(["SSH_AUTH_SOCK=", "scp"] + SSH_OPTS + [img_path, f"{SSH_HOST}:{remote_tmp}"], check=True)
    # Import as media + set featured
    result = subprocess.run(
        ["SSH_AUTH_SOCK=", "ssh"] + SSH_OPTS + [SSH_HOST,
         f"wp media import {remote_tmp} --post_id={pid} --featured_image --porcelain --path={wp_path}"],
        capture_output=True, text=True
    )
    att_id = result.stdout.strip()
    print(f"    ✓ attachment {att_id} assigned to {kind} '{slug}' (id {pid})")

print("\nBatch 6 done.")
PYEOF2
}

# ── DISPATCHER ─────────────────────────────────────────────────────────────────
run_batch() {
  local b="$1"
  case "$b" in
    1|options)           batch_1_options ;;
    1b|menu-css)         batch_1b_menu_css ;;
    1c|container-width)  batch_1c_container_width ;;
    2|absolute-urls)     batch_2_absolute_urls ;;
    3|broken-crosslinks) batch_3_broken_crosslinks ;;
    4|padding)           batch_4_padding ;;
    5|manifest)          batch_5_manifest ;;
    6|images)            batch_6_images ;;
    *) echo "Unknown batch: $b (use 1-6, 1b, or name)" >&2; exit 1 ;;
  esac
}

if [[ "$BATCH" == "all" ]]; then
  for b in 1 1b 1c 2 3 4 5 6; do
    if [[ "$DRY_RUN" == "0" ]]; then
      confirm_proceed "Run batch $b?" || { echo "Skipping batch $b." >&2; continue; }
    fi
    run_batch "$b"
    echo "" >&2
  done
else
  run_batch "$BATCH"
fi
