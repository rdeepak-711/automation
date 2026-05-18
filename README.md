# WordPress Site Automation Pipeline

> Scales WordPress site production from **5 → 30 sites/month** (1,200–1,800 pages/month). Reduces per-site build time from 4–10 days to a few hours.

Built for [Firestorm Internet](https://firestorm-internet.com). Powers the full content production pipeline across 40+ client sites.

---

## What It Does

A single pipeline run takes a blank WordPress install on Bluehost and produces a fully-configured, content-populated, publish-ready site — requiring only a final audit pass.

**11-step automation:**
1. WordPress path discovery + SSH connectivity check
2. Plugin/content cleanup
3. Plugin installation (GenerateBlocks, GP Premium, WP Rocket, etc.)
4. Premium license activation
5. Design customization (logo, favicon, colors, typography) via WP-CLI
6. Layout configuration
7. GP Elements import
8. Search engine indexing settings
9. AI-powered article generation over templates (Claude)
10. Image sourcing + interlinking
11. Publishing + blueprint generation

---

## Stack

- **Python** — orchestration, AI content generation, image pipeline
- **Bash / WP-CLI** — WordPress configuration, plugin management, theme setup
- **Claude CLI** — article generation over content templates
- **Platform:** Bluehost (SSH), WordPress + GeneratePress + GP Premium

---

## Impact

| Before | After |
|--------|-------|
| ~5 sites/month | ~30 sites/month |
| 4–10 days per site | A few hours per site |
| Manual theme config, plugin setup, content writing | Automated end-to-end |
| ~300 pages/month | 1,200–1,800 pages/month |

---

## Structure

```
/                        # Phase-based folders
├── base/               # Steps 1–10: install, configure, design
├── content/            # AI article generation pipeline
├── architecture/       # Site planning
├── page-planning/      # Page structure templates
├── design/             # Theme/color/typography config
└── publishing/         # Final publish + blueprint
```

---

## Requirements

- Bluehost hosting with SSH access
- WordPress installed at `/home1/<user>/public_html/website_*`
- WP-CLI available on server
- Claude CLI configured (`claude` in PATH)
- Python 3.8+

> **Note:** Directory structure is Bluehost-specific. Alternative hosts require manual path configuration in environment variables.

---

## Quick Start

```bash
# Set your site config
export SITE_PATH=/home1/youruser/public_html/website_yoursite
export SITE_URL=https://yoursite.com

# Run the full pipeline
bash base/run-all.sh

# Generate content
python content/generate.py
```
