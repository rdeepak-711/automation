# auto-create-site — Project Summary

## Project Overview

auto-create-site automates the full lifecycle of spinning up WordPress travel affiliate sites on Bluehost. It handles everything from SSH path discovery and WordPress installation through plugin activation, GeneratePress theme configuration, and AI-assisted content generation. The tool is designed to be re-entrant: per-site state files track completed steps so interrupted runs can resume safely.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Orchestration | Bash/zsh (`main.sh`) |
| Remote execution | WP-CLI via SSH (ControlMaster multiplexing) |
| WordPress | GeneratePress + GP Premium |
| Typography injection | PHP templates via WP-CLI eval-file |
| Content generation | Claude AI (`claude --print`) or Gemini CLI |
| WordPress API | REST API + curl |
| Hosting | Bluehost shared/VPS (hardcoded paths) |
| Config format | TSV page manifests |

---

## Architecture Diagram

```
User
 |
 v
main.sh  ──────────────────────────────────────────────────────────
 |  state machine (steps 1-11)                                     |
 |  SSH ControlMaster established once                             |
 |                                                                  |
 +──> scripts/base/                     scripts/content/           |
 |     find-wp-path.sh                   generate-prompt0.sh       |
 |     cleanup.sh                        (architecture, briefs,    |
 |     setup.sh                           articles via Claude)     |
 |     activate-gp-premium.sh                                      |
 |     customize-appearance.sh          prompts/playbook/          |
 |     configure-layout.sh               00-blueprint              |
 |     configure-colors.sh               01-architecture           |
 |     configure-typography.sh           02-briefs                 |
 |     import-gp-elements.sh             03-articles               |
 |     settings-indexing.sh              05-page-builder           |
 |                                                                  |
 +──> config/<hostname>.tsv  (page manifest)                       |
 |                                                                  |
 +──> state/.setup-state-<hostname>  (completion tokens)           |
 |                                                                  |
 +──> output/  (generated content, gitignored)                     |
 |                                                                  |
SSH tunnel ──> Bluehost ──> WP-CLI ──> WordPress DB/FS             |
                                                                   |
         [Phases 2-3: manual Claude.ai interaction required] ──────+
```

---

## File Structure (Key Files)

```
auto-create-site/
├── main.sh                          # Orchestrator — 11-step state machine
├── scripts/
│   ├── base/
│   │   ├── find-wp-path.sh          # Discover WordPress install path on Bluehost
│   │   ├── cleanup.sh               # Remove default WP content
│   │   ├── setup.sh                 # Core WP config (title, permalink, settings)
│   │   ├── activate-gp-premium.sh   # Install and license GeneratePress Premium
│   │   ├── customize-appearance.sh  # Theme activation and appearance settings
│   │   ├── configure-layout.sh      # GeneratePress layout options
│   │   ├── configure-colors.sh      # Theme color palette
│   │   ├── configure-typography.sh  # Font injection via PHP templates
│   │   ├── import-gp-elements.sh    # GeneratePress header/footer elements
│   │   └── settings-indexing.sh     # Search engine visibility settings
│   └── content/
│       └── generate-prompt0.sh      # Blueprint extraction for content generation
├── prompts/playbook/
│   ├── 00-blueprint.md              # Site blueprint prompt
│   ├── 01-architecture.md           # Site architecture prompt
│   ├── 02-briefs.md                 # Page brief generation prompt
│   ├── 03-articles.md               # Article writing prompt
│   └── 05-page-builder.md           # Page builder assembly prompt
├── templates/
│   ├── typography-font-library.php  # PHP: font definitions for WP injection
│   └── typography-manager.php       # PHP: typography management logic
├── config/                          # Per-site TSV page manifests
├── state/                           # Per-site completion tracking
└── output/                          # Generated content (gitignored)
```

---

## Data Flow

```
1. User runs: ./main.sh <hostname>
2. main.sh validates credentials and establishes SSH ControlMaster
3. find-wp-path.sh discovers /home1/<user>/public_html/website_*/ path
4. Base setup scripts execute sequentially (steps 1-9):
   - WordPress core config → plugin setup → GeneratePress theme config
   - Colors, layout, typography (PHP templates injected via WP-CLI)
   - GP Elements imported, search indexing configured
5. [Manual break] Phases 2-3: user pastes prompts into Claude.ai,
   copies output back into output/ directory
6. Content scripts read config/<hostname>.tsv manifest
7. Claude AI (or Gemini) generates page briefs and articles
8. Output written to output/<hostname>/ directory
9. Pages published via WordPress REST API or WP-CLI
10. Each completed step appended to state/.setup-state-<hostname>
```

---

## Integration Points

| Integration | How | Notes |
|---|---|---|
| Bluehost SSH | ControlMaster multiplexing | Hardcoded `/home1/` path pattern |
| WP-CLI | Executed remotely over SSH | Used for all WP configuration |
| WordPress REST API | curl + JSON | Page creation and publishing |
| GeneratePress Premium | WP-CLI plugin install + license activation | Requires valid GP_PREMIUM_KEY |
| Claude AI | `claude --print` CLI subprocess | Switchable via AI_ENGINE env var |
| Gemini AI | Gemini CLI subprocess | Alternative to Claude via AI_ENGINE |
| PHP templates | `wp eval-file` over SSH | Typography injection, not a plugin |
