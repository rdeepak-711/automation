#!/usr/bin/env python3
"""
Fix card "Learn more" links AND images on the homepage and L1 pages.

Unlike script 17 (which matches by slug from the href), this script matches
by CARD TITLE. This means it fixes cards where the href slug is completely
wrong — it reads the <h3> text, finds the WordPress post with the closest
matching title, then updates both the href and the featured image.

Card types handled:
  att-ticket        — h3 is plain text; link is att-ticket__more
  att-highlight     — h3 contains <a href>; also a second link in body
  att-article-card  — h3 contains <a href>; also att-article-card__link
  att-featured      — h3 contains <a href>; also att-featured__link
  att-crosslink     — h3 contains <a href>; link is L1 page (skip link fix)

Usage:
    python3 18-fix-card-links-and-images.py <wp_path> <site_url>

Example:
    python3 18-fix-card-links-and-images.py /home1/dpskbcmy/public_html/website_da6eadef https://vangoghmuseum-guide.com
"""

import subprocess, re, sys, html as html_mod

PLACEHOLDER_GIF = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
SCORE_THRESHOLD = 0.7   # word-overlap threshold for fuzzy match
FIX_IMAGES = True       # fetch featured image from matched post

# Explicit overrides: normalized card title → (category, slug)
# These bypass fuzzy matching entirely — use when auto-match is wrong.
# Key = norm(card h3 text); value = (cat_prefix, post_slug)
TITLE_OVERRIDES = {
    # ── Homepage — Tickets section ────────────────────────────────────────────
    "van gogh museum entry ticket":              ("tickets", "van-gogh-museum-entry-ticket"),
    "van gogh museum with audio guide":          ("tickets", "van-gogh-museum-entry-ticket-audio-guide"),
    "guided tour of van gogh museum":            ("tickets", "van-gogh-museum-guided-tour"),
    "private tour of van gogh museum":           ("tickets", "van-gogh-museum-private-tour"),
    "van gogh museum and canal cruise":          ("tickets", "van-gogh-canal-cruise-combo-tour"),
    "van gogh and rijksmuseum guided tour":      ("tickets", "van-gogh-rijksmuseum-combo-tour"),
    # ── Homepage — Plan Your Visit section ───────────────────────────────────
    "best time to visit the van gogh museum":    ("plan-your-visit", "best-time-to-visit-van-gogh-museum"),
    "how to get to the van gogh museum":         ("plan-your-visit", "how-to-get-to-van-gogh-museum"),
    "tips for first time visitors":              ("plan-your-visit", "van-gogh-museum-tips"),
    # ── Homepage — What to See section ───────────────────────────────────────
    "must see paintings top 10":                 ("what-to-see", "van-gogh-museum-must-see-paintings"),
    "sunflowers the full story":                 ("what-to-see", "van-gogh-sunflowers"),
    "the bedroom meaning versions":              ("what-to-see", "van-gogh-the-bedroom"),
    # ── Hagia Sophia — Homepage tickets ──────────────────────────────────────
    "hagia sophia skip the line entry ticket":   ("tickets", "hagia-sophia-self-guided-entry-ticket"),
    "hagia sophia entry with audio guide":       ("tickets", "hagia-sophia-guided-tour"),
    "entry ticket with audio guide":             ("tickets", "hagia-sophia-guided-tour"),
    "hagia sophia history museum audio tour":    ("tickets", "hagia-sophia-history-museum-only"),
    "architecture what makes it extraordinary":  ("what-to-see", "hagia-sophia-architecture"),
    # ── Mont-Saint-Michel ─────────────────────────────────────────────────────
    "abbey self guided entry ticket":                      ("tickets", "abbey-entry-ticket"),
    "mont saint michel abbey self guided entry ticket":    ("tickets", "abbey-entry-ticket"),
    "mont saint michel abbey self guided entry ticket":    ("tickets", "abbey-entry-ticket"),
    "the tidal wonder":                                  ("what-to-see", "bay-walk-crossing"),
    "medieval village ramparts":                         ("what-to-see", "village-grande-rue"),
    # ── Hagia Sophia — What to See L1 page ───────────────────────────────────
    "the upper gallery":                         ("what-to-see", "hagia-sophia-upper-gallery"),
    "the magnificent dome":                      ("what-to-see", "hagia-sophia-architecture"),
    "byzantine mosaics":                         ("what-to-see", "hagia-sophia-mosaics"),
    "plan your visit to hagia sophia":           ("plan-your-visit", ""),  # L1 page crosslink — image only
    # ── Hagia Sophia — Plan Your Visit L1 page ───────────────────────────────
    "how long do you need at hagia sophia":      ("plan-your-visit", "how-long"),
    "opening hours days":                        ("plan-your-visit", "opening-hours"),
    "tips for first time visitors":              ("plan-your-visit", "tips-for-first-time-visitors"),
    # ── What to See L1 page ──────────────────────────────────────────────────
    "the bedroom":                                               ("what-to-see", "van-gogh-the-bedroom"),
    "sunflowers series":                                         ("what-to-see", "van-gogh-sunflowers"),
    "permanent collection floor by floor":                       ("what-to-see", "van-gogh-museum-permanent-collection"),
    "temporary exhibitions":                                     ("what-to-see", "van-gogh-museum-exhibitions"),
    "almond blossom explained":                                  ("what-to-see", "van-gogh-almond-blossom"),
    "van gogh s self portraits":                                 ("what-to-see", "van-gogh-self-portraits"),
    "the letters drawings":                                      ("what-to-see", "van-gogh-letters-and-drawings"),
    # ── Plan Your Visit L1 page ──────────────────────────────────────────────
    "how to get there":                                          ("plan-your-visit", "how-to-get-to-van-gogh-museum"),
    "visiting with children":                                    ("plan-your-visit", "van-gogh-museum-with-kids"),
    "museumplein neighbourhood guide":                           ("plan-your-visit", "museumplein-neighbourhood-guide"),
    # ── Tickets & Tours L1 page ───────────────────────────────────────────────
    "van gogh museum ticket and city canal cruise":              ("tickets", "van-gogh-canal-cruise-combo-tour"),
    "guided combo tour of van gogh museum and rijksmuseum":      ("tickets", "van-gogh-rijksmuseum-combo-tour"),
    "family guided tour of van gogh museum":                     ("tickets", "van-gogh-museum-family-tour"),
    "amsterdam pass":                                            ("tickets", "amsterdam-pass"),
}

# Hero image overrides: domain → {page_slug → absolute image URL}
_HERO_IMAGES_ALL = {
    "vangoghmuseum-guide.com": {
        "homepage":        "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Exterior.avif",
        "tickets":         "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Entrance.avif",
        "plan-your-visit": "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Sunflowers-Family-Visit.avif",
        "what-to-see":     "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Entrance-Glass-Pavilion.avif",
    },
    "hagiasophia-guide.com": {
        "tickets":         "https://hagiasophia-guide.com/wp-content/uploads/2026/04/hagia-sophia-mosque-in-Istanbul.avif",
        "plan-your-visit": "https://hagiasophia-guide.com/wp-content/uploads/2026/04/interior-of-Hagia-Sophia.avif",
        "what-to-see":     "https://hagiasophia-guide.com/wp-content/uploads/2026/04/mosaics-in-Hagia-Sophia.avif",
    },
    "montsaintmichel-guide.com": {
        "homepage":        "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-Abbey-in-Normandy.avif",
        "tickets":         "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Saint-Michel-Abbey-in-France.avif",
        "plan-your-visit": "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-Abbey-at-night-1.avif",
        "what-to-see":     "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-aerial-view.avif",
    },
    "pyramidsofgiza-guide.com": {
        "homepage":        "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/Pyramids-of-Giza-in-Egypt.avif",
        "tickets":         "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-Sphinx-at-Pyramids-of-Giza.avif",
        "plan-your-visit": "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/Camel-ride-at-the-Giza-Pyramids-in-Egypt.avif",
        "what-to-see":     "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-inside-of-Giza-Pyramids.avif",
    },
}
# HERO_IMAGES resolved after SITE_DOMAIN is known (see below)

# Explicit image overrides: domain → {normalized card title → absolute image URL}
# Use when the WP post has no featured image, or for crosslink cards.
_IMAGE_OVERRIDES_ALL = {
    "vangoghmuseum-guide.com": {
        "permanent collection floor by floor": "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Paintings-Gallery-Interior.avif",
        # crosslinks — norm strips punctuation: "Tickets & Tours" → "tickets tours"
        "tickets tours":                       "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Entrance.avif",
        "van gogh museum tickets tours":       "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Entrance.avif",
        "plan your visit":                     "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Sunflowers-Family-Visit.avif",
        "plan your visit to the van gogh museum": "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Sunflowers-Family-Visit.avif",
        "what to see":                         "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Entrance-Glass-Pavilion.avif",
        "what to see at the van gogh museum":  "https://vangoghmuseum-guide.com/wp-content/uploads/2026/04/Van-Gogh-Museum-Entrance-Glass-Pavilion.avif",
    },
    "hagiasophia-guide.com": {
        "best time to visit hagia sophia":  "https://hagiasophia-guide.com/wp-content/uploads/2026/04/hagia-sophia-morning-light.avif",
        # crosslinks — norm strips punctuation: "Tickets & Tours" → "tickets tours"
        "tickets tours":                    "https://hagiasophia-guide.com/wp-content/uploads/2026/04/hagia-sophia-mosque-in-Istanbul.avif",
        "hagia sophia tickets tours":       "https://hagiasophia-guide.com/wp-content/uploads/2026/04/hagia-sophia-mosque-in-Istanbul.avif",
        "plan your visit":                  "https://hagiasophia-guide.com/wp-content/uploads/2026/04/interior-of-Hagia-Sophia.avif",
        "plan your visit to hagia sophia":  "https://hagiasophia-guide.com/wp-content/uploads/2026/04/interior-of-Hagia-Sophia.avif",
        "what to see":                      "https://hagiasophia-guide.com/wp-content/uploads/2026/04/mosaics-in-Hagia-Sophia.avif",
        "what to see at hagia sophia":      "https://hagiasophia-guide.com/wp-content/uploads/2026/04/mosaics-in-Hagia-Sophia.avif",
    },
    "montsaintmichel-guide.com": {
        # crosslinks — norm strips punctuation: "Tickets & Tours" → "tickets tours"
        "tickets tours":                                  "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Saint-Michel-Abbey-in-France.avif",
        "mont saint michel tickets tours":                "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Saint-Michel-Abbey-in-France.avif",
        "plan your visit":                                "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-Abbey-at-night-1.avif",
        "plan your visit to mont saint michel":           "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-Abbey-at-night-1.avif",
        "what to see":                                    "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-aerial-view.avif",
        "what to see at mont saint michel":               "https://montsaintmichel-guide.com/wp-content/uploads/2026/04/Mont-Saint-Michel-aerial-view.avif",
    },
    "pyramidsofgiza-guide.com": {
        "tickets tours":                                  "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-Sphinx-at-Pyramids-of-Giza.avif",
        "tickets tours to the pyramids of giza":          "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-Sphinx-at-Pyramids-of-Giza.avif",
        "tickets tours at the pyramids of giza":          "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-Sphinx-at-Pyramids-of-Giza.avif",
        "plan your visit":                                "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/Camel-ride-at-the-Giza-Pyramids-in-Egypt.avif",
        "plan your visit to the pyramids of giza":        "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/Camel-ride-at-the-Giza-Pyramids-in-Egypt.avif",
        "plan your visit to pyramids of giza":            "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/Camel-ride-at-the-Giza-Pyramids-in-Egypt.avif",
        "what to see":                                    "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-inside-of-Giza-Pyramids.avif",
        "what to see at the pyramids of giza":            "https://pyramidsofgiza-guide.com/wp-content/uploads/2026/04/The-inside-of-Giza-Pyramids.avif",
    },
}
# IMAGE_OVERRIDES resolved after SITE_DOMAIN is known (see below)

# Cards to remove entirely (normalized title → deleted from page content)
REMOVE_CARDS = {
    "the starry night",
    "japanese print collection",
    "van gogh s contemporaries",
}

def usage():
    print(__doc__)
    sys.exit(1)

if len(sys.argv) < 3:
    usage()

WP_PATH     = sys.argv[1].rstrip("/")
SITE_URL    = sys.argv[2].rstrip("/")
PAGE_FILTER = sys.argv[3] if len(sys.argv) > 3 else None  # optional: only process this page slug
SITE_DOMAIN = re.sub(r"^https?://(?:www\.)?", "", SITE_URL)
HERO_IMAGES    = _HERO_IMAGES_ALL.get(SITE_DOMAIN, {})
IMAGE_OVERRIDES = _IMAGE_OVERRIDES_ALL.get(SITE_DOMAIN, {})

def wp(*args):
    result = subprocess.run(
        ["wp", "--path=" + WP_PATH] + list(args),
        capture_output=True, text=True
    )
    return result.stdout.strip()

# ── Title normalisation ───────────────────────────────────────────────────────
def norm(t):
    t = html_mod.unescape(t)
    t = re.sub(r'<[^>]+>', '', t)          # strip tags
    t = re.sub(r'\s+', ' ', t).strip().lower()
    t = re.sub(r'\b20\d\d\b', '', t).strip()  # strip year suffixes
    t = re.sub(r'[^\w\s]', ' ', t)         # remove punctuation
    t = re.sub(r'\s+', ' ', t).strip()
    return t

def word_score(a, b):
    """
    Containment-biased overlap: intersection / min(len_a, len_b).
    A short card title that fully appears in a long post title scores 1.0.
    Prevents short titles from being penalised by long post suffixes.
    """
    wa, wb = set(a.split()), set(b.split())
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / min(len(wa), len(wb))

# ── Build title → post data map ───────────────────────────────────────────────
print("Fetching all posts from WordPress...")
posts_csv = wp("post", "list", "--post_type=post", "--format=csv",
               "--fields=ID,post_name,post_title", "--posts_per_page=500",
               "--post_status=publish")

# title_map: normalized_title → {slug, cat_slug, img_url, raw_title}
title_map = {}
slug_map  = {}  # slug → same dict

for line in posts_csv.splitlines()[1:]:
    parts = line.split(",", 2)
    if len(parts) != 3:
        continue
    post_id, post_slug, post_title = parts[0].strip(), parts[1].strip(), parts[2].strip()

    # Get category
    cats_raw = wp("post", "term", "list", post_id, "category",
                  "--fields=slug", "--format=csv")
    cat_slug = ""
    for c in cats_raw.splitlines()[1:]:
        c = c.strip()
        if c:
            cat_slug = c
            break

    # Get featured image
    thumb_id = wp("post", "meta", "get", post_id, "_thumbnail_id")
    img_url = ""
    if thumb_id:
        img_url = wp("post", "get", thumb_id, "--field=guid")

    entry = {
        "id":        post_id,
        "slug":      post_slug,
        "cat":       cat_slug,
        "img":       img_url,
        "raw_title": post_title,
    }
    title_map[norm(post_title)] = entry
    slug_map[post_slug] = entry

print(f"  {len(title_map)} posts indexed")

def find_post_by_title(card_title):
    """Return best matching entry or None."""
    n = norm(card_title)
    if not n:
        return None

    # 0. Explicit override (highest priority — bypasses all fuzzy logic)
    if n in TITLE_OVERRIDES:
        cat, slug = TITLE_OVERRIDES[n]
        # Look up full entry from slug_map to get img_url etc.
        if slug in slug_map:
            entry = dict(slug_map[slug])
            entry["cat"] = cat   # use override cat, not WP category
            print(f"    [override] '{card_title}' → /{cat}/{slug}/")
            return entry
        # slug not in DB yet — return minimal entry
        print(f"    [override-nodb] '{card_title}' → /{cat}/{slug}/")
        return {"id": "", "slug": slug, "cat": cat, "img": "", "raw_title": card_title}

    # 1. Exact match
    if n in title_map:
        return title_map[n]

    # 2. Fuzzy: require ALL card words to appear in post title (containment),
    #    then rank by fewest extra words in post (tightest match).
    card_words = set(n.split())
    candidates = []
    for t, entry in title_map.items():
        post_words = set(t.split())
        if not card_words.issubset(post_words):
            continue  # post must contain every word from card title
        extra = len(post_words - card_words)  # fewer extra words = tighter match
        candidates.append((extra, t, entry))

    if candidates:
        candidates.sort(key=lambda x: x[0])
        return candidates[0][2]

    # 3. Fallback: relaxed overlap (≥ SCORE_THRESHOLD), tiebreak by length
    best_score, best_len_diff, best_entry = 0.0, 999, None
    n_word_count = len(n.split())
    for t, entry in title_map.items():
        s = word_score(n, t)
        len_diff = abs(len(t.split()) - n_word_count)
        if s > best_score or (s == best_score and len_diff < best_len_diff):
            best_score, best_len_diff, best_entry = s, len_diff, entry

    if best_score >= SCORE_THRESHOLD:
        return best_entry

    return None

# ── Category prefix map (page slug → category URL prefix) ────────────────────
PAGE_CAT = {
    "homepage":        None,   # inferred per section (see below)
    "tickets":         "tickets",
    "tickets-tours":   "tickets",
    "plan-your-visit": "plan-your-visit",
    "what-to-see":     "what-to-see",
}

# Section anchors on homepage → category
SECTION_CAT = {
    "att-tickets": "tickets",
    "att-plan":    "plan-your-visit",
    "att-what":    "what-to-see",
}

def get_section_cat(content, card_pos):
    """For homepage: scan backward from card_pos for nearest section id."""
    chunk = content[max(0, card_pos - 5000):card_pos]
    best_pos, best_cat = -1, "tickets"
    for anchor, cat in SECTION_CAT.items():
        p = chunk.rfind(f'id="{anchor}')
        if p > best_pos:
            best_pos, best_cat = p, cat
    return best_cat

# ── Regex patterns ────────────────────────────────────────────────────────────

# Capture entire card div (handles nesting: 3 closing divs)
# We process card-by-card using a find-and-replace loop instead of a single regex
# to avoid runaway backtracking on large pages.

H3_TEXT_RE    = re.compile(r'<h3[^>]*>(.*?)</h3>', re.DOTALL)
H3_LINK_RE    = re.compile(r'(<h3[^>]*><a\s[^>]*href=")[^"]*(")', re.DOTALL)
TICKET_MORE_RE = re.compile(r'(<a\b[^>]*\bclass="att-ticket__more"[^>]*\bhref=")[^"]+(")')
ARTICLE_LINK_RE = re.compile(r'(<a\b[^>]*\bclass="att-article-card__link"[^>]*\bhref=")[^"]+(")')
FEATURED_LINK_RE = re.compile(r'(<a\b[^>]*\bclass="att-featured__link"[^>]*\bhref=")[^"]+(")')
HIGHLIGHT_LINK_RE = re.compile(r'(<a\b[^>]*\bclass="att-highlight__(?:link|body\s+a)"[^>]*\bhref=")[^"]+(")')

# Generic: any href inside a highlight body second link (plain <a> in body, not h3)
HIGHLIGHT_BODY_A_RE = re.compile(
    r'(class="att-highlight__body"[^<]*(?:<[^/][^<]*>)*?<h3[^>]*>.*?</h3>[^<]*<p[^>]*>.*?</p>[^<]*<a\s[^>]*href=")[^"]+(")',
    re.DOTALL
)

IMG_SRC_RE    = re.compile(
    r'(<img\b[^>]*\bclass="[^"]*att-(?:ticket|highlight|article-card|featured|crosslink)__img[^"]*"[^>]*\bsrc=")[^"]*(")',
    re.DOTALL
)

CARD_CLASSES = [
    "att-ticket",
    "att-highlight",
    "att-article-card",
    "att-featured",
    "att-crosslink",
]

def extract_card_title(card_html):
    m = H3_TEXT_RE.search(card_html)
    if not m:
        return ""
    return norm(m.group(1))

def fix_card(card_html, card_class, cat_prefix):
    """
    Match card by title, then fix img src and link hrefs.
    Returns (new_card_html, matched_title_or_None, log_lines).
    """
    logs = []
    raw_title_match = H3_TEXT_RE.search(card_html)
    if not raw_title_match:
        logs.append("  ✗ no <h3> found in card")
        return card_html, None, logs

    raw_title = re.sub(r'<[^>]+>', '', raw_title_match.group(1))
    raw_title = html_mod.unescape(raw_title).strip()

    entry = find_post_by_title(raw_title)
    if not entry:
        # No WP post match — check for image-only override (e.g. crosslink cards)
        img_override = IMAGE_OVERRIDES.get(norm(raw_title))
        if FIX_IMAGES and img_override:
            new_card, n = IMG_SRC_RE.subn(rf'\g<1>{img_override}\2', card_html)
            if n:
                logs.append(f"  ✓ '{raw_title}' (image-only override)")
                logs.append(f"    img → {img_override.split('/')[-1]}")
                return new_card, raw_title, logs
        logs.append(f"  ✗ no match for title: '{raw_title}'")
        return card_html, None, logs

    slug     = entry["slug"]
    cat      = entry["cat"] or cat_prefix or "tickets"
    img_url  = IMAGE_OVERRIDES.get(norm(raw_title)) or entry["img"]
    matched  = entry["raw_title"]

    logs.append(f"  ✓ '{raw_title}' → '{matched}' (/{cat}/{slug}/)")

    new_card = card_html

    # 1. Fix image src (only if enabled)
    if FIX_IMAGES and img_url:
        new_card, n = IMG_SRC_RE.subn(rf'\g<1>{img_url}\2', new_card)
        if n:
            logs.append(f"    img → {img_url.split('/')[-1]}")

    correct_href = f"/{cat}/{slug}/"

    # 2. Fix links based on card type
    if card_class == "att-ticket":
        # Fix att-ticket__more href
        new_card, n = TICKET_MORE_RE.subn(rf'\g<1>{correct_href}\2', new_card)
        if n:
            logs.append(f"    att-ticket__more → {correct_href}")

    elif card_class == "att-crosslink":
        # Crosslinks point to L1 pages — don't change href, only image
        pass

    else:
        # att-highlight, att-article-card, att-featured
        # Fix h3 > a href
        new_card, n = H3_LINK_RE.subn(rf'\g<1>{correct_href}\2', new_card)
        if n:
            logs.append(f"    h3 link → {correct_href}")

        # Fix secondary link (att-article-card__link / att-featured__link)
        new_card, n = ARTICLE_LINK_RE.subn(rf'\g<1>{correct_href}\2', new_card)
        if n:
            logs.append(f"    article-card__link → {correct_href}")
        new_card, n = FEATURED_LINK_RE.subn(rf'\g<1>{correct_href}\2', new_card)
        if n:
            logs.append(f"    featured__link → {correct_href}")

        # Fix highlight body second link (plain <a> after <p>)
        # Simple approach: replace any plain href that isn't the h3 link
        if card_class == "att-highlight":
            # Find all <a href="..."> in card that aren't part of h3 already fixed
            # Use a simple replacement: find last <a href in card body
            body_a = re.compile(r'(<div class="att-highlight__body">.*?<p[^>]*>.*?</p>\s*<a\s[^>]*href=")[^"]+(")', re.DOTALL)
            new_card, n = body_a.subn(rf'\g<1>{correct_href}\2', new_card)
            if n:
                logs.append(f"    highlight body link → {correct_href}")

    return new_card, matched, logs


def process_page(page_id, page_slug, content):
    """Find all cards, fix each one, return (new_content, total_fixed)."""
    total_fixed = 0
    new_content = content

    # Determine default category for this page
    default_cat = PAGE_CAT.get(page_slug, None)
    is_homepage = (page_slug == "homepage")

    # Fix hero image if configured for this page
    if page_slug in HERO_IMAGES:
        hero_url = HERO_IMAGES[page_slug]
        hero_re = re.compile(r'(<img\b[^>]*\bclass="att-hero__img"[^>]*\bsrc=")[^"]+(")', re.DOTALL)
        new_content, n = hero_re.subn(rf'\g<1>{hero_url}\2', new_content)
        if n:
            print(f"  hero img → {hero_url.split('/')[-1]}")
            total_fixed += 1

    for card_class in CARD_CLASSES:
        open_tag = f'<div class="{card_class}">'
        offset = 0

        while True:
            start = new_content.find(open_tag, offset)
            if start == -1:
                break

            # Find the matching close — count div depth
            depth = 0
            i = start
            end = -1
            while i < len(new_content):
                if new_content[i:i+4] == '<div':
                    depth += 1
                    i += 4
                elif new_content[i:i+6] == '</div>':
                    depth -= 1
                    if depth == 0:
                        end = i + 6
                        break
                    i += 6
                else:
                    i += 1

            if end == -1:
                offset = start + len(open_tag)
                continue

            card_html = new_content[start:end]

            # Remove unwanted cards entirely
            card_title_norm = extract_card_title(card_html)
            if card_title_norm in REMOVE_CARDS:
                print(f"  ✂ removing card: '{card_title_norm}'")
                new_content = new_content[:start] + new_content[end:]
                # don't advance offset — next card now starts at same position
                continue

            # For homepage, infer category from surrounding section
            if is_homepage:
                cat_prefix = get_section_cat(new_content, start)
            else:
                cat_prefix = default_cat

            new_card, matched, logs = fix_card(card_html, card_class, cat_prefix)

            for line in logs:
                print(line)

            if matched:
                total_fixed += 1
                new_content = new_content[:start] + new_card + new_content[end:]
                # Move offset past the updated card
                offset = start + len(new_card)
            else:
                offset = end

    return new_content, total_fixed


# ── Get all pages to process ──────────────────────────────────────────────────
SKIP_SLUGS = {"about-us", "contact-us", "privacy-policy", "terms", "sitemap"}

pages_csv = wp("post", "list", "--post_type=page", "--format=csv",
               "--fields=ID,post_name", "--posts_per_page=50",
               "--post_status=publish")

pages_to_fix = []
for line in pages_csv.splitlines()[1:]:
    parts = line.split(",", 1)
    if len(parts) != 2:
        continue
    page_id, page_slug = parts[0].strip(), parts[1].strip()
    if page_slug not in SKIP_SLUGS:
        if PAGE_FILTER is None or page_slug == PAGE_FILTER:
            pages_to_fix.append((page_id, page_slug))

print(f"\nPages to process: {[s for _, s in pages_to_fix]}\n")

grand_total = 0

for page_id, page_slug in pages_to_fix:
    print(f"=== Page {page_id} ({page_slug}) ===")
    content = wp("post", "get", page_id, "--field=post_content")

    new_content, fixed = process_page(page_id, page_slug, content)
    grand_total += fixed

    if new_content != content:
        proc = subprocess.run(
            ["wp", "--path=" + WP_PATH, "post", "update", page_id,
             "--post_content=" + new_content],
            capture_output=True, text=True
        )
        if proc.returncode == 0:
            print(f"  → Saved ({fixed} cards updated)")
        else:
            print(f"  → SAVE FAILED: {proc.stderr[:300]}")
    else:
        print(f"  → No changes")
    print()

# ── Flush all caches ──────────────────────────────────────────────────────────
print("Flushing caches...")
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
print(f"Total cards fixed: {grand_total}")
print("Done.")
