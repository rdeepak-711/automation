# Phase 2 — Site Architecture

## Goal

Produce a complete site architecture document and page manifest (TSV) from the filled blueprint.
The architecture defines every page the site will have: URL slugs, intent, primary keyword, word
count target, and monetization role.

## Inputs

| File | Description |
|---|---|
| `output/<site>/00-blueprint.md` | Filled site blueprint from Phase 1 (Step 11) |
| `prompts/playbook/01-architecture.md` | Prompt 1 — Site Architecture Generator |

The blueprint must be complete and reviewed before starting. All product catalog entries, affiliate
links, pricing, and content categories must be accurate.

## Process

1. **Open a Claude conversation** (claude.ai or any Claude interface that accepts long input).

2. **Assemble the prompt:**
   - Paste the full contents of `output/<site>/00-blueprint.md`
   - Then paste the full contents of `prompts/playbook/01-architecture.md`
   - No other text is needed — the prompt is self-contained

3. **Run the prompt.** Claude will work through 9 structured steps:
   - Topic universe (40–60 topics)
   - Keyword intent clustering (transactional / commercial / informational / editorial / utility)
   - Page hierarchy and URL structure (3-category silo: Tickets & Tours, Plan Your Visit, What to See)
   - Navigation and menu structure
   - Internal linking strategy (hub-and-spoke)
   - Content silo map
   - Technical page types (6 templates)
   - Launch roadmap (MVP → Authority → Growth)
   - Page manifest TSV block

4. **Extract the TSV block.** The output ends with a block bounded by:
   ```
   ---PAGES-TSV-START---
   title	url_slug	category	page_type	intent	primary_keyword	word_count
   ...
   ---PAGES-TSV-END---
   ```
   Copy only the content between those markers (including the header row).

5. **Save outputs:**
   ```bash
   mkdir -p output/<site>
   # Save the full architecture document
   # (paste Claude's full response into this file)
   output/<site>/01-architecture.md

   # Save the TSV block only
   config/<site>-pages.tsv
   ```

## Outputs

| File | Contents |
|---|---|
| `output/<site>/01-architecture.md` | Full architecture document (steps 1–8 + TSV) |
| `config/<site>-pages.tsv` | Tab-separated page manifest (7 columns, one row per page) |

The TSV has exactly these columns: `title`, `url_slug`, `category`, `page_type`, `intent`,
`primary_keyword`, `word_count`.

## How to Run

```bash
# Manual — paste prompt into Claude (no script yet):
cat output/<site>/00-blueprint.md
cat prompts/playbook/01-architecture.md

# Or pipe both to Claude CLI (requires claude auth login):
cat output/<site>/00-blueprint.md prompts/playbook/01-architecture.md \
  | claude --print > output/<site>/01-architecture.md

# After saving architecture, extract TSV:
sed -n '/---PAGES-TSV-START---/,/---PAGES-TSV-END---/p' output/<site>/01-architecture.md \
  | grep -v '^---' > config/<site>-pages.tsv
```

## Validation

Before proceeding to Phase 3, verify:

1. **TSV is parseable:**
   ```bash
   awk -F'\t' 'NR==1 { if (NF != 7) print "ERROR: expected 7 columns, got " NF }' config/<site>-pages.tsv
   ```

2. **Page count is reasonable:** A typical Phase 1 MVP launch is 10–15 pages; the full architecture
   is usually 30–60. If fewer than 10 rows, the architecture is too thin.

3. **All three categories are present:**
   ```bash
   cut -f3 config/<site>-pages.tsv | sort | uniq -c
   ```
   Should show rows for `Tickets & Tours`, `Plan Your Visit`, and `What to See`.

4. **Priority 1 product appears in the architecture** — check that the top affiliate product from
   the blueprint is referenced in the navigation and monetization notes.

5. **`01-architecture.md` is saved and readable** — this file is required as input for Phase 3.
