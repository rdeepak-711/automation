#!/usr/bin/env python3
"""
Fix card images on the homepage and L1 pages — replaces placeholder/wrong
images with each post's actual featured image, matched by the nearest
internal article href in the card.

Handles ALL image classes:
  att-hero__img       — page hero banner
  att-article-card__img — 3-col article grid cards
  att-featured__img   — top highlights / featured horizontal cards
  att-ticket__img     — ticket grid cards (homepage + L1)
  att-highlight__img  — highlight grid (homepage)
  att-crosslink__img  — cross-link cards between silos

Strategy: for each placeholder img, scan forward up to 2000 chars to find
the nearest internal /category/slug/ href, then replace with that post's
featured image. This works for all card types regardless of whether the
img is inside or outside the <a> tag.

Hero images and crosslink images use the per-page hero URLs passed as args 3-6.
Crosslinks are always updated to the designated hero regardless of current src.

Usage:
    python3 17-fix-l1-card-images.py <wp_path> <site_url> [homepage_img] [tickets_img] [plan_your_visit_img] [what_to_see_img]

Example:
    python3 17-fix-l1-card-images.py /home1/kzrmeomy/public_html/website_ce6ca565 https://auschwitz-guide.com
    python3 17-fix-l1-card-images.py /home1/dpskbcmy/public_html/website_204db6f9 https://hagiasophia-guide.com https://... https://... https://... https://...
"""

import subprocess, re, sys

PLACEHOLDER_GIF = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

def usage():
    print(__doc__)
    sys.exit(1)

if len(sys.argv) < 3:
    usage()

WP_PATH  = sys.argv[1].rstrip("/")
SITE_URL = sys.argv[2].rstrip("/")
SITE_DOMAIN = re.sub(r"^https?://(?:www\.)?", "", SITE_URL)

# Optional per-page hero images (args 3-6)
PAGE_HERO_IMGS = {}
if len(sys.argv) >= 7:
    for slug, url in zip(
        ["homepage", "tickets", "plan-your-visit", "what-to-see"],
        sys.argv[3:7]
    ):
        if url.strip():
            PAGE_HERO_IMGS[slug] = url.strip()

if PAGE_HERO_IMGS:
    print(f"Hero images provided for: {list(PAGE_HERO_IMGS.keys())}")
else:
    print("No hero images provided — will use post featured image fallback for heroes/crosslinks")

# Matches internal hrefs with 2+ path segments: /silo/slug/ or https://domain/silo/slug/
# Trailing slash is optional (some cards omit it)
ARTICLE_HREF = re.compile(
    r'href="(?:https?://(?:www\.)?' + re.escape(SITE_DOMAIN) + r')?(/[a-z0-9-]+/[a-z0-9-]+/?)"'
)

def wp(*args):
    result = subprocess.run(
        ["wp", "--path=" + WP_PATH] + list(args),
        capture_output=True, text=True
    )
    return result.stdout.strip()

# ── Build slug → featured image URL map ─────────────────────────────────────
print("Building slug → image map...")
posts_csv = wp("post", "list", "--post_type=post", "--format=csv",
               "--fields=ID,post_name", "--posts_per_page=500")
slug_img = {}          # post_slug → image URL
cat_first_img = {}     # category_slug → first available image URL in that cat

for line in posts_csv.splitlines()[1:]:
    parts = line.split(",", 1)
    if len(parts) != 2:
        continue
    post_id, post_slug = parts[0].strip(), parts[1].strip()
    thumb_id = wp("post", "meta", "get", post_id, "_thumbnail_id")
    if not thumb_id:
        continue
    img_url = wp("post", "get", thumb_id, "--field=guid")
    if not img_url:
        continue
    slug_img[post_slug] = img_url
    # Track first available image per category (fallback when no hero provided)
    cats = wp("post", "term", "list", post_id, "category",
              "--fields=slug", "--format=csv").splitlines()
    for cat in cats[1:]:  # skip header
        cat = cat.strip()
        if cat and cat not in cat_first_img:
            cat_first_img[cat] = img_url

print(f"  {len(slug_img)} posts with featured images")
print(f"  Categories with images: {list(cat_first_img.keys())}")
if not slug_img:
    print("  WARNING: No posts have featured images — nothing to do")
    sys.exit(0)

# First available image as last-resort fallback
_first_img = next(iter(slug_img.values()))

def get_slug_from_href(href):
    """Extract last path segment from an internal href."""
    parts = [p for p in href.strip("/").split("/") if p]
    return parts[-1] if len(parts) >= 2 else None

def get_cat_from_href(href):
    """Extract first path segment (category) from an internal href."""
    parts = [p for p in href.strip("/").split("/") if p]
    return parts[0] if parts else None

# L1-page slugs — crosslinks pointing to these use hero or silo fallback image
L1_SLUGS = {"tickets", "tickets-tours", "plan-your-visit", "what-to-see",
            "homepage", "home", "tickets-and-tours"}

def find_best_image(text_window, allow_l1_fallback=True):
    """
    Scan text_window for the nearest internal href, try to match to a post image.
    - /category/slug/  → direct post lookup
    - /category/       → hero image if provided, else first image in that category silo
      (only when allow_l1_fallback=True — crosslinks only; not for article/highlight cards)
    Returns (label, img_url) or (None, None).
    """
    # First pass: try article links (2 segments) → direct post match
    for m in ARTICLE_HREF.finditer(text_window):
        slug = get_slug_from_href(m.group(1))
        if slug and slug in slug_img:
            return slug, slug_img[slug]

    if not allow_l1_fallback:
        return None, None

    # Second pass: try any internal href — including L1 page links (1 segment)
    any_href = re.compile(r'href="(?:https?://(?:www\.)?' + re.escape(SITE_DOMAIN) + r')?(/[a-z0-9-]+/?)"')
    for m in any_href.finditer(text_window):
        cat = get_cat_from_href(m.group(1))
        if not cat:
            continue
        if cat not in L1_SLUGS:
            continue  # skip non-L1 single-segment hrefs — not reliable
        # Use designated hero image if provided, else silo fallback
        if cat in PAGE_HERO_IMGS:
            return f"{cat} (hero)", PAGE_HERO_IMGS[cat]
        if cat in cat_first_img:
            return f"{cat} (silo fallback)", cat_first_img[cat]

    return None, None

def fix_placeholders_in_content(content, page_label, page_slug):
    """
    Replace all placeholder images in content.
    Scans forward 2000 chars after each placeholder to find its article href.
    Returns (new_content, fixed_count, remaining_count).
    """
    # Hero image for this specific page
    hero_img = PAGE_HERO_IMGS.get(page_slug, _first_img)

    fixed = 0
    offset = 0
    new_content = content

    while True:
        pos = new_content.find(PLACEHOLDER_GIF, offset)
        if pos == -1:
            break

        # Get image class for logging — look back up to 600 chars (multi-line img tags)
        before = new_content[max(0, pos-600):pos]
        cls_match = re.search(r'class="([^"]*att-[a-z_-]+__img[^"]*)"', before)
        cls = cls_match.group(1) if cls_match else "unknown"

        # Scan forward to find article href
        # L1 hero fallback only for crosslink images — not article/highlight cards
        _article_classes = ("att-article-card__img", "att-highlight__img", "att-featured__img", "att-ticket__img")
        _allow_l1 = not any(c in cls for c in _article_classes)
        window = new_content[pos:pos + 2000]
        slug, img_url = find_best_image(window, allow_l1_fallback=_allow_l1)

        if img_url:
            new_content = new_content[:pos] + img_url + new_content[pos + len(PLACEHOLDER_GIF):]
            fixed += 1
            print(f"  ✓ {cls}: {slug} → {img_url.split('/')[-1]}")
            # Don't advance offset — string is shorter now, recheck same pos
        else:
            # No article link found — use hero fallback
            if "att-hero__img" in cls:
                new_content = new_content[:pos] + hero_img + new_content[pos + len(PLACEHOLDER_GIF):]
                fixed += 1
                print(f"  ✓ {cls}: hero → {hero_img.split('/')[-1]}")
            else:
                print(f"  ✗ {cls}: no matching post with featured image")
                offset = pos + len(PLACEHOLDER_GIF)

    remaining = new_content.count(PLACEHOLDER_GIF)
    return new_content, fixed, remaining

def fix_crosslink_images(content):
    """
    Update att-crosslink__img srcs to use designated hero images.
    Runs on every page regardless of placeholder presence — ensures
    crosslinks always show the correct silo hero image.
    Only updates if PAGE_HERO_IMGS is populated.
    """
    if not PAGE_HERO_IMGS:
        return content, 0

    fixed = 0

    def replacer(m):
        nonlocal fixed
        block = m.group(0)
        href_m = re.search(r'href="/([\w-]+)/?"', block)
        if not href_m:
            return block
        silo = href_m.group(1)
        if silo not in PAGE_HERO_IMGS:
            return block
        new_block = re.sub(
            r'(<img[^>]*class="att-crosslink__img"[^>]*)src="[^"]*"',
            lambda im: im.group(1) + f'src="{PAGE_HERO_IMGS[silo]}"',
            block
        )
        if new_block != block:
            fixed += 1
            print(f"  ✓ att-crosslink__img → {silo}: {PAGE_HERO_IMGS[silo].split('/')[-1]}")
        return new_block

    new_content = re.sub(
        r'<div class="att-crosslink">.*?</div>\s*</div>',
        replacer, content, flags=re.DOTALL
    )
    return new_content, fixed

def fix_hero_image(content, page_slug):
    """
    Update att-hero__img src to the designated hero image for this page.
    Runs regardless of placeholder presence — ensures hero is always correct.
    Only updates if PAGE_HERO_IMGS has an entry for this page.
    """
    if page_slug not in PAGE_HERO_IMGS:
        return content, 0

    hero_url = PAGE_HERO_IMGS[page_slug]
    new_content = re.sub(
        r'(<img[^>]*class="att-hero__img"[^>]*)src="[^"]*"',
        lambda m: m.group(1) + f'src="{hero_url}"',
        content
    )
    # Also handle src-before-class order
    new_content = re.sub(
        r'(<img[^>]*)src="[^"]*"([^>]*class="att-hero__img")',
        lambda m: m.group(1) + f'src="{hero_url}"' + m.group(2),
        new_content
    )
    changed = 1 if new_content != content else 0
    if changed:
        print(f"  ✓ att-hero__img → {hero_url.split('/')[-1]}")
    return new_content, changed

def save_page(page_id, content):
    proc = subprocess.run(
        ["wp", "--path=" + WP_PATH, "post", "update", page_id,
         "--post_content=" + content],
        capture_output=True, text=True
    )
    if proc.returncode == 0:
        print(f"  Saved OK")
    else:
        print(f"  SAVE FAILED: {proc.stderr[:300]}")

# ── Get all pages to process ─────────────────────────────────────────────────
pages_csv = wp("post", "list", "--post_type=page", "--format=csv",
               "--fields=ID,post_name", "--posts_per_page=50")

SKIP_SLUGS = {"about-us", "contact-us", "privacy-policy", "terms", "sitemap"}
pages_to_fix = []
for line in pages_csv.splitlines()[1:]:
    parts = line.split(",", 1)
    if len(parts) != 2:
        continue
    page_id, page_slug = parts[0].strip(), parts[1].strip()
    if page_slug not in SKIP_SLUGS:
        pages_to_fix.append((page_id, page_slug))

print(f"\nPages to process: {[s for _, s in pages_to_fix]}")

total_fixed = 0
total_remaining = 0

for page_id, page_slug in pages_to_fix:
    print(f"\n=== Page {page_id} ({page_slug}) ===")
    content = wp("post", "get", page_id, "--field=post_content")
    changed = False

    # Pass 1: fix placeholder GIFs
    placeholder_count = content.count(PLACEHOLDER_GIF)
    if placeholder_count > 0:
        print(f"  Placeholders found: {placeholder_count}")
        content, fixed, remaining = fix_placeholders_in_content(content, page_slug, page_slug)
        total_fixed += fixed
        total_remaining += remaining
        print(f"  Fixed: {fixed} | Remaining: {remaining}")
        if fixed > 0:
            changed = True

    # Pass 2: force-set hero image to designated URL
    content, hero_changed = fix_hero_image(content, page_slug)
    if hero_changed:
        changed = True

    # Pass 3: force-set crosslink images to silo hero URLs
    content, cross_fixed = fix_crosslink_images(content)
    if cross_fixed:
        total_fixed += cross_fixed
        changed = True

    if changed:
        save_page(page_id, content)
    else:
        print(f"  Nothing changed — skipping save")

# ── Flush all caches ─────────────────────────────────────────────────────────
print("\nFlushing caches...")
wp("cache", "flush")
wp("transient", "delete", "--all")
subprocess.run(
    ["bash", "-c",
     f"wp --path={WP_PATH} eval 'if(function_exists(\"rocket_clean_domain\")){{rocket_clean_domain();}} "
     f"if(function_exists(\"rocket_clean_minify\")){{rocket_clean_minify();}} opcache_reset();' 2>/dev/null || true"],
    capture_output=True
)
subprocess.run(
    ["bash", "-c",
     f"find {WP_PATH}/wp-content/cache/ -name '*.html' -delete 2>/dev/null; "
     f"find {WP_PATH}/wp-content/cache/ -name '*.html.gz' -delete 2>/dev/null"],
    capture_output=True
)

print(f"\n{'='*50}")
print(f"Total fixed: {total_fixed}")
print(f"Total remaining (no featured image): {total_remaining}")
print("Done.")
