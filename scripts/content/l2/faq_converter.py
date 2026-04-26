#!/usr/bin/env python3
"""
FAQ Hub Converter — dedicated renderer for the site's FAQ page.

Structure differs from regular L2 articles:
  - No `## Frequently Asked Questions` wrapper section
  - Body split into category H2s (e.g. `## Tickets and Prices`, `## Hours and Timing`)
  - Under each category: `**Question?**` lines followed by answer paragraph(s)

Output:
  - Standard header + intro AEO + intro paras
  - Top tickets bar (only if MD declares one)
  - For each category: `<h2>` + open Q&A items (<h3> question + rendered <p> answer)
  - One combined FAQPage JSON-LD (aggregates all Qs from all categories)
  - Related links section
"""

import html as _html
import re

from .components import (
    PARTNER_IDS,
    build_aeo_block,
    build_faq_jsonld,
    build_related_links,
    build_top_tickets,
    detect_provider,
)
from .prose_converter import _inline
from .template_parser import parse as parse_template


# Matches `**Question?**` or `### Question?` on its own line (question must end with ?)
_FAQ_Q_RE = re.compile(r"^\*\*(.+\?)\*\*\s*$")
_FAQ_H3_RE = re.compile(r"^###\s+(.+\?)\s*$")


def is_faq_hub(parsed_md: dict) -> bool:
    """True if this MD should be routed through the FAQ hub converter."""
    url = (parsed_md.get("url") or "").rstrip("/").lower()
    if url.endswith("/faqs") or url.endswith("/faq"):
        return True
    title = (parsed_md.get("title") or "").lower()
    return title.startswith("faqs") or " faqs" in title or " faq" in title


def _extract_category_faqs(content_md: str) -> list:
    """Parse a category section's content into Q&A pairs."""
    lines = content_md.splitlines()
    items = []
    current_q = None
    current_a_lines = []

    def flush():
        if current_q and current_a_lines:
            answer = " ".join(l.strip() for l in current_a_lines if l.strip())
            items.append({"question": current_q, "answer": answer})

    for line in lines:
        m = _FAQ_Q_RE.match(line.strip()) or _FAQ_H3_RE.match(line.strip())
        if m:
            flush()
            current_q = m.group(1).strip()
            current_a_lines = []
            continue
        if current_q is not None:
            current_a_lines.append(line)

    flush()
    return items


def convert(
    parsed_md: dict,
    registry: dict,
    template_path: str,
    campaign_prefix: str,
    article_slug: str,
) -> str:
    """Render the FAQ hub article to HTML."""
    tpl = parse_template(template_path)
    css = tpl["css"]

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

    # ── Top tickets (only if MD declares them) ────────────────────────────────
    top_tickets_html = ""
    md_top_links = parsed_md.get("top_ticket_links", [])
    if md_top_links:
        md_tickets = []
        for link in md_top_links:
            md_tickets.append({
                "title": link["text"],
                "url": link["url"],
                "provider": detect_provider(link["url"]),
            })
        top_tickets_html = build_top_tickets(md_tickets, campaign_prefix, article_slug,
                                              label=parsed_md.get("top_ticket_heading", "Top Tickets"))

    # ── Pre-render category sections as indexed Q&A blocks ───────────────────
    category_htmls = []
    all_faq_items = []  # aggregated for JSON-LD
    for sec in parsed_md.get("sections", []):
        heading = sec["heading"]
        qa_items = _extract_category_faqs(sec.get("content_md", ""))
        if not qa_items:
            category_htmls.append("")  # keep index alignment with blocks
            continue
        all_faq_items.extend(qa_items)
        items_html = "\n".join(
            '<div class="att-faq-qa">'
            f'<h3 class="att-faq-question">{_html.escape(item["question"])}</h3>'
            f'<div class="att-faq-answer"><p>{_inline(item["answer"], campaign_prefix, article_slug)}</p></div>'
            '</div>'
            for item in qa_items
        )
        h2 = _html.escape(heading)
        category_htmls.append(f'<h2>{h2}</h2>\n{items_html}')

    # ── FAQ JSON-LD — one script aggregating all categories ──────────────────
    faq_jsonld = build_faq_jsonld(all_faq_items) if all_faq_items else ""

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
            html_chunk = category_htmls[block["index"]]
            if html_chunk:
                rendered.append(html_chunk)
        elif t == "related" and related_html:
            rendered.append(related_html)

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
    """Fallback block order for FAQ hub when `blocks` key is absent."""
    blocks = []
    if parsed_md.get("quick_answer"):
        blocks.append({"type": "aeo_answer"})
    if parsed_md.get("intro_paras"):
        blocks.append({"type": "intro_paras"})
    if parsed_md.get("top_ticket_links"):
        blocks.append({"type": "top_tickets"})
    for i in range(len(parsed_md.get("sections", []))):
        blocks.append({"type": "body_section", "index": i})
    if parsed_md.get("related_links"):
        blocks.append({"type": "related"})
    return blocks
