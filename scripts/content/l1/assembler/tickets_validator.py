#!/usr/bin/env python3
"""
tickets_validator.py — Mechanical validation for L1 tickets-tours pages.

Returns (ok, reasons, info) — same contract as validator.py.
"""

import re


def validate(
    html_out: str,
    bundle: dict,
    site_slug: str,
    config: dict,
    banner_url: str,
) -> tuple[bool, list[str], dict]:
    tickets = bundle.get("tickets", [])
    informational = bundle.get("informational", [])
    featured = bundle.get("featured", [])
    affiliate_tickets = bundle.get("affiliate_tickets", tickets)  # GYG products for table
    reasons = []
    info = {}

    # 1. Featured card count
    featured_count = len(re.findall(r'class="att-featured"', html_out))
    info["featured_count"] = featured_count
    if featured and featured_count != len(featured):
        reasons.append(f"Featured card count: {featured_count} in HTML vs {len(featured)} expected")

    # 2. Ticket cards — editorial articles should each have a card or featured slot
    all_editorial = featured + tickets + informational
    ticket_cta_count = html_out.count("Check Availability") + html_out.count("See Options")
    info["ticket_cta_count"] = ticket_cta_count

    # 3. Comparison table rows — should match affiliate_tickets (GYG products)
    compare_rows = len(re.findall(r'class="att-compare-row"', html_out))
    info["compare_rows"] = compare_rows
    if affiliate_tickets and compare_rows != len(affiliate_tickets):
        reasons.append(f"Compare table rows: {compare_rows} vs {len(affiliate_tickets)} affiliate tickets")

    # 4. Decision guide has exactly 4 cards
    guide_cards = len(re.findall(r'class="att-guide-card"', html_out))
    info["guide_cards"] = guide_cards
    if guide_cards != 4:
        reasons.append(f"Decision guide card count: {guide_cards} (expected 4)")

    # 5. Affiliate hrefs contain campaign stamp
    campaign_id = f"{site_slug}-tickets"
    affiliate_hrefs = re.findall(r'href="(https?://[^"]*(?:getyourguide|tiqets|viator)[^"]*)"', html_out)
    for href in affiliate_hrefs:
        if campaign_id not in href:
            reasons.append(f"Affiliate href missing campaign '{campaign_id}': {href[:80]}")
            break  # report once

    # 6. All relative internal links start with /
    card_hrefs = re.findall(r'href="(/[^"]+)"', html_out)
    for href in card_hrefs:
        if href.startswith("//"):
            reasons.append(f"Protocol-relative link: {href[:60]}")

    # 7. FAQ JSON-LD name count == rendered FAQ items
    faq_items = len(re.findall(r'class="att-faq-item"', html_out))
    info["faq_count"] = faq_items
    if faq_items > 0:
        jsonld_names = len(re.findall(r'"name":\s*"', html_out))
        if jsonld_names and jsonld_names != faq_items:
            reasons.append(f"FAQ JSON-LD names ({jsonld_names}) != FAQ items ({faq_items})")

    # 8. No colon H2 pattern ("Attraction: Section")
    colon_h2s = re.findall(r"<h2>[^<]+:[^<]+</h2>", html_out)
    for h2 in colon_h2s:
        text = re.sub(r"<[^>]+>", "", h2)
        if re.match(r"^[A-Z][^:]{5,}:\s+\S", text):
            reasons.append(f"Colon-join H2: '{text}'")

    # 9. Size > 30 KB
    if len(html_out.encode("utf-8")) < 30_000:
        reasons.append(f"Output too small ({len(html_out)} bytes) — possible truncation")

    return (len(reasons) == 0, reasons, info)
