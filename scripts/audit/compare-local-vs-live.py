#!/usr/bin/env python3
"""
Compare local HTML files vs live WordPress posts for vangoghmuseum-guide.com.
Extracts H2 headings from both, diffs them, writes key:value report.

Usage:
    python3 scripts/audit/compare-local-vs-live.py \
        --local-dir output/van-gogh \
        --out output/van-gogh/local-vs-live-comparison.md
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

SSH_HOST = "50.6.155.174"
SSH_USER = "dpskbcmy"
SSH_KEY  = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
WP_PATH  = "/home1/dpskbcmy/public_html/website_da6eadef"
LIVE_DOMAIN = "https://vangoghmuseum-guide.com"

# Slug → URL path for L1 pages and homepage
L1_URL_MAP = {
    "homepage":       "/",
    "plan-your-visit": "/plan-your-visit/",
    "tickets-tours":   "/tickets/",
    "what-to-see":     "/what-to-see/",
}

# Dir name → URL prefix for L2 articles
DIR_TO_URL_PREFIX = {
    "plan-your-visit": "/plan-your-visit/",
    "tickets-tours":   "/tickets/",
    "what-to-see":     "/what-to-see/",
}


def ssh(cmd):
    result = subprocess.run(
        ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=15", f"{SSH_USER}@{SSH_HOST}", cmd],
        capture_output=True, text=True,
        env={**os.environ, "SSH_AUTH_SOCK": ""}
    )
    return result.stdout.strip()


def scp_to_remote(local_path, remote_path):
    subprocess.run(
        ["scp", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
         local_path, f"{SSH_USER}@{SSH_HOST}:{remote_path}"],
        capture_output=True,
        env={**os.environ, "SSH_AUTH_SOCK": ""}
    )


def fetch_all_live_posts():
    php = r"""<?php
$posts = get_posts([
    'post_type'   => ['page','post'],
    'post_status' => 'any',
    'numberposts' => -1,
    'fields'      => 'all',
]);
$out = [];
foreach ($posts as $p) {
    $out[] = [
        'id'      => $p->ID,
        'slug'    => $p->post_name,
        'type'    => $p->post_type,
        'content' => $p->post_content,
    ];
}
echo json_encode($out);
"""
    with tempfile.NamedTemporaryFile(suffix=".php", mode="w", delete=False) as f:
        f.write(php)
        local_php = f.name

    remote_php = "/tmp/compare_local_live.php"
    scp_to_remote(local_php, remote_php)
    os.unlink(local_php)

    raw = ssh(f"wp eval-file '{remote_php}' --path='{WP_PATH}' 2>/dev/null; rm -f '{remote_php}'")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        print(f"ERROR: could not parse JSON from WP. Raw output:\n{raw[:500]}", file=sys.stderr)
        sys.exit(1)


def extract_h2s(html):
    html = re.sub(r'<style[^>]*>.*?</style>', '', html, flags=re.DOTALL)
    matches = re.findall(r'<h2(?:\s[^>]*)?>(.+?)</h2>', html, flags=re.DOTALL)
    result = []
    for m in matches:
        text = re.sub(r'<[^>]+>', '', m)
        text = text.replace('&rarr;', '→').replace('&mdash;', '—').replace('&ndash;', '–')
        text = text.replace('&amp;', '&').replace('&rsquo;', "'").replace('&ldquo;', '"').replace('&rdquo;', '"')
        text = re.sub(r'\s+', ' ', text).strip()
        # Skip FAQ title — appears on all pages identically
        if re.search(r'frequently asked questions', text, re.I) and len(text) < 40:
            continue
        if text:
            result.append(text)
    return result


def build_local_map(local_dir):
    """Returns {slug: (filepath, live_url_path)}"""
    result = {}

    # Homepage
    hp = os.path.join(local_dir, "homepage.html")
    if os.path.exists(hp):
        result["homepage"] = (hp, "/")

    # L1 pages
    l1_dir = os.path.join(local_dir, "l1-pages")
    for fname in os.listdir(l1_dir) if os.path.isdir(l1_dir) else []:
        if not fname.endswith(".html"):
            continue
        stem = fname[:-5]
        fpath = os.path.join(l1_dir, fname)
        url = L1_URL_MAP.get(stem)
        if url:
            # Use stem for homepage/l1, but slug is the URL slug
            slug = stem if stem != "tickets-tours" else "tickets"
            slug = slug if slug != "homepage" else "homepage"
            result[slug] = (fpath, url)

    # L2 articles
    l2_dir = os.path.join(local_dir, "l2-articles")
    for dir_name in os.listdir(l2_dir) if os.path.isdir(l2_dir) else []:
        dir_path = os.path.join(l2_dir, dir_name)
        if not os.path.isdir(dir_path):
            continue
        url_prefix = DIR_TO_URL_PREFIX.get(dir_name, f"/{dir_name}/")
        for fname in os.listdir(dir_path):
            if not fname.endswith(".html"):
                continue
            stem = fname[:-5]
            fpath = os.path.join(dir_path, fname)
            result[stem] = (fpath, f"{url_prefix}{stem}/")

    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-dir", default="output/van-gogh")
    parser.add_argument("--out", default="output/van-gogh/local-vs-live-comparison.md")
    args = parser.parse_args()

    local_dir = os.path.abspath(args.local_dir)
    out_path  = os.path.abspath(args.out)

    print("Building local file map...")
    local_map = build_local_map(local_dir)
    print(f"  {len(local_map)} local files found")

    print("Fetching all live WP posts...")
    live_posts = fetch_all_live_posts()
    print(f"  {len(live_posts)} live posts fetched")

    # Build live map: slug → (post_id, url_path, content)
    live_map = {}
    for p in live_posts:
        slug = p["slug"]
        # Determine URL path from slug (heuristic)
        if slug in ("homepage", "home"):
            url = "/"
        elif slug in ("plan-your-visit", "tickets", "what-to-see"):
            url = f"/{slug}/"
        else:
            # Look in local_map for URL
            if slug in local_map:
                url = local_map[slug][1]
            else:
                url = f"/{slug}/"  # fallback
        live_map[slug] = (p["id"], url, p["content"])

    # All slugs across both sets
    all_slugs = sorted(set(list(local_map.keys()) + list(live_map.keys())))

    lines = ["# Local vs Live Comparison — vangoghmuseum-guide.com\n\n"]

    for slug in all_slugs:
        has_local = slug in local_map
        has_live  = slug in live_map

        local_file = local_map[slug][0] if has_local else ""
        local_url  = local_map[slug][1] if has_local else (live_map[slug][1] if has_live else f"/{slug}/")
        live_url   = LIVE_DOMAIN + local_url

        local_h2s = []
        live_h2s  = []

        if has_local:
            with open(local_map[slug][0], encoding="utf-8") as f:
                local_h2s = extract_h2s(f.read())

        if has_live:
            live_h2s = extract_h2s(live_map[slug][2])

        local_only = [h for h in local_h2s if h not in live_h2s]
        live_only  = [h for h in live_h2s  if h not in local_h2s]

        rel_local = os.path.relpath(local_file, start=os.path.dirname(out_path)) if local_file else ""

        lines.append(f"## {slug}\n")
        lines.append(f"local_file: {rel_local}\n")
        lines.append(f"live_url: {live_url}\n")

        if local_only:
            lines.append("in_local_only:\n")
            for h in local_only:
                lines.append(f"  - {h}\n")
        else:
            lines.append("in_local_only:\n")

        if live_only:
            lines.append("in_live_only:\n")
            for h in live_only:
                lines.append(f"  - {h}\n")
        else:
            lines.append("in_live_only:\n")

        lines.append("\n---\n\n")

    with open(out_path, "w", encoding="utf-8") as f:
        f.writelines(lines)

    print(f"\nReport written to: {out_path}")
    print(f"Total entries: {len(all_slugs)}")


if __name__ == "__main__":
    main()
