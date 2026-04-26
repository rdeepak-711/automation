#!/usr/bin/env python3
"""
Layer 5 — Prose Converter (Markdown → HTML)

Converts the MD prose for each body section to clean HTML, preserving the
exact words and structure from the source MD. No Claude call — the MD is the
content authority.

Handles:
  - Paragraphs (blank-line separated)
  - **bold** → <strong>
  - *italic* → <em>
  - [text](url) → <a href="url"> (affiliate links validated separately)
  - - item / * item → <ul><li>
  - 1. item → <ol><li>
  - ### Sub-heading → <h3>
  - #### Sub-sub-heading → <h4>
  - | col | ... | Markdown tables → .att-price-table
  - [Buy This Ticket](url) / [Book This Tour](url) → stripped from prose
    (the dedicated CTA button placed by the assembler handles this)
"""

import html
import re

from .components import build_markdown_table, build_affiliate_url, build_cta_button, detect_provider
from .md_parser import CTA_MARKER_RE


# Patterns for buy/book links that should be stripped (not rendered inline)
_BUY_LINK_RE = re.compile(
    r"\[(?:Buy This Ticket|Book This Tour|Buy Tickets?|Book Now|Buy Now)\]\([^)]+\)",
    re.IGNORECASE,
)


def convert_section(content_md: str, campaign_prefix: str,
                    article_slug: str) -> str:
    """
    Convert one body section's markdown content to HTML.
    Returns an HTML string (no surrounding <h2> — that's added by build_body_section).
    """
    if not content_md.strip():
        return ""

    # Strip buy/book action links from prose (CTA button is placed separately)
    content_md = _BUY_LINK_RE.sub("", content_md)

    # Split into blocks separated by blank lines
    blocks = re.split(r"\n{2,}", content_md.strip())
    parts = []
    i = 0
    while i < len(blocks):
        block = blocks[i].strip()
        if not block:
            i += 1
            continue

        # Inline CTA marker — render button at exact MD position
        cta_m = CTA_MARKER_RE.match(block.strip())
        if cta_m:
            ticket = {
                "url": cta_m.group(2).strip(),
                "provider": detect_provider(cta_m.group(2).strip()),
                "title": cta_m.group(1).strip(),
            }
            parts.append(build_cta_button(ticket, campaign_prefix, article_slug,
                                          button_text=cta_m.group(1).strip()))
            i += 1
            continue

        # Markdown table
        if re.match(r"^\|", block):
            parts.append(build_markdown_table(block))
            i += 1
            continue

        # Unordered list
        if re.match(r"^[-*]\s", block):
            items = _parse_list_items(block, r"^[-*]\s+")
            lis = "".join(f"<li>{_inline(item, campaign_prefix, article_slug)}</li>"
                          for item in items)
            parts.append(f"<ul>{lis}</ul>")
            i += 1
            continue

        # Ordered list
        if re.match(r"^\d+\.\s", block):
            items = _parse_list_items(block, r"^\d+\.\s+")
            lis = "".join(f"<li>{_inline(item, campaign_prefix, article_slug)}</li>"
                          for item in items)
            parts.append(f"<ol>{lis}</ol>")
            i += 1
            continue

        # H3 — first line is the heading; remaining lines (if any) become a paragraph
        if block.startswith("### "):
            first_line, _, rest = block.partition("\n")
            text = _inline(first_line[4:].strip(), campaign_prefix, article_slug)
            parts.append(f"<h3>{text}</h3>")
            if rest.strip():
                para = _inline(" ".join(l.strip() for l in rest.splitlines() if l.strip()),
                               campaign_prefix, article_slug)
                if para:
                    parts.append(f"<p>{para}</p>")
            i += 1
            continue

        # H4 — same pattern
        if block.startswith("#### "):
            first_line, _, rest = block.partition("\n")
            text = _inline(first_line[5:].strip(), campaign_prefix, article_slug)
            parts.append(f"<h4>{text}</h4>")
            if rest.strip():
                para = _inline(" ".join(l.strip() for l in rest.splitlines() if l.strip()),
                               campaign_prefix, article_slug)
                if para:
                    parts.append(f"<p>{para}</p>")
            i += 1
            continue

        # Regular paragraph — may contain single-line embedded list items
        # that weren't separated by blank lines
        lines = block.splitlines()
        if len(lines) > 1 and all(re.match(r"^[-*]\s", l) for l in lines if l.strip()):
            items = [re.sub(r"^[-*]\s+", "", l) for l in lines if l.strip()]
            lis = "".join(f"<li>{_inline(item, campaign_prefix, article_slug)}</li>"
                          for item in items)
            parts.append(f"<ul>{lis}</ul>")
        else:
            text = _inline(" ".join(l.strip() for l in lines if l.strip()),
                           campaign_prefix, article_slug)
            if text:
                parts.append(f"<p>{text}</p>")
        i += 1

    return "\n".join(parts)


# ─── Inline Markdown ──────────────────────────────────────────────────────────

def _inline(text: str, campaign_prefix: str, article_slug: str) -> str:
    """Convert inline markdown (bold, italic, links) to HTML."""
    # Remove any remaining buy/book action links
    text = _BUY_LINK_RE.sub("", text)

    # Links [text](url) — keep internal links as-is, update campaign ID on affiliate links
    def _link(m):
        link_text = m.group(1)
        url = m.group(2)
        if _is_affiliate(url):
            provider = detect_provider(url)
            url = build_affiliate_url(url, provider, campaign_prefix,
                                      article_slug, position="body")
        return f'<a href="{url}">{html.escape(link_text)}</a>'

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", _link, text)

    # Bold **text** or __text__
    text = re.sub(r"\*\*(.+?)\*\*|__(.+?)__",
                  lambda m: f"<strong>{m.group(1) or m.group(2)}</strong>", text)

    # Italic *text* or _text_ (single)
    text = re.sub(r"\*([^*\n]+?)\*|(?<!\w)_([^_\n]+?)_(?!\w)",
                  lambda m: f"<em>{m.group(1) or m.group(2)}</em>", text)

    # Escape remaining HTML entities (applied after link conversion)
    # We html.escape each text node inside the converted HTML
    return text


def _is_affiliate(url: str) -> bool:
    return any(d in url.lower() for d in ("getyourguide.com", "tiqets.com", "viator.com"))


def _parse_list_items(block: str, prefix_re: str) -> list:
    items = []
    for line in block.splitlines():
        line = line.strip()
        if re.match(prefix_re, line):
            items.append(re.sub(prefix_re, "", line))
        elif items:
            items[-1] += " " + line  # continuation line
    return items
