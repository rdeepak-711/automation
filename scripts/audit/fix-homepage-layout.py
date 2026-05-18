#!/usr/bin/env python3
"""
Ensure all 6 pages per site have the correct layout.

Fixes applied per page type:
  homepage
    • _generate-full-width-content post meta = '1'  (GP full-width body class)
    • generate_settings.background_color = '#ffffff' (no grey strips)

  att-* content pages  (tickets, plan-your-visit, what-to-see)
    • _generate-full-width-content post meta = '1'
    • double-selector  .page-class .page-class .att-container → .page-class .att-container
    • animation classes on hero elements (att-animate / att-delay-*)

  about-us / contact-us
    • no structural fixes (standard GP sidebar layout — no att-* classes)

Usage:
  python3 fix-homepage-layout.py                        # audit all sites
  python3 fix-homepage-layout.py --apply                # write changes to WP DB
  python3 fix-homepage-layout.py --site msm             # filter by site name substring
  python3 fix-homepage-layout.py --site msm --apply
"""
import re
import os
import sys
import json
import subprocess
import tempfile

APPLY       = "--apply" in sys.argv
SITE_FILTER = next((sys.argv[i+1] for i, a in enumerate(sys.argv) if a == "--site"), None)

# ── SSH credentials ───────────────────────────────────────────────────────────
SSH_KEY_S1  = os.path.expanduser("~/.ssh/id_rsa_bluehost_old")
SSH_HOST_S1 = "kzrmeomy@50.6.109.30"

SSH_KEY_S2  = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
SSH_HOST_S2 = "dpskbcmy@50.6.155.174"

# ── Site + page registry ──────────────────────────────────────────────────────
# page_type: "homepage" | "att" | "standard"
SITES = [
    {
        "name":     "auschwitz-guide.com",
        "ssh_key":  SSH_KEY_S1,
        "ssh_host": SSH_HOST_S1,
        "wp_path":  "/home1/kzrmeomy/public_html/website_ce6ca565",
        "pages": [
            {"id": 210, "slug": "homepage",        "type": "homepage", "page_class": None},
            {"id": 137, "slug": "tickets-tours",   "type": "att",      "page_class": "att-tickets-page"},
            {"id": 136, "slug": "plan-your-visit", "type": "att",      "page_class": "att-plan-page"},
            {"id": 138, "slug": "what-to-see",     "type": "att",      "page_class": "att-see-page"},
            {"id": None, "slug": "about-us",       "type": "standard", "page_class": None},
            {"id": None, "slug": "contact-us",     "type": "standard", "page_class": None},
        ],
    },
    {
        "name":     "operagarnier-guide.com",
        "ssh_key":  SSH_KEY_S1,
        "ssh_host": SSH_HOST_S1,
        "wp_path":  "/home1/kzrmeomy/public_html/website_b9cdec12",
        "pages": [
            {"id": 129, "slug": "homepage",        "type": "homepage", "page_class": None},
            {"id": 131, "slug": "tickets-tours",   "type": "att",      "page_class": "att-tickets-page"},
            {"id": 130, "slug": "plan-your-visit", "type": "att",      "page_class": "att-plan-page"},
            {"id": 132, "slug": "what-to-see",     "type": "att",      "page_class": "att-see-page"},
            {"id": None, "slug": "about-us",       "type": "standard", "page_class": None},
            {"id": None, "slug": "contact-us",     "type": "standard", "page_class": None},
        ],
    },
    {
        "name":     "montsaintmichel-guide.com",
        "ssh_key":  SSH_KEY_S2,
        "ssh_host": SSH_HOST_S2,
        "wp_path":  "/home1/dpskbcmy/public_html/website_58b542cb",
        "pages": [
            {"id": 65,  "slug": "homepage",        "type": "homepage", "page_class": None},
            {"id": 67,  "slug": "tickets",         "type": "att",      "page_class": "att-tickets-page"},
            {"id": 66,  "slug": "plan-your-visit", "type": "att",      "page_class": "att-plan-page"},
            {"id": 68,  "slug": "what-to-see",     "type": "att",      "page_class": "att-see-page"},
            {"id": None, "slug": "about-us",       "type": "standard", "page_class": None},
            {"id": None, "slug": "contact-us",     "type": "standard", "page_class": None},
        ],
    },
    {
        "name":     "hagiasofia-guide.com",
        "ssh_key":  SSH_KEY_S2,
        "ssh_host": SSH_HOST_S2,
        "wp_path":  "/home1/dpskbcmy/public_html/website_204db6f9",
        "pages": [
            {"id": 219, "slug": "homepage",        "type": "homepage", "page_class": None},
            {"id": 214, "slug": "tickets",         "type": "att",      "page_class": "att-tickets-page"},
            {"id": 213, "slug": "plan-your-visit", "type": "att",      "page_class": "att-plan-page"},
            {"id": 215, "slug": "what-to-see",     "type": "att",      "page_class": "att-see-page"},
            {"id": 451, "slug": "about-us",        "type": "standard", "page_class": None},
            {"id": 452, "slug": "contact-us",      "type": "standard", "page_class": None},
        ],
    },
    {
        "name":     "vangoghmuseum-guide.com",
        "ssh_key":  SSH_KEY_S2,
        "ssh_host": SSH_HOST_S2,
        "wp_path":  "/home1/dpskbcmy/public_html/website_da6eadef",
        "pages": [
            {"id": 70,  "slug": "homepage",        "type": "homepage", "page_class": None},
            {"id": 72,  "slug": "tickets",         "type": "att",      "page_class": "att-tickets-page"},
            {"id": 71,  "slug": "plan-your-visit", "type": "att",      "page_class": "att-plan-page"},
            {"id": 73,  "slug": "what-to-see",     "type": "att",      "page_class": "att-see-page"},
            {"id": 294, "slug": "about-us",        "type": "standard", "page_class": None},
            {"id": 295, "slug": "contact-us",      "type": "standard", "page_class": None},
        ],
    },
]

WANT_BG_COLOR = "#ffffff"

# Animation classes to inject on hero elements (att pages only)
ANIMATE_REPLACEMENTS = [
    ('class="att-hero__badge"',      'class="att-hero__badge att-animate"'),
    ('<h1>',                          '<h1 class="att-animate att-delay-1">'),
    ('class="att-hero__desc"',       'class="att-hero__desc att-animate att-delay-2"'),
    ('class="att-hero__actions"',    'class="att-hero__actions att-animate att-delay-3"'),
    ('class="att-hero__image-wrap"', 'class="att-hero__image-wrap att-animate att-delay-2"'),
    ('class="att-recs-strip"',       'class="att-recs-strip att-animate att-delay-3"'),
]


# ── SSH helpers ───────────────────────────────────────────────────────────────
import time

def _opts(key):
    return f"-i {key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

def ssh(host, key, cmd, retries=5, delay=10):
    for attempt in range(retries):
        r = subprocess.run(
            f'SSH_AUTH_SOCK="" ssh {_opts(key)} {host} {cmd!r}',
            shell=True, capture_output=True, text=True
        )
        if r.returncode == 0:
            return r.stdout.strip()
        if "Connection refused" in r.stderr or r.returncode == 255:
            if attempt < retries - 1:
                print(f"    ⏳ SSH refused, retry {attempt+1}/{retries-1} in {delay}s…")
                time.sleep(delay)
                continue
        raise RuntimeError(f"SSH error [{r.returncode}]: {r.stderr.strip()}")
    raise RuntimeError(f"SSH failed after {retries} attempts")

def scp(key, local, host, remote, retries=5, delay=10):
    for attempt in range(retries):
        r = subprocess.run(
            f'SSH_AUTH_SOCK="" scp {_opts(key)} {local} {host}:{remote}',
            shell=True, capture_output=True
        )
        if r.returncode == 0:
            return
        if b"Connection refused" in r.stderr or r.returncode == 255:
            if attempt < retries - 1:
                time.sleep(delay)
                continue
        r.check_returncode()


# ── Resolve page ID by slug if not hardcoded ─────────────────────────────────
def resolve_id(host, key, wp, slug):
    raw = ssh(host, key,
        f"wp post list --post_type=page --name={slug} --field=ID --path={wp} 2>/dev/null || true"
    )
    ids = [l.strip() for l in raw.splitlines() if l.strip().isdigit()]
    return int(ids[0]) if ids else None


# ── Content read/write ────────────────────────────────────────────────────────
def get_content(host, key, wp, pid):
    return ssh(host, key,
        f"wp post get {pid} --field=post_content --path={wp} 2>/dev/null"
    )

def write_content(host, key, wp, pid, content):
    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp_html.write(content); tmp_html.close()

    php = (
        f'<?php wp_update_post(array('
        f'"ID"=>{pid},'
        f'"post_content"=>file_get_contents("/tmp/fhl_{pid}.html")'
        f')); echo "Updated {pid}\\n";'
    )
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp_php.write(php); tmp_php.close()

    try:
        scp(key, tmp_html.name, host, f"/tmp/fhl_{pid}.html")
        scp(key, tmp_php.name,  host, f"/tmp/fhl_{pid}.php")
        result = ssh(host, key,
            f"wp eval-file /tmp/fhl_{pid}.php --path={wp} 2>/dev/null; "
            f"rm -f /tmp/fhl_{pid}.html /tmp/fhl_{pid}.php"
        )
        return result
    finally:
        os.unlink(tmp_html.name)
        os.unlink(tmp_php.name)


# ── Fix: full-width post meta ─────────────────────────────────────────────────
def check_full_width(host, key, wp, pid):
    val = ssh(host, key,
        f"wp post meta get {pid} _generate-full-width-content --path={wp} 2>/dev/null || true"
    )
    return val.strip()

def fix_full_width(host, key, wp, pid):
    ssh(host, key,
        f"wp post meta update {pid} _generate-full-width-content true --path={wp}"
    )


# ── Fix: background color (site-wide, homepage only) ─────────────────────────
def check_bg_color(host, key, wp):
    raw = ssh(host, key,
        f"wp option get generate_settings --format=json --path={wp} 2>/dev/null || true"
    )
    if not raw:
        return None, None
    try:
        settings = json.loads(raw)
    except json.JSONDecodeError:
        return None, None
    return settings.get("background_color"), settings

def fix_bg_color(host, key, wp, settings):
    php = (
        '<?php\n'
        '$s = (array)get_option("generate_settings", array());\n'
        f'$s["background_color"] = "{WANT_BG_COLOR}";\n'
        'update_option("generate_settings", $s);\n'
        'echo "bg_color updated\\n";\n'
    )
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp.write(php); tmp.close()
    try:
        scp(key, tmp.name, host, "/tmp/fhl_bgfix.php")
        ssh(host, key, f"wp eval-file /tmp/fhl_bgfix.php --path={wp} 2>/dev/null; rm -f /tmp/fhl_bgfix.php")
    finally:
        os.unlink(tmp.name)


# ── Fix: double selector in att-* content ────────────────────────────────────
def fix_double_selector(content, page_class):
    pattern = rf'(\.{re.escape(page_class)})\s+\.{re.escape(page_class)}\s+(\.att-container)'
    return re.sub(pattern, r'\1 \2', content)


# ── Fix: animation classes on hero elements ───────────────────────────────────
def fix_animate(content):
    for old, new in ANIMATE_REPLACEMENTS:
        content = content.replace(old, new)
    return content


# ── Cache flush ───────────────────────────────────────────────────────────────
def flush_cache(host, key, wp):
    try:
        ssh(host, key, f"wp cache flush --path={wp} 2>/dev/null || true")
    except Exception:
        pass
    try:
        ssh(host, key,
            f"rm -rf {wp}/wp-content/cache/wp-rocket/ 2>/dev/null || true"
        )
    except Exception:
        pass


# ── Per-page processor ────────────────────────────────────────────────────────
def process_page(site, page, bg_color, bg_settings):
    host = site["ssh_host"]
    key  = site["ssh_key"]
    wp   = site["wp_path"]
    slug = page["slug"]
    typ  = page["type"]
    cls  = page["page_class"]

    # Resolve ID if not hardcoded
    pid = page["id"]
    if pid is None:
        pid = resolve_id(host, key, wp, slug)
    if pid is None:
        print(f"    ⚠️  {slug}: page not found — skipping")
        return False

    print(f"\n  [{slug}]  ID {pid}  type={typ}")
    changed = False

    # ── Full-width meta (all page types) ─────────────────────────────────────
    meta_val = check_full_width(host, key, wp, pid)
    meta_ok  = meta_val == "true"
    icon = "✅" if meta_ok else "❌"
    print(f"    {icon} _generate-full-width-content: {meta_val!r}", end="")
    if not meta_ok:
        if APPLY:
            fix_full_width(host, key, wp, pid)
            print("  → fixed to 'true'")
            changed = True
        else:
            print("  → needs 'true'")
    else:
        print()

    # ── Background color (homepage only, site-wide setting) ───────────────────
    if typ == "homepage":
        bg_ok = (bg_color == WANT_BG_COLOR)
        icon  = "✅" if bg_ok else "❌"
        print(f"    {icon} background_color: {bg_color!r}", end="")
        if not bg_ok:
            if APPLY and bg_settings:
                fix_bg_color(host, key, wp, bg_settings)
                print(f"  → fixed to {WANT_BG_COLOR!r}")
                changed = True
            else:
                print(f"  → needs {WANT_BG_COLOR!r}")
        else:
            print()

    # ── Double-selector + animation (att pages only) ──────────────────────────
    if typ == "att":
        content = get_content(host, key, wp, pid)
        if not content:
            print(f"    ⚠️  empty post content — skipping content fixes")
            return changed

        after_sel  = fix_double_selector(content, cls)
        sel_fixed  = after_sel != content
        after_anim = fix_animate(after_sel)
        anim_fixed = after_anim != after_sel

        icon = "❌" if sel_fixed else "✅"
        print(f"    {icon} double-selector ({cls}): {'needs fix' if sel_fixed else 'clean'}")
        icon = "❌" if anim_fixed else "✅"
        print(f"    {icon} animation classes: {'needs fix' if anim_fixed else 'already present'}")

        if (sel_fixed or anim_fixed) and APPLY:
            result = write_content(host, key, wp, pid, after_anim)
            print(f"    → DB: {result}")
            changed = True

    return changed


# ── Per-site processor ────────────────────────────────────────────────────────
def process_site(site):
    host = site["ssh_host"]
    key  = site["ssh_key"]
    wp   = site["wp_path"]

    print(f"\n{'='*56}")
    print(f"Site: {site['name']}")
    print(f"{'='*56}")

    # Read bg color once per site (used for homepage page processing)
    bg_color, bg_settings = check_bg_color(host, key, wp)

    any_changed = False
    for page in site["pages"]:
        try:
            changed = process_page(site, page, bg_color, bg_settings)
            if changed:
                any_changed = True
        except Exception as e:
            print(f"    ERROR on {page['slug']}: {e}")

    if any_changed:
        print(f"\n  Flushing cache…")
        flush_cache(host, key, wp)
        print(f"  ✅ cache flushed")
    elif APPLY:
        print(f"\n  No changes needed — cache flush skipped.")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    mode = "APPLY" if APPLY else "AUDIT"
    print(f"=== fix-homepage-layout [{mode}] ===")
    if SITE_FILTER:
        print(f"    --site filter: {SITE_FILTER}")

    sites = [s for s in SITES if not SITE_FILTER or SITE_FILTER in s["name"]]
    if not sites:
        print(f"No sites matched filter '{SITE_FILTER}'")
        sys.exit(1)

    for site in sites:
        try:
            process_site(site)
        except Exception as e:
            print(f"\n  ERROR on {site['name']}: {e}")

    print(f"\n=== Done ===")
    if not APPLY:
        print("Run with --apply to write changes.")


if __name__ == "__main__":
    main()
