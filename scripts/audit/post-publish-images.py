#!/usr/bin/env python3
"""
post-publish-images.py — Sync WP featured images into L1/homepage page content.

Called by post-publish.sh. Uses SCP + wp eval-file pattern (same as configure-gp-menu-footer.py).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str]) -> str:
    env = os.environ.copy()
    env["SSH_AUTH_SOCK"] = ""
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"cmd failed: {cmd}")
    return proc.stdout


def build_ssh_scp(host: str, user: str, key: str, ctl: str) -> tuple[list[str], list[str]]:
    common = [
        "-i", key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=15", "-o", "ControlMaster=auto",
        "-o", f"ControlPath={ctl}", "-o", "ControlPersist=120",
    ]
    ssh_base = ["ssh"] + common + [f"{user}@{host}"]
    scp_base = ["scp"] + common
    return ssh_base, scp_base


def ssh_run(ssh_base: list[str], cmd: str) -> str:
    return run(ssh_base + [cmd])


def scp_to(scp_base: list[str], local: Path, user_host: str, remote: str) -> None:
    run(scp_base + [str(local), f"{user_host}:{remote}"])


def load_url_registry(site_slug: str) -> dict:
    path = ROOT / "output" / site_slug / "url-registry.json"
    if path.exists():
        return json.loads(path.read_text())
    return {}


def resolve_wp_slug(dir_name: str, registry: dict) -> str:
    """tickets-tours → tickets (via url-registry.json dir_to_url map)"""
    url = registry.get("dir_to_url", {}).get(dir_name, "")
    slug = url.strip("/").split("/")[-1] if url else ""
    return slug if slug else dir_name


def load_page_images(site_slug: str) -> dict[str, str]:
    path = ROOT / "input" / site_slug / "page-images.json"
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:
            return {}
    return {}


def prompt_hero(page_key: str) -> str | None:
    try:
        url = input(f"  Hero image URL for {page_key} (blank to skip): ").strip()
        return url if url else None
    except (EOFError, KeyboardInterrupt):
        return None


def build_image_map(ssh_base: list[str], scp_base: list[str],
                    user_host: str, wp_path: str) -> dict[str, str]:
    """SCP a PHP script to server, run via wp eval-file, return slug→url map."""
    php = """<?php
$posts = get_posts([
    'post_type'   => ['post', 'page'],
    'numberposts' => -1,
    'post_status' => 'any',
]);
$map = [];
foreach ($posts as $p) {
    $url = get_the_post_thumbnail_url($p->ID, 'full');
    if ($url) {
        $map[$p->post_name] = $url;
    }
}
echo json_encode($map, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
"""
    with tempfile.NamedTemporaryFile("w", suffix=".php", delete=False) as f:
        f.write(php)
        local = Path(f.name)
    remote = "/tmp/pp-imgmap.php"
    try:
        scp_to(scp_base, local, user_host, remote)
        out = ssh_run(
            ssh_base,
            f"wp eval-file {shlex.quote(remote)} --path={shlex.quote(wp_path)}"
            f" && rm -f {shlex.quote(remote)}",
        )
        return json.loads(out.strip())
    except Exception as e:
        print(f"  ⚠ Could not build image map: {e}", file=sys.stderr)
        return {}
    finally:
        local.unlink(missing_ok=True)


def find_page_id(ssh_base: list[str], wp_path: str, wp_slug: str) -> int | None:
    """Return WP page ID for given slug, or None if not found."""
    try:
        out = ssh_run(
            ssh_base,
            f"wp post list --post_type=page --name={shlex.quote(wp_slug)}"
            f" --fields=ID --format=csv --path={shlex.quote(wp_path)}"
            f" 2>/dev/null | tail -1",
        )
        val = out.strip()
        return int(val) if val.isdigit() else None
    except Exception:
        return None


def get_page_content(ssh_base: list[str], wp_path: str, post_id: int) -> str:
    return ssh_run(
        ssh_base,
        f"wp post get {post_id} --field=post_content --path={shlex.quote(wp_path)}",
    )


def extract_slug(href: str) -> str:
    """Last non-empty path segment: /tickets/entry-ticket/ → entry-ticket"""
    parts = [p for p in href.rstrip("/").split("/") if p]
    return parts[-1] if parts else ""


# Matches any <img> whose src is the 1x1 GIF placeholder
_PLACEHOLDER_IMG = re.compile(
    r'(<img\b[^>]*?)src="data:image/gif;base64,[^"]*"([^>]*/?>)',
    re.DOTALL,
)

# Maps hub URL slugs (/tickets/, /plan-your-visit/, /what-to-see/) to page_images keys
_HUB_SLUG_TO_PAGE_KEY = {
    "tickets":        "tickets-tours",
    "plan-your-visit": "plan-your-visit",
    "what-to-see":    "what-to-see",
}


def patch_content(
    content: str, img_map: dict[str, str], hero_url: str | None,
    page_images: dict[str, str] | None = None,
) -> tuple[str, int, list[str]]:
    """
    Replace placeholder img srcs with real featured image URLs.
    Returns (patched_content, count_replaced, missing_slugs).
    """
    warnings: list[str] = []
    count = 0
    result: list[str] = []
    pos = 0
    _page_images = page_images or {}

    for m in _PLACEHOLDER_IMG.finditer(content):
        result.append(content[pos : m.start()])
        img_tag = m.group(0)
        is_hero = "att-hero__img" in img_tag

        if is_hero:
            if hero_url:
                new_tag = m.group(1) + f'src="{hero_url}"' + m.group(2)
                result.append(new_tag)
                count += 1
            else:
                result.append(img_tag)
        else:
            # Find nearest href after img (within 600 chars)
            ahead = content[m.end() : m.end() + 600]
            href_m = re.search(r'href="(/[^"]+)"', ahead)
            if not href_m:
                # Try 200 chars before (img wrapped by link)
                behind = content[max(0, m.start() - 200) : m.start()]
                href_m = re.search(r'href="(/[^"]+)"', behind)

            if href_m:
                slug = extract_slug(href_m.group(1))
                if slug in img_map:
                    new_tag = m.group(1) + f'src="{img_map[slug]}"' + m.group(2)
                    result.append(new_tag)
                    count += 1
                elif slug in _HUB_SLUG_TO_PAGE_KEY:
                    # Crosslink to another L1 page — use that page's hero image
                    page_key = _HUB_SLUG_TO_PAGE_KEY[slug]
                    hub_url = _page_images.get(page_key)
                    if hub_url:
                        new_tag = m.group(1) + f'src="{hub_url}"' + m.group(2)
                        result.append(new_tag)
                        count += 1
                    else:
                        warnings.append(slug)
                        result.append(img_tag)
                else:
                    warnings.append(slug)
                    result.append(img_tag)
            else:
                result.append(img_tag)

        pos = m.end()

    result.append(content[pos:])
    return "".join(result), count, warnings


def push_page_content(
    ssh_base: list[str],
    scp_base: list[str],
    user_host: str,
    post_id: int,
    content: str,
    wp_path: str,
    dry_run: bool,
) -> bool:
    if dry_run:
        print(f"    [dry-run] would update post_content for page id={post_id}")
        return True

    # Write content to temp file, SCP to server, use wp eval-file to update post
    php = f"""<?php
$content = file_get_contents('/tmp/pp-content-{post_id}.html');
$result  = wp_update_post(['ID' => {post_id}, 'post_content' => $content]);
clean_post_cache({post_id});
echo is_wp_error($result) ? 'error:' . $result->get_error_message() : 'ok:' . $result;
"""
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(content)
        content_local = Path(f.name)
    with tempfile.NamedTemporaryFile("w", suffix=".php", delete=False) as f:
        f.write(php)
        php_local = Path(f.name)

    content_remote = f"/tmp/pp-content-{post_id}.html"
    php_remote = f"/tmp/pp-update-{post_id}.php"
    try:
        scp_to(scp_base, content_local, user_host, content_remote)
        scp_to(scp_base, php_local, user_host, php_remote)
        out = ssh_run(
            ssh_base,
            f"wp eval-file {shlex.quote(php_remote)} --path={shlex.quote(wp_path)}"
            f" && rm -f {shlex.quote(php_remote)} {shlex.quote(content_remote)}",
        )
        return out.strip().startswith("ok:")
    except Exception as e:
        print(f"    ⚠ Push failed for page id={post_id}: {e}", file=sys.stderr)
        return False
    finally:
        content_local.unlink(missing_ok=True)
        php_local.unlink(missing_ok=True)


# The 4 pages we sync, in order
PAGES = [
    {"key": "homepage",        "dir_name": "homepage"},
    {"key": "tickets-tours",   "dir_name": "tickets-tours"},
    {"key": "plan-your-visit", "dir_name": "plan-your-visit"},
    {"key": "what-to-see",     "dir_name": "what-to-see"},
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site-slug",   required=True)
    parser.add_argument("--wp-path",     required=True)
    parser.add_argument("--wp-ssh-host", required=True)
    parser.add_argument("--wp-ssh-user", required=True)
    parser.add_argument("--wp-ssh-key",  required=True)
    parser.add_argument("--ssh-ctl",     required=True)
    parser.add_argument("--dry-run",     action="store_true")
    args = parser.parse_args()

    ssh_base, scp_base = build_ssh_scp(
        args.wp_ssh_host, args.wp_ssh_user, args.wp_ssh_key, args.ssh_ctl
    )
    user_host = f"{args.wp_ssh_user}@{args.wp_ssh_host}"

    # 1. Build slug → featured image URL map
    img_map = build_image_map(ssh_base, scp_base, user_host, args.wp_path)
    if not img_map:
        print("  ⚠ Image map is empty — posts may lack featured images. Skipping image sync.")
        return
    print(f"  ✓ Image map built: {len(img_map)} posts with featured images")

    # 2. Load page-level hero URLs + url-registry for slug resolution
    page_images = load_page_images(args.site_slug)
    registry    = load_url_registry(args.site_slug)

    # 3. Process each page
    for page in PAGES:
        key      = page["key"]
        dir_name = page["dir_name"]
        wp_slug  = resolve_wp_slug(dir_name, registry)

        print(f"\n  ── {key} (wp slug: {wp_slug}) ──")

        # Resolve hero image (from json or interactive prompt)
        hero_url: str | None = page_images.get(key)
        if not hero_url and not args.dry_run:
            hero_url = prompt_hero(key)

        # Find page ID in WP
        post_id = find_page_id(ssh_base, args.wp_path, wp_slug)
        if post_id is None:
            print(f"    ⚠ Page not found in WP (slug={wp_slug}). Skipping.")
            continue
        print(f"    Page id={post_id}")

        # Fetch content
        try:
            content = get_page_content(ssh_base, args.wp_path, post_id)
        except Exception as e:
            print(f"    ⚠ Could not fetch content: {e}")
            continue

        # Patch images
        patched, n_replaced, missing = patch_content(content, img_map, hero_url, page_images)

        if hero_url:
            print(f"    ✓ Hero image set")
        else:
            print(f"    ⚠ No hero image (add to input/{args.site_slug}/page-images.json)")

        print(f"    ✓ {n_replaced} card image(s) updated")
        for slug in missing:
            print(f"    ⚠ No featured image for: {slug}")

        if patched == content:
            print(f"    — No changes (images already set or no placeholders found)")
        else:
            # Push back
            ok = push_page_content(
                ssh_base, scp_base, user_host,
                post_id, patched, args.wp_path, args.dry_run,
            )
            if ok:
                print(f"    ✓ Page updated in WordPress")
            else:
                print(f"    ✗ Failed to update page id={post_id}")

        # Set featured image on the page itself
        if hero_url:
            set_page_featured_image(ssh_base, args.wp_path, post_id, hero_url, args.dry_run)


def set_page_featured_image(
    ssh_base: list[str], wp_path: str, post_id: int, image_url: str, dry_run: bool
) -> None:
    """Find the attachment by URL and set it as the featured image for the page."""
    if dry_run:
        print(f"    [dry-run] would set featured image for page id={post_id}")
        return
    try:
        # Look up attachment ID by matching the filename in the guid
        filename = image_url.rstrip("/").split("/")[-1]
        att_id = ssh_run(
            ssh_base,
            f"wp db query \"SELECT ID FROM wp_posts WHERE post_type='attachment'"
            f" AND guid LIKE '%{filename}%' LIMIT 1;\""
            f" --skip-column-names --path={shlex.quote(wp_path)} 2>/dev/null",
        ).strip()
        if not att_id or not att_id.isdigit():
            print(f"    ⚠ Featured image attachment not found for: {filename}")
            return
        ssh_run(
            ssh_base,
            f"wp post meta update {post_id} _thumbnail_id {att_id}"
            f" --path={shlex.quote(wp_path)}",
        )
        print(f"    ✓ Featured image set (attachment id={att_id})")
    except Exception as e:
        print(f"    ⚠ Could not set featured image: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
