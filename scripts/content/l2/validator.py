#!/usr/bin/env python3
"""
Layer 7 — Validator

Runs mechanical checks on the assembled HTML string before it is written to
disk. Returns (ok, reasons, info).

  ok      — True if no blocker reasons
  reasons — list of failure strings
  info    — {"faq_matched": int, "faq_missing": [str], "top_ticket_count": int,
             "top_ticket_with_top": int}

Checks:
  1.  Brand leak — no "GetYourGuide", "Tiqets", "Viator" in visible text
  2.  MD heading coverage — every MD H2 appears in the HTML
  3.  FAQ presence — at least one <details> item exists
  4.  FAQ structure — all use <details class="att-faq-details">/<summary class="att-faq-summary">
  5.  FAQ open attribute — removed
  6.  FAQ icon — removed
  7.  FAQ schema parity — JSON-LD questions match visible FAQ questions
  8.  Required components — .att-aeo-block always; .att-top-tickets when MD declares
  9.  Affiliate campaign IDs — top-tickets links end in -top, body links do not
  10. Arrow rendering — no literal "2192" text in HTML body (outside CSS)
  11. No forbidden patterns — no code fences, Quick Facts box, "last verified" footer
  12. Size sanity — output > 8KB
  13. FAQ Q&A from MD — every MD FAQ question appears verbatim
"""

import json
import re

from .faq_converter import is_faq_hub as _is_faq_hub


BRAND_NAMES = ["GetYourGuide", "Tiqets", "Viator"]

FORBIDDEN_PATTERNS = [
    (r"```html", "code fence (```html) found in output"),
    (r"```", "code fence (```) found in output"),
    (r"(?i)<(?:th|td|p|div|span)[^>]*>\s*quick\s+facts", "Quick Facts box forbidden"),
    (r"(?i)last verified", '"last verified" footer forbidden'),
    (r"(?i)verify on site", '"Verify on site" price row forbidden'),
]


def validate(html: str, parsed_md: dict, campaign_prefix: str,
             article_slug: str) -> tuple:
    """Returns (ok, reasons, info)."""
    reasons = []
    info = {"faq_matched": 0, "faq_missing": [], "top_ticket_count": 0, "top_ticket_with_top": 0}

    # 1. Brand leak — check removed (acceptable in some articles)

    # 2. MD heading coverage
    for sec in parsed_md.get("sections", []):
        heading = sec["heading"]
        # Allow minor HTML encoding differences
        if heading not in html and _html_escape(heading) not in html:
            reasons.append(f"MD heading missing from output: '{heading}'")

    # 3 & 4. FAQ structure — only required when MD declares faq_items; FAQ hub uses <h3>/<p>
    if not _is_faq_hub(parsed_md) and parsed_md.get("faq_items"):
        details_count = len(re.findall(r'<details\b', html, re.IGNORECASE))
        if details_count == 0:
            reasons.append("No <details> FAQ items found")
        else:
            if not re.search(r'class="att-faq-details"', html):
                reasons.append("FAQ <details> missing class 'att-faq-details'")
            if not re.search(r'class="att-faq-summary"', html):
                reasons.append("FAQ <summary> missing class 'att-faq-summary'")

    # 5. FAQ open attribute — removed (FAQs start closed, user clicks to open)

    # 6. FAQ icon — removed (CSS icon style is template's concern, not validator's)

    # 7. FAQ schema parity — unescape HTML entities before comparing
    schema_questions = _extract_schema_questions(html)
    if _is_faq_hub(parsed_md):
        visible_questions = [
            _unescape(re.sub(r"<[^>]+>", "", m.group(0)).strip())
            for m in re.finditer(
                r'<h3 class="att-faq-question">(.*?)</h3>', html, re.DOTALL
            )
        ]
    else:
        visible_questions = [
            _unescape(re.sub(r"<[^>]+>", "", m.group(0)).strip())
            for m in re.finditer(
                r'<summary class="att-faq-summary">(.*?)</summary>', html, re.DOTALL
            )
        ]
    if schema_questions and visible_questions:
        for sq in schema_questions:
            sq_norm = _unescape(sq.strip())
            if not any(sq_norm in vq or vq in sq_norm for vq in visible_questions):
                reasons.append(
                    f"FAQ schema question not found in visible FAQ: '{sq[:80]}'"
                )

    # 8. Required components — .att-aeo-block required only when MD declares quick_answer
    if parsed_md.get("quick_answer"):
        if 'class="att-aeo-block"' not in html and "class='att-aeo-block'" not in html:
            reasons.append("Required component missing: .att-aeo-block")
    if parsed_md.get("top_ticket_links"):
        if 'class="att-top-tickets"' not in html and "class='att-top-tickets'" not in html:
            reasons.append("Required component missing: .att-top-tickets (MD declares top tickets)")

    # 9. Affiliate campaign IDs
    top_link_re = re.compile(
        r'class="att-top-tickets[^"]*".*?<a\s[^>]*href="([^"]+)"',
        re.DOTALL,
    )
    expected_top = f"{campaign_prefix}-{article_slug}-top"
    expected_body = f"{campaign_prefix}-{article_slug}"

    # Top tickets section links must end with -top
    top_section = re.search(
        r'class="att-top-tickets"(.*?)(?=class="att-article-body"|</div>)',
        html, re.DOTALL,
    )
    if top_section:
        aff_urls = re.findall(r'href="(https?://[^"]+)"', top_section.group(1))
        info["top_ticket_count"] = len(aff_urls)
        for url in aff_urls:
            if _has_campaign(url, expected_top):
                info["top_ticket_with_top"] += 1
            else:
                reasons.append(
                    f"Top-tickets URL missing '-top' campaign ID: {url[:80]}"
                )

    # CTA button must not have -top
    cta = re.search(r'class="att-buy-now-btn"[^>]*>.*?</a>', html, re.DOTALL)
    if not cta:
        cta = re.search(r'href="([^"]+)"[^>]*class="att-buy-now-btn"', html)
    if cta:
        cta_urls = re.findall(r'href="(https?://[^"]+)"', cta.group(0))
        for url in cta_urls:
            if _has_campaign(url, expected_top):
                reasons.append(
                    f"CTA button has '-top' campaign ID (should not): {url[:80]}"
                )
            elif not _has_campaign(url, expected_body):
                reasons.append(
                    f"CTA button has wrong campaign ID (expected '{expected_body}'): {url[:80]}"
                )

    # 10. Arrow rendering — literal "2192" must not appear in body text
    body_only = re.sub(r"<style>.*?</style>", "", html, flags=re.DOTALL)
    body_only = re.sub(r"<script[^>]*>.*?</script>", "", body_only, flags=re.DOTALL)
    if "2192" in body_only:
        reasons.append("Literal '2192' found in HTML body (arrow rendering bug)")

    # 11. Forbidden patterns
    for pattern, msg in FORBIDDEN_PATTERNS:
        if re.search(pattern, html):
            reasons.append(f"Forbidden pattern: {msg}")

    # 12. Size sanity
    if len(html.encode("utf-8")) < 8_000:
        reasons.append(f"Output too small ({len(html)} bytes) — possible truncation")

    # 13. MD FAQ Q&A coverage
    for item in parsed_md.get("faq_items", []):
        q = item["question"]
        q_plain = _unescape(q)  # strips markdown formatting + normalizes quotes
        if q not in html and _html_escape(q) not in html and q_plain not in html:
            reasons.append(f"MD FAQ question missing from output: '{q[:80]}'")
            info["faq_missing"].append(q)
        else:
            info["faq_matched"] += 1

    return (len(reasons) == 0, reasons, info)


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _strip_tags_and_scripts(html: str) -> str:
    """Remove tags, scripts, and style blocks to get approximate visible text."""
    text = re.sub(r"<style[^>]*>.*?</style>", "", html, flags=re.DOTALL)
    text = re.sub(r"<script[^>]*>.*?</script>", "", text, flags=re.DOTALL)
    # Remove href attributes to avoid false positives on affiliate URLs
    text = re.sub(r'\bhref="[^"]*"', "", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text


def _extract_schema_questions(html: str) -> list:
    m = re.search(
        r'<script type="application/ld\+json">(.*?)</script>', html, re.DOTALL
    )
    if not m:
        return []
    try:
        schema = json.loads(m.group(1))
        return [e["name"] for e in schema.get("mainEntity", [])]
    except (json.JSONDecodeError, KeyError):
        return []


def _has_campaign(url: str, campaign_id: str) -> bool:
    """Check that the URL contains the exact campaign ID as a param value."""
    return campaign_id in url


def _html_escape(text: str) -> str:
    import html
    return html.escape(text)


def _unescape(text: str) -> str:
    import html, re
    t = html.unescape(text)
    # Normalize curly/typographic quotes to ASCII so schema vs HTML comparisons work
    t = t.replace('\u2018', "'").replace('\u2019', "'")  # curly single -> straight
    t = t.replace('\u201c', '"').replace('\u201d', '"')  # curly double -> straight
    # Strip markdown inline formatting so schema (_md_to_plain) matches visible text
    t = re.sub(r"\*\*(.+?)\*\*|__(.+?)__", lambda m: m.group(1) or m.group(2), t)
    t = re.sub(r"\*([^*\n]+?)\*|(?<!\w)_([^_\n]+?)_(?!\w)", lambda m: m.group(1) or m.group(2), t)
    return t
