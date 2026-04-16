# Phase 5 — Content + Draft Publish

## Goal

Generate content briefs and full articles for every page in the Phase 1 manifest, then publish
them to WordPress as drafts. At the end of this phase, the site has all MVP pages in WordPress
ready for final review and go-live.

## Inputs

| File | Description |
|---|---|
| `output/<site>/00-blueprint.md` | Master reference for all affiliate products and rules |
| `output/<site>/01-architecture.md` | Full architecture (internal linking targets, page structure) |
| `config/<site>-pages-normalized.tsv` | Prioritized page manifest (Phase 3 output) |
| `prompts/playbook/02-content-brief.md` | Prompt 2 — Content Brief Generator |
| `prompts/playbook/03-content-writer.md` | Prompt 3 — Content Writer |
| `.env` | Active WordPress credentials |

## Process

Run once per page, in priority order (Phase 1 pages first).

### Step A — Generate a content brief (Prompt 2)

For each page in the manifest:

1. **Assemble the brief prompt:**
   - Paste `output/<site>/00-blueprint.md` (master reference)
   - Paste `prompts/playbook/02-content-brief.md`
   - Fill in the **Page Details** block with values from the TSV row:
     ```
     Page Title:       {title from TSV}
     URL Slug:         {url_slug from TSV}
     Content Category: {category from TSV}
     Page Type:        {page_type from TSV}
     Search Intent:    {intent from TSV}
     Primary Keyword:  {primary_keyword from TSV}
     Target Word Count:{word_count from TSV}
     Internal Pages on Site: [list all slugs from TSV]
     ```

2. **Run the prompt** in Claude. Save the output:
   ```
   output/<site>/02-briefs/<url_slug_with_slashes_replaced_by_dashes>.md
   ```
   For example, slug `/tickets/` → `output/<site>/02-briefs/tickets.md`

### Step B — Write the article (Prompt 3)

For each page brief:

1. **Assemble the writer prompt:**
   - Paste `output/<site>/00-blueprint.md`
   - Paste `prompts/playbook/03-content-writer.md`
   - Paste the full content brief from Step A

2. **Run the prompt** in Claude. Save the output:
   ```
   output/<site>/03-articles/<slug>.md
   ```

3. **Review writer's notes.** Each article ends with a `WRITER'S NOTES` section listing
   `[VERIFY]` items — facts that need manual confirmation before publishing.

### Step C — Publish draft to WordPress (REST API)

For each completed article:

```bash
# Set variables
SLUG="tickets"  # matches TSV url_slug without leading slash
ARTICLE_FILE="output/<site>/03-articles/${SLUG}.md"
TITLE=$(head -1 "$ARTICLE_FILE" | sed 's/^# //')

# Convert Markdown → HTML (requires pandoc)
CONTENT_HTML=$(pandoc "$ARTICLE_FILE" -f markdown -t html 2>/dev/null)

# Create WordPress draft via REST API
curl -s -X POST \
  --connect-timeout 10 --max-time 60 \
  -u "$WP_USER:$WP_PASS" \
  -H "Content-Type: application/json" \
  -d "{
    \"title\":   \"$TITLE\",
    \"slug\":    \"${SLUG}\",
    \"content\": $(python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' <<< "$CONTENT_HTML"),
    \"status\":  \"draft\"
  }" \
  "$WP_SITE_URL/wp-json/wp/v2/pages"
```

For blog posts, use `/wp-json/wp/v2/posts` and add `"categories"` as appropriate.

## Outputs

| Path | Contents |
|---|---|
| `output/<site>/02-briefs/<slug>.md` | Content brief — one per page |
| `output/<site>/03-articles/<slug>.md` | Full article in Markdown — one per page |
| WordPress drafts | All pages/posts created as drafts via REST API |

## How to Run

```bash
# List Phase 1 pages to process:
awk -F'\t' 'NR>1 && $8=="1" { print $2 "\t" $1 }' config/<site>-pages-normalized.tsv

# Verify WP REST API is accessible before batch run:
curl -s --connect-timeout 10 \
  -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/users/me" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','AUTH FAILED'))"

# Check existing drafts on site:
curl -s -u "$WP_USER:$WP_PASS" \
  "$WP_SITE_URL/wp-json/wp/v2/pages?status=draft&per_page=100" \
  | python3 -c "import sys,json; [print(p['slug']) for p in json.load(sys.stdin)]"
```

## Validation

After all Phase 1 pages are published as drafts:

1. **Draft count matches Phase 1 TSV count:**
   ```bash
   curl -s -u "$WP_USER:$WP_PASS" \
     "$WP_SITE_URL/wp-json/wp/v2/pages?status=draft&per_page=100" \
     | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'drafts')"
   ```

2. **No `[VERIFY]` items remain unresolved** — review `WRITER'S NOTES` in each article file
   and confirm or correct any flagged facts.

3. **All affiliate links are correct** — spot-check 3–5 articles; confirm product URLs and
   prices match the blueprint's Product Catalog.

4. **Internal links resolve** — every internal link target (`/tickets/`, `/plan/`, etc.) must
   exist as a draft or published page. Missing targets will return 404 after publish.

5. **SEO meta tags are present** — each article file includes a `META TAGS` section with
   `title` (55–60 chars) and `meta description` (150–155 chars). Enter these in WordPress
   via Rank Math (SEO → Meta) for each page.

6. **Search engine visibility still OFF** — `Settings → Reading` should still discourage
   indexing until you do a final review and flip to "allow indexing" at go-live.

## Go-Live Checklist

When ready to publish:

- [ ] All `[VERIFY]` items resolved
- [ ] Affiliate links live and correct
- [ ] Meta titles and descriptions entered in Rank Math for every page
- [ ] Images uploaded and alt text set
- [ ] Internal links tested
- [ ] Mobile preview checked
- [ ] `Settings → Reading → Search Engine Visibility` unchecked (allow indexing)
- [ ] All drafts set to Published
- [ ] Sitemap submitted to Google Search Console
