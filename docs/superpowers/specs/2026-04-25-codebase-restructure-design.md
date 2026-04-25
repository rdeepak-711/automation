# Design: Codebase Restructure + main.sh Redesign

**Date:** 2026-04-25
**Status:** Approved

---

## Goal

Restructure the auto-create-site codebase for clarity and maintainability: clean folder names, remove obsolete scripts, split main.sh into focused interactive phase scripts, and fix four bugs in the publish pipeline.

---

## Part 1 — Directory Structure

### New layout

```
auto-create-site/
├── main.sh                        Thin menu → calls scripts/phases/<phase>.sh
│
├── scripts/
│   ├── phases/                    NEW — phase entry points
│   │   ├── common.sh              Shared: env load, step_done/mark_done, SSH, preflight
│   │   ├── wordpress.sh           Interactive: Steps 1–15 (WP install + config)
│   │   ├── content.sh             Interactive: Steps 16–23 (tickets, MD→HTML, L1, homepage)
│   │   ├── publish.sh             Interactive: Steps 24–26 (REST publish + cache + menu)
│   │   └── audit.sh               Thin wrapper → scripts/audit/audit.sh
│   │
│   ├── wordpress/                 RENAMED from scripts/base/ (numbered scripts removed)
│   │   ├── find-wp-path.sh
│   │   ├── cleanup.sh
│   │   ├── setup.sh
│   │   ├── activate-gp-premium.sh
│   │   ├── customize-appearance.sh
│   │   ├── configure-layout.sh
│   │   ├── configure-colors.sh
│   │   ├── configure-typography.sh
│   │   ├── configure-categories.sh
│   │   ├── configure-permalinks.sh
│   │   ├── configure-rank-math.sh
│   │   ├── configure-additional-css.sh
│   │   ├── configure-gp-menu-footer.py
│   │   ├── import-gp-elements.sh
│   │   ├── settings-indexing.sh
│   │   └── deploy-templates.sh   RENAMED from 10-deploy-templates.sh
│   │
│   ├── content/
│   │   ├── l1/                   NEW — L1 generators + assembler
│   │   │   ├── generate-plan-your-visit.sh   RENAMED from generate-l1-plan-your-visit.sh
│   │   │   ├── generate-tickets-tours.sh     RENAMED from generate-l1-tickets-tours.sh
│   │   │   ├── generate-what-to-see.sh       RENAMED from generate-l1-what-to-see.sh
│   │   │   ├── generate-homepage.sh          MOVED from scripts/content/
│   │   │   └── assembler/        RENAMED from l1_assembler/
│   │   │       ├── content_generator.py
│   │   │       ├── article_source.py
│   │   │       ├── tickets_tours.py
│   │   │       ├── plan_your_visit.py
│   │   │       ├── what_to_see.py
│   │   │       ├── homepage.py
│   │   │       ├── validator.py
│   │   │       └── verifier.py
│   │   │
│   │   ├── l2/                   MOVED from scripts/l2/
│   │   │   ├── convert_one.py
│   │   │   ├── batch.py
│   │   │   ├── md_parser.py
│   │   │   ├── prose_converter.py
│   │   │   ├── assembler.py
│   │   │   ├── faq_converter.py
│   │   │   ├── faq_generator.py
│   │   │   ├── link_resolver.py
│   │   │   ├── article_meta.py
│   │   │   ├── components.py
│   │   │   ├── template_parser.py
│   │   │   ├── validator.py
│   │   │   ├── verifier.py
│   │   │   ├── inventory.py
│   │   │   ├── top_tickets.py
│   │   │   ├── retry.py
│   │   │   └── convert-l2.sh
│   │   │
│   │   ├── standardize-xlsx.py
│   │   ├── build-url-registry.py
│   │   ├── build-article-metas.py
│   │   ├── docx-to-tickets.sh
│   │   ├── split-articles-to-silos.sh
│   │   ├── generate-configs.sh
│   │   ├── populate-tickets.sh
│   │   ├── batch-md-to-html.sh
│   │   ├── md-to-html.sh
│   │   ├── publish-to-wordpress.sh
│   │   └── validate-links.py
│   │
│   ├── post-launch/              NEW — moved from scripts/base/11-18-*
│   │   ├── propagate-images.sh               (was 11-propagate-images.sh)
│   │   ├── fix-l1-card-images.sh             (was 17-fix-l1-card-images.sh)
│   │   ├── fix-l1-card-images.py             (was 17-fix-l1-card-images.py)
│   │   ├── fix-card-links-and-images.sh      (was 18-fix-card-links-and-images.sh)
│   │   └── fix-card-links-and-images.py      (was 18-fix-card-links-and-images.py)
│   │
│   └── audit/                    UNCHANGED
│       ├── audit.sh
│       ├── capture.sh
│       ├── check.py
│       ├── check_local.py
│       ├── compare-local-vs-live.py
│       ├── report.py
│       ├── fix.sh
│       ├── spec.yaml
│       ├── WORKFLOW.md
│       └── lib/common.sh
│
├── templates/                    UNCHANGED
├── prompts/                      UNCHANGED
├── config/                       UNCHANGED
├── docs/                         UNCHANGED (loose scratch .md files deleted)
├── input/                        gitignored
├── output/                       gitignored
└── state/                        gitignored
```

### Files deleted (obsolete/superseded)

**From scripts/base/ (staying in post-launch, rest deleted):**
- `12-update-l1-card-images.sh` + `-fixed.sh` — superseded by 17/18
- `13-list-posts-by-category.sh` — one-off utility
- `14-interactive-card-image-mapper.sh` + `14-show-card-mappings.sh` — one-off utilities
- `15-precise-card-image-update.sh` + `-fixed.sh` — superseded by 17/18
- `16-replace-visitor-guide-images.sh` — one-off

**From scripts/content/ (superseded by new architecture):**
- `generate-l1-pages.sh` — replaced by individual `l1/generate-*.sh`
- `generate-l2-plan-your-visit.sh`, `generate-l2-tickets-and-tours.sh`, `generate-l2-what-to-see.sh` — replaced by `l2/` Python pipeline
- `fix-plan-your-visit-html.sh`, `fix-tickets-html.sh`, `fix-what-to-see-html.sh` — no longer needed
- `inject-cta.sh`, `inject-faqs.sh`, `fix-cta-buttons.py` — superseded
- `verify-html-vs-md.py` — superseded by `l2/verifier.py`

**Root-level scratch files deleted:**
- `fix_menu_v2.php`, `htmlpush.sh`, `"Run Each Step"`
- `todo.md`, `review.md`, `summary.md`, `server1-exploration.md`, `server2-exploration.md`

---

## Part 2 — main.sh Redesign

### main.sh (thin menu, ~50 lines)

Responsibilities:
1. Prompt site slug → load root `.env` → load `input/<slug>/.env`
2. Show phase menu (or accept `$1` argument)
3. `exec scripts/phases/<chosen>.sh` — inherits all exported env vars

```
./main.sh                  # interactive menu
./main.sh wordpress        # jump to wordpress phase
./main.sh content          # jump to content phase
./main.sh publish          # jump to publish phase
./main.sh audit            # jump to audit phase
```

### scripts/phases/common.sh

Sourced by every phase script. Provides:
- `load_env <site_slug>` — loads root `.env` then `input/<slug>/.env`
- `step_done <key>` / `mark_done <key>` — reads/writes `state/.setup-state-<hostname>`
- `prompt_step <num> <name> <desc> <key>` — interactive step prompt with skip-if-done logic
- `prompt_manual <msg> <key>` — manual confirmation step
- `_is_yes` / `_is_no` helpers
- `preflight_check` — validates required env vars
- `ssh_connect` — opens ControlMaster connection, sets `SSH_KEY_OPT`, exports `SSH_CONTROL_PATH`
- Trap: closes SSH ControlMaster on exit

### scripts/phases/wordpress.sh (Steps 0–15)

- Step 0: server selection + SSH ControlMaster + input checklist
- Step 1: split articles into silos
- Steps 2–15: WP setup (find-wp-path, cleanup, plugins, GP Premium, appearance, layout, colors, typography, GP elements, deploy templates, indexing, categories, Rank Math)
- All script paths updated to `scripts/wordpress/`

### scripts/phases/content.sh (Steps 16–23)

- Step 16: docx → tickets.md
- Step 17: generate site configs
- Step 18: populate tickets array
- Step 19: sample MD → HTML (1 per silo)
- Step 20: batch MD → HTML
- Step 21: build article metas
- Step 22: generate L1 pages (calls `l1/generate-*.sh` individually)
- Step 23: generate homepage
- All script paths updated to `scripts/content/l1/` and `scripts/content/`

### scripts/phases/publish.sh (Steps 24–26)

- Step 24: publish to WordPress (`publish-to-wordpress.sh`)
- Step 25: clear WP cache (SSH)
- Step 26: configure menu + footer GP elements (`configure-gp-menu-footer.py`) — **NEW STEP**
  - Fetches all live published posts by category
  - Generates dynamic dropdown menu HTML + footer HTML
  - Deploys as GP Elements via SSH (`generate_before_header` hook for menu, `generate_footer` for footer)
  - Must run AFTER publish so live posts exist

### scripts/phases/audit.sh

Thin wrapper — sources `common.sh` for env loading, then calls `scripts/audit/audit.sh`.

---

## Part 3 — publish-to-wordpress.sh Fixes

### Fix 1 — Fluent Form shortcode not rendering

**Problem:** `[fluentform id="1"]` inside a `<!-- wp:html -->` block is not processed — WordPress only fires shortcodes inside `<!-- wp:shortcode -->` blocks.

**Fix:** In the payload builder (both `publish_page` and `publish_utility_page`), after section-splitting, detect any block containing a `[fluentform ...]` shortcode and rewrap it as `<!-- wp:shortcode -->` instead of `<!-- wp:html -->`:

```python
WP_SHORTCODE_RE = re.compile(r'\[fluentform\b[^\]]*\]')

def wrap_blocks(parts):
    blocks = []
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if WP_SHORTCODE_RE.search(p):
            blocks.append('<!-- wp:shortcode -->\n' + p + '\n<!-- /wp:shortcode -->')
        else:
            blocks.append('<!-- wp:html -->\n' + p + '\n<!-- /wp:html -->')
    return '\n\n'.join(blocks)
```

Form ID is always `1` across all sites.

### Fix 2 — Templates have pre-baked block wrappers

**Problem:** Both `templates/about-us-template.html` and `templates/contact-us-template.html` have literal `<!-- wp:html -->` / `<!-- /wp:html -->` at the top and bottom. The publish script now owns block wrapping, so these create double-wrapping.

**Fix:** Remove the `<!-- wp:html -->` opening line and `<!-- /wp:html -->` closing line from both templates. Add SEO comment blocks at the top of each:

```html
<!-- SEO
title: About Us — {{SITE_NAME}} | {{HOSTNAME}}
description: Learn about {{SITE_NAME}} — your complete resource for {{ATTRACTION_NAME}} tickets, tours, and visitor tips.
canonical: {{SITE_URL}}/about-us/
-->
```

```html
<!-- SEO
title: Contact Us — {{SITE_NAME}} | {{HOSTNAME}}
description: Get in touch with the {{SITE_NAME}} team. Questions about {{ATTRACTION_NAME}} tickets, tours, or visiting?
canonical: {{SITE_URL}}/contact-us/
-->
```

### Fix 3 — Wrong GP meta keys + duplicate SSH call

**Problem:** `publish_utility_page` makes a second SSH call after `publish_page` that:
1. Uses wrong GP meta key names (`_generate_disable_title`, `_generate_disable_featured_image`) — underscore variant that doesn't work
2. Duplicates work already done by `apply_post_meta` (headline + featured image disable)

**Fix:** Remove the duplicate GP meta lines from `publish_utility_page`'s second SSH call. Keep only the noindex setting:

```bash
ssh ... "
  wp eval \"update_post_meta(${_PAGE_ID}, 'rank_math_robots', array('noindex'));\" --path='${WP_PATH}' 2>/dev/null
"
```

The correct headline/image disable keys (`_generate-disable-headline`, `_generate-disable-post-image`) are already applied correctly by `apply_post_meta` inside `publish_page`.

### Fix 4 — Entity conversion applies to utility pages

**Status:** Already fixed — `publish_utility_page` calls `publish_page` which runs the entity conversion. No extra work needed.

---

## Part 4 — configure-gp-menu-footer.py (Step 26)

Currently exists in `scripts/wordpress/` but is never called from `main.sh`.

**Wired as Step 26 in `scripts/phases/publish.sh`:**

```bash
if prompt_step 26 "Configure Menu + Footer GP Elements" \
    "Generates dynamic menu (all published articles) and footer, deploys as GP Elements via SSH." \
    "configure_menu_footer_done"; then
  python3 "$SCRIPT_DIR/scripts/wordpress/configure-gp-menu-footer.py" \
    --site-slug "$CONTENT_SITE_SLUG" \
    --wp-path "$WP_PATH"
  mark_done "configure_menu_footer_done"
fi
```

**Prerequisite:** Runs after Step 24 (publish) so articles exist on the live site.
**Idempotent:** Uses `upsert` PHP — safe to re-run, backs up previous content to `/tmp/`.

---

## Run Order After Restructure

```bash
./main.sh                          # pick: wordpress → content → publish
# or directly:
./main.sh wordpress                # Steps 0–15
./main.sh content                  # Steps 16–23
./main.sh publish                  # Steps 24–26
./main.sh audit                    # audit any live site
```

---

## CLAUDE.md Updates Required

- Update `Key Files` table: `scripts/base/` → `scripts/wordpress/`
- Update `How to Run It` section with new phase script paths
- Note that `scripts/content/l1/` and `scripts/content/l2/` are the new module homes

---

## Verification

1. `./main.sh wordpress amsterdam-canal-cruise` completes Steps 0–15 cleanly
2. `./main.sh content amsterdam-canal-cruise` completes Steps 16–23
3. `./main.sh publish amsterdam-canal-cruise` completes Steps 24–26, menu deploys correctly
4. Contact Us page on live site shows Fluent Form rendered (not blank)
5. About Us + Contact Us: RankMath title/description set, noindex applied, GP elements disabled (headline + featured image hidden)
6. No double `<!-- wp:html -->` wrappers in page source
7. Arrow characters `→` render correctly (not as `&rarr;` text)
8. `scripts/audit/audit.sh` still works via `./main.sh audit`
