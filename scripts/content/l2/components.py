#!/usr/bin/env python3
"""
Layer 3 — Component Builders

One function per HTML component. Each takes typed input and returns an HTML
string. No Claude calls, no I/O, no network. Pure string assembly.

build_affiliate_url() is the ONLY place affiliate URLs are constructed or
corrected. It only replaces the campaign ID — all other params (partner_id,
mcid, medium, etc.) are kept from the source URL exactly as-is.

Campaign ID rules (enforced here and verified in validator.py):
  position="top"  → campaign ID must be  {prefix}-{slug}-top
  position="body" → campaign ID must be  {prefix}-{slug}
"""

import html
import json
import re


ARROW_SVG = (
    '<svg class="att-top-tickets__arrow" viewBox="0 0 12 12" fill="none" '
    'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" '
    'stroke-linejoin="round"><path d="M2.5 6h7M6.5 3L9.5 6L6.5 9"/></svg>'
)

# Campaign ID param name per provider
_CAMPAIGN_PARAM = {
    "gyg": "cmp",
    "tiqets": "tq_campaign",
    "viator": "campaign",
}

# Partner IDs — source of truth
PARTNER_IDS = {
    "gyg": "9BAL9K3",
    "tiqets": "thebettervacation",
    "viator": "P00038490",
}


# ─── Affiliate URL ────────────────────────────────────────────────────────────

def build_affiliate_url(url: str, provider: str, campaign_prefix: str,
                        article_slug: str, position: str) -> str:
    """
    Return the affiliate URL with the correct campaign ID for this article.

    position: "top"  → campaign ID = {campaign_prefix}-{article_slug}-top
              "body" → campaign ID = {campaign_prefix}-{article_slug}

    All existing params (partner_id, mcid, medium, etc.) are preserved.
    Only the campaign ID param is replaced/added.
    """
    cmp_param = _CAMPAIGN_PARAM.get(provider, "cmp")
    suffix = "-top" if position == "top" else ""
    campaign_id = f"{campaign_prefix}-{article_slug}{suffix}"

    # Parse existing query string
    if "?" in url:
        base, _, qs = url.partition("?")
        pairs = []
        replaced = False
        for part in qs.split("&"):
            if "=" in part:
                k, _, v = part.partition("=")
                if k == cmp_param:
                    pairs.append(f"{cmp_param}={campaign_id}")
                    replaced = True
                else:
                    pairs.append(part)
            else:
                pairs.append(part)
        if not replaced:
            pairs.append(f"{cmp_param}={campaign_id}")
        return base + "?" + "&".join(pairs)
    else:
        return f"{url}?{cmp_param}={campaign_id}"


def detect_provider(url: str) -> str:
    url_lower = url.lower()
    if "tiqets.com" in url_lower:
        return "tiqets"
    if "viator.com" in url_lower:
        return "viator"
    return "gyg"


# ─── Component builders ───────────────────────────────────────────────────────

def build_aeo_block(answer_html: str) -> str:
    """AEO answer block. Caller must pass pre-rendered HTML (bold/links already converted)."""
    return (
        '<div class="att-aeo-block">'
        f'<p class="att-aeo-block__a">{answer_html}</p>'
        "</div>"
    )


def build_top_tickets(selected_tickets: list, campaign_prefix: str,
                      article_slug: str, label: str = "Top Tickets") -> str:
    """
    Top-tickets text-link bar. Each ticket gets a → arrow and campaign ID
    ending with -top. Label comes from the MD section heading.
    """
    items = []
    for t in selected_tickets:
        url = build_affiliate_url(
            t["url"], t["provider"], campaign_prefix, article_slug, position="top"
        )
        title = html.escape(t["title"])
        items.append(
            f'<li><a href="{url}" rel="nofollow sponsored" target="_blank">'
            f"{title}{ARROW_SVG}</a></li>"
        )
    list_html = "\n".join(items)
    label_escaped = html.escape(label)
    return (
        '<div class="att-top-tickets">'
        f'<span class="att-top-tickets__label">{label_escaped}</span>'
        f'<ul class="att-top-tickets__list">{list_html}</ul>'
        "</div>"
    )


def build_cta_button(ticket: dict, campaign_prefix: str, article_slug: str,
                     button_text: str = "") -> str:
    """
    Primary CTA buy button. Campaign ID has no -top suffix.
    button_text defaults to the ticket title.
    """
    url = build_affiliate_url(
        ticket["url"], ticket["provider"], campaign_prefix, article_slug, position="body"
    )
    text = html.escape(button_text or ticket["title"])
    return (
        f'<a href="{url}" class="att-buy-now-btn" '
        f'rel="nofollow sponsored" target="_blank">{text}</a>'
    )


def build_insider_tip(text: str) -> str:
    escaped = html.escape(text)
    return (
        '<div class="att-tip-box">'
        '<p class="att-tip-box__label">Insider Tip</p>'
        f"<p>{escaped}</p>"
        "</div>"
    )


def build_faq_item(question: str, answer: str) -> str:
    """
    FAQ accordion item using native <details>/<summary>.
    Starts closed — user clicks to open. No JavaScript needed.
    """
    q = html.escape(question, quote=False)
    a = html.escape(answer, quote=False)
    return (
        '<details class="att-faq-details">'
        f'<summary class="att-faq-summary">{q}</summary>'
        f'<div class="att-faq-content"><p>{a}</p></div>'
        "</details>"
    )


def _md_to_plain(text: str) -> str:
    """Strip Markdown formatting to plain text for use in JSON-LD schema fields."""
    # [link text](url) → link text
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    # **bold** or __bold__ → bold
    text = re.sub(r"\*\*(.+?)\*\*|__(.+?)__", lambda m: m.group(1) or m.group(2), text)
    # *italic* or _italic_ → italic
    text = re.sub(r"\*([^*\n]+?)\*|(?<!\w)_([^_\n]+?)_(?!\w)", lambda m: m.group(1) or m.group(2), text)
    return text.strip()


def build_faq_jsonld(faq_items: list) -> str:
    """FAQPage JSON-LD schema. Derived from the same faq_items as the HTML."""
    entities = []
    for item in faq_items:
        entities.append({
            "@type": "Question",
            "name": _md_to_plain(item["question"]),
            "acceptedAnswer": {
                "@type": "Answer",
                "text": _md_to_plain(item["answer"]),
            },
        })
    schema = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": entities,
    }
    return (
        '<script type="application/ld+json">\n'
        + json.dumps(schema, ensure_ascii=False, indent=2)
        + "\n</script>"
    )


def build_related_links(related_links: list, url_registry: dict) -> str:
    """
    Related articles section. URLs are resolved against the registry when
    they are relative slugs; absolute URLs are used as-is.
    """
    from .link_resolver import resolve

    items = []
    for link in related_links:
        url = resolve(link["url"], url_registry) or link["url"]
        text = html.escape(link["text"])
        items.append(f'<li><a href="{url}">{text}</a></li>')

    list_html = "\n".join(items)
    return (
        '<div class="att-related">'
        '<p class="att-related__title">Related Articles</p>'
        f'<ul class="att-related__list">{list_html}</ul>'
        "</div>"
    )


def build_body_section(heading: str, prose_html: str,
                       aeo_text: str | None = None) -> str:
    """
    One H2 body section. Heading text comes from the MD verbatim.
    Optional aeo_text is placed as an AEO block directly under the H2
    (only for question-phrased headings).
    """
    h2 = html.escape(heading, quote=False)
    aeo_part = f"\n{build_aeo_block(aeo_text)}" if aeo_text else ""
    return f"<h2>{h2}</h2>{aeo_part}\n{prose_html}"


def build_markdown_table(md_table: str) -> str:
    """
    Convert a Markdown pipe table to a .att-price-table HTML table.
    Returns empty string if input doesn't look like a table.
    """
    lines = [l for l in md_table.strip().splitlines() if l.strip()]
    if len(lines) < 2:
        return ""
    header_cells = [c.strip() for c in lines[0].strip("|").split("|")]
    # Skip separator row (---|--- pattern)
    body_lines = [l for l in lines[1:] if not re.match(r"^[\s|:-]+$", l)]

    ths = "".join(f"<th>{html.escape(c)}</th>" for c in header_cells)
    rows = []
    for line in body_lines:
        cells = [c.strip() for c in line.strip("|").split("|")]
        tds = "".join(f"<td>{html.escape(c)}</td>" for c in cells)
        rows.append(f"<tr>{tds}</tr>")

    tbody = "\n".join(rows)
    return (
        '<div class="att-table-wrapper">'
        '<table class="att-price-table">'
        f"<thead><tr>{ths}</tr></thead>"
        f"<tbody>{tbody}</tbody>"
        "</table></div>"
    )
