#!/usr/bin/env python3
"""
build-article-metas.py — Generate article-metas.json for a site.

Walks output/<site>/l2-articles/{plan-your-visit,tickets-tours,what-to-see}/*.html,
extracts title + opening text, calls Claude in batches of 10 to produce:
  description: 2–3 sentences (≤55 words), factual, neutral
  tags: 1–2 short labels (e.g. "Skip-the-Line", "Opening Hours", "Guided Tour")

Output: output/<site>/article-metas.json
  {
    "<slug>": {
      "category": "tickets-tours",
      "title": "...",
      "description": "...",
      "tags": ["..."]
    }
  }

Usage:
  python3 scripts/content/build-article-metas.py <site-slug> [--force]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
CATEGORIES = ["plan-your-visit", "tickets-tours", "what-to-see"]
BATCH_SIZE = 10
MODEL = os.environ.get("CLAUDE_METAS_MODEL", "claude-haiku-4-5-20251001")


def _call_claude(prompt: str, timeout: int = 120) -> str | None:
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
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"(\[.*\]|\{.*\})", raw, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(1))
            except json.JSONDecodeError:
                pass
    return None


def _slug_to_title(slug: str) -> str:
    """Convert slug to readable title as last fallback."""
    return slug.replace("-", " ").title()


def _strip_site_suffix(title: str) -> str:
    """Remove ' | Site Name' or ' - Site Name' suffixes from <title> tags."""
    for sep in [" | ", " — ", " - ", " – "]:
        if sep in title:
            return title.split(sep)[0].strip()
    return title


def _extract_text(html: str) -> tuple[str, str]:
    """Return (title, opening_text) from article HTML."""
    # Try <h1> first (most reliable for article title)
    h1_m = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.IGNORECASE | re.DOTALL)
    if h1_m:
        title = re.sub(r"<[^>]+>", "", h1_m.group(1)).strip()
    else:
        # Try <title> tag, strip site suffix
        title_m = re.search(r"<title[^>]*>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
        if title_m:
            title = _strip_site_suffix(re.sub(r"<[^>]+>", "", title_m.group(1)).strip())
        else:
            title = ""  # caller uses slug_to_title fallback

    paras = re.findall(r"<p[^>]*>(.*?)</p>", html, re.IGNORECASE | re.DOTALL)
    text_parts = []
    total = 0
    for p in paras:
        clean = re.sub(r"<[^>]+>", "", p).strip()
        if len(clean) < 30:
            continue
        text_parts.append(clean)
        total += len(clean)
        if total >= 1200:
            break
    return title, " ".join(text_parts)[:1200]


def _load_top_ticket_slugs(site_slug: str, repo_root: Path) -> set[str]:
    """Return editorial article slugs matched to featured (top-ticket) positions.

    Reads _featured_match_tt from l1-config.json — populated after the first
    tickets-tours L1 generation run. Returns empty set if cache is absent.
    """
    cfg_path = repo_root / "input" / site_slug / "l1-config.json"
    if not cfg_path.exists():
        return set()
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        return set(cfg.get("_featured_match", {}).values())
    except (json.JSONDecodeError, OSError):
        return set()


def _load_top_highlight_slugs(site_slug: str, repo_root: Path) -> set[str]:
    """Return WTS article slugs selected as top highlights (from l1-config.json cache)."""
    cfg_path = repo_root / "input" / site_slug / "l1-config.json"
    if not cfg_path.exists():
        return set()
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        return set(cfg.get("_top_highlights_wts", []))
    except (json.JSONDecodeError, OSError):
        return set()


def _batch_call(articles: list[dict], top_ticket_slugs: set[str], top_highlight_slugs: set[str]) -> list[dict] | None:
    """Call Claude with a batch of articles. Returns list of {card_title, description, tags} in same order."""
    lines = []
    for i, a in enumerate(articles):
        prominence = ""
        if a["category"] == "tickets-tours" and a["slug"] in top_ticket_slugs:
            prominence = ", prominence: top_ticket"
        elif a["category"] == "what-to-see" and a["slug"] in top_highlight_slugs:
            prominence = ", prominence: top_highlight"
        lines.append(f"Article {i+1} [slug: {a['slug']}, category: {a['category']}{prominence}]: {a['title']!r}")
        if a["text"]:
            lines.append(f"  Content excerpt: {a['text'][:400]}")
    articles_block = "\n".join(lines)

    prompt = f"""For each article below, write metadata for a travel website card.

Return a JSON array with exactly {len(articles)} objects in the same order as the articles.
Each object:
  "card_title": 2–4 words max — short label for the card heading (e.g. "Dinner Cruise", "Skip-the-Line", "Family Visit", "Audio Guide"). Never repeat the attraction name. No articles (a/an/the).
  "description": benefit-focused — what the visitor gets or why it matters. Length varies by category and prominence:
    - plan-your-visit: 1 sentence, ≤20 words. Practical and direct.
    - tickets-tours with prominence=top_ticket: 3–4 sentences, 65–100 words. Cover what's included, why it stands out, who it suits.
    - tickets-tours (booking/experience articles — tours, cruises, skip-the-line, guided): 2–3 sentences, 45–70 words. Focus on the experience and booking benefit.
    - tickets-tours (planning/info articles — guides, tips, prices, what's included, how-to): 3–4 sentences, 65–100 words. Cover the key practical points a visitor needs.
    - what-to-see (any): 1–2 sentences, ≤35 words. Describe what the visitor sees and why it's worth visiting.
  "tags": array of 1–2 short labels (≤3 words each) — specific, useful for filtering
  "bullets": array of 3–4 strings, each ≤10 words — "what's included" style for ticket cards. Examples: "Audio guide in 19 languages", "Skip the queue entry", "Departs from city centre dock". ONLY include this field for tickets-tours articles. For plan-your-visit and what-to-see articles, omit "bullets" entirely.

card_title must be short enough to fit a card h3.
Tags must reflect the actual article topic — infer from slug, title, and content excerpt.

Articles:
{articles_block}

Return ONLY the JSON array. No markdown, no explanation.
"""
    raw = _call_claude(prompt, timeout=120)
    result = _parse_json(raw)
    if isinstance(result, list) and len(result) == len(articles):
        return result
    return None


def build_metas(site_slug: str, force: bool = False) -> None:
    output_dir = REPO_ROOT / "output" / site_slug
    l2_root = output_dir / "l2-articles"
    metas_path = output_dir / "article-metas.json"

    if not l2_root.exists():
        print(f"[{site_slug}] No l2-articles directory found: {l2_root}", file=sys.stderr)
        sys.exit(1)

    top_ticket_slugs = _load_top_ticket_slugs(site_slug, REPO_ROOT)
    top_highlight_slugs = _load_top_highlight_slugs(site_slug, REPO_ROOT)
    print(f"[{site_slug}] Top ticket slugs: {top_ticket_slugs or '(none)'}")
    print(f"[{site_slug}] Top highlight slugs: {top_highlight_slugs or '(none — WTS cache not yet generated)'}")

    # Load existing metas
    metas: dict = {}
    if metas_path.exists() and not force:
        metas = json.loads(metas_path.read_text(encoding="utf-8"))
        print(f"[{site_slug}] Loaded {len(metas)} existing metas")

    pending = []
    for cat in CATEGORIES:
        cat_dir = l2_root / cat
        if not cat_dir.exists():
            continue
        for html_file in sorted(cat_dir.glob("*.html")):
            slug = html_file.stem
            if slug in metas and not force:
                continue
            html = html_file.read_text(encoding="utf-8")
            title, text = _extract_text(html)
            pending.append({
                "slug": slug,
                "category": cat,
                "title": title or _slug_to_title(slug),
                "text": text,
            })

    if not pending:
        print(f"[{site_slug}] All articles already have metas. Use --force to rebuild.")
        _write(metas_path, metas)
        return

    print(f"[{site_slug}] Processing {len(pending)} articles in batches of {BATCH_SIZE}...")

    for batch_start in range(0, len(pending), BATCH_SIZE):
        batch = pending[batch_start: batch_start + BATCH_SIZE]
        batch_nums = f"{batch_start+1}–{batch_start+len(batch)}"
        print(f"  Batch {batch_nums} of {len(pending)}...")

        result = _batch_call(batch, top_ticket_slugs, top_highlight_slugs)
        if result is None:
            print(f"  [WARN] Claude call failed for batch {batch_nums}. Skipping.", file=sys.stderr)
            continue

        for article, meta_item in zip(batch, result):
            entry = {
                "category": article["category"],
                "title": article["title"],
                "card_title": meta_item.get("card_title", ""),
                "description": meta_item.get("description", ""),
                "tags": meta_item.get("tags", []),
            }
            if article["category"] == "tickets-tours":
                entry["bullets"] = meta_item.get("bullets", [])
            metas[article["slug"]] = entry

    _write(metas_path, metas)
    print(f"[{site_slug}] Wrote {len(metas)} metas to {metas_path}")


def _write(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


# ---------------------------------------------------------------------------
# Verify + Fix
# ---------------------------------------------------------------------------

def _check_topic_drift_claude(entries: list[dict]) -> dict[str, str]:
    """
    Batch Claude call: for each entry check if description matches slug topic.
    Returns {slug: reason} for off-topic entries only.
    Synonyms are fine — only flags truly wrong topics.
    """
    if not entries:
        return {}
    lines = []
    for e in entries:
        lines.append(f'  {e["slug"]}: title="{e["title"]}" | desc="{e["desc"][:120]}"')
    block = "\n".join(lines)
    prompt = f"""For each article below, does the description cover the topic implied by the slug?
Synonyms are FINE (e.g. slug "prices" + desc "admission fees" = OK, slug "kids" + desc "family-friendly" = OK).
Only flag if the description is clearly about a DIFFERENT subject.

{block}

Return ONLY a JSON object. Keys = slugs that are OFF-TOPIC. Values = one-line reason.
Slugs that are fine should NOT appear in the output.
Example: {{"bad-slug": "describes X but slug implies Y"}}
If all are fine, return: {{}}"""
    raw = _call_claude(prompt, timeout=90)
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{[^{}]*\}", raw, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                pass
    return {}


def verify_metas(site_slug: str, quiet: bool = False) -> list[str]:
    """Quality checks on article-metas.json. Returns flagged slugs."""
    metas_path = REPO_ROOT / "output" / site_slug / "article-metas.json"
    if not metas_path.exists():
        print(f"[{site_slug}] No article-metas.json found", file=sys.stderr)
        return []

    metas = json.loads(metas_path.read_text(encoding="utf-8"))

    # Checks 1–3: fast heuristics (no Claude)
    issues_map: dict[str, list[str]] = {}
    claude_candidates = []

    for slug, m in metas.items():
        issues = []
        title = m.get("title", "")
        desc = m.get("description", "")
        tags = m.get("tags", [])

        if title.lower() == _slug_to_title(slug).lower():
            issues.append("title=slug (h1 extraction failed)")
        cat = m.get("category", "")
        min_desc = 80 if cat == "tickets-tours" else 30
        if len(desc.strip()) < min_desc:
            issues.append(f"desc too short ({len(desc.strip())} chars, min {min_desc})")
        if not tags:
            issues.append("no tags")
        if cat == "tickets-tours":
            bullets = m.get("bullets", [])
            if not bullets:
                issues.append("missing bullets (tickets-tours)")

        issues_map[slug] = issues
        # Only send to Claude if no structural issues (Claude can't fix those)
        if not issues:
            claude_candidates.append({"slug": slug, "title": title, "desc": desc})

    # Check 4: Claude topic-drift check (batched)
    print(f"[{site_slug}] Checking topic drift via Claude ({len(claude_candidates)} articles)...")
    drift = _check_topic_drift_claude(claude_candidates)
    for slug, reason in drift.items():
        issues_map.setdefault(slug, []).append(f"topic drift: {reason}")

    # Report
    flagged = []
    ok_count = 0
    for slug, issues in issues_map.items():
        if issues:
            if not quiet:
                print(f"  ✗ {slug}: {'; '.join(issues)}")
            flagged.append(slug)
        else:
            ok_count += 1

    print(f"[{site_slug}] Verify: {ok_count} OK, {len(flagged)} flagged")
    return flagged


def fix_metas(site_slug: str) -> None:
    """Re-run Claude only on flagged slugs, then re-verify."""
    print(f"[{site_slug}] Running verify pass...")
    flagged = verify_metas(site_slug)
    if not flagged:
        print(f"[{site_slug}] Nothing to fix.")
        return

    l2_root = REPO_ROOT / "output" / site_slug / "l2-articles"
    metas_path = REPO_ROOT / "output" / site_slug / "article-metas.json"
    metas = json.loads(metas_path.read_text(encoding="utf-8"))

    top_ticket_slugs = _load_top_ticket_slugs(site_slug, REPO_ROOT)
    top_highlight_slugs = _load_top_highlight_slugs(site_slug, REPO_ROOT)

    to_fix = []
    structural_only = []
    for slug in flagged:
        cat = metas.get(slug, {}).get("category", "")
        html_file = l2_root / cat / f"{slug}.html" if cat else Path("/nonexistent")
        if not html_file.exists():
            for c in CATEGORIES:
                candidate = l2_root / c / f"{slug}.html"
                if candidate.exists():
                    html_file = candidate
                    cat = c
                    break
        if not html_file.exists():
            print(f"  [SKIP] {slug}: HTML not found")
            continue
        html = html_file.read_text(encoding="utf-8")
        title, text = _extract_text(html)
        # If H1 still absent after re-read, title=slug is structural — Claude can't fix it
        if not title:
            structural_only.append(slug)
            print(f"  [STRUCTURAL] {slug}: no H1 in HTML — fix L2 article, not metas")
            continue
        to_fix.append({
            "slug": slug,
            "category": cat,
            "title": title,
            "text": text,
        })

    if not to_fix:
        if structural_only:
            print(f"[{site_slug}] {len(structural_only)} structural issue(s) need L2 HTML fix: {structural_only}")
        else:
            print(f"[{site_slug}] No fixable slugs (HTML missing for all flagged).")
        return

    print(f"[{site_slug}] Re-generating {len(to_fix)} flagged articles in batches of {BATCH_SIZE}...")
    for batch_start in range(0, len(to_fix), BATCH_SIZE):
        batch = to_fix[batch_start: batch_start + BATCH_SIZE]
        batch_nums = f"{batch_start+1}–{batch_start+len(batch)}"
        print(f"  Fix batch {batch_nums}...")
        result = _batch_call(batch, top_ticket_slugs, top_highlight_slugs)
        if result is None:
            print(f"  [WARN] Claude call failed for fix batch {batch_nums}.", file=sys.stderr)
            continue
        for article, meta_item in zip(batch, result):
            s = article["slug"]
            metas[s]["title"] = article["title"]
            metas[s]["card_title"] = meta_item.get("card_title", "")
            metas[s]["description"] = meta_item.get("description", "")
            metas[s]["tags"] = meta_item.get("tags", [])
            if article["category"] == "tickets-tours":
                new_bullets = meta_item.get("bullets", [])
                if new_bullets:
                    metas[s]["bullets"] = new_bullets

    _write(metas_path, metas)
    print(f"[{site_slug}] Fix done. Re-verifying...")
    verify_metas(site_slug)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Build article-metas.json for a site")
    p.add_argument("site_slug", help="Site slug (e.g. amsterdam-canal-cruise)")
    p.add_argument("--force", action="store_true", help="Regenerate all, ignore cache")
    p.add_argument("--verify", action="store_true", help="Check quality of existing metas")
    p.add_argument("--fix", action="store_true", help="Re-generate Claude output for flagged metas")
    args = p.parse_args()

    if args.verify and not args.fix:
        flagged = verify_metas(args.site_slug)
        sys.exit(1 if flagged else 0)
    elif args.fix:
        fix_metas(args.site_slug)
    else:
        build_metas(args.site_slug, force=args.force)
