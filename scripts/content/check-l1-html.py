#!/usr/bin/env python3
"""
check-l1-html.py — verify L1 page HTML structure and content.

Checks all three L1 pages per site:
  - plan-your-visit.html  (.att-plan-page)
  - tickets-tours.html    (.att-tickets-page)
  - what-to-see.html      (.att-wts-page)

Each page is verified against its own template spec.

Usage:
  python3 scripts/content/check-l1-html.py <site-slug>
  python3 scripts/content/check-l1-html.py <site-slug> --page plan-your-visit
  python3 scripts/content/check-l1-html.py <site-slug> --html path/to/file.html
"""

import sys, os, re, json, glob

PASS = '✅'
FAIL = '❌'
WARN = '⚠️ '

# ── Helpers ───────────────────────────────────────────────────────────────────

def count_elements(html, pattern):
    return len(re.findall(pattern, html))

def body(html):
    """Return only the HTML body (after </style>) to skip CSS class name matches."""
    pos = html.rfind('</style>')
    return html[pos:] if pos >= 0 else html

# ── Shared section checkers ───────────────────────────────────────────────────

def check_hero(html, primary_btn_target, secondary_btn_target):
    """Hero: image right, title/desc/2 buttons left, quicktips bar below."""
    issues, passed = [], []

    if 'att-hero' not in html:
        issues.append(f'{FAIL} Hero section (.att-hero) missing')
        return issues, passed
    passed.append(f'{PASS} Hero section present')

    h1 = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.DOTALL)
    if h1:
        passed.append(f'{PASS} H1: "{re.sub(r"<[^>]+>", "", h1.group(1)).strip()[:60]}"')
    else:
        issues.append(f'{FAIL} No <h1> in hero')

    if 'att-hero__desc' not in html:
        issues.append(f'{FAIL} Hero description (.att-hero__desc) missing')
    else:
        passed.append(f'{PASS} Hero description present')

    if 'att-hero__image-wrap' not in html:
        issues.append(f'{FAIL} Hero image placeholder (.att-hero__image-wrap) missing')
    else:
        passed.append(f'{PASS} Hero image placeholder present')

    # 2 buttons
    if 'att-hero__actions' not in html:
        issues.append(f'{FAIL} Hero action buttons (.att-hero__actions) missing')
    else:
        actions = re.search(r'class="att-hero__actions"(.*?)</div>', html, re.DOTALL)
        if actions:
            btns = re.findall(r'<a\b[^>]+class="[^"]*att-btn[^"]*"', actions.group(0))
            if len(btns) >= 2:
                passed.append(f'{PASS} Hero has {len(btns)} CTA buttons')
            else:
                issues.append(f'{FAIL} Hero has {len(btns)} button(s) — expected 2')

        if primary_btn_target and not re.search(
                rf'att-hero__actions.*?href="[^"]*{re.escape(primary_btn_target)}[^"]*"', html, re.DOTALL):
            issues.append(f'{FAIL} Hero primary button missing (expected href to "{primary_btn_target}")')
        else:
            passed.append(f'{PASS} Hero primary button present')

        if secondary_btn_target and not re.search(
                rf'att-hero__actions.*?href="[^"]*{re.escape(secondary_btn_target)}[^"]*"', html, re.DOTALL):
            issues.append(f'{FAIL} Hero secondary button missing (expected href to "{secondary_btn_target}")')
        else:
            passed.append(f'{PASS} Hero secondary button present')

    # Quicktips bar
    qt_count = count_elements(html, r'<div class="att-quicktip"')
    if qt_count >= 3:
        passed.append(f'{PASS} Quicktips bar: {qt_count} items')
    elif qt_count > 0:
        issues.append(f'{FAIL} Quicktips bar: {qt_count} items — expected at least 3')
    else:
        issues.append(f'{FAIL} Quicktips bar (.att-quicktip) missing')

    return issues, passed


def check_article_cards(html, expected_total, page_label):
    """Article cards spread across multiple sections."""
    issues, passed = [], []

    b = body(html)
    count = count_elements(b, r'<div class="att-article-card"')
    if count == expected_total:
        passed.append(f'{PASS} Article cards: {count} total (expected {expected_total})')
    elif count == 0:
        issues.append(f'{FAIL} No article cards (.att-article-card) found')
    else:
        issues.append(f'{FAIL} Article cards: {count} found, expected {expected_total}')

    if count > 0:
        with_link  = count_elements(b, r'class="att-article-card__link"')
        with_desc  = count_elements(b, r'class="att-article-card__desc"')
        with_img   = count_elements(b, r'class="att-article-card__img"')

        if with_link == count:
            passed.append(f'{PASS} All {count} article cards have a "Read guide" link')
        else:
            issues.append(f'{FAIL} Only {with_link}/{count} article cards have .att-article-card__link')

        if with_desc == count:
            passed.append(f'{PASS} All {count} article cards have a description')
        else:
            issues.append(f'{FAIL} Only {with_desc}/{count} article cards have .att-article-card__desc')

        if with_img == count:
            passed.append(f'{PASS} All {count} article cards have an image placeholder')
        else:
            issues.append(f'{FAIL} Only {with_img}/{count} article cards have .att-article-card__img')

    return issues, passed


def check_practical_cards(html, expected=4):
    """Practical info cards (.att-practical-card) — unique to Plan Your Visit."""
    issues, passed = [], []

    b = body(html)
    if 'att-practical-grid' not in b:
        issues.append(f'{FAIL} Practical info grid (.att-practical-grid) missing')
        return issues, passed
    passed.append(f'{PASS} Practical info grid present')

    count = count_elements(b, r'<div class="att-practical-card"')
    if count == expected:
        passed.append(f'{PASS} Practical cards: {count} (expected {expected})')
    elif count == 0:
        issues.append(f'{FAIL} No practical cards (.att-practical-card) found')
    else:
        issues.append(f'{FAIL} Practical cards: {count} found, expected {expected}')

    return issues, passed


def check_tips(html, min_tips=3):
    issues, passed = [], []

    b = body(html)
    if 'att-tips-grid' not in b:
        issues.append(f'{FAIL} Tips grid (.att-tips-grid) missing')
        return issues, passed
    passed.append(f'{PASS} Tips grid present')

    count = count_elements(b, r'<div class="att-tip"')
    if count >= min_tips:
        passed.append(f'{PASS} Tips: {count}')
    else:
        issues.append(f'{FAIL} Tips: {count} — expected at least {min_tips}')

    icons = count_elements(b, r'class="att-tip__icon"')
    if icons == count and count > 0:
        passed.append(f'{PASS} All {count} tips have an icon')
    elif icons < count:
        issues.append(f'{FAIL} Only {icons}/{count} tips have .att-tip__icon')

    return issues, passed


def check_crosslinks(html, expected_slugs):
    """Cross-links to the other 2 silos."""
    issues, passed = [], []

    b = body(html)
    if 'att-crosslinks' not in b:
        issues.append(f'{FAIL} Cross-links section (.att-crosslinks) missing')
        return issues, passed
    passed.append(f'{PASS} Cross-links section present')

    count = count_elements(b, r'<div class="att-crosslink"')
    if count == len(expected_slugs):
        passed.append(f'{PASS} Cross-links: {count} cards')
    else:
        issues.append(f'{FAIL} Cross-links: {count} found, expected {len(expected_slugs)}')

    for slug in expected_slugs:
        if re.search(rf'href="[^"]*/{re.escape(slug)}/', b):
            passed.append(f'{PASS} Cross-link to /{slug}/ present')
        else:
            issues.append(f'{FAIL} Cross-link to /{slug}/ missing')

    return issues, passed


def check_cta_banner(html):
    issues, passed = [], []
    b = body(html)
    if 'att-cta-banner' not in b:
        issues.append(f'{FAIL} Red CTA banner (.att-cta-banner) missing')
    else:
        passed.append(f'{PASS} Red CTA banner present')
        if re.search(r'att-cta-banner.*?<a\b', b, re.DOTALL):
            passed.append(f'{PASS} CTA banner has a button/link')
        else:
            issues.append(f'{FAIL} CTA banner has no button/link')
    return issues, passed


def check_faqs(html, faq_anchor):
    issues, passed = [], []
    b = body(html)

    if faq_anchor not in b:
        issues.append(f'{FAIL} FAQ section anchor (#{faq_anchor}) missing')
    else:
        passed.append(f'{PASS} FAQ section present (#{faq_anchor})')

    count = count_elements(b, r'class="att-faq-item"')
    if count >= 5:
        passed.append(f'{PASS} FAQ items: {count}')
    elif count > 0:
        issues.append(f'{FAIL} FAQ items: {count} — expected at least 5')
    else:
        issues.append(f'{FAIL} No FAQ items (.att-faq-item) found')

    if count > 0:
        q = count_elements(b, r'class="att-faq-item__q"')
        a = count_elements(b, r'class="att-faq-item__a"')
        if q == count and a == count:
            passed.append(f'{PASS} All {count} FAQ items have question + answer')
        else:
            issues.append(f'{FAIL} FAQ items incomplete: {q} questions, {a} answers (expected {count} each)')

    if 'FAQPage' in html:
        schema_q = count_elements(html, r'itemtype="https://schema.org/Question"')
        passed.append(f'{PASS} FAQPage schema present ({schema_q} question(s))')
    else:
        issues.append(f'{FAIL} FAQPage schema markup missing')

    # View All FAQs link — search after the last closing </details> or att-faq-item__a
    faq_pos = b.rfind('class="att-faq-item__a"')
    if faq_pos >= 0:
        after = b[faq_pos:]
        if re.search(r'class="att-section-link"|href="[^"]*faq[^"]*"', after):
            passed.append(f'{PASS} "View All FAQs" / section link present after FAQs')
        else:
            issues.append(f'{FAIL} "View All FAQs" link missing after FAQ items')

    return issues, passed


# ── Per-page specs ────────────────────────────────────────────────────────────

def check_plan_your_visit(html):
    print('\n  ── Hero ──')
    for line in flatten(check_hero(html, '#pyv-essentials', '#pyv-faqs')):
        print(f'  {line}')

    print('\n  ── Article cards (16 total across sections) ──')
    for line in flatten(check_article_cards(html, 16, 'plan-your-visit')):
        print(f'  {line}')

    print('\n  ── Practical info cards ──')
    for line in flatten(check_practical_cards(html, expected=4)):
        print(f'  {line}')

    print('\n  ── Tips ──')
    for line in flatten(check_tips(html, min_tips=3)):
        print(f'  {line}')

    print('\n  ── Cross-links to other silos ──')
    for line in flatten(check_crosslinks(html, ['tickets', 'what-to-see'])):
        print(f'  {line}')

    print('\n  ── Red CTA banner ──')
    for line in flatten(check_cta_banner(html)):
        print(f'  {line}')

    print('\n  ── FAQs ──')
    for line in flatten(check_faqs(html, 'pyv-faqs')):
        print(f'  {line}')

    return sum(1 for s in [
        check_hero(html, '#pyv-essentials', '#pyv-faqs'),
        check_article_cards(html, 16, 'plan-your-visit'),
        check_practical_cards(html, 4),
        check_tips(html),
        check_crosslinks(html, ['tickets', 'what-to-see']),
        check_cta_banner(html),
        check_faqs(html, 'pyv-faqs'),
    ] for line in s[0])


def check_tickets_tours(html):
    issue_count = 0

    # Hero — no quicktips bar on this page
    print('\n  ── Hero ──')
    issues, passed = check_hero(html, '#tt-top-picks', '#tt-faqs')
    # Tickets page has no quicktips bar — drop that specific failure
    issues = [i for i in issues if 'Quicktips bar' not in i]
    for line in passed + issues: print(f'  {line}')
    issue_count += len(issues)

    # Ticket cards (full cards with price/CTA — no article-cards on this page)
    print('\n  ── Ticket cards ──')
    b = body(html)
    ticket_count = count_elements(b, r'<div class="att-ticket"')
    issues, passed = [], []
    if ticket_count >= 6:
        passed.append(f'{PASS} Ticket cards (.att-ticket): {ticket_count}')
    elif ticket_count >= 3:
        passed.append(f'{PASS} Ticket cards (.att-ticket): {ticket_count} (under 6 — check if intentional)')
    else:
        issues.append(f'{FAIL} Ticket cards: {ticket_count} — expected at least 6')
    # Each card should have CTA, price, tag
    with_cta   = count_elements(b, r'class="att-ticket__cta"')
    with_price = count_elements(b, r'class="att-ticket__price"')
    if ticket_count > 0 and with_cta == ticket_count:
        passed.append(f'{PASS} All {ticket_count} ticket cards have affiliate CTA')
    elif ticket_count > 0:
        issues.append(f'{FAIL} Only {with_cta}/{ticket_count} ticket cards have .att-ticket__cta')
    with_desc = count_elements(b, r'class="att-ticket__desc"')
    if ticket_count > 0 and with_desc == ticket_count:
        passed.append(f'{PASS} All {ticket_count} ticket cards have description')
    elif ticket_count > 0:
        issues.append(f'{FAIL} Only {with_desc}/{ticket_count} ticket cards have .att-ticket__desc')
    for line in passed + issues: print(f'  {line}')
    issue_count += len(issues)

    print('\n  ── Tips ──')
    r = check_tips(html)
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    print('\n  ── Cross-links to other silos ──')
    r = check_crosslinks(html, ['plan-your-visit', 'what-to-see'])
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    print('\n  ── Red CTA banner ──')
    r = check_cta_banner(html)
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    print('\n  ── FAQs ──')
    r = check_faqs(html, 'tt-faqs')
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    return issue_count


def check_what_to_see(html):
    issue_count = 0

    # Hero — no quicktips bar on this page
    print('\n  ── Hero ──')
    issues, passed = check_hero(html, '#wts-top', '#wts-faqs')
    issues = [i for i in issues if 'Quicktips bar' not in i]
    for line in passed + issues: print(f'  {line}')
    issue_count += len(issues)

    # WTS uses 2 featured cards + 4 article cards = 6 total highlights
    print('\n  ── Featured + Article cards (6 total) ──')
    b = body(html)
    featured_count = count_elements(b, r'<div class="att-featured"')
    article_count  = count_elements(b, r'<div class="att-article-card"')
    total = featured_count + article_count
    issues, passed = [], []
    if total == 6:
        passed.append(f'{PASS} Total highlight cards: {total} ({featured_count} featured + {article_count} article)')
    elif total == 0:
        issues.append(f'{FAIL} No highlight cards found (.att-featured or .att-article-card)')
    else:
        issues.append(f'{FAIL} Total highlight cards: {total} — expected 6 ({featured_count} featured + {article_count} article)')
    for line in passed + issues: print(f'  {line}')
    issue_count += len(issues)

    print('\n  ── Cross-links to other silos ──')
    r = check_crosslinks(html, ['tickets', 'plan-your-visit'])
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    print('\n  ── Red CTA banner ──')
    r = check_cta_banner(html)
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    print('\n  ── FAQs ──')
    r = check_faqs(html, 'wts-faqs')
    for line in flatten(r): print(f'  {line}')
    issue_count += len(r[0])

    return issue_count


PAGE_SPECS = {
    'plan-your-visit': {
        'file':    'plan-your-visit.html',
        'wrapper': 'att-plan-page',
        'checker': check_plan_your_visit,
    },
    'tickets-tours': {
        'file':    'tickets-tours.html',
        'wrapper': 'att-tickets-page',
        'checker': check_tickets_tours,
    },
    'what-to-see': {
        'file':    'what-to-see.html',
        'wrapper': 'att-see-page',
        'checker': check_what_to_see,
    },
}

# ── Util ──────────────────────────────────────────────────────────────────────

def flatten(result):
    """Return issues + passed as a single list."""
    return result[1] + result[0]   # passed first, issues last


# ── Runner ────────────────────────────────────────────────────────────────────

def run(site_slug, page_filter=None, html_override=None, repo_root=None):
    if repo_root is None:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

    pages = PAGE_SPECS
    if page_filter:
        pages = {k: v for k, v in PAGE_SPECS.items() if k == page_filter}
        if not pages:
            print(f'Unknown page "{page_filter}". Valid: {", ".join(PAGE_SPECS)}')
            sys.exit(1)

    grand_total = 0

    for page_key, spec in pages.items():
        if html_override:
            html_path = html_override
        else:
            html_path = os.path.join(repo_root, 'output', site_slug, 'l1-pages', spec['file'])

        print(f'\n{"="*70}')
        print(f'  L1 Page Check — {page_key}  [{site_slug}]')
        print(f'  File: {os.path.relpath(html_path, repo_root)}')
        print(f'{"="*70}')

        if not os.path.exists(html_path):
            print(f'  {FAIL} File not found: {html_path}')
            grand_total += 1
            continue

        html = open(html_path).read()

        # Wrapper class
        if spec['wrapper'] in html:
            print(f'\n  {PASS} Root wrapper (.{spec["wrapper"]}) present')
        else:
            print(f'\n  {FAIL} Root wrapper (.{spec["wrapper"]}) missing')
            grand_total += 1

        total_issues = spec['checker'](html)
        grand_total += total_issues

        print(f'\n{"="*70}')
        if total_issues == 0:
            print(f'  {PASS} All checks passed')
        else:
            print(f'  ❌ {total_issues} issue(s) found')
        print(f'{"="*70}')

    if len(pages) > 1:
        print(f'\n  {"✅ Grand total: 0 issues" if grand_total == 0 else f"❌ Grand total: {grand_total} issue(s)"}  across {len(pages)} L1 pages\n')

    return grand_total


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 check-l1-html.py <site-slug> [--page plan-your-visit|tickets-tours|what-to-see] [--html path]')
        sys.exit(1)

    site_slug = sys.argv[1]
    page_filter = None
    html_override = None

    if '--page' in sys.argv:
        page_filter = sys.argv[sys.argv.index('--page') + 1]
    if '--html' in sys.argv:
        html_override = sys.argv[sys.argv.index('--html') + 1]

    sys.exit(run(site_slug, page_filter, html_override))
