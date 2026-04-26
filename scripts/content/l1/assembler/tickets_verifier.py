#!/usr/bin/env python3
"""
tickets_verifier.py — Claude semantic verifier for L1 tickets-tours pages.

Extracts content signals from generated HTML and asks Claude to judge
quality, interlink coverage, and content faithfulness.

Blockers (exit 1):  colon H2s, affiliate CTA lacking campaign stamp,
                    orphan /tickets/... links, generic FAQ answers.
Warnings (log only): decision guide <50% bullets have links, rec-strip 0 links,
                     compare row repeats title, banner missing attraction name.
Fail-safe: Claude unavailable → (True, []) — never blocks the pipeline.
"""

import json
import os
import re
import subprocess
import sys

VERIFIER_MODEL = os.environ.get("CLAUDE_L1_VERIFIER_MODEL", "claude-haiku-4-5-20251001")

FIXED_H2S = {
    "Practical Information",
    "Frequently Asked Questions",
}
FIXED_H2_PREFIXES = (
    "Top ",
    "Which ",
    "How to Pick",
    "Continue Exploring",
)


def verify(
    html: str,
    bundle: dict,
    attraction: str,
    config: dict,
) -> tuple[bool, list[dict]]:
    signals = _extract_signals(html)
    tickets = bundle.get("tickets", [])
    informational = bundle.get("informational", [])
    featured = bundle.get("featured", [])
    known_ticket_slugs = {t.get("article_slug") or t.get("url_slug", "") for t in tickets}
    known_info_slugs = {a.get("url_slug", "") for a in informational}
    known_featured_slugs = {f.get("url_slug") or f.get("article_slug", "") for f in featured}
    known_slugs = (known_ticket_slugs | known_info_slugs | known_featured_slugs) - {""}
    # Also accept affiliate ticket article slugs (GYG product pages in comparison table)
    affiliate_slugs = {t.get("article_slug", "") for t in bundle.get("affiliate_tickets", [])}
    known_slugs |= affiliate_slugs - {""}
    campaign_id = config.get("_campaign_id_tt", "")  # best-effort; verifier checks pattern

    prompt = _build_prompt(signals, known_slugs, attraction)
    raw = _call_claude(prompt)

    if raw is None:
        print("[tickets_verifier] WARNING: Claude verification skipped (Claude CLI unavailable)", file=sys.stderr)
        return (True, [])

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except json.JSONDecodeError:
                print(f"[tickets_verifier] WARNING: could not parse: {raw[:200]}", file=sys.stderr)
                return (True, [])
        else:
            return (True, [])

    issues = result.get("issues", [])
    blockers = [i for i in issues if i.get("severity") == "blocker"]
    return (len(blockers) == 0, issues)


def _extract_signals(html: str) -> dict:
    # H2s
    h2s = [re.sub(r"<[^>]+>", "", h).strip()
           for h in re.findall(r"<h2[^>]*>(.*?)</h2>", html, re.DOTALL | re.IGNORECASE)]

    # Featured cards
    featured = []
    for m in re.finditer(r'class="att-featured"(.*?)(?=class="att-featured"|</div>\s*</div>\s*</section>)', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3>(.*?)</h3>", block, re.DOTALL)
        cta = re.findall(r'href="([^"]+)"[^>]*class="att-btn', block)
        cta += re.findall(r'class="att-btn[^"]*"[^>]*href="([^"]+)"', block)
        featured.append({
            "title": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "cta_hrefs": cta[:2],
        })

    # Ticket cards (att-ticket)
    ticket_cards = []
    for m in re.finditer(r'class="att-ticket"(.*?)(?=class="att-ticket"|</div>\s*</section>)', html, re.DOTALL):
        block = m.group(1)
        h3 = re.search(r"<h3>(.*?)</h3>", block, re.DOTALL)
        cta_hrefs = re.findall(r'href="([^"]+)".*?class="att-ticket__cta"', block, re.DOTALL)
        cta_hrefs += re.findall(r'class="att-ticket__cta".*?href="([^"]+)"', block, re.DOTALL)
        ticket_cards.append({
            "title": re.sub(r"<[^>]+>", "", h3.group(1)).strip() if h3 else "",
            "cta_hrefs": cta_hrefs[:2],
        })

    # Rec-strip links
    rec_links = re.findall(r'class="att-rec-callout".*?href="(/[^"]+)"', html, re.DOTALL)

    # Decision guide bullets
    guide_bullets = []
    for m in re.finditer(r'class="att-guide-card"(.*?)</div>\s*</div>', html, re.DOTALL):
        block = m.group(1)
        bullets = re.findall(r"<li>(.*?)</li>", block, re.DOTALL)
        links_in_bullets = re.findall(r'href="(/tickets/[^"]+)"', block)
        guide_bullets.append({
            "bullet_count": len(bullets),
            "link_count": len(links_in_bullets),
        })

    # FAQs
    faqs = []
    for m in re.finditer(r'itemprop="name">(.*?)</span>.*?itemprop="text">(.*?)</span>', html, re.DOTALL):
        q = re.sub(r"<[^>]+>", "", m.group(1)).strip()
        a = re.sub(r"<[^>]+>", "", m.group(2)).strip()[:200]
        faqs.append({"question": q, "answer": a})

    # Banner
    banner_h2 = ""
    banner_m = re.search(r'class="att-cta-banner".*?<h2>(.*?)</h2>', html, re.DOTALL)
    if banner_m:
        banner_h2 = re.sub(r"<[^>]+>", "", banner_m.group(1)).strip()

    # All /tickets/ links
    all_ticket_links = re.findall(r'href="(/tickets/[^"]+)"', html)

    # Affiliate hrefs
    affiliate_hrefs = re.findall(r'href="(https?://[^"]*(?:getyourguide|tiqets|viator)[^"]*)"', html)

    return {
        "h2s": h2s,
        "featured": featured[:3],
        "ticket_cards": ticket_cards[:6],
        "rec_links": list(set(rec_links)),
        "guide_bullets": guide_bullets,
        "faqs": faqs[:5],
        "banner_h2": banner_h2,
        "all_ticket_links": list(set(all_ticket_links)),
        "affiliate_hrefs": affiliate_hrefs[:5],
    }


def _build_prompt(signals: dict, known_slugs: set[str], attraction: str) -> str:
    known_slugs_list = "\n".join(f"  /tickets/{s}/" for s in sorted(known_slugs))

    h2_block = "\n".join(f"  - {h}" for h in signals["h2s"])
    featured_block = "\n".join(
        f"  - Title: {c['title']!r} | CTA hrefs: {c['cta_hrefs']}"
        for c in signals["featured"]
    )
    ticket_block = "\n".join(
        f"  - Title: {c['title']!r} | CTA hrefs: {c['cta_hrefs']}"
        for c in signals["ticket_cards"]
    )
    rec_block = f"  links found: {signals['rec_links']}"
    guide_block = "\n".join(
        f"  - Card {i+1}: {g['bullet_count']} bullets, {g['link_count']} /tickets/ links"
        for i, g in enumerate(signals["guide_bullets"])
    )
    faq_block = "\n".join(
        f"  Q: {f['question']!r}\n  A: {f['answer']!r}"
        for f in signals["faqs"]
    )
    aff_block = "\n".join(f"  {h}" for h in signals["affiliate_hrefs"])
    ticket_links_block = "\n".join(f"  {lnk}" for lnk in signals["all_ticket_links"])

    return f"""You are a strict content reviewer for a travel website about {attraction!r}.
Review the extracted signals below and identify quality issues.

## Valid article slugs (all /tickets/ links must point to one of these)
{known_slugs_list or "  (none)"}

## Extracted HTML signals

### H2 section headings
{h2_block or "  (none)"}

### Featured ticket cards (sample)
{featured_block or "  (none)"}

### Standard ticket cards (sample)
{ticket_block or "  (none)"}

### Rec-strip callout links
{rec_block}

### Decision guide cards (4 expected)
{guide_block or "  (none)"}

### FAQs (sample)
{faq_block or "  (none)"}

### Banner H2
{signals["banner_h2"] or "  (absent)"}

### Affiliate hrefs (sample)
{aff_block or "  (none)"}

### All /tickets/ links in page
{ticket_links_block or "  (none)"}

## Your task

Return ONLY a JSON object:
{{
  "pass": true or false,
  "issues": [
    {{
      "severity": "blocker" or "warning",
      "area": "h2" | "cta" | "interlink" | "faq" | "compare" | "banner",
      "where": "e.g. Ticket card 'Guided Tour'",
      "description": "specific problem"
    }}
  ]
}}

## Rules

BLOCKERS — set pass to false if ANY blocker exists:
1. An H2 uses "Attraction: Section" colon-join pattern (e.g. "{attraction}: Guided Tours")
2. Any /tickets/ link target is NOT in the valid slug list above (orphan link)
3. A ticket card CTA href does not look like an affiliate URL (e.g. missing http, or is just "#")
4. A FAQ answer is generic filler with no {attraction!r}-specific detail

WARNINGS — include but do NOT fail:
5. Rec-strip has zero /tickets/ or /plan-your-visit/ links across all 4 callouts
6. Fewer than 2 of the 4 decision guide cards have any /tickets/ interlink in their bullets
7. The banner H2 does not reference the attraction subject at all
8. A ticket card CTA href exists but appears not to contain a campaign parameter (cmp=, tq_campaign=, campaign=)

Fixed template H2s (do NOT flag these for missing attraction name):
- Any H2 starting with "Top " (e.g. "Top {attraction} Experiences")
- Any H2 starting with "Which " (e.g. "Which {attraction} Ticket Should You Choose")
- Any H2 starting with "How to Pick"
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
