# Auschwitz Guide — Project Status & Remaining Work

## Completed

- [x] **50 L2 articles written** (MD files in `input/auschwitz/`)
  - plan-your-visit: 21 articles
  - tickets-tours: 17 articles
  - what-to-see: 12 articles
- [x] **50 L2 articles converted to HTML** (in `output/auschwitz/03-articles/`)
  - Design template applied (att-article-page CSS system)
  - Partner IDs on all affiliate links (GYG: `partner_id=9BAL9K3`)
  - Campaign IDs on all links (`auschwitz-{page-slug}`)
  - AEO blocks, Top Tickets bar, CTA buttons, FAQ accordions, JSON-LD schema
- [x] **50 L2 articles published to WordPress** (all as draft posts, ids 66–135)
- [x] **Pipeline tooling built**
  - `md-to-html-v2.sh` — few-shot conversion (71–382s per article)
  - `htmlpush.sh` — batch convert + publish (4 parallel workers, `--force`, `--update`)
  - `publish-to-wordpress.sh` — standalone WP publisher with `<!-- wp:html -->` wrapper
- [x] **WordPress base setup** (Step 1 of main.sh — WP path found)

## Remaining Work

### 1. L1 Category Pages (3 pages)
Hub pages that showcase all L2 articles grouped by sub-group.
Detailed plan at `.claude/plans/elegant-booping-chipmunk.md`.

- [ ] **Plan Your Visit** — `output/auschwitz/l1-pages/plan-your-visit.html`
  - Hero: badge, h1, description, CTA buttons, quick tips strip (4 tips)
  - Section: Before You Go (8 article cards)
  - Section: Getting There (7 article cards)
  - Section: On The Day (6 article cards)
  - Cross-links to Tickets & Tours + What to See
  - CTA banner with affiliate link
- [ ] **Tickets & Tours** — `output/auschwitz/l1-pages/tickets-tours.html`
  - Hero + quick tips
  - Section: Booking Advice (7 cards)
  - Section: Ticket Types (5 cards)
  - Section: Tours by City (5 cards)
  - Cross-links + CTA banner
- [ ] **What to See** — `output/auschwitz/l1-pages/what-to-see.html`
  - Hero + quick tips
  - Section: Auschwitz I (5 cards)
  - Section: Auschwitz II-Birkenau (5 cards)
  - Section: Key Sites (2 cards)
  - Cross-links + CTA banner
- [ ] Publish L1 pages to WordPress as **pages** (not posts) via `/wp-json/wp/v2/pages`

### 2. Homepage (1 page)
- [ ] Design and build homepage using `docs/Four Pages/attraction-homepage-template.html` as base
- [ ] Hero section with site name, description, CTA
- [ ] Featured sections linking to all 3 L1 category pages
- [ ] Top ticket recommendations with affiliate links
- [ ] Publish as WordPress front page

### 3. WordPress Base Setup (Steps 2–10 of main.sh)
- [ ] Step 2: Cleanup (remove default Bluehost content)
- [ ] Step 3: Install plugins & theme (GeneratePress, GP Premium, Rank Math, etc.)
- [ ] Step 4: Activate GP Premium modules
- [ ] Step 5: Customize appearance (logo, favicon)
- [ ] Step 6: Configure layout (container width, header, sidebar)
- [ ] Step 7: Configure colors
- [ ] Step 8: Configure typography (Karla font)
- [ ] Step 9: Import GP Elements (analytics, author profile)
- [ ] Step 10: Configure indexing (discourage search engines during dev)

### 4. Content Quality Pass
- [ ] Verify all 50 articles have correct interlinking (links point to real published URLs)
- [ ] Verify no broken affiliate links
- [ ] Verify all FAQPage JSON-LD validates (test with Google Rich Results Test)
- [ ] Verify responsive rendering on mobile (spot-check 5 articles)
- [ ] Check that `<!-- wp:html -->` wrapper prevents wpautop on all posts

### 5. Pre-Launch
- [ ] Switch WP_SITE_URL from staging to production domain
- [ ] Change WordPress "discourage search engines" to allow indexing
- [ ] Set permalink structure to match xlsx URLs (`/plan-your-visit/slug/`, `/tickets-tours/slug/`, `/what-to-see/slug/`)
- [ ] Set L1 pages as parent pages, L2 posts as children (or use categories)
- [ ] Submit sitemap to Google Search Console
- [ ] Verify GA4 tracking (measurement ID in .env)

## Key Files Reference

| File | Purpose |
|------|---------|
| `htmlpush.sh` | Convert MD→HTML + publish to WP (main workflow tool) |
| `scripts/content/md-to-html-v2.sh` | Few-shot MD→HTML converter (uses Claude) |
| `scripts/content/md-to-html.sh.bak` | Backup of original converter (rollback) |
| `scripts/content/publish-to-wordpress.sh` | Standalone WP publisher |
| `scripts/content/example-output.html` | Few-shot reference HTML (used by v2) |
| `docs/Four Pages/attraction-plan-your-visit-template.html` | L1 page CSS/design template |
| `docs/Four Pages/attraction-individual-article-template.html` | L2 article CSS/design template |
| `input/auschwitz/auschwitz_guide.xlsx` | Master content architecture (50 articles) |
| `.env` | WordPress credentials, SSH, GYG API key |
