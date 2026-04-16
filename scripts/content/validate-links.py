#!/usr/bin/env python3
"""
Pre-publish link validation script.

Usage:
    python3 scripts/content/validate-links.py <site-slug> [--silo <silo-name>]

Exit codes:
    0 = passed (warnings OK)
    1 = failed (errors present) or missing registry
"""

import argparse
import json
import os
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Affiliate/external domains — skip these from internal-link checks
# ---------------------------------------------------------------------------
AFFILIATE_DOMAINS = {
    "getyourguide.com",
    "tiqets.com",
    "viator.com",
    "booking.com",
    "airbnb.com",
}

SKIP_SCHEMES = {"mailto:", "tel:", "javascript:"}


def is_affiliate(href: str) -> bool:
    """Return True if the href points to a known affiliate domain."""
    try:
        parsed = urlparse(href)
        host = parsed.netloc.lower().lstrip("www.")
        return any(host == d or host.endswith("." + d) for d in AFFILIATE_DOMAINS)
    except Exception:
        return False


def should_skip(href: str) -> bool:
    """Return True for anchors, empty hrefs, and special schemes."""
    if not href or href.startswith("#"):
        return True
    return any(href.startswith(s) for s in SKIP_SCHEMES)


# ---------------------------------------------------------------------------
# HTML link extractor
# ---------------------------------------------------------------------------
class LinkExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for name, value in attrs:
                if name == "href" and value:
                    self.links.append(value)


def extract_links(html_path: Path) -> list[str]:
    """Parse an HTML file and return all href values."""
    try:
        content = html_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"  WARNING: could not read {html_path}: {exc}", file=sys.stderr)
        return []
    parser = LinkExtractor()
    try:
        parser.feed(content)
    except Exception:
        # HTMLParser is lenient; this is a safety net
        pass
    return parser.links


# ---------------------------------------------------------------------------
# URL normalisation
# ---------------------------------------------------------------------------
def normalize_path(path: str) -> str:
    """Ensure the path has a leading slash and a trailing slash."""
    path = path.strip()
    if not path.startswith("/"):
        path = "/" + path
    if not path.endswith("/"):
        path = path + "/"
    return path


# ---------------------------------------------------------------------------
# Main validation logic
# ---------------------------------------------------------------------------
def validate(site_slug: str, silo_filter: str | None) -> int:
    """
    Run all link checks.  Returns the number of errors found (0 = success).
    """
    base_dir = Path(__file__).resolve().parent.parent.parent  # repo root
    site_dir = base_dir / "output" / site_slug
    registry_path = site_dir / "url-registry.json"

    # ------------------------------------------------------------------
    # Load registry
    # ------------------------------------------------------------------
    if not registry_path.exists():
        print(f"ERROR: registry not found at {registry_path}", file=sys.stderr)
        print("       Run the URL registry generation step before validating.")
        sys.exit(1)

    try:
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"ERROR: could not parse registry JSON: {exc}", file=sys.stderr)
        sys.exit(1)

    domain: str = registry.get("domain", "")
    pages: dict = registry.get("pages", {})          # path → metadata
    expected_links: dict = registry.get("expected_links", {})
    l0_to_l1: list[str] = expected_links.get("L0_to_L1", [])
    l1_cross: list[str] = expected_links.get("L1_cross", [])

    # Normalise all registry paths so lookups are consistent
    registry_paths: set[str] = {normalize_path(p) for p in pages}

    # ------------------------------------------------------------------
    # Collect HTML files
    # ------------------------------------------------------------------
    homepage_file = site_dir / "homepage.html"
    l1_dir = site_dir / "l1-pages"
    l2_dir = site_dir / "l2-articles"

    l1_files: list[Path] = sorted(l1_dir.glob("*.html")) if l1_dir.is_dir() else []
    l2_files: list[Path] = []

    if l2_dir.is_dir():
        silos = (
            [l2_dir / silo_filter]
            if silo_filter
            else [d for d in l2_dir.iterdir() if d.is_dir()]
        )
        for silo in silos:
            if silo.is_dir():
                l2_files.extend(sorted(silo.glob("*.html")))

    homepage_files = [homepage_file] if homepage_file.exists() else []
    all_files = homepage_files + l1_files + l2_files

    print(f"\n=== Link Validation: {site_slug} ===\n")
    print(
        f"Scanning {len(l2_files)} L2 articles, {len(l1_files)} L1 pages, "
        f"{len(homepage_files)} homepage...\n"
    )

    errors: list[str] = []
    warnings: list[str] = []

    # ------------------------------------------------------------------
    # Helper — label a file relative to site_dir
    # ------------------------------------------------------------------
    def label(path: Path) -> str:
        try:
            return str(path.relative_to(site_dir))
        except ValueError:
            return str(path)

    # ------------------------------------------------------------------
    # Check 7: HTML files not in registry (warn only)
    # ------------------------------------------------------------------
    # dir_name → URL prefix from registry (e.g. "tickets-tours" → "/tickets")
    dir_to_url: dict = registry.get("dir_to_url", {})

    def file_to_registry_path(path: Path) -> str:
        """Derive the URL path that a file would correspond to."""
        rel = path.relative_to(site_dir)
        parts = rel.parts
        if parts[0] == "homepage.html":
            return "/"
        if parts[0] == "l1-pages":
            # l1-pages/tickets.html → /tickets/
            slug = parts[1].replace(".html", "")
            return "/" + slug + "/"
        if parts[0] == "l2-articles":
            dir_name = parts[1]
            slug = parts[2].replace(".html", "")
            # Use dir_to_url mapping if available (e.g. tickets-tours → /tickets)
            prefix = dir_to_url.get(dir_name, "/" + dir_name)
            return prefix.rstrip("/") + "/" + slug + "/"
        return "/" + "/".join(parts)

    # ------------------------------------------------------------------
    # Per-file checks (1, 2, 3, 4, 5)
    # ------------------------------------------------------------------
    for html_file in all_files:
        file_label = label(html_file)
        links = extract_links(html_file)

        # Derive what silo/level this file is
        rel_parts = html_file.relative_to(site_dir).parts
        is_homepage = rel_parts[0] == "homepage.html"
        is_l1 = rel_parts[0] == "l1-pages"
        is_l2 = rel_parts[0] == "l2-articles"
        parent_silo = rel_parts[1] if is_l2 else None

        seen_internal: set[str] = set()

        for href in links:
            if should_skip(href):
                continue

            # ----------------------------------------------------------------
            # Check 1: Absolute domain URL (ERROR)
            # External non-affiliate absolute URLs pointing to our own domain
            # ----------------------------------------------------------------
            if href.startswith("http://") or href.startswith("https://"):
                if is_affiliate(href):
                    continue
                # Flag if it uses our own domain (or any non-affiliate domain
                # that should be a relative link — we flag all absolute non-
                # affiliate https links as potential errors).
                if domain and domain in href:
                    errors.append(
                        f"  [{file_label}] Absolute URL (use relative path): {href}"
                    )
                elif not domain:
                    # No domain in registry — flag all absolute non-affiliate
                    errors.append(
                        f"  [{file_label}] Absolute URL (use relative path): {href}"
                    )
                # Absolute links to genuinely external non-affiliate sites are
                # intentionally not flagged (e.g. Wikipedia, news sites).
                # Only same-domain absolute URLs are errors.
                continue

            # ----------------------------------------------------------------
            # Check 2: Broken internal link (ERROR)
            # ----------------------------------------------------------------
            if href.startswith("/"):
                # Strip query string and fragment for registry lookup
                clean = href.split("?")[0].split("#")[0]
                norm = normalize_path(clean)
                seen_internal.add(norm)

                if norm not in registry_paths:
                    errors.append(
                        f"  [{file_label}] Broken link: {href} (not in registry)"
                    )

        # ----------------------------------------------------------------
        # Check 3: L2 → L1 parent link (WARNING)
        # ----------------------------------------------------------------
        if is_l2 and parent_silo:
            # Use dir_to_url to find actual L1 URL (e.g. tickets-tours → /tickets)
            parent_url = dir_to_url.get(parent_silo, "/" + parent_silo)
            parent_path = normalize_path(parent_url)
            if parent_path not in seen_internal:
                warnings.append(
                    f"  [{file_label}] No link back to parent L1 {parent_path}"
                )

        # ----------------------------------------------------------------
        # Check 4: L1 cross-link check (WARNING)
        # ----------------------------------------------------------------
        if is_l1 and l1_cross:
            for cross_path in l1_cross:
                norm = normalize_path(cross_path)
                # Don't require a page to link to itself
                own_path = file_to_registry_path(html_file)
                if normalize_path(own_path) == norm:
                    continue
                if norm not in seen_internal:
                    warnings.append(
                        f"  [{file_label}] Missing cross-link to {cross_path}"
                    )

        # ----------------------------------------------------------------
        # Check 5: L0 → L1 check (ERROR)
        # ----------------------------------------------------------------
        if is_homepage and l0_to_l1:
            for l1_path in l0_to_l1:
                norm = normalize_path(l1_path)
                if norm not in seen_internal:
                    errors.append(
                        f"  [{file_label}] Missing L0→L1 link to {l1_path}"
                    )

    # ------------------------------------------------------------------
    # Check 6: Orphaned articles — in registry but no HTML generated (WARNING)
    # ------------------------------------------------------------------
    generated_paths: set[str] = set()
    for html_file in all_files:
        generated_paths.add(normalize_path(file_to_registry_path(html_file)))

    for reg_path in registry_paths:
        meta = pages.get(reg_path) or pages.get(reg_path.rstrip("/")) or {}
        level = meta.get("level", "")
        if level in ("L2",) and reg_path not in generated_paths:
            warnings.append(f"  [registry] Orphaned (not yet generated): {reg_path}")

    # ------------------------------------------------------------------
    # Check 7: HTML files not in registry (WARNING)
    # ------------------------------------------------------------------
    for html_file in all_files:
        fp = normalize_path(file_to_registry_path(html_file))
        if fp != "/" and fp not in registry_paths:
            warnings.append(
                f"  [{label(html_file)}] HTML exists but not in registry: {fp}"
            )

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------
    if errors:
        print("ERRORS (blocks publishing):")
        for e in errors:
            print(e)
        print()

    if warnings:
        print("WARNINGS (review recommended):")
        for w in warnings:
            print(w)
        print()

    total_files = len(all_files)
    error_count = len(errors)
    warning_count = len(warnings)

    print("SUMMARY:")
    print(f"  Files checked: {total_files}")
    print(f"  Errors: {error_count}")
    print(f"  Warnings: {warning_count}")

    if error_count > 0:
        print("  Status: \u2717 FAILED \u2014 fix errors before publishing")
    else:
        print("  Status: \u2713 PASSED \u2014 safe to publish")

    print()
    return error_count


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Validate internal link integrity before publishing."
    )
    parser.add_argument("site_slug", help="Site slug (e.g. hagia-sofia)")
    parser.add_argument(
        "--silo",
        metavar="SILO_NAME",
        default=None,
        help="Limit L2 scan to a single silo (e.g. tickets-tours)",
    )
    args = parser.parse_args()

    error_count = validate(args.site_slug, args.silo)
    sys.exit(1 if error_count > 0 else 0)


if __name__ == "__main__":
    main()
