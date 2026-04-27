#!/usr/bin/env bash
# Orchestrator: CAPTURE → CHECK (live + local) → merge → REPORT
# Usage:
#   ./audit.sh <hostname>              full pipeline
#   ./audit.sh <hostname> --no-capture skip SSH, re-run checks on latest snapshot
#   ./audit.sh --all                   run pipeline for every hostname in the map

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

ALL_HOSTS=(
  topkapipalace-guide.com
  bluemosque-guide.com
  hagiasophia-guide.com
  montsaintmichel-guide.com
  vangoghmuseum-guide.com
  plitvicelakes-guide.com
  angkorwat-guide.com
  pyramidsofgiza-guide.com
)

run_one() {
  local hostname="$1"
  local no_capture="${2:-0}"

  echo "" >&2
  echo "################################################################" >&2
  echo "# AUDIT: $hostname" >&2
  echo "################################################################" >&2

  local snap_dir="$OUTPUT_DIR/snapshots"
  local viol_dir="$OUTPUT_DIR/violations"
  mkdir -p "$snap_dir" "$viol_dir"

  # 1. Capture (unless --no-capture)
  if [[ "$no_capture" != "1" ]]; then
    "$HERE/capture.sh" "$hostname"
  else
    echo "--no-capture: skipping SSH snapshot" >&2
  fi

  # Resolve latest snapshot (follow symlink)
  local latest_link="$snap_dir/${hostname}-latest.json"
  if [[ ! -L "$latest_link" && ! -f "$latest_link" ]]; then
    echo "ERROR: no snapshot at $latest_link — run without --no-capture first" >&2
    return 1
  fi
  local snap_path
  snap_path="$(cd "$snap_dir" && readlink "${hostname}-latest.json" 2>/dev/null || echo "${hostname}-latest.json")"
  snap_path="$snap_dir/$snap_path"

  # Derive stamp for violation file naming (e.g. plitvicelakes-guide.com-20260418-123456.json)
  local snap_base
  snap_base="$(basename "$snap_path" .json)"
  local viol_live="$viol_dir/${snap_base}.json"
  local viol_local="$viol_dir/${snap_base}.local.json"
  local viol_merged="$viol_dir/${snap_base}.merged.json"

  # 2. Check live (snapshot vs spec)
  python3 "$HERE/check.py" "$snap_path" --out "$viol_live"

  # 3. Check local (snapshot vs local input/output files)
  python3 "$HERE/check_local.py" "$snap_path" --out "$viol_local"

  # 4. Merge the two violation files into one for reporting
  python3 - "$viol_live" "$viol_local" "$viol_merged" "$snap_path" "$hostname" <<'PYEOF'
import sys, json
live_p, local_p, out_p, snap_p, hostname = sys.argv[1:]
live  = json.load(open(live_p))
local = json.load(open(local_p))
violations = live['violations'] + local['violations']
order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
violations.sort(key=lambda x: (order.get(x['severity'], 9), x['category'], x['id']))
by_sev = {s: sum(1 for v in violations if v['severity']==s) for s in ['critical','high','medium','low']}
json.dump({
    'snapshot':    snap_p,
    'hostname':    hostname,
    'total':       len(violations),
    'by_severity': by_sev,
    'sources':     {'live': live_p, 'local': local_p},
    'violations':  violations,
}, open(out_p, 'w'), indent=2, ensure_ascii=False)
print(f"Merged violations: {out_p} (total {len(violations)})", file=sys.stderr)
PYEOF

  # 5. Point report.py at the merged file by temporarily making it the latest violations file
  # report.py globs for ${hostname}-*.json — merged file matches the pattern
  python3 "$HERE/report.py" "$hostname"

  echo "" >&2
  echo "DONE: $hostname" >&2
}

main() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <hostname> [--no-capture] | $0 --all [--no-capture]" >&2
    exit 1
  fi

  local no_capture=0
  local hosts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-capture) no_capture=1; shift ;;
      --all)        hosts=("${ALL_HOSTS[@]}"); shift ;;
      -*)           echo "Unknown flag: $1" >&2; exit 1 ;;
      *)            hosts+=("$1"); shift ;;
    esac
  done

  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "No hostname provided" >&2
    exit 1
  fi

  local failed=()
  for h in "${hosts[@]}"; do
    if ! run_one "$h" "$no_capture"; then
      failed+=("$h")
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "" >&2
    echo "FAILED hosts: ${failed[*]}" >&2
    exit 1
  fi
}

main "$@"
