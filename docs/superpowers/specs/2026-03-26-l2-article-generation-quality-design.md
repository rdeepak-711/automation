# Design Spec: L2 Article Generation Quality System (2026-03-26)

> Supersedes: `2026-03-26-tickets-article-generation-improvement-design.md`

## 1. Objective

Make L2 article generation reliable and consistent regardless of AI engine (Claude, Gemini, or
future engines). The core problem is that long prompts with rules buried after context cause AI
models to forget or deprioritize prohibitions. The solution is a layered defence: prompt
restructure, context trimming, and a post-process validator.

---

## 2. Files Changed

| File | Change |
|---|---|
| `scripts/content/generate-l2-articles.sh` | Prompt restructure + context trimming |
| `scripts/content/validate-article.sh` | New — post-process validator |
| `docs/Four Pages/attraction-individual-article-template.html` | No changes — already correct |

---

## 3. Prompt Restructure

### 3.1 New Prompt Order

Rules always appear before context. The AI reads and weights early tokens more heavily — putting
prohibitions first makes them stick regardless of engine.

```
SECTION 1: HARD RULES       (~400 tokens, numbered one-liners)
SECTION 2: ARTICLE METADATA (title, url, category, keyword, word_count)
SECTION 3: TICKET DATA      (filtered blueprint — matching products only)
SECTION 4: LINK MANIFEST    (TSV: title | URL — for internal linking only)
SECTION 5: TEMPLATE         (the HTML template to populate)
```

### 3.2 Hard Rules Block (verbatim in prompt)

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HARD RULES — read before everything else
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CONTENT
1. Write ONLY about the specific ticket/tour named in Article Metadata. No unrelated content.
2. DO NOT include: Quick Facts box, "Where to Buy" section, "last verified" footer,
   any disclaimer about checking the official site, any comparison to other tickets.
3. BANNED brand names everywhere (body, labels, CTAs, alt text, comments):
   GetYourGuide, Tiqets, Viator. Use "book this ticket" or "check availability."
4. AEO blocks: direct answer text only. No "Q:", no question text, no prefix of any kind.
5. Price table: only the specific ticket/tour being written about with its confirmed euro price.
   BANNED rows: "Reduced", "Concession", "Student", "Verify on site", "Confirm in advance",
   "See official site", or any row without a confirmed fixed euro price.

STRUCTURE — produce sections in this exact order, nothing added, nothing removed:
6.  AEO answer block (.att-aeo-block)
7.  Introduction — exactly 2 paragraphs (80–100 words each, zero repetition between them)
8.  Ticket Options bar (.att-top-tickets) — label: "Ticket Options"
9.  Body H2 sections with inline AEO blocks on question-phrased H2s
10. Primary CTA button (.att-buy-now-btn, text: "Buy this ticket") — exactly once
11. Insider Tip box (.att-tip-box) — immediately after the CTA button
12. Practical Visit Reality box (.att-visit-reality)
13. Closing H2 + 1–2 paragraphs + final affiliate CTA
14. FAQ section (.att-faq) — <details>/<summary> pattern only
15. FAQPage JSON-LD schema block
16. Related Articles (.att-related) — plain text links, no pills, no borders

LINKS
17. Internal links (pages on this site): no rel attribute, same tab, dofollow. 4–6 per article,
    spread through body sections. May link to hub pages (/tickets/, /plan-your-visit/, /what-to-see/).
18. Affiliate/ticket links: rel="nofollow sponsored", target="_blank". Max 3 per article.
    Price in or next to anchor text: "Book entry ticket (€25)".
19. NEVER mention a booking platform name in body text or near a link.

SEO / AEO / GEO
20. Primary keyword in H1, first 100 words, one H2, 3–5× in body.
21. Weave LSI/secondary keywords naturally throughout (do not list them separately).
22. Every .att-aeo-block must be self-contained: readable without surrounding context,
    no pronouns referring elsewhere, answers ONE question in sentence 1 with a specific data point.
23. Every factual claim: specific enough to cite ("€25 as of March 2026", not "around €20").
24. At the very top of output add HTML comments:
    <!-- META TITLE: [55–60 char] -->
    <!-- META DESC: [150–155 char with primary keyword + specific fact] -->

OUTPUT
25. Complete standalone HTML only. No markdown fences, no explanation, no preamble.
    Start with <!-- META TITLE comment. End with closing </div> of .att-article-page.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. Context Trimming

### 4.1 Blueprint → Filtered Ticket Data

**Problem:** The full blueprint is injected regardless of which ticket is being written. The AI
attends to all products equally, causing cross-contamination (wrong prices, wrong inclusions).

**Fix:** Extract only the product block(s) relevant to the current article. Use the article's
`$primary_keyword` and `$category` to grep the blueprint for matching sections. Pass the
extracted block under the heading "## Product Data for This Article".

If no matching block is found, fall back to passing the full products section of the blueprint
(not the entire file).

### 4.2 Architecture → TSV Link Manifest Only

**Problem:** The full architecture prose document is injected for internal linking. The AI doesn't
need the strategic rationale — only page titles and URLs.

**Fix:** Extract the TSV lines between `---PAGES-TSV-START---` and `---PAGES-TSV-END---` markers
(the same extraction already used to save `config/$SITE_SLUG-pages.tsv`). Pass this two-column
table under the heading "## Internal Link Manifest (title | url)".

This reduces architecture context by ~70%.

---

## 5. Post-Process Validator

### 5.1 New File: `scripts/content/validate-article.sh`

Called automatically after each article is saved in `generate-l2-articles.sh`.

**Usage:**
```bash
./scripts/content/validate-article.sh <html-file>
# Returns exit 0 if clean, exit 1 if any warnings found
# Prints per-check result to stdout
```

### 5.2 Checks

| ID | Check | Pattern / Method |
|---|---|---|
| V1 | Brand name leak | `grep -qi "getyourguide\|tiqets\|viator"` |
| V2 | Q: prefix in AEO block | `grep -qi 'class="att-aeo-block__a"[^<]*Q:'` |
| V3 | Quick facts component | `grep -qi 'att-quick-facts\|quick.facts'` |
| V4 | Last-verified footer | `grep -qi 'last verified\|always check the official'` |
| V5 | Where-to-buy section | `grep -qi 'where to buy'` |
| V6 | Missing buy-now button | absence of `att-buy-now-btn` |
| V7 | Missing FAQ accordion | absence of `att-faq-details` |
| V8 | Missing AEO block | absence of `att-aeo-block` |
| V9 | Unconfirmed price rows | `grep -qi 'verify on site\|confirm in advance\|see official'` |

### 5.3 Run Summary

At the end of the full `generate-l2-articles.sh` run, print:

```
═══════════════════════════════════════
  VALIDATION SUMMARY
═══════════════════════════════════════
  ✓  tickets-and-tours/opera-garnier-entry-ticket.html
  ✗  tickets-and-tours/self-guided-tour-ticket.html
       → V1: brand name detected
       → V6: missing buy-now button
  ✓  plan-your-visit/opening-hours.html
═══════════════════════════════════════
  1 article(s) need review. Delete and re-run to regenerate.
═══════════════════════════════════════
```

Validator never auto-fixes. Re-running is idempotent — delete the file and re-run.

---

## 6. Sample-First Workflow

Before running a full batch, always validate with `--sample` first:

```bash
# Test 1 article per silo (3 total)
./scripts/content/generate-l2-articles.sh opera-garnier --sample --engine gemini

# Review output + validation summary
# If clean → run full batch
./scripts/content/generate-l2-articles.sh opera-garnier --engine gemini
```

This catches engine-specific drift (Gemini vs Claude often behave differently with the same
prompt) before committing to a full 22-article run.

---

## 7. Template — No Changes

`docs/Four Pages/attraction-individual-article-template.html` is already correct:
- `<details>`/`<summary>` FAQ accordion ✓
- `.att-buy-now-btn` above insider tip ✓
- "Ticket Options" label on top-tickets bar ✓
- Text-only related links (no pills) ✓
- No `.att-quick-facts` component ✓
- No last-verified footer ✓
- AEO block with no question field ✓

The template is the strongest structural guardrail. Keep it clean — never add placeholder
components for things you don't want the AI to generate.

---

## 8. Article Content Rules (Category-Specific)

### tickets-and-tours
- Price table columns: Visitor Type | Price | Notes
- Only confirmed adult price rows (and any other tier with a fixed euro amount in the blueprint)
- Insider Tip: sold-out workaround (specific day/time to check or book)
- Practical Reality bullets: Metro stop + line + walk time, timed entry rules, photography, bags/cloakroom, dress code, ID check, arrival timing

### plan-your-visit
- Price table columns: Season/Period | Hours | Last Entry
- Insider Tip: best day+time combo or what to do if unexpectedly closed
- Practical Reality bullets: Metro, photography, nearby alternatives, what to do if closed

### what-to-see
- Price table columns: Ticket Type | Access to This Area
- Insider Tip: least-crowded time for this space OR hidden detail most visitors miss
- Practical Reality bullets: exactly where in building (floor/wing), how to find it, what to look for

---

## 9. Success Criteria

- [ ] Generated articles contain zero mentions of GetYourGuide, Tiqets, or Viator
- [ ] AEO blocks start directly with the answer (no Q: prefix)
- [ ] Price tables contain only definitive, fixed-price rows for the specific ticket
- [ ] "Buy this ticket" button appears exactly once, above the Insider Tip
- [ ] FAQ items expand/collapse correctly without JavaScript
- [ ] Related links are plain text (no pill styling, no borders)
- [ ] 4–6 internal links per article, dofollow, same tab
- [ ] All affiliate links: nofollow sponsored, new tab, max 3 per article
- [ ] No Quick Facts box in any generated article
- [ ] No last-verified footer in any generated article
- [ ] Validator runs automatically and prints a summary after each batch
- [ ] `--sample` run produces clean output before full batch is approved
