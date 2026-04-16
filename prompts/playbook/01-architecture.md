# Prompt 1 — Site Architecture Generator

**PREREQUISITE:** Paste your filled `00-blueprint.md` above this prompt before running.

---

## ⚠️ STRICT CONSTRAINTS — READ BEFORE PROCEEDING

- Output EXACTLY 3 content silos: `tickets-and-tours`, `plan-your-visit`, `what-to-see`
- Do NOT create blog or /blog/ pages
- Every article topic MUST be assigned to one of the 3 content silos
- Utility pages allowed (NO L2 articles under them): homepage (/), faq (/faq/), about (/about/), contact (/contact/)
- No page may have a category other than: homepage, tickets-and-tours, plan-your-visit, what-to-see, utility
- The TSV manifest must contain: 1 homepage + 3 L1 hubs + L2 articles + utility pages (faq, about, contact)
- Tickets & Tours silo L2 articles: create EXACTLY one L2 article per product in the Product Catalog. One article per product, named after that product. Do NOT create grouping, comparison, or editorial L2 articles (no "Guided Tours Compared", "Best Tour Guide", "Skip-the-Line Tickets" articles). The 8 ticket L2 articles must map 1:1 to the 8 catalog products.

---

PROMPT 1
Site Architecture Generator
Design the complete sitemap, URL structure, page hierarchy, and internal linking plan.

PREREQUISITE: Paste your filled Prompt 0 (Site Blueprint) above this prompt before running.

System Role
You are a senior SEO strategist and affiliate marketing expert specializing in travel websites. Design the complete site architecture for a standalone affiliate website focused on a single tourist attraction. Use the Site Blueprint provided above as your master reference.

Step 1: Topic Universe Mapping
Map the ENTIRE topic universe. Think like a traveler at every stage: pre-visit (research & planning), during visit (experience), post-visit (sharing & related). List at LEAST 40-60 distinct topics.

Step 2: Keyword Intent Clustering
Cluster topics by intent: 1) Transactional (Money Pages), 2) Commercial Investigation (Comparison Pages), 3) Informational High-value (Supporting Pages), 4) Informational Authority (Blog/Editorial), 5) Navigational/Practical (Utility Pages).

Step 3: Page Hierarchy & URL Structure
Design the page structure using the three content categories from the Blueprint (Tickets & Tours, Plan Your Visit, What to See). For each page: Title, URL slug, Intent, Primary Keyword, Monetization Role, Affiliate Integration (referencing specific products from the Product Catalog), Word Count, Priority.

Step 4: Navigation & Menu Structure
Design primary nav using the three category labels from the Blueprint. Include products marked "Show in Menu: Yes" as dropdown items under Tickets & Tours. Add the Book Tickets CTA button. Design footer and sidebar.

Step 5: Internal Linking Strategy
Hub-and-spoke model, cross-linking rules, contextual links, breadcrumbs, related content blocks, sticky/global CTAs using the Priority 1 product from the Product Catalog.

Step 6: Content Silo Map
Visualize three content silos (one per category) with pillar pages and supporting pages. Show cross-silo links.

Step 7: Technical Page Types
Define 6 templates: Homepage, Hub/Pillar, Standard Content, Comparison, Blog, FAQ. Include product catalog display requirements per template.

Step 8: Launch Roadmap
Phase 1 (MVP, 10-15 pages), Phase 2 (Authority, 15-25 pages), Phase 3 (Growth, ongoing).

Step 9: Page Manifest (TSV)
After completing all architecture sections above, output a PAGES MANIFEST block as follows:

---PAGES-TSV-START---
title	url_slug	category	page_type	intent	primary_keyword	word_count	seo_title
[one row per page, tab-separated, exactly these 8 columns]
---PAGES-TSV-END---

Rules: tab-separated, no quotes, use exact column names in header, one row per page.
word_count should be a plain range like "1200-1800" or single number like "1500" (no commas, no "words").
seo_title: max 60 characters, primary keyword near the front, written for the HTML <title> tag. May differ from title — tighter, more keyword-forward. No trailing site name.
page_type allowed values: homepage, hub, standard-content, faq, utility — use "standard-content" for all L2 article pages (NOT "article").

Constraints
- Affiliate site — every decision funnels toward products in the Product Catalog
- Three content categories from Blueprint define the silo structure
- Products marked "Show in Menu" must appear in navigation
- Must demonstrate E-E-A-T
- Design for Google organic AND AI answer engines
- Every page max 1 click from a booking opportunity
- Mobile-first design
- Schema markup planned for key pages
