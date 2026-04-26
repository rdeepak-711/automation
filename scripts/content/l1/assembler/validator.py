#!/usr/bin/env python3
"""
validator.py — Mechanical validation for L1 plan-your-visit pages.

Checks structure, counts, fixed button texts, and size.
Returns (ok, reasons, info) — same contract as scripts/l2/validator.py.
"""

import re


def validate(
    html_out: str,
    articles: list[dict],
    site_slug: str,
    config: dict,
    banner_url: str,
) -> tuple[bool, list[str], dict]:
    reasons = []
    info = {"card_count": 0, "faq_count": 0}

    # 1. Card count
    card_count = len(re.findall(r'class="att-article-card"', html_out))
    info["card_count"] = card_count
    if card_count != len(articles):
        reasons.append(f"Card count mismatch: {card_count} in HTML vs {len(articles)} articles")

    # 2. Every card has "Read guide" link
    read_links = len(re.findall(r"Read guide", html_out))
    if read_links < len(articles):
        reasons.append(f"'Read guide' link count {read_links} < article count {len(articles)}")

    # 3. All card links are relative
    card_hrefs = re.findall(r'class="att-article-card__link"[^>]*href="([^"]+)"', html_out)
    card_hrefs += re.findall(r'href="([^"]+)"[^>]*class="att-article-card__link"', html_out)
    for href in card_hrefs:
        if not href.startswith("/"):
            reasons.append(f"Card link not relative: {href}")

    # 4. Campaign ID in banner (only when banner is an affiliate URL, not relative)
    campaign_id = f"{site_slug}-plan-your-visit"
    if not banner_url.startswith("/") and campaign_id not in html_out:
        reasons.append(f"Campaign ID '{campaign_id}' not found in HTML")

    # 5. FAQPage JSON-LD question count matches visible FAQ item count
    details_count = len(re.findall(r'class="att-faq-item"', html_out))
    info["faq_count"] = details_count
    if details_count > 0:
        jsonld_names = len(re.findall(r'"name":', html_out))
        if jsonld_names and jsonld_names != details_count:
            reasons.append(
                f"FAQ JSON-LD names ({jsonld_names}) != FAQ items ({details_count})"
            )

    # 6. Fixed button texts
    for text, msg in [
        ("Essential Guides", "Hero button 'Essential Guides →' missing"),
        ("Read FAQs", "Hero button 'Read FAQs' missing"),
        ("View All Tickets", "CTA banner 'View All Tickets & Tours' missing"),
        ("View All FAQs", "FAQ section 'View All FAQs →' missing"),
        ("Read guide", "Article card 'Read guide →' missing"),
    ]:
        if text not in html_out:
            reasons.append(msg)

    # 7. No colon H2 pattern — e.g. "Amsterdam Canal Cruise: When to Go"
    colon_h2s = re.findall(r"<h2>[^<]+:[^<]+</h2>", html_out)
    for h2 in colon_h2s:
        # Allow <h2>Tickets &amp; Tours</h2> — only flag "Attraction: Section" pattern
        text = re.sub(r"<[^>]+>", "", h2)
        if re.match(r"^[A-Z][^:]{5,}:\s+\S", text):
            reasons.append(f"Colon-join H2 still present: '{text}'")

    # 8. Size > 20 KB
    if len(html_out.encode("utf-8")) < 20_000:
        reasons.append(f"Output too small ({len(html_out)} bytes) — possible truncation")

    return (len(reasons) == 0, reasons, info)


def validate_wts(
    html_out: str,
    articles: list[dict],
    site_slug: str,
    config: dict,
    banner_url: str,
    featured_count: int = 2,
) -> tuple[bool, list[str], dict]:
    """Mechanical validation for L1 what-to-see pages."""
    reasons = []
    info = {"card_count": 0, "faq_count": 0, "featured_count": 0, "guide_card_count": 0}

    # 1. Featured card count
    feat_count = len(re.findall(r'class="att-featured"', html_out))
    info["featured_count"] = feat_count
    if feat_count != featured_count:
        reasons.append(f"Featured card count: {feat_count} in HTML vs {featured_count} expected")

    # 2. Article card count == len(articles) - featured_count
    card_count = len(re.findall(r'class="att-article-card"', html_out))
    info["card_count"] = card_count
    expected_cards = len(articles) - featured_count
    if card_count != expected_cards:
        reasons.append(f"Article card count: {card_count} in HTML vs {expected_cards} expected (articles - featured)")

    # 3. Guide card count >= 2
    guide_count = len(re.findall(r'class="att-guide-card"', html_out))
    info["guide_card_count"] = guide_count
    if guide_count < 2:
        reasons.append(f"Guide card count too low: {guide_count} (expected >= 2)")

    # 4. Every article card has "Read guide" link
    read_links = len(re.findall(r"Read guide", html_out))
    if read_links < expected_cards:
        reasons.append(f"'Read guide' count {read_links} < expected article cards {expected_cards}")

    # 5. All article card links are relative
    card_hrefs = re.findall(r'class="att-article-card__link"[^>]*href="([^"]+)"', html_out)
    card_hrefs += re.findall(r'href="([^"]+)"[^>]*class="att-article-card__link"', html_out)
    for href in card_hrefs:
        if not href.startswith("/"):
            reasons.append(f"Card link not relative: {href}")

    # 6. Featured card hrefs don't overlap with article grid hrefs
    feat_hrefs = set(re.findall(r'class="att-featured__link"[^>]*href="([^"]+)"', html_out))
    feat_hrefs |= set(re.findall(r'href="([^"]+)"[^>]*class="att-featured__link"', html_out))
    art_hrefs = set(card_hrefs)
    overlap = feat_hrefs & art_hrefs
    if overlap:
        reasons.append(f"Featured article(s) also appear in article grid: {overlap}")

    # 7. Campaign ID in banner (when not relative)
    campaign_id = f"{site_slug}-what-to-see"
    if not banner_url.startswith("/") and campaign_id not in html_out:
        reasons.append(f"Campaign ID '{campaign_id}' not found in HTML")

    # 8. FAQ count and JSON-LD match
    faq_count = len(re.findall(r'class="att-faq-item"', html_out))
    info["faq_count"] = faq_count
    if faq_count > 0:
        jsonld_names = len(re.findall(r'"name":', html_out))
        if jsonld_names and jsonld_names != faq_count:
            reasons.append(f"FAQ JSON-LD names ({jsonld_names}) != FAQ items ({faq_count})")

    # 9. Required strings
    for text, msg in [
        ("Top Highlights", "Section 'Top Highlights' missing"),
        ("How to Choose", "Section 'How to Choose' missing"),
        ("Continue Exploring", "Section 'Continue Exploring' missing"),
        ("Frequently Asked Questions", "FAQ section heading missing"),
        ("View All FAQs", "FAQ section 'View All FAQs' missing"),
        ("Read guide", "Article card 'Read guide →' missing"),
        ("Explore", "Featured card 'Explore →' CTA missing"),
    ]:
        if text not in html_out:
            reasons.append(msg)

    # 10. No colon H2 pattern
    colon_h2s = re.findall(r"<h2>[^<]+:[^<]+</h2>", html_out)
    for h2 in colon_h2s:
        text = re.sub(r"<[^>]+>", "", h2)
        if re.match(r"^[A-Z][^:]{5,}:\s+\S", text):
            reasons.append(f"Colon-join H2 still present: '{text}'")

    # 11. Size > 20 KB
    if len(html_out.encode("utf-8")) < 20_000:
        reasons.append(f"Output too small ({len(html_out)} bytes) — possible truncation")

    return (len(reasons) == 0, reasons, info)
