# Post-Publish Audit Phase 1 — Design

> **For agentic workers:** Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** After a site is published, run a single script that (A) ensures menu, footer, about-us, and contact-us are present, and (B) syncs article featured images from WordPress into the L1 and homepage page content via WP-CLI over SSH.

**Architecture:** A new standalone script `scripts/audit/post-publish.sh` plus a Python helper `scripts/audit/post-publish-images.py`. The shell script handles presence checks and orchestration; the Python script handles HTML parsing and image URL replacement. Added as Step 27 in `scripts/phases/publish.sh`.

---

## Sub-task A — Presence Check + Remediate

Check four required items via WP-CLI over SSH. If any are absent, run the appropriate creation command.

### Items checked

| Item | WP-CLI check | Fix command |
|---|---|---|
| GP Element "Menu" | `wp post list --post_type=gp_elements --name=Menu --field=ID` | `python3 scripts/wordpress/configure-gp-menu-footer.py --site-slug <slug> --wp-path <WP_PATH>` |
| GP Element "Footer" | `wp post list --post_type=gp_elements --name=Footer --field=ID` | `python3 scripts/wordpress/configure-gp-menu-footer.py --site-slug <slug> --wp-path <WP_PATH>` |
| Page `about-us` | `wp post list --post_type=page --name=about-us --field=ID` | `scripts/content/publish-to-wordpress.sh <slug> --only about-us` |
| Page `contact-us` | `wp post list --post_type=page --name=contact-us --field=ID` | `scripts/content/publish-to-wordpress.sh <slug> --only contact-us` |

Both GP elements are checked first; if either is missing, `configure-gp-menu-footer.py` runs once (it creates both). About-us and contact-us are checked and fixed independently.

### Output

```
── Sub-task A: Presence check ──
  ✓ GP Element "Menu" present (id=42)
  ✗ GP Element "Footer" missing — running configure-gp-menu-footer.py...
  ✓ GP Element "Footer" created
  ✓ Page "about-us" present (id=18)
  ✗ Page "contact-us" missing — publishing from template...
  ✓ Page "contact-us" created
```

---

## Sub-task B — Card Image Sync

Replace the `data:image/gif;base64,` placeholder `src` on every article card inside the 4 WP pages (homepage + 3 L1 pages) with the post's actual WordPress featured image URL.

### Page-level hero images

The 4 pages each have a hero `<img class="att-hero__img">` (and on homepage a top billboard image). These come from `input/<site-slug>/page-images.json`:

```json
{
  "homepage":        "https://example.com/wp-content/uploads/homepage-hero.jpg",
  "tickets-tours":   "https://example.com/wp-content/uploads/tickets-hero.jpg",
  "plan-your-visit": "https://example.com/wp-content/uploads/pyv-hero.jpg",
  "what-to-see":     "https://example.com/wp-content/uploads/wts-hero.jpg"
}
```

If the file is absent or a key is missing, the script prompts interactively:
```
  Hero image URL for tickets-tours (leave blank to skip):
```

### Slug → featured image map

Built via a single WP-CLI PHP eval over SSH:

```php
$posts = get_posts(['post_type' => ['post','page'], 'numberposts' => -1, 'post_status' => 'any']);
$map = [];
foreach ($posts as $p) {
    $url = get_the_post_thumbnail_url($p->ID, 'full');
    if ($url) $map[$p->post_name] = $url;
}
echo json_encode($map);
```

Result: `{ "entry-ticket": "https://.../entry-ticket.jpg", ... }`

### Card matching

The Python helper (`post-publish-images.py`) does:

1. Fetch each of the 4 WP page contents via `wp post get <id> --field=post_content`
2. Parse HTML with `html.parser` (stdlib, no beautifulsoup dependency)
3. For every `<img>` whose `src` starts with `data:image/`:
   - Walk up the DOM tree to find the nearest ancestor `<a href>` within the same card container
   - Extract slug: last non-empty path segment of href (e.g. `/tickets/entry-ticket/` → `entry-ticket`)
   - If slug is in the map: replace `src` with map value, also update `srcset` if present
4. Replace hero `<img class="att-hero__img">` with the page-level URL from `page-images.json`
5. Push updated content: `wp post update <id> --post_content="$(cat /tmp/updated.html)" --path=<WP_PATH>`

### Card image classes covered

| Class | Page | Notes |
|---|---|---|
| `att-hero__img` | all 4 | page-level URL from `page-images.json` |
| `att-featured__img` | tickets-tours | featured ticket card; slug from `<a href>` sibling |
| `att-ticket__img` | tickets-tours | regular ticket card; slug from `<a href>` sibling |
| `att-article-card__img` | all 4 | article grid card; slug from `<h3><a href>` inside same card |
| `att-crosslink__img` | all 4 | cross-silo card at bottom; slug from `<a href>` sibling |
| `att-highlight__img` | what-to-see | WTS highlight card; slug from `<a href>` sibling |

If a slug is not found in the map (post has no featured image set), the placeholder is left in place and a warning is printed.

### Output

```
── Sub-task B: Card image sync ──
  ✓ Built image map: 47 posts with featured images
  ── homepage ──
    ✓ Hero image set
    ✓ 6 ticket cards updated
    ✓ 6 PYV cards updated
    ✓ 6 WTS cards updated
    ⚠ 1 card has no featured image: stonehenge-accessibility
  ── tickets-tours ──
    ✓ Hero image set
    ✓ 2 featured ticket cards updated
    ✓ 8 ticket cards updated
    ✓ 3 info/crosslink cards updated
  ...
```

---

## File Layout

| File | Role |
|---|---|
| `scripts/audit/post-publish.sh` | Orchestrator: env load, SSH setup, sub-task A + B dispatch |
| `scripts/audit/post-publish-images.py` | Python: fetches WP data, parses HTML, replaces img src, pushes content |
| `input/<site-slug>/page-images.json` | Hero image URLs for the 4 pages (user-supplied) |

### `post-publish.sh` interface

```bash
./scripts/audit/post-publish.sh <site-slug>             # run both sub-tasks
./scripts/audit/post-publish.sh <site-slug> --only presence
./scripts/audit/post-publish.sh <site-slug> --only images
./scripts/audit/post-publish.sh <site-slug> --dry-run    # print what would change, no writes
```

### Integration in `scripts/phases/publish.sh`

Added as **Step 27** after existing Step 26 (configure menu + footer GP elements):

```bash
# ── Step 27: Post-publish audit ──────────────────────────────────────────────
if prompt_step 27 "Post-publish audit" \
    "Ensures menu/footer/about-us/contact-us are present; syncs card images from WP featured images." \
    "post_publish_audit_done"; then
  "$REPO_ROOT/scripts/audit/post-publish.sh" "$CONTENT_SITE_SLUG"
  mark_done "post_publish_audit_done"
else
  echo "  Skipped."
fi
```

---

## Error Handling

- SSH unreachable: exit with clear message; no partial writes
- WP-CLI returns no posts: warn and skip image sync (don't wipe existing content)
- `page-images.json` missing key: prompt interactively; blank answer skips that hero
- `wp post update` fails: print error with post ID; continue to next page
- `--dry-run`: all WP-CLI write commands are printed but not executed

---

## Dependencies

- Same SSH credentials as publish phase (`WP_SSH_HOST`, `WP_SSH_USER`, `WP_SSH_KEY`, `WP_PATH`)
- Python 3 stdlib only (no new packages)
- WP-CLI available on the remote server (already required by existing scripts)
- `configure-gp-menu-footer.py` and `publish-to-wordpress.sh` already exist and work standalone
