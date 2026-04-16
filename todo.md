# auto-create-site Todo — Priority Order (Highest → Lowest)

## P0 — Critical / Security

- [ ] **Fix `StrictHostKeyChecking=no` (or unset) in SSH calls**: Host key verification should never be disabled.
  - Use `StrictHostKeyChecking=yes` with a pre-populated `known_hosts` file
  - Or run `ssh-keyscan $HOST >> known_hosts` during initial setup and reference it
- [ ] **Fix unsafe string interpolation in SSH commands**: Variables inserted into SSH command strings without quoting create injection risks.
  - Quote all shell variables: `"${VARIABLE}"` everywhere
  - Audit every `ssh $HOST "..."` call for unquoted variable expansion
- [ ] **Add SSL certificate validation**: Some `curl` / `wget` calls skip cert verification (`-k` flag).
  - Remove all `-k` / `--insecure` flags
  - Ensure the execution environment has a valid CA bundle

## P1 — High / Reliability

- [ ] **Replace regex JSON parsing with `jq`**: Parsing JSON with `grep`/`sed`/`awk` is fragile and fails on multiline values or escaped characters.
  - Install `jq` check at script start: `command -v jq || { echo "jq required"; exit 1; }`
  - Replace all regex-based JSON extraction with `jq` queries
- [ ] **Fix non-atomic state file writes**: State is written non-atomically — a crash mid-write corrupts the state machine, requiring manual recovery.
  - Write state to a temp file first, then atomically rename: `mv "${STATE_FILE}.tmp" "${STATE_FILE}"`
- [ ] **Fix temp file cleanup with `trap`**: Temp files may not be cleaned up on error or interrupt.
  - Register cleanup at script top: `TMP=$(mktemp); trap "rm -f $TMP" EXIT`
  - Replace all `$$`-based temp names with `mktemp`
- [ ] **Check for Pandoc before use**: Pandoc auto-install is fragile (assumes `apt-get`, fails silently on macOS or non-Debian systems).
  - Add a pre-flight check: `command -v pandoc || { echo "Install pandoc: https://pandoc.org/installing.html"; exit 1; }`
  - Document Pandoc as a required dependency

## P2 — High / Correctness

- [ ] **Add output validation for Claude-generated content**: LLM output is used directly without validating format, length, or quality.
  - After each Claude call: check response is non-empty, meets minimum length, and matches expected structure
  - Re-prompt up to 2 times on invalid output before failing with a clear error

## P3 — Medium / Architecture

- [ ] **Make Bluehost-specific paths configurable**: Scripts have hardcoded Bluehost directory paths.
  - Extract all paths to a config section: `WP_ROOT`, `PUBLIC_HTML`, etc.
  - Add validation that these paths exist before starting
- [ ] **Add TSV column header validation**: TSV files are parsed without verifying column order — a reordered export breaks everything silently.
  - Read and validate the header row against expected column names before processing any data rows
- [ ] **Automate manual phases 2-3**: Currently require manual SSH intervention mid-run.
  - Document exactly what phases 2-3 do
  - Evaluate if they can be scripted (SSH commands, WP-CLI, REST API calls)
  - At minimum: add clear prompts explaining what the user must do manually before continuing

## P4 — Medium / Observability

- [ ] **Add structured audit logging**: No record of what was created, what failed, or what was skipped.
  - Log each major step to `logs/run-YYYYMMDD-HHMMSS.log`
  - Include timestamp, step name, status, and any error output

## P5 — Low / Housekeeping

- [ ] Create `.env.example` with all required environment variables.
- [ ] Add `--dry-run` flag to preview what will be created without executing.
- [ ] Document which steps are safe to re-run vs destructive.
- [ ] Add `--help` to the main script entry point.
