#!/usr/bin/env python3
"""
Layer 1 — MD Parser

Parses one L2 article .md file into a structured dict. Handles two frontmatter
formats (YAML with --- delimiters, and bare **Field:** lines) and the body
sections the pipeline needs.

Output dict shape:
{
  "title": str,              # SEO title
  "description": str,        # meta description
  "url": str,                # canonical URL
  "category": str,           # "Tickets & Tours" | "Plan Your Visit" | "What To See"
  "sub_group": str,
  "quick_answer": str,       # text from > **Quick Answer:** blockquote
  "intro_paras": [str],      # 1-2 intro paragraphs (markdown)
  "sections": [              # body H2 sections (in order)
    {
      "heading": str,
      "is_question": bool,    # heading ends with "?"
      "content_md": str,      # raw markdown for this section (paragraphs, lists, tables)
      "aeo_hint": str|None,   # inline > **AEO Answer:** blockquote text under this H2
    }
  ],
  "faq_items": [             # from ## Frequently Asked Questions
    {"question": str, "answer": str}
  ],
  "related_links": [         # from ## Related Reading / Related Guides
    {"text": str, "url": str}
  ],
  "top_ticket_links": [      # from ## Top Tickets section
    {"text": str, "url": str}
  ],
}
"""

import re
from pathlib import Path


FAQ_HEADINGS = {"frequently asked questions", "faq"}
RELATED_HEADINGS = {"related reading", "related guides", "related articles", "related"}
TOP_TICKET_HEADINGS = {"top tickets", "top ticket", "tickets"}

# Matches inline CTA markers like:
#   `[CTA — "Buy This Ticket" → https://...]`
#   `[CTA - "Book Now" -> https://...]`
CTA_MARKER_RE = re.compile(
    r"`\[CTA\s*[—–-]+\s*\"([^\"]+)\"\s*(?:→|->)\s*([^\]]+)\]`"
)


def parse(md_path: str) -> dict:
    text = Path(md_path).read_text(encoding="utf-8")
    lines = text.splitlines()

    # ── Frontmatter ──────────────────────────────────────────────────────────
    meta, body_start = _extract_meta(lines)

    # ── Body lines ───────────────────────────────────────────────────────────
    body_lines = lines[body_start:]

    # Strip H1 if it duplicates the title (some MDs start with # Title)
    if body_lines and body_lines[0].startswith("# "):
        body_lines = body_lines[1:]

    # ── Quick Answer blockquote ───────────────────────────────────────────────
    quick_answer, body_lines = _extract_quick_answer(body_lines)

    # ── Split body into sections at ## headings ───────────────────────────────
    sections_raw = _split_sections(body_lines)

    intro_paras = []
    top_ticket_links = []
    top_ticket_heading = "Top Tickets"
    body_sections = []
    faq_items = []
    related_links = []
    blocks = []  # ordered sequence of block types as they appear in the MD

    # AEO answer was extracted from body before sections — record it first
    if quick_answer:
        blocks.append({"type": "aeo_answer"})

    # First "section" before any ## heading is the intro
    if sections_raw and sections_raw[0]["heading"] is None:
        intro_paras = _extract_paragraphs(sections_raw[0]["lines"])
        if intro_paras:
            blocks.append({"type": "intro_paras"})
        sections_raw = sections_raw[1:]

    body_section_index = 0
    for sec in sections_raw:
        heading_lower = sec["heading"].lower().strip() if sec["heading"] else ""

        if heading_lower in TOP_TICKET_HEADINGS:
            top_ticket_links = _extract_links(sec["lines"])
            top_ticket_heading = sec["heading"]
            blocks.append({"type": "top_tickets"})
        elif heading_lower in FAQ_HEADINGS:
            faq_items = _extract_faq(sec["lines"])
            blocks.append({"type": "faq"})
        elif heading_lower in RELATED_HEADINGS:
            related_links = _extract_links(sec["lines"])
            blocks.append({"type": "related"})
        else:
            aeo_hint, content_lines = _extract_aeo_hint(sec["lines"])
            content_md = "\n".join(content_lines).strip()
            # Collect CTAs for audit/validation — markers stay in content_md so
            # prose_converter renders them at their exact MD position
            ctas = [{"button_text": m.group(1).strip(), "link_target": m.group(2).strip()}
                    for m in CTA_MARKER_RE.finditer(content_md)]
            body_sections.append({
                "heading": sec["heading"],
                "is_question": sec["heading"].rstrip().endswith("?"),
                "content_md": content_md,
                "aeo_hint": aeo_hint,
                "ctas": ctas,
            })
            blocks.append({"type": "body_section", "index": body_section_index})
            body_section_index += 1

    return {
        "title": meta.get("title", ""),
        "description": meta.get("description", ""),
        "url": meta.get("url", ""),
        "category": meta.get("category", ""),
        "sub_group": meta.get("sub_group", ""),
        "quick_answer": quick_answer,
        "intro_paras": intro_paras,
        "sections": body_sections,
        "faq_items": faq_items,
        "related_links": related_links,
        "top_ticket_links": top_ticket_links,
        "top_ticket_heading": top_ticket_heading,
        "blocks": blocks,
    }


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _extract_meta(lines: list) -> tuple:
    """Extract metadata and return (meta_dict, body_start_index)."""
    meta = {}
    i = 0

    # YAML frontmatter: ---...---
    if lines and lines[0].strip() == "---":
        i = 1
        while i < len(lines) and lines[i].strip() != "---":
            if ":" in lines[i]:
                key, _, val = lines[i].partition(":")
                meta[_yaml_key(key)] = val.strip().strip('"').strip("'")
            i += 1
        return meta, i + 1

    # Bare **Field:** lines — may be preceded by an H1 heading and blank lines
    field_map = {
        "seo title": "title",
        "meta description": "description",
        "url": "url",
        "category": "category",
        "sub-group": "sub_group",
        "sub_group": "sub_group",
        "subgroup": "sub_group",
    }
    # Skip over leading H1 and blank lines before we look for **Field:** blocks
    while i < len(lines) and (lines[i].strip() == "" or lines[i].startswith("# ")):
        i += 1

    # Read **Field:** meta lines — blank lines between fields are OK; stop at
    # body content (blockquote, paragraph, list, or H2+)
    meta_end = i
    consecutive_blanks = 0
    while meta_end < len(lines):
        line = lines[meta_end]
        m = re.match(r"^\*\*(.+?)\*\*[:\s]+(.+)$", line)
        if m:
            raw_key = m.group(1).strip().lower().rstrip(":")
            val = m.group(2).strip()
            mapped = field_map.get(raw_key)
            if mapped:
                meta[mapped] = val
            consecutive_blanks = 0
            meta_end += 1
        elif line.strip() == "":
            consecutive_blanks += 1
            meta_end += 1
            # Two consecutive blank lines = body has started
            if consecutive_blanks >= 2 and meta:
                break
        else:
            # Non-meta, non-blank line — body has started
            break

    return meta, meta_end


def _yaml_key(raw: str) -> str:
    return raw.strip().lower().replace("-", "_").replace(" ", "_")


def _extract_quick_answer(lines: list) -> tuple:
    """Find and remove the FIRST > **Quick Answer:** blockquote. Returns (text, remaining_lines)."""
    result_lines = []
    qa = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        bq = re.match(r"^>\s*\*\*(?:Quick Answer|AEO Answer Block|AEO Answer):\*\*\s*(.*)$", line, re.IGNORECASE)
        if bq and not qa:
            # Only capture the first occurrence — subsequent ones are section-level AEO hints
            qa_parts = [bq.group(1).strip()]
            i += 1
            while i < len(lines) and lines[i].startswith(">"):
                qa_parts.append(lines[i].lstrip(">").strip())
                i += 1
            qa = " ".join(qa_parts).strip()
        else:
            result_lines.append(line)
            i += 1
    return qa, result_lines


def _split_sections(lines: list) -> list:
    """Split body lines into sections at ## H2 headings."""
    sections = []
    current_heading = None
    current_lines = []

    for line in lines:
        m = re.match(r"^##\s+(.+)$", line)
        if m:
            sections.append({"heading": current_heading, "lines": current_lines})
            current_heading = m.group(1).strip()
            current_lines = []
        else:
            current_lines.append(line)

    sections.append({"heading": current_heading, "lines": current_lines})
    return sections


def _extract_paragraphs(lines: list) -> list:
    """Return non-empty paragraphs as a list of stripped strings."""
    paras = []
    current = []
    for line in lines:
        if line.strip() == "":
            if current:
                paras.append(" ".join(current).strip())
                current = []
        else:
            # Skip bare-field lines (**Field:** format) that leaked past meta extraction
            if re.match(r"^\*\*[A-Z][^*]*\*\*[:\s]", line):
                continue
            current.append(line.strip())
    if current:
        paras.append(" ".join(current).strip())
    return [p for p in paras if p]


def _extract_aeo_hint(lines: list) -> tuple:
    """Find and remove > **AEO Answer(*):** blockquote. Returns (text|None, remaining_lines)."""
    result_lines = []
    aeo = None
    i = 0
    while i < len(lines):
        line = lines[i]
        bq = re.match(r"^>\s*\*\*(?:AEO Answer Block|AEO Answer|Quick Answer):\*\*\s*(.*)$", line, re.IGNORECASE)
        if bq:
            parts = [bq.group(1).strip()]
            i += 1
            while i < len(lines) and lines[i].startswith(">"):
                parts.append(lines[i].lstrip(">").strip())
                i += 1
            aeo = " ".join(parts).strip()
        else:
            result_lines.append(line)
            i += 1
    return aeo, result_lines


def _extract_links(lines: list) -> list:
    """Extract all markdown links from lines as [{"text": ..., "url": ...}]."""
    links = []
    for line in lines:
        for m in re.finditer(r"\[([^\]]+)\]\(([^)]+)\)", line):
            links.append({"text": m.group(1).strip(), "url": m.group(2).strip()})
    return links


def _extract_faq(lines: list) -> list:
    """
    Parse FAQ Q&A pairs. Supports two formats:
      1. **Question?** followed by answer paragraph(s)
      2. ### Question? followed by answer paragraph(s)
    """
    items = []
    current_q = None
    current_a_lines = []

    def flush():
        if current_q and current_a_lines:
            answer = " ".join(l.strip() for l in current_a_lines if l.strip())
            # Strip trailing arrow-link " → [text](url)" pattern from answers
            answer = re.sub(r"\s*→\s*\[[^\]]+\]\([^)]+\)$", "", answer).strip()
            items.append({"question": current_q, "answer": answer})

    for line in lines:
        # Format 1: **Bold question?**
        m = re.match(r"^\*\*(.+\?)\*\*\s*$", line.strip())
        if m:
            flush()
            current_q = m.group(1).strip()
            current_a_lines = []
            continue

        # Format 2: ### Heading question?
        m2 = re.match(r"^###\s+(.+\?)\s*$", line)
        if m2:
            flush()
            current_q = m2.group(1).strip()
            current_a_lines = []
            continue

        if current_q is not None:
            current_a_lines.append(line)

    flush()
    return items
