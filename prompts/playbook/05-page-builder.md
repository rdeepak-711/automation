PROMPT 05
Page Content Builder
Generate structured page content data as Markdown files. Each chapter produces one output file.

The blueprint, architecture, and design config are provided above. Use them as the authoritative source for all attraction details: products, prices, links, categories, and brand voice.

---

## GLOBAL RULES — Apply to Every Chapter

### Campaign IDs
The campaign identifier for this site is "og". Format: `og-{page}-{product-slug}`.
- `{page}` = the page where the link appears: `home`, `tickets`, `plan-your-visit`, `what-to-see`
- `{product-slug}` = kebab-case slug of the specific ticket/product being linked to
- For general CTA banners with no specific product: use `og-{page}` (no product slug)

Examples:
- Entry ticket link on homepage: `&cmp=og-home-entry-ticket`
- Guided tour link on tickets page: `&cmp=og-tickets-guided-tour`
- General CTA on plan-your-visit page: `&cmp=og-plan-your-visit`
- Private tour link on what-to-see page: `&cmp=og-what-to-see-private-tour`

Base GYG URL (always use this; append campaign ID at end — no space):
`https://www.getyourguide.com/s/?q=Paris&lc=16&et=81297&searchSource=3&src=search_bar?partner_id=9BAL9K3&cmp=`

### CTA Banner
Every `## CTA Banner` section must use the full GYG base URL + campaign ID as the `button_url`.
- Use `og-{page}` for the banner (general CTA, no product slug).
- The banner is a prominent red box — write a strong conversion-focused headline (e.g. "Book Opera Garnier Tickets") and short supporting text (1 sentence).

---

## General Rules

- Output ONLY the Markdown content for the requested chapter — no preamble, no explanation
- Use exact product names, prices, and links from the blueprint
- Do not invent ticket prices or URLs — use what the blueprint provides or write `[price TBC]` / `[link TBC]` if missing
- Every FAQ answer must be a complete sentence (≥ 2 sentences), useful and specific to this attraction
- Emoji icons: use relevant emoji for tip icons, category icons, and section icons
- All headings must use `##` (level 2) for section names within the file

---

## CHAPTER A — homepage.md

Generate content data for the **Homepage (L0)**.

### ## Hero

```
headline: [8–12 word headline for the attraction homepage]
subtext: [20–30 word supporting sentence — what visitors will find on this site]
cta_primary_text: [button text, e.g. "See Ticket Options"]
cta_primary_url: [link to tickets page — use /tickets-tours/ as relative URL]
cta_secondary_text: [button text, e.g. "Plan Your Visit"]
cta_secondary_url: [link to plan page — use /plan-your-visit/ as relative URL]
```

### ## Category Cards

3 cards — one per navigation category (Tickets & Tours, Plan Your Visit, What to See).

```
card_1_title: Tickets & Tours
card_1_icon: 🎟️
card_1_blurb: [1 sentence describing what the visitor finds in this section]
card_1_url: /tickets-tours/

card_2_title: Plan Your Visit
card_2_icon: 🗺️
card_2_blurb: [1 sentence]
card_2_url: /plan-your-visit/

card_3_title: What to See
card_3_icon: 👁️
card_3_blurb: [1 sentence]
card_3_url: /what-to-see/
```

### ## Featured Products

List the top 3 products/ticket types from the blueprint. Use the exact names and prices.

For each product:
```
product_N_name: [exact name from blueprint]
product_N_price: [e.g. £35 / from £22]
product_N_badge: [one of: Most Popular | Best Value | Skip the Line | Premium | Guided Tour | Family Pick | Combo Deal]
product_N_link: [booking URL from blueprint, or [link TBC] if not provided]
product_N_bullets:
  - [benefit 1 — 8 words max]
  - [benefit 2 — 8 words max]
  - [benefit 3 — 8 words max]
product_N_cta_primary: Book Now
product_N_cta_secondary: See Details
```

### ## Trust Strip

```
trust_text: [1 sentence about why visitors trust this guide — e.g. "Updated for 2026 with verified prices, skip-the-line tips, and firsthand visiting advice."]
stat_1_number: [e.g. 2M+]
stat_1_label: [e.g. annual visitors]
stat_2_number: [e.g. 12th century]
stat_2_label: [e.g. founded]
stat_3_number: [e.g. 4.5★]
stat_3_label: [e.g. visitor rating]
```

### ## Tips (Things to Know)

5 practical tips for first-time visitors.

```
tip_1_icon: ⏰
tip_1_title: [tip title — 4 words max]
tip_1_text: [1–2 sentences, practical advice]

[repeat for tip_2 through tip_5 with different icons]
```

### ## FAQ

5 question-answer pairs for the homepage.

```
faq_1_q: [question]
faq_1_a: [answer — 2–4 sentences, specific and helpful]

[repeat for faq_2 through faq_5]
```

### ## CTA Banner

```
cta_banner_headline: [8–12 words encouraging visitors to book]
cta_banner_subtext: [1 sentence, 15–20 words]
cta_banner_button_text: [e.g. "See All Ticket Options"]
cta_banner_button_url: /tickets-tours/
```

---

## CHAPTER B — tickets.md

Generate content data for the **Tickets & Tours (L1)** page.

### ## Hero

```
headline: [headline for the tickets page — 8–12 words]
subtext: [20–30 words describing what's covered on this page]
badge_text: [e.g. "Updated for 2026"]
```

### ## Intro

```
intro: [2–3 sentences introducing the ticket landscape for this attraction. What types are available? What should visitors know before buying?]
```

### ## Products

List ALL products/ticket types from the blueprint (not just top 3). For each:

```
product_N_name: [exact name]
product_N_price: [price]
product_N_badge: [Most Popular | Best Value | Skip the Line | Premium | Guided Tour | Family Pick | Combo Deal]
product_N_link: [URL or [link TBC]]
product_N_bullets:
  - [bullet 1]
  - [bullet 2]
  - [bullet 3]
  - [bullet 4]
product_N_cta_primary: Book Now
product_N_cta_secondary: See Details
product_N_meta_duration: [e.g. "2–3 hours"]
product_N_meta_group: [e.g. "All ages" or "Adults only"]
```

### ## Comparison Table

Create a comparison table for the top 4–5 products.

```
compare_columns: [Name | Price | Skip Line | Duration | Guided | Best For]
compare_row_N: [product name | price | ✓ or — | duration | ✓ or — | who it's best for]
```

### ## Decision Guide

2 guide cards helping visitors choose.

```
guide_1_title: [e.g. "First-time visitor?"]
guide_1_body: [2–3 sentences of advice]
guide_1_bullets:
  - [advice point 1]
  - [advice point 2]
  - [advice point 3]

guide_2_title: [e.g. "On a tight schedule?"]
guide_2_body: [2–3 sentences]
guide_2_bullets:
  - [point 1]
  - [point 2]
  - [point 3]
```

### ## Tips

5 tips for buying tickets and avoiding common mistakes.

```
tip_1_icon: 🎟️
tip_1_title: [4 words max]
tip_1_text: [1–2 sentences]

[repeat for tip_2 through tip_5]
```

### ## FAQ

8 ticket-specific FAQ pairs.

```
faq_1_q: [question]
faq_1_a: [answer — 2–4 sentences]

[repeat for faq_2 through faq_8]
```

### ## CTA Banner

```
cta_banner_headline: [headline]
cta_banner_subtext: [1 sentence]
cta_banner_button_text: [button text]
cta_banner_button_url: [booking URL for top product, or /tickets-tours/]
```

### ## Cross-Links

2 cross-link cards to Plan Your Visit and What to See.

```
crosslink_1_title: Plan Your Visit
crosslink_1_desc: [1 sentence]
crosslink_1_url: /plan-your-visit/
crosslink_1_link_text: See tips →

crosslink_2_title: What to See
crosslink_2_desc: [1 sentence]
crosslink_2_url: /what-to-see/
crosslink_2_link_text: Explore highlights →
```

## ARTICLES GRID

From the architecture TSV provided above, extract ALL pages with category `tickets-and-tours` that are NOT the L1 hub (i.e. exclude the row whose url_slug is exactly `/tickets/`). For each L2 article, output one block:

```
### Article N
- title: (exact title from TSV)
- url: (exact url_slug from TSV)
- tag: (1–2 word label, e.g. "Entry Ticket", "Guided Tour", "Skip the Line", "Private Tour", "Combo")
- desc: (2 sentences describing what this article covers and why it's useful)
```

---

## CHAPTER C — plan-your-visit.md

Generate content data for the **Plan Your Visit (L1)** page.

### ## Hero

```
headline: [8–12 word headline]
subtext: [20–30 words]
badge_text: [e.g. "2026 Visitor Guide"]
```

### ## Intro

```
intro: [2–3 sentences overview of what visitors need to know before going]
```

### ## Visit Info

Key practical information, structured for the info cards section.

```
info_hours_title: Opening Hours
info_hours_icon: 🕐
info_hours_lines:
  - [line 1, e.g. "Daily: 9:30am – 6:00pm (Apr–Sep)"]
  - [line 2, e.g. "Daily: 9:30am – 5:00pm (Oct–Mar)"]
  - [line 3, e.g. "Last entry 1 hour before closing"]
info_hours_note: [any important note about closures or exceptions]

info_getting_there_title: Getting There
info_getting_there_icon: 🚌
info_getting_there_lines:
  - [e.g. "Bus: Routes 23, 27, 41, 42 stop nearby"]
  - [e.g. "Walk: 15 min from Rome Termini station"]
  - [e.g. "Car: Limited parking — public car parks nearby"]
info_getting_there_note: [e.g. "No on-site parking. Public transport recommended."]

info_prices_title: Admission Prices
info_prices_icon: 💷
info_prices_lines:
  - [e.g. "Adults: from £35"]
  - [e.g. "Children (5–15): from £22"]
  - [e.g. "Under 5s: Free"]
info_prices_note: [e.g. "Book online to save up to 10%."]

info_address_title: Address & Map
info_address_icon: 📍
info_address_lines:
  - [street address]
  - [city, postcode]
info_address_note: [e.g. "Follow signs for 'The Royal Mile' — castle is visible from most of the city centre."]
```

### ## Best Time to Visit

```
best_time_intro: [1–2 sentences about the general visit timing landscape]

time_1_label: [e.g. "Early Morning (9:30–11am)"]
time_1_icon: 🌅
time_1_pros:
  - [pro 1]
  - [pro 2]
time_1_cons:
  - [con 1]

time_2_label: [e.g. "Midday (11am–2pm)"]
time_2_icon: ☀️
time_2_pros:
  - [pro 1]
time_2_cons:
  - [con 1]
  - [con 2]

time_3_label: [e.g. "Late Afternoon (2–5pm)"]
time_3_icon: 🌇
time_3_pros:
  - [pro 1]
  - [pro 2]
time_3_cons:
  - [con 1]
```

### ## Tips

6 practical visitor tips.

```
tip_1_icon: 🧥
tip_1_title: [4 words max]
tip_1_text: [1–2 sentences]

[repeat for tip_2 through tip_6]
```

### ## FAQ

8 planning FAQ pairs.

```
faq_1_q: [question]
faq_1_a: [answer — 2–4 sentences]

[repeat for faq_2 through faq_8]
```

### ## CTA Banner

```
cta_banner_headline: [headline]
cta_banner_subtext: [1 sentence]
cta_banner_button_text: [button text]
cta_banner_button_url: /tickets-tours/
```

### ## Cross-Links

```
crosslink_1_title: Tickets & Tours
crosslink_1_desc: [1 sentence]
crosslink_1_url: /tickets-tours/
crosslink_1_link_text: Compare tickets →

crosslink_2_title: What to See
crosslink_2_desc: [1 sentence]
crosslink_2_url: /what-to-see/
crosslink_2_link_text: Explore highlights →
```

## ARTICLES GRID

From the architecture TSV provided above, extract ALL pages with category `plan-your-visit` that are NOT the L1 hub (i.e. exclude the row whose url_slug is exactly `/plan-your-visit/`). For each L2 article, output one block:

```
### Article N
- title: (exact title from TSV)
- url: (exact url_slug from TSV)
- tag: (1–2 word label, e.g. "Opening Hours", "Transport", "Families", "Accessibility", "Itinerary")
- desc: (2 sentences describing what this article covers and why it's useful)
```

---

## CHAPTER D — what-to-see.md

Generate content data for the **What to See (L1)** page.

### ## Hero

```
headline: [8–12 word headline]
subtext: [20–30 words]
badge_text: [e.g. "2026 Guide"]
```

### ## Intro

```
intro: [2–3 sentences setting the scene for what visitors will experience]
```

### ## Highlights

6 highlight cards — the top things to see/do at this attraction.

```
highlight_N_name: [exhibit, area, or experience name]
highlight_N_emoji: [relevant emoji]
highlight_N_body: [2–3 sentences describing it and why it's unmissable]
highlight_N_tip: [1 insider tip for visiting this specific highlight]
```

### ## Things To Do List

A structured list of activities, organized by category.

```
activity_category_1: [e.g. "Must-See Exhibits"]
activity_category_1_items:
  - [activity name]: [1-line description]
  - [activity name]: [1-line description]
  - [activity name]: [1-line description]

activity_category_2: [e.g. "Guided Experiences"]
activity_category_2_items:
  - [activity name]: [1-line description]
  - [activity name]: [1-line description]

activity_category_3: [e.g. "For Families"]
activity_category_3_items:
  - [activity name]: [1-line description]
  - [activity name]: [1-line description]
```

### ## Tips

5 tips for getting the most from the visit.

```
tip_1_icon: 📸
tip_1_title: [4 words max]
tip_1_text: [1–2 sentences]

[repeat for tip_2 through tip_5]
```

### ## FAQ

8 what-to-see FAQ pairs.

```
faq_1_q: [question]
faq_1_a: [answer — 2–4 sentences]

[repeat for faq_2 through faq_8]
```

### ## CTA Banner

```
cta_banner_headline: [headline]
cta_banner_subtext: [1 sentence]
cta_banner_button_text: [button text]
cta_banner_button_url: /tickets-tours/
```

### ## Cross-Links

```
crosslink_1_title: Tickets & Tours
crosslink_1_desc: [1 sentence]
crosslink_1_url: /tickets-tours/
crosslink_1_link_text: Compare tickets →

crosslink_2_title: Plan Your Visit
crosslink_2_desc: [1 sentence]
crosslink_2_url: /plan-your-visit/
crosslink_2_link_text: See practical tips →
```

## ARTICLES GRID

From the architecture TSV provided above, extract ALL pages with category `what-to-see` that are NOT the L1 hub (i.e. exclude the row whose url_slug is exactly `/what-to-see/`). For each L2 article, output one block:

```
### Article N
- title: (exact title from TSV)
- url: (exact url_slug from TSV)
- tag: (1–2 word label, e.g. "Highlight", "Hidden Gem", "Art", "Architecture", "History & Legend")
- desc: (2 sentences describing what this article covers and why it's useful)
```

---

## CHAPTER E — l1-shared-cards.md

Generate the cross-link card data that the 3 L1 pages use to link to each other.
This file is a shared reference — the fill script pulls from it.

### ## Cards

```
tickets_card_title: Tickets & Tours
tickets_card_desc: [1 sentence — what visitors find on the tickets page]
tickets_card_cta: Compare ticket options →
tickets_card_url: /tickets-tours/
tickets_card_icon: 🎟️

plan_card_title: Plan Your Visit
plan_card_desc: [1 sentence — what visitors find on the plan page]
plan_card_cta: See visitor tips →
plan_card_url: /plan-your-visit/
plan_card_icon: 🗺️

see_card_title: What to See
see_card_desc: [1 sentence — what visitors find on the what-to-see page]
see_card_cta: Explore highlights →
see_card_url: /what-to-see/
see_card_icon: 👁️
```
