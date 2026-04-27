#!/usr/bin/env python3
"""Layer 4: REPORT — markdown + diff vs previous snapshot.

Reads latest violations JSON, diffs vs previous, emits markdown report.
Usage: python3 report.py <hostname> [--out report.md]
"""
import sys, json, argparse
from pathlib import Path
from datetime import datetime

SEV_ORDER = ['critical', 'high', 'medium', 'low']
SEV_EMOJI = {'critical': '[CRIT]', 'high': '[HIGH]', 'medium': '[MED]', 'low': '[LOW]'}


def load_json(path):
    return json.load(open(path))


def find_violation_files(viol_dir, hostname):
    """Return sorted list of merged violation JSON paths for a hostname, newest last.

    Prefers `.merged.json` files (from audit.sh pipeline). Falls back to any
    `{hostname}-*.json` if no merged files present (standalone check.py usage).
    """
    merged = sorted(viol_dir.glob(f"{hostname}-*.merged.json"))
    if merged:
        return merged
    return sorted(
        p for p in viol_dir.glob(f"{hostname}-*.json")
        if not p.name.endswith('.local.json')
    )


def violation_key(v):
    """Stable identity for diffing: (id, target.type, target.slug|key|path|id)."""
    t = v.get('target', {})
    ttype = t.get('type', '?')
    tid = t.get('slug') or t.get('key') or t.get('path') or str(t.get('id', ''))
    return (v['id'], ttype, tid)


def diff_violations(prev, curr):
    """Return (new, resolved, unchanged) lists of violation dicts."""
    prev_map = {violation_key(v): v for v in prev}
    curr_map = {violation_key(v): v for v in curr}
    new       = [curr_map[k] for k in curr_map if k not in prev_map]
    resolved  = [prev_map[k] for k in prev_map if k not in curr_map]
    unchanged = [curr_map[k] for k in curr_map if k in prev_map]
    return new, resolved, unchanged


def group_by_severity(violations):
    out = {s: [] for s in SEV_ORDER}
    for v in violations:
        out.setdefault(v['severity'], []).append(v)
    return out


def fmt_violation(v):
    sev = SEV_EMOJI.get(v['severity'], v['severity'])
    t = v.get('target', {})
    target_str = ''
    if t.get('type') in ('post', 'page'):
        target_str = f" `{t.get('slug', '?')}` (id {t.get('id', '?')})"
    elif t.get('type') == 'option':
        target_str = f" option:`{t.get('key', '?')}`"
    elif t.get('type') == 'option_nested':
        target_str = f" option:`{t.get('path', '?')}`"
    elif t.get('type') == 'category':
        target_str = f" category:`{t.get('slug', '?')}`"
    fix = ' [fixable]' if v.get('fixable') else ''
    return f"- {sev} **{v['id']}**{target_str} — {v['message']}{fix}"


def build_report(hostname, viol_payload, snap, prev_payload=None):
    lines = []
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    lines.append(f"# Audit Report — {hostname}")
    lines.append(f"_{now}_")
    lines.append("")

    # Site stats
    s = snap['summary']
    lines.append("## Site Stats")
    lines.append(f"- Posts: {s['total_posts']} ({s['posts_missing_image']} missing image)")
    lines.append(f"- Pages: {s['total_pages']} ({s['pages_missing_image']} missing image)")
    lines.append(f"- Categories: {len(snap['categories'])}")
    lines.append(f"- GP Elements: {len(snap['gp_elements'])}")
    lines.append("")
    lines.append("### Posts by category")
    for c, n in sorted(s['posts_by_category'].items(), key=lambda x: -x[1]):
        lines.append(f"- `{c}`: {n}")
    lines.append("")

    # Diff vs previous
    curr_vs = viol_payload['violations']
    new_v, resolved_v, unchanged_v = [], [], curr_vs
    if prev_payload:
        prev_vs = prev_payload['violations']
        new_v, resolved_v, unchanged_v = diff_violations(prev_vs, curr_vs)
        lines.append("## Diff vs Previous Run")
        lines.append(f"- New (regressions): **{len(new_v)}**")
        lines.append(f"- Resolved: **{len(resolved_v)}**")
        lines.append(f"- Unchanged: {len(unchanged_v)}")
        lines.append("")
        if new_v:
            lines.append("### Regressions")
            for v in sorted(new_v, key=lambda x: (SEV_ORDER.index(x['severity']) if x['severity'] in SEV_ORDER else 9)):
                lines.append(fmt_violation(v))
            lines.append("")
        if resolved_v:
            lines.append("### Resolved since last run")
            for v in sorted(resolved_v, key=lambda x: (SEV_ORDER.index(x['severity']) if x['severity'] in SEV_ORDER else 9)):
                lines.append(fmt_violation(v))
            lines.append("")

    # Totals
    lines.append("## Violations Summary")
    lines.append(f"- Total: **{viol_payload['total']}**")
    for sev in SEV_ORDER:
        n = viol_payload['by_severity'].get(sev, 0)
        marker = '!!' if n > 0 and sev in ('critical', 'high') else ''
        lines.append(f"- {sev}: {n} {marker}".rstrip())
    lines.append("")

    # By severity
    grouped = group_by_severity(curr_vs)
    for sev in SEV_ORDER:
        bucket = grouped.get(sev, [])
        if not bucket:
            continue
        lines.append(f"## {sev.upper()} ({len(bucket)})")
        # Sub-group by category for readability
        by_cat = {}
        for v in bucket:
            by_cat.setdefault(v['category'], []).append(v)
        for cat, items in sorted(by_cat.items()):
            lines.append(f"### {cat} ({len(items)})")
            for v in items:
                lines.append(fmt_violation(v))
            lines.append("")

    # Footer
    lines.append("---")
    lines.append(f"Snapshot: `{viol_payload.get('snapshot', '?')}`")
    lines.append(f"Fixable violations: **{sum(1 for v in curr_vs if v.get('fixable'))}**")
    return '\n'.join(lines) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('hostname')
    ap.add_argument('--out', default=None)
    args = ap.parse_args()

    here = Path(__file__).parent
    root = here.parent.parent
    viol_dir = root / 'output' / 'audit' / 'violations'
    snap_dir = root / 'output' / 'audit' / 'snapshots'
    rep_dir  = root / 'output' / 'audit' / 'reports'
    rep_dir.mkdir(parents=True, exist_ok=True)

    viol_files = find_violation_files(viol_dir, args.hostname)
    if not viol_files:
        print(f"No violations files found for {args.hostname} in {viol_dir}", file=sys.stderr)
        sys.exit(1)

    latest_viol = viol_files[-1]
    prev_viol   = viol_files[-2] if len(viol_files) >= 2 else None

    viol_payload = load_json(latest_viol)
    prev_payload = load_json(prev_viol) if prev_viol else None

    # Load corresponding snapshot
    snap_path = viol_payload.get('snapshot')
    if not snap_path or not Path(snap_path).exists():
        snap_latest = snap_dir / f"{args.hostname}-latest.json"
        snap_path = str(snap_latest) if snap_latest.exists() else None
    if not snap_path:
        print("Cannot locate snapshot referenced by violations payload", file=sys.stderr)
        sys.exit(1)
    snap = load_json(snap_path)

    report = build_report(args.hostname, viol_payload, snap, prev_payload)

    out_path = Path(args.out) if args.out else (rep_dir / f"{latest_viol.stem}.md")
    with open(out_path, 'w') as f:
        f.write(report)

    print(f"Report: {out_path}", file=sys.stderr)
    # Also print short summary to stderr
    print(f"\nTotal violations: {viol_payload['total']}", file=sys.stderr)
    for sev in SEV_ORDER:
        n = viol_payload['by_severity'].get(sev, 0)
        marker = '!' if n > 0 else ' '
        print(f"  [{marker}] {sev:<9} {n}", file=sys.stderr)


if __name__ == '__main__':
    main()
