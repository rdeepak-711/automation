PROMPT 04
Design Configuration
Extract the site's design tokens from the blueprint. Output exactly 4 key-value lines — nothing else.

---

## Task

You are extracting design configuration from a Site Blueprint.

Read the blueprint provided above and output **exactly** the following 4 lines, and nothing else. No preamble, no explanation, no markdown headings — just the 4 lines:

```
ACCENT_COLOR: #XXXXXX
SITE_NAME: ...
SITE_TAGLINE: ...
SHORT_DESCRIPTION: ...
```

---

## Rules for each field

**ACCENT_COLOR**
- One hex color code including the `#` prefix (e.g. `#C41E3A`)
- Choose the single most fitting brand/accent color for the attraction
- If the blueprint suggests a brand color, use it; otherwise pick a color that fits the attraction's character (historic castles: deep red, crimson, or navy; theme parks: bold primary colors; beaches: ocean blue; art museums: warm gold or terracotta)
- This color will be used for all buttons, headings accent, price displays, and CTA elements across the site

**SITE_NAME**
- Derive from the `{Site Domain}` field in the blueprint
- Convert the domain to a human-readable name (e.g. `colosseumguide.com` → `Colosseum Guide`)
- Title case, no `.com` or hyphens

**SITE_TAGLINE**
- 10–15 words, max
- Should answer: "What does this site help the reader do?"
- Example: "Your complete guide to tickets, tours, and visiting the Colosseum"

**SHORT_DESCRIPTION**
- 1–2 sentences, max 40 words
- Describes the attraction itself (not the website)
- Start with the attraction's name
- Use the "one-line description" from the blueprint if present, otherwise derive from context

---

## Output format (exact)

Output ONLY these 4 lines. No other text before or after.

ACCENT_COLOR: #XXXXXX
SITE_NAME: Replace with site name
SITE_TAGLINE: Replace with tagline
SHORT_DESCRIPTION: Replace with short description of the attraction.
