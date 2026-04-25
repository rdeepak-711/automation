# Codebase Restructure + main.sh Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the auto-create-site repo into a clean directory layout, fix four publish-to-wordpress.sh bugs, split main.sh into focused phase scripts, and wire Step 26 (menu/footer deployment).

**Architecture:** Bugs fixed first (Tasks 1–2, standalone). Then directory moves (Tasks 3–8). Then new phase scripts (Tasks 9–14). Then main.sh rewrite + cleanup (Tasks 15–16). Every moved Python file gets its REPO_ROOT depth corrected. Every moved shell script gets its REPO_ROOT path corrected. `scripts/phases/common.sh` provides the shared helpers extracted from main.sh.

**Tech Stack:** Bash (zsh), Python 3, WordPress REST API, WP-CLI over SSH, GeneratePress Premium.

---

## Task 1: Fix publish-to-wordpress.sh — Fluent Form + utility page bugs

**Files:**
- Modify: `scripts/content/publish-to-wordpress.sh:299-310` (publish_page payload builder)
- Modify: `scripts/content/publish-to-wordpress.sh:418-432` (publish_silo payload builder)
- Modify: `scripts/content/publish-to-wordpress.sh:529-537` (publish_utility_page SSH block)

### Context
Three bugs in the publish pipeline:
1. `[fluentform id="1"]` inside `<!-- wp:html -->` is never processed — shortcodes only fire in `<!-- wp:shortcode -->` blocks.
2. `publish_utility_page`'s second SSH call uses wrong GP meta keys `_generate_disable_title` / `_generate_disable_featured_image` (underscores). Correct keys are `_generate-disable-headline` / `_generate-disable-post-image` (hyphens). But `apply_post_meta` (called from `publish_page`) already sets the correct hyphen-variant keys — so the underscore calls are both wrong AND redundant. Remove them.
3. The rank_math_title / rank_math_description / rank_math_robots lines in the second SSH block are correct and must be kept.

- [ ] **Step 1: Update the publish_page payload builder (lines ~299–310)**

Replace the existing inline Python block inside the `TMP_PAYLOAD` heredoc with a version that detects `[fluentform ...]` and wraps that block in `wp:shortcode` instead of `wp:html`:

Current code at line 299–310:
```python
import json, re, sys
html_file, title, slug, status = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
# Decode presentation entities so WP doesn't double-encode them
for ent, ch in [('&rarr;','→'),('&larr;','←'),('&mdash;','—'),('&ndash;','–'),('&middot;','·'),('&bull;','•'),('&hellip;','…'),('&times;','×')]:
    content = content.replace(ent, ch)
# Split at <section> boundaries — each section becomes its own editable wp:html block
parts = re.split(r'(?=<section\b)', content)
blocks = '\n\n'.join('<!-- wp:html -->\n' + p.strip() + '\n<!-- /wp:html -->' for p in parts if p.strip())
print(json.dumps({'title': title, 'slug': slug, 'content': blocks, 'status': status}))
```

Replace with:
```python
import json, re, sys
html_file, title, slug, status = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
for ent, ch in [('&rarr;','→'),('&larr;','←'),('&mdash;','—'),('&ndash;','–'),('&middot;','·'),('&bull;','•'),('&hellip;','…'),('&times;','×')]:
    content = content.replace(ent, ch)
WP_SHORTCODE_RE = re.compile(r'\[fluentform\b[^\]]*\]')
parts = re.split(r'(?=<section\b)', content)
out = []
for p in parts:
    p = p.strip()
    if not p:
        continue
    if WP_SHORTCODE_RE.search(p):
        out.append('<!-- wp:shortcode -->\n' + p + '\n<!-- /wp:shortcode -->')
    else:
        out.append('<!-- wp:html -->\n' + p + '\n<!-- /wp:html -->')
blocks = '\n\n'.join(out)
print(json.dumps({'title': title, 'slug': slug, 'content': blocks, 'status': status}))
```

- [ ] **Step 2: Update the publish_silo payload builder (lines ~418–432)**

Same change as Step 1 but in the `publish_silo` payload builder. Replace the inline Python with:
```python
import json, re, sys
html_file, title, slug, cat_id, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
content = open(html_file).read()
content = re.sub(r'<!--\s*SEO[\s\S]*?-->\s*', '', content, count=1).lstrip()
for ent, ch in [('&rarr;','→'),('&larr;','←'),('&mdash;','—'),('&ndash;','–'),('&middot;','·'),('&bull;','•'),('&hellip;','…'),('&times;','×')]:
    content = content.replace(ent, ch)
WP_SHORTCODE_RE = re.compile(r'\[fluentform\b[^\]]*\]')
parts = re.split(r'(?=<section\b)', content)
out = []
for p in parts:
    p = p.strip()
    if not p:
        continue
    if WP_SHORTCODE_RE.search(p):
        out.append('<!-- wp:shortcode -->\n' + p + '\n<!-- /wp:shortcode -->')
    else:
        out.append('<!-- wp:html -->\n' + p + '\n<!-- /wp:html -->')
blocks = '\n\n'.join(out)
payload = {'title': title, 'slug': slug, 'content': blocks, 'status': status}
if cat_id > 0:
    payload['categories'] = [cat_id]
print(json.dumps(payload))
```

- [ ] **Step 3: Fix publish_utility_page — remove wrong GP keys, keep rank_math meta**

The second SSH block in `publish_utility_page` (lines ~529–537) currently runs 5 WP-CLI commands. Remove the first two (`_generate_disable_title` and `_generate_disable_featured_image` — both wrong keys, already set correctly by `apply_post_meta`). Keep the rank_math ones.

Replace:
```bash
      ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
        wp post meta update ${_PAGE_ID} _generate_disable_title true --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} _generate_disable_featured_image true --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} rank_math_title \"\$(printf '%s' '${_rm_title_b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} rank_math_description \"\$(printf '%s' '${_rm_desc_b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null
        wp eval \"update_post_meta(${_PAGE_ID}, 'rank_math_robots', array('noindex'));\" --path='${WP_PATH}' 2>/dev/null
      " </dev/null 2>/dev/null && \
        echo "  ⚙ Utility meta set (id=${_PAGE_ID}): GP title/image disabled + noindex" || \
        echo "  ⚠ Could not set utility meta for id=${_PAGE_ID}"
```

With:
```bash
      ssh "${SSH_KEY_OPT[@]}" "${WP_SSH_USER}@${WP_SSH_HOST}" "
        wp post meta update ${_PAGE_ID} rank_math_title \"\$(printf '%s' '${_rm_title_b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null
        wp post meta update ${_PAGE_ID} rank_math_description \"\$(printf '%s' '${_rm_desc_b64}' | base64 -d)\" --path='${WP_PATH}' 2>/dev/null
        wp eval \"update_post_meta(${_PAGE_ID}, 'rank_math_robots', array('noindex'));\" --path='${WP_PATH}' 2>/dev/null
      " </dev/null 2>/dev/null && \
        echo "  ⚙ Utility meta set (id=${_PAGE_ID}): Rank Math title/desc + noindex" || \
        echo "  ⚠ Could not set utility meta for id=${_PAGE_ID}"
```

- [ ] **Step 4: Verify changes look correct**

```bash
grep -n "WP_SHORTCODE_RE\|wp:shortcode\|_generate_disable" scripts/content/publish-to-wordpress.sh
```
Expected:
- Two `WP_SHORTCODE_RE` lines (one per payload builder)
- Two `wp:shortcode` lines
- Zero `_generate_disable_title` or `_generate_disable_featured_image` lines

- [ ] **Step 5: Commit**

```bash
git add scripts/content/publish-to-wordpress.sh
git commit -m "fix(publish): fluent form shortcode block, remove wrong GP meta keys in utility pages"
```

---

## Task 2: Fix templates — remove pre-baked wp:html wrappers, add SEO comments

**Files:**
- Modify: `templates/contact-us-template.html` (lines 1 and 261)
- Modify: `templates/about-us-template.html` (line 1 and last line)

### Context
Both templates start with `<!-- wp:html -->` and end with `<!-- /wp:html -->`. The `publish_utility_page` flow calls `publish_page`, which now owns block-wrapping. These manual wrappers cause double-wrapping. Additionally, there's no SEO comment block at the top, so `publish_utility_page` must handle SEO inline (which it already does via the second SSH call — good). We just need to strip the manual wrappers.

- [ ] **Step 1: Remove manual wp:html wrapper from contact-us-template.html**

Delete line 1 (`<!-- wp:html -->`) and the last line (`<!-- /wp:html -->`).

Then add SEO comment block as the new first line:
```html
<!-- SEO
title: Contact Us — {{SITE_NAME}} Guide | {{HOSTNAME}}
description: Get in touch with the {{SITE_NAME}} Guide team. Questions about {{ATTRACTION_NAME}} tickets, tours, or visiting? We are here to help.
canonical: {{SITE_URL}}/contact-us/
-->
```

Note: `{{HOSTNAME}}` and `{{SITE_NAME}}` are not currently substituted by `publish_utility_page`'s `sed` call. The SEO comment is stripped by `publish_page` before publishing — it's only used by `parse_seo_comment` to set `SEO_TITLE`/`SEO_DESC` before wrapping. Verify that `parse_seo_comment` is called from `publish_utility_page`... it's not — `publish_utility_page` calls `publish_page` which calls `parse_seo_comment` on the file. So the template substitution with `{{SITE_NAME}}` must happen before `publish_page` reads it. Since `_RENDERED` already has `{{SITE_NAME}}` substituted (via the `sed` call at line ~499), and `_RENDERED` is written to `_TMP_HTML` before being passed to `publish_page`, the SEO comment in the template will have `{{SITE_NAME}}` replaced. This works.

However, `{{HOSTNAME}}` is not in the `sed` substitution list. Add it to the `sed` call in `publish_utility_page`:

In `publish_utility_page`, the sed command (line ~499) substitutes 4 vars. Add `{{HOSTNAME}}`:
```bash
  _RENDERED=$(sed \
    -e "s|{{SITE_URL}}|${_SITE_URL}|g" \
    -e "s|{{HOSTNAME}}|${_HOSTNAME}|g" \
    -e "s|{{SITE_NAME}}|${_SITE_NAME}|g" \
    -e "s|{{ATTRACTION_NAME}}|${_ATTRACTION_NAME}|g" \
    -e "s|{{ATTRACTION_SLUG}}|${_ATTRACTION_SLUG}|g" \
    "$TEMPLATE_FILE")
```

- [ ] **Step 2: Remove manual wp:html wrapper from about-us-template.html**

Delete line 1 (`<!-- wp:html -->`) and the last line (`<!-- /wp:html -->`).

Add SEO comment block as new first line:
```html
<!-- SEO
title: About Us — {{SITE_NAME}} Guide | {{HOSTNAME}}
description: Learn about {{SITE_NAME}} Guide — your complete resource for {{ATTRACTION_NAME}} tickets, tours, and visitor tips.
canonical: {{SITE_URL}}/about-us/
-->
```

- [ ] **Step 3: Verify**

```bash
head -5 templates/contact-us-template.html
tail -3 templates/contact-us-template.html
head -5 templates/about-us-template.html
tail -3 templates/about-us-template.html
```
Expected: First line is `<!-- SEO`, no `<!-- wp:html -->` or `<!-- /wp:html -->` at either end.

- [ ] **Step 4: Commit**

```bash
git add templates/contact-us-template.html templates/about-us-template.html scripts/content/publish-to-wordpress.sh
git commit -m "fix(templates): remove pre-baked wp:html wrappers, add SEO comments, wire HOSTNAME substitution"
```

---

## Task 3: Move scripts/base/ → scripts/wordpress/

**Files:**
- Create dir: `scripts/wordpress/`
- git mv all files (see list below)
- Rename: `10-deploy-templates.sh` → `deploy-templates.sh`
- Move `typography-font-library.php` and `typography-manager.php` to `scripts/wordpress/`

### Scripts to move (keeping, renamed where noted):

| Old path | New path |
|---|---|
| `scripts/base/find-wp-path.sh` | `scripts/wordpress/find-wp-path.sh` |
| `scripts/base/cleanup.sh` | `scripts/wordpress/cleanup.sh` |
| `scripts/base/setup.sh` | `scripts/wordpress/setup.sh` |
| `scripts/base/activate-gp-premium.sh` | `scripts/wordpress/activate-gp-premium.sh` |
| `scripts/base/customize-appearance.sh` | `scripts/wordpress/customize-appearance.sh` |
| `scripts/base/configure-layout.sh` | `scripts/wordpress/configure-layout.sh` |
| `scripts/base/configure-colors.sh` | `scripts/wordpress/configure-colors.sh` |
| `scripts/base/configure-typography.sh` | `scripts/wordpress/configure-typography.sh` |
| `scripts/base/configure-categories.sh` | `scripts/wordpress/configure-categories.sh` |
| `scripts/base/configure-permalinks.sh` | `scripts/wordpress/configure-permalinks.sh` |
| `scripts/base/configure-rank-math.sh` | `scripts/wordpress/configure-rank-math.sh` |
| `scripts/base/configure-additional-css.sh` | `scripts/wordpress/configure-additional-css.sh` |
| `scripts/base/configure-gp-menu-footer.py` | `scripts/wordpress/configure-gp-menu-footer.py` |
| `scripts/base/import-gp-elements.sh` | `scripts/wordpress/import-gp-elements.sh` |
| `scripts/base/settings-indexing.sh` | `scripts/wordpress/settings-indexing.sh` |
| `scripts/base/10-deploy-templates.sh` | `scripts/wordpress/deploy-templates.sh` |
| `scripts/base/create-utility-pages.sh` | `scripts/wordpress/create-utility-pages.sh` |
| `scripts/base/typography-font-library.php` | `scripts/wordpress/typography-font-library.php` |
| `scripts/base/typography-manager.php` | `scripts/wordpress/typography-manager.php` |

- [ ] **Step 1: Create directory and move files**

```bash
mkdir -p scripts/wordpress
git mv scripts/base/find-wp-path.sh scripts/wordpress/find-wp-path.sh
git mv scripts/base/cleanup.sh scripts/wordpress/cleanup.sh
git mv scripts/base/setup.sh scripts/wordpress/setup.sh
git mv scripts/base/activate-gp-premium.sh scripts/wordpress/activate-gp-premium.sh
git mv scripts/base/customize-appearance.sh scripts/wordpress/customize-appearance.sh
git mv scripts/base/configure-layout.sh scripts/wordpress/configure-layout.sh
git mv scripts/base/configure-colors.sh scripts/wordpress/configure-colors.sh
git mv scripts/base/configure-typography.sh scripts/wordpress/configure-typography.sh
git mv scripts/base/configure-categories.sh scripts/wordpress/configure-categories.sh
git mv scripts/base/configure-permalinks.sh scripts/wordpress/configure-permalinks.sh
git mv scripts/base/configure-rank-math.sh scripts/wordpress/configure-rank-math.sh
git mv scripts/base/configure-additional-css.sh scripts/wordpress/configure-additional-css.sh
git mv scripts/base/configure-gp-menu-footer.py scripts/wordpress/configure-gp-menu-footer.py
git mv scripts/base/import-gp-elements.sh scripts/wordpress/import-gp-elements.sh
git mv scripts/base/settings-indexing.sh scripts/wordpress/settings-indexing.sh
git mv "scripts/base/10-deploy-templates.sh" scripts/wordpress/deploy-templates.sh
git mv scripts/base/create-utility-pages.sh scripts/wordpress/create-utility-pages.sh
git mv scripts/base/typography-font-library.php scripts/wordpress/typography-font-library.php
git mv scripts/base/typography-manager.php scripts/wordpress/typography-manager.php
```

- [ ] **Step 2: Check if any moved scripts self-reference scripts/base/**

```bash
grep -rn "scripts/base/" scripts/wordpress/ 2>/dev/null
```
Fix any hits by replacing `scripts/base/` with `scripts/wordpress/`. Typically none expected — these scripts don't call each other.

- [ ] **Step 3: Commit**

```bash
git add scripts/wordpress/ scripts/base/
git commit -m "refactor: move scripts/base/ to scripts/wordpress/, rename 10-deploy-templates.sh"
```

---

## Task 4: Move scripts/l2/ → scripts/content/l2/ + fix REPO_ROOT depth

**Files:**
- `scripts/l2/*.py` → `scripts/content/l2/*.py` — fix `parents[2]` → `parents[3]` in 4 files
- `scripts/l2/convert-l2.sh` → `scripts/content/l2/convert-l2.sh` — fix REPO_ROOT to 3 levels up
- `scripts/l2/__init__.py` → `scripts/content/l2/__init__.py`

### Context
Currently `scripts/l2/` is at depth 2 from repo root, so `parents[2]` is correct. After move to `scripts/content/l2/`, depth is 3, so `parents[3]` is needed. The 4 files to update: `audit.py`, `article_meta.py`, `batch.py`, `inventory.py`.

`convert-l2.sh` uses `REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"`. After moving to `scripts/content/l2/`, it needs `"$(cd "$SCRIPT_DIR/../../.." && pwd)"`.

- [ ] **Step 1: Move all l2 files**

```bash
git mv scripts/l2 scripts/content/l2
```

- [ ] **Step 2: Fix REPO_ROOT in audit.py**

```bash
# Current: REPO_ROOT = Path(__file__).resolve().parents[2]
sed -i '' 's/parents\[2\]/parents[3]/g' scripts/content/l2/audit.py
```
Also fix the hardcoded `parents[2]` inside `article_meta.py` at line ~129 (it's a local variable, not the module-level one):
```bash
grep -n "parents\[2\]" scripts/content/l2/audit.py scripts/content/l2/article_meta.py scripts/content/l2/batch.py scripts/content/l2/inventory.py
```
Fix all occurrences — replace every `parents[2]` with `parents[3]` in all four files.

- [ ] **Step 3: Fix REPO_ROOT in convert-l2.sh**

In `scripts/content/l2/convert-l2.sh`, line ~15:
```bash
# Change:
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# To:
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
```

Also update the usage comment at top of file:
```bash
# Change:
#   ./scripts/l2/convert-l2.sh <site-slug> ...
# To:
#   ./scripts/content/l2/convert-l2.sh <site-slug> ...
```

- [ ] **Step 4: Verify REPO_ROOT is correct**

```bash
cd scripts/content/l2 && python3 -c "from pathlib import Path; print(Path('batch.py').resolve().parents[3])"
```
Expected: prints the repo root path (the `auto-create-site` directory).

Actually run this test from the repo root:
```bash
python3 -c "
from pathlib import Path
p = Path('scripts/content/l2/batch.py').resolve()
print('parents[3]:', p.parents[3])
import os; print('repo root should be:', os.path.abspath('.'))
"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/content/l2/ scripts/l2/
git commit -m "refactor: move scripts/l2/ to scripts/content/l2/, fix REPO_ROOT depth parents[2]->parents[3]"
```

---

## Task 5: Move l1_assembler/ → scripts/content/l1/assembler/ + fix REPO_ROOT

**Files:**
- `scripts/content/l1_assembler/*.py` → `scripts/content/l1/assembler/*.py`
- `scripts/content/l1_assembler/__init__.py` → `scripts/content/l1/assembler/__init__.py`
- Create: `scripts/content/l1/__init__.py` (empty — needed for `python3 -m` invocations)
- Fix REPO_ROOT in `homepage.py`: 4 parents → 5 parents
- Fix `sys.path.insert` in `homepage.py`: path to assembler dir changes
- No other assembler `.py` files use absolute REPO_ROOT (they import via relative imports)

### Context
`scripts/content/l1_assembler/homepage.py` uses:
```python
REPO_ROOT = Path(__file__).parent.parent.parent.parent
```
After move to `scripts/content/l1/assembler/homepage.py`, needs one more parent:
```python
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
```
Same for `TEMPLATE_PATH` which is derived from `REPO_ROOT` — no separate change needed.

Also in `homepage.py` at line ~415:
```python
sys.path.insert(0, str(REPO_ROOT / "scripts" / "content" / "l1_assembler"))
```
Changes to:
```python
sys.path.insert(0, str(REPO_ROOT / "scripts" / "content" / "l1" / "assembler"))
```

- [ ] **Step 1: Create the l1/ directory and move l1_assembler/**

```bash
mkdir -p scripts/content/l1
git mv scripts/content/l1_assembler scripts/content/l1/assembler
```

- [ ] **Step 2: Create scripts/content/l1/__init__.py**

```bash
touch scripts/content/l1/__init__.py
git add scripts/content/l1/__init__.py
```

- [ ] **Step 3: Fix REPO_ROOT depth in homepage.py**

In `scripts/content/l1/assembler/homepage.py`, find and update:

Old (line ~32–33):
```python
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-homepage-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent
```

New:
```python
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-homepage-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
```

- [ ] **Step 4: Fix sys.path.insert in homepage.py**

In `scripts/content/l1/assembler/homepage.py`, find line ~415:
```python
sys.path.insert(0, str(REPO_ROOT / "scripts" / "content" / "l1_assembler"))
```

Replace with:
```python
sys.path.insert(0, str(REPO_ROOT / "scripts" / "content" / "l1" / "assembler"))
```

- [ ] **Step 5: Verify the REPO_ROOT resolves correctly**

From the repo root:
```bash
python3 -c "
from pathlib import Path
p = Path('scripts/content/l1/assembler/homepage.py').resolve()
repo_root = p.parent.parent.parent.parent.parent
import os
assert str(repo_root) == os.path.abspath('.'), f'Mismatch: {repo_root} vs {os.path.abspath(\".\")}'
print('REPO_ROOT OK:', repo_root)
"
```

- [ ] **Step 6: Commit**

```bash
git add scripts/content/l1/ scripts/content/l1_assembler/
git commit -m "refactor: move l1_assembler/ to scripts/content/l1/assembler/, fix REPO_ROOT depth"
```

---

## Task 6: Move l1 shell generators → scripts/content/l1/ + fix paths

**Files:**
- `scripts/content/generate-l1-plan-your-visit.sh` → `scripts/content/l1/generate-plan-your-visit.sh`
- `scripts/content/generate-l1-what-to-see.sh` → `scripts/content/l1/generate-what-to-see.sh`
- `scripts/content/generate-l1-tickets-tours.sh` → `scripts/content/l1/generate-tickets-tours.sh`
- `scripts/content/generate-homepage.sh` → `scripts/content/l1/generate-homepage.sh`

### Context
All 4 scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"` which resolves 2 levels up from `scripts/content/` to reach repo root. After moving to `scripts/content/l1/`, they need 3 levels up: `"$(cd "$(dirname "$0")/../../.." && pwd)"`.

The 3 `generate-l1-*.sh` scripts invoke Python modules:
- `python3 -m scripts.content.l1_assembler.plan_your_visit` → `python3 -m scripts.content.l1.assembler.plan_your_visit`
- `python3 -m scripts.content.l1_assembler.what_to_see` → `python3 -m scripts.content.l1.assembler.what_to_see`
- `python3 -m scripts.content.l1_assembler.tickets_tours` → `python3 -m scripts.content.l1.assembler.tickets_tours`

`generate-homepage.sh` calls `python3 "$REPO_ROOT/scripts/content/l1_assembler/homepage.py"` → `python3 "$REPO_ROOT/scripts/content/l1/assembler/homepage.py"`.

- [ ] **Step 1: Move the 4 shell scripts**

```bash
git mv scripts/content/generate-l1-plan-your-visit.sh scripts/content/l1/generate-plan-your-visit.sh
git mv scripts/content/generate-l1-what-to-see.sh scripts/content/l1/generate-what-to-see.sh
git mv scripts/content/generate-l1-tickets-tours.sh scripts/content/l1/generate-tickets-tours.sh
git mv scripts/content/generate-homepage.sh scripts/content/l1/generate-homepage.sh
```

- [ ] **Step 2: Fix REPO_ROOT in all 4 moved scripts**

In each of the 4 scripts, find and replace:
```bash
# Change (in all 4):
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# To:
SCRIPT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
```

Note: `generate-l1-tickets-tours.sh` uses `SCRIPT_DIR` differently (line 9: `python3 -m ...`). Check its actual REPO_ROOT line and update accordingly.

- [ ] **Step 3: Fix Python module paths in generate-plan-your-visit.sh**

```bash
# Change:
python3 -m scripts.content.l1_assembler.plan_your_visit "$SITE_SLUG" $FORCE
# To:
python3 -m scripts.content.l1.assembler.plan_your_visit "$SITE_SLUG" $FORCE
```

- [ ] **Step 4: Fix Python module paths in generate-what-to-see.sh**

```bash
# Change:
python3 -m scripts.content.l1_assembler.what_to_see "$SITE_SLUG" $FORCE
# To:
python3 -m scripts.content.l1.assembler.what_to_see "$SITE_SLUG" $FORCE
```

- [ ] **Step 5: Fix Python module paths in generate-tickets-tours.sh**

```bash
# Change:
python3 -m scripts.content.l1_assembler.tickets_tours "$SITE" "$@"
# To:
python3 -m scripts.content.l1.assembler.tickets_tours "$SITE" "$@"
```

- [ ] **Step 6: Fix Python path in generate-homepage.sh**

```bash
# Change:
python3 "$REPO_ROOT/scripts/content/l1_assembler/homepage.py" "$@"
# To:
python3 "$REPO_ROOT/scripts/content/l1/assembler/homepage.py" "$@"
```

- [ ] **Step 7: Verify all 4 scripts have correct REPO_ROOT and module paths**

```bash
grep -n "SCRIPT_DIR\|REPO_ROOT\|l1_assembler\|l1\.assembler" scripts/content/l1/*.sh
```
Expected: `../../..` in all SCRIPT_DIR lines, `l1.assembler` in module paths, no `l1_assembler`.

- [ ] **Step 8: Commit**

```bash
git add scripts/content/l1/ scripts/content/generate-l1-*.sh scripts/content/generate-homepage.sh
git commit -m "refactor: move l1 generators to scripts/content/l1/, fix REPO_ROOT depth and module paths"
```

---

## Task 7: Move post-launch scripts to scripts/post-launch/

**Files:**
- Create: `scripts/post-launch/`
- Move `scripts/base/11-propagate-images.sh` → `scripts/post-launch/propagate-images.sh`
- Move `scripts/base/17-fix-l1-card-images.sh` → `scripts/post-launch/fix-l1-card-images.sh`
- Move `scripts/base/17-fix-l1-card-images.py` → `scripts/post-launch/fix-l1-card-images.py`
- Move `scripts/base/18-fix-card-links-and-images.sh` → `scripts/post-launch/fix-card-links-and-images.sh`
- Move `scripts/base/18-fix-card-links-and-images.py` → `scripts/post-launch/fix-card-links-and-images.py`

- [ ] **Step 1: Create directory and move files**

```bash
mkdir -p scripts/post-launch
git mv scripts/base/11-propagate-images.sh scripts/post-launch/propagate-images.sh
git mv scripts/base/17-fix-l1-card-images.sh scripts/post-launch/fix-l1-card-images.sh
git mv scripts/base/17-fix-l1-card-images.py scripts/post-launch/fix-l1-card-images.py
git mv scripts/base/18-fix-card-links-and-images.sh scripts/post-launch/fix-card-links-and-images.sh
git mv scripts/base/18-fix-card-links-and-images.py scripts/post-launch/fix-card-links-and-images.py
```

- [ ] **Step 2: Fix any internal references in moved files**

These scripts may reference each other (e.g., the `.sh` calling its `.py` sibling). Check:
```bash
grep -n "17-fix\|18-fix\|scripts/base" scripts/post-launch/*.sh scripts/post-launch/*.py 2>/dev/null
```
If `fix-l1-card-images.sh` calls `./17-fix-l1-card-images.py`, update to `./fix-l1-card-images.py`.
If `fix-card-links-and-images.sh` calls `./18-fix-card-links-and-images.py`, update to `./fix-card-links-and-images.py`.

- [ ] **Step 3: Commit**

```bash
git add scripts/post-launch/ scripts/base/
git commit -m "refactor: move post-launch scripts (11, 17, 18) to scripts/post-launch/"
```

---

## Task 8: Delete obsolete scripts/base/ files

**Files:**
- Delete `scripts/base/12-update-l1-card-images.sh`
- Delete `scripts/base/12-update-l1-card-images-fixed.sh`
- Delete `scripts/base/13-list-posts-by-category.sh`
- Delete `scripts/base/14-interactive-card-image-mapper.sh`
- Delete `scripts/base/14-show-card-mappings.sh`
- Delete `scripts/base/15-precise-card-image-update.sh`
- Delete `scripts/base/15-precise-card-image-update-fixed.sh`
- Delete `scripts/base/16-replace-visitor-guide-images.sh`

And obsolete content scripts:
- Delete `scripts/content/generate-l1-pages.sh`
- Delete `scripts/content/generate-l2-plan-your-visit.sh`
- Delete `scripts/content/generate-l2-tickets-and-tours.sh`
- Delete `scripts/content/generate-l2-what-to-see.sh`
- Delete `scripts/content/fix-plan-your-visit-html.sh`
- Delete `scripts/content/fix-tickets-html.sh`
- Delete `scripts/content/fix-what-to-see-html.sh`
- Delete `scripts/content/inject-cta.sh`
- Delete `scripts/content/inject-faqs.sh`
- Delete `scripts/content/fix-cta-buttons.py`
- Delete `scripts/content/verify-html-vs-md.py`
- Delete `scripts/content/retry-failed.sh` (one-off utility)

- [ ] **Step 1: Delete obsolete base scripts**

```bash
git rm scripts/base/12-update-l1-card-images.sh \
       scripts/base/12-update-l1-card-images-fixed.sh \
       scripts/base/13-list-posts-by-category.sh \
       scripts/base/14-interactive-card-image-mapper.sh \
       scripts/base/14-show-card-mappings.sh \
       scripts/base/15-precise-card-image-update.sh \
       scripts/base/15-precise-card-image-update-fixed.sh \
       scripts/base/16-replace-visitor-guide-images.sh
```

- [ ] **Step 2: Delete obsolete content scripts**

```bash
git rm scripts/content/generate-l1-pages.sh \
       scripts/content/generate-l2-plan-your-visit.sh \
       scripts/content/generate-l2-tickets-and-tours.sh \
       scripts/content/generate-l2-what-to-see.sh \
       scripts/content/fix-plan-your-visit-html.sh \
       scripts/content/fix-what-to-see-html.sh \
       scripts/content/inject-cta.sh \
       scripts/content/inject-faqs.sh \
       scripts/content/fix-cta-buttons.py \
       scripts/content/verify-html-vs-md.py \
       scripts/content/retry-failed.sh
```

For `fix-tickets-html.sh`: check if it exists first:
```bash
ls scripts/content/fix-tickets-html.sh 2>/dev/null && git rm scripts/content/fix-tickets-html.sh || echo "not found, skipping"
```

- [ ] **Step 3: Verify scripts/base/ is now empty (should be removed)**

After Task 3 (wordpress move) and Task 7 (post-launch move) and this task, `scripts/base/` should be empty. Confirm and remove:
```bash
ls scripts/base/ 2>/dev/null && echo "NOT EMPTY — check above" || git rm -r scripts/base/ 2>/dev/null || rmdir scripts/base/ 2>/dev/null || true
```

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "refactor: delete obsolete scripts (base/12-16, generate-l2-*, fix-*-html.sh)"
```

---

## Task 9: Create scripts/phases/common.sh

**Files:**
- Create: `scripts/phases/common.sh`

### Context
Extracted from `main.sh`. Provides: `load_env`, `step_done`/`mark_done`, `prompt_step`, `prompt_manual`, `_is_yes`/`_is_no`, `preflight_check`, `ssh_connect`, SSH trap. All phase scripts source this file.

- [ ] **Step 1: Create scripts/phases/ directory and common.sh**

```bash
mkdir -p scripts/phases
```

Create `scripts/phases/common.sh`:

```bash
#!/usr/bin/env zsh
# common.sh — Shared helpers for all phase scripts.
# Source this file: source "$(dirname "$0")/common.sh"
set -euo pipefail

# Must be set by the sourcing script before sourcing this file:
#   PHASE_SCRIPT_DIR  — absolute path of the sourcing script's directory
#   REPO_ROOT         — repo root (typically: cd "$(dirname "$0")/../.." && pwd)

# ── Env loading ───────────────────────────────────────────────────────────────
load_env() {
  local site_slug="$1"
  local root_env="$REPO_ROOT/.env"
  local site_env="$REPO_ROOT/input/$site_slug/.env"
  [[ -f "$root_env" ]] && { set -a; source "$root_env"; set +a; }
  if [[ -f "$site_env" ]]; then
    set -a; source "$site_env"; set +a
    echo "  ✓ Loaded per-site config: input/$site_slug/.env"
  else
    echo ""
    echo "  No per-site .env found. Enter site-specific details:"
    mkdir -p "$REPO_ROOT/input/$site_slug"
    printf "  Site URL (e.g. https://hagiasophia-guide.com): "
    read -r _SITE_URL
    printf "  Campaign prefix (e.g. hagia-sophia, auschwitz, msm): "
    read -r _CAMPAIGN_PREFIX
    printf "  GA4 Measurement ID (e.g. G-XXXXXXXXXX): "
    read -r _GA4_ID
    printf "  Favicon URL (full URL to uploaded PNG): "
    read -r _FAVICON_URL
    cat > "$site_env" << SITEENV
WP_SITE_URL=${_SITE_URL}
CAMPAIGN_PREFIX=${_CAMPAIGN_PREFIX}
GA4_MEASUREMENT_ID=${_GA4_ID}
FAVICON_URL=${_FAVICON_URL}
logo_path=input/${site_slug}/images/logo.png
favicon_path=input/${site_slug}/images/favicon.png
SITEENV
    set -a; source "$site_env"; set +a
    echo "  ✓ Saved and loaded: input/$site_slug/.env"
  fi
}

# ── State tracking ────────────────────────────────────────────────────────────
# STATE_FILE must be exported before these are called.
step_done() { [[ -f "$STATE_FILE" ]] && grep -qF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { echo "$1" >> "$STATE_FILE"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
_is_yes() { [[ "$1" =~ ^([Yy]([Ee][Ss])?|1)$ ]]; }
_is_no()  { [[ "$1" =~ ^([Nn][Oo]?|0)$       ]]; }

prompt_step() {
  local num="$1" name="$2" desc="$3" key="$4"
  local reply
  echo ""
  echo "────────────────────────────────────────────────────────────────────────────"
  printf "  Step %s — %s\n" "$num" "$name"
  printf "  %s\n" "$desc"
  if step_done "$key"; then
    echo "  [already done — logged in $(basename "$STATE_FILE")]"
    printf "  Run again? (y/N): "
    read -r reply; reply="${reply:-N}"
  else
    printf "  Run this step? (Y/n): "
    read -r reply; reply="${reply:-Y}"
  fi
  _is_yes "$reply"
}

prompt_manual() {
  local msg="$1" key="$2"
  if step_done "$key"; then return 0; fi
  echo ""
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "  Manual — $msg"
  echo "────────────────────────────────────────────────────────────────────────────"
  local reply
  printf "  Done? (Y/n): "
  read -r reply; reply="${reply:-Y}"
  if _is_yes "$reply"; then
    mark_done "$key"
    echo "  ✓ Marked done."
  fi
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight_check() {
  local required_vars=(WP_SITE_URL WP_USER WP_PASS GA4_MEASUREMENT_ID GeneratePress_license_key)
  if [[ -z "${WP_SSH_HOST:-}" && -z "${WP_SSH_HOST2:-}" ]]; then
    echo "ERROR: No SSH server configured. Set WP_SSH_HOST or WP_SSH_HOST2 in .env."
    exit 1
  fi
  local missing=()
  for var in "${required_vars[@]}"; do
    [[ -n "${(P)var:-}" ]] || missing+=("$var")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required .env vars: ${missing[*]}"
    echo "  Fill in root .env and/or input/$CONTENT_SITE_SLUG/.env"
    exit 1
  fi
  echo "  ✓ Config validated"
}

_check_one_key() {
  local key_path="$1" label="$2"
  if [[ ! -f "$key_path" ]]; then
    echo "ERROR: SSH key not found at $key_path ($label)"; exit 1
  fi
  local perms
  perms=$(stat -f "%OLp" "$key_path" 2>/dev/null || stat -c "%a" "$key_path" 2>/dev/null || echo "unknown")
  if [[ "$perms" != "600" && "$perms" != "unknown" ]]; then
    echo "WARN: SSH key $key_path permissions are $perms — fix with: chmod 600 $key_path"
  fi
  if ! ssh-keygen -y -f "$key_path" < /dev/null >/dev/null 2>&1; then
    echo "ERROR: SSH key $key_path requires a passphrase. Run: ssh-add $key_path"; exit 1
  fi
  echo "  ✓ SSH key OK: $key_path"
}

# ── SSH ControlMaster ─────────────────────────────────────────────────────────
# After calling ssh_connect, SSH_KEY_OPT and SSH_CONTROL_PATH are exported.
ssh_connect() {
  export SSH_CONTROL_PATH="/tmp/wp-ssh-main-$$"
  ssh -i "$WP_SSH_KEY" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600 \
    -N -f "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null \
    && echo "  ✓ SSH multiplexed connection established" \
    || echo "  ⚠ SSH multiplexing failed — scripts will fall back to individual connections"
  export SSH_KEY_OPT="-i ${WP_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=${SSH_CONTROL_PATH}"
  trap '[[ -n "${SSH_CONTROL_PATH:-}" ]] && ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" "${WP_SSH_USER}@${WP_SSH_HOST}" 2>/dev/null; true' EXIT
}
```

- [ ] **Step 2: Verify syntax**

```bash
zsh -n scripts/phases/common.sh
```
Expected: no output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add scripts/phases/common.sh
git commit -m "feat(phases): add scripts/phases/common.sh with shared helpers"
```

---

## Task 10: Create scripts/phases/wordpress.sh (Steps 0–15)

**Files:**
- Create: `scripts/phases/wordpress.sh`

### Context
Extracts Steps 0–15 from `main.sh`. All script paths updated to `scripts/wordpress/`. Sources `common.sh`.

- [ ] **Step 1: Create scripts/phases/wordpress.sh**

Create `scripts/phases/wordpress.sh` with the following content. This is a refactored extract of main.sh Steps 0–15, with script paths changed from `scripts/base/` to `scripts/wordpress/`.

```bash
#!/usr/bin/env zsh
# wordpress.sh — Phase 1: WordPress setup (Steps 0–15)
# Called from main.sh or directly: ./scripts/phases/wordpress.sh
set -euo pipefail

PHASE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PHASE_SCRIPT_DIR/../.." && pwd)"
source "$PHASE_SCRIPT_DIR/common.sh"

# ── Site slug ─────────────────────────────────────────────────────────────────
CONTENT_SITE_SLUG="${CONTENT_SITE_SLUG:-}"
if [[ -z "$CONTENT_SITE_SLUG" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi

load_env "$CONTENT_SITE_SLUG"

SITE_HOST="${WP_SITE_URL:-default}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"
mkdir -p "$REPO_ROOT/state"
export STATE_FILE="$REPO_ROOT/state/.setup-state-${SITE_HOST}"

SITE_NOT_READY=false
for arg in "$@"; do
  [[ "$arg" == "--site-not-ready" ]] && SITE_NOT_READY=true
done

if [[ "$SITE_NOT_READY" == "false" ]]; then
  preflight_check
  [[ -n "${WP_SSH_HOST2:-}" ]] && _check_one_key "${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}" "WP_SSH_KEY2"
  [[ -n "${WP_SSH_HOST:-}" ]]  && _check_one_key "${WP_SSH_KEY:-$HOME/.ssh/id_rsa}" "WP_SSH_KEY"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
if [[ "$SITE_NOT_READY" == "true" ]]; then
  echo "  WordPress Phase — ${SITE_HOST} [CONTENT ONLY — no WP push]"
else
  echo "  WordPress Phase — ${SITE_HOST}"
fi
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 0: Site setup ────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Step 0 — Site Setup"
echo "────────────────────────────────────────────────────────────────────────────"

if [[ "$SITE_NOT_READY" == "false" ]]; then
  echo ""
  echo "  Which server is this site on?"
  printf "    [1] New server: %s@%s\n" "${WP_SSH_USER2:-?}" "${WP_SSH_HOST2:-?}"
  printf "    [2] Old server: %s@%s\n" "${WP_SSH_USER:-?}" "${WP_SSH_HOST:-?}"
  printf "  Enter 1 or 2: "
  read -r _SRV
  if [[ "$_SRV" == "2" ]]; then
    _ACTIVE_HOST="${WP_SSH_HOST}"; _ACTIVE_USER="${WP_SSH_USER}"; _ACTIVE_KEY="${WP_SSH_KEY:-$HOME/.ssh/id_rsa}"
    echo "  ✓ Using old server: ${_ACTIVE_USER}@${_ACTIVE_HOST}"
  else
    _ACTIVE_HOST="${WP_SSH_HOST2}"; _ACTIVE_USER="${WP_SSH_USER2}"; _ACTIVE_KEY="${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}"
    echo "  ✓ Using new server: ${_ACTIVE_USER}@${_ACTIVE_HOST}"
  fi
  export WP_SSH_HOST="$_ACTIVE_HOST" WP_SSH_USER="$_ACTIVE_USER" WP_SSH_KEY="$_ACTIVE_KEY"
  ssh_connect
fi

# 0b: Clear stale WP_PATH
if [[ -n "${WP_PATH:-}" ]]; then
  echo ""
  echo "  ⚠ WP_PATH is set to: $WP_PATH (may be from a previous site)"
  printf "  Unset and auto-discover? (Y/n): "
  read -r reply; reply="${reply:-Y}"
  if _is_yes "$reply"; then unset WP_PATH; echo "  ✓ WP_PATH unset."; fi
fi

# 0c: Input folder checklist
echo ""
echo "  Input folder checklist for: $CONTENT_SITE_SLUG"
_INPUT_DIR="$REPO_ROOT/input/$CONTENT_SITE_SLUG"
mkdir -p "$_INPUT_DIR/articles" "$_INPUT_DIR/images"
_check_item() {
  if ls $2 2>/dev/null | grep -q .; then
    printf "  ✓ %-30s %s\n" "$1" "$(ls $2 2>/dev/null | head -1 | xargs basename)"
  else
    printf "  ✗ %-30s MISSING\n" "$1"
  fi
}
_check_item "IA spreadsheet (*.xlsx)"  "$_INPUT_DIR/*.xlsx"
_check_item "tickets.docx or .md"      "$_INPUT_DIR/tickets.*"
_check_item "Article MD files"         "$_INPUT_DIR/articles/*.md"
_check_item "Logo"                     "$_INPUT_DIR/images/logo.png"
_check_item "Favicon"                  "$_INPUT_DIR/images/favicon.png"
echo ""
printf "  Place any missing files above, then press Enter to continue..."
read -r

if [[ "$SITE_NOT_READY" == "true" ]]; then
  echo "  [--site-not-ready] Skipping WordPress setup steps 2–15."
fi

# ── Step 1: Split Articles ────────────────────────────────────────────────────
if prompt_step 1 "Split Articles into Silo Folders" \
    "Moves MD files from articles/ into tickets-tours/, plan-your-visit/, what-to-see/ based on xlsx." \
    "split_articles_done"; then
  _MD_COUNT=$(ls "$_INPUT_DIR/articles/"*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$_MD_COUNT" -gt 0 ]]; then
    _XLSX=$(echo "$_INPUT_DIR"/*.xlsx | tr ' ' '\n' | grep -v '\.bak$' | head -1)
    if [[ -f "$_XLSX" ]]; then
      python3 "$REPO_ROOT/scripts/content/standardize-xlsx.py" "$_XLSX"
    fi
    python3 - "$_INPUT_DIR" << 'PYEOF'
import sys, os, re, glob, shutil, openpyxl

base = sys.argv[1]
xlsx_files = glob.glob(os.path.join(base, '*.xlsx'))
if not xlsx_files:
    print("  ✗ No xlsx found — place xlsx in input folder and re-run.")
    sys.exit(1)

wb = openpyxl.load_workbook(xlsx_files[0])
SILO_MAP = {
    'Tickets & Tours': 'tickets-tours', 'Tickets and Tours': 'tickets-tours',
    'tickets': 'tickets-tours', 'tickets-tours': 'tickets-tours',
    'Plan Your Visit': 'plan-your-visit', 'plan-your-visit': 'plan-your-visit',
    'What To See': 'what-to-see', 'What to See': 'what-to-see', 'what-to-see': 'what-to-see',
}

slug_to_silo = {}
silo_sheets = [s for s in wb.sheetnames if s in SILO_MAP]
if silo_sheets:
    for sheet_name in silo_sheets:
        silo_folder = SILO_MAP[sheet_name]
        ws = wb[sheet_name]
        for row in ws.iter_rows(values_only=True):
            slug_val = row[3] if len(row) > 3 else None
            if not slug_val or not str(slug_val).startswith('/'): continue
            leaf = str(slug_val).strip('/').split('/')[-1]
            if leaf: slug_to_silo[leaf] = silo_folder
else:
    ws = wb.worksheets[0]
    _current_silo = None
    for row in ws.iter_rows(min_row=2, values_only=True):
        col0 = str(row[0]).strip() if row[0] else ''
        if col0 and '\n' in col0:
            silo_name = col0.split('\n')[0].strip()
            _current_silo = SILO_MAP.get(silo_name)
        if not _current_silo:
            continue
        art_slug = str(row[3]).strip() if len(row) > 3 and row[3] else ''
        if not art_slug: continue
        art_slug = art_slug.strip('/').split('/')[-1]
        if art_slug:
            slug_to_silo[art_slug] = _current_silo

print(f"  Loaded {len(slug_to_silo)} slugs from xlsx")

moved, unmatched = 0, []
for md_path in sorted(glob.glob(os.path.join(base, 'articles', '*.md'))):
    fname = os.path.basename(md_path)
    name = os.path.splitext(fname)[0]
    slug = re.sub(r'^(?:article-?\d+[_-]|\d+[-_])', '', name)
    if slug in slug_to_silo:
        os.makedirs(os.path.join(base, slug_to_silo[slug]), exist_ok=True)
        shutil.move(md_path, os.path.join(base, slug_to_silo[slug], fname))
        print(f"  → {slug_to_silo[slug]}/{fname}")
        moved += 1
    else:
        unmatched.append(fname)

print(f"\n  ✓ Moved {moved} files")
if unmatched:
    print(f"  ⚠ {len(unmatched)} unmatched (left in articles/): {', '.join(unmatched)}")
PYEOF
    mark_done "split_articles_done"
  else
    echo "  No MD files in articles/ — nothing to split."
    mark_done "split_articles_done"
  fi
else
  echo "  Skipped."
fi

if [[ "$SITE_NOT_READY" == "false" ]]; then

# ── Steps 2–15 (WP setup) ─────────────────────────────────────────────────────
if prompt_step 2 "Find WP Path" \
    "Auto-discovers the WordPress install path on the server for this site." \
    "find_wp_path_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/find-wp-path.sh" "$@"
  _SITE_ENV_RELOAD="$REPO_ROOT/input/$CONTENT_SITE_SLUG/.env"
  [[ -f "$_SITE_ENV_RELOAD" ]] && { set -a; source "$_SITE_ENV_RELOAD"; set +a; }
  mark_done "find_wp_path_done"
else
  echo "  Skipped."
fi

if prompt_step 3 "Cleanup" \
    "Removes all plugins (except Bluehost), all pages and posts. Only for a fresh Bluehost site." \
    "cleanup_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/cleanup.sh" "$@"
  mark_done "cleanup_done"
else
  echo "  Skipped."
fi

if prompt_step 4 "Install Plugins & Theme" \
    "Installs GenerateBlocks, GP Premium, WP Rocket, Max Mega Menu, Fluent Forms, Rank Math Pro, and GeneratePress theme." \
    "setup_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/setup.sh" "$@"
  mark_done "setup_done"
else
  echo "  Skipped."
fi

if prompt_step 5 "Configure Permalinks" \
    "Sets permalink structure to /%category%/%postname%/ and flushes rewrite rules." \
    "configure_permalinks_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/configure-permalinks.sh"
  mark_done "configure_permalinks_done"
else
  echo "  Skipped."
fi

if prompt_step 6 "Activate GP Premium" \
    "Stores the license key and activates GP Premium modules via WP-CLI." \
    "gp_premium_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/activate-gp-premium.sh" "$@"
  mark_done "gp_premium_done"
else
  echo "  Skipped."
fi

if prompt_step 7 "Customize Appearance" \
    "Hides site title and tagline, uploads logo and favicon via WP-CLI." \
    "customize_appearance_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/customize-appearance.sh" --site-slug "$CONTENT_SITE_SLUG" "$@"
  mark_done "customize_appearance_done"
else
  echo "  Skipped."
fi

if prompt_step 8 "Configure Layout" \
    "Sets container width, header layout, mobile header, sidebar via WP-CLI." \
    "configure_layout_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/configure-layout.sh" "$@"
  mark_done "configure_layout_done"
else
  echo "  Skipped."
fi

if prompt_step 9 "Configure Colors" \
    "Sets GeneratePress theme colors via WP-CLI." \
    "configure_colors_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/configure-colors.sh" "$@"
  mark_done "configure_colors_done"
else
  echo "  Skipped."
fi

if prompt_step 10 "Configure Typography" \
    "Adds Karla font to GP Font Library via WP-CLI." \
    "configure_typography_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/configure-typography.sh" "$@"
  mark_done "configure_typography_done"
else
  echo "  Skipped."
fi

if prompt_step 11 "Import GP Elements" \
    "Imports GeneratePress Elements (Google Analytics, Author Profile, etc.) via WP-CLI." \
    "import_gp_elements_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/import-gp-elements.sh" --site-slug "$CONTENT_SITE_SLUG" "$@"
  mark_done "import_gp_elements_done"
else
  echo "  Skipped."
fi

if prompt_step 12 "Deploy Templates" \
    "Deploys footer and Author Box CSS with site-specific branding." \
    "deploy_templates_done"; then
  SITE_HOST_LOCAL="${WP_SITE_URL#https://}"
  SITE_HOST_LOCAL="${SITE_HOST_LOCAL#http://}"
  SITE_HOST_LOCAL="${SITE_HOST_LOCAL%%/*}"
  ATTRACTION_NAME=$(echo "$SITE_HOST_LOCAL" | sed 's/-guide\.com$//' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')
  case "$SITE_HOST_LOCAL" in
    *auschwitz*) ACCENT_COLOR="#ff0000" ;;
    *opera*) ACCENT_COLOR="#c4956c" ;;
    *) ACCENT_COLOR="#ff0000" ;;
  esac
  BLUEHOST_USER="$WP_SSH_USER" BLUEHOST_HOST="$WP_SSH_HOST" WP_SSH_KEY="$WP_SSH_KEY" \
    "$REPO_ROOT/scripts/wordpress/deploy-templates.sh" "$SITE_HOST_LOCAL" "$CONTENT_SITE_SLUG" "$ATTRACTION_NAME" "$ACCENT_COLOR"
  mark_done "deploy_templates_done"
else
  echo "  Skipped."
fi

if prompt_step 13 "Configure Indexing" \
    "Discourages search engine indexing while in development." \
    "settings_indexing_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/settings-indexing.sh" "$@"
  mark_done "settings_indexing_done"
else
  echo "  Skipped."
fi

if prompt_step 14 "Configure Categories" \
    "Creates 3 WordPress post categories (Tickets & Tours, Plan Your Visit, What to See)." \
    "configure_categories_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/configure-categories.sh" "$CONTENT_SITE_SLUG"
  mark_done "configure_categories_done"
else
  echo "  Skipped."
fi

if prompt_step 15 "Configure Rank Math" \
    "Activates Rank Math modules, sets title separator, enables XML sitemap." \
    "configure_rank_math_done"; then
  CONTENT_SITE_SLUG="$CONTENT_SITE_SLUG" WP_SSH_HOST="$WP_SSH_HOST" WP_SSH_USER="$WP_SSH_USER" WP_SSH_KEY="$WP_SSH_KEY" "$REPO_ROOT/scripts/wordpress/configure-rank-math.sh"
  mark_done "configure_rank_math_done"
else
  echo "  Skipped."
fi

prompt_manual "Go to WP Admin → Rank Math → Dashboard → Connect your account (activates Pro modules)." "rank_math_pro_connected_done"

fi # end SITE_NOT_READY block

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  WordPress phase complete — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"
```

- [ ] **Step 2: Make executable and verify syntax**

```bash
chmod +x scripts/phases/wordpress.sh
zsh -n scripts/phases/wordpress.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/phases/wordpress.sh
git commit -m "feat(phases): add scripts/phases/wordpress.sh (Steps 0-15)"
```

---

## Task 11: Create scripts/phases/content.sh (Steps 16–23)

**Files:**
- Create: `scripts/phases/content.sh`

- [ ] **Step 1: Create scripts/phases/content.sh**

```bash
#!/usr/bin/env zsh
# content.sh — Phase 2: Content generation (Steps 16–23)
# Called from main.sh or directly: ./scripts/phases/content.sh
set -euo pipefail

PHASE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PHASE_SCRIPT_DIR/../.." && pwd)"
source "$PHASE_SCRIPT_DIR/common.sh"

CONTENT_SITE_SLUG="${CONTENT_SITE_SLUG:-}"
if [[ -z "$CONTENT_SITE_SLUG" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi

load_env "$CONTENT_SITE_SLUG"

SITE_HOST="${WP_SITE_URL:-default}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"
mkdir -p "$REPO_ROOT/state"
export STATE_FILE="$REPO_ROOT/state/.setup-state-${SITE_HOST}"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Content Phase — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"

_INPUT_DIR="$REPO_ROOT/input/$CONTENT_SITE_SLUG"

# ── Step 16: Convert tickets.docx → tickets.md ───────────────────────────────
if [[ -f "$_INPUT_DIR/tickets.docx" && ! -f "$_INPUT_DIR/tickets.md" ]]; then
  if prompt_step 16 "Convert tickets.docx → tickets.md" \
      "Parses tickets.docx and generates the tickets.md file needed for config generation." \
      "docx_to_tickets_done"; then
    "$REPO_ROOT/scripts/content/docx-to-tickets.sh" "$CONTENT_SITE_SLUG"
    echo "  Review input/$CONTENT_SITE_SLUG/tickets.md before continuing."
    mark_done "docx_to_tickets_done"
  else
    echo "  Skipped."
  fi
elif [[ -f "$_INPUT_DIR/tickets.md" ]]; then
  echo "  ✓ tickets.md already exists — skipping docx conversion."
fi

# ── Step 17: Generate Site Configs ───────────────────────────────────────────
if prompt_step 17 "Generate Site Configs" \
    "Generates homepage-config.json and l1-config.json from tickets.md via Claude." \
    "generate_configs_done"; then
  if [[ ! -f "$_INPUT_DIR/tickets.md" ]]; then
    echo "  ERROR: input/$CONTENT_SITE_SLUG/tickets.md not found."; exit 1
  fi
  "$REPO_ROOT/scripts/content/generate-configs.sh" "$CONTENT_SITE_SLUG" && mark_done "generate_configs_done"
else
  echo "  Skipped."
fi

# ── Step 18: Populate Tickets Array ──────────────────────────────────────────
if prompt_step 18 "Populate Tickets Array" \
    "Parses tickets.md and populates the tickets[] array in homepage-config.json." \
    "populate_tickets_done"; then
  if [[ ! -f "$_INPUT_DIR/homepage-config.json" ]]; then
    echo "  ERROR: homepage-config.json not found. Run Step 17 first."; exit 1
  fi
  "$REPO_ROOT/scripts/content/populate-tickets.sh" "$CONTENT_SITE_SLUG" && mark_done "populate_tickets_done"
else
  echo "  Skipped."
fi

# ── Step 19: Sample MD to HTML (1 per silo) ──────────────────────────────────
if prompt_step 19 "Sample MD to HTML (1 per silo)" \
    "Converts 1 article from each silo to HTML for verification before full batch." \
    "md_to_html_sample_done"; then
  _PIDS=(); _LOGS=()
  for silo in tickets-tours plan-your-visit what-to-see; do
    _FIRST=$(ls "$_INPUT_DIR/$silo/"*.md 2>/dev/null | head -1)
    if [[ -z "$_FIRST" ]]; then echo "  ⚠ No articles in $silo — skipping"; continue; fi
    _LOG=$(mktemp /tmp/md-sample-XXXXXX)
    _LOGS+=("$silo:$_LOG")
    echo "  → $silo: $(basename "$_FIRST")"
    "$REPO_ROOT/scripts/content/md-to-html.sh" "$CONTENT_SITE_SLUG" "$_FIRST" --force > "$_LOG" 2>&1 &
    _PIDS+=($!)
  done
  _HB_START=$SECONDS
  ( while true; do sleep 5; printf "    ⏱  %ds elapsed\n" "$(( SECONDS - _HB_START ))" >&2; done ) &
  _HB_PID=$!
  _SAMPLE_OK=true
  for pid in "${_PIDS[@]}"; do wait "$pid" || _SAMPLE_OK=false; done
  kill "$_HB_PID" 2>/dev/null; wait "$_HB_PID" 2>/dev/null || true
  for entry in "${_LOGS[@]}"; do
    echo ""; echo "  ── ${entry%%:*} ──"; cat "${entry##*:}"; rm -f "${entry##*:}"
  done
  if $_SAMPLE_OK; then
    mark_done "md_to_html_sample_done"
    echo "  ✓ Samples generated. Review output/$CONTENT_SITE_SLUG/l2-articles/ before continuing."
  else
    echo "  ✗ Some samples failed — fix before proceeding."; exit 1
  fi
else
  echo "  Skipped."
fi

# ── Step 20: Convert All MD to HTML ──────────────────────────────────────────
if prompt_step 20 "Convert All MD to HTML" \
    "Converts all markdown articles to HTML using the article template." \
    "md_to_html_done"; then
  "$REPO_ROOT/scripts/content/batch-md-to-html.sh" "$CONTENT_SITE_SLUG" && mark_done "md_to_html_done"
else
  echo "  Skipped."
fi

# ── Step 21: Build Article Metas ─────────────────────────────────────────────
if prompt_step 21 "Build Article Metas" \
    "Auto-generates article descriptions, card titles, tags, and bullets via Claude." \
    "build_article_metas_done"; then
  python3 "$REPO_ROOT/scripts/content/build-article-metas.py" "$CONTENT_SITE_SLUG" && mark_done "build_article_metas_done"
  echo "  Review output/$CONTENT_SITE_SLUG/article-metas.json before building L1."
else
  echo "  Skipped."
fi

# ── Step 22: Generate L1 Pages ───────────────────────────────────────────────
if prompt_step 22 "Generate L1 Pages" \
    "Builds 3 L1 category hub pages (Tickets & Tours, Plan Your Visit, What to See)." \
    "generate_l1_html_done"; then
  "$REPO_ROOT/scripts/content/l1/generate-plan-your-visit.sh" "$CONTENT_SITE_SLUG" --force
  "$REPO_ROOT/scripts/content/l1/generate-what-to-see.sh" "$CONTENT_SITE_SLUG" --force
  "$REPO_ROOT/scripts/content/l1/generate-tickets-tours.sh" "$CONTENT_SITE_SLUG" --force
  mark_done "generate_l1_html_done"
else
  echo "  Skipped."
fi

# ── Step 23: Generate Homepage ───────────────────────────────────────────────
if prompt_step 23 "Generate Homepage" \
    "Generates the homepage with ticket cards, highlights, tips, and FAQ from tickets.md." \
    "generate_homepage_done"; then
  "$REPO_ROOT/scripts/content/l1/generate-homepage.sh" "$CONTENT_SITE_SLUG" --force && mark_done "generate_homepage_done"
else
  echo "  Skipped."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Content phase complete — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"
```

- [ ] **Step 2: Make executable and verify syntax**

```bash
chmod +x scripts/phases/content.sh
zsh -n scripts/phases/content.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/phases/content.sh
git commit -m "feat(phases): add scripts/phases/content.sh (Steps 16-23)"
```

---

## Task 12: Create scripts/phases/publish.sh (Steps 24–26)

**Files:**
- Create: `scripts/phases/publish.sh`

### Context
Steps 24–26. Step 26 is NEW — wires `configure-gp-menu-footer.py` which was never called from main.sh. Must run after Step 24 (publish) so articles exist on the live site.

- [ ] **Step 1: Create scripts/phases/publish.sh**

```bash
#!/usr/bin/env zsh
# publish.sh — Phase 3: Publish to WordPress (Steps 24–26)
# Called from main.sh or directly: ./scripts/phases/publish.sh
set -euo pipefail

PHASE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PHASE_SCRIPT_DIR/../.." && pwd)"
source "$PHASE_SCRIPT_DIR/common.sh"

CONTENT_SITE_SLUG="${CONTENT_SITE_SLUG:-}"
if [[ -z "$CONTENT_SITE_SLUG" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi

load_env "$CONTENT_SITE_SLUG"

SITE_HOST="${WP_SITE_URL:-default}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"
mkdir -p "$REPO_ROOT/state"
export STATE_FILE="$REPO_ROOT/state/.setup-state-${SITE_HOST}"

# Restore active SSH server if passed via env (from main.sh server selection)
if [[ -n "${WP_SSH_HOST:-}" ]]; then
  # Already set — respect it
  :
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Publish Phase — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Step 24: Publish to WordPress ────────────────────────────────────────────
if prompt_step 24 "Publish to WordPress" \
    "Publishes all generated HTML (L2 articles + L1 pages + homepage + About Us + Contact Us)." \
    "publish_wp_done"; then
  "$REPO_ROOT/scripts/content/publish-to-wordpress.sh" "$CONTENT_SITE_SLUG" --status publish
  mark_done "publish_wp_done"
else
  echo "  Skipped."
fi

# ── Step 25: Clear WP Cache ──────────────────────────────────────────────────
if prompt_step 25 "Clear WP Cache" \
    "Clears WP Rocket page cache and WP object cache via SSH after publishing." \
    "clear_cache_done"; then
  echo "  Clearing caches on ${WP_SSH_HOST}..."
  _WP_KEY="${WP_SSH_KEY/#\~/$HOME}"
  ssh -i "$_WP_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 "${WP_SSH_USER}@${WP_SSH_HOST}" bash << SSHEOF
wp cache flush --path="${WP_PATH}" 2>/dev/null && echo "  ✓ WP object cache flushed" || true
wp transient delete --all --path="${WP_PATH}" 2>/dev/null && echo "  ✓ Transients deleted" || true
wp rewrite flush --path="${WP_PATH}" 2>/dev/null && echo "  ✓ Rewrite rules flushed" || true
wp eval 'if(function_exists("rocket_clean_domain")){rocket_clean_domain(); echo "  ✓ WP Rocket domain cache purged\n";}
         if(function_exists("rocket_clean_minify")){rocket_clean_minify(); echo "  ✓ WP Rocket minified assets purged\n";}
         opcache_reset(); echo "  ✓ OPcache reset\n";' \
  --path="${WP_PATH}" 2>/dev/null || true
_COUNT=\$(find "${WP_PATH}/wp-content/cache/" -name "*.html" -o -name "*.html.gz" 2>/dev/null | wc -l | tr -d ' ')
find "${WP_PATH}/wp-content/cache/" -name "*.html" -delete 2>/dev/null || true
find "${WP_PATH}/wp-content/cache/" -name "*.html.gz" -delete 2>/dev/null || true
echo "  ✓ Deleted \${_COUNT} cached HTML files"
SSHEOF
  mark_done "clear_cache_done"
  echo "  ✓ Cache cleared"
else
  echo "  Skipped."
fi

# ── Step 26: Configure Menu + Footer GP Elements ─────────────────────────────
if prompt_step 26 "Configure Menu + Footer GP Elements" \
    "Generates dynamic menu (all published articles) and footer, deploys as GP Elements via SSH." \
    "configure_menu_footer_done"; then
  python3 "$REPO_ROOT/scripts/wordpress/configure-gp-menu-footer.py" \
    --site-slug "$CONTENT_SITE_SLUG" \
    --wp-path "${WP_PATH:-}"
  mark_done "configure_menu_footer_done"
else
  echo "  Skipped."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Publish phase complete — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"
```

- [ ] **Step 2: Make executable and verify syntax**

```bash
chmod +x scripts/phases/publish.sh
zsh -n scripts/phases/publish.sh
```

- [ ] **Step 3: Check configure-gp-menu-footer.py accepts --site-slug and --wp-path**

```bash
grep -n "argparse\|add_argument\|site.slug\|wp.path" scripts/wordpress/configure-gp-menu-footer.py | head -10
```
Confirm the Python script uses `argparse` with `--site-slug` and `--wp-path`. If the arg names differ, update the call in Step 26 to match.

- [ ] **Step 4: Commit**

```bash
git add scripts/phases/publish.sh
git commit -m "feat(phases): add scripts/phases/publish.sh (Steps 24-26), wire Step 26 configure-gp-menu-footer.py"
```

---

## Task 13: Create scripts/phases/audit.sh

**Files:**
- Create: `scripts/phases/audit.sh`

- [ ] **Step 1: Create scripts/phases/audit.sh**

```bash
#!/usr/bin/env zsh
# audit.sh — Phase 4: Audit wrapper
# Sources common.sh for env loading, then delegates to scripts/audit/audit.sh
set -euo pipefail

PHASE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PHASE_SCRIPT_DIR/../.." && pwd)"
source "$PHASE_SCRIPT_DIR/common.sh"

CONTENT_SITE_SLUG="${CONTENT_SITE_SLUG:-}"
if [[ -z "$CONTENT_SITE_SLUG" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi

load_env "$CONTENT_SITE_SLUG"
export CONTENT_SITE_SLUG

exec "$REPO_ROOT/scripts/audit/audit.sh" "$@"
```

- [ ] **Step 2: Make executable and verify syntax**

```bash
chmod +x scripts/phases/audit.sh
zsh -n scripts/phases/audit.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/phases/audit.sh
git commit -m "feat(phases): add scripts/phases/audit.sh (thin wrapper over scripts/audit/audit.sh)"
```

---

## Task 14: Rewrite main.sh as thin menu

**Files:**
- Modify: `main.sh` (complete rewrite)

### Context
Current `main.sh` is 704 lines and does everything. New version is ~50 lines: prompts for slug, loads env, shows a phase menu (or accepts `$1`), then `exec`s the chosen phase script. The actual step logic lives in `scripts/phases/`.

The `CONTENT_SITE_SLUG` is exported so phase scripts can inherit it without prompting again.

- [ ] **Step 1: Back up current main.sh to docs/**

```bash
cp main.sh docs/main.sh.bak-before-restructure
git add docs/main.sh.bak-before-restructure
```

This is a reference if anything is missed. Delete after verification.

- [ ] **Step 2: Rewrite main.sh**

Replace the entire content of `main.sh` with:

```bash
#!/usr/bin/env zsh
# main.sh — Auto Create Site orchestrator
# Prompts for site slug, loads env, shows phase menu (or accepts $1 argument).
#
# Usage:
#   ./main.sh                  # interactive menu
#   ./main.sh wordpress        # jump to wordpress phase (Steps 0–15)
#   ./main.sh content          # jump to content phase (Steps 16–23)
#   ./main.sh publish          # jump to publish phase (Steps 24–26)
#   ./main.sh audit            # audit any live site
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Site slug ─────────────────────────────────────────────────────────────────
PHASE="${1:-}"

if [[ -z "${CONTENT_SITE_SLUG:-}" ]]; then
  echo ""
  printf "  Enter your site slug (e.g. opera-garnier, hagia-sofia): "
  read -r CONTENT_SITE_SLUG
fi
export CONTENT_SITE_SLUG

# ── Load envs (for banner only — phase scripts reload them) ───────────────────
ROOT_ENV="$SCRIPT_DIR/.env"
SITE_ENV="$SCRIPT_DIR/input/$CONTENT_SITE_SLUG/.env"
[[ -f "$ROOT_ENV" ]] && { set -a; source "$ROOT_ENV"; set +a; }
[[ -f "$SITE_ENV" ]] && { set -a; source "$SITE_ENV"; set +a; }

SITE_HOST="${WP_SITE_URL:-$CONTENT_SITE_SLUG}"
SITE_HOST="${SITE_HOST#https://}"
SITE_HOST="${SITE_HOST#http://}"
SITE_HOST="${SITE_HOST%%/*}"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  Auto Create Site — ${SITE_HOST}"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Phase selection ───────────────────────────────────────────────────────────
if [[ -z "$PHASE" ]]; then
  echo ""
  echo "  Select a phase:"
  echo "    [1] wordpress  — Steps 0–15: WP install + config"
  echo "    [2] content    — Steps 16–23: tickets, MD→HTML, L1, homepage"
  echo "    [3] publish    — Steps 24–26: REST publish + cache + menu"
  echo "    [4] audit      — Audit any live site"
  echo ""
  printf "  Enter 1–4 (or phase name): "
  read -r _INPUT
  case "$_INPUT" in
    1|wordpress) PHASE="wordpress" ;;
    2|content)   PHASE="content"   ;;
    3|publish)   PHASE="publish"   ;;
    4|audit)     PHASE="audit"     ;;
    *) echo "  Unknown phase: $_INPUT"; exit 1 ;;
  esac
fi

# ── Dispatch ──────────────────────────────────────────────────────────────────
PHASE_SCRIPT="$SCRIPT_DIR/scripts/phases/${PHASE}.sh"
if [[ ! -f "$PHASE_SCRIPT" ]]; then
  echo "  ERROR: Phase script not found: $PHASE_SCRIPT"
  exit 1
fi

exec "$PHASE_SCRIPT" "${@:2}"
```

- [ ] **Step 3: Make executable and verify syntax**

```bash
chmod +x main.sh
zsh -n main.sh
```

- [ ] **Step 4: Smoke-test — verify dispatch works**

```bash
# This should print the wordpress phase header without actually running anything:
echo "test-site" | timeout 5 ./main.sh wordpress 2>&1 | head -10 || true
```
Expected: prints WordPress phase header or prompts for slug (not "Phase script not found").

- [ ] **Step 5: Remove the backup after verifying**

```bash
git rm docs/main.sh.bak-before-restructure
```

- [ ] **Step 6: Commit**

```bash
git add main.sh
git commit -m "feat: rewrite main.sh as thin phase-dispatch menu (~50 lines)"
```

---

## Task 15: Update CLAUDE.md + delete root scratch files

**Files:**
- Modify: `CLAUDE.md`
- Delete: `fix_menu_v2.php`, `"Run Each Step"` (if present)
- Check and delete: root-level `todo.md`, `review.md`, `summary.md`

- [ ] **Step 1: Update CLAUDE.md — How to Run It section**

Replace the `How to Run It` section:
```markdown
## How to Run It

\`\`\`bash
# Start or resume site setup (interactive menu)
./main.sh

# Jump to a specific phase
./main.sh wordpress        # Steps 0–15: WP install + config
./main.sh content          # Steps 16–23: tickets, MD→HTML, L1, homepage
./main.sh publish          # Steps 24–26: REST publish + cache + menu
./main.sh audit            # Audit any live site
\`\`\`

The script is interactive — it will pause and prompt you at key steps.
```

- [ ] **Step 2: Update CLAUDE.md — Key Files table**

Replace the `scripts/base/` row with `scripts/wordpress/`:
```markdown
| `scripts/wordpress/` | WordPress base setup scripts (find-wp-path, cleanup, setup, plugins, theme, layout, colors, typography, GP elements, indexing) |
| `scripts/content/l1/` | L1 page generators (generate-*.sh) and assembler Python modules |
| `scripts/content/l2/` | L2 article converters (batch MD→HTML pipeline) |
| `scripts/post-launch/` | Post-launch image and card fix scripts |
| `scripts/phases/` | Phase entry points: wordpress.sh, content.sh, publish.sh, audit.sh + common.sh |
| `scripts/audit/` | Live site audit scripts |
```

- [ ] **Step 3: Delete root scratch files**

```bash
[[ -f fix_menu_v2.php ]] && git rm fix_menu_v2.php || true
[[ -f "Run Each Step" ]] && git rm "Run Each Step" || true
for f in todo.md review.md summary.md server1-exploration.md server2-exploration.md htmlpush.sh; do
  [[ -f "$f" ]] && git rm "$f" || true
done
```

- [ ] **Step 4: Verify CLAUDE.md is updated**

```bash
grep -A 10 "How to Run It" CLAUDE.md
grep "scripts/wordpress\|scripts/phases" CLAUDE.md
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for new directory structure and phase scripts, delete scratch files"
```

---

## Verification

After all tasks complete, run these checks to confirm the restructure is working end-to-end.

- [ ] **V1: No broken references to old paths**

```bash
grep -rn "scripts/base/\|l1_assembler\|scripts/l2/" scripts/ main.sh 2>/dev/null | grep -v ".bak\|#"
```
Expected: zero hits.

- [ ] **V2: Python REPO_ROOT resolves correctly for all moved files**

```bash
python3 -c "
from pathlib import Path
import os
root = os.path.abspath('.')

checks = [
    ('scripts/content/l2/batch.py', 3),
    ('scripts/content/l2/audit.py', 3),
    ('scripts/content/l2/inventory.py', 3),
    ('scripts/content/l2/article_meta.py', 3),
    ('scripts/content/l1/assembler/homepage.py', 5),
]

ok = True
for rel_path, depth in checks:
    p = Path(rel_path).resolve()
    repo_root = p.parents[depth - 1]
    if str(repo_root) == root:
        print(f'  ✓ {rel_path}')
    else:
        print(f'  ✗ {rel_path}: got {repo_root}, expected {root}')
        ok = False

print('All OK' if ok else 'FAILURES FOUND')
"
```

- [ ] **V3: Python module invocations work**

```bash
cd "$(git rev-parse --show-toplevel)"
python3 -c "import scripts.content.l1.assembler.plan_your_visit" 2>&1 | head -5
python3 -c "import scripts.content.l1.assembler.what_to_see" 2>&1 | head -5
python3 -c "import scripts.content.l1.assembler.tickets_tours" 2>&1 | head -5
```
Expected: no ImportError (a usage error is fine — we're just checking the module resolves).

- [ ] **V4: Phase scripts have correct syntax**

```bash
for f in scripts/phases/*.sh; do
  zsh -n "$f" && echo "  ✓ $f" || echo "  ✗ $f"
done
```

- [ ] **V5: main.sh dispatches correctly**

```bash
zsh -n main.sh && echo "  ✓ main.sh syntax OK"
grep "scripts/phases" main.sh | head -5
```

- [ ] **V6: Fluent Form fix in publish-to-wordpress.sh**

```bash
grep -A 5 "WP_SHORTCODE_RE" scripts/content/publish-to-wordpress.sh | head -15
```
Expected: two occurrences of `WP_SHORTCODE_RE = re.compile`, one per payload builder.

- [ ] **V7: Template wrappers removed**

```bash
head -3 templates/contact-us-template.html
head -3 templates/about-us-template.html
tail -2 templates/contact-us-template.html
tail -2 templates/about-us-template.html
```
Expected: First line is `<!-- SEO`, last line is `</div>` or `</script>` — NOT `<!-- /wp:html -->`.
