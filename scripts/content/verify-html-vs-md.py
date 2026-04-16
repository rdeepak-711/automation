#!/usr/bin/env python3
"""
verify-html-vs-md.py

Cross-verifies generated HTML against source MD for each article.
Checks: H2 sections present, key paragraphs present, FAQ questions present.

Usage:
    python3 scripts/content/verify-html-vs-md.py angkor-wat
    python3 scripts/content/verify-html-vs-md.py angkor-wat --silo tickets-tours
    python3 scripts/content/verify-html-vs-md.py angkor-wat --slug angkor-bike-tour
"""

import sys, os, re, glob, html as html_lib

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

args = sys.argv[1:]
SITE_SLUG = args[0] if args else None
FILTER_SILO = None
FILTER_SLUG = None
for i, a in enumerate(args):
    if a == "--silo" and i+1 < len(args):
        FILTER_SILO = args[i+1]
    if a == "--slug" and i+1 < len(args):
        FILTER_SLUG = args[i+1]

if not SITE_SLUG:
    print("Usage: verify-html-vs-md.py <site-slug> [--silo <silo>] [--slug <slug>]")
    sys.exit(1)

INPUT  = os.path.join(REPO, "input", SITE_SLUG)
OUTPUT = os.path.join(REPO, "output", SITE_SLUG, "l2-articles")
SILOS  = ["tickets-tours", "plan-your-visit", "what-to-see"]

def strip_html(text):
    text = html_lib.unescape(text)
    text = re.sub(r'<[^>]+>', '', text)
    return text.strip()

def normalize(text):
    text = html_lib.unescape(text)
    text = re.sub(r'[^\w\s]', ' ', text.lower())
    return re.sub(r'\s+', ' ', text).strip()

def extract_md_h2s(md):
    return re.findall(r'^## (.+)', md, re.MULTILINE)

def extract_md_faqs(md):
    return re.findall(r'^\*\*(.+\?)\*\*', md, re.MULTILINE)

def extract_md_paragraphs(md):
    """Extract first sentence of each non-header, non-list paragraph."""
    lines = md.split('\n')
    paras = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('-') or line.startswith('*') or line.startswith('>') or line.startswith('`') or line.startswith('|'):
            continue
        # First sentence
        sentence = re.split(r'(?<=[.!?])\s', line)[0]
        if len(sentence) > 40:
            paras.append(sentence)
    return paras[:5]  # check first 5 paragraphs

def extract_html_h2s(html):
    return [strip_html(m) for m in re.findall(r'<h2[^>]*>(.*?)</h2>', html, re.DOTALL)]

def extract_html_text(html):
    # Strip style/script blocks
    html = re.sub(r'<style[^>]*>.*?</style>', '', html, flags=re.DOTALL)
    html = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL)
    return normalize(strip_html(html))

def check_article(md_path, html_path, slug):
    issues = []
    passed = []

    md   = open(md_path).read()
    html = open(html_path).read()

    html_text = extract_html_text(html)

    # ── 1. H2 sections ───────────────────────────────────────────────────────
    md_h2s   = extract_md_h2s(md)
    html_h2s = extract_html_h2s(html)

    skip_h2s = {"Book This Tour", "Top Tickets", "Buy This Ticket", "Book This Ticket", "Related Guides"}

    for h2 in md_h2s:
        if h2 in skip_h2s:
            continue
        h2_norm = normalize(h2)
        found = any(h2_norm in normalize(hh) or normalize(hh) in h2_norm for hh in html_h2s)
        if found:
            passed.append(f"H2 present: {h2}")
        else:
            issues.append(f"MISSING H2: '{h2}'")

    # ── 2. FAQ questions ──────────────────────────────────────────────────────
    md_faqs = extract_md_faqs(md)
    for q in md_faqs:
        q_norm = normalize(q)[:60]
        if q_norm in html_text:
            passed.append(f"FAQ present: {q[:60]}")
        else:
            issues.append(f"MISSING FAQ: '{q[:70]}'")

    # ── 3. Key paragraphs (first sentence check) ──────────────────────────────
    md_paras = extract_md_paragraphs(md)
    missing_paras = 0
    for para in md_paras:
        para_norm = normalize(para)[:80]
        if para_norm not in html_text:
            missing_paras += 1
    if missing_paras == 0:
        passed.append(f"Intro paragraphs: all {len(md_paras)} present")
    elif missing_paras == len(md_paras):
        issues.append(f"MISSING PARAGRAPHS: all {len(md_paras)} intro paragraphs absent — likely truncated conversion")
    else:
        issues.append(f"MISSING PARAGRAPHS: {missing_paras}/{len(md_paras)} intro paragraphs absent")

    return issues, passed

# ── Run ───────────────────────────────────────────────────────────────────────

total_ok = 0
total_fail = 0
failed_slugs = []

for silo in SILOS:
    if FILTER_SILO and silo != FILTER_SILO:
        continue

    md_dir   = os.path.join(INPUT, silo)
    html_dir = os.path.join(OUTPUT, silo)

    for md_path in sorted(glob.glob(os.path.join(md_dir, "*.md"))):
        slug = re.sub(r'^article\d+_', '', os.path.basename(md_path).replace('.md', ''))
        if FILTER_SLUG and slug != FILTER_SLUG:
            continue

        html_path = os.path.join(html_dir, slug + ".html")
        if not os.path.exists(html_path):
            print(f"  ⚠  [{silo}] {slug} — no HTML file")
            continue

        issues, passed = check_article(md_path, html_path, slug)

        if issues:
            total_fail += 1
            failed_slugs.append(f"{silo}/{slug}")
            print(f"\n  ✗  [{silo}] {slug}")
            for i in issues:
                print(f"       {i}")
        else:
            total_ok += 1
            if FILTER_SLUG:
                print(f"\n  ✓  [{silo}] {slug}")
                for p in passed:
                    print(f"       {p}")
            else:
                print(f"  ✓  [{silo}] {slug}")

print(f"\n{'='*70}")
print(f"  RESULT: {total_ok} passed  |  {total_fail} failed")
if failed_slugs:
    print(f"\n  Failed articles:")
    for s in failed_slugs:
        print(f"    - {s}")
print(f"{'='*70}\n")
