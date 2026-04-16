# Phase 4 — Design

## Goal

Finalize the visual design system and section/component map for the site before generating content.
This is a configuration phase — decisions made here govern how GP Elements, GenerateBlocks templates,
and typography settings are applied across all pages.

## Inputs

| File | Description |
|---|---|
| `output/<site>/00-blueprint.md` | Blueprint — brand colors, fonts, logo |
| `output/<site>/01-architecture.md` | Architecture — page types and content templates |
| `.env` | Active site credentials with `WP_SITE_URL` pointing to the target site |

The WordPress site must already have Phase 1 complete (Steps 1–11 of `main.sh`) — GeneratePress,
GP Premium, GenerateBlocks, and all plugins installed and activated.

## Process

### 4a. Color palette

1. From the blueprint, extract the brand's primary color, secondary color, and accent.
2. In WordPress Admin → GeneratePress → Customize → Colors, set:
   - Background: from Step 7 (already done via `configure-colors.sh`)
   - Links: primary brand color
   - Buttons: primary brand color (background), white (text)
   - Headings: brand dark color or near-black

Or via WP-CLI (SSH):
```bash
ssh user@host "wp option update generate_settings '{...}' --path='/path/to/wp' --format=json"
```

### 4b. Typography review

The base font (Karla or configured `FONT_NAME`) was set in Step 8. Verify it renders correctly:
- Open the WP site in a browser, inspect the body font
- Check that heading sizes (H1=35px → H4=24px defaults) look proportionate
- Adjust via `.env` overrides and re-run `configure-typography.sh` if needed

### 4c. GenerateBlocks section templates

For each page type defined in the architecture (Homepage, Hub/Pillar, Standard Content, Comparison,
Blog, FAQ), plan the GenerateBlocks section structure:

| Page Type | Sections |
|---|---|
| Homepage | Hero, Quick CTA, 3-column category grid, Featured products, Trust block |
| Money/Hub | Page hero, TOC, Content blocks, CTA boxes, FAQ accordion |
| Supporting | Simple header, Content, Internal links sidebar, Related pages |
| Blog | Post header, Content, Author bio (GP Element), Related posts |
| FAQ | FAQ header, Q&A accordion blocks |

Document the section pattern for each template in a brief design spec — this is a reference for
content entry in Phase 5.

### 4d. Navigation

Navigation is **not** created by any Phase 1 script — it must be built manually in WP Admin:

1. Go to **Appearance → Menus → Create a new menu** named "Primary Menu"
2. Add 3 top-level items using the category labels from the blueprint (e.g. "Tickets & Tours", "Plan Your Visit", "What to See")
3. Add products marked "Show in Menu: Yes" from the blueprint as sub-items under Tickets & Tours
4. Add a custom link item for "Book Tickets" pointing to the Priority 1 product URL — this becomes the CTA button
5. Set Display Location: Primary Navigation
6. Save

If GP Premium's Menu Plus module is active (activated in Step 4), the header CTA button styling is available under **Appearance → GP Premium → Menu Plus**.

### 4e. GP Elements review

Verify the 4 GP Elements imported in Step 9 are active and rendering:
```bash
ssh user@host "wp post list --post_type=gp_elements --fields=post_name,post_status \
  --path='/path/to/wp' --format=table"
```
Expected: `google-analytics`, `author-profile`, `contained-width-for-all-post`, `stay22` — all `publish`.

## Outputs

This phase produces no files in `output/` — it results in configured WordPress state. Document
your design decisions here:

| Decision | Value |
|---|---|
| Primary color | `#______` |
| Secondary color | `#______` |
| Font name | ________ |
| Body font size | ____px |
| Logo width | ____px |
| H1 size | ____px |

Save a screenshot of the configured homepage as `output/<site>/04-design-preview.png` for reference.

## How to Run

Mostly WP Admin / manual review. For typography/color re-runs:

```bash
# Re-run typography with updated .env values:
./scripts/base/configure-typography.sh

# Re-run colors with updated .env:
./scripts/base/configure-colors.sh

# Re-run layout (container width, header):
./scripts/base/configure-layout.sh
```

## Validation

Before proceeding to Phase 5, verify:

1. **Site loads without errors** — open `WP_SITE_URL` in a browser, check console for JS errors.

2. **Typography renders** — body text is the configured font at the configured size.

3. **Navigation is correct** — 3 primary nav items, Book Tickets CTA visible.

4. **GP Elements active** — Google Analytics fires (check browser network tab for GA4 request),
   author profile renders on any post.

5. **Logo and favicon display** — verify in browser tab and header.

6. **Mobile responsive** — open DevTools, test at 375px width. Header collapses to hamburger.

7. **Search engine discouragement ON** — `Settings → Reading → Search Engine Visibility` should
   be checked (step 10). Uncheck this only when ready to launch.
