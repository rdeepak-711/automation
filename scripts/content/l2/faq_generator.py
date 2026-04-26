#!/usr/bin/env python3
"""
Layer 1.8 — FAQ Auto-Generator

Called when an article has no faq_items in the MD.
Asks Claude to generate 5–7 relevant Q&A pairs based on the article's
title and H2 section headings, then returns them as faq_items dicts.

Failure (Claude unavailable / bad JSON) → returns [] so pipeline continues
without FAQs rather than blocking.
"""

import json
import os
import re
import subprocess
import sys


GENERATOR_MODEL = os.environ.get("CLAUDE_VERIFIER_MODEL", "claude-haiku-4-5-20251001")


def generate_faqs(parsed_md: dict) -> list:
    """
    Returns list of {"question": str, "answer": str} dicts (5–7 items).
    Returns [] on failure — caller must decide whether to block or continue.
    """
    prompt = _build_prompt(parsed_md)
    raw = _call_claude(prompt)
    if raw is None:
        print("[faq-generator] WARNING: Claude unavailable — skipping FAQ generation", file=sys.stderr)
        return []

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\[.*\]", raw, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except json.JSONDecodeError:
                print(f"[faq-generator] WARNING: could not parse output: {raw[:200]}", file=sys.stderr)
                return []
        else:
            return []

    if not isinstance(result, list):
        return []

    items = []
    for item in result:
        q = (item.get("question") or "").strip()
        a = (item.get("answer") or "").strip()
        if q and a:
            items.append({"question": q, "answer": a})

    return items[:7]


def _build_prompt(parsed_md: dict) -> str:
    title = parsed_md.get("title", "")
    sections = parsed_md.get("sections", [])
    headings = "\n".join(f"  - {s['heading']}" for s in sections)
    intro = " ".join(parsed_md.get("intro_paras", []))[:400]

    return f"""You are writing FAQ content for a travel guide article.

Article title: {title}

Article sections (H2 headings):
{headings or "(none)"}

Article intro (first 400 chars):
{intro or "(none)"}

Generate exactly 6 FAQ items that a real visitor would ask about this specific topic.
Questions must be specific to the article subject — not generic travel questions.
Answers must be 1–3 sentences, factual, and directly useful.

Return ONLY a JSON array — no preamble, no markdown fence:

[
  {{"question": "Question here?", "answer": "Answer here."}},
  ...
]
"""


def _call_claude(prompt: str):
    try:
        result = subprocess.run(
            ["claude", "--print", "--model", GENERATOR_MODEL],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=90,
        )
        if result.returncode != 0:
            return None
        return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
