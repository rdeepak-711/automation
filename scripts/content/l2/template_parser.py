#!/usr/bin/env python3
"""
Layer 2 — Template Parser

Reads the HTML template and extracts the <style> block verbatim.
The template is NOT modified. CSS is extracted once and embedded into
every generated article unchanged.

The HTML structure and class names defined in the template are reproduced
faithfully by the component builders in components.py.
"""

import re
from pathlib import Path


def parse(template_path: str) -> dict:
    """
    Read the template and return:
        {"css": str}   — verbatim <style>...</style> inner content
    """
    html = Path(template_path).read_text(encoding="utf-8")
    m = re.search(r"<style>(.*?)</style>", html, re.DOTALL | re.IGNORECASE)
    if not m:
        raise ValueError(f"No <style> block found in template: {template_path}")
    css = m.group(1)
    return {"css": css}
