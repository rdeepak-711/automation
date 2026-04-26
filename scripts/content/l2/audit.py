#!/usr/bin/env python3
"""
L2 Article Audit

Generates one audit doc per L2 article for a site, cross-referencing:
  - XLSX manifest (ground truth for titles, URL slugs, silo)
  - MD source files
  - Generated HTML output files
  - tickets.md (valid ticket IDs and provider data)

Usage:
    python3 -m scripts.l2.audit <site-slug>
    python3 -m scripts.l2.audit basilica-cistern

Output:
    output/<site-slug>/audit/<id>-<slug>.md   — per-article audit doc
    output/<site-slug>/audit/AUDIT-SUMMARY.md — overall summary
"""

import argparse
import html as _html_mod
import json
import re
import sys
from pathlib import Path
from datetime import datetime

REPO_ROOT = Path(__file__).resolve().parents[3]

# Campaign ID checks
BRAND_NAMES_RE = re.compile(r"getyourguide|tiqets|viator", re.IGNORECASE)
ARROW_LITERAL_RE = re.compile(r"(?<![\\'\"])2192")


# ── XLSX reader ───────────────────────────────────────────────────────────────

def load_xlsx(xlsx_path: Path) -> list:
    """
    Returns list of dicts:
      {article_id, title, url_slug, article_slug, silo_dir, silo_url_prefix}
    """
    try:
        import openpyxl
    except ImportError:
        print("openpyxl not installed — run: pip install openpyxl", file=sys.stderr)
        sys.exit(1)

    wb = openpyxl.load_workbook(str(xlsx_path))
    ws = wb.active

    rows = []
    current_silo_dir = None
    current_silo_url = None

    # Silo header detection: col A contains "Plan Your Visit\n/plan-your-visit/" etc.
    SILO_MAP = {
        "plan your visit": ("plan-your-visit", "/plan-your-visit"),
        "tickets": ("tickets-tours", "/tickets"),
        "what to see": ("what-to-see", "/what-to-see"),
    }

    for row in ws.iter_rows(min_row=2, values_only=True):
        col_a, article_id, title, url_slug, *_ = (list(row) + [None] * 7)[:7]

        # Detect silo header in col A
        if col_a:
            col_a_lower = str(col_a).lower()
            for key, (sdir, surl) in SILO_MAP.items():
                if key in col_a_lower:
                    current_silo_dir = sdir
                    current_silo_url = surl
                    break

        if not article_id or not url_slug:
            continue

        # article_slug = last path segment of URL
        article_slug = url_slug.rstrip("/").rsplit("/", 1)[-1]

        rows.append({
            "article_id": str(article_id),
            "title": str(title) if title else "",
            "url_slug": str(url_slug),
            "article_slug": article_slug,
            "silo_dir": current_silo_dir,
            "silo_url_prefix": current_silo_url,
        })

    return rows


# ── tickets.md reader ─────────────────────────────────────────────────────────

def load_tickets_index(tickets_path: Path) -> dict:
    """Returns {T1: {id, name, url, provider, local_path}, ...}"""
    tickets = {}
    if not tickets_path.exists():
        return tickets
    for line in tickets_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4:
            continue
        tid = parts[0]  # e.g. "T1"
        tickets[tid] = {
            "id": tid,
            "name": parts[1] if len(parts) > 1 else "",
            "url": parts[2] if len(parts) > 2 else "",
            "provider": parts[3] if len(parts) > 3 else "",
            "local_path": parts[4] if len(parts) > 4 else "",
        }
    return tickets


# ── MD index builder ──────────────────────────────────────────────────────────

def build_md_index(site_slug: str) -> dict:
    """
    Scan all MD files under input/<site-slug>/<silo>/ and build:
      {article_slug: {"path": Path, "silo": silo_dir}}
    using the URL field in each MD's frontmatter.
    """
    from . import md_parser

    index = {}
    silos = ["plan-your-visit", "tickets-tours", "what-to-see"]
    for silo in silos:
        silo_dir = REPO_ROOT / "input" / site_slug / silo
        if not silo_dir.exists():
            continue
        for md_path in sorted(silo_dir.glob("*.md")):
            try:
                parsed = md_parser.parse(str(md_path))
                url = parsed.get("url", "")
                if url:
                    slug = url.rstrip("/").rsplit("/", 1)[-1]
                    if slug:
                        index[slug] = {"path": md_path, "silo": silo, "parsed": parsed}
            except Exception as e:
                # Fall back to filename slug
                slug = md_path.stem.split("-", 2)[-1] if "-" in md_path.stem else md_path.stem
                index[slug] = {"path": md_path, "silo": silo, "parsed": None, "error": str(e)}
    return index


# ── HTML checker ──────────────────────────────────────────────────────────────

def _md_has_cta(parsed_md: dict | None) -> bool:
    """True only if MD has explicit inline [CTA — "..." → url] markers."""
    if not parsed_md:
        return False
    return any(sec.get("ctas") for sec in parsed_md.get("sections", []))


def check_html(html_path: Path, parsed_md: dict, campaign_prefix: str,
               article_slug: str, tickets_index: dict) -> dict:
    """Run mechanical checks on a generated HTML file. Returns findings dict."""
    findings = {
        "size_bytes": html_path.stat().st_size,
        "has_aeo_block": False,
        "has_top_tickets": False,
        "has_cta_button": False,
        "has_faq_html": False,
        "has_faq_jsonld": False,
        "brand_leak": [],
        "arrow_literal": False,
        "h2_missing": [],
        "faq_open_missing": [],
        "campaign_top_bad": [],
        "campaign_body_bad": [],
        "top_ticket_partner_bad": [],
        "issues": [],
        "status": "PASS",
    }

    html = html_path.read_text(encoding="utf-8")

    findings["has_aeo_block"] = 'class="att-aeo-block"' in html
    findings["has_top_tickets"] = 'class="att-top-tickets"' in html
    findings["has_cta_button"] = 'class="att-buy-now-btn"' in html
    findings["has_faq_html"] = 'att-faq-details' in html
    findings["has_faq_jsonld"] = '"FAQPage"' in html

    # Brand leak (strip href attrs first)
    visible = re.sub(r'href="[^"]*"', 'href=""', html)
    for m in BRAND_NAMES_RE.finditer(visible):
        ctx = visible[max(0, m.start()-30):m.end()+30]
        if 'href=' not in ctx and '<a ' not in ctx:
            findings["brand_leak"].append(m.group(0))

    # Arrow rendering
    findings["arrow_literal"] = bool(ARROW_LITERAL_RE.search(html))

    # H2 coverage — normalize HTML entities and smart quotes before comparing
    def _norm(s: str) -> str:
        return (_html_mod.unescape(s)
                .replace("‘", "'").replace("’", "'")
                .replace("“", '"').replace("”", '"')
                .replace("–", "-").replace("—", "--"))

    html_norm = _norm(html)
    if parsed_md:
        for sec in parsed_md.get("sections", []):
            heading = sec.get("heading", "")
            if heading and _norm(heading) not in html_norm:
                findings["h2_missing"].append(heading)

        # FAQ open attribute check removed — <details> without open is valid;
        # user confirmed accordions open on click. New pipeline adds open by
        # default but old pipeline omitting it is not an audit failure.

    # Campaign ID checks
    expected_top = f"{campaign_prefix}-{article_slug}-top"
    expected_body = f"{campaign_prefix}-{article_slug}"

    top_section_m = re.search(r'class="att-top-tickets"(.*?)(?=class="att-article-body"|</section>|$)',
                              html, re.DOTALL)
    if top_section_m:
        for url in re.findall(r'href="(https?://[^"]+)"', top_section_m.group(1)):
            if "getyourguide.com" in url or "tiqets.com" in url or "viator.com" in url:
                if expected_top not in url:
                    findings["campaign_top_bad"].append(url[:100])
                # Check partner ID
                if "getyourguide.com" in url and "partner_id=9BAL9K3" not in url:
                    findings["top_ticket_partner_bad"].append(url[:100])
                elif "tiqets.com" in url and "tq_campaign=" not in url:
                    findings["top_ticket_partner_bad"].append(url[:100])
                elif "viator.com" in url and "campaign=" not in url:
                    findings["top_ticket_partner_bad"].append(url[:100])

    for cta_m in re.finditer(r'class="att-buy-now-btn"[^>]*href="([^"]+)"', html):
        url = cta_m.group(1)
        if "getyourguide.com" in url or "tiqets.com" in url or "viator.com" in url:
            if expected_top in url:
                findings["campaign_body_bad"].append(f"has -top suffix: {url[:80]}")
            elif expected_body not in url:
                findings["campaign_body_bad"].append(f"missing campaign ID: {url[:80]}")

    # Build issue list and status
    if findings["brand_leak"]:
        findings["issues"].append(f"FAIL: Brand names in visible text: {findings['brand_leak']}")
        findings["status"] = "FAIL"
    if not findings["has_aeo_block"]:
        findings["issues"].append("FAIL: Missing .att-aeo-block")
        findings["status"] = "FAIL"
    if not findings["has_top_tickets"]:
        findings["issues"].append("WARN: Missing .att-top-tickets")
        if findings["status"] == "PASS":
            findings["status"] = "WARN"
    if not findings["has_cta_button"] and _md_has_cta(parsed_md):
        findings["issues"].append("WARN: MD has CTA but HTML missing .att-buy-now-btn")
        if findings["status"] == "PASS":
            findings["status"] = "WARN"
    if findings["h2_missing"]:
        findings["issues"].append(f"FAIL: H2s from MD not in HTML: {findings['h2_missing']}")
        findings["status"] = "FAIL"
    if findings["arrow_literal"]:
        findings["issues"].append("FAIL: Arrow literal '2192' found in HTML")
        findings["status"] = "FAIL"
    if findings["campaign_top_bad"]:
        findings["issues"].append(f"FAIL: Top-ticket URLs missing -top campaign: {findings['campaign_top_bad']}")
        findings["status"] = "FAIL"
    if findings["campaign_body_bad"]:
        findings["issues"].append(f"FAIL: CTA button campaign ID wrong: {findings['campaign_body_bad']}")
        findings["status"] = "FAIL"
    if findings["top_ticket_partner_bad"]:
        findings["issues"].append(f"WARN: Top-ticket partner ID may be wrong: {findings['top_ticket_partner_bad']}")
        if findings["status"] == "PASS":
            findings["status"] = "WARN"
    if findings["faq_open_missing"]:
        findings["issues"].append(f"WARN: FAQ <details> missing 'open' attribute: {findings['faq_open_missing']}")
        if findings["status"] == "PASS":
            findings["status"] = "WARN"

    return findings


# ── Audit doc writer ──────────────────────────────────────────────────────────

def write_audit_doc(out_path: Path, row: dict, md_info: dict | None,
                    html_path: Path | None, html_findings: dict | None,
                    tickets_index: dict):
    """Write one per-article audit .md file."""
    lines = []
    article_id = row["article_id"]
    slug = row["article_slug"]
    status = "MISSING_HTML"
    if html_path and html_findings:
        status = html_findings["status"]
    elif md_info and not html_path:
        status = "MISSING_HTML"
    elif not md_info and html_path:
        status = "MISSING_MD"
    elif not md_info and not html_path:
        status = "BOTH_MISSING"

    lines.append(f"# Audit: {article_id} — {row['title']}")
    lines.append(f"\n**Status:** {status}")
    lines.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}")

    lines.append("\n## XLSX Entry")
    lines.append(f"- **ID:** {article_id}")
    lines.append(f"- **Title:** {row['title']}")
    lines.append(f"- **URL slug:** {row['url_slug']}")
    lines.append(f"- **Silo:** {row['silo_dir']}")

    lines.append("\n## Source MD")
    if md_info:
        lines.append(f"- **File:** `{md_info['path'].relative_to(REPO_ROOT)}`")
        parsed = md_info.get("parsed")
        if parsed:
            lines.append(f"- **MD title:** {parsed.get('title', '—')}")
            lines.append(f"- **MD description:** {parsed.get('description', '—')[:100]}")
            lines.append(f"- **MD URL:** {parsed.get('url', '—')}")
            lines.append(f"- **H2 sections:** {len(parsed.get('sections', []))}")
            lines.append(f"- **FAQ items:** {len(parsed.get('faq_items', []))}")
            lines.append(f"- **Related links:** {len(parsed.get('related_links', []))}")
            lines.append(f"- **Quick answer present:** {'Yes' if parsed.get('quick_answer') else 'No'}")

            # Top ticket references
            top_links = parsed.get("top_ticket_links", [])
            if top_links:
                lines.append(f"- **Top ticket links in MD:** {len(top_links)}")
                for tl in top_links:
                    lines.append(f"  - [{tl.get('text', '')}]({tl.get('url', '')})")

            # Inline CTAs across sections
            inline_ctas = []
            for sec in parsed.get("sections", []):
                for cta in sec.get("ctas", []):
                    inline_ctas.append(f"{sec['heading']}: \"{cta['button_text']}\" → {cta['link_target'][:60]}")
            if inline_ctas:
                lines.append(f"- **Inline CTA markers:** {len(inline_ctas)}")
                for c in inline_ctas:
                    lines.append(f"  - {c}")
            else:
                lines.append("- **Inline CTA markers:** none")
        elif "error" in md_info:
            lines.append(f"- **Parse error:** {md_info['error']}")
    else:
        lines.append("- **⚠️ MD file NOT FOUND** — no MD file with matching URL slug in this silo")

    # Ticket cross-reference
    lines.append("\n## Ticket Cross-Reference")
    if md_info and md_info.get("parsed"):
        parsed = md_info["parsed"]
        referenced_urls = set()
        for tl in parsed.get("top_ticket_links", []):
            referenced_urls.add(tl.get("url", ""))
        for sec in parsed.get("sections", []):
            for cta in sec.get("ctas", []):
                referenced_urls.add(cta.get("link_target", ""))

        matched = []
        unmatched = []
        for url in referenced_urls:
            if not url:
                continue
            # Find ticket by URL match
            found = None
            for tid, tdata in tickets_index.items():
                if tdata["url"] and (tdata["url"] in url or url in tdata["url"]):
                    found = tid
                    break
            if found:
                matched.append(f"  - {found} ({tickets_index[found]['name'][:60]}): URL matched")
            else:
                unmatched.append(f"  - ⚠️ URL not in tickets.md: {url[:80]}")

        if matched:
            lines.append("**Matched tickets:**")
            lines.extend(matched)
        if unmatched:
            lines.append("**Unmatched URLs (not in tickets.md):**")
            lines.extend(unmatched)
        if not matched and not unmatched:
            lines.append("No ticket URLs referenced in this MD.")
    else:
        lines.append("Cannot cross-reference — MD not parsed.")

    lines.append("\n## Output HTML")
    if html_path:
        lines.append(f"- **File:** `{html_path.relative_to(REPO_ROOT)}`")
        if html_findings:
            lines.append(f"- **Size:** {html_findings['size_bytes']:,} bytes")
            lines.append(f"- **AEO block:** {'✅' if html_findings['has_aeo_block'] else '❌ MISSING'}")
            lines.append(f"- **Top tickets bar:** {'✅' if html_findings['has_top_tickets'] else '⚠️ MISSING'}")
            lines.append(f"- **CTA button:** {'✅' if html_findings['has_cta_button'] else '⚠️ MISSING'}")
            lines.append(f"- **FAQ (HTML):** {'✅' if html_findings['has_faq_html'] else '⚠️ MISSING'}")
            lines.append(f"- **FAQ JSON-LD:** {'✅' if html_findings['has_faq_jsonld'] else '⚠️ MISSING'}")
            lines.append(f"- **Arrow literal '2192':** {'❌ FOUND' if html_findings['arrow_literal'] else '✅ clean'}")
            lines.append(f"- **Brand leak:** {'❌ ' + str(html_findings['brand_leak']) if html_findings['brand_leak'] else '✅ clean'}")
            if html_findings["h2_missing"]:
                lines.append(f"- **H2s missing from HTML:** {html_findings['h2_missing']}")
            else:
                lines.append("- **H2 coverage:** ✅ all present")
    else:
        lines.append("- **⚠️ HTML file NOT FOUND** — not yet generated")

    if html_findings and html_findings.get("issues"):
        lines.append("\n## Issues")
        for issue in html_findings["issues"]:
            lines.append(f"- {issue}")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ── Main ──────────────────────────────────────────────────────────────────────

def run_audit(site_slug: str, article_filter: str = None):
    print(f"[audit] {site_slug}: starting audit", flush=True)

    # Paths
    xlsx_candidates = list((REPO_ROOT / "input" / site_slug).glob("*.xlsx"))
    if not xlsx_candidates:
        print(f"[audit] ERROR: no XLSX found under input/{site_slug}/", file=sys.stderr)
        sys.exit(1)
    xlsx_path = xlsx_candidates[0]

    tickets_path = REPO_ROOT / "input" / site_slug / "tickets.md"
    output_root = REPO_ROOT / "output" / site_slug
    audit_dir = output_root / "audit"
    audit_dir.mkdir(parents=True, exist_ok=True)

    # Load ground-truth sources
    xlsx_rows = load_xlsx(xlsx_path)
    tickets_index = load_tickets_index(tickets_path)
    print(f"[audit] XLSX: {len(xlsx_rows)} articles, tickets.md: {len(tickets_index)} tickets", flush=True)

    # Read campaign prefix from .env
    campaign_prefix = site_slug  # default
    for env_candidate in [
        REPO_ROOT / "input" / site_slug / ".env",
        REPO_ROOT / "sites" / site_slug / ".env",
    ]:
        if env_candidate.exists():
            for line in env_candidate.read_text().splitlines():
                if line.startswith("CAMPAIGN_PREFIX="):
                    campaign_prefix = line.split("=", 1)[1].strip().strip('"')
            break

    # Build MD index
    print("[audit] building MD index...", flush=True)
    md_index = build_md_index(site_slug)
    print(f"[audit] MD index: {len(md_index)} articles indexed", flush=True)

    # Per-article audit
    summary_rows = []
    for row in xlsx_rows:
        af = article_filter.replace(".md", "").lower() if article_filter else None
        if af and af not in (row["article_slug"], row["article_id"].lower()):
            continue
        slug = row["article_slug"]
        article_id = row["article_id"]
        silo_dir = row["silo_dir"]

        # Find MD
        md_info = md_index.get(slug)

        # Find HTML
        html_path = None
        if silo_dir:
            candidate = output_root / "l2-articles" / silo_dir / f"{slug}.html"
            if candidate.exists():
                html_path = candidate

        # Check HTML
        html_findings = None
        if html_path and md_info and md_info.get("parsed"):
            html_findings = check_html(
                html_path, md_info["parsed"], campaign_prefix, slug, tickets_index
            )
        elif html_path:
            html_findings = check_html(html_path, None, campaign_prefix, slug, tickets_index)

        # Write audit doc
        doc_filename = f"{article_id.lower()}-{slug}.md"
        doc_path = audit_dir / doc_filename
        write_audit_doc(doc_path, row, md_info, html_path, html_findings, tickets_index)

        status = html_findings["status"] if html_findings else ("MISSING_HTML" if not html_path else "UNKNOWN")
        symbol = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌", "MISSING_HTML": "🔴", "MISSING_MD": "🔴", "BOTH_MISSING": "🔴"}.get(status, "?")
        print(f"[audit]  {symbol} {article_id} {slug:<45} {status}", flush=True)
        summary_rows.append((article_id, slug, status, html_path is not None, md_info is not None))

    # Write summary
    _write_summary(audit_dir, site_slug, xlsx_rows, summary_rows, tickets_index)
    print(f"\n[audit] done — audit docs in output/{site_slug}/audit/", flush=True)


def _write_summary(audit_dir: Path, site_slug: str, xlsx_rows: list,
                   summary_rows: list, tickets_index: dict):
    counts = {"PASS": 0, "WARN": 0, "FAIL": 0, "MISSING_HTML": 0, "MISSING_MD": 0, "BOTH_MISSING": 0}
    for _, _, status, _, _ in summary_rows:
        counts[status] = counts.get(status, 0) + 1

    total = len(summary_rows)
    lines = [
        f"# Audit Summary — {site_slug}",
        f"\n**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        f"**Total articles in XLSX:** {total}",
        f"**tickets.md entries:** {len(tickets_index)}",
        "",
        "| Status | Count |",
        "|--------|-------|",
        f"| ✅ PASS | {counts['PASS']} |",
        f"| ⚠️ WARN | {counts['WARN']} |",
        f"| ❌ FAIL | {counts['FAIL']} |",
        f"| 🔴 MISSING_HTML | {counts['MISSING_HTML']} |",
        f"| 🔴 MISSING_MD | {counts['MISSING_MD']} |",
        f"| 🔴 BOTH_MISSING | {counts.get('BOTH_MISSING', 0)} |",
        "",
        "## Per-Article Status",
        "",
        "| ID | Slug | Has MD | Has HTML | Status |",
        "|----|------|--------|----------|--------|",
    ]
    for article_id, slug, status, has_html, has_md in summary_rows:
        md_mark = "✅" if has_md else "❌"
        html_mark = "✅" if has_html else "❌"
        symbol = {"PASS": "✅ PASS", "WARN": "⚠️ WARN", "FAIL": "❌ FAIL"}.get(status, f"🔴 {status}")
        lines.append(f"| {article_id} | {slug} | {md_mark} | {html_mark} | {symbol} |")

    lines.append("\n## Tickets.md Coverage")
    lines.append(f"\n{len(tickets_index)} tickets registered in tickets.md:\n")
    for tid in sorted(tickets_index.keys()):
        t = tickets_index[tid]
        lines.append(f"- **{tid}**: {t['name'][:60]} ({t['provider']})")

    (audit_dir / "AUDIT-SUMMARY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Audit L2 articles for a site")
    p.add_argument("site_slug")
    p.add_argument("--article", help="Audit one article by slug or ID (e.g. opening-hours or p1)")
    args = p.parse_args()
    run_audit(args.site_slug, article_filter=args.article)
