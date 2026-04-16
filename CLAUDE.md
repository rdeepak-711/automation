# Claude Code Context — auto-create-site

## What This Project Does

auto-create-site is a WordPress site bootstrapping automation tool for travel affiliate websites hosted on Bluehost. It runs 11 interactive steps using Bash scripts and Claude AI to set up WordPress sites with GeneratePress + GP Premium themes. Phase 1 (base setup) is fully automated; Phases 2–5 (content generation) are partially manual.

---

## How to Run It

```bash
# Start or resume site setup
./main.sh <hostname>

# Example
./main.sh mysite.com

# Force re-run a specific step (edit state file first)
nano state/.setup-state-mysite.com
# Remove the relevant completed step line, then re-run main.sh
```

The script is interactive — it will pause and prompt you at key steps. Keep a terminal open and follow the prompts.

---

## Key Files

| File/Dir | Purpose |
|---|---|
| `main.sh` | 251-line orchestrator; runs steps 1–11 with state machine |
| `scripts/base/` | WordPress base setup scripts (path discovery, cleanup, WP install, plugins, theme, layout, colors, typography, GP elements, indexing) |
| `scripts/content/` | Content generation via Claude AI (blueprint extraction, site architecture, page briefs, article writing) |
| `prompts/playbook/` | 5 reusable Claude prompts: `00-blueprint` through `05-page-builder` |
| `config/` | Per-site TSV page manifests defining content structure |
| `output/` | Generated content — gitignored, safe to delete |
| `state/` | Per-site completion tracking files (`.setup-state-<hostname>`) |
| `templates/typography-font-library.php` | PHP template for font injection into WordPress |
| `templates/typography-manager.php` | PHP template for typography management |

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

- SSH multiplexing (`ControlMaster`) is used across all scripts for efficiency. The master socket is established in `main.sh` and reused by child scripts. Do not break this pattern.
- All scripts use `set -euo pipefail`. Any unhandled error exits immediately. Add explicit error handling for expected failure modes.
- The `scripts/base/` scripts are designed to be idempotent — safe to re-run if state tracking is cleared. Maintain this property when modifying them.
- PHP templates are injected via WP-CLI and SSH — they are not loaded as standard WordPress plugins. Be careful editing template structure.
- The `AI_ENGINE` flag allows swapping between Claude (`claude --print`) and Gemini CLIs. Keep AI invocations behind this abstraction.
- `config/*.tsv` manifests drive content architecture. Column order matters — changing it breaks downstream content scripts.
