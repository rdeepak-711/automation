#!/usr/bin/env python3
"""
Layer 4 — Link Resolver

Resolves article slug references to live URLs using url-registry.json.
Handles the hagia-sofia case where MD uses short slug "dress-code" but
WordPress stores it as "hagia-sophia-dress-code".

All URL rewriting (www-stripping, absolute-to-relative) lives here.
No other module rewrites URLs.
"""

import json
import re
from pathlib import Path


def load_registry(registry_path: str) -> dict:
    with open(registry_path) as f:
        return json.load(f)


def resolve(url_or_slug: str, registry: dict) -> str | None:
    """
    Given a URL or slug, return the canonical live URL from the registry.

    Accepts:
      - Full absolute URL: "https://www.example.com/tickets/opening-hours/"
      - Root-relative path: "/tickets/opening-hours/"
      - Short slug: "opening-hours"

    Returns root-relative path (e.g. "/tickets/opening-hours/") or None if
    the slug is not found.
    """
    pages = registry.get("pages", {})
    domain = registry.get("domain", "")

    # Strip scheme + domain from absolute URLs
    target = url_or_slug.strip()
    if target.startswith("http"):
        # Remove scheme + www/non-www domain
        target = re.sub(r"^https?://(?:www\.)?\S+?(/)", r"\1", target)

    target = target.rstrip("/") + "/"

    # Direct match
    if target in pages:
        return target

    # Match by slug portion (last path segment)
    slug = target.rstrip("/").rsplit("/", 1)[-1]
    for path in pages:
        seg = path.rstrip("/").rsplit("/", 1)[-1]
        if seg == slug:
            return path

    # Fuzzy: slug is a suffix of a stored slug (hagia-sofia case)
    for path in pages:
        seg = path.rstrip("/").rsplit("/", 1)[-1]
        if seg.endswith(f"-{slug}") or seg.endswith(slug):
            return path

    return None
