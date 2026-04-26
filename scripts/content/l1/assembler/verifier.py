#!/usr/bin/env python3
"""
verifier.py — Claude semantic verifier for L1 plan-your-visit pages.

Extracts content signals from generated HTML and asks Claude to judge
faithfulness, interlink quality, and content specificity.

Claude returns:
  {"pass": true|false, "issues": [{"severity", "area", "where", "description"}]}

Blockers (exit 1):  colon H2s, orphan interlinks, generic filler FAQs, banner
                    missing attraction name.
Warnings (log only): quicktips 0 interlinks, know-tips < 2, brief repeats title.
Fail-safe: Claude unavailable → (True, []) — never blocks the pipeline.
"""

import json
import os
import re
import subprocess
import sys


VERIFIER_MODEL = os.environ.get("CLAUDE_L1_VERIFIER_MODEL", "claude-haiku-4-5-20251001")


def verify(
    html: str,
    articles: list[dict],
    attraction: str,
    config: dict,
) -> tuple[bool, list[dict]]:
    """
    Returns (pass: bool, issues: list).
    Blockers block; warnings are returned but do not block.
    """
    signals = _extract_signals(html)
    known_slugs = {a["url_slug"] for a in articles}
    prompt = _build_prompt(signals, known_slugs, attraction)
    raw = _call_claude(prompt)

    if raw is None:
        print("[verifier] WARNING: Claude verification skipped (Claude CLI unavailable)", file=sys.stderr)
        return (True, [])

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except json.JSONDecodeError:
                print(f"[verifier] WARNING: could not parse output: {raw[:200]}", file=sys.stderr)
                return (True, [])
        else:
            return (True, [])

    issues = result.get("issues", [])
    blockers = [i for i in issues if i.get("severity") == "blocker"]
    return (len(blockers) == 0, issues)


def _extract_signals(html: str) -> dict:
    """Pull content signals from HTML — no raw HTML sent to Claude."""

    # H2s
    h2s = [re.sub(r"<[^>]+>", "", h).strip()
           for h in re.findall(r"<h2[^>]*>(.*?)</h2>", html, re.DOTALL | re.IGNORECASE)]

    # Article cards: h3 + brief + whether "Read guide" link exists
    cards = []
    for m in re.finditer(r'class="att-article-card"(.*?)(?=class="att-article-card"|</div>\s*</div>\s*</div>)', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3[^>]*><a[^>]*>([^<]+)</a>", block)
        brief = re.search(r'class="att-article-card__desc"[^>]*>(.*?)</p>', block, re.DOTALL)
        cards.append({
            "title": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "brief": re.sub(r"<[^>]+>", "", brief.group(1)).strip()[:100] if brief else "",
        })

    # Quicktips: label + desc + links
    quicktips = []
    for m in re.finditer(r'class="att-quicktip"(.*?)</div>\s*</div>', html, re.DOTALL):
        block = m.group(1)
        label = re.search(r'class="att-quicktip__label"[^>]*>(.*?)</div>', block, re.DOTALL)
        para = re.search(r"<p>(.*?)</p>", block, re.DOTALL)
        links = re.findall(r'href="(/plan-your-visit/[^"]+)"', block)
        quicktips.append({
            "label": re.sub(r"<[^>]+>", "", label.group(1)).strip() if label else "",
            "desc": re.sub(r"<[^>]+>", "", para.group(1)).strip()[:150] if para else "",
            "links": links,
        })

    # Practical cards: h3 + items + links
    practical = []
    for m in re.finditer(r'class="att-practical-card"(.*?)</div>\s*</div>', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3>(.*?)</h3>", block, re.DOTALL)
        items = re.findall(r"<li>(.*?)</li>", block, re.DOTALL)
        links = re.findall(r'href="(/plan-your-visit/[^"]+)"', block)
        practical.append({
            "h3": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "items": [re.sub(r"<[^>]+>", "", i).strip()[:80] for i in items[:3]],
            "links": links,
        })

    # Know-tips: label + desc + links
    know_tips = []
    for m in re.finditer(r'class="att-tip"(.*?)</div>', html, re.DOTALL):
        block = m.group(1)
        label = re.search(r"<strong>(.*?)</strong>", block, re.DOTALL)
        links = re.findall(r'href="(/plan-your-visit/[^"]+)"', block)
        text = re.sub(r"<[^>]+>", "", block).strip()[:120]
        know_tips.append({
            "label": re.sub(r"<[^>]+>", "", label.group(1)).strip() if label else "",
            "desc": text,
            "links": links,
        })

    # FAQs: question + first 200 chars of answer
    faqs = []
    for m in re.finditer(r'<span itemprop="name">(.*?)</span>.*?<span itemprop="text">(.*?)</span>', html, re.DOTALL):
        q = re.sub(r"<[^>]+>", "", m.group(1)).strip()
        a = re.sub(r"<[^>]+>", "", m.group(2)).strip()[:200]
        faqs.append({"question": q, "answer": a})

    # Banner
    banner_h2 = ""
    banner_m = re.search(r'class="att-cta-banner".*?<h2>(.*?)</h2>', html, re.DOTALL)
    if banner_m:
        banner_h2 = re.sub(r"<[^>]+>", "", banner_m.group(1)).strip()

    # All plan-your-visit hrefs (to check for orphans)
    all_pyv_links = re.findall(r'href="(/plan-your-visit/[^"]+)"', html)

    return {
        "h2s": h2s,
        "cards": cards[:5],
        "quicktips": quicktips,
        "practical": practical,
        "know_tips": know_tips,
        "faqs": faqs[:5],
        "banner_h2": banner_h2,
        "all_pyv_links": list(set(all_pyv_links)),
    }


def _build_prompt(signals: dict, known_slugs: set[str], attraction: str) -> str:
    known_slugs_list = "\n".join(f"  /plan-your-visit/{s}/" for s in sorted(known_slugs))

    h2_block = "\n".join(f"  - {h}" for h in signals["h2s"])
    card_block = "\n".join(
        f"  - Title: {c['title']!r}\n    Brief: {c['brief']!r}"
        for c in signals["cards"]
    )
    quicktip_block = "\n".join(
        f"  - [{t['label']}] {t['desc']!r} | links: {t['links']}"
        for t in signals["quicktips"]
    )
    practical_block = "\n".join(
        f"  - [{c['h3']}] items: {c['items']} | links: {c['links']}"
        for c in signals["practical"]
    )
    know_tip_block = "\n".join(
        f"  - [{t['label']}] {t['desc']!r} | links: {t['links']}"
        for t in signals["know_tips"]
    )
    faq_block = "\n".join(
        f"  Q: {f['question']!r}\n  A: {f['answer']!r}"
        for f in signals["faqs"]
    )
    pyv_links_block = "\n".join(f"  {lnk}" for lnk in signals["all_pyv_links"])

    return f"""You are a strict content reviewer for a travel website about {attraction!r}.
Review the extracted content signals below and identify quality issues.

## Valid article slugs (interlinks must point to one of these)
{known_slugs_list or "  (none)"}

## Extracted HTML signals

### H2 section headings
{h2_block or "  (none)"}

### Article cards (sample)
{card_block or "  (none)"}

### Quicktips (4 cards)
{quicktip_block or "  (none)"}

### Practical information cards
{practical_block or "  (none)"}

### Things to know tips
{know_tip_block or "  (none)"}

### FAQs (sample)
{faq_block or "  (none)"}

### Banner H2
{signals["banner_h2"] or "  (absent)"}

### All /plan-your-visit/ links in page
{pyv_links_block or "  (none)"}

## Your task

Return ONLY a JSON object:
{{
  "pass": true or false,
  "issues": [
    {{
      "severity": "blocker" or "warning",
      "area": "h2" | "coverage" | "interlink" | "relevance" | "tone" | "faq",
      "where": "e.g. Quicktip 'Tickets'",
      "description": "specific problem"
    }}
  ]
}}

## Rules (check every item)

BLOCKERS — set pass to false if ANY blocker exists:
1. An H2 uses "Attraction: Section" colon-join pattern (e.g. "{attraction}: When to Go")
2. Any /plan-your-visit/ link target is NOT in the valid slug list above (orphan link)
3. A FAQ answer is generic filler with no {attraction}-specific detail (e.g. "Consult the official website", "Opening hours vary")

WARNINGS — include in issues but do NOT change pass to false:
4. All 4 quicktips have zero interlinks (poor interlinking)
5. Fewer than 2 of the know-tips have any interlink
6. A card brief is nearly identical to its title (no added value)
7. An H2 heading (that is NOT one of the fixed template H2s below) does not mention {attraction!r}
8. The banner H2 does not reference the attraction subject at all (a banner like "Ready to plan your canal cruise?" is acceptable even if it abbreviates the name)

Fixed template H2s (do NOT flag these for missing attraction name — they are intentionally generic):
- "Practical Information"
- "Things to Know Before You Book"
- "Continue Exploring …" (any H2 starting with "Continue Exploring")
- "Frequently Asked Questions"

If nothing is wrong, return {{"pass": true, "issues": []}}.
Return ONLY the JSON — no preamble, no markdown fence.
"""


def verify_wts(
    html: str,
    articles: list[dict],
    attraction: str,
    config: dict,
) -> tuple[bool, list[dict]]:
    """WTS semantic verifier. Returns (pass: bool, issues: list)."""
    signals = _extract_signals_wts(html)
    known_slugs = {a["url_slug"] for a in articles}
    prompt = _build_prompt_wts(signals, known_slugs, attraction)
    raw = _call_claude(prompt)

    if raw is None:
        print("[verifier] WARNING: Claude verification skipped (Claude CLI unavailable)", file=sys.stderr)
        return (True, [])

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except json.JSONDecodeError:
                print(f"[verifier] WARNING: could not parse output: {raw[:200]}", file=sys.stderr)
                return (True, [])
        else:
            return (True, [])

    issues = result.get("issues", [])
    blockers = [i for i in issues if i.get("severity") == "blocker"]
    return (len(blockers) == 0, issues)


def _extract_signals_wts(html: str) -> dict:
    """Pull content signals from WTS HTML."""
    h2s = [re.sub(r"<[^>]+>", "", h).strip()
           for h in re.findall(r"<h2[^>]*>(.*?)</h2>", html, re.DOTALL | re.IGNORECASE)]

    featured = []
    for m in re.finditer(r'class="att-featured"(.*?)(?=class="att-featured"|</div>\s*</div>\s*</section>)', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3[^>]*><a[^>]*>([^<]+)</a>", block)
        desc = re.search(r'class="att-featured__desc"[^>]*>(.*?)</p>', block, re.DOTALL)
        featured.append({
            "title": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "desc": re.sub(r"<[^>]+>", "", desc.group(1)).strip()[:120] if desc else "",
        })

    cards = []
    for m in re.finditer(r'class="att-article-card"(.*?)(?=class="att-article-card"|</div>\s*</div>\s*</div>)', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3[^>]*><a[^>]*>([^<]+)</a>", block)
        brief = re.search(r'class="att-article-card__desc"[^>]*>(.*?)</p>', block, re.DOTALL)
        cards.append({
            "title": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "brief": re.sub(r"<[^>]+>", "", brief.group(1)).strip()[:100] if brief else "",
        })

    guide_cards = []
    for m in re.finditer(r'class="att-guide-card"(.*?)(?=class="att-guide-card"|</div>\s*</div>\s*</div>)', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3[^>]*>(.*?)</h3>", block, re.DOTALL)
        items = re.findall(r"<li>(.*?)</li>", block, re.DOTALL)
        guide_cards.append({
            "h3": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "items": [re.sub(r"<[^>]+>", "", i).strip()[:80] for i in items[:3]],
        })

    faqs = []
    for m in re.finditer(r'<span itemprop="name">(.*?)</span>.*?<span itemprop="text">(.*?)</span>', html, re.DOTALL):
        q = re.sub(r"<[^>]+>", "", m.group(1)).strip()
        a = re.sub(r"<[^>]+>", "", m.group(2)).strip()[:200]
        faqs.append({"question": q, "answer": a})

    banner_h2 = ""
    banner_m = re.search(r'class="att-cta-banner".*?<h2>(.*?)</h2>', html, re.DOTALL)
    if banner_m:
        banner_h2 = re.sub(r"<[^>]+>", "", banner_m.group(1)).strip()

    all_wts_links = re.findall(r'href="(/what-to-see/[^"]+)"', html)

    return {
        "h2s": h2s,
        "featured": featured,
        "cards": cards[:5],
        "guide_cards": guide_cards,
        "faqs": faqs[:5],
        "banner_h2": banner_h2,
        "all_wts_links": list(set(all_wts_links)),
    }


def _build_prompt_wts(signals: dict, known_slugs: set[str], attraction: str) -> str:
    known_slugs_list = "\n".join(f"  /what-to-see/{s}/" for s in sorted(known_slugs))
    h2_block = "\n".join(f"  - {h}" for h in signals["h2s"])
    featured_block = "\n".join(
        f"  - Title: {c['title']!r}\n    Desc: {c['desc']!r}"
        for c in signals["featured"]
    )
    card_block = "\n".join(
        f"  - Title: {c['title']!r}\n    Brief: {c['brief']!r}"
        for c in signals["cards"]
    )
    guide_block = "\n".join(
        f"  - [{c['h3']}] items: {c['items']}"
        for c in signals["guide_cards"]
    )
    faq_block = "\n".join(
        f"  Q: {f['question']!r}\n  A: {f['answer']!r}"
        for f in signals["faqs"]
    )
    wts_links_block = "\n".join(f"  {lnk}" for lnk in signals["all_wts_links"])

    return f"""You are a strict content reviewer for a travel website about {attraction!r}.
Review the extracted content signals from a 'What to See' page and identify quality issues.

## Valid article slugs (interlinks must point to one of these)
{known_slugs_list or "  (none)"}

## Extracted HTML signals

### H2 section headings
{h2_block or "  (none)"}

### Featured cards (Top Highlights)
{featured_block or "  (none)"}

### Article cards (sample)
{card_block or "  (none)"}

### How to Choose guide cards
{guide_block or "  (none)"}

### FAQs (sample)
{faq_block or "  (none)"}

### Banner H2
{signals["banner_h2"] or "  (absent)"}

### All /what-to-see/ links in page
{wts_links_block or "  (none)"}

## Your task

Return ONLY a JSON object:
{{
  "pass": true or false,
  "issues": [
    {{
      "severity": "blocker" or "warning",
      "area": "h2" | "coverage" | "interlink" | "relevance" | "tone" | "faq",
      "where": "e.g. Featured card 'Full Canal Guide'",
      "description": "specific problem"
    }}
  ]
}}

## Rules

BLOCKERS — set pass to false if ANY blocker exists:
1. An H2 uses "Attraction: Section" colon-join pattern (e.g. "{attraction}: History")
2. Any /what-to-see/ link target is NOT in the valid slug list above (orphan link)
3. A FAQ answer is generic filler with no {attraction}-specific detail

WARNINGS — include in issues but do NOT change pass to false:
4. A card brief is nearly identical to its title (no added value)
5. An H2 (that is NOT one of the fixed template H2s below) does not mention {attraction!r}
6. The banner H2 does not reference the attraction subject at all

Fixed template H2s (do NOT flag for missing attraction name):
- Any H2 starting with "Top Highlights"
- Any H2 starting with "How to Choose"
- Any H2 starting with "Continue Exploring"
- "Frequently Asked Questions"

If nothing is wrong, return {{"pass": true, "issues": []}}.
Return ONLY the JSON — no preamble, no markdown fence.
"""


def _call_claude(prompt: str) -> str | None:
    try:
        r = subprocess.run(
            ["claude", "--print", "--model", VERIFIER_MODEL],
            input=prompt, capture_output=True, text=True, timeout=90,
        )
        if r.returncode != 0:
            return None
        return r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
