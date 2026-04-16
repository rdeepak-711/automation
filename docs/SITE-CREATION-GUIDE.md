# The Complete Guide to Building an Attraction/City Affiliate Site

This document describes the end-to-end system for creating a travel affiliate website focused on a single attraction or city. It covers the content architecture, design system, tooling pipeline, and the exact sequence of steps to go from zero to a fully published WordPress site with 50+ articles.

This system was built for Bluehost-hosted WordPress sites using the GeneratePress theme, but the content architecture and design patterns apply to any platform.

---

## 1. The Site Architecture

Every site follows a 3-level hierarchy:

```
L0: Homepage
├── L1: Plan Your Visit (category hub)
│   ├── L2: Opening Hours
│   ├── L2: Getting There from [City]
│   ├── L2: What to Expect
│   └── ... (15-25 articles)
├── L1: Tickets & Tours (category hub)
│   ├── L2: How to Book Tickets
│   ├── L2: Guided Tour with Hotel Pickup
│   ├── L2: Day Tours from [City]
│   └── ... (10-20 articles)
└── L1: What to See (category hub)
    ├── L2: [Main Site] Complete Guide
    ├── L2: [Key Landmark]
    ├── L2: [Exhibition/Area]
    └── ... (8-15 articles)
```

### Why 3 Silos?

These three categories map directly to the visitor decision journey:

1. **Tickets & Tours** — "How do I get in? What does it cost?" (commercial intent, highest conversion)
2. **Plan Your Visit** — "When should I go? How do I get there?" (informational intent, builds trust)
3. **What to See** — "What's actually inside?" (discovery intent, supports longer visits + upsells)

Every visitor question falls into one of these three buckets. The silo structure also creates natural interlinking opportunities — a "What to Expect" article links to tickets, an "Opening Hours" article links to transport options, a "Block 11" article links to the guided tour that covers it.

### The Sub-Group System

Each L1 category is divided into 2-4 sub-groups that organize articles by visitor need:

**Plan Your Visit:**
- Before You Go (preparation: what is it, what to wear, accessibility, children)
- Getting There (transport: from each major city, bus, train, car, airports)
- On The Day (practical: hours, rules, photography, facilities, shuttle)

**Tickets & Tours:**
- Booking Advice (how to book, prices, how far ahead, organised vs direct)
- Ticket Types (guided vs self-guided, specific product reviews)
- Tours by City (day tours from each departure city)

**What to See:**
- [Site 1] (e.g., Auschwitz I — individual landmarks and exhibitions)
- [Site 2] (e.g., Birkenau — ramp, gas chambers, barracks, monument)
- Key Sites (additional locations, FAQ)

Sub-groups appear as sections on the L1 hub pages, with article cards in a responsive 3-column grid.

---

## 2. The Content Spreadsheet (xlsx)

The master spreadsheet is the single source of truth for the entire site. It drives:
- Article generation (titles, slugs, URLs, categories)
- L1 page generation (articles grouped by sub-group)
- Homepage generation (featured articles)
- WordPress publishing (titles, slugs)

### Required Columns

| Column | Purpose | Example |
|--------|---------|---------|
| # | Article number (ordering) | 1 |
| Article Title | H1 and card title | "Opening Hours of Auschwitz-Birkenau" |
| Category | Which L1 silo | "Plan Your Visit" |
| Sub-Group | Section within the L1 page | "On The Day" |
| Category Slug | URL path segment | "plan-your-visit" |
| Article Slug | URL path segment | "opening-hours" |
| Full URL | Complete canonical URL | "https://www.auschwitz-guide.com/plan-your-visit/opening-hours" |
| Priority | Ordering within category | 16 |
| GYG Ticket ID | GetYourGuide activity ID (if applicable) | "t88880" |
| GYG Ticket Type | Product description | "Guided tour + hotel pickup" |
| Content Notes | Brief description (used as card text) | "Open 7 days. Seasonal entry hours." |
| Status | Tracking | "Not Started" / "Draft" / "Published" |

### How Many Articles?

A good target is **40-60 articles** for a single-attraction site:
- Plan Your Visit: 15-25 articles (largest category — covers all practical questions)
- Tickets & Tours: 10-20 articles (depends on number of affiliate products + departure cities)
- What to See: 8-15 articles (depends on the size/complexity of the attraction)

For a city guide (covering multiple attractions), multiply accordingly.

---

## 3. The Design System

All pages share a single CSS design system based on CSS custom properties. The same visual language is used across L0, L1, and L2 pages.

### CSS Variables (Theme)

```css
:root {
  --accent: #ff0000;        /* Brand color — buttons, links, accents */
  --accent-light: #ffe5e5;  /* Tint for badges and backgrounds */
  --accent-dark: #cc0000;   /* Hover states */
  --text-primary: #2a2725;  /* Headings */
  --text-secondary: #5a5550; /* Body text */
  --text-muted: #8a837c;    /* Captions, labels */
  --bg-warm: #faf8f6;       /* Card backgrounds */
  --bg-white: #ffffff;      /* Page background */
  --border: #ece8e4;        /* Borders, dividers */
}
```

To rebrand a site, change only the `--accent` family. Everything else adapts automatically.

### Typography

- **Headings:** Playfair Display (Georgia serif fallback)
- **Body:** Source Sans 3 (Segoe UI sans-serif fallback)
- Both loaded from Google Fonts

### Page Templates

Four HTML templates define the design for each page level:

| Template | Root Class | Purpose |
|----------|-----------|---------|
| `attraction-homepage-template.html` | `.att-homepage` | L0 homepage with hero, ticket cards, highlights, tips, FAQ |
| `attraction-plan-your-visit-template.html` | `.att-plan-page` | L1 category hub with hero, article card grid, cross-links |
| `attraction-tickets-tours-template.html` | `.att-tickets-page` | L1 tickets hub (alternative styling) |
| `attraction-what-to-see-template.html` | `.att-see-page` | L1 what-to-see hub (alternative styling) |
| `attraction-individual-article-template.html` | `.att-article-page` | L2 article with AEO blocks, FAQ accordion, related articles |

Templates are stored in `docs/Four Pages/` and contain the full CSS + HTML structure as reference. The generation scripts extract the CSS from these templates and inject it into the output HTML.

### Responsive Breakpoints

All templates include responsive rules:
- **Desktop:** 3-column grids, 2-column hero, 4-column quick tips
- **Tablet (≤960px):** 2-column grids
- **Mobile (≤768px):** 1-column everything, hero image hidden, stacked layout

### Component Library

| Component | Class | Used In |
|-----------|-------|---------|
| Hero section | `.att-hero` | L0, L1 |
| Quick tips strip | `.att-quicktips` | L1 |
| Article card grid | `.att-articles-grid` + `.att-article-card` | L1 |
| Ticket card grid | `.att-tickets-grid` + `.att-ticket` | L0 |
| Highlight card grid | `.att-highlights-grid` + `.att-highlight` | L0 |
| AEO answer block | `.att-aeo-block` | L2 |
| Top tickets bar | `.att-top-tickets` | L2 |
| CTA button | `.att-buy-now-btn` | L2 |
| Tip box | `.att-tip-box` | L2 |
| Price table | `.att-price-table` | L2 |
| FAQ accordion | `.att-faq` + `.att-faq-details` | L0, L1, L2 |
| Related articles | `.att-related` | L2 |
| Cross-links | `.att-crosslinks` + `.att-crosslink` | L1 |
| CTA banner | `.att-cta-banner` | L0, L1 |

---

## 4. The Article Format (Markdown)

Each L2 article is written as a Markdown file with YAML frontmatter:

```markdown
---
SEO Title: Opening Hours of Auschwitz-Birkenau (55-60 chars)
Meta Description: Check Auschwitz opening hours by month... (150-155 chars)
URL: https://www.auschwitz-guide.com/plan-your-visit/opening-hours
Category: Plan Your Visit
Sub-Group: On The Day
Primary Keyword: auschwitz opening hours
Secondary Keywords: auschwitz birkenau hours, museum opening times
LSI Keywords: seasonal hours, last entry, closed dates
---

# Opening Hours of Auschwitz-Birkenau

> **Quick Answer:** The museum is open every day except 1 January, 25 December, and Easter Sunday. Hours vary by season...

{Two intro paragraphs, 80-100 words each}

## {H2 Sections with body content}

> **Key Fact:** {AEO blocks under question-phrased H2s}

[Book This Tour](https://www.getyourguide.com/...t88880/)

## Frequently Asked Questions

**Question text?**
Answer text.

## Related Articles
[Article Title](url) — Description
```

### Key Article Elements

| Element | Purpose | Frequency |
|---------|---------|-----------|
| YAML frontmatter | SEO metadata | Top of every article |
| AEO blocks (`> **Label:**`) | Answer Engine Optimization — direct answers for AI snippets | 1 before intro + under question H2s (max 4-5) |
| Top Tickets | Affiliate links bar | After intro, before first H2 |
| CTA buttons | Affiliate conversion | Every 500-700 words |
| FAQ section | Long-tail SEO + rich results | End of every article (5-7 questions) |
| Related Articles | Interlinking | End of every article (5-6 links) |
| Internal links | Silo interlinking | 4-6 per article, spread across sections |

### Affiliate Link Rules

Three partners are supported, each with their own tracking parameters:

| Partner | Partner ID Parameter | Campaign ID Parameter |
|---------|---------------------|----------------------|
| GetYourGuide | `?partner_id=9BAL9K3` | `&cmp=auschwitz-{page-slug}` |
| Tiqets | `?partner=thebettervacation` | `&tq_campaign=auschwitz-{page-slug}` |
| Viator | `?pid=P00038490&mcid=42383&medium=link` | `&campaign=auschwitz-{page-slug}` |

**Campaign ID format:** `{site-identifier}-{page-slug}` (e.g., `auschwitz-opening-hours`)

All affiliate links must have `rel="nofollow sponsored" target="_blank"`. Internal links have no `rel` attribute and open in the same tab.

**CTA wording:** Tickets → "Buy This Ticket". Tours → "Book This Tour".

**Brand names:** Never mention GetYourGuide, Tiqets, or Viator in visible text. Use generic product-focused language.

---

## 5. The Pipeline

### Step-by-Step: From Zero to Published Site

```
1. Create the xlsx spreadsheet (master content plan)
2. Write all L2 articles as .md files
3. Place .md files in input/<site-slug>/<category-slug>/
4. Run htmlpush.sh to convert MD→HTML and push to WordPress
5. Run generate-l1-pages.sh to create category hub pages
6. Run generate-homepage.sh to create the homepage
7. Push L1 pages + homepage to WordPress
8. Configure WordPress (theme, plugins, permalinks, indexing)
```

### Key Scripts

| Script | What It Does | Input | Output |
|--------|-------------|-------|--------|
| `htmlpush.sh <folder>` | Converts MD→HTML (parallel) + pushes to WP | `input/<slug>/<silo>/*.md` | `output/<slug>/l2-articles/<silo>/*.html` + WP posts |
| `md-to-html-v2.sh <slug> <file>` | Single MD→HTML conversion via Claude (few-shot) | One `.md` file | One `.html` file |
| `generate-l1-pages.sh <slug>` | Generates 3 L1 category pages from xlsx | `auschwitz_guide.xlsx` | `output/<slug>/l1-pages/*.html` |
| `generate-homepage.sh <slug>` | Generates L0 homepage | Homepage template | `output/<slug>/homepage.html` |
| `publish-to-wordpress.sh <slug>` | Pushes all L2 HTML to WP as draft posts | `output/<slug>/l2-articles/` | WordPress REST API |
| `batch-md-to-html.sh <slug>` | Batch converts all MD files sequentially | `input/<slug>/` | `output/<slug>/l2-articles/` |
| `main.sh` | Full 14-step orchestrator (base setup + content) | Everything | Everything |

### The MD→HTML Conversion

The conversion from Markdown to styled HTML is the most complex step. It uses Claude (via `claude -p` CLI) with a **few-shot prompt**:

1. Claude receives a verified input/output example pair (one complete article)
2. Claude receives the new article to convert
3. Claude pattern-matches and produces HTML using the same classes and structure
4. The script injects the CSS from the template file (Claude doesn't output CSS)
5. Post-processing: strips trailing garbage, injects CSS between SEO comment and HTML body

**Performance:** ~70-400 seconds per article depending on length. With 4 parallel workers, 50 articles complete in ~60-80 minutes.

The CSS is injected from the template file, not generated by Claude. This ensures pixel-perfect consistency across all articles and eliminates CSS drift.

### htmlpush.sh Features

- **Parallel workers** (4 by default) — converts multiple articles simultaneously
- **Skip existing** — doesn't re-convert articles that already have HTML output
- **`--force`** — reconverts all articles regardless
- **`--update`** — updates existing WordPress posts (default: create only, skip existing)
- **Heartbeat** — shows elapsed time and completion count during conversion
- **WordPress publish** — creates/updates posts via REST API with `<!-- wp:html -->` wrapper

---

## 6. WordPress Integration

### Publishing

All content is pushed to WordPress via the REST API (`/wp-json/wp/v2/posts` for articles, `/wp-json/wp/v2/pages` for L1/L0 pages). Authentication uses application passwords.

### The wpautop Problem

WordPress automatically runs `wpautop` on post content, which wraps raw HTML in `<p>` tags and converts newlines to `<br>`. This destroys `<style>` blocks and CSS formatting.

**Solution:** Wrap all content in WordPress Gutenberg raw HTML blocks:
```html
<!-- wp:html -->
{your HTML content}
<!-- /wp:html -->
```

This tells the block editor to treat the content as raw HTML, bypassing all formatting filters.

### Required Plugins

| Plugin | Purpose |
|--------|---------|
| GeneratePress (theme) | Lightweight base theme |
| GP Premium | Advanced layout, typography, elements |
| Rank Math Pro | SEO (meta tags, sitemaps, schema) |
| WP Rocket | Caching and performance |

### Permalink Structure

Set WordPress permalinks to match the xlsx URL structure:
- L2 articles: `/%category%/%postname%/` or custom structure matching `/plan-your-visit/opening-hours/`
- L1 pages: `/plan-your-visit/`, `/tickets-tours/`, `/what-to-see/`
- L0 homepage: set as static front page

---

## 7. SEO, AEO, and GEO

### SEO (Search Engine Optimization)

Every article includes:
- **SEO title** (55-60 characters) in frontmatter → extracted into HTML `<!-- SEO -->` comment
- **Meta description** (150-155 characters)
- **Canonical URL**
- **Primary keyword** in H1, first 100 words, one H2, and 3-5 times in body
- **Internal links** (4-6 per article, dofollow, same tab, LSI keyword anchors)
- **FAQPage JSON-LD schema** for rich results

### AEO (Answer Engine Optimization)

AEO blocks are designed to be extracted by AI assistants (ChatGPT, Perplexity, Google AI Overviews):
- Self-contained 2-3 sentence answers
- Include one specific data point
- No pronouns referring to earlier context
- Placed before the intro (primary query) and under question-phrased H2s

### GEO (Generative Engine Optimization)

For AI citation readiness:
- Full address included at least once
- All prices specific with year ("75 PLN as of 2026", not "around 75 PLN")
- Unique factual details that give AI tools a reason to cite your page
- Entity-rich content (proper nouns, dates, measurements)

---

## 8. Adapting for a New Site

To create a new attraction or city site:

1. **Copy the xlsx template** — change the attraction name, categories, sub-groups, articles, and URLs
2. **Set the GYG ticket IDs** — look up the GetYourGuide activity IDs for tours at the new attraction
3. **Update `.env`** — new WordPress URL, credentials, SSH details, brand color
4. **Write the MD articles** — follow the format described in Section 4
5. **Update the generate scripts** — change the hardcoded content in `generate-homepage.sh` and `generate-l1-pages.sh` (hero text, quick tips, crosslinks, ticket products, FAQs)
6. **Update the few-shot example** — replace `example-output.html` with a verified article from the new site
7. **Run the pipeline** — `htmlpush.sh` for articles, `generate-l1-pages.sh` for hubs, `generate-homepage.sh` for homepage

### What's Reusable As-Is

- The HTML/CSS design templates (just change `--accent` color)
- The `htmlpush.sh` pipeline (parallel conversion + publishing)
- The `md-to-html-v2.sh` conversion logic (few-shot approach)
- The `publish-to-wordpress.sh` publisher
- The WordPress base setup scripts (Steps 1-10 in `main.sh`)
- The entire responsive design system

### What Needs Customisation Per Site

- The xlsx content plan
- The article markdown files
- Hero text, quick tips, and FAQ content in the L1/L0 generator scripts
- Ticket product data (GYG IDs, URLs, prices)
- Campaign ID prefix (e.g., "auschwitz" → "colosseum")
- The few-shot example HTML

---

## 9. Output Directory Structure

```
output/<site-slug>/
├── homepage.html                      ← L0 homepage
├── l1-pages/                          ← L1 category hub pages
│   ├── plan-your-visit.html
│   ├── tickets-tours.html
│   └── what-to-see.html
└── l2-articles/                       ← L2 individual articles
    ├── plan-your-visit/
    │   ├── opening-hours.html
    │   ├── getting-there-from-krakow.html
    │   └── ...
    ├── tickets-tours/
    │   ├── how-to-book-tickets.html
    │   ├── guided-tour-hotel-pickup-krakow.html
    │   └── ...
    └── what-to-see/
        ├── auschwitz-i-complete-guide.html
        ├── block-11-death-block.html
        └── ...
```

---

## 10. Lessons Learned

1. **WordPress `wpautop` will destroy your CSS** if you don't wrap content in `<!-- wp:html -->` blocks.
2. **Claude outputs CSS slowly** — stripping CSS from the output and injecting it from the template file cut conversion time by 27%.
3. **Few-shot prompting beats rule-based prompts** — replacing a 200-line conversion rules document with one verified input/output example reduced conversion time from 376s to 71s (81% faster) with identical output quality.
4. **Parallel workers save wall-clock time** — 4 workers converting simultaneously cuts total time by ~4x.
5. **Campaign IDs should be injected by the script, not written by Claude** — sed replacement after the prompt is built is more reliable than asking Claude to compute them.
6. **The CSS should be a single source of truth** — template file CSS is extracted and injected by the script. Never let Claude generate or modify CSS.
7. **Always strip trailing garbage** from Claude output — it occasionally repeats content after the final `</div>`.
8. **`list-style: none` and `font-weight: 600` on links** need careful handling — changes to the template CSS must be batch-patched across all existing HTML files.
9. **Publish L1/L0 pages as WordPress pages**, not posts — use `/wp-json/wp/v2/pages` endpoint.
10. **The xlsx is the single source of truth** — all generators read from it. Keep it updated as articles move through the pipeline.
