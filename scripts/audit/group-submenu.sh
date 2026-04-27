#!/usr/bin/env bash
# Submenu Grouping Derivation — Claude AI decides groupings
# Consumes:
#   output/audit/01-inventory-<hostname>.json  — article data
#   input/<site-slug>/tickets.md               — raw ticket products
# Calls Claude with all titles+descriptions → Claude returns JSON groupings
# Output: output/audit/submenu-<hostname>.json + .md
# Usage: ./group-submenu.sh [hostname]

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

HOSTNAME="${1:-topkapipalace-guide.com}"
INVENTORY="$(save_output "01-inventory" "$HOSTNAME" "json")"
OUT_JSON="$(save_output "submenu" "$HOSTNAME" "json")"
OUT_MD="$(save_output "submenu"  "$HOSTNAME" "md")"
AI_ENGINE="${AI_ENGINE:-claude}"

[[ ! -f "$INVENTORY" ]] && echo "Run 01-page-inventory.sh first: $INVENTORY not found" >&2 && exit 1

# Resolve hostname → input folder slug
resolve_input_slug() {
  case "$1" in
    topkapipalace-guide.com)   echo "topkapi-palace" ;;
    bluemosque-guide.com)      echo "blue-mosque" ;;
    hagiasophia-guide.com)     echo "hagia-sofia" ;;
    montsaintmichel-guide.com) echo "mont-saint-michel" ;;
    vangoghmuseum-guide.com)   echo "van-gogh" ;;
    plitvicelakes-guide.com)   echo "plitvice-lakes" ;;
    angkorwat-guide.com)       echo "angkor-wat" ;;
    *) echo "" ;;
  esac
}

INPUT_SLUG="$(resolve_input_slug "$HOSTNAME")"
TICKETS_MD=""
if [[ -n "$INPUT_SLUG" ]]; then
  CANDIDATE="$(dirname "$0")/../../input/${INPUT_SLUG}/tickets.md"
  [[ -f "$CANDIDATE" ]] && TICKETS_MD="$(realpath "$CANDIDATE")"
fi

[[ -z "$TICKETS_MD" ]] && echo "Warning: tickets.md not found for $HOSTNAME — skipping ticket grouping" >&2

# Build combined prompt: articles (all silos) + raw tickets
PROMPT=$(python3 - "$INVENTORY" "$HOSTNAME" "${TICKETS_MD:-}" <<'PYEOF'
import sys, json, re

inv_path, hostname, tickets_path = sys.argv[1], sys.argv[2], sys.argv[3]
data   = json.load(open(inv_path))
posts  = data['posts']

# --- Articles by silo ---
silos = {}
for p in posts:
    for cat in p['category']:
        silos.setdefault(cat, []).append(p)

silo_labels = {
    'tickets':         'Tickets & Tours',
    'plan-your-visit': 'Plan Your Visit',
    'what-to-see':     'What to See',
}

# --- Raw tickets from tickets.md ---
raw_tickets = []
if tickets_path:
    for line in open(tickets_path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) >= 3:
            raw_tickets.append({
                'id':    parts[0],           # T1, T2 ...
                'name':  parts[1],           # human name
                'url':   parts[2],           # affiliate URL
                'platform': parts[3] if len(parts) > 3 else '',
                'slug':  parts[4] if len(parts) > 4 else '',
            })

lines = []
lines.append(f"Site: {hostname}")
lines.append("")
lines.append("I have a travel attraction website. Do TWO grouping tasks:")
lines.append("")
lines.append("TASK 1 — Article Silos")
lines.append("Group each silo's articles into 2–5 visitor-intent sub-groups for a nav dropdown.")
lines.append("Rules: short labels (2–4 words), group by visitor intent, no orphan groups, important first.")
lines.append("Every article must appear in exactly one group.")
lines.append("")
lines.append("TASK 2 — Buy Tickets Dropdown")
lines.append("Group the raw ticket products into 2–5 sub-groups for a 'Buy Tickets' nav dropdown.")
lines.append("Rules: same label/grouping rules. Each ticket must appear in exactly one group.")
lines.append("Group by product type (single entry, guided, combo, special etc.).")
lines.append("")
lines.append("Return ONLY valid JSON — no explanation, no extra text:")
lines.append("""```json
{
  "tickets": {
    "label": "Tickets & Tours",
    "groups": [ { "label": "Group Name", "slugs": ["slug1"] } ]
  },
  "plan-your-visit": {
    "label": "Plan Your Visit",
    "groups": [ { "label": "Group Name", "slugs": ["slug1"] } ]
  },
  "what-to-see": {
    "label": "What to See",
    "groups": [ { "label": "Group Name", "slugs": ["slug1"] } ]
  },
  "buy-tickets": {
    "label": "Buy Tickets",
    "groups": [ { "label": "Group Name", "ticket_ids": ["T1", "T2"] } ]
  }
}
```""")
lines.append("")

lines.append("## TASK 1 — Articles")
for cat_slug, cat_posts in silos.items():
    label = silo_labels.get(cat_slug, cat_slug)
    lines.append(f"### {label} ({len(cat_posts)} articles)")
    for p in cat_posts:
        lines.append(f"  - slug: {p['slug']}")
        lines.append(f"    title: {p['title']}")
        if p.get('seo_desc'):
            lines.append(f"    description: {p['seo_desc']}")
    lines.append("")

if raw_tickets:
    lines.append("## TASK 2 — Raw Ticket Products")
    for t in raw_tickets:
        lines.append(f"  - id: {t['id']}")
        lines.append(f"    name: {t['name']}")
        lines.append(f"    platform: {t['platform']}")
    lines.append("")

print('\n'.join(lines))
PYEOF
)

echo "Asking Claude to group articles + tickets for $HOSTNAME..." >&2

# Validate grouping JSON against inventory + tickets
# Prints error lines to stdout; exits 0 if valid, 1 if errors found
validate_grouping() {
  local inv_path="$1"
  local tickets_path="${2:-}"
  python3 - "$inv_path" "$tickets_path" <<'PYEOF'
import sys, json

inv_path, tickets_path = sys.argv[1], sys.argv[2]
inventory = json.load(open(inv_path))
grouping  = json.loads(sys.stdin.read())
errors    = []

# Build expected sets
silo_slugs = {}
for p in inventory['posts']:
    for cat in p['category']:
        silo_slugs.setdefault(cat, set()).add(p['slug'])

all_ticket_ids = set()
if tickets_path:
    for line in open(tickets_path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [x.strip() for x in line.split('|')]
        if len(parts) >= 3:
            all_ticket_ids.add(parts[0])

# Validate article silos
for silo_slug, silo_data in grouping.items():
    if silo_slug == 'buy-tickets':
        continue
    groups   = silo_data.get('groups', [])
    expected = silo_slugs.get(silo_slug, set())

    if len(groups) > 5:
        errors.append(f"{silo_slug}: {len(groups)} groups — max 5")
    if len(groups) < 2 and len(expected) > 1:
        errors.append(f"{silo_slug}: only {len(groups)} group — need at least 2")

    assigned = []
    for g in groups:
        label = g.get('label', '')
        slugs = g.get('slugs', [])
        wc = len(label.split())
        if wc < 2 or wc > 4:
            errors.append(f"{silo_slug}/{label!r}: label must be 2–4 words (got {wc})")
        if not slugs:
            errors.append(f"{silo_slug}/{label!r}: empty group")
        if len(slugs) == 1 and len(expected) > 4:
            errors.append(f"{silo_slug}/{label!r}: orphan group with 1 item")
        assigned.extend(slugs)

    seen = set()
    for s in assigned:
        if s in seen:
            errors.append(f"{silo_slug}: duplicate slug '{s}'")
        seen.add(s)
    missing = expected - set(assigned)
    if missing:
        errors.append(f"{silo_slug}: unassigned slugs: {', '.join(sorted(missing))}")
    extra = set(assigned) - expected
    if extra:
        errors.append(f"{silo_slug}: unknown slugs: {', '.join(sorted(extra))}")

# Validate buy-tickets
if 'buy-tickets' in grouping and all_ticket_ids:
    groups = grouping['buy-tickets'].get('groups', [])
    if len(groups) > 5:
        errors.append(f"buy-tickets: {len(groups)} groups — max 5")
    if len(groups) < 2 and len(all_ticket_ids) > 1:
        errors.append(f"buy-tickets: only {len(groups)} group — need at least 2")
    assigned = []
    for g in groups:
        label      = g.get('label', '')
        ticket_ids = g.get('ticket_ids', [])
        wc = len(label.split())
        if wc < 2 or wc > 4:
            errors.append(f"buy-tickets/{label!r}: label must be 2–4 words (got {wc})")
        if not ticket_ids:
            errors.append(f"buy-tickets/{label!r}: empty group")
        if len(ticket_ids) == 1 and len(all_ticket_ids) > 4:
            errors.append(f"buy-tickets/{label!r}: orphan group with 1 ticket")
        assigned.extend(ticket_ids)
    seen = set()
    for t in assigned:
        if t in seen:
            errors.append(f"buy-tickets: duplicate ticket_id '{t}'")
        seen.add(t)
    missing = all_ticket_ids - set(assigned)
    if missing:
        errors.append(f"buy-tickets: unassigned tickets: {', '.join(sorted(missing))}")
    extra = set(assigned) - all_ticket_ids
    if extra:
        errors.append(f"buy-tickets: unknown ticket_ids: {', '.join(sorted(extra))}")

for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PYEOF
}

# Call AI with retry loop (max 3 attempts)
MAX_RETRIES=3
ATTEMPT=0
GROUPING_JSON=""
RETRY_ERRORS=""

while [[ $ATTEMPT -lt $MAX_RETRIES ]]; do
  ATTEMPT=$((ATTEMPT + 1))

  FULL_PROMPT="$PROMPT"
  if [[ -n "$RETRY_ERRORS" ]]; then
    FULL_PROMPT="${PROMPT}

VALIDATION ERRORS from previous attempt — fix all of these and return corrected JSON:
${RETRY_ERRORS}"
    echo "Attempt $ATTEMPT (reprompting with ${#RETRY_ERRORS} chars of errors)..." >&2
  fi

  if [[ "$AI_ENGINE" == "gemini" ]]; then
    RAW_RESPONSE=$(echo "$FULL_PROMPT" | gemini --print 2>/dev/null)
  else
    RAW_RESPONSE=$(echo "$FULL_PROMPT" | claude --print 2>/dev/null)
  fi

  # Extract JSON from response (strip markdown fences if present)
  GROUPING_JSON=$(echo "$RAW_RESPONSE" | python3 -c "
import sys, re, json
raw = sys.stdin.read()
m = re.search(r'\`\`\`(?:json)?\s*(\{.*?\})\s*\`\`\`', raw, re.DOTALL)
if m:
    j = m.group(1)
else:
    m2 = re.search(r'(\{.*\})', raw, re.DOTALL)
    j = m2.group(1) if m2 else raw.strip()
parsed = json.loads(j)
print(json.dumps(parsed, indent=2, ensure_ascii=False))
") || { echo "ERROR: could not parse JSON from AI response (attempt $ATTEMPT)" >&2; continue; }

  RETRY_ERRORS=$(echo "$GROUPING_JSON" | validate_grouping "$INVENTORY" "${TICKETS_MD:-}" 2>/dev/null || true)
  if [[ -z "$RETRY_ERRORS" ]]; then
    echo "Validation passed (attempt $ATTEMPT)" >&2
    break
  else
    echo "Validation failed (attempt $ATTEMPT):" >&2
    echo "$RETRY_ERRORS" >&2
    if [[ $ATTEMPT -ge $MAX_RETRIES ]]; then
      echo "ERROR: grouping validation failed after $MAX_RETRIES attempts — aborting" >&2
      exit 1
    fi
  fi
done

# Enrich grouping JSON and write outputs
python3 - "$INVENTORY" "${TICKETS_MD:-}" "$HOSTNAME" "$OUT_JSON" "$OUT_MD" <<PYEOF
import sys, json

inv_path, tickets_path, hostname, out_json_path, out_md_path = sys.argv[1:]
inventory = json.load(open(inv_path))
grouping  = json.loads("""$GROUPING_JSON""")

# Build slug → post map
slug_map = {p['slug']: p for p in inventory['posts']}

# Build ticket id → ticket map
ticket_map = {}
if tickets_path:
    for line in open(tickets_path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) >= 3:
            tid = parts[0]
            ticket_map[tid] = {
                'id':       tid,
                'name':     parts[1],
                'url':      parts[2],
                'platform': parts[3] if len(parts) > 3 else '',
                'slug':     parts[4] if len(parts) > 4 else '',
            }

silo_labels = {
    'tickets':         'Tickets & Tours',
    'plan-your-visit': 'Plan Your Visit',
    'what-to-see':     'What to See',
    'buy-tickets':     'Buy Tickets',
}

result = {}

# Enrich article silos
for silo_slug, silo_data in grouping.items():
    if silo_slug == 'buy-tickets':
        continue
    enriched_groups = []
    for g in silo_data.get('groups', []):
        items = [slug_map[s] for s in g.get('slugs', []) if s in slug_map]
        if items:
            enriched_groups.append({'label': g['label'], 'items': [
                {'id': p['id'], 'slug': p['slug'], 'title': p['title'],
                 'image': p['image'], 'has_image': p['has_image']}
                for p in items
            ]})
    result[silo_slug] = {
        'label':  silo_labels.get(silo_slug, silo_slug),
        'total':  sum(len(g['items']) for g in enriched_groups),
        'groups': enriched_groups,
    }

# Enrich buy-tickets
if 'buy-tickets' in grouping and ticket_map:
    enriched_groups = []
    for g in grouping['buy-tickets'].get('groups', []):
        items = [ticket_map[t] for t in g.get('ticket_ids', []) if t in ticket_map]
        if items:
            enriched_groups.append({'label': g['label'], 'items': items})
    result['buy-tickets'] = {
        'label':  'Buy Tickets',
        'total':  sum(len(g['items']) for g in enriched_groups),
        'groups': enriched_groups,
    }

# Save JSON
with open(out_json_path, 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# Save markdown
with open(out_md_path, 'w') as f:
    f.write(f'# Submenu Grouping — {hostname}\n\n')

    # Articles silos
    for silo_slug in ['tickets', 'plan-your-visit', 'what-to-see']:
        if silo_slug not in result:
            continue
        silo = result[silo_slug]
        f.write(f'## {silo["label"]} ({silo["total"]} articles)\n\n')
        for g in silo['groups']:
            f.write(f'### {g["label"]} ({len(g["items"])})\n')
            for item in g['items']:
                img = '✓' if item['has_image'] else '✗'
                f.write(f'- [{img}] \`/{silo_slug}/{item["slug"]}/\` — {item["title"]}\n')
            f.write('\n')

    # Buy Tickets dropdown
    if 'buy-tickets' in result:
        bt = result['buy-tickets']
        f.write(f'## Buy Tickets ({bt["total"]} products)\n\n')
        for g in bt['groups']:
            f.write(f'### {g["label"]} ({len(g["items"])})\n')
            for item in g['items']:
                f.write(f'- {item["id"]} | {item["name"]} | {item["platform"]} | {item["url"]}\n')
            f.write('\n')

# Print summary
for silo_slug, silo in result.items():
    print(f'\n{silo["label"]} ({silo["total"]}):')
    for g in silo['groups']:
        print(f'  [{len(g["items"]):2d}] {g["label"]}')

print(f'\nJSON : {out_json_path}')
print(f'MD   : {out_md_path}')
PYEOF
