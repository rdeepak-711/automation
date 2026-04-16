#!/usr/bin/env zsh
set -euo pipefail

# ── L1: Category Hub Page Generator ──────────────────────────────────────────
# Generates L1 category pages from a site's xlsx + l1-config.json.
# Uses the Plan Your Visit template CSS for consistent design.
#
# Usage:
#   ./scripts/content/generate-l1-pages.sh <site-slug> [--force]
#
# Requires:
#   input/<site-slug>/*.xlsx          (article data — auto-detected)
#   input/<site-slug>/l1-config.json  (page metadata, SEO, CTAs, tips)

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--force]"
  echo "Example: $0 opera-garnier"
  exit 1
fi

SITE_SLUG="$1"
shift

FORCE=false
ONLY_PAGE=""
HTML_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --only) ONLY_PAGE="$2"; shift 2 ;;
    --html-only) HTML_ONLY=true; FORCE=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Auto-detect xlsx
XLSX=$(ls "$REPO_ROOT/input/$SITE_SLUG/"*.xlsx 2>/dev/null | head -1)
CONFIG="$REPO_ROOT/input/$SITE_SLUG/l1-config.json"
TEMPLATES_DIR="$REPO_ROOT/docs/Four Pages"
OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG/l1-pages"

[[ -n "$XLSX" ]]      || { echo "Error: no .xlsx found in input/$SITE_SLUG/"; exit 1; }
[[ -f "$XLSX" ]]      || { echo "Error: xlsx not found: $XLSX"; exit 1; }

# Auto-create l1-config.json from template if missing
if [[ ! -f "$CONFIG" ]]; then
  TEMPLATE="$TEMPLATES_DIR/l1-config-template.json"
  if [[ -f "$TEMPLATE" ]]; then
    cp "$TEMPLATE" "$CONFIG"
    echo "  Created l1-config.json from template at: $CONFIG"
    echo "  ⚠ Edit l1-config.json with your site details before continuing."
    echo "  Replace: DOMAIN, ATTRACTION_NAME, LOCATION, PREFIX, TICKET_URL"
    exit 1
  else
    echo "Error: l1-config.json not found: $CONFIG"; exit 1
  fi
fi
[[ -d "$TEMPLATES_DIR" ]] || { echo "Error: templates dir not found: $TEMPLATES_DIR"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# Read page slugs from config to check skip condition
PAGE_SLUGS=$(python3 -c "
import json
cfg = json.load(open('$CONFIG'))
for p in cfg['pages'].values():
    print(p['slug'])
")

if [[ "$FORCE" == "false" ]]; then
  ALL_EXIST=true
  while IFS= read -r slug; do
    [[ -f "$OUTPUT_DIR/$slug.html" ]] || { ALL_EXIST=false; break; }
  done <<< "$PAGE_SLUGS"
  if $ALL_EXIST; then
    echo "  All L1 pages already exist. Use --force to regenerate."
    exit 0
  fi
fi

echo "========================================================="
echo "  Generate L1 Pages — $SITE_SLUG"
echo "  Source:   $XLSX"
echo "  Config:   $CONFIG"
echo "  Output:   $OUTPUT_DIR"
echo "========================================================="

python3 - "$XLSX" "$TEMPLATES_DIR" "$OUTPUT_DIR" "$CONFIG" "$ONLY_PAGE" "$HTML_ONLY" "$REPO_ROOT" "$SITE_SLUG" << 'PYEOF'
import os, sys, re, json, html as h
from collections import OrderedDict

HTML_ONLY = sys.argv[6].lower() == 'true' if len(sys.argv) > 6 else False
import openpyxl

XLSX_PATH, TEMPLATES_DIR, OUTPUT_DIR, CONFIG_PATH = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ONLY_PAGE = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else ''
REPO_ROOT = sys.argv[7] if len(sys.argv) > 7 else os.path.dirname(os.path.dirname(OUTPUT_DIR))
SITE_SLUG = sys.argv[8] if len(sys.argv) > 8 else os.path.basename(os.path.dirname(CONFIG_PATH))

# Template file mapping: template key → filename
TEMPLATE_FILES = {
    'plan-your-visit': 'attraction-plan-your-visit-template.html',
    'tickets-tours': 'attraction-tickets-tours-template.html',
    'what-to-see': 'attraction-what-to-see-template.html',
}

def load_template_css(template_key):
    fname = TEMPLATE_FILES.get(template_key, TEMPLATE_FILES['plan-your-visit'])
    tpath = os.path.join(TEMPLATES_DIR, fname)
    content = open(tpath).read()
    return re.search(r'<style>.*?</style>', content, re.DOTALL).group(0)

def load_template_js(template_key):
    fname = TEMPLATE_FILES.get(template_key, TEMPLATE_FILES['plan-your-visit'])
    tpath = os.path.join(TEMPLATES_DIR, fname)
    content = open(tpath).read()
    m = re.search(r'<script>.*?</script>', content, re.DOTALL)
    return m.group(0) if m else ''
P = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

from urllib.parse import urlparse, urlencode, parse_qs, urlunparse

def affiliate_url(raw_url, site_slug, page_slug):
    """Build affiliate URL with correct partner ID + campaign ID for GYG/Tiqets/Viator."""
    parsed = urlparse(raw_url)
    host = parsed.hostname or ''
    # Strip existing tracking params
    params = parse_qs(parsed.query, keep_blank_values=True)
    for k in list(params.keys()):
        if k in ('partner_id', 'cmp', 'partner', 'tq_campaign', 'pid', 'mcid', 'medium', 'campaign'):
            del params[k]
    # Flatten single-value lists
    clean_params = {k: v[0] if len(v) == 1 else v for k, v in params.items()}
    campaign = f"{site_slug}-{page_slug}"
    if 'getyourguide.com' in host:
        clean_params['partner_id'] = '9BAL9K3'
        clean_params['cmp'] = campaign
    elif 'tiqets.com' in host:
        clean_params['partner'] = 'thebettervacation'
        clean_params['tq_campaign'] = campaign
    elif 'viator.com' in host:
        clean_params['pid'] = 'P00038490'
        clean_params['mcid'] = '42383'
        clean_params['medium'] = 'link'
        clean_params['campaign'] = campaign
    new_query = urlencode(clean_params, doseq=True)
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, new_query, parsed.fragment))

cfg = json.load(open(CONFIG_PATH))
DOMAIN = cfg['domain']
SITE_SLUG = os.path.basename(os.path.dirname(CONFIG_PATH))
GYG = cfg['gyg_url']
SHEET = cfg.get('sheet_name', 'IA — All Articles')
EXPLORE = cfg.get('explore_label', 'Continue exploring.')

# Load homepage-config for ticket data (used by tickets-tours page)
hc_path = os.path.join(os.path.dirname(CONFIG_PATH), 'homepage-config.json')
HC_TICKETS = []
HC_CURRENCY = '€'
if os.path.exists(hc_path):
    hc = json.load(open(hc_path))
    HC_TICKETS = hc.get('tickets', [])
    HC_CURRENCY = hc.get('currency', '€')

    # Auto-generate missing ticket descriptions via Claude
    import subprocess
    needs_save = False
    for t in HC_TICKETS:
        if HTML_ONLY: break
        if t.get('desc'):
            continue
        title = t.get('title', '')
        price = t.get('price', '')
        bullets = ', '.join(t.get('bullets', []))
        duration = t.get('duration', '')
        lang = t.get('lang', '')
        prompt = (
            f"Write a 1-2 sentence summary description for this ticket/tour product. "
            f"Be specific and informative — describe what the visitor gets. No marketing fluff. "
            f"Plain text only, no HTML.\n\n"
            f"Title: {title}\n"
            f"Price: {HC_CURRENCY}{price}\n"
            f"Duration: {duration}\n"
            f"Language: {lang}\n"
            f"Includes: {bullets}"
        )
        try:
            result = subprocess.run(
                ['claude', '--print', '-p', prompt],
                capture_output=True, text=True, timeout=30
            )
            desc = result.stdout.strip()
            if desc and len(desc) > 20:
                t['desc'] = desc
                needs_save = True
                print(f"  ✓ Generated desc for: {title}")
            else:
                print(f"  ⚠ Could not generate desc for: {title}")
        except Exception as e:
            print(f"  ⚠ Claude call failed for {title}: {e}")

    if needs_save:
        with open(hc_path, 'w') as f:
            json.dump(hc, f, indent=2, ensure_ascii=False)
        print(f"  Saved {sum(1 for t in HC_TICKETS if t.get('desc'))} ticket descriptions to homepage-config.json")
import subprocess

def claude_gen(prompt):
    """Call Claude CLI and return stripped output."""
    try:
        r = subprocess.run(['claude', '--print', '-p', prompt], capture_output=True, text=True, timeout=60)
        return r.stdout.strip()
    except Exception as e:
        print(f"  ⚠ Claude call failed: {e}")
        return ''

def claude_json(prompt):
    """Call Claude CLI expecting JSON array output."""
    raw = claude_gen(prompt + "\n\nRespond ONLY with a valid JSON array, no markdown fences, no explanation.")
    if not raw:
        return None
    # Strip markdown fences if present
    raw = raw.strip()
    if raw.startswith('```'):
        raw = '\n'.join(raw.split('\n')[1:])
    if raw.endswith('```'):
        raw = '\n'.join(raw.split('\n')[:-1])
    try:
        return json.loads(raw.strip())
    except json.JSONDecodeError:
        print(f"  ⚠ Could not parse Claude JSON: {raw[:100]}...")
        return None

def ensure_page_content(p, page_name):
    """Auto-generate missing practical, know_tips, and expand faqs via Claude."""
    changed = False

    # Practical Information — 2-3 prose cards with bullet lists
    if not p.get('practical'):
        print(f"  Generating practical info for {page_name}...")
        result = claude_json(
            f"Generate 4 practical information cards for a '{page_name}' travel guide page about {cfg.get('domain','')}. "
            f"Each card has: h3 (title), p (1-sentence intro), items (array of 4-5 bullet strings with practical advice). "
            f"Format: [{'{'}\"h3\":\"...\",\"p\":\"...\",\"items\":[\"...\"]{'}'}, ...]. "
            f"Make content specific to this attraction. No generic filler."
        )
        if result:
            p['practical'] = result
            changed = True
            print(f"  ✓ Generated {len(result)} practical cards")

    # Top Highlights — featured cards (for what-to-see pages)
    if not p.get('highlights') and 'see' in page_name.lower():
        print(f"  Generating highlights for {page_name}...")
        result = claude_json(
            f"Generate 3 'top highlight' entries for a 'what to see' page about {cfg.get('domain','')}. "
            f"Each is a must-see site/feature that every visitor should prioritise. "
            f"Each entry: {'{'}\"title\":\"...\",\"desc\":\"1-2 sentence description\",\"url\":\"/{p['slug']}/article-slug\"{'}'} "
            f"Format: [{'{'}\"title\":\"...\",\"desc\":\"...\",\"url\":\"...\"{'}'}, ...]. "
            f"Make titles and descriptions specific to this attraction."
        )
        if result:
            p['highlights'] = result
            changed = True
            print(f"  ✓ Generated {len(result)} highlights")

    # Decision Guide — 4 prose cards (for tickets-tours and what-to-see pages)
    if not p.get('guide_cards') and ('ticket' in page_name.lower() or 'see' in page_name.lower()):
        guide_context = "ticket to pick" if 'ticket' in page_name.lower() else "what to prioritise seeing"
        print(f"  Generating guide_cards for {page_name}...")
        result = claude_json(
            f"Generate 4 'how to choose' decision guide cards for a page about {cfg.get('domain','')}. "
            f"Each card helps visitors decide {guide_context} based on their situation. "
            f"Each card has: h3 (e.g. 'If you have limited time'), p (1-sentence intro), items (array of 3-4 bullet advice strings), rec (a 1-sentence recommendation or tip, e.g. 'Recommended: [option] — reason'). "
            f"Format: [{'{'}\"h3\":\"...\",\"p\":\"...\",\"items\":[\"...\"],\"rec\":\"...\"{'}'}, ...]. "
            f"Make content specific to this attraction."
        )
        if result:
            p['guide_cards'] = result
            changed = True
            print(f"  ✓ Generated {len(result)} guide cards")

    # Things to Know — 4-6 icon+tip cards
    if not p.get('know_tips'):
        print(f"  Generating know_tips for {page_name}...")
        result = claude_json(
            f"Generate 6 'things to know' tips for a '{page_name}' travel guide page about {cfg.get('domain','')}. "
            f"Each tip: [emoji, \"Bold label —\", \"Explanation sentence.\"]. "
            f"Format: [[\"🎫\",\"Book online —\",\"Walk-up tickets are often unavailable.\"], ...]. "
            f"Make content specific to this attraction."
        )
        if result:
            p['know_tips'] = result
            changed = True
            print(f"  ✓ Generated {len(result)} know_tips")

    # Expand FAQs to 8-10 if fewer than 8
    if len(p.get('faqs', [])) < 8:
        existing = p.get('faqs', [])
        existing_qs = [q[0] for q in existing]
        need = 10 - len(existing)
        print(f"  Expanding FAQs from {len(existing)} to 10 for {page_name}...")
        result = claude_json(
            f"Generate {need} FAQ entries for a '{page_name}' travel guide page about {cfg.get('domain','')}. "
            f"Each FAQ: [\"Question?\", \"Answer sentence(s).\"]. "
            f"Do NOT repeat these existing questions: {json.dumps(existing_qs)}. "
            f"Make answers specific, 1-3 sentences, factual. No generic filler."
        )
        if result:
            p['faqs'] = existing + result
            changed = True
            print(f"  ✓ FAQs now: {len(p['faqs'])}")

    return changed

# Build CFG and auto-generate missing content
CFG = {}
cfg_changed = False
for cat, p in cfg['pages'].items():
    if ONLY_PAGE and p['slug'] != ONLY_PAGE:
        CFG[cat] = {
            'slug': p['slug'], 'rc': p['rc'],
            'template': p.get('template', 'plan-your-visit'),
            'seo_t': p['seo_t'], 'seo_d': p['seo_d'],
            'badge': p['badge'], 'h1': p['h1'], 'desc': p['desc'],
            'cta1': tuple(p['cta1']), 'cta2': tuple(p['cta2']),
            'tips': [tuple(t) for t in p['tips']],
            'cta_h': p['cta_h'], 'cta_d': p['cta_d'], 'cta_b': p['cta_b'],
            'xlinks': [tuple(x) for x in p['xlinks']],
            'sg_desc': p.get('sg_desc', {}),
            'faqs': [tuple(f) for f in p.get('faqs', [])],
            'practical': p.get('practical', []),
            'know_tips': p.get('know_tips', []),
            'guide_cards': p.get('guide_cards', []),
            'highlights': p.get('highlights', []),
        }
        continue
    if not HTML_ONLY and ensure_page_content(p, f"{cat} - {p['h1']}"):
        cfg_changed = True
    CFG[cat] = {
        'slug': p['slug'], 'rc': p['rc'],
        'template': p.get('template', 'plan-your-visit'),
        'seo_t': p['seo_t'], 'seo_d': p['seo_d'],
        'badge': p['badge'], 'h1': p['h1'], 'desc': p['desc'],
        'cta1': tuple(p['cta1']), 'cta2': tuple(p['cta2']),
        'tips': [tuple(t) for t in p['tips']],
        'cta_h': p['cta_h'], 'cta_d': p['cta_d'], 'cta_b': p['cta_b'],
        'xlinks': [tuple(x) for x in p['xlinks']],
        'sg_desc': p.get('sg_desc', {}),
        'faqs': [tuple(f) for f in p.get('faqs', [])],
        'practical': p.get('practical', []),
        'know_tips': p.get('know_tips', []),
        'guide_cards': p.get('guide_cards', []),
        'highlights': p.get('highlights', []),
    }

if cfg_changed:
    with open(CONFIG_PATH, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  Saved updated config to l1-config.json")

wb = openpyxl.load_workbook(XLSX_PATH)

# Detect xlsx format: single master sheet vs per-silo sheets
SILO_SHEETS = ['Tickets & Tours', 'Plan Your Visit', 'What To See', 'What to See']
has_silo_sheets = any(s in wb.sheetnames for s in SILO_SHEETS)

articles = []
if has_silo_sheets:
    # Per-silo format: each sheet = one category
    # Columns: [0]=#, [1]=Article Title, [2]=Target Query, [3]=URL Slug, [4]=Partner, [5]=Priority, [6]=Notes
    for sheet_name in wb.sheetnames:
        if not any(s.lower() in sheet_name.lower() for s in ['ticket', 'plan', 'see']):
            continue
        ws = wb[sheet_name]
        category = sheet_name
        for row in ws.iter_rows(min_row=2):
            vals = [c.value for c in row]
            if not vals[0] or not vals[1]: continue
            # Skip non-article rows (PILLAR, CLUSTER, header rows, etc.)
            if str(vals[0]).upper() in ('PILLAR', 'CLUSTER', '#', ''): continue
            if not str(vals[0]).startswith(('A', 'T', 'P', 'W', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9')): continue
            notes = vals[6] if len(vals) > 6 and vals[6] else ''
            articles.append({'title': vals[1], 'category': category, 'subgroup': category, 'url': vals[3] or '', 'notes': notes, '_row': row})
else:
    # Single master sheet format — two sub-formats:
    # A) Legacy: col0=#, col1=title, col2=category, col3=url, col4=keyword ...
    # B) Standard 7-col: col0=silo-header(has \n) or blank, col1=cat_id, col2=title, col3=url_slug ...
    ws = wb[SHEET] if SHEET in wb.sheetnames else wb.worksheets[0]
    _current_cat = None
    _is_standard = None  # detect on first real row
    for row in ws.iter_rows(min_row=2):
        vals = [c.value for c in row]
        if all(v is None for v in vals): continue
        col0 = str(vals[0]).strip() if vals[0] else ''
        # Detect silo-header row (standard format): col0 contains newline
        if col0 and '\n' in col0:
            _current_cat = col0.split('\n')[0].strip()
            _is_standard = True
            continue
        if _is_standard is None:
            # Detect format from first real data row
            # Standard: col1 looks like P1/T1/W1; Legacy: col2 is a category name
            _is_standard = bool(vals[1] and str(vals[1]).strip() and len(str(vals[1]).strip()) <= 4 and str(vals[1]).strip()[0] in 'PTWA')
        if _is_standard:
            # Standard 7-col: col1=id, col2=title, col3=url_slug, col4=keyword, col5=affiliate, col6=priority
            cat_id, title, url_slug = vals[1], vals[2], vals[3]
            if not cat_id or not title: continue
            if not _current_cat: continue
            notes = str(vals[4]).strip() if len(vals) > 4 and vals[4] else ''
            articles.append({'title': str(title), 'category': _current_cat, 'subgroup': _current_cat, 'url': str(url_slug or ''), 'notes': notes, '_row': row})
        else:
            # Legacy format: col0=#, col1=title, col2=category, col3=url
            if not vals[0] or not vals[1]: continue
            notes = vals[10] if len(vals) > 10 else ''
            full_url = str(vals[5]).strip() if len(vals) > 5 and vals[5] else ''
            articles.append({'title': vals[1], 'category': vals[2], 'subgroup': vals[2], 'url': full_url, 'notes': notes or '', '_row': row})

# Auto-generate subgroups for articles that only have category (no dedicated subgroup column)
import subprocess
needs_subgroups = any(a['subgroup'] == a['category'] for a in articles)
if needs_subgroups and not HTML_ONLY:
    # Group articles by category, ask Claude to split each into 2-3 subgroups
    from collections import defaultdict
    by_cat = defaultdict(list)
    for a in articles:
        by_cat[a['category']].append(a['title'])
    for cat, titles in by_cat.items():
        if len(titles) < 4:
            continue  # too few to subgroup
        prompt = (
            f"I have {len(titles)} articles in the '{cat}' category of a travel guide website.\n"
            f"Group them into 2-3 logical subgroups with short, clear heading names (2-4 words each).\n\n"
            f"Articles:\n" + "\n".join(f"- {t}" for t in titles) +
            f"\n\nReturn a JSON object mapping each exact article title to its subgroup name.\n"
            f"Example: {{\"Article Title\": \"Getting There\", ...}}\n\n"
            f"Respond ONLY with a valid JSON object, no markdown fences."
        )
        raw = claude_gen(prompt)
        if raw:
            raw = raw.strip()
            if raw.startswith('```'): raw = '\n'.join(raw.split('\n')[1:])
            if raw.endswith('```'): raw = '\n'.join(raw.split('\n')[:-1])
            try:
                mapping = json.loads(raw.strip())
                for a in articles:
                    if a['category'] == cat and a['title'] in mapping:
                        a['subgroup'] = mapping[a['title']]
                print(f"  ✓ Auto-grouped {cat}: {len(set(mapping.values()))} subgroups")
            except json.JSONDecodeError:
                print(f"  ⚠ Could not parse subgroup JSON for {cat}")
elif needs_subgroups and HTML_ONLY:
    # Load cached subgroups from l1-config if available
    cached_subgroups = cfg.get('_subgroups', {})
    if cached_subgroups:
        for a in articles:
            key = a['title']
            if key in cached_subgroups:
                a['subgroup'] = cached_subgroups[key]
        print(f"  ✓ Loaded cached subgroups from l1-config.json")

# Save subgroup mapping to config for --html-only reuse
if needs_subgroups and not HTML_ONLY:
    subgroup_map = {a['title']: a['subgroup'] for a in articles if a['subgroup'] != a['category']}
    if subgroup_map:
        cfg['_subgroups'] = subgroup_map
        with open(CONFIG_PATH, 'w') as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"  ✓ Saved subgroup mapping to l1-config.json")

def _needs_desc(a):
    notes = a['notes'].strip()
    if not notes: return True
    if len(notes) > 80 and not any(c in notes for c in [',', ';']) and notes.endswith('.'): return False
    words = notes.split()
    prose_markers = {'a', 'an', 'the', 'this', 'that', 'with', 'from', 'for', 'how', 'what', 'which', 'where', 'includes', 'covers', 'offers'}
    if len(notes) > 80 and len(words) > 12 and len(prose_markers & set(w.lower() for w in words)) >= 3: return False
    return True

def _gen_desc(a):
    notes = a['notes'].strip()
    prompt = (
        f"Write a single sentence (max 30 words) summarising this article for a card subtitle on a travel guide website. "
        f"Be specific and informative. Plain text, no HTML, end with a period.\n\n"
        f"Article title: {a['title']}\nCategory: {a['category']}\nSub-group: {a['subgroup']}\nCurrent notes: {notes}"
    )
    try:
        result = subprocess.run(['claude', '--print', '-p', prompt], capture_output=True, text=True, timeout=60)
        desc = result.stdout.strip().strip('"')
        return desc if desc and len(desc) > 20 else None
    except Exception as e:
        print(f"  ⚠ Claude call failed for {a['title']}: {e}")
        return None

xlsx_changed = False
if not HTML_ONLY:
    from concurrent.futures import ThreadPoolExecutor, as_completed
    to_gen = [a for a in articles if _needs_desc(a)]
    if to_gen:
        print(f"  Generating descriptions for {len(to_gen)} articles (parallel)...")
        with ThreadPoolExecutor(max_workers=8) as ex:
            futures = {ex.submit(_gen_desc, a): a for a in to_gen}
            for fut in as_completed(futures):
                a = futures[fut]
                desc = fut.result()
                if desc:
                    a['notes'] = desc
                    notes_col = 6 if has_silo_sheets else 10
                    if len(a['_row']) > notes_col:
                        a['_row'][notes_col].value = desc
                        xlsx_changed = True
                    print(f"  ✓ {a['title'][:50]}...")
                else:
                    print(f"  ⚠ No desc: {a['title'][:50]}")

if xlsx_changed:
    wb.save(XLSX_PATH)
    print(f"  Saved article descriptions back to xlsx")

# Generate card tags for all articles (1-2 short keyword tags per article)
# Cache in l1-config under _card_tags for --html-only reuse
CARD_TAGS = cfg.get('_card_tags', {})
if not CARD_TAGS and not HTML_ONLY:
    titles_for_tags = [a['title'] for a in articles]
    if titles_for_tags:
        prompt = (
            "For each article title below, generate 1-2 short keyword tags (1-2 words each) "
            "that would work as small labels on a card. Tags should describe the article topic, "
            "NOT repeat the section/category name. Examples: 'Hours', 'Seasonal', 'Transport', 'Budget', 'Tips', 'Rules', 'Tides', 'Parking', 'Families'.\n\n"
            "Return a JSON object mapping each title to an array of 1-2 tag strings.\n\n"
            "Titles:\n" + "\n".join(f"- {t}" for t in titles_for_tags) +
            "\n\nRespond ONLY with a valid JSON object, no markdown fences."
        )
        raw = claude_gen(prompt)
        if raw:
            raw = raw.strip()
            if raw.startswith('```'): raw = '\n'.join(raw.split('\n')[1:])
            if raw.endswith('```'): raw = '\n'.join(raw.split('\n')[:-1])
            try:
                CARD_TAGS = json.loads(raw.strip())
                cfg['_card_tags'] = CARD_TAGS
                with open(CONFIG_PATH, 'w') as f:
                    json.dump(cfg, f, indent=2, ensure_ascii=False)
                print(f"  ✓ Generated & cached card tags for {len(CARD_TAGS)} articles")
            except json.JSONDecodeError:
                print(f"  ⚠ Could not parse card tags JSON")
elif CARD_TAGS:
    print(f"  ✓ Loaded cached card tags for {len(CARD_TAGS)} articles")

# ── Build JSON payloads for Claude ──────────────────────────────────────────
ROOT_CLASSES = {
    'plan-your-visit': 'att-plan-page',
    'tickets-tours': 'att-tickets-page',
    'what-to-see': 'att-see-page',
}

WORK_DIR = os.environ.get('L1_WORK_DIR', '/tmp/l1-gen')
os.makedirs(WORK_DIR, exist_ok=True)

for cat, c in CFG.items():
    if ONLY_PAGE and c['slug'] != ONLY_PAGE:
        continue
    tpl = c['template']
    # Show all articles from xlsx — slug matching was unreliable due to naming differences
    # between xlsx URL slugs and HTML filenames across sites
    arts = [a for a in articles if a['category']==cat]

    # Group articles by subgroup
    grp = OrderedDict()
    for a in arts: grp.setdefault(a['subgroup'],[]).append(a)
    article_sections = []
    for sg, aa in grp.items():
        section_articles = []
        for a in aa:
            tags = CARD_TAGS.get(a['title'], [])
            if isinstance(tags, str): tags = [tags]
            if not tags: tags = [sg]
            section_articles.append({
                'title': a['title'],
                'url': a['url'],
                'desc': a['notes'],
                'tags': tags[:2],
            })
        article_sections.append({
            'heading': sg,
            'subheading': c['sg_desc'].get(sg, ''),
            'articles': section_articles,
        })

    # Pre-compute affiliate URLs for tickets
    tickets_data = []
    if tpl == 'tickets-tours' and HC_TICKETS:
        for t in HC_TICKETS:
            tickets_data.append({
                'title': t['title'],
                'url': affiliate_url(t['url'], SITE_SLUG, c['slug']),
                'price': t.get('price', ''),
                'tag': t.get('tag', ''),
                'duration': t.get('duration', ''),
                'lang': t.get('lang', ''),
                'bullets': t.get('bullets', []),
                'desc': t.get('desc', ''),
                'l2': t.get('l2', ''),
                'best_for': t.get('best_for', t.get('tag', '')),
            })

    # For tickets-tours: split article_sections into ticket vs guide sections
    ticket_article_cards = []
    guide_article_cards = []
    ticket_sections = []
    guide_sections = []
    if tpl == 'tickets-tours':
        # Keywords that identify a subgroup as ticket/product articles
        TICKET_SUBGROUP_KEYWORDS = ('ticket', 'tour', 'combo', 'pass', 'entry', 'guided', 'private', 'multi', 'hop')
        for sec in article_sections:
            heading_lower = sec['heading'].lower()
            if any(kw in heading_lower for kw in TICKET_SUBGROUP_KEYWORDS):
                ticket_sections.append(sec)
            else:
                guide_sections.append(sec)

        # Build flat article card lists from classified sections (for featured picks)
        for sec in ticket_sections:
            for a in sec['articles']:
                ticket_article_cards.append({
                    'title': a['title'],
                    'article_url': a['url'],
                    'desc': a['desc'],
                    'tags': a['tags'],
                })
        for sec in guide_sections:
            for a in sec['articles']:
                guide_article_cards.append({
                    'title': a['title'],
                    'article_url': a['url'],
                    'desc': a['desc'],
                    'tags': a['tags'],
                })

        # Keep article_sections intact — Claude renders them as categorised card sections
        # (ticket_sections and guide_sections are passed separately for clarity)

    # Pre-compute crosslink data
    crosslinks = []
    for x in c['xlinks']:
        crosslinks.append({
            'name': x[0], 'url': x[1], 'desc': x[2], 'link_text': x[3],
        })

    payload = {
        'page_type': tpl,
        'root_class': ROOT_CLASSES.get(tpl, 'att-plan-page'),
        'domain': DOMAIN,
        'site_slug': SITE_SLUG,
        'seo_title': c['seo_t'],
        'seo_description': c['seo_d'],
        'canonical': f"https://{DOMAIN}/{c['slug']}",
        'badge': c['badge'],
        'h1': c['h1'],
        'hero_desc': c['desc'],
        'cta_primary': {'text': c['cta1'][0], 'url': c['cta1'][1]},
        'cta_secondary': {'text': c['cta2'][0], 'url': c['cta2'][1]},
        'quicktips': [{'label': t[0], 'text': t[1]} for t in c['tips']],
        'article_sections': article_sections,
        'practical': c.get('practical', []),
        'know_tips': c.get('know_tips', []),
        'highlights': c.get('highlights', []),
        'guide_cards': c.get('guide_cards', []),
        'tickets': tickets_data,
        'ticket_article_cards': ticket_article_cards,
        'guide_article_cards': guide_article_cards,
        'ticket_sections': ticket_sections,
        'guide_sections': guide_sections,
        'crosslinks': crosslinks,
        'cta_banner': {
            'h2': c['cta_h'],
            'desc': c['cta_d'],
            'button': c['cta_b'],
            'url': GYG.format(slug=c['slug']),
        },
        'faqs': [{'q': f[0], 'a': f[1]} for f in c['faqs']],
        'explore_label': EXPLORE,
        'currency': HC_CURRENCY,
    }

    payload_path = os.path.join(WORK_DIR, f"{c['slug']}.json")
    with open(payload_path, 'w') as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Payload: {c['slug']}.json ({len(arts)} articles)")

print(f"\n  Data prep complete. Starting HTML generation...")
PYEOF

# ── Resolve accent color ──────────────────────────────────────────────────────
ACCENT_COLOR=""
DESIGN_CONFIG="$REPO_ROOT/output/$SITE_SLUG/04-design-config/design-config.md"
if [[ -f "$DESIGN_CONFIG" ]]; then
  _ac=$(grep "^ACCENT_COLOR:" "$DESIGN_CONFIG" | sed 's/ACCENT_COLOR: *//' | tr -d '[:space:]')
  [[ -n "$_ac" ]] && ACCENT_COLOR="$_ac"
fi
[[ -z "$ACCENT_COLOR" ]] && ACCENT_COLOR="#ff0000"

# ── Template mapping ──────────────────────────────────────────────────────────
declare -A TEMPLATE_MAP
TEMPLATE_MAP[plan-your-visit]="attraction-plan-your-visit-template.html"
TEMPLATE_MAP[tickets-tours]="attraction-tickets-tours-template.html"
TEMPLATE_MAP[what-to-see]="attraction-what-to-see-template.html"

# ── Generate HTML for each page via Claude (3 parallel workers) ───────────────
L1_WORK_DIR="${L1_WORK_DIR:-/tmp/l1-gen}"

CSS_OVERRIDES='<style>
  .att-featured__img { min-height: 0 !important; aspect-ratio: 16/9 !important; }
  .att-featured__desc { flex: 0 0 auto !important; }
  @media (max-width:768px) { .att-featured__img { aspect-ratio: unset !important; } }
  .att-article-card h3 { font-weight: 700; }
  .att-article-card h3 a { color: #000 !important; }
  .att-article-card h3 a:hover { color: var(--accent) !important; }
  @media (min-width: 1280px) { .att-container { max-width: 74% !important; } }
  @media (min-width: 1024px) and (max-width: 1279px) { .att-container { max-width: 82% !important; } }
  @media (min-width: 768px) and (max-width: 1023px) { .att-container { max-width: 88% !important; } }
  @media (max-width: 767px) { .att-container { max-width: 94% !important; padding-left: 12px !important; padding-right: 12px !important; } }
</style>'

# Worker function: generate one L1 page
_generate_one() {
  local PAYLOAD_FILE="$1"
  local ACCENT_COLOR="$2"
  [[ -f "$PAYLOAD_FILE" ]] || return 1

  local PAGE_SLUG OUTPUT_FILE PAGE_TYPE TEMPLATE_FILE
  PAGE_SLUG=$(basename "$PAYLOAD_FILE" .json)
  OUTPUT_FILE="$OUTPUT_DIR/${PAGE_SLUG}.html"
  PAGE_TYPE=$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['page_type'])" 2>/dev/null)

  local -A _TMAP
  _TMAP[plan-your-visit]="attraction-plan-your-visit-template.html"
  _TMAP[tickets-tours]="attraction-tickets-tours-template.html"
  _TMAP[what-to-see]="attraction-what-to-see-template.html"

  TEMPLATE_FILE="$TEMPLATES_DIR/${_TMAP[$PAGE_TYPE]}"
  [[ -f "$TEMPLATE_FILE" ]] || { echo "  ✗ Template not found for $PAGE_SLUG ($PAGE_TYPE)"; return 1; }

  echo "  ── [$PAGE_SLUG] Starting..."

  # Extract CSS (with accent color substitution) and JS from template
  local CSS_BLOCK JS_BLOCK TEMPLATE_BODY
  CSS_BLOCK=$(python3 << CSSEOF
import re
content = open("$TEMPLATE_FILE").read()
css = re.search(r'<style>.*?</style>', content, re.DOTALL).group(0)
def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
def rgb_to_hex(r, g, b): return f'#{r:02x}{g:02x}{b:02x}'
def tint(r, g, b, f): return (int(r+(255-r)*f), int(g+(255-g)*f), int(b+(255-b)*f))
def shade(r, g, b, f): return (int(r*f), int(g*f), int(b*f))
accent = "$ACCENT_COLOR"
r, g, b = hex_to_rgb(accent)
css = css.replace('--accent: #ff0000', '--accent: ' + accent)
css = css.replace('--accent-light: #ffe5e5', '--accent-light: ' + rgb_to_hex(*tint(r,g,b,0.85)))
css = css.replace('--accent-dark: #cc0000', '--accent-dark: ' + rgb_to_hex(*shade(r,g,b,0.75)))
css = css.replace('--bg-warm: #faf8f6', '--bg-warm: #ffffff')
print(css)
CSSEOF
)

  JS_BLOCK=$(python3 -c "
import re
content = open('$TEMPLATE_FILE').read()
m = re.search(r'<script>.*?</script>', content, re.DOTALL)
print(m.group(0) if m else '')
")

  # Send only the HTML body to Claude (strip <style> and <script> to save tokens)
  TEMPLATE_BODY=$(python3 -c "
import re
content = open('$TEMPLATE_FILE').read()
content = re.sub(r'<style>.*?</style>\s*', '', content, flags=re.DOTALL)
content = re.sub(r'<script>.*?</script>\s*', '', content, flags=re.DOTALL)
print(content.strip())
")

  local PAYLOAD_CONTENT TMP_PROMPT
  PAYLOAD_CONTENT=$(cat "$PAYLOAD_FILE")
  TMP_PROMPT=$(mktemp /tmp/l1-prompt-XXXXXX)

  cat > "$TMP_PROMPT" << 'PROMPT_END'
Generate an L1 category hub page for a travel website.

## RULES
1. Output ONLY the HTML body starting with an SEO comment block, then the root `<div>` through its closing `</div>`. No `<style>`, `<script>`, `<!DOCTYPE>`, `<html>`, `<head>`, `<body>`. The SEO comment block must be first and use this exact format:
   ```
   <!-- SEO
   title: {generated: max 60 chars, primary keyword near front}
   description: {generated: max 155 chars, compelling, includes keyword}
   canonical: {canonical from JSON payload}
   -->
   ```
   Generate the title and description — do NOT copy the `seo_title`/`seo_description` fields from the JSON verbatim. Write them as a skilled SEO copywriter would.
2. Match the TEMPLATE structure EXACTLY — same class names, same section IDs, same nesting, same order. Do not add or remove sections.
3. Images: `data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==`
4. Affiliate URLs (getyourguide.com, tiqets.com, viator.com) from JSON: use VERBATIM, add `rel="nofollow sponsored" target="_blank"`. Internal links (starting `/`) get no rel attribute.
5. ONE visible FAQ accordion. JSON-LD FAQPage `<script>` at very end — invisible structured data only, NOT a second FAQ section.
6. FAQ: use `<details class="att-faq-item">` with `<summary class="att-faq-item__q">` — NO onclick, NO button, NO icon span. The CSS `::after` adds the + indicator automatically.
7. For tickets-tours page — EXACT section layout:
   - `#tt-top-picks` (featured): render ONLY the first 2 items from `tickets` (homepage ticket products) as featured horizontal cards. Each featured card uses the product's `url` field as the booking link with rel="nofollow sponsored" target="_blank" → "Check Availability", and links to the matching article in `ticket_article_cards` by title slug → "Find Out More". If no matching article found, omit the article link.
   - TICKET ARTICLE SECTIONS: for each entry in `ticket_sections`, render one `<section>` with an `<h2>` using the section `heading`, and an `att-tickets-grid` containing one `att-ticket` card per article. Each ticket card MUST have TWO buttons in `att-ticket__footer`: (1) `att-ticket__cta` linking to `cta_banner.url` with `rel="nofollow sponsored" target="_blank"` and text "Check Availability →"; (2) `att-ticket__more` linking to the article `url` (internal) with text "Read More →". EVERY article in every `ticket_sections` entry must appear exactly once.
   - GUIDE ARTICLE SECTIONS: for each entry in `guide_sections`, render one `<section>` with an `<h2>` using the section `heading`, and an `att-tickets-grid` containing one `att-ticket` card per article. Each guide card MUST have ONE button only in `att-ticket__footer`: `att-ticket__cta` linking to the article `url` (internal, no rel) with text "Read More →". No booking/affiliate link on guide cards. EVERY article in every `guide_sections` entry must appear exactly once.
   - Comparison table: render one row per `tickets` entry. Each row's "Book Now" button uses the ticket `url` field (affiliate). NEVER use internal article URLs in "Book Now" buttons.
   - Decision guide: render `guide_cards` as prose cards using `att-guide-grid`.
   - CRITICAL: Every article in `ticket_sections` and every article in `guide_sections` MUST appear in the output exactly once. No omissions.
8. For plan-your-visit and what-to-see pages — EXACT article section layout:
   - For each entry in `article_sections`, render one `<section>` with an `<h2>` using the section `heading`, and an `att-articles-grid` containing one `att-article-card` per article. Card link: `article_url` only.
   - EVERY article in EVERY `article_sections` entry must appear exactly once. No omissions, no merging of sections.
9. Image placeholder for ALL images (featured, article cards, crosslinks, hero): `data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==`

## TEMPLATE (match this HTML structure exactly)

PROMPT_END

  echo "$TEMPLATE_BODY" >> "$TMP_PROMPT"
  printf '\n\n## JSON DATA PAYLOAD\n\n' >> "$TMP_PROMPT"
  echo "$PAYLOAD_CONTENT" >> "$TMP_PROMPT"
  printf '\n\nGenerate the HTML now. Output ONLY the HTML, no explanation, no markdown fences.\n' >> "$TMP_PROMPT"

  local TMP_RAW TMP_FINAL
  TMP_RAW=$(mktemp /tmp/l1-raw-XXXXXX)
  TMP_FINAL=$(mktemp /tmp/l1-final-XXXXXX)

  claude -p --model claude-sonnet-4-6 --output-format text < "$TMP_PROMPT" > "$TMP_RAW"
  local _EXIT=$?
  rm -f "$TMP_PROMPT"

  [[ $_EXIT -eq 0 ]] || { echo "  ✗ [$PAGE_SLUG] Claude error (exit $_EXIT)"; rm -f "$TMP_RAW"; return 1; }
  [[ -s "$TMP_RAW" ]] || { echo "  ✗ [$PAGE_SLUG] Empty output"; rm -f "$TMP_RAW"; return 1; }

  # Strip any <style> Claude may have added + markdown fences; extract SEO comment
  local SEO_COMMENT
  SEO_COMMENT=$(python3 - "$TMP_RAW" << 'STRIPEOF'
import re, sys
content = open(sys.argv[1]).read()
m = re.match(r'(<!--\s*SEO.*?-->)', content.strip(), re.DOTALL)
print(m.group(1) if m else '')
STRIPEOF
)
  python3 - "$TMP_RAW" << 'STRIPEOF' > "$TMP_FINAL"
import re, sys
content = open(sys.argv[1]).read()
content = re.sub(r'<style>.*?</style>\s*', '', content, flags=re.DOTALL)
# Remove leading SEO comment so it doesn't appear inside the body block
content = re.sub(r'^<!--\s*SEO.*?-->\s*', '', content.strip(), flags=re.DOTALL)
content = content.strip()
if content.startswith('```'): content = '\n'.join(content.split('\n')[1:])
if content.endswith('```'): content = '\n'.join(content.split('\n')[:-1])
print(content.strip())
STRIPEOF
  rm -f "$TMP_RAW"

  # Fix www./trailing-slash issues in card links
  local SITE_DOMAIN
  SITE_DOMAIN=$(python3 -c "import json; cfg=json.load(open('$REPO_ROOT/input/$SITE_SLUG/l1-config.json')); print(cfg.get('domain',''))" 2>/dev/null || true)
  if [[ -n "$SITE_DOMAIN" ]]; then
    local TMP_FIXED
    TMP_FIXED=$(mktemp /tmp/l1-fixed-XXXXXX)
    local REGISTRY_PATH="$REPO_ROOT/output/$SITE_SLUG/url-registry.json"
    python3 - "$TMP_FINAL" "$SITE_DOMAIN" "$REGISTRY_PATH" << 'FIXEOF' > "$TMP_FIXED"
import re, sys, json, os
content = open(sys.argv[1]).read()
domain = sys.argv[2]
registry_path = sys.argv[3] if len(sys.argv) > 3 else ''
# Strip www. from absolute internal links (https and http)
content = re.sub(r'https://www\.' + re.escape(domain) + r'/', 'https://' + domain + '/', content)
content = re.sub(r'http://www\.' + re.escape(domain) + r'/', 'http://' + domain + '/', content)
# Convert absolute internal links to relative paths (https and http)
content = re.sub(r'https://' + re.escape(domain) + r'(/[^"\'>\s]*)', r'\1', content)
content = re.sub(r'http://' + re.escape(domain) + r'(/[^"\'>\s]*)', r'\1', content)
# Add trailing slash to internal hrefs that are paths ending in a slug (no extension, no trailing slash)
content = re.sub(r'(href="/[^"]*[^/"]{1})"', lambda m: m.group(0) if '.' in m.group(1).split('/')[-1] else m.group(1) + '/"', content)
# Validate internal hrefs against url-registry.json if available
if registry_path and os.path.isfile(registry_path):
    try:
        registry = json.load(open(registry_path))
        known_pages = set(registry.get('pages', {}).keys())
        hrefs = re.findall(r'href="(/[^"]*)"', content)
        for href in hrefs:
            # Normalise: ensure trailing slash for path-only hrefs
            norm = href if href.endswith('/') or '.' in href.split('/')[-1] else href + '/'
            if norm not in known_pages:
                print(f'WARNING: internal href not in url-registry: {href}', file=sys.stderr)
    except Exception as e:
        print(f'WARNING: url-registry validation failed: {e}', file=sys.stderr)
print(content, end='')
FIXEOF
    mv "$TMP_FIXED" "$TMP_FINAL"
  fi

  # Assemble: SEO comment + CSS + overrides + body + JS
  {
    [[ -n "$SEO_COMMENT" ]] && printf '%s\n\n' "$SEO_COMMENT"
    echo "$CSS_BLOCK"
    echo "$CSS_OVERRIDES"
    echo ""
    cat "$TMP_FINAL"
    echo ""
    echo "$JS_BLOCK"
  } > "$OUTPUT_FILE"
  rm -f "$TMP_FINAL"

  local SIZE
  SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
  echo "  ✓ [$PAGE_SLUG] Done — ${SIZE} bytes"

  # Validate card coverage: every article in payload must appear in output
  python3 - "$PAYLOAD_FILE" "$OUTPUT_FILE" "$PAGE_SLUG" << 'VALIDATEEOF'
import json, re, sys
payload = json.load(open(sys.argv[1]))
html = open(sys.argv[2]).read()
page_slug = sys.argv[3]
# Collect all article URLs from payload
article_urls = []
for section_key in ('article_sections', 'ticket_sections', 'guide_sections'):
    for sec in payload.get(section_key, []):
        for art in sec.get('articles', []):
            article_urls.append(art['url'])
if not article_urls:
    sys.exit(0)
# Extract all hrefs from output
hrefs = set(re.findall(r'href="([^"]+)"', html))
missing = [u for u in article_urls if u not in hrefs]
if missing:
    print(f"  ⚠ [{page_slug}] MISSING {len(missing)} article(s) from card grid:")
    for u in missing:
        print(f"    - {u}")
else:
    print(f"  ✓ [{page_slug}] Card coverage OK — all {len(article_urls)} articles present")
VALIDATEEOF
}

# Launch all 3 workers in parallel
_PIDS=()
_LOGS=()
_HB_START=$SECONDS

for PAYLOAD_FILE in "$L1_WORK_DIR"/*.json; do
  [[ -f "$PAYLOAD_FILE" ]] || continue
  PAGE_SLUG=$(basename "$PAYLOAD_FILE" .json)
  _LOG="/tmp/l1-worker-${PAGE_SLUG}-$$.log"
  _LOGS+=("$_LOG")
  _generate_one "$PAYLOAD_FILE" "$ACCENT_COLOR" > "$_LOG" 2>&1 &
  _PIDS+=($!)
  echo "  Launched: $PAGE_SLUG (PID $!)"
done

# Heartbeat
( while true; do
    sleep 5
    printf "  ⏱  %ds elapsed...\n" "$(( SECONDS - _HB_START ))"
  done ) &
_HB_PID=$!

# Wait for all workers and collect output
_ALL_OK=true
for i in {1..${#_PIDS[@]}}; do
  wait "${_PIDS[$i]}" || _ALL_OK=false
  cat "${_LOGS[$i]}"
  rm -f "${_LOGS[$i]}"
done
kill "$_HB_PID" 2>/dev/null; wait "$_HB_PID" 2>/dev/null || true

# Cleanup
rm -rf "$L1_WORK_DIR"

[[ "$_ALL_OK" == "true" ]] || echo "  ⚠ One or more pages failed — check output above"

echo ""
echo "========================================================="
echo "  L1 pages generated in $OUTPUT_DIR"
echo "========================================================="
