#!/usr/bin/env python3
"""
Normalize non-homepage pages across all sites.

Fixes applied per page:
  1. Double-selector — .page-class .page-class .att-container → .page-class .att-container
  2. Animation       — adds att-animate / att-delay-* to hero elements missing them

Usage:
  python3 fix-pages.py                         # list pending changes, all sites/pages
  python3 fix-pages.py --apply                 # write changes to DB
  python3 fix-pages.py --site auschwitz        # filter by site name substring
  python3 fix-pages.py --page tickets          # filter by page slug substring
  python3 fix-pages.py --apply --site opera --page plan
"""
import re
import os
import sys
import subprocess
import tempfile

# ── CLI flags ────────────────────────────────────────────────────────────────
# Modes: --list (default) = show pending changes only
#        --apply          = write changes to DB
APPLY       = "--apply" in sys.argv
SITE_FILTER = next((sys.argv[i+1] for i, a in enumerate(sys.argv) if a == "--site"), None)
PAGE_FILTER = next((sys.argv[i+1] for i, a in enumerate(sys.argv) if a == "--page"), None)

# ── SSH credentials ───────────────────────────────────────────────────────────
SSH_KEY_S1  = os.path.expanduser("~/.ssh/id_rsa_bluehost_old")
SSH_HOST_S1 = "kzrmeomy@50.6.109.30"

SSH_KEY_S2  = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
SSH_HOST_S2 = "dpskbcmy@50.6.155.174"

# ── Site + page registry ──────────────────────────────────────────────────────
SITES = [
    {
        "name":     "auschwitz-guide.com",
        "ssh_key":  SSH_KEY_S1,
        "ssh_host": SSH_HOST_S1,
        "wp_path":  "/home1/kzrmeomy/public_html/website_ce6ca565",
        "pages": [
            {"id": 210, "slug": "homepage",        "page_class": None},
            {"id": 137, "slug": "tickets-tours",   "page_class": "att-tickets-page"},
            {"id": 136, "slug": "plan-your-visit", "page_class": "att-plan-page"},
            {"id": 138, "slug": "what-to-see",     "page_class": "att-see-page"},
        ],
    },
    {
        "name":     "operagarnier-guide.com",
        "ssh_key":  SSH_KEY_S1,
        "ssh_host": SSH_HOST_S1,
        "wp_path":  "/home1/kzrmeomy/public_html/website_b9cdec12",
        "pages": [
            {"id": 129, "slug": "homepage",        "page_class": None},
            {"id": 131, "slug": "tickets-tours",   "page_class": "att-tickets-page"},
            {"id": 130, "slug": "plan-your-visit", "page_class": "att-plan-page"},
            {"id": 132, "slug": "what-to-see",     "page_class": "att-see-page"},
        ],
    },
    {
        "name":     "montsaintmichel-guide.com",
        "ssh_key":  SSH_KEY_S2,
        "ssh_host": SSH_HOST_S2,
        "wp_path":  "/home1/dpskbcmy/public_html/website_58b542cb",
        "pages": [
            {"id": 65,  "slug": "homepage",        "page_class": None},
            {"id": 67,  "slug": "tickets",         "page_class": "att-tickets-page"},
            {"id": 66,  "slug": "plan-your-visit", "page_class": "att-plan-page"},
            {"id": 68,  "slug": "what-to-see",     "page_class": "att-see-page"},
        ],
    },
]

# ── Animation classes to inject on hero elements ──────────────────────────────
# Each tuple: (existing class attr value, replacement with att-animate added)
ANIMATE_REPLACEMENTS = [
    ('class="att-hero__badge"',      'class="att-hero__badge att-animate"'),
    ('<h1>',                          '<h1 class="att-animate att-delay-1">'),
    ('class="att-hero__desc"',       'class="att-hero__desc att-animate att-delay-2"'),
    ('class="att-hero__actions"',    'class="att-hero__actions att-animate att-delay-3"'),
    ('class="att-hero__image-wrap"', 'class="att-hero__image-wrap att-animate att-delay-2"'),
    ('class="att-recs-strip"',       'class="att-recs-strip att-animate att-delay-3"'),
]


# ── SSH helpers ───────────────────────────────────────────────────────────────
def _opts(key):
    return f"-i {key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

def ssh(host, key, cmd):
    r = subprocess.run(
        f'SSH_AUTH_SOCK="" ssh {_opts(key)} {host} {cmd!r}',
        shell=True, capture_output=True, text=True
    )
    if r.returncode != 0:
        raise RuntimeError(f"SSH error [{r.returncode}]: {r.stderr.strip()}")
    return r.stdout

def scp(key, local, host, remote):
    subprocess.run(
        f'SSH_AUTH_SOCK="" scp {_opts(key)} {local} {host}:{remote}',
        shell=True, check=True, capture_output=True
    )


# ── Fix passes ────────────────────────────────────────────────────────────────
def fix_double_selector(content, page_class):
    pattern = rf'(\.{re.escape(page_class)})\s+\.{re.escape(page_class)}\s+(\.att-container)'
    return re.sub(pattern, r'\1 \2', content)

def fix_animate(content):
    fixed = content
    for old, new in ANIMATE_REPLACEMENTS:
        fixed = fixed.replace(old, new)
    return fixed


# ── Write back to DB ──────────────────────────────────────────────────────────
def write_to_db(host, key, wp, pid, content):
    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp_html.write(content); tmp_html.close()

    php = (
        f'<?php wp_update_post(array('
        f'"ID"=>{pid},'
        f'"post_content"=>file_get_contents("/tmp/fp_{pid}.html")'
        f')); echo "Updated {pid}\\n";'
    )
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp_php.write(php); tmp_php.close()

    try:
        scp(key, tmp_html.name, host, f"/tmp/fp_{pid}.html")
        scp(key, tmp_php.name, host, f"/tmp/fp_{pid}.php")
        result = ssh(host, key,
            f"wp eval-file /tmp/fp_{pid}.php --path={wp} 2>/dev/null; "
            f"rm -f /tmp/fp_{pid}.html /tmp/fp_{pid}.php"
        )
        print(f"    DB: {result.strip()}")
    finally:
        os.unlink(tmp_html.name)
        os.unlink(tmp_php.name)

    try:
        ssh(host, key, f"wp cache flush --path={wp} 2>/dev/null")
        print(f"    CACHE: flushed")
    except Exception:
        pass


# ── Per-page processor ────────────────────────────────────────────────────────
def process_page(site, page):
    host = site["ssh_host"]
    key  = site["ssh_key"]
    wp   = site["wp_path"]
    pid  = page["id"]
    slug = page["slug"]
    cls  = page["page_class"]

    print(f"\n  [{slug}] ID {pid}")

    content = ssh(host, key, f"wp post get {pid} --field=post_content --path={wp} 2>/dev/null")
    if not content.strip():
        print(f"    SKIP: empty content")
        return

    # Pass 1 — double selector (skip for homepage — uses plain .att-container)
    after_selector = fix_double_selector(content, cls) if cls else content
    sel_changed = after_selector != content
    print(f"    selector fix: {'YES' if sel_changed else 'already clean'}")
    if sel_changed and not APPLY:
        pat = rf'(\.{re.escape(cls)})\s+\.{re.escape(cls)}\s+(\.att-container)'
        for line in content.splitlines():
            if re.search(pat, line):
                print(f"      BEFORE: {line.strip()}")
        for line in after_selector.splitlines():
            if f".{cls} .att-container" in line and "48px" in line:
                print(f"      AFTER:  {line.strip()}")

    # Pass 2 — animation classes
    after_animate = fix_animate(after_selector)
    anim_changed  = after_animate != after_selector
    added = [old for old, _ in ANIMATE_REPLACEMENTS if old in after_selector and old not in after_animate]
    print(f"    animate fix:  {'YES (' + str(len(added)) + ' elements)' if anim_changed else 'already has classes'}")

    final = after_animate
    if final == content:
        print(f"    STATUS: nothing to do")
        return

    if not APPLY:
        print(f"    STATUS: pending — run with --apply to write")
        return

    write_to_db(host, key, wp, pid, final)
    print(f"    STATUS: done")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    mode = "LIST" if not APPLY else "APPLY"
    print(f"=== fix-pages [{mode}]", end="")
    if SITE_FILTER: print(f"  --site {SITE_FILTER}", end="")
    if PAGE_FILTER: print(f"  --page {PAGE_FILTER}", end="")
    print(" ===\n")

    sites = [s for s in SITES if not SITE_FILTER or SITE_FILTER in s["name"]]
    for site in sites:
        print(f"{'='*50}")
        print(f"Site: {site['name']}")
        pages = [p for p in site["pages"] if not PAGE_FILTER or PAGE_FILTER in p["slug"]]
        for page in pages:
            process_page(site, page)

    print(f"\n=== Done ===")

if __name__ == "__main__":
    main()
