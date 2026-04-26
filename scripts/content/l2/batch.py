#!/usr/bin/env python3
"""
Layer 10 — Batch Runner

Discovers all MD articles under input/<site-slug>/<silo>/ and converts them
in parallel (default 4 workers). Writes a summary report on completion.

Usage:
    python3 -m scripts.l2.batch <site-slug> [--force] [--workers N] [--silo <silo>]
"""

import argparse
import glob
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
VALID_SILOS = ["tickets-tours", "plan-your-visit", "what-to-see"]


def run_batch(site_slug: str, force: bool = False, workers: int = 4,
              silo: str | None = None) -> dict:
    from .convert_one import convert_article

    silos = [silo] if silo else VALID_SILOS
    md_files = []
    for s in silos:
        pattern = str(REPO_ROOT / "input" / site_slug / s / "*.md")
        md_files.extend(sorted(glob.glob(pattern)))

    if not md_files:
        print(f"[batch] No MD files found for {site_slug}", file=sys.stderr)
        return {"converted": 0, "skipped": 0, "failed": 0, "failures": []}

    total = len(md_files)
    print(f"[batch] {site_slug}: {total} articles found", flush=True)

    results = {"converted": 0, "skipped": 0, "failed": 0, "failures": []}
    start = time.time()

    # Progress heartbeat thread
    import threading
    done_count = [0]
    stop_event = threading.Event()

    def heartbeat():
        while not stop_event.is_set():
            time.sleep(10)
            pct = int(done_count[0] / total * 100) if total else 0
            print(f"[batch] progress: {done_count[0]}/{total} ({pct}%)", flush=True)

    hb = threading.Thread(target=heartbeat, daemon=True)
    hb.start()

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(convert_article, md, site_slug, force): md
            for md in md_files
        }
        for fut in as_completed(futures):
            md = futures[fut]
            done_count[0] += 1
            try:
                res = fut.result()
            except Exception as e:
                res = {"status": "failed", "reasons": [str(e)], "path": None}

            if res["status"] == "written":
                results["converted"] += 1
            elif res["status"] == "skipped":
                results["skipped"] += 1
            else:
                results["failed"] += 1
                slug = Path(md).stem
                results["failures"].append({
                    "slug": slug,
                    "reasons": res.get("reasons", []),
                })

    stop_event.set()
    elapsed = time.time() - start

    _print_report(site_slug, results, elapsed)
    return results


def _print_report(site_slug: str, results: dict, elapsed: float):
    total = results["converted"] + results["skipped"] + results["failed"]
    mins, secs = divmod(int(elapsed), 60)
    sep = "═" * 44
    print(f"\n{sep}")
    print(f"  {site_slug} — L2 Article Conversion")
    print(sep)
    print(f"  Converted:  {results['converted']:>4} / {total}")
    print(f"  Skipped:    {results['skipped']:>4}")
    print(f"  Failed:     {results['failed']:>4}")
    if results["failures"]:
        for f in results["failures"]:
            reasons_str = "; ".join(f["reasons"][:2])
            print(f"    - {f['slug']:<40} {reasons_str[:60]}")
    print(f"  Elapsed:    {mins}m {secs:02d}s")
    print(sep + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Batch convert L2 MD articles to HTML")
    p.add_argument("site_slug")
    p.add_argument("--force", action="store_true")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--silo", choices=VALID_SILOS, default=None)
    args = p.parse_args()

    results = run_batch(args.site_slug, args.force, args.workers, args.silo)
    sys.exit(0 if results["failed"] == 0 else 1)
