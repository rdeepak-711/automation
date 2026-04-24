#!/usr/bin/env python3
"""
homepage.py — L0 Homepage HTML assembler.

Reads article-metas.json + l1-config.json + tickets.md to build homepage.html.
CSS/JS extracted from attraction-homepage-template.html.

Usage:
  python3 scripts/content/l1_assembler/homepage.py <site-slug> [--force]

Sections:
  1. Hero
  2. Top Tickets (6 editorial ticket articles)
  3. Plan Your Visit (6 PYV articles)
  4. Things to Know (6 tips)
  5. What to See (6 WTS articles, top highlights first)
  6. CTA Banner
  7. FAQ
"""

import argparse
import html as _html
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

PLACEHOLDER_IMG = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-homepage-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent
MODEL = os.environ.get("CLAUDE_L1_MODEL", "claude-haiku-4-5-20251001")


# ─── Text helpers ─────────────────────────────────────────────────────────────

def _e(text: str) -> str:
    return _html.escape(str(text), quote=True)


def _raw(text: str) -> str:
    return str(text)


# ─── Env loading ──────────────────────────────────────────────────────────────

def _load_env(site_slug: str) -> dict:
    env = {}
    for env_path in [REPO_ROOT / ".env", REPO_ROOT / "input" / site_slug / ".env"]:
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ─── Affiliate URL stamping ────────────────────────────────────────────────────

def _stamp_campaign(base_url: str, campaign_id: str) -> str:
    if base_url.startswith("/"):
        return base_url
    parsed = urlparse(base_url)
    host = parsed.hostname or ""
    params = parse_qs(parsed.query, keep_blank_values=True)
    for k in list(params):
        if k in ("partner_id", "cmp", "partner", "tq_campaign", "pid", "mcid", "medium", "campaign"):
            del params[k]
    clean = {k: v[0] if len(v) == 1 else v for k, v in params.items()}
    if "getyourguide.com" in host:
        clean["partner_id"] = "9BAL9K3"
        clean["cmp"] = campaign_id
    elif "tiqets.com" in host:
        clean["partner"] = "thebettervacation"
        clean["tq_campaign"] = campaign_id
    elif "viator.com" in host:
        clean["pid"] = "P00038490"
        clean["mcid"] = "42383"
        clean["medium"] = "link"
        clean["campaign"] = campaign_id
    else:
        clean["cmp"] = campaign_id
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, urlencode(clean, doseq=True), parsed.fragment))


# ─── Claude helper ────────────────────────────────────────────────────────────

def _call_claude(prompt: str, timeout: int = 90) -> str | None:
    try:
        r = subprocess.run(
            ["claude", "--print", "--model", MODEL],
            input=prompt, capture_output=True, text=True, timeout=timeout,
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def _parse_json(raw: str | None):
    if not raw:
        return None
    raw = raw.strip()
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    raw = raw.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        for pattern in [r"\[.*\]", r"\{.*\}"]:
            m = re.search(pattern, raw, re.DOTALL)
            if m:
                try:
                    return json.loads(m.group(0))
                except json.JSONDecodeError:
                    pass
    return None


# ─── CSS/JS extraction ────────────────────────────────────────────────────────

def _load_css_js() -> tuple[str, str]:
    """Return (css_block, js_block) from homepage template."""
    content = TEMPLATE_PATH.read_text(encoding="utf-8")
    css_m = re.search(r"<style>.*?</style>", content, re.DOTALL)
    js_m = re.search(r"<script>.*?</script>", content, re.DOTALL)
    css = css_m.group(0) if css_m else "<style></style>"
    js = js_m.group(0) if js_m else ""
    return css, js


# ─── Data loaders ─────────────────────────────────────────────────────────────

def _load_metas(site_slug: str) -> dict:
    """Load output/<site>/article-metas.json."""
    p = REPO_ROOT / "output" / site_slug / "article-metas.json"
    if not p.exists():
        print(f"[{site_slug}] ERROR: article-metas.json not found. Run build-article-metas.py first.", file=sys.stderr)
        sys.exit(1)
    return json.loads(p.read_text(encoding="utf-8"))


def _load_cfg(site_slug: str) -> dict:
    """Load input/<site>/l1-config.json."""
    p = REPO_ROOT / "input" / site_slug / "l1-config.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def _save_cfg(site_slug: str, cfg: dict) -> None:
    """Write l1-config.json back."""
    p = REPO_ROOT / "input" / site_slug / "l1-config.json"
    p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")


def _parse_tickets_md(site_slug: str) -> list[dict]:
    """Parse tickets.md — pipe-delimited: Tid | Title | URL | token | /slug/path/
    Returns list of {tid, title, affiliate_url, article_slug}."""
    tickets_path = REPO_ROOT / "input" / site_slug / "tickets.md"
    tickets = []
    if not tickets_path.exists():
        return tickets
    for line in tickets_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or not line[0].upper().startswith("T") or "|" not in line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 5:
            continue
        tid = parts[0]
        title = re.sub(r"\s+[Pp]\d{4,}$", "", parts[1]).strip()
        affiliate_url = parts[2]
        col5 = parts[4]
        article_slug = col5.rstrip("/").rsplit("/", 1)[-1] if "/" in col5.rstrip("/") else col5
        tickets.append({
            "tid": tid,
            "title": title,
            "affiliate_url": affiliate_url,
            "article_slug": article_slug,
        })
    return tickets
