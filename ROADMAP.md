# Beast Mode Roadmap — Auto-Create-Site

## Goal
`./create-site.sh "Mont-Saint-Michel" montsaintmichel-guide.com --tickets tickets.json`
→ Fully published WordPress site. 10+ sites/month. Solo operator.

## Three Phases (with review gates)

```
Phase 1: Content         Phase 2: HTML + Config       Phase 3: WP Publish
─────────────────        ─────────────────────        ────────────────────
Attraction name    →     MD files              →      WP install + DNS
  ↓                        ↓                           ↓
Content graph             L2 article HTML              Publish all pages
  ↓                        ↓                           ↓
xlsx manifest             L1 hub pages                 Nav menu
  ↓                        ↓                           ↓
39 MD articles            Homepage                     RankMath + GP Elements
  ↓                        ↓                           ↓
homepage-config.json      Validate all                 GA4 + GSC
l1-config.json                                          ↓
design-config.md          ── REVIEW GATE ──            ── REVIEW GATE ──
                          (open in browser)             (visual QA on live site)
── REVIEW GATE ──
(review MD quality)
```

---

## Phase 1: Content Generation (Priority #1)

### What exists today
- Manual Claude chat to create content graph + xlsx
- Manual Claude chat to write MD articles in batches of 5-10
- Manual JSON config creation

### What to build

#### 1.1 — Content Graph Generator
**Script:** `scripts/content/generate-content-graph.sh`
**Input:** Attraction name, domain, country/region
**Output:** `input/<slug>/content-graph.json`

```json
{
  "attraction": "Mont-Saint-Michel",
  "domain": "montsaintmichel-guide.com",
  "silos": [
    {
      "name": "Tickets & Tours",
      "slug": "tickets-tours",
      "articles": [
        {"title": "...", "slug": "...", "keywords": [...], "intent": "transactional", "brief": "..."}
      ]
    }
  ]
}
```

**How:** Single Claude call with a prompt that:
- Takes the attraction name
- Generates 3 silos (or 4 if warranted) with ~30-40 articles
- Assigns keywords, search intent, and a 2-sentence brief per article
- Follows the proven structure from existing sites (Opera Garnier, Auschwitz, MSM)

#### 1.2 — xlsx Manifest Generator
**Script:** `scripts/content/generate-xlsx.sh`
**Input:** `content-graph.json`
**Output:** `input/<slug>/*.xlsx`

**How:** Python script that converts content-graph.json into the xlsx format expected by the pipeline. No Claude needed — pure data transformation.

#### 1.3 — Article Batch Writer
**Script:** `scripts/content/generate-articles.sh`
**Input:** `content-graph.json`, `tickets.json` (manually curated)
**Output:** `input/<slug>/{tickets-tours,plan-your-visit,what-to-see}/*.md`

**How:**
- Reads the content graph for article titles, briefs, keywords
- Uses per-silo prompt templates (3 templates):
  - `prompts/silo-tickets.md` — price tables, What's Included, Buy CTAs
  - `prompts/silo-plan.md` — logistics, transport, timing, practical info
  - `prompts/silo-what-to-see.md` — descriptive, editorial, experience-focused
- All share: AEO Quick Answer, FAQ, Related Reading, front matter format
- Calls `claude -p` per article (or batch of 3-5 per silo)
- Injects correct affiliate links from `tickets.json`
- Numbers files: `1-slug.md`, `2-slug.md`, etc.
- Parallel execution: 4 workers (same pattern as batch-md-to-html.sh)

#### 1.4 — Config Auto-Generator
**Script:** `scripts/content/generate-configs.sh`
**Input:** `content-graph.json`, `tickets.json`, domain, accent color
**Output:** `homepage-config.json`, `l1-config.json`, `design-config.md`

**How:**
- `homepage-config.json`: built from tickets.json + content graph (picks top articles for plan_your_visit and what_to_see highlights). FAQs, tips generated via one Claude call.
- `l1-config.json`: built from content graph (silo structure → page configs). SEO titles, descriptions, CTAs, quicktips all generated via Claude.
- `design-config.md`: accent color (auto-picked or provided), always `#ff0000` default.
- Config validation: check all required fields exist before writing.

#### 1.5 — Phase 1 Orchestrator
**Script:** `scripts/phase1.sh`
**Input:** `"Mont-Saint-Michel" montsaintmichel-guide.com --tickets tickets.json [--accent "#ff0000"]`
**Output:** Complete `input/<slug>/` directory ready for Phase 2

```
phase1.sh
  ├── generate-content-graph.sh  →  content-graph.json
  ├── generate-xlsx.sh           →  *.xlsx
  ├── generate-articles.sh       →  39 MD files
  └── generate-configs.sh        →  homepage-config.json, l1-config.json, design-config.md
```

---

## Phase 2: HTML + Config (Exists, needs reliability fixes)

### What exists today
- `batch-md-to-html.sh` — parallel MD→HTML via Claude (recently fixed)
- `generate-l1-pages.sh` — L1 hub pages via Claude (recently rewritten)
- `generate-homepage.sh` — homepage from template (works)

### What to fix/improve

#### 2.1 — Config Validator
**Script:** `scripts/content/validate-configs.sh`
**Runs before any HTML generation.**
Checks:
- All required fields in homepage-config.json
- All required fields in l1-config.json (per page)
- xlsx column mapping matches expected format
- Ticket URLs are valid (no broken tracking params)
- Campaign prefix consistency across all configs
- Cross-references: l1-config category names match xlsx categories

#### 2.2 — HTML Output Validator
**Runs after each HTML generation.**
Checks per file:
- Has `<h2>` sections matching MD source
- Has Top Tickets block (correct count: 2 or 3)
- Has FAQ section with JSON-LD
- Has Related Reading section
- Correct accent color in CSS
- No duplicate Top Tickets blocks
- File size > 10KB (not truncated)
- Correct slug (no numeric prefix)

#### 2.3 — Phase 2 Orchestrator
**Script:** `scripts/phase2.sh`
**Input:** site slug
**Output:** Complete `output/<slug>/` directory

```
phase2.sh
  ├── validate-configs.sh        →  pass/fail
  ├── batch-md-to-html.sh        →  39 L2 HTML files
  ├── generate-l1-pages.sh       →  3 L1 HTML files
  └── generate-homepage.sh       →  homepage.html
```

---

## Phase 3: WP Publish (Partially exists, needs expansion)

### What exists today
- `main.sh` steps 1-13: WP setup (plugins, theme, layout, colors, typography, etc.)
- `publish-to-wordpress.sh`: publishes HTML as WP posts/pages

### What to build

#### 3.1 — Bluehost WP Install Creator
**Script:** `scripts/base/create-wp-install.sh`
**Input:** domain name
**How:** SSH into Bluehost, create new WP install via WP-CLI or Bluehost API, configure siteurl/home.

#### 3.2 — DNS Configurator
**Script:** `scripts/base/configure-dns.sh`
**Input:** domain name, Bluehost server IP
**How:** Bluehost API or cPanel API to point domain A record to server.

#### 3.3 — Auto Menu Creator
**Script:** `scripts/content/create-menu.sh`
**Input:** site slug, l1-config.json
**How:** WP-CLI via SSH to create nav menu:
- Top level: Home | Tickets & Tours | Plan Your Visit | What to See
- Dropdowns: all L2 article pages under each L1

#### 3.4 — GSC Connector
**Script:** `scripts/base/configure-gsc.sh`
**Input:** domain, GA4 measurement ID
**How:** Submit sitemap URL to GSC via API (requires one-time OAuth setup).

#### 3.5 — Phase 3 Orchestrator
**Script:** `scripts/phase3.sh`
**Input:** site slug, domain

```
phase3.sh
  ├── create-wp-install.sh       →  WP install on Bluehost
  ├── configure-dns.sh           →  DNS pointed
  ├── main.sh steps 1-13         →  plugins, theme, layout, colors, etc.
  ├── publish-to-wordpress.sh    →  all pages published
  ├── create-menu.sh             →  nav menu configured
  └── configure-gsc.sh           →  GSC + sitemap submitted
```

---

## Master Orchestrator

**Script:** `create-site.sh`

```bash
./create-site.sh "Mont-Saint-Michel" montsaintmichel-guide.com --tickets tickets.json

# Phase 1: Content
./scripts/phase1.sh "$ATTRACTION" "$DOMAIN" --tickets "$TICKETS"
echo "Review content in input/$SLUG/. Press Y to continue."
read confirm

# Phase 2: HTML
./scripts/phase2.sh "$SLUG"
echo "Review HTML in output/$SLUG/. Open in browser. Press Y to continue."
read confirm

# Phase 3: Publish
./scripts/phase3.sh "$SLUG" "$DOMAIN"
echo "Site live at https://$DOMAIN. Do visual QA."
```

---

## Implementation Order

| Priority | Chunk | Effort | Impact |
|---|---|---|---|
| 1 | 1.1 Content Graph Generator | 1 day | Eliminates manual Claude chat for site structure |
| 2 | 1.3 Article Batch Writer | 2 days | Eliminates manual article writing (80% of time) |
| 3 | 1.4 Config Auto-Generator | 1 day | Eliminates manual JSON creation |
| 4 | 1.2 xlsx Manifest Generator | 0.5 day | Pure data transform |
| 5 | 2.1 Config Validator | 0.5 day | Catches mismatches before they cause bugs |
| 6 | 2.2 HTML Output Validator | 0.5 day | Catches truncated/broken output |
| 7 | 1.5 + 2.3 Phase orchestrators | 0.5 day | Ties it all together |
| 8 | 3.3 Auto Menu Creator | 0.5 day | Eliminates manual WP menu setup |
| 9 | 3.1 + 3.2 WP Install + DNS | 1 day | Eliminates cPanel clicks |
| 10 | 3.4 GSC Connector | 0.5 day | Eliminates manual GSC setup |

**Total: ~8 days to full beast mode.**
**First 4 items (content generation) = 4.5 days, delivers 80% of the time savings.**
