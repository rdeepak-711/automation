#!/usr/bin/env zsh
set -euo pipefail

# ── L0: Homepage Generator ───────────────────────────────────────────────────
# Generates the homepage HTML from the homepage template + homepage-config.json.
# No AI needed — pure data-driven template rendering.
#
# Usage:
#   ./scripts/content/generate-homepage.sh <site-slug> [--force]
#
# Requires:
#   input/<site-slug>/homepage-config.json  (all page data)
#
# Output:
#   output/<site-slug>/homepage.html

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-slug> [--force]"
  echo "Example: $0 opera-garnier"
  exit 1
fi

SITE_SLUG="$1"
shift

FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG="$REPO_ROOT/input/$SITE_SLUG/homepage-config.json"
TICKETS_MD="$REPO_ROOT/input/$SITE_SLUG/tickets.md"
TEMPLATE="$REPO_ROOT/docs/Four Pages/attraction-homepage-template.html"
OUTPUT_DIR="$REPO_ROOT/output/$SITE_SLUG"
OUTPUT_FILE="$OUTPUT_DIR/homepage.html"

[[ -f "$CONFIG" ]]   || { echo "Error: homepage-config.json not found: $CONFIG"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "Error: template not found: $TEMPLATE"; exit 1; }

if [[ "$FORCE" == "false" && -f "$OUTPUT_FILE" ]]; then
  echo "  homepage.html already exists. Use --force to regenerate."
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

# ── Enrich tickets from tickets.md if not already cached in config ─────────────
if [[ -f "$TICKETS_MD" ]]; then
  echo "  Checking ticket cards..."
  python3 - "$CONFIG" "$TICKETS_MD" << 'ENRICH_EOF'
import sys, json, re, subprocess

CONFIG_PATH, TICKETS_MD = sys.argv[1], sys.argv[2]
cfg = json.load(open(CONFIG_PATH))

# Skip if tickets already cached
if cfg.get('tickets') and len(cfg['tickets']) >= 3:
    print("  ✓ Tickets already cached in config — skipping enrichment")
    sys.exit(0)

# Parse tickets.md — format: T1 | Title | URL | Partner | /l2-slug/
raw_tickets = []
with open(TICKETS_MD) as f:
    for line in f:
        line = line.strip()
        m = re.match(r'^T(\d+)\s*\|\s*(.+?)\s*\|\s*(https?://\S+)\s*\|\s*.+?\s*\|\s*(/\S+)', line)
        if m:
            raw_tickets.append({'num': int(m.group(1)), 'title': m.group(2), 'url': m.group(3), 'l2': m.group(4).rstrip('/')+'/'})

if not raw_tickets:
    print("  ⚠ No tickets found in tickets.md")
    sys.exit(0)

# Take top 6
top = raw_tickets[:6]
currency = cfg.get('currency', '€')
domain = cfg.get('domain', '')

ticket_list = '\n'.join(f"T{t['num']}. {t['title']} (URL: {t['url']})" for t in top)

prompt = f"""For each of these ticket/tour products for {domain}, generate card data.

Tickets:
{ticket_list}

For EACH ticket return a JSON object with:
- "title": short display title (max 8 words, keep key details)
- "tag": one of: "Best Seller", "Best Value", "Skip the Line", "Top Rated", "Most Popular", "Guided Tour", "Private Tour", "Combo Deal"
- "price": numeric price string only (e.g. "25" — no currency symbol). Use realistic market price.
- "bullets": array of 3 short benefit strings (max 8 words each, e.g. "Skip the entry queue", "Audio guide included")
- "duration": e.g. "1.5–2 hrs", "Half day", "Full day"
- "lang": e.g. "English", "Multi-language", "Audio guide"

Output ONLY a JSON array of {len(top)} objects. No markdown fences, no explanation."""

print(f"  Calling Claude to enrich {len(top)} tickets...")
try:
    r = subprocess.run(['claude', '-p', '--model', 'claude-opus-4-6', '--output-format', 'text', prompt],
                       capture_output=True, text=True, timeout=60)
    raw = r.stdout.strip()
    if raw.startswith('```'): raw = '\n'.join(raw.split('\n')[1:])
    if raw.endswith('```'): raw = '\n'.join(raw.split('\n')[:-1])
    enriched = json.loads(raw.strip())
    # Merge with URL and l2 from parsed MD
    tickets_out = []
    for i, t in enumerate(top):
        e = enriched[i] if i < len(enriched) else {}
        tickets_out.append({
            'title': e.get('title', t['title']),
            'url': t['url'],
            'tag': e.get('tag', 'Popular'),
            'price': str(e.get('price', '')),
            'bullets': e.get('bullets', []),
            'duration': e.get('duration', ''),
            'lang': e.get('lang', 'English'),
            'l2': t['l2'],
        })
    cfg['tickets'] = tickets_out
    with open(CONFIG_PATH, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Enriched and cached {len(tickets_out)} tickets in homepage-config.json")
except Exception as e:
    print(f"  ⚠ Ticket enrichment failed: {e}")
    sys.exit(0)
ENRICH_EOF
fi

echo "========================================================="
echo "  Generate Homepage — $SITE_SLUG"
echo "  Config:   $CONFIG"
echo "  Template: $TEMPLATE"
echo "  Output:   $OUTPUT_FILE"
echo "========================================================="

python3 - "$TEMPLATE" "$OUTPUT_FILE" "$CONFIG" << 'PYEOF'
import re, sys, json, html as h, subprocess

TEMPLATE_PATH, OUTPUT_FILE, CONFIG_PATH = sys.argv[1], sys.argv[2], sys.argv[3]
P = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

cfg = json.load(open(CONFIG_PATH))
CMP = cfg['cmp']
CURRENCY = cfg.get('currency', '€')

template_content = open(TEMPLATE_PATH).read()
css = re.search(r'<style>\s*(?:/\*|:root)', template_content, re.DOTALL)
css_start = css.start()
css_end = template_content.find('</style>', css_start) + len('</style>')
css = template_content[css_start:css_end]
js_m = re.search(r'<script>.*?</script>', template_content, re.DOTALL)
js = js_m.group(0) if js_m else ''

CSS_OVERRIDES = """<style>
  .att-faq { max-width:920px; margin:0 auto; }
  .att-faq-item { border:1px solid var(--border); border-radius:10px; overflow:hidden; margin:0 0 8px 0; padding:0; }
  details.att-faq-item[open] { background:var(--bg-warm); }
  .att-faq-item__q { width:100%; display:flex; align-items:center; padding:18px 22px; margin:0; border:none; background:transparent; cursor:pointer; font-family:'Source Sans 3',sans-serif; font-size:15px; font-weight:600; color:var(--text-primary); text-align:left; line-height:1.4; gap:12px; list-style:none; }
  .att-faq-item__q::-webkit-details-marker { display:none; }
  .att-faq-item__q::marker { display:none; content:''; }
  .att-faq-item__q::after { content:'+'; font-size:20px; color:var(--accent); flex-shrink:0; font-weight:300; transition:transform 0.25s; margin-left:auto; }
  details.att-faq-item[open] .att-faq-item__q::after { transform:rotate(45deg); }
  .att-faq-item__q:hover { color:var(--text-primary); }
  .att-faq-item__a { padding:4px 22px 20px; margin:0; font-size:14px; color:var(--text-secondary); line-height:1.72; }
  .att-faq-item__a span { display:block; margin:0; padding:0; }
  details.att-faq-item > div { padding:4px 22px 20px; margin:0; font-size:14px; color:var(--text-secondary); line-height:1.72; }
  details.att-faq-item > div span { display:block; margin:0; padding:0; }
  .att-homepage .att-highlight__body h3 { font-size:18px !important; line-height:1.3 !important; font-style:normal; font-weight:700; }
  .att-homepage .att-highlight__body h3 a { font-size:18px !important; font-weight:700 !important; color:#000 !important; }
  .att-homepage .att-highlight__body h3 a:hover { color:var(--accent) !important; }
  .att-homepage .att-ticket h3 { font-style:normal; font-weight:700; color:#000 !important; }
  .att-container { max-width: 100% !important; }
  @media (max-width: 767px) { .att-container { padding-left: 16px !important; padding-right: 16px !important; } }
  @media (min-width: 768px) and (max-width: 1023px) { .att-container { padding-left: 24px !important; padding-right: 24px !important; } }
</style>"""

# Build ticket card affiliate URL (adds partner params + cmp, deduplicates)
from urllib.parse import urlparse, urlencode, parse_qs, urlunparse
def ticket_aff_url(raw_url, cmp):
    parsed = urlparse(raw_url)
    host = parsed.hostname or ''
    params = parse_qs(parsed.query, keep_blank_values=True)
    for k in list(params.keys()):
        if k in ('partner_id', 'cmp', 'partner', 'tq_campaign', 'pid', 'mcid', 'medium', 'campaign'):
            del params[k]
    flat = {k: v[0] if len(v)==1 else v for k,v in params.items()}
    if 'getyourguide.com' in host:
        flat['partner_id'] = '9BAL9K3'
        flat['cmp'] = cmp
    elif 'tiqets.com' in host:
        flat['partner'] = 'thebettervacation'
        flat['tq_campaign'] = cmp
    elif 'viator.com' in host:
        flat['pid'] = 'P00038490'
        flat['mcid'] = '42383'
        flat['medium'] = 'link'
        flat['campaign'] = cmp
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, urlencode(flat, doseq=True), parsed.fragment))

# Build ticket cards
tc = ''
for t in cfg.get('tickets', []):
    aff = h.escape(ticket_aff_url(t['url'], CMP))
    bl = ''.join(f'<li>{b}</li>' for b in t['bullets'])
    tc += f'''
        <div class="att-ticket">
          <img class="att-ticket__img" src="{P}" alt="{h.escape(t['title'])}" />
          <div class="att-ticket__body">
            <span class="att-ticket__tag att-ticket__tag--popular">{h.escape(t['tag'])}</span>
            <h3>{h.escape(t['title'])}</h3>
            <div class="att-ticket__price"><span class="att-ticket__price-label">from</span><span class="att-ticket__price-value">{CURRENCY} {t['price']}</span></div>
            <ul class="att-ticket__bullets">{bl}</ul>
          </div>
          <div class="att-ticket__footer">
            <div class="att-ticket__meta"><span>{t['duration']}</span><span>{t['lang']}</span></div>
            <a href="{aff}" class="att-ticket__cta" rel="nofollow sponsored" target="_blank">Book This Tour</a>
            <a href="{h.escape(t['l2'])}" class="att-ticket__more">Learn more &rarr;</a>
          </div>
        </div>'''

# Build highlight cards
import re as _re
domain_esc = _re.escape(cfg.get('domain', ''))

def highlights(items):
    def rel(u):
        if domain_esc:
            u = _re.sub(r'https?://(?:www\.)?' + domain_esc, '', u)
        return u.rstrip('/') + '/' if u.startswith('/') else u
    return ''.join(f'''
        <div class="att-highlight">
          <img class="att-highlight__img" src="{P}" alt="{t}" />
          <div class="att-highlight__body"><h3><a href="{h.escape(rel(u))}">{t}</a></h3><p>{d}</p><a href="{h.escape(rel(u))}">Read guide &rarr;</a></div>
        </div>''' for t,u,d in items)

pyv_c = highlights(cfg['plan_your_visit'])
wts_c = highlights(cfg['what_to_see'])

tips_h = ''.join(f'''
        <div class="att-tip"><span class="att-tip__icon">{i}</span><span><strong>{l} &mdash;</strong> {t}</span></div>''' for i,l,t in cfg['tips'])

faq_h = ''.join(f'''
        <details class="att-faq-item" itemscope itemprop="mainEntity" itemtype="https://schema.org/Question">
          <summary class="att-faq-item__q">
            <span itemprop="name">{q}</span>
          </summary>
          <div class="att-faq-item__a" itemscope itemprop="acceptedAnswer" itemtype="https://schema.org/Answer">
            <span itemprop="text">{a}</span>
          </div>
        </details>''' for q,a in cfg['faqs'])

cta_url = h.escape(cfg['cta_url'])

# Generate SEO title and description via Claude
seo_prompt = f"""Generate an SEO title and meta description for the homepage of {cfg['domain']}.

Site: {cfg['domain']}
H1: {cfg['h1']}
Location: {cfg['location']}
Hero description: {cfg['hero_desc']}

Rules:
- title: max 60 chars, primary keyword near front
- description: max 155 chars, compelling, includes keyword

Output ONLY two lines:
title: <your title>
description: <your description>"""

seo_title = cfg.get('seo_title', '')
seo_desc = cfg.get('seo_desc', '')
try:
    r = subprocess.run(
        ['claude', '-p', '--model', 'claude-opus-4-6', '--output-format', 'text', seo_prompt],
        capture_output=True, text=True, timeout=30
    )
    for line in r.stdout.strip().splitlines():
        if line.startswith('title:'):
            seo_title = line[len('title:'):].strip()
        elif line.startswith('description:'):
            seo_desc = line[len('description:'):].strip()
except Exception:
    pass  # fall back to config values

seo_block = f'''<!-- SEO
title: {seo_title}
description: {seo_desc}
canonical: https://{cfg['domain']}
-->'''

page = f'''{seo_block}

{css}
{CSS_OVERRIDES}

<div class="att-homepage">
  <section class="att-hero">
    <div class="att-container">
      <div class="att-hero__inner">
        <div class="att-hero__content">
          <div class="att-hero__badge att-animate">{cfg['location']}</div>
          <h1 class="att-animate att-delay-1">{cfg['h1']}</h1>
          <p class="att-hero__desc att-animate att-delay-2">{cfg['hero_desc']}</p>
          <div class="att-hero__actions att-animate att-delay-3">
            <a href="#att-tickets" class="att-btn att-btn--primary">View Tickets &rarr;</a>
            <a href="#att-plan" class="att-btn att-btn--outline">Plan Your Visit</a>
          </div>
        </div>
        <div class="att-hero__image-wrap att-animate att-delay-2"><img class="att-hero__img" src="{P}" alt="{cfg['h1']}" loading="eager" /></div>
      </div>
    </div>
  </section>

  <section id="att-tickets" class="att-section">
    <div class="att-container">
      <div class="att-section-header"><h2>{cfg['tickets_heading']}</h2><p>{cfg['tickets_desc']}</p></div>
      <div class="att-tickets-grid">{tc}</div>
      <div class="att-section-link"><a href="/tickets/">View All Tickets &amp; Tours &rarr;</a></div>
    </div>
  </section>

  <section id="att-plan" class="att-section">
    <div class="att-container">
      <div class="att-section-header"><h2>{cfg['pyv_heading']}</h2><p>{cfg['pyv_desc']}</p></div>
      <div class="att-highlights-grid">{pyv_c}</div>
      <div class="att-section-link"><a href="/plan-your-visit/">View Complete Visitor Guide &rarr;</a></div>
    </div>
  </section>

  <section class="att-section att-section--alt">
    <div class="att-container">
      <div class="att-section-header"><h2>{cfg['tips_heading']}</h2><p>{cfg['tips_desc']}</p></div>
      <div class="att-tips-grid">{tips_h}</div>
    </div>
  </section>

  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header"><h2>{cfg['wts_heading']}</h2><p>{cfg['wts_desc']}</p></div>
      <div class="att-highlights-grid">{wts_c}</div>
      <div class="att-section-link"><a href="/what-to-see/">Explore Everything to See &rarr;</a></div>
    </div>
  </section>

  <section class="att-cta-banner">
    <h2>{cfg['cta_h']}</h2>
    <p>{cfg['cta_d']}</p>
    <a href="{cta_url}" class="att-btn att-btn--white" rel="nofollow sponsored" target="_blank">{cfg['cta_b']} &rarr;</a>
  </section>

  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header att-section-header--center"><h2>{cfg['faq_heading']}</h2><p>{cfg['faq_desc']}</p></div>
      <div class="att-faq" itemscope itemtype="https://schema.org/FAQPage">{faq_h}</div>
      <div class="att-section-link"><a href="{cfg['faq_link']}">View All Frequently Asked Questions &rarr;</a></div>
    </div>
  </section>
</div>

{js}
'''

# Ensure all internal links are relative paths
if domain_esc:
    page = _re.sub(r'https?://(?:www\.)?' + domain_esc + r'(/[^"\'>\s]*)', r'\1', page)

open(OUTPUT_FILE,'w').write(page)
print(f"  \u2713 homepage.html ({len(page)} bytes)")
PYEOF

echo ""
echo "========================================================="
echo "  Done — Homepage generated"
echo "========================================================="
