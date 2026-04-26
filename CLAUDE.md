# Claude Code Context — auto-create-site

## What This Project Does

auto-create-site is a WordPress site bootstrapping automation tool for travel affiliate websites hosted on Bluehost. It runs 11 interactive steps using Bash scripts and Claude AI to set up WordPress sites with GeneratePress + GP Premium themes. Phase 1 (base setup) is fully automated; Phases 2–5 (content generation) are partially manual.

---

## How to Run It

```bash
# Start or resume site setup (interactive menu)
./main.sh

# Jump to a specific phase
./main.sh wordpress        # Steps 0–15: WP install + config
./main.sh content          # Steps 16–23: tickets, MD→HTML, L1, homepage
./main.sh publish          # Steps 24–26: REST publish + cache + menu
./main.sh audit            # Audit any live site
```

The script is interactive — it will pause and prompt you at key steps.

---

## Key Files

| File/Dir | Purpose |
|---|---|
| `main.sh` | Thin ~50-line phase-dispatch menu |
| `scripts/phases/` | Phase entry points: wordpress.sh, content.sh, publish.sh, audit.sh + common.sh |
| `scripts/wordpress/` | WordPress base setup scripts (find-wp-path, cleanup, setup, plugins, theme, layout, colors, typography, GP elements, indexing) |
| `scripts/content/` | Content generation via Claude AI (MD→HTML pipeline, publish, build-article-metas) |
| `scripts/content/l1/` | L1 page generators (generate-*.sh) and assembler Python modules |
| `scripts/content/l2/` | L2 article converters (batch MD→HTML pipeline) |
| `scripts/post-launch/` | Post-launch image and card fix scripts |
| `scripts/audit/` | Live site audit scripts |
| `input/` | Per-site input: tickets.md, .env, images, article markdown |
| `output/` | Generated content — gitignored, safe to delete |
| `state/` | Per-site completion tracking files (`.setup-state-<hostname>`) |
| `templates/` | HTML page templates and PHP templates for WordPress |

---

## Environment Variables

These should be set in your shell or a `.env` file sourced before running:

```bash
BLUEHOST_USER=<your_bluehost_username>     # SSH user for Bluehost
BLUEHOST_HOST=<your_bluehost_hostname>     # SSH host (often same as site hostname)
SSH_KEY_PATH=<path_to_private_key>         # Optional: SSH key if not default
WP_ADMIN_USER=<wp_admin_username>          # WordPress admin login
WP_ADMIN_PASS=<wp_admin_password>          # WordPress admin password
WP_ADMIN_EMAIL=<admin_email>               # WordPress admin email
GP_PREMIUM_KEY=<generatepress_license>     # GP Premium license key
AI_ENGINE=claude                           # AI engine: 'claude' or 'gemini'
```

Pre-flight credential validation runs before any destructive steps.

---

## How State Tracking Works

Each run creates/appends to `state/.setup-state-<hostname>`. Completed steps are written as single-line tokens (e.g., `step_1_complete`). On subsequent runs, `main.sh` reads this file and skips already-completed steps. This makes the script safely re-entrant.

**Caveat:** State is append-only with no atomic writes. If a step crashes mid-execution, the state file may not reflect the partial failure. Manual cleanup of the state file and WordPress state may be needed before retrying.

---

## Known Limitations and Gotchas

- **Bluehost-only**: Hardcodes `/home1/<user>/public_html/website_*/` path patterns. Will not work on other hosting providers without modification.
- **Manual Phases 2–3**: These content phases require copy-pasting prompts into Claude.ai manually. There is a deliberate break in automation here.
- **Pandoc auto-install**: The script attempts to auto-install Pandoc if missing; this is fragile and may fail silently on some systems.
- **No rollback**: If a step partially fails, there is no automatic rollback. You must manually clean up WordPress state before retrying.
- **Regex JSON parsing**: Claude AI output is parsed with regex, not a JSON parser. Malformed output can silently corrupt data.
- **SSH StrictHostKeyChecking**: Not explicitly configured — first-run SSH connections may hang waiting for host key confirmation.

---

## Architecture Notes for Claude

- SSH multiplexing (`ControlMaster`) is used across all scripts for efficiency. `common.sh`'s `ssh_connect` establishes the master socket; child scripts inherit it via `SSH_KEY_OPT`. Do not break this pattern.
- All scripts use `set -euo pipefail`. Any unhandled error exits immediately. Add explicit error handling for expected failure modes.
- The `scripts/wordpress/` scripts are designed to be idempotent — safe to re-run if state tracking is cleared. Maintain this property when modifying them.
- PHP templates are injected via WP-CLI and SSH — they are not loaded as standard WordPress plugins. Be careful editing template structure.
- The `AI_ENGINE` flag allows swapping between Claude (`claude --print`) and Gemini CLIs. Keep AI invocations behind this abstraction.
- State tracking uses `scripts/phases/common.sh`'s `step_done`/`mark_done` helpers against `state/.setup-state-<hostname>`.
