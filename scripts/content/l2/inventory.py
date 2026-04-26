#!/usr/bin/env python3
"""
Layer 0 — Inventory & Input Contract

Verifies all required inputs exist and are well-formed before any processing
begins. Fails loudly with a specific error at the boundary rather than silently
downstream.
"""

import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
TEMPLATE_PATH = REPO_ROOT / "docs" / "Four Pages" / "attraction-individual-article-template.html"

VALID_SILOS = {"tickets-tours", "plan-your-visit", "what-to-see"}


def check_inputs(md_path: str, site_slug: str) -> dict:
    """
    Validate all required inputs for converting one MD article.

    Returns a dict with resolved absolute paths and env values:
        {
            "md_path": Path,
            "site_slug": str,
            "silo": str,                   # "tickets-tours" | "plan-your-visit" | "what-to-see"
            "article_slug": str,           # filename without leading digits and .md
            "template_path": Path,
            "tickets_path": Path,
            "registry_path": Path,
            "output_dir": Path,
            "campaign_prefix": str,
            "accent_color": str,           # hex, e.g. "#c0392b"
            "top_ticket_indexes": list,    # list of int, e.g. [1, 2]
            "site_env": dict,              # all env vars from site .env
        }

    Raises SystemExit with a clear message on any failure.
    """
    errors = []

    md = Path(md_path).resolve()
    if not md.exists():
        _fail(f"MD file not found: {md}")
    if not md.suffix == ".md":
        _fail(f"Expected a .md file, got: {md}")

    # Derive silo from parent directory name
    silo = md.parent.name
    if silo not in VALID_SILOS:
        _fail(
            f"MD file must be inside one of {sorted(VALID_SILOS)}, "
            f"but its parent directory is '{silo}' ({md})"
        )

    # Article slug — prefer URL field in MD frontmatter (matches XLSX),
    # fall back to stripping "article-NN-" prefix from filename.
    stem = md.stem
    url_slug = _slug_from_md_url(md)
    if url_slug:
        article_slug = url_slug
        filename_slug = url_slug  # used for registry lookup below
    else:
        m_prefix = re.match(r"^article-\d+-(.+)$", stem)
        filename_slug = m_prefix.group(1) if m_prefix else stem
        article_slug = filename_slug

    # Template
    if not TEMPLATE_PATH.exists():
        errors.append(f"Template not found: {TEMPLATE_PATH}")

    # tickets.md
    tickets_path = REPO_ROOT / "input" / site_slug / "tickets.md"
    if not tickets_path.exists():
        errors.append(f"tickets.md not found: {tickets_path}")

    # url-registry.json
    registry_path = REPO_ROOT / "output" / site_slug / "url-registry.json"
    if not registry_path.exists():
        errors.append(
            f"url-registry.json not found: {registry_path} "
            f"(run build-url-registry.py {site_slug} first)"
        )

    # Site .env
    site_env_path = REPO_ROOT / "sites" / site_slug / ".env"
    if not site_env_path.exists():
        # Fall back: check input/<site_slug>/.env
        site_env_path = REPO_ROOT / "input" / site_slug / ".env"
    if not site_env_path.exists():
        errors.append(
            f"Site .env not found at sites/{site_slug}/.env or input/{site_slug}/.env"
        )

    if errors:
        _fail("\n".join(errors))

    # Parse site .env
    site_env = _parse_env(site_env_path)

    campaign_prefix = site_env.get("CAMPAIGN_PREFIX") or site_env.get("CAMPAIGN_ID") or site_slug
    accent_color = (
        site_env.get("WP_BRAND_COLOR")
        or site_env.get("ACCENT_COLOR")
        or "#c0392b"
    )
    if not accent_color.startswith("#"):
        accent_color = f"#{accent_color}"

    # TOP_TICKET_INDEXES — comma-separated ints like "1,2" or "1,3,5"
    raw_idx = site_env.get("TOP_TICKET_INDEXES", "1,2")
    try:
        top_ticket_indexes = [int(x.strip()) for x in raw_idx.split(",") if x.strip()]
    except ValueError:
        _fail(f"TOP_TICKET_INDEXES must be comma-separated integers, got: '{raw_idx}'")

    if not top_ticket_indexes:
        _fail("TOP_TICKET_INDEXES is empty — need at least one ticket index")

    # Load registry and resolve the canonical article slug from XLSX data
    with open(registry_path) as f:
        registry = json.load(f)
    pages = registry.get("pages", {})

    # Find the registry entry whose slug matches (or ends with) the filename slug
    registry_slug = None
    for path, meta in pages.items():
        page_slug = meta.get("slug", "")
        if page_slug == filename_slug or page_slug.endswith(f"-{filename_slug}"):
            registry_slug = page_slug
            break
        # Also try: filename_slug is a suffix of page_slug
        if filename_slug and page_slug.endswith(filename_slug):
            registry_slug = page_slug
            break

    if registry_slug:
        article_slug = registry_slug
    else:
        # Non-fatal — fall back to filename-derived slug with a warning
        import sys
        print(
            f"[inventory] WARNING: no registry entry found for slug '{filename_slug}' "
            f"in {site_slug}; using filename-derived slug for campaign IDs",
            file=sys.stderr,
        )

    # Output dir
    output_dir = REPO_ROOT / "output" / site_slug / "l2-articles" / silo
    output_dir.mkdir(parents=True, exist_ok=True)

    return {
        "md_path": md,
        "site_slug": site_slug,
        "silo": silo,
        "article_slug": article_slug,
        "template_path": TEMPLATE_PATH,
        "tickets_path": tickets_path,
        "registry_path": registry_path,
        "output_dir": output_dir,
        "campaign_prefix": campaign_prefix,
        "accent_color": accent_color,
        "top_ticket_indexes": top_ticket_indexes,
        "site_env": site_env,
    }


def _parse_env(path: Path) -> dict:
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, val = line.partition("=")
                env[key.strip()] = val.strip().strip('"').strip("'")
    return env


def _slug_from_md_url(md_path: Path) -> str | None:
    """Quick scan of first 60 lines for URL field; returns last path segment."""
    url_re = re.compile(r"^\*\*URL:\*\*\s*(.+)$", re.IGNORECASE)
    yaml_re = re.compile(r"^url:\s*(.+)$", re.IGNORECASE)
    for line in md_path.read_text(encoding="utf-8").splitlines()[:60]:
        for pat in (url_re, yaml_re):
            m = pat.match(line.strip())
            if m:
                url = m.group(1).strip().strip('"').strip("'")
                slug = url.rstrip("/").rsplit("/", 1)[-1]
                return slug if slug else None
    return None


def _fail(msg: str):
    print(f"[inventory] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)
