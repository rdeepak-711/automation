#!/usr/bin/env python3
"""
Layer 7.5 — Claude Verifier (semantic fidelity)

Runs after the Python validator passes. Asks Claude to act as a reviewer —
checking that the generated HTML faithfully covers what the MD specified.

Claude does NOT rewrite anything here. It only judges and returns JSON.

Input to Claude:
  - Generated HTML (stripped of CSS/scripts for brevity)
  - MD sections list (headings + content_md briefs)
  - MD FAQ items
  - Expected structure order

Output from Claude (JSON):
  {
    "pass": true|false,
    "issues": [
      {
        "severity": "blocker"|"warning",
        "area": "structure"|"coverage"|"faq"|"cta"|"top-tickets"|"tone"|"hallucination",
        "where": "H2 'Opening Hours'",
        "description": "prose does not mention winter opening hours from MD"
      }
    ]
  }
"""

import json
import os
import re
import subprocess
import sys


VERIFIER_MODEL = os.environ.get("CLAUDE_VERIFIER_MODEL", "claude-haiku-4-5-20251001")


def verify(html: str, parsed_md: dict, campaign_prefix: str,
           article_slug: str) -> tuple:
    """
    Returns (pass: bool, issues: list).
    Warnings are returned but do not block; blockers do block.
    """
    prompt = _build_prompt(html, parsed_md)
    raw = _call_claude(prompt)
    if raw is None:
        # Claude unavailable — log warning, don't block
        print(
            "[verifier] WARNING: Claude verification skipped (Claude CLI unavailable)",
            file=sys.stderr,
        )
        return (True, [])

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        # Try to extract JSON from within the response
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except json.JSONDecodeError:
                print(f"[verifier] WARNING: could not parse verifier output: {raw[:200]}",
                      file=sys.stderr)
                return (True, [])
        else:
            return (True, [])

    passed = result.get("pass", True)
    issues = result.get("issues", [])

    # blockers only block; warnings are logged but pass
    blockers = [i for i in issues if i.get("severity") == "blocker"]
    return (len(blockers) == 0, issues)


def _extract_html_content(html: str) -> dict:
    """Pull only the content signals the verifier needs — no raw HTML sent to Claude."""
    h2s = re.findall(r"<h2[^>]*>(.*?)</h2>", html, re.DOTALL | re.IGNORECASE)
    h2s = [re.sub(r"<[^>]+>", "", h).strip() for h in h2s]

    # FAQ hub uses <h3 class="att-faq-question">; regular articles use <summary>
    faq_qs = re.findall(r"<summary[^>]*>(.*?)</summary>", html, re.DOTALL | re.IGNORECASE)
    faq_qs += re.findall(r'<h3[^>]*class="att-faq-question"[^>]*>(.*?)</h3>', html, re.DOTALL | re.IGNORECASE)
    faq_qs = [re.sub(r"<[^>]+>", "", q).strip() for q in faq_qs]

    aeo_m = re.search(
        r'class="att-aeo-block"[^>]*>(.*?)</div>', html, re.DOTALL | re.IGNORECASE
    )
    if aeo_m:
        aeo_raw = re.sub(r"<[^>]+>", "", aeo_m.group(1)).strip()
        aeo_text = (aeo_raw[:300] + "[…]") if len(aeo_raw) > 300 else aeo_raw
    else:
        aeo_text = ""

    return {"h2s": h2s, "faq_questions": faq_qs, "aeo_text": aeo_text}


def _build_prompt(html: str, parsed_md: dict) -> str:
    extracted = _extract_html_content(html)

    # Include FAQ H2 in expected if faq_items exist — assembler auto-generates it
    sections = parsed_md.get("sections", [])
    expected_h2s = "\n".join(
        f"  - {s['heading']}" + (" (question-phrased)" if s.get("is_question") else "")
        for s in sections
    )
    if parsed_md.get("faq_items") and not parsed_md.get("_is_faq_hub"):
        expected_h2s += "\n  - Frequently Asked Questions"
    expected_faqs = "\n".join(
        f"  - {i['question']}" for i in parsed_md.get("faq_items", [])
    )
    found_h2s = "\n".join(f"  - {h}" for h in extracted["h2s"])
    found_faqs = "\n".join(f"  - {q}" for q in extracted["faq_questions"])

    faq_hub_note = (
        "\nNOTE: This is a FAQ hub article. Q&A is distributed across thematic H2 sections "
        "(no dedicated 'Frequently Asked Questions' H2 exists or is expected).\n"
        if parsed_md.get("_is_faq_hub") else ""
    )

    return f"""You are a strict content reviewer. Compare what the MD specifies against what was extracted from the generated HTML.
{faq_hub_note}

## Expected (from MD source)

H2 headings (in order):
{expected_h2s or "(none)"}

FAQ questions:
{expected_faqs or "(none)"}

Quick Answer text:
{parsed_md.get("quick_answer", "(none)")[:300]}

## Found in generated HTML

H2 headings:
{found_h2s or "(none)"}

FAQ questions (from <summary> tags):
{found_faqs or "(none)"}

AEO block text:
{extracted["aeo_text"] or "(absent)"}

## Your Task

Return ONLY a JSON object:

{{
  "pass": true or false,
  "issues": [
    {{
      "severity": "blocker" or "warning",
      "area": "structure" | "coverage" | "faq" | "tone",
      "where": "H2 'Heading Text'",
      "description": "specific issue"
    }}
  ]
}}

Rules:
- "blocker" = expected H2 heading missing from HTML, or expected FAQ question missing, or AEO block absent when Quick Answer specified
- "warning" = minor discrepancy (heading text slightly different wording)
- If everything matches, return {{"pass": true, "issues": []}}
- Return ONLY the JSON — no preamble, no markdown fence
"""


def _call_claude(prompt: str) -> str | None:
    try:
        result = subprocess.run(
            ["claude", "--print", "--model", VERIFIER_MODEL],
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
