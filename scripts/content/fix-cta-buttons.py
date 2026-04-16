#!/usr/bin/env python3
"""
fix-cta-buttons.py

For ticket/tour articles: removes all existing CTA buttons, places ONE button
after the What's Included bullet list.

For informational articles: prints placement plan only (no changes).

Usage:
    python3 scripts/content/fix-cta-buttons.py angkor-wat [--dry-run]
"""

import sys, os, re, glob

SITE_SLUG = sys.argv[1] if len(sys.argv) > 1 else None
DRY_RUN = "--dry-run" in sys.argv

if not SITE_SLUG:
    print("Usage: fix-cta-buttons.py <site-slug> [--dry-run]")
    sys.exit(1)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INPUT  = os.path.join(REPO, "input", SITE_SLUG)
OUTPUT = os.path.join(REPO, "output", SITE_SLUG, "l2-articles")

# ── Classify article ──────────────────────────────────────────────────────────

def classify(title):
    t = title.lower()
    if "combo" in t:
        return "combo", "Book This Combo"
    if any(w in t for w in ["tour", "trip", "photoshoot", "experience", "zipline", "bike"]):
        return "tour", "Book This Tour"
    if any(w in t for w in ["ticket", "pass", "admission"]):
        return "ticket", "Buy This Ticket"
    return "info", None

# ── Extract primary affiliate URL from MD ─────────────────────────────────────

def primary_url(md_text):
    """Return first GYG/Viator/Tiqets URL found in ## Book This Tour or ## Top Tickets section."""
    # Find the book/tickets section
    m = re.search(
        r'## (?:Book This Tour|Book This Ticket|Top Tickets|Buy This Ticket)(.*?)(?=\n## |\Z)',
        md_text, re.DOTALL | re.IGNORECASE
    )
    block = m.group(1) if m else md_text

    urls = re.findall(r'https?://(?:www\.)?(?:viator|getyourguide|tiqets)\.com\S+', block)
    if urls:
        return urls[0].rstrip(')')
    return None

# ── HTML manipulation ─────────────────────────────────────────────────────────

def strip_existing_buttons(html):
    """Remove .att-buy-now-btn anchors and the H2 block that contains them."""
    # Remove the entire <h2>Book This Tour</h2> block (h2 + following buttons up to next h2)
    html = re.sub(
        r'<h2[^>]*>(?:Book This Tour|Buy This Ticket|Book This Combo|Top Tickets?)[^<]*</h2>\s*'
        r'(?:<a[^>]*class="att-buy-now-btn"[^>]*>.*?</a>\s*)*',
        '', html, flags=re.DOTALL | re.IGNORECASE
    )
    # Remove any remaining standalone att-buy-now-btn anchors
    html = re.sub(r'<a[^>]*class="att-buy-now-btn"[^>]*>.*?</a>\s*', '', html, flags=re.DOTALL)
    return html

def build_button(label, url):
    return (
        f'\n      <a\n        href="{url}"\n        class="att-buy-now-btn"\n'
        f'        rel="nofollow sponsored"\n        target="_blank"\n'
        f'      >{label}</a>\n'
    )

def insert_after_included(html, button_html):
    """Insert button after the closing </ul> of the What's Included section."""
    # Find What's Included h2, then the first </ul> after it
    pattern = r"(<h2[^>]*>What(?:&rsquo;|'|&#8217;|\u2019)?s Included</h2>.*?</ul>)"
    m = re.search(pattern, html, re.DOTALL | re.IGNORECASE)
    if m:
        insert_pos = m.end()
        return html[:insert_pos] + button_html + html[insert_pos:]
    return None

def insert_after_first_section(html, button_html):
    """Fallback: insert after the first </ul> in the article body."""
    # Find first </ul> after the intro section
    m = re.search(r'(</ul>)', html)
    if m:
        insert_pos = m.end()
        return html[:insert_pos] + button_html + html[insert_pos:]
    return None

# ── Process ticket articles ───────────────────────────────────────────────────

print(f"\n{'='*70}")
print(f"  CTA Button Fix — {SITE_SLUG}{'  [DRY RUN]' if DRY_RUN else ''}")
print(f"{'='*70}")

print(f"\n── TICKET/TOUR ARTICLES (fixing) ────────────────────────────────────")

tickets_dir = os.path.join(INPUT, "tickets-tours")
html_dir    = os.path.join(OUTPUT, "tickets-tours")

for md_path in sorted(glob.glob(os.path.join(tickets_dir, "*.md"))):
    slug = re.sub(r'^article\d+_', '', os.path.basename(md_path).replace('.md', ''))
    html_path = os.path.join(html_dir, slug + ".html")

    if not os.path.exists(html_path):
        print(f"  ⚠  {slug} — no HTML found, skipping")
        continue

    md_text = open(md_path).read()
    html    = open(html_path).read()

    # Get title from MD
    title_m = re.search(r'^# (.+)', md_text, re.MULTILINE)
    title   = title_m.group(1) if title_m else slug

    kind, btn_label = classify(title)

    if kind == "info":
        print(f"  ℹ  {slug} — informational, skipping (see plan below)")
        continue

    url = primary_url(md_text)
    if not url:
        print(f"  ⚠  {slug} — no affiliate URL found, skipping")
        continue

    # Strip all existing buttons
    html_fixed = strip_existing_buttons(html)

    # Insert one button after What's Included
    button = build_button(btn_label, url)
    result = insert_after_included(html_fixed, button)

    if result:
        placement = "after What's Included bullet list"
    else:
        # Fallback for articles without What's Included section
        result = insert_after_first_section(html_fixed, button)
        placement = "after first content list (no What's Included section found)"

    if not result:
        print(f"  ✗  {slug} — could not find insertion point")
        continue

    if not DRY_RUN:
        open(html_path, 'w').write(result)

    print(f"  ✓  {slug}")
    print(f"       label:     \"{btn_label}\"")
    print(f"       placed:    {placement}")
    print(f"       url:       {url[:80]}{'...' if len(url)>80 else ''}")

# ── Informational articles plan ───────────────────────────────────────────────

print(f"\n── INFORMATIONAL ARTICLES — PLACEMENT PLAN ─────────────────────────")

INFO_PLAN = {
    # tickets-tours informational
    "angkor-pass": {
        "links": 1, "label": "Buy This Ticket",
        "placement": "After 'Where to Buy the Angkor Pass' section (the natural conversion point)"
    },
    "how-to-buy-tickets": {
        "links": 1, "label": "Buy This Ticket",
        "placement": "After the step-by-step buying guide, before FAQ"
    },
    "guided-vs-self-guided": {
        "links": 2, "label": "Book This Tour / Buy This Ticket",
        "placement": "Two buttons: 'Book This Tour' at end of 'Case for guided' section, 'Buy This Ticket' at end of 'Case for self-guided' section"
    },
    "private-vs-group-tour": {
        "links": 2, "label": "Book This Tour (x2)",
        "placement": "Two buttons: one at end of 'Private tour' section, one at end of 'Group tour' section"
    },
    "angkor-wat-private-tour": {
        "links": 3, "label": "Book This Tour (x3)",
        "placement": "One button per product section — after each product's description/inclusions"
    },
    # plan-your-visit
    "what-is-angkor-wat": {
        "links": 2, "label": "Book This Tour + Buy This Ticket",
        "placement": "After 'Planning Your Visit' section — 2 buttons (pass + sunrise tour)"
    },
    "best-time-to-visit": {
        "links": 3, "label": "Book This Tour",
        "placement": "After 'Best months' verdict paragraph — 1 button (sunrise tour fits any season)"
    },
    "how-many-days": {
        "links": 3, "label": "Book This Tour + Buy This Ticket",
        "placement": "After the 1-day / 2-day / 3-day itinerary summary — 2 buttons"
    },
    "opening-hours": {
        "links": 2, "label": "Buy This Ticket",
        "placement": "After 'Angkor Pass hours & ticket info' section — 1 button"
    },
    "dress-code": {
        "links": 2, "label": "Buy This Ticket",
        "placement": "After 'What to wear' checklist — 1 button"
    },
    "accessibility": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Guided tour recommendation' paragraph — 1 button (guided tour is most accessible)"
    },
    "what-to-expect": {
        "links": 3, "label": "Book This Tour",
        "placement": "After 'What a typical visit looks like' section — 1 button"
    },
    "getting-there-from-siem-reap": {
        "links": 5, "label": "Book This Tour",
        "placement": "After 'Guided tour includes transport' paragraph — 1 button"
    },
    "getting-to-siem-reap": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Once you arrive in Siem Reap' closing section — 1 button"
    },
    "transport-inside-the-park": {
        "links": 4, "label": "Book This Tour + tuk-tuk tour",
        "placement": "2 buttons: after tuk-tuk section and after 'private tour' section"
    },
    "angkor-wat-map": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How guides navigate the map' paragraph — 1 button"
    },
    "angkor-wat-itinerary": {
        "links": 2, "label": "Book This Tour",
        "placement": "After the 1-day itinerary section (highest conversion point) — 1 button"
    },
    "small-circuit-vs-grand-circuit": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Which circuit is right for you' verdict — 1 button"
    },
    "visiting-with-kids": {
        "links": 3, "label": "Book This Tour",
        "placement": "After 'Best tours for families' section — 1 button"
    },
    "solo-travel": {
        "links": 5, "label": "Book This Tour + tuk-tuk",
        "placement": "2 buttons: after 'Solo tour options' section + after 'tuk-tuk' section"
    },
    "budget-guide": {
        "links": 4, "label": "Buy This Ticket + Book This Tour",
        "placement": "2 buttons: after 'Ticket costs' section + after 'Budget tour options'"
    },
    "where-to-stay": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'From your hotel — guided tours' paragraph — 1 button"
    },
    "photography-tips": {
        "links": 3, "label": "Book This Tour + photoshoot",
        "placement": "2 buttons: after 'Sunrise shoot timing' section + after 'Photoshoot experience' mention"
    },
    "crowds-and-peak-times": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Book early for peak season' paragraph — 1 button"
    },
    "rules-and-etiquette": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Guided tour ensures compliance' paragraph — 1 button"
    },
    "food-and-restaurants": {
        "links": 3, "label": "Book This Tour",
        "placement": "After 'Tours that include meals' section — 1 button (angkor-tour-with-meals)"
    },
    "faq": {
        "links": 2, "label": "Buy This Ticket + Book This Tour",
        "placement": "After the ticket/booking FAQ section — 2 buttons"
    },
    "official-website": {
        "links": 2, "label": "Buy This Ticket",
        "placement": "After 'Book online vs official site' section — 1 button"
    },
    # what-to-see
    "angkor-wat-complete-guide": {
        "links": 2, "label": "Book This Tour + Buy This Ticket",
        "placement": "2 buttons: after 'Getting in' section + after 'Guided tours' recommendation"
    },
    "angkor-wat-towers": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Best way to see the towers' paragraph — 1 button"
    },
    "angkor-wat-bas-reliefs": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Guide recommendation' paragraph — 1 button (guide essential for bas-reliefs)"
    },
    "angkor-wat-sunrise": {
        "links": 3, "label": "Book This Tour",
        "placement": "After 'How to book a sunrise tour' section — 1 button"
    },
    "bayon-temple": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to visit Bayon' section — 1 button"
    },
    "ta-prohm-temple": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Best tours that include Ta Prohm' section — 1 button"
    },
    "banteay-srei-temple": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to get there' section — 1 button (needs specific tour)"
    },
    "preah-khan-temple": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to visit' section — 1 button"
    },
    "angkor-wat-vs-angkor-thom": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Verdict / which to prioritise' section — 1 button"
    },
    "phnom-bakheng": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Sunset tour recommendation' paragraph — 1 button (sunset tour)"
    },
    "beng-mealea-temple": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to get there / day trip' section — 1 button (beng-mealea day trip)"
    },
    "angkor-thom": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to visit Angkor Thom' section — 1 button"
    },
    "neak-pean-temple": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to include Neak Pean in your visit' section — 1 button"
    },
    "terrace-of-the-elephants": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to see both terraces' section — 1 button"
    },
    "angkor-wat-history": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Why a guide enhances the history' paragraph — 1 button"
    },
    "angkor-wat-hidden-gems": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'How to find the hidden gems' section — 1 button (private tour)"
    },
    "roluos-group-temples": {
        "links": 2, "label": "Book This Tour",
        "placement": "After 'Day trip options' section — 1 button"
    },
    "khmer-empire-history": {
        "links": 2, "label": "Book This Tour",
        "placement": "After closing 'See it in person' paragraph — 1 button"
    },
}

for slug, plan in INFO_PLAN.items():
    print(f"\n  {slug}")
    print(f"    buttons:   {plan['label']}")
    print(f"    placement: {plan['placement']}")

print(f"\n{'='*70}")
print(f"  Done. {len(INFO_PLAN)} informational articles planned.")
print(f"{'='*70}\n")
