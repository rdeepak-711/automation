# Phase 3 — Pages Plan

## Goal

Review and normalize the page manifest from Phase 2 into a prioritized generation queue.
This phase is a human review checkpoint — validate that the architecture makes sense before
spending time generating content briefs for every page.

## Inputs

| File | Description |
|---|---|
| `output/<site>/01-architecture.md` | Full architecture document from Phase 2 |
| `config/<site>-pages.tsv` | Raw page manifest (7 columns) from Phase 2 |

## Process

1. **Review the TSV.** Open `config/<site>-pages.tsv` in a spreadsheet or text editor:
   - Check URL slugs: should be lowercase, hyphenated, no trailing slashes
   - Check word counts: money pages 2,000–4,000 words; supporting pages 1,000–2,000; blog posts 1,500–2,500
   - Check intent: every Money page should be Transactional or Commercial
   - Remove duplicate slugs

2. **Prioritize for MVP launch.** Mark 10–15 pages as Phase 1 (MVP) — these will be generated and
   published first. Selection criteria:
   - Homepage (always Phase 1)
   - All Transactional / Money pages for Priority 1 and Priority 2 products
   - One pillar hub per content silo
   - 2–3 high-traffic informational pages to establish authority

3. **Add a `phase` column** to the TSV:
   ```
   title	url_slug	category	page_type	intent	primary_keyword	word_count	phase
   Colosseum Tickets	/tickets/	Tickets & Tours	Money	Transactional	colosseum tickets	2500-3500	1
   ...
   ```

4. **Save the normalized manifest:**
   ```bash
   config/<site>-pages-normalized.tsv
   ```
   This file is the generation queue for Phase 5.

## Outputs

| File | Contents |
|---|---|
| `config/<site>-pages-normalized.tsv` | Normalized page manifest with `phase` column |

The normalized TSV has 8 columns: the original 7 plus `phase` (integer: 1 = MVP, 2 = Authority,
3 = Growth).

## How to Run

This phase is currently a manual review step — no script. Open the TSV, apply the criteria above,
and save the updated file.

```bash
# View the raw manifest:
column -t -s $'\t' config/<site>-pages.tsv | less

# Count pages by category:
awk -F'\t' 'NR>1 { print $3 }' config/<site>-pages.tsv | sort | uniq -c | sort -rn

# Count pages by page_type:
awk -F'\t' 'NR>1 { print $4 }' config/<site>-pages.tsv | sort | uniq -c | sort -rn
```

## Validation

Before proceeding to Phase 4, verify:

1. **No duplicate slugs:**
   ```bash
   awk -F'\t' 'NR>1 { print $2 }' config/<site>-pages-normalized.tsv | sort | uniq -d
   ```
   Should return no output.

2. **Phase 1 count is 10–15:**
   ```bash
   awk -F'\t' 'NR>1 && $8=="1"' config/<site>-pages-normalized.tsv | wc -l
   ```

3. **Homepage is present** with slug `/` or `/home/`.

4. **All Money pages have Transactional or Commercial intent** (no Money page with Informational intent).

5. **Normalized TSV is saved** at `config/<site>-pages-normalized.tsv` — this is required input for Phase 5.
