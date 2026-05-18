#!/usr/bin/env bash
# fix.sh — remediation batches for Server 1 + Server 2 WordPress sites
#
# Usage:
#   ./fix.sh <hostname> --batch <1-6|name> [--server 1|2] [--dry-run]
#   ./fix.sh <hostname> --all [--server 1|2] [--dry-run]
#   ./fix.sh <hostname> --batch 1c --page-name homepage --page-name plan-your-visit
#   ./fix.sh <hostname> --batch 1c --page-name homepage --width 90%
#
# Flags:
#   --server 1|2    Override auto-detected server (default: resolved from hostname)
#
# Batches:
#   1  / options          — WP options (nav_position_setting, content_top)
#   1b / menu-css         — inject .site-header hide rule into Menu GP element
#   1c / container-width  — enforce template att-container CSS (48px/10px padding)
#   1d / animate          — inject attFadeUp CSS + IntersectionObserver scroll JS
#   2  / absolute-urls    — strip absolute internal URLs from post content
#   3  / broken-crosslinks — rewrite broken slug hrefs using rewrite map
#   4  / padding          — strip "padding: 24px 0 0 0" from post content
#   5  / manifest         — generate slug rename + redirect plan (preview only)
#   6  / images           — upload + assign featured images (if files exist locally)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

DRY_RUN=0
BATCH=""
HOSTNAME=""
PAGE_NAMES=()
WIDTH="100%"
SERVER_OVERRIDE=""

# ── arg parsing ────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <hostname> --batch <1-6|name> [--server 1|2] [--dry-run]" >&2
  echo "       $0 <hostname> --batch 1c [--page-name <slug>]... [--width <value>] [--dry-run]" >&2
  echo "       $0 <hostname> --all [--server 1|2] [--dry-run]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)      BATCH="$2"; shift 2 ;;
    --all)        BATCH="all"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --page-name)  PAGE_NAMES+=("$2"); shift 2 ;;
    --width)      WIDTH="$2"; shift 2 ;;
    --server)
      [[ "$2" == "1" || "$2" == "2" ]] || { echo "ERROR: --server must be 1 or 2" >&2; usage; }
      SERVER_OVERRIDE="$2"; shift 2 ;;
    -*)           echo "Unknown flag: $1" >&2; usage ;;
    *)            HOSTNAME="$1"; shift ;;
  esac
done

[[ -z "$HOSTNAME" || -z "$BATCH" ]] && usage

WP_PATH="$(resolve_wp_path "$HOSTNAME")"
if [[ -z "$WP_PATH" ]]; then
  echo "ERROR: unknown hostname '$HOSTNAME'" >&2
  exit 1
fi

# Set SSH credentials — override takes precedence over auto-detection
if [[ -n "$SERVER_OVERRIDE" ]]; then
  if [[ "$SERVER_OVERRIDE" == "1" ]]; then
    SSH_KEY="$SSH_KEY_S1"
    SSH_HOST="$SSH_HOST_S1"
    SSH_OPTS="$SSH_OPTS_S1"
  fi
  # SERVER_OVERRIDE=2: common.sh defaults are already Server 2, nothing to do
else
  _set_ssh_for_host "$HOSTNAME"
fi

# ── resolve latest merged violations + snapshot (optional for some batches) ───
VIOL_DIR="$OUTPUT_DIR/violations"
SNAP_DIR="$OUTPUT_DIR/snapshots"

find_latest_merged() {
  local host="$1"
  ls -t "$VIOL_DIR/${host}-"*.merged.json 2>/dev/null | head -1
}

MERGED_FILE="$(find_latest_merged "$HOSTNAME")" || true
SNAP_FILE="$SNAP_DIR/${HOSTNAME}-latest.json"

_require_audit_files() {
  if [[ -z "$MERGED_FILE" ]]; then
    echo "ERROR: no merged violations file for $HOSTNAME in $VIOL_DIR" >&2
    echo "  Run: scripts/audit/audit.sh $HOSTNAME" >&2
    exit 1
  fi
  if [[ ! -f "$SNAP_FILE" ]]; then
    echo "ERROR: snapshot not found at $SNAP_FILE" >&2
    exit 1
  fi
}

_resolved_server="$(resolve_server "$HOSTNAME")"
echo "" >&2
echo "Host:    $HOSTNAME" >&2
echo "WP path: $WP_PATH" >&2
echo "Server:  ${SERVER_OVERRIDE:-$_resolved_server}${SERVER_OVERRIDE:+ (override; auto=$_resolved_server)}" >&2
echo "SSH:     $SSH_HOST" >&2
echo "Dry run: $DRY_RUN" >&2
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
  _require_audit_files
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

# ── BATCH 1c: container width ─────────────────────────────────────────────────
batch_1c_container_width() {
  # Default to homepage if no --page-name supplied
  local pages=("${PAGE_NAMES[@]:-homepage}")
  [[ ${#PAGE_NAMES[@]} -eq 0 ]] && pages=("homepage")

  echo "Batch 1c: .att-container → canonical CSS (48px/10px/16px/24px) on: ${pages[*]}" >&2

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would enforce template att-container CSS on: ${pages[*]}" >&2
    return
  fi

  python3 - "$WP_PATH" "$SSH_KEY" "$SSH_HOST" "$WIDTH" "${pages[@]}" << 'PYEOF'
import sys, subprocess, re, tempfile, os

wp_path, ssh_key, ssh_host, width, *page_slugs = sys.argv[1:]

SSH_CMD = f"SSH_AUTH_SOCK='' ssh -i {ssh_key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes {ssh_host}"
SCP_CMD = f"SSH_AUTH_SOCK='' scp -i {ssh_key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes"
WP_OPTS = f"--path={wp_path} --skip-themes --skip-plugins"

CANONICAL_BASE   = f".att-container {{ max-width: {width}; margin: 0 auto; padding-left: 48px; padding-right: 48px; }}"
CANONICAL_MOBILE = ".att-container { padding-left: 10px; padding-right: 10px; }"
CANONICAL_767    = "@media (max-width: 767px)  { .att-container { padding-left: 16px !important; padding-right: 16px !important; } }"
CANONICAL_1023   = "@media (min-width: 768px) and (max-width: 1023px) { .att-container { padding-left: 24px !important; padding-right: 24px !important; } }"

# Normalize whitespace for canonical comparison
def _norm(s): return re.sub(r'\s+', ' ', s).strip()

CANONICAL_RESPONSIVE = {_norm(CANONICAL_767), _norm(CANONICAL_1023)}

# [ \t]* not \s* for trailing whitespace — prevents eating the next line's indent
ATT_CONTAINER_RE = re.compile(r'[ \t]*\.att-container[ \t]*\{[^}]*\}[ \t]*\n?')

def ssh(cmd):
    r = subprocess.run(f"{SSH_CMD} {repr(cmd)}", shell=True, capture_output=True, text=True)
    return r.stdout

def find_media_block(content, condition_re):
    """Return (start, end) of @media <condition> { ... } using brace counting, or None."""
    m = re.search(r'@media\s*' + condition_re + r'\s*\{', content)
    if not m:
        return None
    depth = 0
    for i in range(m.start(), len(content)):
        if content[i] == '{': depth += 1
        elif content[i] == '}':
            depth -= 1
            if depth == 0:
                return (m.start(), i + 1)
    return None

def normalize_att_container(content):
    # B1: remove @media blocks whose entire body is only .att-container rules
    solo_re = re.compile(r'[ \t]*@media\s*[^{]+\{', re.DOTALL)
    i = 0
    out = []
    while i < len(content):
        m = solo_re.search(content, i)
        if not m:
            out.append(content[i:]); break
        out.append(content[i:m.start()])
        depth = 0
        j = m.start()
        while j < len(content):
            if content[j] == '{': depth += 1
            elif content[j] == '}':
                depth -= 1
                if depth == 0:
                    j += 1; break
            j += 1
        block = content[m.start():j]
        brace_open = block.index('{')
        inner = block[brace_open+1:-1]
        if ATT_CONTAINER_RE.sub('', inner).strip() == '':
            # Keep canonical responsive blocks; remove everything else
            if _norm(block) in CANONICAL_RESPONSIVE:
                out.append(block)
            elif j < len(content) and content[j] == '\n':
                j += 1
        else:
            out.append(block)
        i = j
    content = ''.join(out)

    # B2: remove top-level .att-container { ... } rules (not inside @media)
    result = []
    i = 0
    media_depth = 0
    while i < len(content):
        if content[i:i+6] == '@media':
            media_depth += 1
            result.append(content[i]); i += 1; continue
        if content[i] == '{' and media_depth > 0:
            result.append(content[i]); i += 1; continue
        if content[i] == '}' and media_depth > 0:
            result.append(content[i]); i += 1; media_depth -= 1; continue
        m = ATT_CONTAINER_RE.match(content[i:])
        if m and media_depth == 0:
            i += len(m.group(0)); continue
        result.append(content[i]); i += 1
    content = ''.join(result)

    # B3: strip .att-container rules from inside the @media (max-width: 768px) block
    span = find_media_block(content, r'\(max-width:\s*768px\)')
    if span:
        block = content[span[0]:span[1]]
        brace_open = block.index('{')
        inner = block[brace_open+1:-1]
        block_clean = block[:brace_open+1] + ATT_CONTAINER_RE.sub('', inner) + '}'
        content = content[:span[0]] + block_clean + content[span[1]:]

    # C1: insert canonical base rule after /* ── UTILITIES ── */ comment
    utilities_re = re.compile(r'(/\*[^*]*UTILITIES[^*]*\*/[ \t]*\n?)')
    if utilities_re.search(content):
        content = utilities_re.sub(r'\1  ' + CANONICAL_BASE + '\n', content)
    else:
        att_section_re = re.compile(r'[ \t]*\.att-section\s*\{')
        if att_section_re.search(content):
            content = att_section_re.sub('  ' + CANONICAL_BASE + '\n  .att-section {', content, count=1)

    # C2: inject canonical mobile rule as first declaration inside @media (max-width: 768px)
    span = find_media_block(content, r'\(max-width:\s*768px\)')
    if span:
        block = content[span[0]:span[1]]
        brace_open = block.index('{')
        new_block = block[:brace_open+1] + '\n    ' + CANONICAL_MOBILE + block[brace_open+1:]
        content = content[:span[0]] + new_block + content[span[1]:]
    else:
        style_close = content.rfind('</style>')
        if style_close != -1:
            mobile_block = f'  @media (max-width: 768px) {{\n    {CANONICAL_MOBILE}\n  }}\n'
            content = content[:style_close] + mobile_block + content[style_close:]

    # C3: ensure canonical 767px and 1023px responsive blocks exist
    for canonical in [CANONICAL_767, CANONICAL_1023]:
        if _norm(canonical) not in _norm(content):
            last_style_close = content.rfind('</style>')
            if last_style_close != -1:
                content = content[:last_style_close] + '  ' + canonical + '\n' + content[last_style_close:]

    return content

any_fixed = False
for slug in page_slugs:
    print(f"\n  [{slug}]", flush=True)
    post_id = ssh(f"wp post list --post_type=page --name={slug} --field=ID --format=csv {WP_OPTS} 2>/dev/null").strip()
    if not post_id:
        print(f"    ERROR: page '{slug}' not found", flush=True)
        continue

    content = ssh(f"wp post get {post_id} --field=post_content {WP_OPTS} 2>/dev/null")
    print(f"    Length: {len(content)}", flush=True)

    if 'att-container' not in content:
        print(f"    SKIP: no att-container in content", flush=True)
        continue
    if '<style' not in content:
        print(f"    SKIP: no <style> block in content", flush=True)
        continue

    updated = normalize_att_container(content)

    if updated == content:
        print(f"    SKIP: already matches template (no change)", flush=True)
        continue

    print(f"    MATCH: normalizing att-container CSS", flush=True)

    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix='.html', mode='w', encoding='utf-8')
    tmp_html.write(updated)
    tmp_html.close()

    php_code = f'<?php wp_update_post(array("ID"=>{post_id},"post_content"=>file_get_contents("/tmp/fix1c_{post_id}.html"))); echo "Success: Updated post {post_id}.\\n";'
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix='.php', mode='w', encoding='utf-8')
    tmp_php.write(php_code)
    tmp_php.close()

    subprocess.run(f"{SCP_CMD} {tmp_html.name} {ssh_host}:/tmp/fix1c_{post_id}.html",
                   shell=True, check=True, capture_output=True)
    subprocess.run(f"{SCP_CMD} {tmp_php.name} {ssh_host}:/tmp/fix1c_{post_id}.php",
                   shell=True, check=True, capture_output=True)
    os.unlink(tmp_html.name)
    os.unlink(tmp_php.name)

    result = ssh(f"wp eval-file /tmp/fix1c_{post_id}.php {WP_OPTS} 2>/dev/null; rm -f /tmp/fix1c_{post_id}.html /tmp/fix1c_{post_id}.php")
    print(f"    {result.strip()}", flush=True)
    any_fixed = True

if any_fixed:
    print("\n  Flushing caches...", flush=True)
    print(ssh(f"wp cache flush {WP_OPTS} 2>/dev/null").strip(), flush=True)
    print(ssh(f"wp eval 'if(function_exists(\"rocket_clean_domain\")){{rocket_clean_domain();echo \"Rocket cleared\\n\";}}' {WP_OPTS} 2>/dev/null").strip(), flush=True)
PYEOF

  echo "" >&2
  echo "Batch 1c done. Hard-refresh to verify 48px desktop gutters." >&2
}

# ── BATCH 1d: animate — inject attFadeUp CSS + IntersectionObserver JS ────────
batch_1d_animate() {
  local pages=("${PAGE_NAMES[@]:-homepage}")
  [[ ${#PAGE_NAMES[@]} -eq 0 ]] && pages=("homepage")

  echo "Batch 1d: animation — attFadeUp CSS + scroll observer JS on: ${pages[*]}" >&2

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] would inject animation CSS/JS on: ${pages[*]}" >&2
    return
  fi

  python3 - "$WP_PATH" "$SSH_KEY" "$SSH_HOST" "${pages[@]}" << 'PYEOF'
import sys, subprocess, re, tempfile, os

wp_path, ssh_key, ssh_host, *page_slugs = sys.argv[1:]

SSH_CMD = f"SSH_AUTH_SOCK='' ssh -i {ssh_key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes {ssh_host}"
SCP_CMD = f"SSH_AUTH_SOCK='' scp -i {ssh_key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes"
WP_OPTS = f"--path={wp_path} --skip-themes --skip-plugins"

ANIMATION_CSS = """\
  /* ── ANIMATION ── */
  @keyframes attFadeUp {
    from { opacity: 0; transform: translateY(16px); }
    to   { opacity: 1; transform: translateY(0); }
  }
  .att-animate { opacity: 0; animation: attFadeUp 0.5s ease-out forwards; }
  .att-delay-1 { animation-delay: 0.1s; }
  .att-delay-2 { animation-delay: 0.2s; }
  .att-delay-3 { animation-delay: 0.3s; }
"""

# querySelectorAll target string per page wrapper class
PAGE_SELECTORS = {
    'att-homepage':
        '.att-ticket, .att-faq-item, .att-highlight, .att-tip',
    'att-tickets-page':
        '.att-tickets-page .att-featured, .att-tickets-page .att-ticket, '
        '.att-tickets-page .att-faq-item, .att-tickets-page .att-tip, '
        '.att-tickets-page .att-guide-card, .att-tickets-page .att-rec-callout',
    'att-plan-page':
        '.att-plan-page .att-article-card, .att-plan-page .att-faq-item, '
        '.att-plan-page .att-tip, .att-plan-page .att-practical-card, '
        '.att-plan-page .att-quicktip',
    'att-see-page':
        '.att-see-page .att-featured, .att-see-page .att-article-card, '
        '.att-see-page .att-faq-item, .att-see-page .att-guide-card',
}

def observer_js(sel):
    return (
        "  // Scroll-triggered fade-in\n"
        "  if ('IntersectionObserver' in window) {\n"
        "    var observer = new IntersectionObserver(function(entries) {\n"
        "      entries.forEach(function(entry) {\n"
        "        if (entry.isIntersecting) {\n"
        "          entry.target.style.opacity = '1';\n"
        "          entry.target.style.transform = 'translateY(0)';\n"
        "          observer.unobserve(entry.target);\n"
        "        }\n"
        "      });\n"
        "    }, { threshold: 0.1 });\n"
        f"    document.querySelectorAll('{sel}').forEach(function(el) {{\n"
        "      el.style.opacity = '0';\n"
        "      el.style.transform = 'translateY(16px)';\n"
        "      el.style.transition = 'opacity 0.45s ease-out, transform 0.45s ease-out';\n"
        "      observer.observe(el);\n"
        "    });\n"
        "  }"
    )

# Hero element class additions: (search_class, classes_to_add)
HERO_CLASSES = [
    ('att-hero__badge',      ['att-animate']),
    ('att-hero__desc',       ['att-animate', 'att-delay-2']),
    ('att-hero__actions',    ['att-animate', 'att-delay-3']),
    ('att-hero__image-wrap', ['att-animate', 'att-delay-2']),
]

def add_hero_classes(content):
    changed = False
    for base_class, add_classes in HERO_CLASSES:
        pattern = re.compile(r'(class="' + re.escape(base_class) + r'")')
        for cls in add_classes:
            def inserter(m, cls=cls):
                existing = m.group(1)
                return existing[:-1] + ' ' + cls + '"'
            new = re.sub(
                r'class="([^"]*\b' + re.escape(base_class) + r'\b[^"]*)"',
                lambda m, cls=cls: (
                    m.group(0) if cls in m.group(1).split()
                    else f'class="{m.group(1)} {cls}"'
                ),
                content
            )
            if new != content:
                content = new
                changed = True
    # h1 in hero: add att-animate att-delay-1 if missing
    h1_re = re.compile(r'(<h1\s[^>]*class=")([^"]*)"')
    def patch_h1(m):
        cls_str = m.group(2)
        classes = cls_str.split()
        added = False
        for c in ['att-animate', 'att-delay-1']:
            if c not in classes:
                classes.append(c)
                added = True
        return f'{m.group(1)}{" ".join(classes)}"' if added else m.group(0)
    new = h1_re.sub(patch_h1, content, count=1)
    if new != content:
        content = new; changed = True
    return content, changed

def ssh(cmd):
    r = subprocess.run(f"{SSH_CMD} {repr(cmd)}", shell=True, capture_output=True, text=True)
    return r.stdout

any_fixed = False
for slug in page_slugs:
    print(f"\n  [{slug}]", flush=True)
    post_id = ssh(f"wp post list --post_type=page --name={slug} --field=ID --format=csv {WP_OPTS} 2>/dev/null").strip()
    if not post_id:
        print(f"    ERROR: page '{slug}' not found", flush=True)
        continue

    content = ssh(f"wp post get {post_id} --field=post_content {WP_OPTS} 2>/dev/null")
    print(f"    Length: {len(content)}", flush=True)
    updated = content

    # Detect page type
    page_type = next((k for k in PAGE_SELECTORS if f'class="{k}"' in updated or f"class='{k}'" in updated), None)
    if not page_type:
        print(f"    SKIP: could not detect page wrapper class", flush=True)
        continue
    print(f"    Type: {page_type}", flush=True)

    # 1. Inject animation CSS before </style> if missing
    if 'attFadeUp' not in updated:
        updated = updated.replace('</style>', ANIMATION_CSS + '</style>', 1)
        print(f"    + animation CSS injected", flush=True)
    else:
        print(f"    ~ animation CSS already present", flush=True)

    # 2. Inject IntersectionObserver JS before </script> if missing
    if 'IntersectionObserver' not in updated:
        js_block = observer_js(PAGE_SELECTORS[page_type])
        # Insert before closing })(); </script>
        updated = re.sub(r'(\}\)\(\);[\s\n]*</script>)', js_block + '\n})();\n</script>', updated, count=1)
        if 'IntersectionObserver' not in updated:
            # Fallback: insert before last </script>
            updated = updated.replace('</script>', js_block + '\n</script>', 1)
        print(f"    + IntersectionObserver JS injected", flush=True)
    else:
        print(f"    ~ scroll observer already present", flush=True)

    # 3. Add att-animate classes to hero elements if missing
    updated, hero_changed = add_hero_classes(updated)
    print(f"    {'+ hero classes patched' if hero_changed else '~ hero classes already present'}", flush=True)

    if updated == content:
        print(f"    SKIP: no changes needed", flush=True)
        continue

    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix='.html', mode='w', encoding='utf-8')
    tmp_html.write(updated)
    tmp_html.close()

    php_code = f'<?php wp_update_post(array("ID"=>{post_id},"post_content"=>file_get_contents("/tmp/fix1d_{post_id}.html"))); echo "Success: Updated post {post_id}.\\n";'
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix='.php', mode='w', encoding='utf-8')
    tmp_php.write(php_code)
    tmp_php.close()

    for attempt in range(3):
        r = subprocess.run(f"{SCP_CMD} {tmp_html.name} {ssh_host}:/tmp/fix1d_{post_id}.html",
                           shell=True, capture_output=True)
        if r.returncode == 0: break
        print(f"    scp attempt {attempt+1} failed, retrying...", flush=True)
    subprocess.run(f"{SCP_CMD} {tmp_php.name} {ssh_host}:/tmp/fix1d_{post_id}.php",
                   shell=True, check=True, capture_output=True)
    os.unlink(tmp_html.name)
    os.unlink(tmp_php.name)

    result = ssh(f"wp eval-file /tmp/fix1d_{post_id}.php {WP_OPTS} 2>/dev/null; rm -f /tmp/fix1d_{post_id}.html /tmp/fix1d_{post_id}.php")
    print(f"    {result.strip()}", flush=True)
    any_fixed = True

if any_fixed:
    print("\n  Flushing caches...", flush=True)
    print(ssh(f"wp cache flush {WP_OPTS} 2>/dev/null").strip(), flush=True)
    print(ssh(f"wp eval 'if(function_exists(\"rocket_clean_domain\")){{rocket_clean_domain();echo \"Rocket cleared\\n\";}}' {WP_OPTS} 2>/dev/null").strip(), flush=True)
PYEOF

  echo "" >&2
  echo "Batch 1d done. Hard-refresh to verify hero fade-in + scroll animations." >&2
}

# ── BATCH 2: absolute URLs ─────────────────────────────────────────────────────
batch_2_absolute_urls() {
  _require_audit_files
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
  _require_audit_files
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
  _require_audit_files
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
  _require_audit_files
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
  _require_audit_files
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
    1d|animate)          batch_1d_animate ;;
    2|absolute-urls)     batch_2_absolute_urls ;;
    3|broken-crosslinks) batch_3_broken_crosslinks ;;
    4|padding)           batch_4_padding ;;
    5|manifest)          batch_5_manifest ;;
    6|images)            batch_6_images ;;
    *) echo "Unknown batch: $b (use 1-6, 1b, or name)" >&2; exit 1 ;;
  esac
}

if [[ "$BATCH" == "all" ]]; then
  for b in 1 1b 1c 1d 2 3 4 5 6; do
    if [[ "$DRY_RUN" == "0" ]]; then
      confirm_proceed "Run batch $b?" || { echo "Skipping batch $b." >&2; continue; }
    fi
    run_batch "$b"
    echo "" >&2
  done
else
  run_batch "$BATCH"
fi
