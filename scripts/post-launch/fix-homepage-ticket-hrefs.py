#!/usr/bin/env python3
"""
Fix ticket card hrefs on the homepage that are missing the category prefix.
e.g. /audio-guide/ -> /tickets/audio-guide/

Scans all att-ticket__card blocks on the homepage, finds any href with only
one path segment, looks up the post's actual category, and rewrites the href.
Then re-runs image fix for those cards.

Usage:
    python3 fix-homepage-ticket-hrefs.py <wp_path> <site_url>
"""

import subprocess, re, sys, os, tempfile

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)

WP_PATH  = sys.argv[1].rstrip("/")
SITE_URL = sys.argv[2].rstrip("/")
SITE_DOMAIN = re.sub(r"^https?://(?:www\.)?", "", SITE_URL)

PLACEHOLDER_GIF = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

def wp(*args):
    result = subprocess.run(
        ["wp", "--path=" + WP_PATH] + list(args),
        capture_output=True, text=True
    )
    return result.stdout.strip()

def save_page(page_id, content):
    tmp = f"/tmp/wp_page_{page_id}.html"
    with open(tmp, "w") as f:
        f.write(content)
    proc = subprocess.run(
        ["wp", "--path=" + WP_PATH, "eval",
         f"wp_update_post(['ID'=>{page_id},'post_content'=>file_get_contents('{tmp}')]);"],
        capture_output=True, text=True
    )
    try:
        os.unlink(tmp)
    except OSError:
        pass
    if proc.returncode == 0:
        print(f"  Saved OK")
    else:
        print(f"  SAVE FAILED: {proc.stderr[:300]}")

# Build slug -> category map for all posts
print("Building slug → category map...")
posts_csv = wp("post", "list", "--post_type=post", "--format=csv",
               "--fields=ID,post_name", "--posts_per_page=500")

slug_cat = {}   # post_slug -> category_slug
slug_img = {}   # post_slug -> featured image URL

for line in posts_csv.splitlines()[1:]:
    parts = line.split(",", 1)
    if len(parts) != 2:
        continue
    post_id, post_slug = parts[0].strip(), parts[1].strip()
    cats = wp("post", "term", "list", post_id, "category",
              "--fields=slug", "--format=csv").splitlines()
    for cat in cats[1:]:
        cat = cat.strip()
        if cat and cat != "uncategorized":
            slug_cat[post_slug] = cat
            break
    thumb_id = wp("post", "meta", "get", post_id, "_thumbnail_id")
    if thumb_id:
        img_url = wp("post", "get", thumb_id, "--field=guid")
        if img_url:
            slug_img[post_slug] = img_url

print(f"  {len(slug_cat)} posts mapped")

# Get homepage
pages_csv = wp("post", "list", "--post_type=page", "--format=csv",
               "--fields=ID,post_name", "--posts_per_page=50")
homepage_id = None
for line in pages_csv.splitlines()[1:]:
    parts = line.split(",", 1)
    if len(parts) == 2 and parts[1].strip() == "homepage":
        homepage_id = parts[0].strip()
        break

if not homepage_id:
    print("❌ Could not find homepage page")
    sys.exit(1)

print(f"\nHomepage ID: {homepage_id}")
content = wp("post", "get", homepage_id, "--field=post_content")

# Find single-segment hrefs (missing category prefix) and fix them
# Match href="/slug/" where slug has no slashes inside
SINGLE_SEG = re.compile(r'href="/([a-z0-9-]+)/"')
fixed_hrefs = 0
not_found = []

def fix_href(m):
    global fixed_hrefs
    slug = m.group(1)
    # Skip L1 page slugs and anchors
    if slug in {"tickets", "plan-your-visit", "what-to-see", "homepage",
                "about-us", "contact-us", "privacy-policy", "sitemap"}:
        return m.group(0)
    if slug in slug_cat:
        cat = slug_cat[slug]
        new_href = f'href="/{cat}/{slug}/"'
        print(f"  ✓ /{slug}/ → /{cat}/{slug}/")
        fixed_hrefs += 1
        return new_href
    else:
        not_found.append(slug)
        return m.group(0)

new_content = SINGLE_SEG.sub(fix_href, content)

if not_found:
    print(f"  ✗ Could not find category for: {not_found}")

if fixed_hrefs == 0:
    print("  No single-segment hrefs found to fix")
    sys.exit(0)

# Now fix placeholder images in the updated content
print(f"\nFixing images for {fixed_hrefs} corrected cards...")

def find_img(text_window):
    href_re = re.compile(r'href="/[a-z0-9-]+/([a-z0-9-]+)/"')
    for m in href_re.finditer(text_window):
        slug = m.group(1)
        if slug in slug_img:
            return slug, slug_img[slug]
    return None, None

offset = 0
img_fixed = 0
while True:
    pos = new_content.find(PLACEHOLDER_GIF, offset)
    if pos == -1:
        break
    before = new_content[max(0, pos-600):pos]
    cls_match = re.search(r'class="([^"]*att-ticket__img[^"]*)"', before)
    if not cls_match:
        offset = pos + len(PLACEHOLDER_GIF)
        continue
    window = new_content[pos:pos + 2000]
    slug, img_url = find_img(window)
    if img_url:
        new_content = new_content[:pos] + img_url + new_content[pos + len(PLACEHOLDER_GIF):]
        print(f"  ✓ att-ticket__img: {slug} → {img_url.split('/')[-1]}")
        img_fixed += 1
    else:
        print(f"  ✗ att-ticket__img: no image found after href fix")
        offset = pos + len(PLACEHOLDER_GIF)

print(f"\nHrefs fixed: {fixed_hrefs} | Images fixed: {img_fixed}")
save_page(homepage_id, new_content)

# Flush caches
print("\nFlushing caches...")
wp("cache", "flush")
wp("transient", "delete", "--all")
subprocess.run(
    ["bash", "-c",
     f"wp --path={WP_PATH} eval 'if(function_exists(\"rocket_clean_domain\")){{rocket_clean_domain();}}' 2>/dev/null || true"],
    capture_output=True
)
print("Done.")
