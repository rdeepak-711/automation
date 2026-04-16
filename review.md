# auto-create-site — Code Review

---

## GOOD

**Solid state machine with re-entrant execution**
`main.sh` tracks completed steps in `state/.setup-state-<hostname>`, allowing interrupted runs to resume cleanly. This prevents costly re-execution of destructive steps like WordPress install and prevents duplicate plugin installations.

**SSH ControlMaster multiplexing**
Establishing a single SSH master connection in `main.sh` and reusing it across all child scripts is exactly the right approach for interactive provisioning. It eliminates per-command handshake overhead and avoids repeated authentication prompts.

**`set -euo pipefail` throughout**
All scripts fail loudly and immediately on errors, unset variables, or failed pipes. This catches silent failures that would otherwise leave the site in a half-configured state.

**PHP template separation for typography**
Keeping `typography-font-library.php` and `typography-manager.php` as discrete templates rather than inlining PHP in Bash strings is the correct call. It keeps the PHP readable, testable, and editable independently of the Bash orchestration.

**Credential pre-flight validation**
Credentials are validated before any destructive operations begin. This surfaces configuration errors early rather than failing midway through a multi-minute provisioning run.

**AI engine abstraction (`AI_ENGINE` flag)**
Wrapping AI invocations behind a switchable `AI_ENGINE=claude|gemini` flag is a clean design. It decouples the content pipeline from a specific CLI tool and enables substitution without touching core logic.

**Clear README and per-project documentation**
The project has a coherent README and a `CLAUDE.md` with context for AI-assisted development — a pattern that significantly reduces ramp-up time.

**Idempotent base scripts**
`scripts/base/` scripts are designed to be safe to re-run. This is essential for a tool that can resume mid-run.

---

## BAD

**Hardcoded Bluehost paths (`/home1/<user>/public_html/website_*/`)**
`scripts/base/find-wp-path.sh` and likely other base scripts hardcode Bluehost's specific filesystem layout. This makes the tool unusable on any other host — including Bluehost VPS plans that use a different directory structure — without manual edits. The path pattern should be configurable via an env var (e.g., `WP_BASE_PATH`).

**Manual Phases 2–3 break the automation contract**
The tool advertises as automation but requires the user to manually copy-paste prompts into Claude.ai and paste output back. This is an unresolved design gap. The same `claude --print` CLI used in other steps could automate this; the manual step appears to be a deferred implementation, not an intentional design choice.

**No structured output validation from Claude**
`scripts/content/generate-prompt0.sh` and downstream content scripts accept whatever Claude outputs and pass it along. If Claude returns a conversational response instead of the expected structured data, it silently corrupts the content pipeline. There is no schema check, word count check, or format assertion.

**Pandoc auto-install is fragile**
Auto-installing system dependencies (`pandoc`) inside a provisioning script is unreliable. It assumes package manager availability, sudo access, and network connectivity — none of which are guaranteed. It should either be a hard prerequisite check that exits early with an install instruction, or be removed in favor of a pure-Bash Markdown processor.

**No rollback on partial failure**
If `setup.sh` or `activate-gp-premium.sh` fails mid-execution (e.g., network drop during plugin download), the site is left in an inconsistent state. The state file won't record completion, but WordPress may have partial changes. There is no cleanup path. At minimum, failed steps should print explicit recovery instructions.

**Regex-based JSON parsing**
WordPress REST API responses and Claude output are parsed with `grep`/`sed` regex rather than `jq`. This is brittle — it breaks on whitespace changes, field reordering, or unexpected characters. `jq` is a single `brew install` away and should be a stated dependency.

---

## UGLY

**Unsafe string interpolation in SSH commands**
Variables are interpolated directly into SSH heredocs and remote command strings without escaping. A site hostname or username containing spaces, quotes, or special characters (e.g., `my site.com`) would cause unexpected command splitting or injection. All user-supplied variables passed into SSH remote execution should be shell-quoted with `printf '%q'` or passed as positional arguments.

**State file has no atomic writes**
Completion tokens are appended to `state/.setup-state-<hostname>` with a plain `echo >>`. If the script is killed between step execution and the append, the step runs again on next invocation. This is rarely a problem in practice but can cause double plugin activations or duplicate content. Writes should use a temp-file-and-rename pattern for atomicity.

**Temp file cleanup is inconsistent**
Some scripts create temp files in `/tmp` or `output/` and clean them up; others do not. On repeated runs, stale temp files can interfere with content generation by feeding old data to Claude. All temp files should be tracked and cleaned up in a `trap ... EXIT` handler.

**No SSL certificate validation in curl**
`curl` calls to the WordPress REST API likely use `-k` or omit validation, silently accepting invalid certs. This exposes the provisioning process to MITM attacks on the credentials being transmitted. SSL validation should be on by default; self-signed cert exceptions should be explicit and documented.

**SSH `StrictHostKeyChecking` not addressed**
No SSH config is set for `StrictHostKeyChecking`. On first run against a new host, SSH will hang waiting for the user to confirm the host key fingerprint. In an automated context this causes silent hangs. The SSH command should include `-o StrictHostKeyChecking=accept-new` (safer than `no`) on first connection, or the expected fingerprint should be pre-populated in `known_hosts`.

**No audit logging**
There is no persistent log of what commands were executed, what output was returned, or what errors occurred. When provisioning fails at step 7 of 11 on a site you set up three weeks ago, there is nothing to diagnose from. All SSH commands and their output should be appended to a per-site log file in `output/<hostname>/provision.log`.

**`config/*.tsv` column order is undocumented and fragile**
The TSV manifest format is implicitly relied upon by content scripts via positional `cut -f` column references. A column added in the wrong position silently breaks all downstream scripts. The format needs a header row and scripts should reference columns by name (via `awk -F'\t'` with a header map), not by position.

---

## IMPROVEMENTS

Prioritized from highest to lowest impact:

### P0 — Security

1. **Fix SSH string interpolation**: Audit every SSH command for unquoted variable interpolation. Use `printf '%q'` for all user-supplied values. This is a correctness and security issue.
2. **Enable SSL validation in curl**: Remove any `-k` flags. Add `--cacert` if operating on an internal CA. Failing open on TLS errors is unacceptable when transmitting WP credentials.
3. **Address SSH StrictHostKeyChecking**: Add `-o StrictHostKeyChecking=accept-new` to initial connections, or pre-populate `known_hosts` as part of setup docs.

### P1 — Reliability

4. **Replace regex JSON parsing with `jq`**: Add `jq` as a stated dependency in the README. Replace all `grep`/`sed` JSON parsing with `jq` expressions. This alone eliminates a class of silent content corruption bugs.
5. **Add `trap ... EXIT` for temp file cleanup**: Implement a global temp file registry and ensure cleanup runs on exit (clean or crash) in every script that creates temp files.
6. **Atomic state file writes**: Replace `echo >> state/...` with `tmp=$(mktemp); echo "token" > "$tmp"; mv "$tmp" state/...` to prevent double-execution on crash.

### P2 — Operability

7. **Add per-site audit log**: Redirect all SSH command output and Claude invocation results to `output/<hostname>/provision.log` with timestamps. This is essential for diagnosing failures.
8. **Validate Claude output structure**: After each `claude --print` invocation, run a format check (word count floor, expected JSON keys, absence of apology phrases) before passing output downstream. Exit with an error and the raw output on validation failure.
9. **Replace Pandoc auto-install with a hard prerequisite check**: At script start, check for `pandoc` (and `jq`) and exit with a clear install instruction if missing. Remove the auto-install logic.

### P3 — Portability and Maintainability

10. **Make Bluehost path configurable**: Move `/home1/<user>/public_html/website_*/` into a `WP_BASE_PATH` env var with the Bluehost value as default. Document clearly that this is Bluehost-specific.
11. **Document and enforce TSV manifest schema**: Add a header row to `config/*.tsv` files and update content scripts to reference columns by name. Add a manifest validation step before content generation begins.
12. **Automate Phases 2–3**: The `claude --print` CLI is already in use. The manual copy-paste phases should be automatable with the same pattern used in `generate-prompt0.sh`. This would complete the automation contract the tool implies.
