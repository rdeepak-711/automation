#!/usr/bin/env python3
"""
content_generator.py — Claude content generation for L1 plan-your-visit pages.

Each function returns structured content. Claude is called only when content
is not already cached in l1-config.json.

All Claude calls use claude --print via subprocess (same pattern as faq_generator.py).
Failure returns a safe default — never blocks the pipeline.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict

MODEL = os.environ.get("CLAUDE_L1_MODEL", "claude-haiku-4-5-20251001")


def _call_claude(prompt: str, timeout: int = 90) -> str | None:
    try:
        r = subprocess.run(
            ["claude", "--print", "--model", MODEL],
            input=prompt, capture_output=True, text=True, timeout=timeout,
        )
        if r.returncode != 0:
            return None
        return r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def _parse_json(raw: str | None):
    if not raw:
        return None
    raw = raw.strip()
    # Strip markdown fences
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    raw = raw.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Try to extract array or object
        for pattern in [r"\[.*\]", r"\{.*\}"]:
            m = re.search(pattern, raw, re.DOTALL)
            if m:
                try:
                    return json.loads(m.group(0))
                except json.JSONDecodeError:
                    pass
        return None


def rewrite_group_h2(attraction: str, subgroup: str, article_titles: list[str], cache: dict, force: bool = False) -> str:
    """Return a natural 4–8 word H2 phrase that includes the attraction name, no colons."""
    if not force and subgroup in cache:
        return cache[subgroup]
    titles_str = ", ".join(article_titles[:3])
    prompt = (
        f"Rewrite this section heading as a natural 4–8 word phrase an editor would write. "
        f"Must mention \"{attraction}\" naturally. No colons. Title Case. Return only the phrase, no quotes.\n\n"
        f"Section label: {subgroup}\n"
        f"Section contains articles like: {titles_str}"
    )
    raw = _call_claude(prompt, timeout=30)
    if raw and 5 < len(raw) < 80 and ":" not in raw:
        result = raw.strip().strip('"').strip("'")
    else:
        # Fallback: prepend attraction to subgroup naturally
        result = f"{attraction} {subgroup}"
    cache[subgroup] = result
    return result


def generate_article_groups(attraction: str, articles: list[dict], h2_cache: dict | None = None, force: bool = False, category: str = "plan-your-visit") -> list[dict]:
    """
    Group articles into 3–5 sections with H2 titles + sub-descriptions.

    If articles have subgroup values from config, use them.
    Otherwise ask Claude.

    Returns [{h2, desc, articles: [article_dicts]}]
    """
    # Use existing subgroups if present
    has_subgroups = any(a.get("subgroup") for a in articles)

    if h2_cache is None:
        h2_cache = {}

    if has_subgroups:
        groups_map = defaultdict(list)
        order = []
        for a in articles:
            sg = a.get("subgroup") or "General"
            if sg not in groups_map:
                order.append(sg)
            groups_map[sg].append(a)

        groups = []
        for sg in order:
            arts = groups_map[sg]
            h2 = rewrite_group_h2(attraction, sg, [a["title"] for a in arts], h2_cache, force)
            desc = _generate_group_desc(attraction, sg, arts)
            groups.append({"h2": h2, "desc": desc, "articles": arts})
        return groups

    # No subgroups — ask Claude to generate groupings
    n = len(articles)
    if n <= 6:
        target = 3
    elif n <= 12:
        target = 4
    else:
        target = 5

    silo_label = "what to see" if category == "what-to-see" else "travel guide"
    titles_list = "\n".join(f"  {i}. {a['title']}" for i, a in enumerate(articles))
    prompt = f"""Group the following {n} {silo_label} articles about {attraction} into exactly {target} logical sections.
Each section should have a natural H2 heading (4–8 words) that mentions "{attraction}" naturally — no colons, no "Attraction: Section" pattern. Write as an editor would.

Articles:
{titles_list}

Return ONLY a JSON array where each element has:
  "h2": "Natural heading mentioning {attraction} (4–8 words, no colons)",
  "desc": "One sentence describing this section (≤15 words)",
  "indexes": [list of article indexes from 0 to {n-1}]

Every article index must appear in exactly one group. No index omitted or duplicated.
"""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)

    if not result or not isinstance(result, list):
        # Fallback: split evenly
        chunk = max(1, n // target)
        result = []
        for i in range(0, n, chunk):
            result.append({
                "h2": f"{attraction} Planning Guides",
                "desc": "Essential guides for planning your visit.",
                "indexes": list(range(i, min(i + chunk, n))),
            })

    # Normalise to include article dicts
    groups = []
    for g in result:
        if "indexes" in g:
            arts = [articles[i] for i in g["indexes"] if i < len(articles)]
        elif "articles" in g:
            arts = g["articles"]
        else:
            arts = []
        h2 = g.get("h2", f"{attraction} Planning Guides")
        if attraction.lower() not in h2.lower():
            h2 = f"{attraction} {h2}"
        groups.append({
            "h2": h2,
            "desc": g.get("desc", ""),
            "articles": arts,
        })

    return groups


def _generate_group_desc(attraction: str, group_name: str, articles: list[dict]) -> str:
    titles = ", ".join(a["title"] for a in articles[:3])
    prompt = (
        f"Write a single-sentence description (≤15 words) for a section titled '{group_name}' "
        f"about {attraction}. The section contains articles like: {titles}. "
        f"Plain text only, no punctuation at end except period."
    )
    raw = _call_claude(prompt, timeout=30)
    if raw and len(raw) < 120:
        return raw.strip().rstrip(".")
    # Fallback
    return f"Essential {group_name.lower()} guides for your {attraction} visit."


def generate_card_brief(attraction: str, article_title: str) -> str:
    """Generate a 1–2 sentence card description for an article."""
    prompt = (
        f"Write a 1–2 sentence description (≤25 words) for a travel guide article card. "
        f"Be specific and useful to a visitor planning their trip. No marketing language. "
        f"Plain text only.\n\n"
        f"Article title: {article_title}\n"
        f"Attraction: {attraction}"
    )
    raw = _call_claude(prompt, timeout=30)
    if raw and 10 < len(raw) < 200:
        return raw.strip()
    return f"Practical guide to {article_title.lower()} at {attraction}."


def generate_quicktips(attraction: str, articles: list[dict]) -> list[dict]:
    """Generate 4 quicktip cards: {label, desc}."""
    article_list = "\n".join(
        f'  - "{a["title"]}" → {a["url"]}' for a in articles
    )
    prompt = f"""Generate exactly 4 quick-tip cards for a '{attraction} — Plan Your Visit' page.
Each tip covers a key planning topic. Labels: Tickets, Before you go, Best timing, On arrival.
Each desc: 1–2 sentences, practical and specific to {attraction}.

At least 2 of the 4 tips MUST contain exactly one inline link using this format: <a href="/plan-your-visit/slug/">2–3 word phrase</a>. Link only to slugs in the Available guides list. The other tips may skip links. Do NOT use "click here" or "read more" as link text.

Available guides:
{article_list}

Return ONLY a JSON array (desc values may contain inline <a> HTML):
[
  {{"label": "Tickets", "desc": "..."}},
  {{"label": "Before you go", "desc": "..."}},
  {{"label": "Best timing", "desc": "..."}},
  {{"label": "On arrival", "desc": "..."}}
]"""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    if isinstance(result, list) and len(result) == 4:
        return result
    return [
        {"label": "Tickets", "desc": f"Book {attraction} tickets online in advance. Popular slots sell out days ahead."},
        {"label": "Before you go", "desc": "Check opening hours, transport options, and entrance details before heading out."},
        {"label": "Best timing", "desc": "Early morning and late afternoon offer smaller crowds and the best experience."},
        {"label": "On arrival", "desc": "Arrive 15 minutes before your time slot. Security screening may be required."},
    ]


def generate_practical_info(attraction: str, articles: list[dict] | None = None) -> list[dict]:
    """Generate 4 practical information cards: {h3, p, items:[str]}."""
    article_list = ""
    if articles:
        article_list = "\nYou may naturally interlink 2–3 words within bullet items to relevant guides — only where it helps the reader. Use HTML: <a href=\"/plan-your-visit/slug/\">short phrase</a>. Do NOT link every bullet.\n\nAvailable guides:\n" + "\n".join(
            f'  - "{a["title"]}" → {a["url"]}' for a in articles
        )
    prompt = f"""Generate 4 practical information cards for a '{attraction} — Plan Your Visit' page.
Each card: h3 (title), p (1-sentence intro), items (4–5 bullet strings with specific advice).
{article_list}

Return ONLY a JSON array (items may contain inline <a> HTML):
[{{"h3": "...", "p": "...", "items": ["...", "..."]}}]

Make content specific to {attraction}. No generic filler."""
    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        return result[:4]
    return []


def generate_know_tips(attraction: str, articles: list[dict] | None = None) -> list[dict]:
    """Generate 6 know-before-you-book tips: {emoji, label, desc}."""
    article_list = ""
    if articles:
        article_list = "\nYou may naturally interlink 2–3 words within a desc to a relevant guide — only where helpful. Use HTML: <a href=\"/plan-your-visit/slug/\">short phrase</a>. Do NOT link every tip.\n\nAvailable guides:\n" + "\n".join(
            f'  - "{a["title"]}" → {a["url"]}' for a in articles
        )
    prompt = f"""Generate 6 'things to know' tips for '{attraction} — Plan Your Visit' page.
Each tip: emoji, bold label (3–5 words ending with em-dash), 1–2 sentence explanation.
{article_list}

Return ONLY a JSON array (desc may contain inline <a> HTML):
[{{"emoji": "🎫", "label": "Book online in advance —", "desc": "..."}}]

Make tips specific to {attraction}."""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        return result[:6]
    return []


def generate_booking_tips(attraction: str) -> list[dict]:
    """Generate 6 booking-focused tips for the Tickets & Tours page: {emoji, label, desc}."""
    prompt = f"""Generate 6 practical booking tips for visitors buying tickets to '{attraction}'.
Focus on: booking in advance, arrival timing, cancellation policy, mobile tickets, what's included/excluded, dress code or access rules.
Each tip: emoji, bold label (3–5 words ending with em-dash), 1–2 sentence explanation specific to {attraction}.

Return ONLY a JSON array:
[{{"emoji": "🎫", "label": "Book online in advance —", "desc": "..."}}]

Make tips specific and actionable for {attraction}."""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        return result[:6]
    return []


def generate_faqs(attraction: str, articles: list[dict]) -> list[dict]:
    """Generate 8–10 FAQ items: {question, answer}."""
    article_titles = [a["title"] for a in articles]
    prompt = f"""Generate 10 FAQ items for '{attraction} — Plan Your Visit' page.
Questions should cover topics visitors ask when planning their trip (hours, getting there, tickets, tips, accessibility, etc.).
Each answer: 1–3 sentences, factual, no filler.

Return ONLY a JSON array:
[{{"question": "Question?", "answer": "Answer."}}]"""
    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        return result[:10]
    return []


def generate_banner(attraction: str) -> dict:
    """Generate CTA banner: {h2, desc}."""
    prompt = (
        f"Write a short CTA banner for a '{attraction} — Plan Your Visit' page.\n"
        f"h2: 6–10 words, a call-to-action about booking tickets. MUST include '{attraction}' in the h2.\n"
        f"desc: 1 sentence, 15–20 words, encouraging visitors to book online.\n"
        f"Return ONLY JSON: {{\"h2\": \"...\", \"desc\": \"...\"}}"
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict) and "h2" in result and "desc" in result:
        if attraction.lower() not in result["h2"].lower():
            result["h2"] = f"Ready to book your {attraction} tickets?"
        return result
    return {
        "h2": f"Ready to book your {attraction} tickets?",
        "desc": "Secure your preferred time slot online and skip the queues.",
    }


def generate_crosslinks(attraction: str) -> dict:
    """Generate crosslink descriptions for tickets and what-to-see pages."""
    prompt = (
        f"Write two short descriptions (1–2 sentences each) for a travel website about {attraction}:\n"
        f"1. 'tickets_desc': describe what visitors find on the Tickets & Tours page\n"
        f"2. 'what_to_see_desc': describe what visitors find on the What to See page\n"
        f"Return ONLY JSON: {{\"tickets_desc\": \"...\", \"what_to_see_desc\": \"...\"}}"
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict):
        return result
    return {
        "tickets_desc": f"Compare all ticket options for {attraction} — skip-the-line entry, guided tours, and combo deals.",
        "what_to_see_desc": f"Discover the must-see highlights and masterpieces at {attraction}.",
    }


# ─────────────────────────────────────────────────────────────────────────────
# Tickets & Tours page generators
# ─────────────────────────────────────────────────────────────────────────────

REC_LABELS = [
    "Best for first-time visitors",
    "Best premium option",
    "Best budget choice",
    "Best combo value",
]


def generate_rec_callouts(attraction: str, tickets: list[dict], cache: dict, force: bool = False) -> list[dict]:
    """4 rec-strip callouts with inline links to ticket articles."""
    KEY = "_recs_tt"
    if not force and KEY in cache:
        return cache[KEY]
    ticket_list = "\n".join(f'  - "{t["title"]}" → {t["article_url"]}' for t in tickets[:10])
    prompt = f"""Write 4 recommendation callout blurbs for a '{attraction} Tickets & Tours' page.
Fixed labels (use them exactly): {REC_LABELS}
Each blurb: 1–2 sentences (≤35 words). Must contain exactly one inline link using:
<a href="/tickets/slug/">2–3 word phrase</a> — link to a relevant ticket article.
Do NOT use "click here".

Available ticket articles:
{ticket_list}

Return ONLY a JSON array with 4 objects (order matches the labels above):
[{{"label": "Best for first-time visitors", "desc": "..."}}, ...]"""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    if isinstance(result, list) and len(result) == 4:
        cache[KEY] = result
        return result
    fallback = [
        {"label": REC_LABELS[0], "desc": f"<a href=\"{tickets[0]['article_url']}\">Guided tours</a> give context on {attraction}'s history and make the most of your visit." if tickets else f"Guided tours are the best way to experience {attraction}."},
        {"label": REC_LABELS[1], "desc": f"Private tours offer a fully personalised pace with skip-the-line access at {attraction}."},
        {"label": REC_LABELS[2], "desc": f"Standard <a href=\"{tickets[0]['article_url']}\">entry tickets</a> are the most affordable way to visit {attraction}." if tickets else f"Standard entry tickets are the most affordable option."},
        {"label": REC_LABELS[3], "desc": f"Combo deals bundle {attraction} with nearby attractions and save on total cost."},
    ]
    cache[KEY] = fallback
    return fallback


def generate_featured_desc(attraction: str, ticket: dict, cache: dict, force: bool = False) -> str:
    """3–4 sentence description for a featured ticket card body."""
    KEY = f"_featured_tt_{ticket['tid']}"
    if not force and KEY in cache:
        return cache[KEY]
    bullets = ticket.get("bullets", [])
    prompt = (
        f"Write 3–4 sentences (60–90 words) describing this {attraction} ticket/tour for a featured card.\n"
        f"Cover: what's included, why it's worth it, who it suits best.\n"
        f"Be specific. No marketing fluff. Plain text only.\n\n"
        f"Ticket: {ticket['title']}"
        + (f"\nKnown features: {'; '.join(bullets[:4])}" if bullets else "")
    )
    raw = _call_claude(prompt, timeout=45)
    fallback = " ".join(bullets[:3]) if bullets else f"The {ticket['title']} — one of the top {attraction} experiences. Book in advance to secure your preferred time slot."
    result = raw.strip() if raw and 40 < len(raw) < 600 else fallback
    cache[KEY] = result
    return result


def generate_ticket_sections(
    attraction: str,
    featured: list[dict],
    other_tickets: list[dict],
    cache: dict,
    force: bool = False,
) -> list[dict]:
    """
    Group non-featured ticket articles into 2–4 sections.
    Featured tickets are told to Claude as already pinned; they are excluded from grouping.
    Returns list of {h2, desc, tids}.
    """
    KEY = "_ticket_sections_tt"
    if not force and KEY in cache:
        return cache[KEY]
    n = len(other_tickets)
    if n == 0:
        cache[KEY] = []
        return []
    target = 2 if n <= 6 else (3 if n <= 12 else 4)
    featured_block = "\n".join(f"  [{t['tid']}] {t['title']}" for t in featured)
    other_block = "\n".join(
        f"  [{t['tid']}] {t['title']}"
        + (f" | tags: {', '.join(t['tags'])}" if t.get("tags") else "")
        for t in other_tickets
    )
    prompt = f"""You are grouping ticket and tour articles for a travel page about {attraction!r}.

ALREADY SHOWN in "Top {attraction} Experiences" (do NOT include these):
{featured_block or "  (none)"}

Group the remaining {n} tickets below into exactly {target} sections.
Rules:
- Each section H2: 4–8 words, natural phrase, mentions {attraction!r}, no colon pattern
- Each section: one-sentence desc (≤15 words)
- Every remaining ticket appears in exactly one section

Remaining tickets:
{other_block}

Return ONLY a JSON array:
[{{"h2": "...", "desc": "...", "tids": ["T3", "T5", ...]}}]
"""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    groups = []
    remaining_tids = {t["tid"] for t in other_tickets}
    assigned: set[str] = set()
    if isinstance(result, list):
        for g in result:
            h2 = g.get("h2", f"{attraction} Tickets")
            # Strip colon-join pattern: "Stonehenge Tickets: Section" → "Stonehenge Tickets Section"
            if ":" in h2:
                before, _, after = h2.partition(":")
                h2 = f"{before.strip()} {after.strip()}"
            if attraction.lower() not in h2.lower():
                h2 = f"{attraction} {h2}"
            tids = [tid for tid in g.get("tids", []) if tid in remaining_tids]
            assigned.update(tids)
            if tids:
                groups.append({"h2": h2, "desc": g.get("desc", ""), "tids": tids})
    # Catch any unassigned tickets
    leftover = [t["tid"] for t in other_tickets if t["tid"] not in assigned]
    if leftover:
        if groups:
            groups[-1]["tids"].extend(leftover)
        else:
            groups = [{"h2": f"{attraction} Ticket Options", "desc": "All available tickets and tours.", "tids": leftover}]
    if not groups:
        groups = [{"h2": f"{attraction} Ticket Options", "desc": "All available tickets and tours.", "tids": [t["tid"] for t in other_tickets]}]

    # If Claude returned fewer sections than target, redistribute evenly
    if len(groups) < target:
        all_tids = [tid for g in groups for tid in g["tids"]]
        chunk = max(1, len(all_tids) // target)
        labels = ["Standard Tickets", "Guided & Themed Cruises", "Special Experiences", "Combo Packages"]
        groups = []
        for i in range(0, len(all_tids), chunk):
            chunk_tids = all_tids[i: i + chunk]
            label = labels[len(groups)] if len(groups) < len(labels) else "More Options"
            groups.append({
                "h2": f"{attraction} {label}",
                "desc": "",
                "tids": chunk_tids,
            })

    cache[KEY] = groups
    return groups


def generate_info_sections(
    attraction: str,
    informational: list[dict],
    cache: dict,
    force: bool = False,
) -> list[dict]:
    """
    Group informational T&T articles into 3–5 sections.
    Returns list of {h2, desc, slugs}.
    """
    KEY = "_info_sections_tt"
    if not force and KEY in cache:
        return cache[KEY]
    n = len(informational)
    if n == 0:
        cache[KEY] = []
        return []
    target = 3 if n <= 9 else (4 if n <= 16 else 5)
    articles_block = "\n".join(
        f"  [{a['url_slug']}] {a['title']}"
        + (f" | tags: {', '.join(a['tags'])}" if a.get("tags") else "")
        + (f" | {a['description'][:80]}" if a.get("description") else "")
        for a in informational
    )
    slug_list = [a["url_slug"] for a in informational]
    prompt = f"""You are grouping informational ticket guide articles for a travel page about {attraction!r}.

Group these {n} articles into exactly {target} sections.
Rules:
- Each section H2: 4–8 words, natural phrase, mentions {attraction!r}, no colon pattern
- Each section: one-sentence desc (≤15 words)
- Every article appears in exactly one section
- Group by topic (e.g. "how to buy", "skip-the-line options", "free entry", "tours & combos", "planning")

Articles (slug | title | context):
{articles_block}

Valid slugs: {slug_list}

Return ONLY a JSON array:
[{{"h2": "...", "desc": "...", "slugs": ["slug-1", "slug-2", ...]}}]
"""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    groups = []
    valid_slugs = {a["url_slug"] for a in informational}
    assigned: set[str] = set()
    if isinstance(result, list):
        for g in result:
            h2 = g.get("h2", f"{attraction} Ticket Guides")
            if attraction.lower() not in h2.lower():
                h2 = f"{attraction} {h2}"
            slugs = [s for s in g.get("slugs", []) if s in valid_slugs]
            assigned.update(slugs)
            if slugs:
                groups.append({"h2": h2, "desc": g.get("desc", ""), "slugs": slugs})
    # Catch unassigned
    leftover = [a["url_slug"] for a in informational if a["url_slug"] not in assigned]
    if leftover:
        if groups:
            groups[-1]["slugs"].extend(leftover)
        else:
            groups = [{"h2": f"{attraction} Ticket Guides", "desc": "Essential guides for visiting.", "slugs": leftover}]
    if not groups:
        groups = [{"h2": f"{attraction} Ticket Guides", "desc": "Essential guides for visiting.", "slugs": [a["url_slug"] for a in informational]}]
    cache[KEY] = groups
    return groups


def generate_comparison_rows(attraction: str, tickets: list[dict], cache: dict, force: bool = False) -> list[dict]:
    """Comparison table rows: {tid, best_for, subtitle}."""
    KEY = "_compare_tt"
    if not force and KEY in cache:
        return cache[KEY]
    ticket_list = "\n".join(f"  [{t['tid']}] {t['title']}" for t in tickets)
    prompt = f"""For each ticket/tour listed, write a short "best for" description (≤8 words) and a subtitle (≤6 words) about what the ticket includes.

Attraction: {attraction}

Tickets:
{ticket_list}

Return ONLY a JSON array (one entry per ticket in the same order):
[{{"tid": "T1", "best_for": "Budget travelers...", "subtitle": "Self-guided with audio guide"}}]"""
    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    if isinstance(result, list) and len(result) == len(tickets):
        cache[KEY] = result
        return result
    # Fallback: one row per ticket, minimal data
    fallback = [{"tid": t["tid"], "best_for": f"Visitors to {attraction}", "subtitle": ""} for t in tickets]
    cache[KEY] = fallback
    return fallback


def generate_decision_guide(attraction: str, tickets: list[dict], cache: dict, force: bool = False) -> list[dict]:
    """4 'How to pick' guide cards: {h3, bullets[]}. Bullets contain inline links."""
    KEY = "_decision_tt"
    if not force and KEY in cache:
        return cache[KEY]
    ticket_list = "\n".join(f'  - "{t["title"]}" → {t["article_url"]}' for t in tickets[:12])
    prompt = f"""Write 4 'How to Pick' guide cards for a '{attraction} Tickets & Tours' page.
Each card helps a different visitor type choose the right ticket.
Each card: h3 (scenario heading, 5–8 words), bullets (3 bullet sentences, each with one inline link to a ticket article).
Inline link format: <a href="/tickets/slug/">2–4 word phrase</a>

Available ticket articles:
{ticket_list}

Return ONLY a JSON array (exactly 4 elements):
[{{"h3": "...", "bullets": ["...<a href=...>...</a>...", ...]}}]

Make headings specific to {attraction}. Never use "Attraction:" colon pattern."""
    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and len(result) == 4:
        # Strip any <a> whose href contains a product-ID slug (e.g. -p1234567, -t1234567)
        _bad_href = re.compile(r'<a\s+href="[^"]*-[pt]\d{4,}[^"]*"[^>]*>.*?</a>', re.IGNORECASE)
        for card in result:
            card["bullets"] = [_bad_href.sub(lambda m: re.sub(r'<[^>]+>', '', m.group(0)), b) for b in card.get("bullets", [])]
        cache[KEY] = result
        return result
    fallback = [
        {"h3": f"If you want a guided {attraction} experience", "bullets": [f"Choose a guided tour for expert commentary on {attraction}.", "Book early to secure your preferred time slot.", "Small group options offer a more personal pace."]},
        {"h3": f"If you are on a budget", "bullets": [f"Standard entry tickets give full access to {attraction}.", "Look for free admission times if available.", "Skip audio guide add-ons to keep costs down."]},
        {"h3": f"If you are visiting with a group", "bullets": [f"Private tours at {attraction} offer fully personalised pacing.", "Group booking discounts may be available.", "Check cancellation policies before booking for groups."]},
        {"h3": f"If you want a premium experience", "bullets": [f"VIP or early-access tours offer exclusive {attraction} access.", "Private guided experiences are ideal for special occasions.", "Combo deals cover multiple sites in one booking."]},
    ]
    cache[KEY] = fallback
    return fallback


def generate_faqs_tickets(attraction: str, tickets: list[dict], cache: dict, force: bool = False) -> list[dict]:
    """8–10 FAQ items for the Tickets & Tours page."""
    KEY = "_faqs_tt"
    if not force and KEY in cache:
        return cache[KEY]
    ticket_names = ", ".join(t["title"] for t in tickets[:8])
    prompt = f"""Generate 10 FAQ items for '{attraction} — Tickets & Tours' page.
Cover: pricing, booking in advance, difference between ticket types, guided vs self-guided,
combo tickets, cancellation, time slots, skip-the-line.

Available tickets: {ticket_names}

Return ONLY a JSON array:
[{{"question": "Question?", "answer": "Answer."}}]

Answers: 1–3 sentences, specific to {attraction}. No filler."""
    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        cache[KEY] = result[:10]
        return result[:10]
    fallback = [
        {"question": f"Do I need to book {attraction} tickets in advance?", "answer": f"Yes — booking online in advance is strongly recommended. Tickets frequently sell out, especially during peak season and weekends."},
        {"question": f"What is the difference between a standard ticket and a guided tour?", "answer": f"A standard ticket gives self-guided access. Guided tours include an expert who provides context and commentary throughout your visit to {attraction}."},
    ]
    cache[KEY] = fallback
    return fallback


def generate_banner_tickets(attraction: str, cache: dict, force: bool = False) -> dict:
    """CTA banner for the Tickets & Tours page: {h2, desc}."""
    KEY = "_banner_tt"
    if not force and KEY in cache:
        return cache[KEY]
    prompt = (
        f"Write a short CTA banner for a '{attraction} Tickets & Tours' page.\n"
        f"h2: 6–10 words, call-to-action about booking tickets. MUST include '{attraction}' in the h2.\n"
        f"desc: 1 sentence, 15–20 words, encouraging visitors to book online.\n"
        f"Return ONLY JSON: {{\"h2\": \"...\", \"desc\": \"...\"}}"
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict) and "h2" in result and "desc" in result:
        if attraction.lower() not in result["h2"].lower():
            result["h2"] = f"Ready to book your {attraction} tickets?"
        cache[KEY] = result
        return result
    fallback = {
        "h2": f"Ready to book your {attraction} tickets?",
        "desc": "Secure your preferred time slot online and skip the queues.",
    }
    cache[KEY] = fallback
    return fallback


def generate_crosslinks_tt(attraction: str, cache: dict, force: bool = False) -> dict:
    """Crosslink descriptions for plan-your-visit and what-to-see (TT page)."""
    KEY = "_crosslinks_tt"
    if not force and KEY in cache:
        return cache[KEY]
    prompt = (
        f"Write two short descriptions (1–2 sentences each) for a travel website about {attraction}:\n"
        f"1. 'pyv_desc': describe what visitors find on the Plan Your Visit page\n"
        f"2. 'what_to_see_desc': describe what visitors find on the What to See page\n"
        f"Return ONLY JSON: {{\"pyv_desc\": \"...\", \"what_to_see_desc\": \"...\"}}"
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict):
        cache[KEY] = result
        return result
    fallback = {
        "pyv_desc": f"Opening hours, getting there, visitor tips, and everything you need to plan your {attraction} visit.",
        "what_to_see_desc": f"Discover the must-see highlights, galleries, and masterpieces at {attraction}.",
    }
    cache[KEY] = fallback
    return fallback


# ─────────────────────────────────────────────────────────────────────────────
# What to See page generators
# ─────────────────────────────────────────────────────────────────────────────

def generate_featured_desc_wts(
    attraction: str,
    article: dict,
    repo_root,
    cache: dict,
    force: bool = False,
) -> str:
    """
    3-4 sentence description for a Top Highlights featured card.
    Reads the L2 HTML for context. Cached under '_featured_desc_wts_<slug>'.
    """
    from pathlib import Path
    slug = article["url_slug"]
    KEY = f"_featured_desc_wts_{slug}"
    if not force and KEY in cache:
        return cache[KEY]

    # Extract opening text from L2 HTML for context
    l2_path = Path(repo_root) / "output" / article.get("_site_slug", "") / "l2-articles" / "what-to-see" / f"{slug}.html"
    excerpt = ""
    if l2_path.exists():
        raw_html = l2_path.read_text(encoding="utf-8")
        paras = re.findall(r"<p[^>]*>(.*?)</p>", raw_html, re.IGNORECASE | re.DOTALL)
        parts = []
        total = 0
        for p in paras:
            clean = re.sub(r"<[^>]+>", "", p).strip()
            if len(clean) < 30:
                continue
            parts.append(clean)
            total += len(clean)
            if total >= 800:
                break
        excerpt = " ".join(parts)[:800]

    title = article.get("card_title") or article["title"]
    prompt = (
        f"Write a 2-3 sentence description (30-45 words) for a featured card on a '{attraction} — What to See' page.\n"
        f"Card heading: {title!r}\n"
        f"Cover: what the visitor sees or experiences and why it's worth prioritising at {attraction}. Be specific. No generic fluff. Complete sentences only.\n"
        + (f"Article excerpt for context:\n{excerpt[:400]}\n" if excerpt else "")
        + "Return ONLY the plain text description (no quotes, no HTML)."
    )
    raw = _call_claude(prompt, timeout=45)
    if raw and 50 < len(raw) < 700:
        result = raw.strip()
    else:
        result = article.get("description", f"One of the essential highlights at {attraction}. A must-see on any visit.")

    cache[KEY] = result
    return result


def generate_top_highlights(
    attraction: str,
    articles: list[dict],
    cache: dict,
    force: bool = False,
) -> list[str]:
    """
    Returns list of exactly 2 slugs to feature at the top of the What to See page.
    First: pillar/overview article. Second: standout sight.
    Cached under '_top_highlights_wts'.
    """
    KEY = "_top_highlights_wts"
    if not force and KEY in cache:
        return cache[KEY]

    block = "\n".join(
        f'  [{a["url_slug"]}] {a.get("card_title") or a["title"]}'
        + (f' — {a.get("description", "")[:100]}' if a.get("description") else "")
        + (f' (tags: {", ".join(a["tags"])})' if a.get("tags") else "")
        for a in articles
    )
    prompt = f"""You are curating the top of a 'What to See at {attraction}' page.

From the articles below, pick exactly 2 slugs to feature at the top:
  - one PILLAR/overview article (broad guide that sets up the page)
  - one STANDOUT article (a single striking sight, experience, or unique angle)

Articles:
{block}

Return ONLY JSON: {{"featured": ["slug1", "slug2"]}}
Use exact slugs as shown. No explanation."""

    raw = _call_claude(prompt, timeout=45)
    result = _parse_json(raw)
    slugs: list[str] = []
    if isinstance(result, dict):
        valid_slugs = {a["url_slug"] for a in articles}
        slugs = [s for s in result.get("featured", []) if s in valid_slugs][:2]

    if len(slugs) < 2:
        slugs = [a["url_slug"] for a in articles[:2]]

    cache[KEY] = slugs
    return slugs


def generate_how_to_choose(
    attraction: str,
    articles: list[dict],
    cache: dict,
    force: bool = False,
) -> list[dict]:
    """
    Returns 3-4 guide card dicts for 'How to Choose What to See' section.
    Each: {h3, p, items[], rec_text, rec_url, rec_link_label}
    Cached under '_how_to_choose_wts'.
    """
    KEY = "_how_to_choose_wts"
    if not force and KEY in cache:
        return cache[KEY]

    article_block = "\n".join(
        f'  [{a["url_slug"]}] {a.get("card_title") or a["title"]}'
        + (f' — {a.get("description", "")[:80]}' if a.get("description") else "")
        for a in articles
    )
    prompt = f"""Write 3-4 decision cards for 'How to Choose What to See at {attraction}'.
Each helps a different visitor profile pick what to focus on
(e.g. "If you only have 1 hour", "For first-timers", "If you love architecture", "With kids", "At night").
Lean into what makes {attraction} distinct.

For each card return:
  h3:             2-5 words, no colon
  p:              1 sentence intro
  items:          2-4 bullet strings (may include <a href="/what-to-see/slug/"> links to matching articles)
  rec_text:       short footer label ("Best pick:" or "Start with:")
  rec_url:        /what-to-see/slug/ (must be a slug from the list above)
  rec_link_label: the card_title of that article

Available articles (use their slugs for links):
{article_block}

Return ONLY a JSON array:
[{{"h3": "...", "p": "...", "items": ["...", "..."], "rec_text": "Best pick:", "rec_url": "/what-to-see/slug/", "rec_link_label": "..."}}]"""

    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and len(result) >= 2:
        cache[KEY] = result[:4]
        return result[:4]

    first = articles[0] if articles else {}
    fallback = [
        {
            "h3": "For First-Time Visitors",
            "p": f"Start with the most iconic aspects of {attraction}.",
            "items": [f"The overview guide gives you the full picture before you visit."],
            "rec_text": "Best pick:",
            "rec_url": f"/what-to-see/{first.get('url_slug', '')}/" if first else "/what-to-see/",
            "rec_link_label": first.get("card_title") or first.get("title", "Full Guide") if first else "Full Guide",
        },
        {
            "h3": "On a Short Visit",
            "p": f"Prioritise the highlights if your time at {attraction} is limited.",
            "items": [f"Focus on the signature sights that define {attraction}."],
            "rec_text": "Start with:",
            "rec_url": f"/what-to-see/{first.get('url_slug', '')}/" if first else "/what-to-see/",
            "rec_link_label": first.get("card_title") or first.get("title", "Full Guide") if first else "Full Guide",
        },
    ]
    cache[KEY] = fallback
    return fallback


def generate_faqs_wts(attraction: str, articles: list[dict], cache: dict, force: bool = False) -> list[dict]:
    """8–10 FAQ items for the What to See page. Cached under '_faqs_wts'."""
    KEY = "_faqs_wts"
    if not force and KEY in cache:
        return cache[KEY]
    prompt = f"""Generate 10 FAQ items for '{attraction} — What to See' page.
Cover what visitors ask about highlights, best spots, what not to miss,
time needed per section, photography, what's included with entry, etc.
Each answer: 1–3 sentences, factual, specific to {attraction}. No filler.

Return ONLY a JSON array:
[{{"question": "Question?", "answer": "Answer."}}]"""
    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        cache[KEY] = result[:10]
        return result[:10]
    fallback = [
        {"question": f"What should I see first at {attraction}?", "answer": f"Start with the most iconic highlight — the one element that defines {attraction}. Your entry ticket typically includes access to all main areas."},
        {"question": f"How long do I need to see everything at {attraction}?", "answer": f"Most visitors spend 1.5–3 hours at {attraction}. Allow more time if you plan to visit add-on areas or join a guided tour."},
    ]
    cache[KEY] = fallback
    return fallback


def generate_banner_wts(attraction: str, cache: dict, force: bool = False) -> dict:
    """CTA banner for the What to See page: {h2, desc}. Cached under '_banner_wts'."""
    KEY = "_banner_wts"
    if not force and KEY in cache:
        return cache[KEY]
    prompt = (
        f"Write a short CTA banner for a '{attraction} — What to See' page.\n"
        f"h2: 6–10 words, a call-to-action about seeing the highlights. MUST include '{attraction}' in the h2.\n"
        f"desc: 1 sentence, 15–20 words, encouraging visitors to book tickets in advance.\n"
        f"Return ONLY JSON: {{\"h2\": \"...\", \"desc\": \"...\"}}"
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict) and "h2" in result and "desc" in result:
        if attraction.lower() not in result["h2"].lower():
            result["h2"] = f"Ready to see {attraction} for yourself?"
        cache[KEY] = result
        return result
    fallback = {
        "h2": f"Ready to see {attraction} for yourself?",
        "desc": "Book your tickets in advance and choose the experience that matches your interests.",
    }
    cache[KEY] = fallback
    return fallback


def generate_crosslinks_wts(attraction: str, cache: dict, force: bool = False) -> dict:
    """Crosslink descriptions for tickets and plan-your-visit (WTS page). Cached under '_crosslinks_wts'."""
    KEY = "_crosslinks_wts"
    if not force and KEY in cache:
        return cache[KEY]
    prompt = (
        f"Write two short descriptions (1–2 sentences each) for a travel website about {attraction}:\n"
        f"1. 'tickets_desc': describe what visitors find on the Tickets & Tours page\n"
        f"2. 'pyv_desc': describe what visitors find on the Plan Your Visit page\n"
        f"Return ONLY JSON: {{\"tickets_desc\": \"...\", \"pyv_desc\": \"...\"}}"
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict):
        cache[KEY] = result
        return result
    fallback = {
        "tickets_desc": f"Compare all ticket options for {attraction} — skip-the-line entry, guided tours, and combo deals.",
        "pyv_desc": f"Opening hours, how to get there, visitor tips, and practical info for your {attraction} visit.",
    }
    cache[KEY] = fallback
    return fallback
