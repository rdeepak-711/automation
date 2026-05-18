#!/usr/bin/env python3
"""
fix-card-images-from-wp.py

For each placeholder card image in a locally-generated HTML file, finds the
nearest internal article href, SSHes to the live WP site to look up that
post's featured image URL, then patches the local file.

One batched SSH call per run — no per-slug round-trips.

Usage:
    python3 scripts/post-launch/fix-card-images-from-wp.py <site-slug> [<html-file>]

    site-slug   e.g. wieliczka-salt-mine
    html-file   default: output/<site-slug>/homepage.html

Examples:
    python3 scripts/post-launch/fix-card-images-from-wp.py wieliczka-salt-mine
    python3 scripts/post-launch/fix-card-images-from-wp.py wieliczka-salt-mine output/wieliczka-salt-mine/l1-pages/tickets.html
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
PLACEHOLDER = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

# Card image classes we want to fix
CARD_IMG_CLASSES = (
    "att-ticket__img",
    "att-highlight__img",
    "att-article-card__img",
    "att-featured__img",
)


def load_env(path: Path) -> dict:
    env = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def ssh_run(host: str, user: str, key: str, command: str) -> str:
    result = subprocess.run(
        [
            "ssh",
            "-i", os.path.expanduser(key),
            "-o", "StrictHostKeyChecking=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            f"{user}@{host}",
            command,
        ],
        capture_output=True, text=True,
        env={**os.environ, "SSH_AUTH_SOCK": ""},
    )
    if result.returncode != 0 and result.stderr:
        print(f"  SSH stderr: {result.stderr[:300]}", file=sys.stderr)
    return result.stdout.strip()


def get_featured_images(slugs: list[str], wp_path: str, host: str, user: str, key: str) -> dict[str, str]:
    """One SSH session: bash loop over slugs, WP-CLI for each. No PHP eval needed."""
    if not slugs:
        return {}

    slug_args = " ".join(f'"{s}"' for s in slugs)
    bash = (
        f'WP="wp --path={wp_path}"\n'
        f'for slug in {slug_args}; do\n'
        '  id=$($WP post list --post_type=post --name="$slug" --field=ID --posts_per_page=1 2>/dev/null | head -1)\n'
        '  [ -z "$id" ] && continue\n'
        '  content=$($WP post get "$id" --field=post_content 2>/dev/null)\n'
        '  url=$(echo "$content" | grep -o \'class="att-article-header__image" src="[^"]*"\' | grep -o \'src="[^"]*"\' | sed \'s/src="//;s/"//\')\n'
        '  [ -z "$url" ] && url=$(echo "$content" | grep -o \'src="[^"]*" [^>]*class="att-article-header__image"\' | grep -o \'src="[^"]*"\' | sed \'s/src="//;s/"//\')\n'
        '  [ -n "$url" ] && [[ "$url" != data:* ]] && printf "%s\\t%s\\n" "$slug" "$url"\n'
        'done\n'
    )

    # Pipe bash script via stdin to remote bash — one SSH session, no quoting issues
    result = subprocess.run(
        [
            "ssh",
            "-i", os.path.expanduser(key),
            "-o", "StrictHostKeyChecking=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            f"{user}@{host}",
            "bash",
        ],
        input=bash, capture_output=True, text=True,
        env={**os.environ, "SSH_AUTH_SOCK": ""},
    )
    if result.returncode != 0 and result.stderr:
        print(f"  SSH stderr: {result.stderr[:300]}", file=sys.stderr)
    output = result.stdout.strip()

    result = {}
    for line in output.splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2:
            result[parts[0].strip()] = parts[1].strip()
    return result


def extract_slug_from_window(window: str, site_domain: str) -> str | None:
    """Scan forward text window for the nearest internal /category/slug/ href."""
    pattern = re.compile(
        r'href="(?:https?://(?:www\.)?' + re.escape(site_domain) + r')?(/[a-z0-9-]+/[a-z0-9-]+/?)"'
    )
    m = pattern.search(window)
    if not m:
        return None
    parts = [p for p in m.group(1).strip("/").split("/") if p]
    return parts[-1] if len(parts) >= 2 else None


def fix_html(html: str, slug_img: dict[str, str], site_domain: str) -> tuple[str, int, list[str]]:
    """Replace placeholder card images. Returns (new_html, fixed_count, missed_slugs)."""
    fixed = 0
    missed = []
    offset = 0
    result = html

    while True:
        pos = result.find(PLACEHOLDER, offset)
        if pos == -1:
            break

        # Identify class — look back up to 400 chars
        before = result[max(0, pos - 400):pos]
        cls_m = re.search(r'class="([^"]*att-[a-z_-]+__img[^"]*)"', before)
        cls = cls_m.group(1) if cls_m else ""

        # Only fix known card image classes (not hero)
        if not any(c in cls for c in CARD_IMG_CLASSES):
            offset = pos + len(PLACEHOLDER)
            continue

        # Scan forward up to 1500 chars for article href
        window = result[pos:pos + 1500]
        slug = extract_slug_from_window(window, site_domain)

        if slug and slug in slug_img:
            img_url = slug_img[slug]
            result = result[:pos] + img_url + result[pos + len(PLACEHOLDER):]
            fixed += 1
            print(f"  ✓ {cls.split()[-1]}: {slug} → {img_url.split('/')[-1]}")
            # Don't advance — string length changed, recheck same pos
        else:
            if slug:
                missed.append(slug)
                print(f"  ✗ {cls.split()[-1] if cls else '?'}: {slug} — no featured image on WP")
            else:
                print(f"  ✗ {cls.split()[-1] if cls else '?'}: no article href found nearby")
            offset = pos + len(PLACEHOLDER)

    return result, fixed, missed


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    site_slug = sys.argv[1]
    html_path = Path(sys.argv[2]) if len(sys.argv) >= 3 else REPO_ROOT / "output" / site_slug / "homepage.html"

    if not html_path.exists():
        print(f"ERROR: {html_path} not found")
        sys.exit(1)

    # Load site .env
    site_env = load_env(REPO_ROOT / "input" / site_slug / ".env")
    wp_path = site_env.get("WP_PATH", "")
    wp_server = site_env.get("WP_SERVER", "2")
    site_url = site_env.get("WP_SITE_URL", "")
    site_domain = re.sub(r"^https?://(?:www\.)?", "", site_url).rstrip("/")

    if not wp_path:
        print(f"ERROR: WP_PATH not set in input/{site_slug}/.env")
        sys.exit(1)

    # Load root .env for SSH creds
    root_env = load_env(REPO_ROOT / ".env")
    if wp_server == "1":
        host = root_env.get("WP_SSH_HOST", "50.6.109.30")
        user = root_env.get("WP_SSH_USER", "kzrmeomy")
        key  = root_env.get("WP_SSH_KEY", "~/.ssh/id_rsa_bluehost_old")
    else:
        host = root_env.get("WP_SSH_HOST2", "50.6.155.174")
        user = root_env.get("WP_SSH_USER2", "dpskbcmy")
        key  = root_env.get("WP_SSH_KEY2", "~/.ssh/id_rsa_bluehost2")

    print(f"Site:     {site_slug} ({site_domain})")
    print(f"File:     {html_path}")
    print(f"WP path:  {wp_path}")
    print(f"Server:   {user}@{host} (server {wp_server})")

    html = html_path.read_text(encoding="utf-8")

    # First pass: collect all slugs that need images
    placeholder_count = html.count(PLACEHOLDER)
    print(f"\nPlaceholders found: {placeholder_count}")
    if placeholder_count == 0:
        print("Nothing to do.")
        return

    slugs_needed = set()
    temp = html
    offset = 0
    while True:
        pos = temp.find(PLACEHOLDER, offset)
        if pos == -1:
            break
        before = temp[max(0, pos - 400):pos]
        cls_m = re.search(r'class="([^"]*att-[a-z_-]+__img[^"]*)"', before)
        cls = cls_m.group(1) if cls_m else ""
        if any(c in cls for c in CARD_IMG_CLASSES):
            window = temp[pos:pos + 1500]
            slug = extract_slug_from_window(window, site_domain)
            if slug:
                slugs_needed.add(slug)
        offset = pos + len(PLACEHOLDER)

    print(f"Slugs to look up: {sorted(slugs_needed)}")

    # One batched SSH call for all slugs
    print(f"\nFetching featured images from WP ({host})...")
    slug_img = get_featured_images(list(slugs_needed), wp_path, host, user, key)
    print(f"Found {len(slug_img)}/{len(slugs_needed)} featured images")
    for slug, url in slug_img.items():
        print(f"  {slug} → {url.split('/')[-1]}")

    # Second pass: replace
    print(f"\nPatching {html_path.name}...")
    new_html, fixed, missed = fix_html(html, slug_img, site_domain)

    if fixed == 0:
        print("Nothing replaced.")
        return

    html_path.write_text(new_html, encoding="utf-8")
    print(f"\nDone. Fixed {fixed} images. Saved {html_path}")
    if missed:
        print(f"Missing featured images for: {missed}")


if __name__ == "__main__":
    main()
