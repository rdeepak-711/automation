#!/usr/bin/env python3
"""
article_meta.py — Post-verify sidecar writer for L1 card consumption.

After Layer 7.5 passes, writes <slug>.meta.json alongside the article HTML:
  - ticket articles → {"kind":"ticket","slug":"...","bullets":["...",...]}
  - others          → {"kind":"pyv"|"what_to_see"|"informational_ticket"|"other",
                        "slug":"...", "summary":"..."}

Fail-safe: any error → log warning, skip write. Never blocks the pipeline.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

MODEL = os.environ.get("CLAUDE_L2_META_MODEL", "claude-haiku-4-5-20251001")


def write_sidecar(out_path: Path, parsed: dict, ctx: dict, tickets_md_slugs: set) -> None:
    """Write sidecar JSON. Silently skips on any error."""
    try:
        _write(out_path, parsed, ctx, tickets_md_slugs)
    except Exception as exc:
        print(f"[article_meta] WARNING: skipped ({exc})", file=sys.stderr)


def _write(out_path: Path, parsed: dict, ctx: dict, tickets_md_slugs: set) -> None:
    slug = ctx.get("article_slug", out_path.stem)
    silo = ctx.get("silo", out_path.parent.name)

    # Determine kind
    if slug in tickets_md_slugs:
        kind = "ticket"
    elif silo == "plan-your-visit":
        kind = "pyv"
    elif silo == "what-to-see":
        kind = "what_to_see"
    elif silo == "tickets-tours":
        kind = "informational_ticket"
    else:
        kind = "other"

    # Build article text excerpt (title + intro + first ~800 chars)
    title = parsed.get("title", slug)
    intro = parsed.get("intro", "")
    body_parts = []
    for sec in parsed.get("sections", [])[:3]:
        body_parts.append(sec.get("content_md", "")[:300])
    body_excerpt = " ".join(body_parts)[:800]
    article_text = f"Title: {title}\n\nIntro: {intro}\n\nBody excerpt: {body_excerpt}"

    if kind == "ticket":
        prompt = (
            f"Read this travel article about a ticket or tour experience.\n\n"
            f"{article_text}\n\n"
            f"Return ONLY valid JSON with 2-4 short feature bullets about what this ticket/tour includes.\n"
            f"Each bullet ≤14 words. Be specific to this ticket, not generic.\n"
            f'{{\"bullets\": [\"...\", \"...\"]}}'
        )
    else:
        prompt = (
            f"Read this travel article.\n\n"
            f"{article_text}\n\n"
            f"Return ONLY valid JSON with a 2-3 sentence neutral summary (≤55 words total) "
            f"of what this article covers. Be specific, no marketing language.\n"
            f'{{\"summary\": \"...\"}}'
        )

    raw = _call_claude(prompt)
    if raw is None:
        return

    data = _parse_json(raw)
    if not data:
        print(f"[article_meta] WARNING: could not parse Claude output for {slug}", file=sys.stderr)
        return

    # Validate expected shape
    if kind == "ticket":
        if "bullets" not in data or not isinstance(data["bullets"], list):
            return
    else:
        if "summary" not in data or not isinstance(data["summary"], str):
            return

    sidecar = {"kind": kind, "slug": slug, **data}
    sidecar_path = out_path.with_suffix(".meta.json")
    sidecar_path.write_text(json.dumps(sidecar, ensure_ascii=False, indent=2), encoding="utf-8")


def _call_claude(prompt: str) -> str | None:
    try:
        r = subprocess.run(
            ["claude", "--print", "--model", MODEL],
            input=prompt, capture_output=True, text=True, timeout=45,
        )
        if r.returncode != 0:
            return None
        return r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def _parse_json(raw: str):
    raw = raw.strip()
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    raw = raw.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        for pattern in [r"\{.*\}", r"\[.*\]"]:
            m = re.search(pattern, raw, re.DOTALL)
            if m:
                try:
                    return json.loads(m.group(0))
                except json.JSONDecodeError:
                    pass
    return None


def load_tickets_md_slugs(site_slug: str, repo_root: Path | None = None) -> set:
    """Load col-5 slugs from input/<site>/tickets.md."""
    if repo_root is None:
        repo_root = Path(__file__).resolve().parents[3]
    tickets_path = repo_root / "input" / site_slug / "tickets.md"
    if not tickets_path.exists():
        return set()
    slugs = set()
    for line in tickets_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or not line[0].upper().startswith("T"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 5 and parts[4]:
            slug = parts[4].rstrip("/").rsplit("/", 1)[-1]
            if slug:
                slugs.add(slug)
    return slugs
