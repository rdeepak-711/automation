#!/usr/bin/env python3
"""
check-sample-html.py — verify L2 sample HTMLs against source MD and template.

Checks:
  1. Template compliance  — required CSS classes, structural elements
  2. Content fidelity     — H2s, FAQs, related links match source MD
  3. Schema               — FAQPage JSON-LD present and populated

Usage:
  python3 scripts/content/check-sample-html.py <site-slug>
  python3 scripts/content/check-sample-html.py <site-slug> --html path/to/file.html
"""

import sys, os, re, json, glob
from html import unescape

# ── Config ────────────────────────────────────────────────────────────────────
REQUIRED_CLASSES = [
    'att-article-page',
    'att-container',
    'att-article-header',
    'att-article-header__image',
    'att-article-body',
    'att-top-tickets',
    'att-top-tickets__list',
    'att-related',
    'att-related__list',
]

# Required unless the article uses the FAQ-page layout (att-faq-qa)
REQUIRED_UNLESS_FAQ_PAGE = [
    'att-aeo-block',
    'att-faq',
    'att-faq-details',
    'att-faq-summary',
    'att-faq-content',
    'att-buy-now-btn',
]

OPTIONAL_CLASSES = [
    'att-price-table',
    'att-tip-box',
    'att-article-header__subtitle',
]

PASS = '✅'
FAIL = '❌'
WARN = '⚠️ '
INFO = '   '

# ── Helpers ───────────────────────────────────────────────────────────────────
def extract_classes(html):
    classes = set()
    for m in re.finditer(r'class="([^"]*)"', html):
        for c in m.group(1).split():
            classes.add(c)
    return classes

def extract_h2s(html):
    return re.findall(r'<h2[^>]*>\s*(.*?)\s*</h2>', html, re.IGNORECASE | re.DOTALL)

def extract_h1(html):
    m = re.search(r'<h1[^>]*>\s*(.*?)\s*</h1>', html, re.IGNORECASE | re.DOTALL)
    return re.sub(r'<[^>]+>', '', m.group(1)).strip() if m else None

def extract_faq_questions_html(html):
    # Standard accordion pattern: att-faq-summary
    summaries = re.findall(r'<summary[^>]*class="[^"]*att-faq-summary[^"]*"[^>]*>\s*(.*?)\s*</summary>', html, re.DOTALL)
    if summaries:
        return [re.sub(r'<[^>]+>', '', s).strip() for s in summaries]
    # FAQ-page pattern: att-faq-question h3
    questions = re.findall(r'<h3[^>]*class="[^"]*att-faq-question[^"]*"[^>]*>\s*(.*?)\s*</h3>', html, re.DOTALL)
    return [re.sub(r'<[^>]+>', '', q).strip() for q in questions]

def is_faq_page(html):
    return bool(re.search(r'att-faq-qa', html))

def extract_schema_faqs(html):
    m = re.search(r'<script[^>]+type="application/ld\+json"[^>]*>(.*?)</script>', html, re.DOTALL)
    if not m:
        return None
    try:
        data = json.loads(m.group(1))
        if data.get('@type') == 'FAQPage':
            return [e['name'] for e in data.get('mainEntity', [])]
    except Exception:
        pass
    return None

def strip_md(text):
    text = re.sub(r'\*\*|__|\*|_|`', '', text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    return text.strip()

def parse_md(md_path):
    """Extract H2s, H3s, FAQ questions, related links, top-ticket links, aeo blocks from MD."""
    result = {'h2s': [], 'h3s': [], 'faqs': [], 'related': [], 'top_tickets': [], 'aeo_blocks': []}
    if not os.path.exists(md_path):
        return result

    content = open(md_path).read()
    skip_h2 = {'Frequently Asked Questions', 'Related Guides', 'Related Articles'}

    # H2 headings
    result['h2s'] = [strip_md(h) for h in re.findall(r'^## (.+)', content, re.MULTILINE)
                     if h.strip() not in skip_h2]
    # H3 headings (questions in FAQ-page articles)
    result['h3s'] = [strip_md(h) for h in re.findall(r'^### (.+)', content, re.MULTILINE)]

    # FAQ questions — under ## Frequently Asked Questions
    faq_section = re.search(r'## Frequently Asked Questions\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if faq_section:
        result['faqs'] = [strip_md(q) for q in re.findall(r'\*\*(.+?)\*\*', faq_section.group(1))]
        if not result['faqs']:
            result['faqs'] = [strip_md(q.lstrip('- ')) for q in
                              re.findall(r'^[-*]\s*\*\*?(.+?)\*\*?', faq_section.group(1), re.MULTILINE)]

    # Related links
    related_section = re.search(r'## Related (?:Guides|Articles)\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if related_section:
        result['related'] = re.findall(r'\[([^\]]+)\]', related_section.group(1))

    # Top tickets
    top_section = re.search(r'(?:## )?Top Tickets?\n(.*?)(?=\n## )', content, re.DOTALL)
    if top_section:
        result['top_tickets'] = re.findall(r'\[([^\]]+)\]', top_section.group(1))

    # AEO blocks — distinct blockquote groups + capture their answer text
    for m in re.finditer(r'(?:^>.*\n?)+', content, re.MULTILINE):
        block_text = re.sub(r'^>\s*\*\*Quick Answer:?\*\*\s*\n?', '', m.group(0), flags=re.MULTILINE)
        answer = re.sub(r'^>\s*', '', block_text, flags=re.MULTILINE).strip()
        if answer:
            result['aeo_blocks'].append(answer)

    return result

def normalize(text):
    text = unescape(text)  # decode &amp; &mdash; &rsquo; etc.
    text = text.replace('—', ' ').replace('–', ' ').replace("'", '').replace('"', '')
    return re.sub(r'\s+', ' ', re.sub(r'[^\w\s]', '', text.lower())).strip()

def fuzzy_present(needle, haystack_list, threshold=0.7):
    """Check if needle is present in haystack_list using word overlap."""
    nw = set(normalize(needle).split())
    for h in haystack_list:
        hw = set(normalize(h).split())
        if not nw: continue
        overlap = len(nw & hw) / len(nw)
        if overlap >= threshold:
            return h
    return None

# ── Main checker ──────────────────────────────────────────────────────────────
def check_html(html_path, md_path, label):
    issues = []
    warnings = []
    passed = []

    if not os.path.exists(html_path):
        return [f'{FAIL} File not found: {html_path}'], [], []

    html = open(html_path).read()
    md_data = parse_md(md_path)

    # ── 1. Template compliance ────────────────────────────────────────────────
    classes = extract_classes(html)
    faq_page = is_faq_page(html)

    effective_required = REQUIRED_CLASSES + ([] if faq_page else REQUIRED_UNLESS_FAQ_PAGE)
    missing_required = [c for c in effective_required if c not in classes]
    missing_optional = [c for c in OPTIONAL_CLASSES if c not in classes]

    if missing_required:
        for c in missing_required:
            issues.append(f'{FAIL} Missing required class: .{c}')
    else:
        passed.append(f'{PASS} All {len(effective_required)} required template classes present')

    for c in missing_optional:
        warnings.append(f'{WARN} Optional class absent: .{c}')

    # H1
    h1 = extract_h1(html)
    if h1:
        passed.append(f'{PASS} H1 present: "{h1[:60]}"')
    else:
        issues.append(f'{FAIL} No <h1> found')

    # FAQ structure — accept either accordion (att-faq-details) or FAQ-page (att-faq-qa)
    details_count = len(re.findall(r'<details', html, re.IGNORECASE))
    faq_qa_count = len(re.findall(r'class="att-faq-qa"', html))
    if details_count > 0:
        passed.append(f'{PASS} FAQ uses <details> accordion ({details_count} items)')
    elif faq_qa_count > 0:
        passed.append(f'{PASS} FAQ uses Q&A page layout ({faq_qa_count} questions)')
    else:
        issues.append(f'{FAIL} No FAQ structure found (<details> accordion or att-faq-qa)')

    # ── 2. Content fidelity vs MD ─────────────────────────────────────────────
    html_h2s = extract_h2s(html)
    html_text_plain = unescape(re.sub(r'<[^>]+>', ' ', html))

    # H2 sections
    if md_data['h2s']:
        missing_h2s = [h for h in md_data['h2s'] if not fuzzy_present(h, html_h2s)]
        if missing_h2s:
            for h in missing_h2s:
                issues.append(f'{FAIL} MD H2 missing in HTML: "{h}"')
        else:
            passed.append(f'{PASS} All {len(md_data["h2s"])} MD H2 sections present in HTML')

    # H3 questions (FAQ-page articles have all content under H3s)
    if md_data['h3s']:
        html_h3s = [re.sub(r'<[^>]+>', '', h).strip()
                    for h in re.findall(r'<h3[^>]*>(.*?)</h3>', html, re.DOTALL)]
        missing_h3s = [h for h in md_data['h3s'] if not fuzzy_present(h, html_h3s)]
        if missing_h3s:
            for h in missing_h3s:
                issues.append(f'{FAIL} MD H3 question missing in HTML: "{h[:70]}"')
        else:
            passed.append(f'{PASS} All {len(md_data["h3s"])} MD H3 questions present in HTML')

    # FAQ questions (standard accordion articles)
    if md_data['faqs']:
        html_faq_qs = extract_faq_questions_html(html)
        missing_faqs = [q for q in md_data['faqs'] if not fuzzy_present(q, html_faq_qs)]
        if missing_faqs:
            for q in missing_faqs:
                issues.append(f'{FAIL} MD FAQ question missing in HTML: "{q[:60]}"')
        else:
            passed.append(f'{PASS} All {len(md_data["faqs"])} FAQ questions rendered')
    elif not md_data['h3s']:
        warnings.append(f'{WARN} No FAQ questions found in MD (check format)')

    # AEO blocks — verify both count and content presence (skip for FAQ-page layout)
    aeo_blocks = md_data['aeo_blocks']
    html_aeo_count = len(re.findall(r'class="att-aeo-block"', html))
    if faq_page and aeo_blocks:
        passed.append(f'{PASS} FAQ-page layout — AEO blocks embedded as Q&A answers (not checked separately)')
        aeo_blocks = []  # suppress further aeo checks
    if aeo_blocks:
        missing_aeo = []
        for answer_text in aeo_blocks:
            # Check first 60 chars of answer appear somewhere in HTML text
            snippet = normalize(answer_text[:60])
            if snippet and snippet not in normalize(html_text_plain):
                missing_aeo.append(answer_text[:60])
        if html_aeo_count == 0 and aeo_blocks:
            issues.append(f'{FAIL} MD has {len(aeo_blocks)} Quick Answer block(s) but 0 .att-aeo-block rendered')
        elif missing_aeo:
            for snip in missing_aeo:
                issues.append(f'{FAIL} AEO answer content missing in HTML: "{snip}..."')
        else:
            passed.append(f'{PASS} AEO blocks: {html_aeo_count} rendered, all answer content present')

    # Related links
    if md_data['related']:
        html_text = re.sub(r'<[^>]+>', ' ', html)
        missing_related = [r for r in md_data['related'] if normalize(r) not in normalize(html_text)]
        if missing_related:
            for r in missing_related:
                warnings.append(f'{WARN} Related link may be missing: "{r}"')
        else:
            passed.append(f'{PASS} Related links section present ({len(md_data["related"])} links)')

    # Top tickets bar
    top_ticket_links = re.findall(r'att-top-tickets__list.*?</ul>', html, re.DOTALL)
    link_count = len(re.findall(r'<li', top_ticket_links[0])) if top_ticket_links else 0
    if link_count >= 2:
        passed.append(f'{PASS} Top-tickets bar has {link_count} links')
    elif link_count == 1:
        warnings.append(f'{WARN} Top-tickets bar has only 1 link (expected 2)')
    else:
        issues.append(f'{FAIL} Top-tickets bar is empty or missing')

    # ── 3. Schema ─────────────────────────────────────────────────────────────
    schema_faqs = extract_schema_faqs(html)
    if schema_faqs is None:
        issues.append(f'{FAIL} No FAQPage JSON-LD schema found')
    elif len(schema_faqs) == 0:
        issues.append(f'{FAIL} FAQPage schema present but mainEntity is empty')
    else:
        passed.append(f'{PASS} FAQPage schema: {len(schema_faqs)} Q&As')

    # Schema FAQ count vs rendered FAQ count
    html_faq_qs = extract_faq_questions_html(html)
    if schema_faqs and html_faq_qs and len(schema_faqs) != len(html_faq_qs):
        warnings.append(f'{WARN} Schema has {len(schema_faqs)} FAQs but accordion has {len(html_faq_qs)} — mismatch')

    return issues, warnings, passed

# ── Discovery + report ────────────────────────────────────────────────────────
def find_md_for_html(html_path, site_slug, repo_root):
    """Find the source MD file for a given HTML output path."""
    # html: output/<site>/l2-articles/<silo>/<slug>.html
    # md:   input/<site>/<silo-dir>/article-NN-<slug>.md
    slug = os.path.splitext(os.path.basename(html_path))[0]
    silo_dir = os.path.basename(os.path.dirname(html_path))
    # silo_dir in output is 'tickets-tours' | 'plan-your-visit' | 'what-to-see'
    md_dir = os.path.join(repo_root, 'input', site_slug, silo_dir)
    # find article-NN-<slug>.md
    pattern = os.path.join(md_dir, f'*{slug}.md')
    matches = glob.glob(pattern)
    return matches[0] if matches else None

def run(site_slug, html_files=None, repo_root=None):
    if repo_root is None:
        repo_root = os.path.join(os.path.dirname(__file__), '..', '..')
        repo_root = os.path.abspath(repo_root)

    if html_files is None:
        base = os.path.join(repo_root, 'output', site_slug, 'l2-articles')
        html_files = []
        for silo in ['tickets-tours', 'plan-your-visit', 'what-to-see']:
            silo_path = os.path.join(base, silo)
            if os.path.isdir(silo_path):
                html_files += sorted(glob.glob(os.path.join(silo_path, '*.html')))

    if not html_files:
        print(f'No HTML files found for {site_slug}')
        sys.exit(1)

    total_issues = 0
    total_warnings = 0

    print(f'\n{"="*70}')
    print(f'  L2 HTML Check — {site_slug}  ({len(html_files)} file(s))')
    print(f'{"="*70}')

    for html_path in html_files:
        slug = os.path.splitext(os.path.basename(html_path))[0]
        silo = os.path.basename(os.path.dirname(html_path))
        label = f'{silo}/{slug}'
        md_path = find_md_for_html(html_path, site_slug, repo_root)

        print(f'\n  ── {label} ──')
        if md_path:
            print(f'  {INFO} MD: {os.path.relpath(md_path, repo_root)}')
        else:
            print(f'  {WARN} No source MD found — content checks skipped')

        issues, warnings, passed = check_html(html_path, md_path or '', label)

        for p in passed:
            print(f'  {p}')
        for w in warnings:
            print(f'  {w}')
        for i in issues:
            print(f'  {i}')

        total_issues += len(issues)
        total_warnings += len(warnings)

    print(f'\n{"="*70}')
    if total_issues == 0 and total_warnings == 0:
        print(f'  {PASS} All checks passed — {len(html_files)} file(s) clean')
    elif total_issues == 0:
        print(f'  {WARN} {total_warnings} warning(s), 0 blockers across {len(html_files)} file(s)')
    else:
        print(f'  {FAIL} {total_issues} issue(s), {total_warnings} warning(s) across {len(html_files)} file(s)')
    print(f'{"="*70}\n')

    return total_issues

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 check-sample-html.py <site-slug> [--html file.html ...]')
        sys.exit(1)

    site_slug = sys.argv[1]
    html_files = None

    if '--html' in sys.argv:
        idx = sys.argv.index('--html')
        html_files = sys.argv[idx+1:]

    sys.exit(run(site_slug, html_files))
