#!/usr/bin/env python3
"""
Layer 1.5 — Top-Tickets Selector

Reconciles TOP_TICKET_INDEXES from the site .env with tickets.md to produce
an ordered list of ticket dicts ready for the component builder.

tickets.md format (pipe-delimited, no header):
  T1 | Title | https://url | GYG t123 | /internal/path/
  T2 | Title | https://url | Tiqets p456 | /internal/path/
  T3 | Title | https://url | Viator 789P10 | /internal/path/
"""

import re
from pathlib import Path


PROVIDERS = {
    "gyg": "gyg",
    "getyourguide": "gyg",
    "tiqets": "tiqets",
    "viator": "viator",
}

PARTNER_IDS = {
    "gyg": "9BAL9K3",
    "tiqets": "thebettervacation",
    "viator": "P00038490",
}


def load_tickets(tickets_path: str) -> dict:
    """Parse tickets.md → {ticket_num: ticket_dict}."""
    tickets = {}
    path = Path(tickets_path)
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4:
            continue
        raw_id = parts[0]
        m = re.match(r"^T(\d+)$", raw_id, re.IGNORECASE)
        if not m:
            continue
        ticket_num = int(m.group(1))
        title = parts[1] if len(parts) > 1 else ""
        url = parts[2] if len(parts) > 2 else ""
        partner_ref = parts[3] if len(parts) > 3 else ""
        internal_path = parts[4] if len(parts) > 4 else ""
        provider = _detect_provider(url, partner_ref)
        tickets[ticket_num] = {
            "id": ticket_num,
            "title": title,
            "url": url,           # keep as-is; only campaign ID is replaced per article
            "partner_ref": partner_ref,
            "internal_path": internal_path,
            "provider": provider,
        }
    return tickets


def select(top_ticket_indexes: list, tickets: dict) -> list:
    """
    Return ordered list of ticket dicts for the given indexes.

    Each dict has:
        id, title, url, provider
    url still has whatever affiliate params were in tickets.md;
    build_affiliate_url() will only swap the campaign ID.
    """
    result = []
    for idx in top_ticket_indexes:
        t = tickets.get(idx)
        if t is None:
            continue
        result.append({
            "id": t["id"],
            "title": t["title"],
            "url": t["url"],
            "provider": t["provider"],
        })
    return result


def _detect_provider(url: str, partner_ref: str) -> str:
    ref_lower = partner_ref.lower()
    url_lower = url.lower()
    for key, val in PROVIDERS.items():
        if key in ref_lower or key in url_lower:
            return val
    return "gyg"  # default
