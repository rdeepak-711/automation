#!/usr/bin/env python3
"""
check-homepage-html.py — verify homepage HTML structure and content.

Checks:
  1. Hero section — image placeholder right, title/desc/2 buttons left
  2. Ticket cards — exactly 6
  3. Plan Your Visit cards — exactly 6
  4. Insider tips — section present with tips
  5. What to See cards — exactly 6
  6. Red CTA banner — present
  7. FAQs — section with FAQ items
  8. View All FAQs button/link — present

Usage:
  python3 scripts/content/check-homepage-html.py <site-slug>
  python3 scripts/content/check-homepage-html.py <site-slug> --html path/to/homepage.html
"""

import sys, os, re, glob

PASS = '✅'
FAIL = '❌'
WARN = '⚠️ '

# ── Helpers ───────────────────────────────────────────────────────────────────

def extract_classes(html):
    classes = set()
    for m in re.finditer(r'class="([^"]*)"', html):
        for c in m.group(1).split():
            classes.add(c)
    return classes

def count_elements(html, pattern):
    return len(re.findall(pattern, html))

# ── Section checkers ──────────────────────────────────────────────────────────

def check_hero(html):
    issues, passed = [], []

    if 'att-hero' not in html:
        issues.append(f'{FAIL} Hero section (.att-hero) missing')
        return issues, passed
    passed.append(f'{PASS} Hero section (.att-hero) present')

    # Left content: title, description, buttons
    if 'att-hero__content' not in html:
        issues.append(f'{FAIL} Hero content block (.att-hero__content) missing')
    else:
        passed.append(f'{PASS} Hero content block present')

    h1 = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.DOTALL)
    if h1:
        passed.append(f'{PASS} H1 present: "{re.sub(r"<[^>]+>", "", h1.group(1)).strip()[:60]}"')
    else:
        issues.append(f'{FAIL} No <h1> in hero')

    if 'att-hero__desc' not in html:
        issues.append(f'{FAIL} Hero description (.att-hero__desc) missing')
    else:
        passed.append(f'{PASS} Hero description present')

    if 'att-hero__actions' not in html:
        issues.append(f'{FAIL} Hero action buttons (.att-hero__actions) missing')
    else:
        hero_block = re.search(r'class="att-hero__actions".*?</div>', html, re.DOTALL)
        if hero_block:
            btns = re.findall(r'<a\b[^>]+class="[^"]*att-btn[^"]*"[^>]*>', hero_block.group(0))
            if len(btns) >= 2:
                passed.append(f'{PASS} Hero has {len(btns)} CTA buttons')
            else:
                issues.append(f'{FAIL} Hero has {len(btns)} button(s) — expected 2 (Tickets + Plan Your Visit)')

        # Specifically check for tickets button and plan-your-visit button
        tickets_btn = re.search(r'att-hero__actions.*?href="[^"]*(?:#att-tickets|/tickets)[^"]*"', html, re.DOTALL)
        plan_btn    = re.search(r'att-hero__actions.*?href="[^"]*(?:#att-plan|/plan-your-visit)[^"]*"', html, re.DOTALL)
        if not tickets_btn:
            issues.append(f'{FAIL} Hero missing Tickets button (href to #att-tickets or /tickets)')
        else:
            passed.append(f'{PASS} Hero Tickets button present')
        if not plan_btn:
            issues.append(f'{FAIL} Hero missing Plan Your Visit button (href to #att-plan or /plan-your-visit)')
        else:
            passed.append(f'{PASS} Hero Plan Your Visit button present')

    # Right content: image placeholder
    if 'att-hero__image-wrap' not in html:
        issues.append(f'{FAIL} Hero image wrap (.att-hero__image-wrap) missing')
    else:
        passed.append(f'{PASS} Hero image placeholder present')

    return issues, passed


def check_ticket_cards(html, expected=6):
    issues, passed = [], []

    count = count_elements(html, r'<div class="att-ticket"')
    if count == expected:
        passed.append(f'{PASS} Ticket cards: {count} (expected {expected})')
    elif count == 0:
        issues.append(f'{FAIL} No ticket cards (.att-ticket) found')
    else:
        issues.append(f'{FAIL} Ticket cards: {count} found, expected {expected}')

    # Each card should have: img, tag, title, price, bullets, CTA link, learn-more link
    if count > 0:
        cards_with_cta  = count_elements(html, r'class="att-ticket__cta"')
        cards_with_more = count_elements(html, r'class="att-ticket__more"')
        cards_with_price = count_elements(html, r'class="att-ticket__price"')
        cards_with_tag  = count_elements(html, r'class="att-ticket__tag[^"]*"')

        if cards_with_cta == count:
            passed.append(f'{PASS} All {count} ticket cards have affiliate CTA link')
        else:
            issues.append(f'{FAIL} Only {cards_with_cta}/{count} ticket cards have .att-ticket__cta')

        if cards_with_more == count:
            passed.append(f'{PASS} All {count} ticket cards have "Learn more" link')
        else:
            issues.append(f'{FAIL} Only {cards_with_more}/{count} ticket cards have .att-ticket__more')

        if cards_with_price == count:
            passed.append(f'{PASS} All {count} ticket cards have price')
        else:
            issues.append(f'{FAIL} Only {cards_with_price}/{count} ticket cards have .att-ticket__price')

        if cards_with_tag == count:
            passed.append(f'{PASS} All {count} ticket cards have a tag label')
        else:
            issues.append(f'{FAIL} Only {cards_with_tag}/{count} ticket cards have .att-ticket__tag')

    # View All Tickets link
    if re.search(r'href="[^"]*/?tickets/?[^"]*"[^>]*>.*?[Vv]iew [Aa]ll', html, re.DOTALL):
        passed.append(f'{PASS} "View All Tickets" link present')
    else:
        issues.append(f'{FAIL} "View All Tickets" link missing below ticket cards')

    return issues, passed


def check_plan_cards(html, expected=6):
    issues, passed = [], []

    # Plan Your Visit uses att-highlight cards inside #att-plan section
    plan_section = re.search(r'id="att-plan".*?(?=<section|</div>\s*</div>\s*</section>)', html, re.DOTALL)
    if not plan_section:
        issues.append(f'{FAIL} Plan Your Visit section (#att-plan) missing')
        return issues, passed
    passed.append(f'{PASS} Plan Your Visit section (#att-plan) present')

    plan_html = plan_section.group(0)
    count = count_elements(plan_html, r'<div class="att-highlight"')
    if count == expected:
        passed.append(f'{PASS} Plan Your Visit cards: {count} (expected {expected})')
    elif count == 0:
        issues.append(f'{FAIL} No Plan Your Visit cards (.att-highlight) found in #att-plan section')
    else:
        issues.append(f'{FAIL} Plan Your Visit cards: {count} found, expected {expected}')

    # View All link
    if re.search(r'href="[^"]*/?plan-your-visit/?[^"]*"[^>]*>.*?[Vv]iew', plan_html, re.DOTALL):
        passed.append(f'{PASS} "View" link to /plan-your-visit/ present')
    else:
        issues.append(f'{FAIL} "View Complete Visitor Guide" link missing below Plan Your Visit cards')

    return issues, passed


def check_insider_tips(html):
    issues, passed = [], []

    if 'att-tips-grid' not in html:
        issues.append(f'{FAIL} Insider tips grid (.att-tips-grid) missing')
        return issues, passed
    passed.append(f'{PASS} Insider tips grid present')

    count = count_elements(html, r'<div class="att-tip"')
    if count >= 3:
        passed.append(f'{PASS} Insider tips: {count} tip(s)')
    elif count > 0:
        issues.append(f'{FAIL} Insider tips: only {count} — expected at least 3')
    else:
        issues.append(f'{FAIL} No individual tips (.att-tip) found in tips grid')

    # Tips should have icons
    icons = count_elements(html, r'class="att-tip__icon"')
    if icons == count and count > 0:
        passed.append(f'{PASS} All {count} tips have an icon')
    elif icons < count:
        issues.append(f'{FAIL} Only {icons}/{count} tips have .att-tip__icon')

    return issues, passed


def check_what_to_see(html, expected=6):
    issues, passed = [], []

    # Work only in the HTML body (after </style>) to avoid CSS false-positives
    body_start = html.find('</style>')
    body = html[body_start:] if body_start >= 0 else html

    # What to See is the second att-highlights-grid div in the body
    first = body.find('<div class="att-highlights-grid"')
    wts_start = body.find('<div class="att-highlights-grid"', first + 1) if first >= 0 else -1

    if wts_start < 0:
        issues.append(f'{FAIL} What to See highlights grid missing (no second .att-highlights-grid found)')
        return issues, passed

    # Clip from wts_start to the next <section tag (which is the CTA banner)
    wts_end = body.find('<section', wts_start + 100)
    wts_html = body[wts_start:wts_end] if wts_end > 0 else body[wts_start:]

    count = count_elements(wts_html, r'<div class="att-highlight"')
    if count == expected:
        passed.append(f'{PASS} What to See cards: {count} (expected {expected})')
    elif count == 0:
        issues.append(f'{FAIL} No What to See cards (.att-highlight) found in second highlights grid')
    else:
        issues.append(f'{FAIL} What to See cards: {count} found, expected {expected}')

    # View All link
    if re.search(r'href="[^"]*/?what-to-see/?[^"]*"', wts_html):
        passed.append(f'{PASS} "Explore/View" link to /what-to-see/ present')
    else:
        issues.append(f'{FAIL} Link to /what-to-see/ missing below What to See cards')

    return issues, passed


def check_cta_banner(html):
    issues, passed = [], []

    if 'att-cta-banner' not in html:
        issues.append(f'{FAIL} Red CTA banner (.att-cta-banner) missing')
        return issues, passed
    passed.append(f'{PASS} Red CTA banner (.att-cta-banner) present')

    banner_html = re.search(r'class="att-cta-banner".*?</section>', html, re.DOTALL)
    if banner_html:
        # Should have a link/button inside
        btn = re.search(r'<a\b[^>]+>', banner_html.group(0))
        if btn:
            passed.append(f'{PASS} CTA banner has a clickable link/button')
        else:
            issues.append(f'{FAIL} CTA banner has no link or button')

    # Confirm red via CSS class or inline style (not a hard requirement, just warn if absent)
    return issues, passed


def check_faqs(html):
    issues, passed = [], []

    if 'att-faq' not in html:
        issues.append(f'{FAIL} FAQ section (.att-faq) missing')
        return issues, passed
    passed.append(f'{PASS} FAQ section (.att-faq) present')

    count = count_elements(html, r'class="att-faq-item"')
    if count >= 5:
        passed.append(f'{PASS} FAQ items: {count}')
    elif count > 0:
        issues.append(f'{FAIL} FAQ items: only {count} — expected at least 5')
    else:
        issues.append(f'{FAIL} No FAQ items (.att-faq-item) found in FAQ section')

    # Each FAQ item needs a question button and an answer div
    q_count = count_elements(html, r'class="att-faq-item__q"')
    a_count = count_elements(html, r'class="att-faq-item__a"')
    if q_count == count and a_count == count:
        passed.append(f'{PASS} All {count} FAQ items have question + answer')
    else:
        issues.append(f'{FAIL} FAQ items: {q_count} questions, {a_count} answers — expected {count} each')

    # FAQPage schema
    if 'FAQPage' in html and 'mainEntity' in html:
        schema_count = count_elements(html, r'itemtype="https://schema.org/Question"')
        passed.append(f'{PASS} FAQPage schema markup present ({schema_count} question(s))')
    else:
        issues.append(f'{FAIL} FAQPage schema markup missing (itemtype="https://schema.org/FAQPage")')

    # "View All FAQs" link
    view_all = re.search(
        r'href="[^"]*(?:faq|frequently-asked)[^"]*"[^>]*>|'
        r'>[^<]*[Vv]iew [Aa]ll [Ff]AQ|'
        r'>[^<]*[Aa]ll [Ff]requently [Aa]sked',
        html
    )
    # Also check for a section-link below the FAQ block
    faq_pos = html.rfind('att-faq-item')
    if faq_pos >= 0:
        after_faq = html[faq_pos:]
        section_link = re.search(r'class="att-section-link"', after_faq)
        faq_link = re.search(r'href="[^"]*faq[^"]*"', after_faq)
        if section_link or faq_link or view_all:
            passed.append(f'{PASS} "View All FAQs" link present')
        else:
            issues.append(f'{FAIL} "View All FAQs" link missing after FAQ items')

    return issues, passed


# ── Main runner ───────────────────────────────────────────────────────────────

def check_homepage(html_path):
    issues_total, passed_total = [], []

    if not os.path.exists(html_path):
        print(f'{FAIL} File not found: {html_path}')
        return 1

    html = open(html_path).read()

    # Outer wrapper
    if 'att-homepage' not in html:
        issues_total.append(f'{FAIL} Root wrapper .att-homepage missing')
    else:
        passed_total.append(f'{PASS} Root wrapper .att-homepage present')

    sections = [
        ('Hero',             check_hero),
        ('Ticket cards',     check_ticket_cards),
        ('Plan Your Visit',  check_plan_cards),
        ('Insider tips',     check_insider_tips),
        ('What to See',      check_what_to_see),
        ('Red CTA banner',   check_cta_banner),
        ('FAQs',             check_faqs),
    ]

    total_issues = 0
    total_warnings = 0

    for label, fn in sections:
        result = fn(html)
        # functions return (issues, passed) — no warnings currently
        s_issues, s_passed = result[0], result[1]

        print(f'\n  ── {label} ──')
        for p in s_passed:
            print(f'  {p}')
        for i in s_issues:
            print(f'  {i}')
        total_issues += len(s_issues)

    return total_issues


def run(site_slug, html_path=None, repo_root=None):
    if repo_root is None:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

    if html_path is None:
        html_path = os.path.join(repo_root, 'output', site_slug, 'homepage.html')

    print(f'\n{"="*70}')
    print(f'  Homepage Check — {site_slug}')
    print(f'  File: {os.path.relpath(html_path, repo_root)}')
    print(f'{"="*70}')

    total_issues = check_homepage(html_path)

    print(f'\n{"="*70}')
    if total_issues == 0:
        print(f'  {PASS} All homepage checks passed')
    else:
        print(f'  ❌ {total_issues} issue(s) found')
    print(f'{"="*70}\n')

    return total_issues


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 check-homepage-html.py <site-slug> [--html path/to/homepage.html]')
        sys.exit(1)

    site_slug = sys.argv[1]
    html_path = None

    if '--html' in sys.argv:
        idx = sys.argv.index('--html')
        html_path = sys.argv[idx + 1]

    sys.exit(run(site_slug, html_path))
