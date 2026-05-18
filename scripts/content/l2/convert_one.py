#!/usr/bin/env python3
"""
Layer 9 — Single-Article Orchestrator

Public entry point for converting one MD file to a validated HTML file.

Usage (CLI):
    python3 -m scripts.l2.convert_one <site-slug> <md-file-path> [--force]

Returns dict:
    {
        "status": "written" | "failed" | "skipped",
        "path": str | None,
        "reasons": [str],
    }
"""

import json
import sys
from pathlib import Path


def convert_article(md_path: str, site_slug: str, force: bool = False) -> dict:
    """Convert one MD article to HTML. Returns status dict."""
    from . import article_meta, assembler, faq_converter, faq_generator, inventory, link_resolver, md_parser, retry, top_tickets, validator, verifier

    tag = f"[{site_slug}/{Path(md_path).stem}]"

    # ── Layer 0 — Input contract ──────────────────────────────────────────────
    try:
        ctx = inventory.check_inputs(md_path, site_slug)
    except SystemExit as e:
        return {"status": "failed", "path": None, "reasons": [str(e)]}

    out_path = ctx["output_dir"] / f"{ctx['article_slug']}.html"
    if out_path.exists() and not force:
        return {"status": "skipped", "path": str(out_path), "reasons": []}

    _log(tag, "Layer 0: inputs OK")

    # ── Layer 1 — MD Parser ──────────────────────────────────────────────────
    parsed = md_parser.parse(str(ctx["md_path"]))
    _log(
        tag,
        f"Layer 1: parsed {len(parsed['sections'])} H2 sections, "
        f"{len(parsed['faq_items'])} FAQ items, "
        f"{len(parsed['related_links'])} related links",
    )

    # ── Layer 1.8 — FAQ auto-generator (when MD has no FAQ items) ───────────
    is_faq_hub_article = faq_converter.is_faq_hub(parsed)
    if not is_faq_hub_article and not parsed.get("faq_items"):
        generated = faq_generator.generate_faqs(parsed)
        if generated:
            # Inject FAQ block before 'related' in blocks list
            blocks = list(parsed.get("blocks", []))
            insert_at = next(
                (i for i, b in enumerate(blocks) if b["type"] == "related"),
                len(blocks),
            )
            blocks.insert(insert_at, {"type": "faq"})
            parsed = {**parsed, "faq_items": generated, "blocks": blocks}
            _log(tag, f"Layer 1.8: generated {len(generated)} FAQ items")
        else:
            _log(tag, "Layer 1.8: FAQ generation skipped or failed — proceeding without FAQs")

    # ── Layer 1.5 — Top-tickets selector ─────────────────────────────────────
    all_tickets = top_tickets.load_tickets(str(ctx["tickets_path"]))
    selected = top_tickets.select(ctx["top_ticket_indexes"], all_tickets)
    _log(tag, f"Layer 1.5: selected {len(selected)} top tickets {ctx['top_ticket_indexes']}")

    # ── Layer 4 — Load URL registry ──────────────────────────────────────────
    registry = link_resolver.load_registry(str(ctx["registry_path"]))

    # ── Layer 6 — Assemble (route FAQ hub to dedicated converter) ────────────
    is_faq = is_faq_hub_article
    if is_faq:
        html = faq_converter.convert(
            parsed_md=parsed,
            registry=registry,
            template_path=str(ctx["template_path"]),
            campaign_prefix=ctx["campaign_prefix"],
            article_slug=ctx["article_slug"],
            accent_color=ctx["accent_color"],
        )
        _log(tag, f"Layer 6 (FAQ hub): assembled {len(html.encode())} bytes")
    else:
        html = assembler.assemble(
            parsed_md=parsed,
            selected_tickets=selected,
            registry=registry,
            template_path=str(ctx["template_path"]),
            campaign_prefix=ctx["campaign_prefix"],
            article_slug=ctx["article_slug"],
            accent_color=ctx["accent_color"],
        )
        _log(tag, f"Layer 6: assembled {len(html.encode())} bytes")

    # ── Layer 7 — Python validator ───────────────────────────────────────────
    ok, reasons, val_info = validator.validate(
        html, parsed, ctx["campaign_prefix"], ctx["article_slug"]
    )
    if not ok:
        _log(tag, f"Layer 7: FAILED ({len(reasons)} issues)")
        return _write_fail(tag, ctx, reasons)
    _log(tag, "Layer 7: Python validator passed")
    faq_total = val_info["faq_matched"] + len(val_info["faq_missing"])
    _log(tag, f"  FAQ coverage: {val_info['faq_matched']}/{faq_total} questions present")
    for q in val_info["faq_missing"]:
        _log(tag, f"  FAQ WARNING missing: '{q[:80]}'")
    tt = val_info["top_ticket_count"]
    if tt:
        _log(tag, f"  Top-tickets: {val_info['top_ticket_with_top']}/{tt} have '-top' suffix")

    # ── Layer 7.5 — Claude verifier (with transient-failure retry) ───────────
    # For FAQ hub: verifier needs the aggregated Q&A as faq_items (MD has none)
    if is_faq:
        hub_faqs = []
        for sec in parsed.get("sections", []):
            hub_faqs.extend(faq_converter._extract_category_faqs(sec.get("content_md", "")))
        parsed_for_verify = {**parsed, "faq_items": hub_faqs, "_is_faq_hub": True}
    else:
        parsed_for_verify = parsed

    ver_ok, ver_issues = retry.run_with_retry(
        lambda: verifier.verify(html, parsed_for_verify, ctx["campaign_prefix"], ctx["article_slug"])
    )
    blockers = [i for i in ver_issues if i.get("severity") == "blocker"]
    warnings = [i for i in ver_issues if i.get("severity") != "blocker"]
    if warnings:
        for w in warnings:
            _log(tag, f"Layer 7.5 WARNING: {w.get('where','')} — {w.get('description','')}")
    if not ver_ok:
        _log(tag, f"Layer 7.5: FAILED ({len(blockers)} blockers)")
        return _write_fail(tag, ctx, [f"{i['where']}: {i['description']}" for i in blockers])
    _log(tag, f"Layer 7.5: Claude verifier passed (0 blockers, {len(warnings)} warnings)")

    # ── Layer 8 — Article meta sidecar (bullets/summary for L1 cards) ─────────
    try:
        tickets_md_slugs = article_meta.load_tickets_md_slugs(site_slug)
        article_meta.write_sidecar(out_path, parsed, ctx, tickets_md_slugs)
        _log(tag, "Layer 8: meta sidecar written")
    except Exception as exc:
        _log(tag, f"Layer 8 meta: skipped ({exc})")

    # ── Write to disk ─────────────────────────────────────────────────────────
    out_path.write_text(html, encoding="utf-8")
    _log(tag, f"Layer 6: wrote {out_path}")

    return {"status": "written", "path": str(out_path), "reasons": []}


def _write_fail(tag: str, ctx: dict, reasons: list) -> dict:
    fail_dir = Path(ctx["output_dir"]).parent.parent / "failed"
    fail_dir.mkdir(parents=True, exist_ok=True)
    fail_path = fail_dir / f"{ctx['article_slug']}.log"
    fail_path.write_text("\n".join(reasons), encoding="utf-8")
    _log(tag, f"Wrote failure log to {fail_path}")
    return {"status": "failed", "path": str(fail_path), "reasons": reasons}


def _log(tag: str, msg: str):
    print(f"{tag} {msg}", flush=True)


# ── CLI entry point ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Convert one MD article to HTML")
    p.add_argument("site_slug")
    p.add_argument("md_path")
    p.add_argument("--force", action="store_true", help="Re-convert even if output exists")
    args = p.parse_args()

    result = convert_article(args.md_path, args.site_slug, force=args.force)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["status"] in ("written", "skipped") else 1)
