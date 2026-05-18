#!/usr/bin/env python3
"""
Fix double page-class selectors on .att-container in non-homepage pages.

Bug: batch 1c wrote `.att-tickets-page .att-tickets-page .att-container`
     instead of `.att-tickets-page .att-container` (and same for plan/see pages).
     Double selector never matches → 0px padding on all non-homepage pages.

Runs dry-run by default. Pass --live to write to DB.
"""
import re
import os
import sys
import subprocess
import tempfile

DRY_RUN = "--live" not in sys.argv

SSH_KEY_S1 = os.path.expanduser("~/.ssh/id_rsa_bluehost_old")
SSH_HOST_S1 = "kzrmeomy@50.6.109.30"

SSH_KEY_S2 = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
SSH_HOST_S2 = "dpskbcmy@50.6.155.174"

SITES = [
    {
        "name": "auschwitz-guide.com",
        "ssh_key": SSH_KEY_S1,
        "ssh_host": SSH_HOST_S1,
        "wp_path": "/home1/kzrmeomy/public_html/website_ce6ca565",
        "pages": [
            {"id": 137, "slug": "tickets-tours",   "page_class": "att-tickets-page"},
            {"id": 136, "slug": "plan-your-visit",  "page_class": "att-plan-page"},
            {"id": 138, "slug": "what-to-see",      "page_class": "att-see-page"},
        ],
    },
    {
        "name": "operagarnier-guide.com",
        "ssh_key": SSH_KEY_S1,
        "ssh_host": SSH_HOST_S1,
        "wp_path": "/home1/kzrmeomy/public_html/website_b9cdec12",
        "pages": [
            {"id": 131, "slug": "tickets-tours",   "page_class": "att-tickets-page"},
            {"id": 130, "slug": "plan-your-visit",  "page_class": "att-plan-page"},
            {"id": 132, "slug": "what-to-see",      "page_class": "att-see-page"},
        ],
    },
    {
        "name": "montsaintmichel-guide.com",
        "ssh_key": SSH_KEY_S2,
        "ssh_host": SSH_HOST_S2,
        "wp_path": "/home1/dpskbcmy/public_html/website_58b542cb",
        "pages": [
            {"id": 67,  "slug": "tickets",          "page_class": "att-tickets-page"},
            {"id": 66,  "slug": "plan-your-visit",  "page_class": "att-plan-page"},
            {"id": 68,  "slug": "what-to-see",      "page_class": "att-see-page"},
        ],
    },
]


def ssh_opts(key):
    return f"-i {key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"


def ssh(host, key, cmd):
    full = f'SSH_AUTH_SOCK="" ssh {ssh_opts(key)} {host} {cmd!r}'
    r = subprocess.run(full, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"SSH failed [{r.returncode}]: {r.stderr.strip()}")
    return r.stdout


def scp(key, local, host, remote):
    cmd = f'SSH_AUTH_SOCK="" scp {ssh_opts(key)} {local} {host}:{remote}'
    subprocess.run(cmd, shell=True, check=True, capture_output=True)


def fix_double_selector(content, page_class):
    """Replace .page-class .page-class .att-container with .page-class .att-container"""
    pattern = rf'(\.{re.escape(page_class)})\s+\.{re.escape(page_class)}\s+(\.att-container)'
    fixed = re.sub(pattern, r'\1 \2', content)
    return fixed


def process_page(site, page):
    host = site["ssh_host"]
    key = site["ssh_key"]
    wp = site["wp_path"]
    pid = page["id"]
    slug = page["slug"]
    cls = page["page_class"]

    print(f"\n[{site['name']}] {slug} (ID {pid})")

    content = ssh(host, key, f"wp post get {pid} --field=post_content --path={wp} 2>/dev/null")

    if not content.strip():
        print(f"  SKIP: empty content")
        return

    fixed = fix_double_selector(content, cls)

    if fixed == content:
        print(f"  OK: no double selector found — already clean")
        return

    # Count how many replacements
    pattern = rf'(\.{re.escape(cls)})\s+\.{re.escape(cls)}\s+(\.att-container)'
    matches = len(re.findall(pattern, content))
    print(f"  MATCH: {matches} double-selector occurrence(s) → will fix")

    if DRY_RUN:
        print(f"  DRY-RUN: skipping DB write")
        # Show before/after for the affected line
        for line in content.splitlines():
            if re.search(pattern, line):
                print(f"    BEFORE: {line.strip()}")
        for line in fixed.splitlines():
            if f".{cls} .att-container" in line and f".{cls} .{cls}" not in line:
                if "att-container" in line and "48px" in line:
                    print(f"    AFTER:  {line.strip()}")
        return

    # Write HTML to temp file, SCP, then wp eval-file
    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp_html.write(fixed)
    tmp_html.close()

    php = f'<?php wp_update_post(array("ID"=>{pid},"post_content"=>file_get_contents("/tmp/fixds_{pid}.html"))); echo "Updated {pid}\\n";'
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp_php.write(php)
    tmp_php.close()

    try:
        scp(key, tmp_html.name, host, f"/tmp/fixds_{pid}.html")
        scp(key, tmp_php.name, host, f"/tmp/fixds_{pid}.php")
        result = ssh(host, key, f"wp eval-file /tmp/fixds_{pid}.php --path={wp} 2>/dev/null; rm -f /tmp/fixds_{pid}.html /tmp/fixds_{pid}.php")
        print(f"  DONE: {result.strip()}")
    finally:
        os.unlink(tmp_html.name)
        os.unlink(tmp_php.name)

    # Flush cache
    try:
        ssh(host, key, f"wp cache flush --path={wp} 2>/dev/null")
        print(f"  CACHE: flushed")
    except Exception:
        pass


def main():
    mode = "DRY-RUN" if DRY_RUN else "LIVE"
    print(f"=== fix-double-selector [{mode}] ===")
    print(f"Sites: {len(SITES)}, Pages per site: 3, Total: 9\n")

    for site in SITES:
        print(f"\n{'='*50}")
        print(f"Site: {site['name']}")
        for page in site["pages"]:
            process_page(site, page)

    print(f"\n=== Done ===")


if __name__ == "__main__":
    main()
