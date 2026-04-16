# Auto Create Site

> **Platform:** Bluehost shared/VPS hosting only. WP-CLI auto-discovery and SSH paths are
> hardcoded to Bluehost's `/home1/<user>/public_html/website_*` structure. Other hosts
> require manual `WP_PATH` in `.env`.

Standalone WordPress base bootstrap for new sites built on GeneratePress + GP Premium.

This folder implements **Phase 1** (steps 1–11): cleanup, plugin/theme setup, GP Premium
activation, appearance/layout/colors/typography, GP Elements import, indexing settings, and
blueprint generation.

## Quick Start

```bash
cd auto-create-site
cp .env.example .env
# fill in credentials and site URL in .env
chmod +x main.sh scripts/base/*.sh scripts/content/generate-prompt0.sh
./main.sh
```

## Implemented Steps

`main.sh` runs these interactive steps with per-site state tracking (`state/.setup-state-<host>`).
Each step prompts to run, skip, or re-run. Already-completed steps are skipped by default.

| Step | Script | What it does |
|---|---|---|
| 1 | `find-wp-path.sh` | Scans server for WP installs; offers to write `WP_PATH` to `.env` |
| 2 | `cleanup.sh` | Removes all plugins (except Bluehost), all pages and posts |
| 3 | `setup.sh` | Installs GenerateBlocks, GP Premium, WP Rocket, Max Mega Menu, Fluent Forms, Rank Math Pro, GeneratePress theme |
| 4 | `activate-gp-premium.sh` | Stores license key + activates 7 GP Premium modules |
| 5 | `customize-appearance.sh` | Hides title/tagline, uploads logo and favicon |
| 6 | `configure-layout.sh` | Sets container width, header layout, sidebars, blog meta |
| 7 | `configure-colors.sh` | Sets body background color |
| 8 | `configure-typography.sh` | Adds font to GP Font Library + sets body/heading typography |
| 9 | `import-gp-elements.sh` | Imports GP Elements (Google Analytics, Author Profile, etc.) |
| 10 | `settings-indexing.sh` | Discourages search engines (dev mode) |
| 11 | `generate-prompt0.sh` | Generates `00-blueprint.md` from a `.docx` file via Claude CLI |

## Configuring Layout, Colors & Typography

All design defaults work out of the box. Override by uncommenting in `.env`:

```bash
# Layout
CONTAINER_WIDTH=1365    # px

# Colors
BODY_BG_COLOR=ffffff    # hex without #

# Typography
FONT_NAME=Karla
BODY_FONT_SIZE=18       # px
H1_FONT_SIZE=35         # px
# ... see .env.example for all vars
```

## Folder Structure

```text
auto-create-site/
├── main.sh
├── .env.example
├── scripts/
│   ├── base/           # Steps 1–10 (all implemented)
│   │   ├── typography-font-library.php   # PHP template (used by step 8)
│   │   └── typography-manager.php        # PHP template (used by step 8)
│   ├── content/        # Step 11 + scaffold for future phases
│   ├── architecture/   # Scaffold (Phase 2)
│   ├── pages-plan/     # Scaffold (Phase 3)
│   ├── design/         # Scaffold (Phase 4)
│   └── publish/        # Scaffold (Phase 5)
├── config/
├── prompts/playbook/   # Prompt templates (00–03)
├── plugins/            # Premium plugin ZIPs (gitignored)
├── input/              # Source materials (gitignored)
├── output/             # Generated artifacts (gitignored)
├── state/              # Per-site state files (gitignored)
└── docs/phases/        # Implementation docs for phases 2+
```

## Supporting Files Required

- **Premium plugin ZIPs** (Step 3) go in `plugins/`. Any version is picked automatically:
  - `generateblocks-pro-*.zip`
  - `gp-premium-*.zip`
  - `wp-rocket*.zip`
  - `seo-by-rank-math-pro.zip`
- **GP Elements XML** (Step 9) defaults to `input/gp-elements.xml`. Override with `GP_ELEMENTS_XML` in `.env`.

## Future Phases

See `docs/phases/*.md` for process docs on Phases 2–5 (architecture, pages plan, design, content & publish).

---

## Troubleshooting

**SSH hangs or asks for passphrase on step 3+**
Your SSH key requires a passphrase. Add it to ssh-agent before running:
```bash
ssh-add ~/.ssh/id_rsa
./main.sh
```
Or use a passphrase-free key. `main.sh` validates the key before starting.

**"Could not find a WordPress install" on step 1**
The auto-discovery scans Bluehost's `/home1/<user>/public_html/website_*/` pattern.
If your install is elsewhere, set `WP_PATH` manually in `.env`:
```bash
WP_PATH=/home1/yourusername/public_html/yoursite
```

**Plugin couldn't be deleted (step 2 warning)**
Some plugins fail REST API deletion due to uninstall hooks. Delete them manually:
WP Admin → Plugins → deactivate → delete.
Then re-run step 2 to verify the rest were removed.

**"wp eval returned unexpected output" or step exits with ERROR**
Re-run that specific step (main.sh will ask "Run again? y/N"). If it fails again,
check the full error output — common causes: WP_PATH wrong, GP Premium not installed
yet (step 4 requires step 3 first), or SSH connection dropped mid-operation.

**`claude --print` fails in step 11**
Claude CLI is not authenticated. Run:
```bash
claude auth login
```
Then re-run step 11.

**Partial run / picking up where you left off**
State is tracked per-site in `state/.setup-state-<hostname>`. Completed steps are
skipped by default. To re-run a specific step, answer `y` when prompted "Run again?".
To reset all state for a site, delete the state file:
```bash
rm state/.setup-state-yoursitehostname
```
