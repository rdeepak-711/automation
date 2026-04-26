#!/usr/bin/env python3
"""
Layer 6 — Assembler

Assembles the final HTML string from all components. The output structure
mirrors the template exactly. All MD sections are converted and included in
the output in their original order — no sections are skipped.

CTA button and insider tip box are optional:
  - CTA only if selected_tickets is non-empty
  - Tip box only if parsed_md contains a section explicitly marked as a tip
    (heading contains "tip", "insider", or "practical tip")
"""

import html as _html
import re

from .components import (
    build_aeo_block,
    build_body_section,
    build_cta_button,
    build_faq_item,
    build_faq_jsonld,
    build_insider_tip,
    build_related_links,
    build_top_tickets,
    build_affiliate_url,
    detect_provider,
    PARTNER_IDS,
)
from .prose_converter import convert_section, _inline
from .template_parser import parse as parse_template

def _extract_pid(url: str) -> str:
    """Return a stable product-ID key for deduplication."""
    m = re.search(r"-t(\d+)", url)
    if m: return f"gyg:{m.group(1)}"
    m = re.search(r"-p(\d+)", url, re.IGNORECASE)
    if m: return f"tiq:{m.group(1)}"
    m = re.search(r"/tours/[^/]+/([^/?]+)", url)
    if m: return f"via:{m.group(1)}"
    return url  # fallback: full URL as key


_TIP_HEADING_RE = re.compile(
    r"^(insider\s+tip|practical\s+tip|tip|insider)s?\s*$", re.IGNORECASE
)


def assemble(
    parsed_md: dict,
    selected_tickets: list,
    registry: dict,
    template_path: str,
    campaign_prefix: str,
    article_slug: str,
) -> str:
    """
    Build the complete article HTML string.

    All sections from parsed_md["sections"] are converted and included in
    the output in their original order.

    Parameters
    ----------
    parsed_md        : output of md_parser.parse()
    selected_tickets : output of top_tickets.select() — may be empty
    registry         : loaded url-registry.json dict
    template_path    : path to the template (CSS extraction only)
    campaign_prefix  : e.g. "hagia"
    article_slug     : e.g. "hagia-sophia-tickets" (from XLSX / registry)
    """
    tpl = parse_template(template_path)
    css = tpl["css"]

    # ── Header ───────────────────────────────────────────────────────────────
    h1 = _html.escape(parsed_md.get("title", ""))
    featured_image = (
        '<img class="att-article-header__image" '
        'src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" '
        'alt="" loading="eager"/>'
    )

    # ── Intro AEO ────────────────────────────────────────────────────────────
    intro_aeo = ""
    if parsed_md.get("quick_answer"):
        aeo_html = _inline(parsed_md["quick_answer"], campaign_prefix, article_slug)
        intro_aeo = build_aeo_block(aeo_html)

    # ── Intro paragraphs ─────────────────────────────────────────────────────
    intro_html_parts = []
    for para in parsed_md.get("intro_paras", []):
        text = _inline(para, campaign_prefix, article_slug)
        if text:
            intro_html_parts.append(f"<p>{text}</p>")
    intro_html = "\n".join(intro_html_parts)

    # ── Top tickets — use MD link text + URLs verbatim; only fix campaign ID ──
    top_tickets_html = ""
    md_top_links = parsed_md.get("top_ticket_links", [])
    if md_top_links:
        # Build tickets list in components.py format using MD text+URL
        # Deduplicate by PID — keep first occurrence of each affiliate product ID
        seen_pids = set()
        md_tickets = []
        for link in md_top_links:
            provider = detect_provider(link["url"])
            pid = _extract_pid(link["url"])
            if pid in seen_pids:
                continue
            seen_pids.add(pid)
            md_tickets.append({
                "title": link["text"],
                "url": link["url"],
                "provider": provider,
            })
        top_tickets_html = build_top_tickets(md_tickets, campaign_prefix, article_slug,
                                              label=parsed_md.get("top_ticket_heading", "Top Tickets"))
    elif selected_tickets:
        top_tickets_html = build_top_tickets(selected_tickets, campaign_prefix, article_slug)

    # ── Pre-render body sections (indexed so blocks loop can reference them) ───
    body_section_htmls = []
    tip_box_html = ""
    for sec in parsed_md.get("sections", []):
        prose_html = convert_section(sec["content_md"], campaign_prefix, article_slug)
        aeo_hint = sec.get("aeo_hint")
        aeo_hint_html = _inline(aeo_hint, campaign_prefix, article_slug) if aeo_hint else None
        section_html = build_body_section(
            heading=sec["heading"],
            prose_html=prose_html,
            aeo_text=aeo_hint_html,
        )
        if _TIP_HEADING_RE.search(sec["heading"]) and prose_html:
            first_p = re.search(r"<p>(.*?)</p>", prose_html, re.DOTALL)
            if first_p:
                tip_text = re.sub(r"<[^>]+>", "", first_p.group(1)).strip()
                if tip_text:
                    tip_box_html = build_insider_tip(tip_text)
        body_section_htmls.append(section_html)

    # ── FAQ ──────────────────────────────────────────────────────────────────
    faq_items = parsed_md.get("faq_items", [])
    faq_items_html = "\n".join(
        build_faq_item(i["question"], i["answer"]) for i in faq_items
    )
    faq_section_html = ""
    if faq_items:
        faq_section_html = (
            '<div class="att-faq">\n'
            '<h2 class="att-faq__title">Frequently Asked Questions</h2>\n'
            f"{faq_items_html}\n"
            "</div>"
        )

    faq_jsonld = build_faq_jsonld(faq_items) if faq_items else ""

    # ── Related ──────────────────────────────────────────────────────────────
    related_html = build_related_links(parsed_md.get("related_links", []), registry)

    # ── Final assembly — follow MD block order ────────────────────────────────
    seo_title = parsed_md.get("title", "")
    seo_desc = parsed_md.get("description", "")
    seo_url = parsed_md.get("url", "")
    parts = [
        f"<!-- SEO\ntitle: {seo_title}\ndescription: {seo_desc}\ncanonical: {seo_url}\n-->",
        f"<style>{css}</style>",
        "",
        '<div class="att-article-page">',
        '  <section class="att-article-header">',
        '    <div class="att-container">',
        f"      <h1>{h1}</h1>",
        f"      {featured_image}",
        "    </div>",
        "  </section>",
        "",
        '  <div class="att-container">',
        '    <div class="att-article-body">',
    ]

    rendered = []
    for block in parsed_md.get("blocks", _default_blocks(parsed_md)):
        t = block["type"]
        if t == "aeo_answer" and intro_aeo:
            rendered.append(intro_aeo)
        elif t == "intro_paras" and intro_html:
            rendered.append(intro_html)
        elif t == "top_tickets" and top_tickets_html:
            rendered.append(top_tickets_html)
        elif t == "body_section":
            rendered.append(body_section_htmls[block["index"]])
        elif t == "faq" and faq_section_html:
            rendered.append(faq_section_html)
        elif t == "related" and related_html:
            rendered.append(related_html)

    if tip_box_html:
        rendered.append(tip_box_html)

    parts.append("      " + "\n\n      ".join(rendered))

    parts += [
        "    </div>",
        "  </div>",
        "</div>",
    ]

    if faq_jsonld:
        parts.append(f"\n{faq_jsonld}")

    return "\n".join(parts)


def _default_blocks(parsed_md: dict) -> list:
    """Fallback block order when `blocks` key is absent (e.g. old parsed dicts)."""
    blocks = []
    if parsed_md.get("quick_answer"):
        blocks.append({"type": "aeo_answer"})
    if parsed_md.get("intro_paras"):
        blocks.append({"type": "intro_paras"})
    if parsed_md.get("top_ticket_links"):
        blocks.append({"type": "top_tickets"})
    for i in range(len(parsed_md.get("sections", []))):
        blocks.append({"type": "body_section", "index": i})
    if parsed_md.get("faq_items"):
        blocks.append({"type": "faq"})
    if parsed_md.get("related_links"):
        blocks.append({"type": "related"})
    return blocks
