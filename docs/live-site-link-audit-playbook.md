# Live Site Link Audit & Fix Playbook

**Last used:** 2026-04-12 on hagiasophia-guide.com  
**Author:** Claude Code (wp-site-auditor agent)  
**Purpose:** Audit all internal links on a published WordPress site, convert absolute URLs to relative, fix broken links, and verify every link returns HTTP 200 with the correct page title.

---

## Prerequisites

- SSH access to Bluehost server 2: `ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174`
- WP-CLI available on server (runs as `wp`)
- Python 3 available on server
- Local access to `auto-create-site/input/<slug>/` (MD source files) and `auto-create-site/output/<slug>/` (registry, reports)
- **Note:** Bluehost restricted shell does NOT have `sed`, `awk`, `head`, `tail`. Use Python on-server for any text processing.

## Site Directory Map

| Site | WP Directory | Domain |
|---|---|---|
| Hagia Sophia | `website_204db6f9` | hagiasophia-guide.com |
| Mont-Saint-Michel | `website_58b542cb` | montsaintmichel-guide.com |
| Van Gogh Museum | `website_da6eadef` | vangoghmuseum-guide.com |
| Museo del Prado | `website_34029298` | museodelprado-guide.com |
| Amsterdam Canal | `website_amsterdam` | amsterdamcanalcruise-guide.com |
| Angkor Wat | `website_angkorwat` | angkorwat-guide.com |
| Plitvice Lakes | `website_plitvice` | plitvicelakes-guide.com |
| Stonehenge | `website_stonehenge` | guide-stonehenge.com |
| Topkapi Palace | `website_topkapi` | topkapipalace-guide.com |

---

## The Process (7 Steps)

### Step 1: Build URL Registry (local)

Generate the single source of truth for all URLs from the XLSX manifest.

```bash
cd /Users/deepak/Desktop/firestormInternet/auto-create-site
python3 scripts/content/build-url-registry.py <site-slug>
# e.g. python3 scripts/content/build-url-registry.py hagia-sofia
```

**Output:** `output/<slug>/url-registry.json`  
**Verify:** Check page counts (L0 + L1 + L2), domain, category slugs.

---

### Step 2: Count Absolute URLs on Live Site (SSH)

Before fixing anything, count how many absolute internal URLs exist per post.

```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 python3 << 'PYEOF'
import subprocess, re, json

WP_PATH = "/home1/dpskbcmy/public_html/<WEBSITE_DIR>"
DOMAIN = "<DOMAIN>"

def wp(cmd):
    r = subprocess.run(f"wp {cmd} --path={WP_PATH}", shell=True, capture_output=True, text=True)
    return r.stdout.strip()

posts = json.loads(wp("post list --post_type=post,page --post_status=publish --fields=ID,post_name,post_title --format=json"))
total = 0
for p in posts:
    content = wp(f"post get {p['ID']} --field=content")
    count = len(re.findall(rf'https://(?:www\.)?{re.escape(DOMAIN)}/', content))
    if count > 0:
        print(f"Post {p['ID']} ({p['post_name']}): {count} absolute URLs")
        total += count
print(f"---\nTOTAL: {total} absolute URLs across {len(posts)} posts/pages")
PYEOF
```

**Replace:** `<WEBSITE_DIR>` and `<DOMAIN>` for the target site.

---

### Step 3: Cross-Reference Live Links vs MD Source (local + SSH)

Extract all absolute internal `href` links from live posts, then check each against the source MD files to classify as "from MD source" or "Claude-added".

**Key gotcha discovered on hagia-sofia:**
- MD files may use a **different domain spelling** than the live site (e.g., `hagiasofia-guide.com` in MD vs `hagiasophia-guide.com` on live WP)
- MD files may use **shorter slugs** than live WP (e.g., `/tickets/audio-guide/` in MD vs `/tickets/hagia-sophia-audio-guide/` on live)
- Always `grep` a sample MD file first to discover the actual domain used: `grep -o 'https://[^)]*' input/<slug>/<silo>/<any-article>.md | head -5`

**Process:**

1. SSH to server, extract all absolute internal hrefs from every post, output as JSON (post ID, slug, list of absolute URLs)
2. Locally, scan all MD files in `input/<slug>/` for internal links to the MD domain
3. Build mapping: MD short slug → live long slug (try `hagia-sophia-` prefix, etc.)
4. For each live link, classify: found in MD source or Claude-added
5. Check target exists (slug matches a published WP post)

**Output:** `output/<slug>/link-audit-report.md`

---

### Step 4: Apply Absolute-to-Relative Fix (SSH)

Once satisfied all links are safe, bulk-convert on the live site.

```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 python3 << 'PYEOF'
import subprocess, re, json

WP_PATH = "/home1/dpskbcmy/public_html/<WEBSITE_DIR>"
DOMAIN = "<DOMAIN>"

def wp(cmd):
    r = subprocess.run(f"wp {cmd} --path={WP_PATH}", shell=True, capture_output=True, text=True)
    return r.stdout.strip()

posts = json.loads(wp("post list --post_type=post,page --post_status=publish --fields=ID,post_name --format=json"))
fixed = 0
for p in posts:
    content = wp(f"post get {p['ID']} --field=content")
    new_content = re.sub(rf'https://(?:www\.)?{re.escape(DOMAIN)}/', '/', content)
    if new_content != content:
        # Backup
        with open(f"/tmp/backup_{p['ID']}.html", 'w') as f:
            f.write(content)
        # Update
        with open(f"/tmp/fix_{p['ID']}.html", 'w') as f:
            f.write(new_content)
        result = subprocess.run(
            f'wp post update {p["ID"]} --post_content="$(cat /tmp/fix_{p["ID"]}.html)" --path={WP_PATH}',
            shell=True, capture_output=True, text=True
        )
        if 'Success' in result.stdout:
            count = len(re.findall(rf'https://(?:www\.)?{re.escape(DOMAIN)}/', content))
            print(f"Fixed {p['ID']} ({p['post_name']}): {count} URLs converted")
            fixed += 1
        else:
            print(f"FAILED {p['ID']}: {result.stderr}")
        subprocess.run(f"rm -f /tmp/fix_{p['ID']}.html", shell=True)

print(f"---\nFixed: {fixed} posts/pages\nBackups: /tmp/backup_*.html")
PYEOF
```

**Important:**
- Backups are saved at `/tmp/backup_<ID>.html` on the server
- This converts ALL absolute internal URLs (both `https://domain/` and `https://www.domain/`)
- Affiliate links (getyourguide.com, tiqets.com, viator.com) are NOT touched — they don't match the domain pattern

---

### Step 5: Fix Broken Links (SSH)

After converting to relative, some links may be broken due to slug mismatches between MD source and live WP. Find and fix them.

```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 python3 << 'PYEOF'
import subprocess, re, json

WP_PATH = "/home1/dpskbcmy/public_html/<WEBSITE_DIR>"

def wp(cmd):
    r = subprocess.run(f"wp {cmd} --path={WP_PATH}", shell=True, capture_output=True, text=True)
    return r.stdout.strip()

# Build slug lookup
posts = json.loads(wp("post list --post_type=post,page --post_status=publish --fields=ID,post_name --format=json"))
valid_slugs = set(p['post_name'] for p in posts)

# Find all internal links and check targets
all_links = set()
for p in posts:
    content = wp(f"post get {p['ID']} --field=content")
    hrefs = re.findall(r'href="(/[^"]*)"', content)
    all_links.update(hrefs)

broken = []
for link in sorted(all_links):
    slug = link.strip('/').split('/')[-1]
    if slug and slug not in valid_slugs:
        broken.append(link)
        print(f"BROKEN: {link} (slug '{slug}' not found)")

if not broken:
    print(f"All {len(all_links)} internal links resolve correctly!")
else:
    print(f"\n{len(broken)} broken links need manual fix")
    print("Define a mapping dict and re-run with replacements")
PYEOF
```

**If broken links found**, define the fix mapping and apply:

```python
# Example fix mapping (discovered per site)
fixes = {
    '/tickets-tours/': '/tickets/',                              # old category slug
    '/tickets/audio-guide/': '/tickets/hagia-sophia-audio-guide/',  # short -> long slug
    '/tickets/guided-tours/': '/tickets/best-hagia-sophia-guided-tours/',
}

# Then for each post, replace href="<old>" with href="<new>"
```

---

### Step 6: Verify All Links Return HTTP 200 (local)

After all fixes, check every unique internal link path returns HTTP 200 and get the page title.

```python
import urllib.request, ssl, re, time

paths = [...]  # all unique internal paths from Step 5
domain = "https://<DOMAIN>"
ctx = ssl.create_default_context()

for path in paths:
    url = domain + path
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        'Accept': 'text/html',
    })
    resp = urllib.request.urlopen(req, timeout=15, context=ctx)
    html = resp.read(20000).decode('utf-8', errors='ignore')
    title_m = re.search(r'<title>([^<]+)</title>', html)
    title = title_m.group(1).strip() if title_m else '?'
    print(f"200 {path} | {title[:80]}")
    time.sleep(0.3)  # be nice to the server
```

**Important:** Bluehost blocks HEAD requests with 406. Always use GET with a browser User-Agent.

---

### Step 7: Link Integrity Check — Anchor Text vs Page Title (local)

The final quality check. For every link in every post, verify the anchor text is contextually appropriate for the target page.

**Process:**

1. From the backup files (Step 4), extract every `<a href="...">anchor text</a>` with the original absolute URL
2. Map each relative path to the target page title (from Step 6)
3. Compare anchor text keywords against page title keywords
4. Flag any link where anchor text has <30% keyword overlap with the target title

**Output:** `output/<slug>/link-integrity-check.md` — per-post table with columns:

| # | Anchor Text | Links To | Target Page Title | Match? |
|---|---|---|---|---|

**Expect:** Most links will be OK. "CHECK" flags are usually contextual anchors like "full ticket comparison" → Tickets overview page — valid but uses different wording than the title.

---

## Output Files

After completing all 7 steps, you'll have these reports in `output/<slug>/`:

| File | What it contains |
|---|---|
| `url-registry.json` | Single source of truth — all pages, categories, expected links |
| `link-audit-report.md` | Cross-reference: live links vs MD source, classification |
| `url-change-log.md` | Every change made: post title, anchor text, old URL, new URL |
| `link-integrity-check.md` | Final verification: anchor text vs target page title, HTTP 200 |

---

## Known Gotchas

### 1. Domain Spelling Mismatches
MD source files may use a different domain than the live WP site. Always check the actual domain in MD content before cross-referencing.
- hagia-sofia: MD uses `hagiasofia-guide.com`, live uses `hagiasophia-guide.com`

### 2. Short Slug vs Long Slug
XLSX/MD may have short slugs (`dress-code`), but WP published with long slugs (`hagia-sophia-dress-code`). The permalink structure `/%category%/%postname%/` means the URL is `/plan-your-visit/hagia-sophia-dress-code/`, not `/plan-your-visit/dress-code/`.

When cross-referencing, try mapping by:
- Exact match first
- Prepending `<site-prefix>-` to the short slug
- Checking if short slug is a suffix of the live slug

### 3. Bluehost Restricted Shell
The SSH shell on Bluehost does NOT have: `sed`, `awk`, `head`, `tail`, `wc` (sometimes). Always use Python for text processing on-server. `grep` works but only basic flags.

### 4. Bluehost Blocks HEAD Requests
HTTP HEAD requests return 406. Always use GET with a full browser User-Agent header for HTTP checks.

### 5. Backups Persist on Server
After Step 4, backups are at `/tmp/backup_<ID>.html`. These survive until server restart. Clean up after verifying:
```bash
ssh ... "rm -f /tmp/backup_*.html"
```

### 6. Category Slug vs Directory Name
The input directory might be `tickets-tours/` but the WP category slug is `tickets` and the URL path is `/tickets/`. The `url-registry.json` `dir_to_url` mapping resolves this.

### 7. Permalink Structure
All sites use `/%category%/%postname%/`. This means:
- L1 pages: `/tickets/`, `/plan-your-visit/`, `/what-to-see/`
- L2 posts: `/tickets/hagia-sophia-tickets/`, `/plan-your-visit/opening-hours/`
- Posts are under their category in the URL, not at root

### 8. Pages Without Categories
Some posts may appear under `/plan-your-visit/` in the URL but were actually published under a different category slug. WP-CLI `wp post get <ID> --field=post_name` gives the slug, but the full URL depends on the category assignment. Verify with `wp post term list <ID> category --fields=slug --format=csv`.

---

## Quick Reference — SSH One-Liners

```bash
# Set variables for any site
SSH="ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174"
WP_PATH="/home1/dpskbcmy/public_html/<WEBSITE_DIR>"

# Count all published posts
$SSH "wp post list --post_type=post --post_status=publish --format=count --path=$WP_PATH"

# Count all published pages
$SSH "wp post list --post_type=page --post_status=publish --format=count --path=$WP_PATH"

# List all posts with titles
$SSH "wp post list --post_type=post --post_status=publish --fields=ID,post_name,post_title --format=table --path=$WP_PATH"

# Check permalink structure
$SSH "wp option get permalink_structure --path=$WP_PATH"

# List categories
$SSH "wp term list category --fields=term_id,name,slug,count --format=table --path=$WP_PATH"

# Get content of a specific post
$SSH "wp post get <ID> --field=content --path=$WP_PATH"

# Check what category a post belongs to
$SSH "wp post term list <ID> category --fields=slug --format=csv --path=$WP_PATH"
```

---

## How to Use the Agents

Both agents live in `auto-create-site/.claude/agents/`. Run from inside `auto-create-site/` or its parent.

### wp-site-auditor (audit & fix live sites)

```bash
# Audit a specific site
claude --agent wp-site-auditor "Audit hagiasophia-guide.com — check all internal links are relative and working"

# Full audit + fix + report
claude --agent wp-site-auditor "Run the full 7-step link audit playbook on montsaintmichel-guide.com"

# Check a specific issue
claude --agent wp-site-auditor "Check if all posts on vangoghmuseum-guide.com have Rank Math SEO metadata"
```

### wp-site-builder (build & publish new sites)

```bash
# Build a new site end-to-end
claude --agent wp-site-builder "Build and publish the plitvice-lakes site"

# Run just Phase 2 (HTML generation)
claude --agent wp-site-builder "Run Phase 2 for angkor-wat — generate HTML from MD articles"

# Run just Phase 3 (WordPress publishing)
claude --agent wp-site-builder "Run Phase 3 for stonehenge — publish to WordPress"
```

**Important:** Both agents use Sonnet 4.6. They have full access to SSH, local files, and all scripts in `auto-create-site/`.

---

## Checklist for Running on a New Site

- [ ] Build URL registry: `python3 scripts/content/build-url-registry.py <slug>`
- [ ] Identify site's `<WEBSITE_DIR>` and `<DOMAIN>` from the table above
- [ ] Grep a sample MD file to find the domain used in MD source
- [ ] Run Step 2: count absolute URLs
- [ ] Run Step 3: cross-reference live vs MD
- [ ] Write `link-audit-report.md`
- [ ] Run Step 4: bulk convert absolute → relative
- [ ] Run Step 5: find & fix broken links
- [ ] Run Step 6: HTTP 200 verification
- [ ] Run Step 7: anchor text vs page title check
- [ ] Write `url-change-log.md` and `link-integrity-check.md`
- [ ] Clean up server backups
