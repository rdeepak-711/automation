# Prompt 2 — Content Brief Generator

**PREREQUISITE:** Paste your filled `00-blueprint.md` above this prompt. Then add the Page Details below from your Prompt 1 output.

---

PROMPT 2
Content Brief Generator
Generate a production-ready content brief for any page from your site architecture. Run once per page.

PREREQUISITE: Paste your filled Prompt 0 (Site Blueprint) above this prompt. Then add the page details below from your Prompt 1 output.

Page Details (from Architecture)
{Page Title (H1)}  e.g., Colosseum Tickets: Prices, Discounts & How to Book in 2026
{URL Slug}  e.g., /tickets/
{Content Category}  Tickets & Tours / Plan Your Visit / What to See
{Page Type}  Money / Hub / Supporting / Comparison / Blog
{Search Intent}  Transactional / Commercial / Informational
{Primary Keyword}  e.g., colosseum tickets
{Target Word Count}  e.g., 2,500 - 3,500 words
{Internal Pages on Site}  List all pages from architecture

Sections to Generate
1. Keyword Strategy (primary, secondary, LSI, long-tail questions). 2. SERP & Competitor Analysis (landscape, top 5 pages, content gaps). 3. Detailed Content Outline (section-by-section with affiliate product placements from the Product Catalog). 4. AEO Answer Blocks (5-8 blocks). 5. Affiliate Integration Map (using specific products from the Catalog, following Display Rules). 6. Internal Linking Plan. 7. Technical SEO (schema, meta tags, images). 8. Quality Checklists.

CRITICAL: The Affiliate Integration Map must reference specific products from the Product Catalog by name, with correct prices and links. The Display Rules in the Blueprint govern CTA placement, comparison tables, and contextual links.

---

## Required Brief Sections (for automated HTML generation)

Every content brief must include these sections in addition to the above:

### AEO Answer Blocks
Generate 5-8 Q&A blocks specifically formatted for AI answer engines (Google AI Overview, Perplexity, ChatGPT). Each block must:
- Contain a single focused question phrased as a traveler would ask it
- Answer in 2-3 sentences that are SELF-CONTAINED (readable without surrounding context)
- Include one specific data point (price, time, measurement, date)
- Be written as if answering a voice assistant query

### Quick Facts Box
A scannable TL;DR box with 5-7 rows — content adapts by category:
- **tickets-and-tours**: Price / Duration / Booking platform / Cancellation policy / Audio guide / Auditorium access
- **plan-your-visit**: Opening hours / Last entry / Closed on / Best season / Best time of day / Address / Metro stop
- **what-to-see**: Location in building / Ticket required / Photography allowed / Best time / Duration to allow / Highlight detail

### Category Table
Adapts by article type:
- **tickets-and-tours**: Price table with Visitor Type / Price / Notes columns (adult, child, concession, free tiers)
- **plan-your-visit**: Seasonal hours table with Season / Opening Hours / Last Entry columns
- **what-to-see**: Access table with Ticket Type / Access to This Area columns

### Practical Visit Reality
4-6 bullet points covering logistical details visitors need on the day:
- Nearest Metro/tube stop and walking time
- Photography rules for this specific space
- Dress code or entry requirements (if any)
- Bag/cloakroom policy
- Arrival timing recommendation
- What to do if unexpectedly closed or sold out

### Insider Tip / Urgency Block
One specific, actionable insider tip — NOT generic advice. Must include:
- A concrete workaround for the most common pain point (sold out, long queue, unexpected closure)
- A specific timing recommendation (day of week, time of day, season)
- For tickets: when slots sell out and when to check for availability

### FAQ Section
5-7 long-tail question-and-answer pairs targeting specific search queries. Questions adapt by category:
- **tickets-and-tours**: "Can I get a refund?", "Do I need to print my ticket?", "Is the auditorium included?"
- **plan-your-visit**: "Is Opera Garnier open on Sundays?", "What time is least crowded?", "Is it closed for performances?"
- **what-to-see**: "Can I photograph [specific space]?", "How long should I spend here?", "Is it accessible?"
Each FAQ answer must include FAQPage JSON-LD schema markup.

### Internal Linking Plan
List 4-6 specific internal pages to link from this article (from the site architecture):
- ALWAYS include: one link to the relevant hub page (/tickets-and-tours/, /plan-your-visit/, or /what-to-see/)
- PLUS: 3-5 links to related L2 articles from adjacent silos
- Specify the anchor text for each link — use secondary keywords, not generic phrases like "click here"

### Link Attribute Map
Two distinct lists:
1. **Internal links** (dofollow, same tab): list each page URL and anchor text — no rel attribute, no target="_blank"
2. **Affiliate links** (nofollow + sponsored, new tab): list each booking URL with rel="nofollow sponsored" target="_blank" and price in anchor text or adjacent
NEVER mix — internal links must never have nofollow or open in a new tab.
