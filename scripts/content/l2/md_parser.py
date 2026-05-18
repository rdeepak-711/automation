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
    r"`?\[CTA[:\s]*[—–-]*\s*[\"“]([^\"“”]+)[\"”]\s*(?:→|->)\s*([^\]`]+)\]`?"
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
        # Detect **Top Tickets** used as a bold-paragraph label (not a heading).
        # Pattern: a para that starts with **Top Tickets** followed by link list items.
        _BOLD_TT_RE = re.compile(
            r"^\*\*(?:" + "|".join(re.escape(h) for h in TOP_TICKET_HEADINGS) + r")\*\*",
            re.IGNORECASE,
        )
        remaining_paras = []
        for para in intro_paras:
            if _BOLD_TT_RE.match(para) and not top_ticket_links:
                top_ticket_links = _extract_links([para])
                top_ticket_heading = "Top Tickets"
            else:
                remaining_paras.append(para)
        intro_paras = remaining_paras
        if top_ticket_links and not any(b["type"] == "top_tickets" for b in blocks):
            blocks.append({"type": "top_tickets"})
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
            new_faq = _extract_faq(sec["lines"])
            if faq_items:
                faq_items.extend(new_faq)  # merge into existing — don't add second block
            else:
                faq_items = new_faq
                blocks.append({"type": "faq"})
        elif heading_lower in RELATED_HEADINGS:
            related_links = _extract_links(sec["lines"])
            blocks.append({"type": "related"})
        else:
            # FAQ body section (e.g. "## FAQs About X") → collapsible faq_items
            if "faq" in heading_lower:
                from_body_faq = _extract_faq(sec["lines"])
                if from_body_faq:
                    faq_items.extend(from_body_faq)
                    if not any(b["type"] == "faq" for b in blocks):
                        blocks.append({"type": "faq"})
                    continue  # don't add as body_section

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
        "h1": meta.get("h1", ""),
        "featured_image": meta.get("featured_image", ""),
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

_BARE_FIELD_RE = re.compile(
    r"^(SEO Title|Meta Description|URL|Category|Sub-Group|SubGroup|Subgroup|Featured Image|Image):\s+(.+)$"
)


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

    # Capture H1 from first line before skipping it
    if lines and lines[0].startswith("# "):
        meta["h1"] = lines[0][2:].strip()

    # Bare **Field:** or plain Field: lines — may be preceded by an H1 heading and blank lines
    field_map = {
        "seo title": "title",
        "meta description": "description",
        "url": "url",
        "category": "category",
        "sub-group": "sub_group",
        "sub_group": "sub_group",
        "subgroup": "sub_group",
        "featured image": "featured_image",
        "image": "featured_image",
    }
    # Skip over leading H1 and blank lines before we look for Field: blocks
    while i < len(lines) and (lines[i].strip() == "" or lines[i].startswith("# ")):
        i += 1

    # Read **Field:** or plain Field: meta lines — blank lines between fields are OK; stop at
    # body content (blockquote, paragraph, list, or H2+)
    meta_end = i
    consecutive_blanks = 0
    while meta_end < len(lines):
        line = lines[meta_end]
        # Bold **Field:** format
        m = re.match(r"^\*\*(.+?)\*\*[:\s]+(.+)$", line)
        if m:
            raw_key = m.group(1).strip().lower().rstrip(":")
            val = m.group(2).strip()
            mapped = field_map.get(raw_key)
            if mapped:
                meta[mapped] = val
            consecutive_blanks = 0
            meta_end += 1
        else:
            # Bare Field: format (whitelisted names only)
            m2 = _BARE_FIELD_RE.match(line)
            if m2:
                raw_key = m2.group(1).strip().lower()
                val = m2.group(2).strip()
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
    """Find and remove the FIRST blockquote before any H2. Returns (text, remaining_lines)."""
    result_lines = []
    qa = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        # Stop treating blockquotes as quick answer once we're inside a section (## heading seen)
        if re.match(r"^##\s", line):
            result_lines.extend(lines[i:])
            break
        bq = re.match(r"^>\s*\*\*(?:Quick Answer|AEO Answer Block|AEO Answer):?\*\*\s*(.*)$", line, re.IGNORECASE)
        bq_q = re.match(r"^>\s*\*\*(.+\?)\*\*\s*$", line) if not bq else None
        bq_plain = re.match(r"^>\s+(.+)$", line) if not bq and not bq_q else None
        if bq and not qa:
            qa_parts = [bq.group(1).strip()]
            i += 1
            while i < len(lines) and lines[i].startswith(">"):
                qa_parts.append(lines[i].lstrip(">").strip())
                i += 1
            qa = " ".join(qa_parts).strip()
        elif bq_q and not qa and i + 1 < len(lines) and lines[i + 1].startswith(">"):
            # Question-style: skip question line, collect answer from following > lines
            i += 1
            qa_parts = []
            while i < len(lines) and lines[i].startswith(">"):
                qa_parts.append(lines[i].lstrip(">").strip())
                i += 1
            qa = " ".join(qa_parts).strip()
        elif bq_plain and not qa:
            # Plain blockquote before first H2 — treat as quick answer
            qa_parts = [bq_plain.group(1).strip()]
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
    """Split body lines into sections at ## H2 headings and special H3 section headings."""
    _SPECIAL_H3 = FAQ_HEADINGS | RELATED_HEADINGS | TOP_TICKET_HEADINGS
    sections = []
    current_heading = None
    current_lines = []

    for line in lines:
        m2 = re.match(r"^##\s+(.+)$", line)
        m3 = re.match(r"^###\s+(.+)$", line)
        if m2:
            sections.append({"heading": current_heading, "lines": current_lines})
            current_heading = m2.group(1).strip()
            current_lines = []
        elif m3 and m3.group(1).strip().lower() in _SPECIAL_H3:
            sections.append({"heading": current_heading, "lines": current_lines})
            current_heading = m3.group(1).strip()
            current_lines = []
        else:
            current_lines.append(line)

    sections.append({"heading": current_heading, "lines": current_lines})
    return sections


def _extract_paragraphs(lines: list) -> list:
    """Return non-empty paragraphs as a list of stripped strings.

    Blockquote lines (starting with '>') are joined with newlines so that
    prose_converter sees a proper multi-line block and can strip the '>'
    prefix from each line individually. Regular prose lines are joined with
    spaces as before.
    """
    paras = []
    current: list = []
    current_is_bq = False

    def _flush():
        if not current:
            return
        if current_is_bq:
            paras.append("\n".join(current))
        else:
            paras.append(" ".join(current).strip())

    for line in lines:
        if line.strip() == "":
            _flush()
            current = []
            current_is_bq = False
        else:
            # Skip field lines that leaked past meta extraction
            if re.match(r"^\*\*[A-Z][^*]*\*\*[:\s]", line):
                continue
            if _BARE_FIELD_RE.match(line):
                continue
            # Skip horizontal rules
            if re.match(r"^[-*_]{3,}\s*$", line):
                continue
            is_bq = line.strip().startswith(">")
            if current and is_bq != current_is_bq:
                # Type switch — flush accumulated paragraph first
                _flush()
                current = []
            current_is_bq = is_bq
            current.append(line.rstrip() if is_bq else line.strip())

    _flush()
    return [p for p in paras if p]


def _extract_aeo_hint(lines: list) -> tuple:
    """Find and remove > **AEO Answer(*):** blockquote. Returns (text|None, remaining_lines)."""
    result_lines = []
    aeo = None
    i = 0
    while i < len(lines):
        line = lines[i]
        bq = re.match(r"^>\s*\*\*(?:AEO Answer Block|AEO Answer|Quick Answer):?\*\*\s*(.*)$", line, re.IGNORECASE)
        if bq and aeo is None:  # only extract the first blockquote; leave the rest for prose_converter
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
            current_q = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", m.group(1).strip())
            current_a_lines = []
            continue

        # Format 2: ### Heading question?
        m2 = re.match(r"^###\s+(.+\?)\s*$", line)
        if m2:
            flush()
            current_q = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", m2.group(1).strip())
            current_a_lines = []
            continue

        if current_q is not None:
            current_a_lines.append(line)

    flush()
    return items
