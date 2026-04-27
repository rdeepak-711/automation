# Audit & Fix Workflow

Single source of truth for running audits and fixing violations on any site.
All scripts live in `scripts/audit/`. All output goes to `output/audit/`.

---

## Overview

```
capture.sh → snapshot.json
                  ↓
check.py  ──┐
            ├── violations.merged.json
check_local.py ─┘
                  ↓
            report.py → report.md (printed to terminal)
                  ↓
            fix.sh (batch remediation per violation type)
```

| Script | Role |
|---|---|
| `capture.sh` | SSH → server, runs PHP, saves fat JSON snapshot |
| `check.py` | Snapshot vs spec → live violations JSON |
| `check_local.py` | Snapshot vs local files (XLSX manifest, images, etc.) |
| `audit.sh` | Orchestrator: capture + check + check_local + merge + report |
| `fix.sh` | Batch remediator: reads merged violations, fixes via WP-CLI over SSH |
| `report.py` | Reads merged violations, prints markdown summary with diff vs previous |
| `inject_subgroups.py` | Rebuilds GP Element menu HTML with subgroup labels |
| `spec.yaml` | Declarative expectations — single source of truth for what correct looks like |

---

## Supported Sites

| Hostname | WP Path |
|---|---|
| `topkapipalace-guide.com` | `/home1/dpskbcmy/public_html/website_topkapi` |
| `hagiasophia-guide.com` | `/home1/dpskbcmy/public_html/website_204db6f9` |
| `bluemosque-guide.com` | `/home1/dpskbcmy/public_html` |
| `montsaintmichel-guide.com` | `/home1/dpskbcmy/public_html/website_58b542cb` |
| `vangoghmuseum-guide.com` | `/home1/dpskbcmy/public_html/website_da6eadef` |
| `plitvicelakes-guide.com` | `/home1/dpskbcmy/public_html/website_plitvice` |
| `angkorwat-guide.com` | `/home1/dpskbcmy/public_html/website_angkorwat` |
| `pyramidsofgiza-guide.com` | `/home1/dpskbcmy/public_html/website_pyramids` |

---

## Step-by-Step: New Site or Full Re-Audit

### Step 1 — Capture snapshot

SSH into the server, runs a PHP script via WP-CLI, saves everything (posts, pages,
meta, GP elements, options, content) to a single JSON file.

```bash
cd scripts/audit
./capture.sh <hostname>
# e.g.
./capture.sh plitvicelakes-guide.com
```

Output: `output/audit/snapshots/<hostname>-<timestamp>.json`
Also updates symlink: `output/audit/snapshots/<hostname>-latest.json`

### Step 2 — Run full audit

Runs capture (optional) + both checkers + merges + prints report.

```bash
# Full pipeline (capture + check + report):
./audit.sh plitvicelakes-guide.com

# Skip capture, re-run checks on existing snapshot:
./audit.sh plitvicelakes-guide.com --no-capture

# Run all known sites:
./audit.sh --all
```

Output files:
- `output/audit/violations/<hostname>-<stamp>.json` — live check violations
- `output/audit/violations/<hostname>-<stamp>.local.json` — local file check violations
- `output/audit/violations/<hostname>-<stamp>.merged.json` — combined, sorted by severity

The terminal prints a formatted markdown report automatically.

### Step 3 — Read the report

The report prints to terminal after every audit run. To re-read:

```bash
python3 report.py <hostname>
# e.g.
python3 report.py plitvicelakes-guide.com
```

Report shows:
- Total violations by severity (critical / high / medium / low)
- Each violation: id, severity, message, whether fixable
- Diff vs previous audit (new violations, resolved violations)

### Step 4 — Fix violations (batch by batch)

`fix.sh` reads the latest merged violations JSON and applies fixes over SSH.
Run batches in order. Re-audit after each batch to confirm delta.

```bash
./fix.sh <hostname> --batch <N>     # run one batch
./fix.sh <hostname> --all           # run all batches with confirm prompts
./fix.sh <hostname> --batch <N> --dry-run   # preview without applying
```

---

## Fix Batches Reference

### Batch 1 — WP Options
**Violations fixed:** `option-value-generate_settings-nav_position_setting`, `option-value-generate_spacing_settings-content_top`

Sets two GeneratePress options to required values:
- `nav_position_setting = nav-none` (disables GP built-in nav — custom GP Element nav handles it)
- `content_top = 0` (removes default top padding on content area)

```bash
./fix.sh <hostname> --batch 1
# or
./fix.sh <hostname> --batch options
```

---

### Batch 1b — Menu CSS: Hide Native GP Header
**Violations fixed:** `menu-site-header-not-hidden`

**The problem:** Our custom nav is a GP Element injected at `generate_before_header`.
Without this fix, the native GP `.site-header` element still renders in the DOM
(even though it contains no visible content), adding 40–80px of blank space between
the nav and the page content on desktop.

**The fix:** Injects `.site-header, #site-navigation, #sticky-navigation, #mobile-header { display: none !important; opacity: 0; }` into the Menu GP Element's `<style>` block.

```bash
./fix.sh <hostname> --batch 1b
# or
./fix.sh <hostname> --batch menu-css
```

Verify: hard refresh the site. The blank gap between nav and hero should disappear.

---

### Batch 1c — Homepage Container Width
**Violations fixed:** `homepage-container-width-restricted`

**The problem:** Older homepage templates include a second `<style>` block that
overrides `.att-container` with aggressive percentage max-widths:

```css
@media (min-width: 1280px) { .att-container { max-width: 74% !important; } }
@media (min-width: 1024px) and (max-width: 1279px) { .att-container { max-width: 82% !important; } }
@media (min-width: 768px)  and (max-width: 1023px) { .att-container { max-width: 88% !important; } }
@media (max-width: 767px)  { .att-container { max-width: 94% !important; ... } }
```

On a ~1400px screen this caps content at ~1036px with large empty margins on both sides,
making the site look narrow compared to newer sites that span full width.

**The fix:** Replaces the restrictive block with:

```css
.att-container { max-width: 100% !important; }
@media (max-width: 767px)  { .att-container { padding-left: 16px !important; padding-right: 16px !important; } }
@media (min-width: 768px) and (max-width: 1023px) { .att-container { padding-left: 24px !important; padding-right: 24px !important; } }
```

Content now spans the full container width (1365px) matching the newer site standard.

```bash
./fix.sh <hostname> --batch 1c
# or
./fix.sh <hostname> --batch container-width
```

Verify: hard refresh the site. Hero section and all content should stretch edge-to-edge like hagiasophia-guide.com.

---

### Batch 2 — Absolute Internal URLs
**Violations fixed:** `absolute-internal-links`

Strips `https://<hostname>/` → `/` across all post content.
Absolute internal links break staging environments and are flagged by Rank Math.

```bash
./fix.sh <hostname> --batch 2
# or
./fix.sh <hostname> --batch absolute-urls
```

---

### Batch 3 — Broken Internal Crosslinks
**Violations fixed:** `broken-internal-link`

Rebuilds in-content `<a href>` anchors using a rewrite map.
Matches broken slug segments to live published slugs via sub-token matching.
Example: `/plan-your-visit/opening-hours/` → `/plan-your-visit/topkapi-palace-opening-hours/`

```bash
./fix.sh <hostname> --batch 3
# or
./fix.sh <hostname> --batch broken-crosslinks
```

---

### Batch 4 — Padding Remnants
**Violations fixed:** `padding-24`

Strips `padding: 24px 0 0 0` from post content — leftover inline style from an
older content generation template.

```bash
./fix.sh <hostname> --batch 4
# or
./fix.sh <hostname> --batch padding
```

---

### Batch 5 — Manifest Reconciliation (preview only)
**Violations fixed:** `manifest-orphan`, `manifest-unpublished`

Diffs live post slugs against the XLSX content manifest. Generates a rename plan
and `.htaccess` redirect block. Does NOT apply automatically — outputs scripts for
manual review before running.

```bash
./fix.sh <hostname> --batch 5
# or
./fix.sh <hostname> --batch manifest
```

Review the output files, then run `--apply` when ready.

---

### Batch 6 — Featured Images
**Violations fixed:** `featured-image-missing`

Checks for missing featured images on posts and pages. If image files exist locally
under `input/<site-slug>/images/`, auto-uploads via `wp media import` and assigns
to the post. If files are missing, prints a checklist of what to upload.

```bash
./fix.sh <hostname> --batch 6
# or
./fix.sh <hostname> --batch images
```

Required local file layout:
```
input/<site-slug>/images/posts/<slug>.jpg
input/<site-slug>/images/pages/homepage.jpg
input/<site-slug>/images/pages/about-us.jpg
...
```

---

## Violation Severity Guide

| Severity | Meaning | Fix urgency |
|---|---|---|
| `critical` | Broken internal link — 404 in browser | Fix immediately |
| `high` | SEO meta missing, featured image absent, absolute URL, menu broken | Fix before launch |
| `medium` | Option wrong, subgroup count off, manifest mismatch | Fix soon |
| `low` | Minor padding remnant, extra subgroups | Nice to have |

---

## Menu Subgroup Injection

After publishing new articles, re-run the menu subgroup injector to keep the
desktop + mobile dropdowns organised into labelled sub-sections:

```bash
# Fetch current live menu HTML
ssh dpskbcmy@50.6.155.174 \
  "wp eval 'foreach(get_posts([\"post_type\"=>\"gp_elements\",\"numberposts\"=>-1]) as \$e){ if(\$e->post_title===\"Menu\"){ echo get_post_meta(\$e->ID,\"_generate_element_content\",true); break; } }' \
  --path=/home1/dpskbcmy/public_html/website_topkapi --skip-themes --skip-plugins" \
  > /tmp/live_menu.html

# Inject subgroups (reads input/<site>/tickets.md + menu_groupings.json)
python3 inject_subgroups.py --site topkapi-palace < /tmp/live_menu.html > /tmp/new_menu.html

# Deploy back to server
NEW_CONTENT=$(cat /tmp/new_menu.html)
ssh dpskbcmy@50.6.155.174 \
  "wp eval 'foreach(get_posts([\"post_type\"=>\"gp_elements\",\"numberposts\"=>-1]) as \$e){ if(\$e->post_title===\"Menu\"){ update_post_meta(\$e->ID,\"_generate_element_content\",\$_SERVER[\"MENU_HTML\"]); echo \"done\"; break; } }' \
  --path=/home1/dpskbcmy/public_html/website_topkapi --skip-themes --skip-plugins" \
  MENU_HTML="$NEW_CONTENT"
```

Sub-group definitions per site live in `input/<site-slug>/menu_groupings.json`.

---

## Audit Checks Reference

Every check is defined in `check.py` or `check_local.py` and driven by `spec.yaml`.

| Violation ID | Severity | Check | Fixable |
|---|---|---|---|
| `option-value-*` | medium | WP option != expected value | batch 1 |
| `menu-site-header-not-hidden` | high | `.site-header` hide rule absent from Menu CSS | batch 1b |
| `homepage-container-width-restricted` | high | `.att-container` has `74%` max-width override | batch 1c |
| `absolute-internal-links` | high | Post content has `https://<hostname>/` hrefs | batch 2 |
| `broken-internal-link` | critical | Internal href points to non-existent slug | batch 3 |
| `padding-24` | low | Post content contains `padding: 24px 0 0 0` | batch 4 |
| `manifest-unpublished` | high | Slug in XLSX manifest not published on site | batch 5 |
| `manifest-orphan` | medium | Live slug not in XLSX manifest | batch 5 |
| `featured-image-missing` | high/medium | Post or page has no featured image | batch 6 |
| `rank-math-title-missing` | high | `rank_math_title` meta empty | manual |
| `rank-math-description-missing` | high | `rank_math_description` meta empty | manual |
| `menu-element-missing` | high | GP Element "Menu" not found | re-run configure-gp-menu-footer.py |
| `menu-ticket-missing` | high | Ticket from tickets.md not in Buy Tickets dropdown | re-run inject_subgroups.py |
| `menu-subgroups-too-few` | medium | Article dropdown has fewer than 3 section labels (mobile) | inject_subgroups.py |
| `menu-subgroups-too-few-desktop` | medium | Article dropdown has fewer than 3 section labels (desktop) | inject_subgroups.py |
| `menu-buy-subgroups-too-few-desktop` | medium | Buy Tickets desktop dropdown has fewer than 2 section labels | inject_subgroups.py |
| `menu-book-now-missing` | high | No CTA button in menu | re-run configure-gp-menu-footer.py |

---

## Quick Reference — Common Commands

```bash
# Full audit (one site)
./audit.sh topkapipalace-guide.com

# Full audit (all sites)
./audit.sh --all

# Fix all batches with prompts
./fix.sh plitvicelakes-guide.com --all

# Fix specific violation type
./fix.sh plitvicelakes-guide.com --batch 1c   # container width
./fix.sh plitvicelakes-guide.com --batch 1b   # menu CSS gap
./fix.sh plitvicelakes-guide.com --batch 3    # broken links

# Dry run (preview without applying)
./fix.sh plitvicelakes-guide.com --batch 3 --dry-run

# Re-audit after fixes (no re-capture)
./audit.sh plitvicelakes-guide.com --no-capture
```
