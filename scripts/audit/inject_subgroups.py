#!/usr/bin/env python3
"""
Rebuild GP Elements menu HTML with section-label sub-groups.

Usage:
  ./inject_subgroups.py [--tickets path/to/tickets.md] < menu.html > new_menu.html

Buy Tickets group is derived from tickets.md (single source of truth).
Article silo groups (Tickets & Tours, Plan Your Visit, What to See) use
the hardcoded slug groupings below.
"""
import json, re, sys, html as htmllib, argparse
from pathlib import Path

# ── Default article silo groupings (used when no menu_groupings.json found) ───
_DEFAULT_GROUPINGS = {
  "tickets-tours": {
    "groups": [
      {"label": "Combo Tickets", "slugs": []},
      {"label": "Guided Tours",  "slugs": []},
      {"label": "Audio Guides",  "slugs": []},
      {"label": "Entry Tickets", "slugs": []},
    ]
  },
  "plan-your-visit": {
    "groups": [
      {"label": "Tickets & Hours",   "slugs": []},
      {"label": "Getting There",     "slugs": []},
      {"label": "Planning Your Day", "slugs": []},
      {"label": "On-Site Info",      "slugs": []},
    ]
  },
  "what-to-see": {
    "groups": [
      {"label": "Must-See Highlights", "slugs": []},
      {"label": "Art & Collections",   "slugs": []},
      {"label": "Views & Hidden Gems", "slugs": []},
    ]
  }
}

groupings = _DEFAULT_GROUPINGS  # replaced at runtime by load_groupings()

silo_keywords = {
    'Tickets & Tours': 'tickets-tours',
    'Plan Your Visit': 'plan-your-visit',
    'What to See':     'what-to-see',
}

GROUP_ORDER = ["entry", "guided", "private", "adventure", "combo", "passes"]
GROUP_LABELS = {
    "entry":     "Entry & Tickets",
    "guided":    "Guided Tours",
    "private":   "Private Tours",
    "adventure": "Adventure & Day Trips",
    "combo":     "Combo Tickets",
    "passes":    "City Passes",
}

# Explicit token→group mapping (takes priority over keyword classification)
KNOWN_TOKEN_GROUPS = {
    't523510':  'entry',   # skip-line + audio
    'p1111504': 'entry',   # audio guide + harem (tiqets)
    't192789':  'guided',  # 20-min guided tour
    't127010':  'guided',  # harem guided tour
    't762572':  'guided',  # private harem small group
    't1282589': 'guided',  # secrets tour russian guide
    't792565':  'guided',  # small group tour
    't490497':  'guided',  # blue mosque + harem guided
    'p1101284': 'combo',   # harem + bosphorus cruise
    't943122':  'combo',   # hagia sophia combo
    't948206':  'combo',   # basilica + hagia sophia combo
    't938745':  'combo',   # basilica cistern combo
    '65151P4':  'combo',   # viator private + basilica
    't334016':  'combo',   # 4-site combo
    't676089':  'passes',  # official museum pass
    't49897':   'passes',  # tourist pass
    # Angkor Wat
    'd5480-39527P96': 'entry',    # admission ticket
    't1151222':       'entry',    # photoshoot
    'd5480-68746P15': 'guided',   # sunrise/sunset tour
    't466712':        'guided',   # 2-day guided
    't430978':        'guided',   # full day sunset
    't481140':        'guided',   # full day sunrise
    'd5480-31721P1':  'guided',   # temples of angkor
    't171234':        'guided',   # tour with meals
    'd5480-68746P1':  'private',  # private day tour
    'd5480-142794P3': 'private',  # private 2-day
    't467885':        'private',  # private tuk-tuk
    't18395':         'adventure', # bike temples
    't151874':        'adventure', # zipline
}


# ── Article groupings loader ─────────────────────────────────────────────────

def load_groupings(site_slug: str | None) -> dict:
    """Load menu_groupings.json for a site; fall back to defaults if absent."""
    if site_slug:
        here = Path(__file__).parent
        root = here.parent.parent
        json_path = root / 'input' / site_slug / 'menu_groupings.json'
        if json_path.exists():
            try:
                data = json.loads(json_path.read_text())
                print(f'  Loaded groupings from {json_path}', file=sys.stderr)
                return data
            except Exception as e:
                print(f'  WARN: could not parse {json_path} ({e}) — using defaults', file=sys.stderr)
        else:
            print(f'  WARN: {json_path} not found — using flat "Published Articles" fallback', file=sys.stderr)
    return _DEFAULT_GROUPINGS


# ── tickets.md parsing ───────────────────────────────────────────────────────

def url_token(url):
    """Extract unique product ID from an affiliate URL."""
    base = url.split('?')[0].rstrip('/-')
    return base.split('/')[-1]


def classify_ticket(name, url):
    """Fallback keyword classification for unknown tokens."""
    n = name.lower()
    if 'pass' in n:
        return 'passes'
    if 'combo' in n or n.count('+') >= 2:
        return 'combo'
    if any(w in n for w in ('guided tour', 'private', 'small group', 'secrets')):
        return 'guided'
    if 'tour' in n and 'audio' not in n:
        return 'guided'
    return 'entry'


def parse_tickets_md(path):
    """Return ordered list of {id, name, url, token, group} dicts."""
    tickets = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 3:
            continue
        tid, name, url = parts[0], parts[1], parts[2]
        if not re.match(r'^T\d+$', tid):
            continue
        tok = url_token(url)
        # KNOWN_TOKEN_GROUPS keys are short IDs (e.g. 't948206'); tok may be a full slug ending in that ID
        grp = next((g for kid, g in KNOWN_TOKEN_GROUPS.items() if kid in tok), None) or classify_ticket(name, url)
        tickets.append({'id': tid, 'name': name, 'url': url, 'token': tok, 'group': grp})
    return tickets


# ── text cleanup for affiliate link display text ─────────────────────────────

def clean_buy_text(raw_text, is_combo=False):
    t = htmllib.unescape(raw_text)
    for pat in [r'\bTopkap[ıi]\s+Palace\b', r'\btopkap[ıi]\s+palace\b',
                r'\bTopkap[ıi]\b', r'\btopkap[ıi]\b']:
        t = re.sub(pat, '', t, flags=re.IGNORECASE)
    t = re.sub(r'\s+of\s+and\s+', ' & ', t, flags=re.IGNORECASE)
    t = re.sub(r'\s+of\s+\+', ' +', t, flags=re.IGNORECASE)
    t = re.sub(r'\bPrivate\s+and\s+', 'Private ', t, flags=re.IGNORECASE)
    t = re.sub(r',\s+and\s+', ', ', t, flags=re.IGNORECASE)
    if is_combo:
        t = re.sub(r'\s*\+?\s*combo\s+ticket\s*$', '', t, flags=re.IGNORECASE).strip()
        t = re.sub(r'\s*combo\s*$', '', t, flags=re.IGNORECASE).strip()
    t = re.sub(r'  +', ' ', t).strip()
    t = re.sub(r'^[\s,&]+', '', t)
    t = re.sub(r'^(and|of|with|or)\s+', '', t, flags=re.IGNORECASE)
    t = re.sub(r'\s*[,&]?\s*(and|of|with|,|&)$', '', t, flags=re.IGNORECASE).strip()
    t = re.sub(r'  +', ' ', t).strip()
    if t:
        t = t[0].upper() + t[1:]
    if is_combo and not t.startswith('+'):
        t = '+ ' + t
    return t


# ── HTML reconstruction helpers ───────────────────────────────────────────────

def make_group_html(details_open, summary_html, new_links_lines):
    links = '\n'.join(new_links_lines)
    return (f'{details_open}\n'
            f'        {summary_html}\n'
            f'        <div class="mp-links">\n'
            f'{links}\n'
            f'        </div>\n'
            f'      </details>')


def slug_from_href(href):
    return href.rstrip('/').split('/')[-1]


# ── Buy Tickets rebuilder (tickets.md-driven) ─────────────────────────────────

def rebuild_buy_tickets(group_html, tickets):
    """
    Rebuild Buy Tickets using tickets.md as source of truth.
    Matches existing anchors by URL token; builds new anchor from tickets.md
    URL if not found in current menu.
    """
    details_open = re.match(r'<details[^>]*>', group_html).group(0)
    summary_html  = re.search(r'<summary>.*?</summary>', group_html, re.DOTALL).group(0)

    # Build token → anchor map from current menu
    anchors = re.findall(r'<a [^>]+>.*?</a>', group_html, re.DOTALL)
    menu_by_token = {}
    for a in anchors:
        href_m = re.search(r'href="([^"]+)"', a)
        if href_m:
            tok = url_token(href_m.group(1))
            if tok not in menu_by_token:
                menu_by_token[tok] = a

    # Group tickets by classification
    classified = {gk: [] for gk in GROUP_ORDER}
    for t in tickets:
        classified[t['group']].append(t)

    new_lines = []
    for gk in GROUP_ORDER:
        items = classified[gk]
        if not items:
            continue
        new_lines.append(f'          <div class="mp-section-label">{GROUP_LABELS[gk]}</div>')
        is_combo = (gk == "combo")
        for t in items:
            a = menu_by_token.get(t['token'])
            if a:
                # Rewrite display text with cleaned name from tickets.md
                text_m = re.search(r'>([^<]+)</a>', a)
                if text_m:
                    cleaned = clean_buy_text(t['name'], is_combo=is_combo)
                    a = a[:text_m.start(1)] + cleaned + a[text_m.end(1):]
            else:
                # Ticket in tickets.md but not in current menu — construct anchor
                print(f'  WARN: {t["id"]} token {t["token"]!r} not in menu — adding from tickets.md', file=sys.stderr)
                cleaned = clean_buy_text(t['name'], is_combo=is_combo)
                a = f'<a href="{htmllib.escape(t["url"])}" rel="noopener nofollow sponsored" target="_blank">{cleaned}</a>'
            new_lines.append(f'          {a}')

    # Report any menu anchors not covered by tickets.md
    md_tokens = {t['token'] for t in tickets}
    for tok, a in menu_by_token.items():
        if tok not in md_tokens:
            href = re.search(r'href="([^"]+)"', a).group(1)
            print(f'  WARN: menu link {tok!r} not in tickets.md — DROPPED: {href[:70]}', file=sys.stderr)

    return make_group_html(details_open, summary_html, new_lines)


# ── Article silo rebuilder ────────────────────────────────────────────────────

def rebuild_group(group_html, silo_key):
    silo = groupings.get(silo_key)
    if not silo:
        return group_html

    details_open = re.match(r'<details[^>]*>', group_html).group(0)
    summary_html  = re.search(r'<summary>.*?</summary>', group_html, re.DOTALL).group(0)

    anchors = re.findall(r'<a [^>]+>.*?</a>', group_html, re.DOTALL)
    hub_anchors     = [a for a in anchors if 'mp-hub' in a]
    article_anchors = [a for a in anchors if 'mp-hub' not in a]

    slug_to_a = {}
    for a in article_anchors:
        hrefs = re.findall(r'href="([^"]+)"', a)
        if hrefs:
            s = slug_from_href(hrefs[0])
            if s not in slug_to_a:
                slug_to_a[s] = a

    new_lines = []
    for h in hub_anchors:
        new_lines.append(f'          {h}')
    for g in silo['groups']:
        new_lines.append(f'          <div class="mp-section-label">{g["label"]}</div>')
        for slug in g['slugs']:
            a = slug_to_a.get(slug)
            if a:
                new_lines.append(f'          {a}')
            else:
                print(f'  WARN: slug {slug!r} not in menu', file=sys.stderr)

    return make_group_html(details_open, summary_html, new_lines)


# ── Div depth-walker (for nested div content extraction) ─────────────────────

def find_div_end(html, open_pos):
    """Given position of '<div', walk forward to find matching '</div>'.
    Returns position of the '</div>' start, or -1 if not found."""
    # Advance past the opening tag itself
    tag_end = html.find('>', open_pos)
    if tag_end == -1:
        return -1
    pos = tag_end + 1
    depth = 1
    while pos < len(html) and depth > 0:
        open_m  = html.find('<div', pos)
        close_m = html.find('</div>', pos)
        if close_m == -1:
            return -1
        if open_m != -1 and open_m < close_m:
            depth += 1
            pos = open_m + 4
        else:
            depth -= 1
            if depth == 0:
                return close_m
            pos = close_m + 6
    return -1


# ── Desktop dropdown rebuilders ───────────────────────────────────────────────

def rebuild_desktop_buy_tickets(grid_html, tickets):
    """Rebuild drop-grid content for desktop Buy Tickets dropdown."""
    anchors = re.findall(r'<a [^>]+>.*?</a>', grid_html, re.DOTALL)

    menu_by_token = {}
    for a in anchors:
        href_m = re.search(r'href="([^"]+)"', a)
        if href_m:
            tok = url_token(href_m.group(1))
            if tok not in menu_by_token:
                menu_by_token[tok] = a

    classified = {gk: [] for gk in GROUP_ORDER}
    for t in tickets:
        classified[t['group']].append(t)

    new_lines = ['              ']
    for gk in GROUP_ORDER:
        items = classified[gk]
        if not items:
            continue
        new_lines.append(f'              <div class="drop-label">{GROUP_LABELS[gk]}</div>')
        is_combo = (gk == "combo")
        for t in items:
            a = menu_by_token.get(t['token'])
            cleaned = clean_buy_text(t['name'], is_combo=is_combo)
            if a:
                # Replace text inside <span class="drop-buy-name">...</span>
                a = re.sub(r'(<span class="drop-buy-name">)[^<]*(</span>)',
                           lambda m, c=cleaned: m.group(1) + c + m.group(2), a)
            else:
                print(f'  WARN desktop: {t["id"]} not in menu — skipping', file=sys.stderr)
                continue
            new_lines.append(f'              {a}')

    return '\n'.join(new_lines) + '\n            '


def rebuild_desktop_silo(grid_html, silo_key):
    """Rebuild drop-grid content for desktop article silo dropdown."""
    silo = groupings.get(silo_key)
    if not silo:
        return grid_html

    anchors = re.findall(r'<a [^>]+>.*?</a>', grid_html, re.DOTALL)
    hub_anchors     = [a for a in anchors if 'drop-hub' in a]
    article_anchors = [a for a in anchors if 'drop-hub' not in a]

    slug_to_a = {}
    for a in article_anchors:
        hrefs = re.findall(r'href="([^"]+)"', a)
        if hrefs:
            s = slug_from_href(hrefs[0])
            if s not in slug_to_a:
                slug_to_a[s] = a

    new_lines = ['              ']
    for h in hub_anchors:
        new_lines.append(f'              {h}')
    for g in silo['groups']:
        new_lines.append(f'              <div class="drop-label">{g["label"]}</div>')
        for slug in g['slugs']:
            a = slug_to_a.get(slug)
            if a:
                new_lines.append(f'              {a}')
            else:
                print(f'  WARN desktop: slug {slug!r} not found', file=sys.stderr)

    return '\n'.join(new_lines) + '\n            '


def process_desktop_dropdowns(html_in, tickets):
    """Find each desktop .dropdown div and rebuild its drop-grid content."""
    result = html_in
    search_from = 0

    while True:
        # Find next dropdown div
        dd_start = result.find('<div class="dropdown"', search_from)
        if dd_start == -1:
            break
        dd_end = find_div_end(result, dd_start)
        if dd_end == -1:
            search_from = dd_start + 20
            continue

        dd_full_end = dd_end + len('</div>')
        dd = result[dd_start:dd_full_end]

        aria = re.search(r'aria-label="([^"]+)"', dd)
        if not aria:
            search_from = dd_full_end
            continue
        label = aria.group(1).strip()

        # Map label to silo key
        silo_map = {
            'Tickets and Tours': 'tickets-tours',
            'Plan Your Visit':   'plan-your-visit',
            'What to See':       'what-to-see',
        }

        # Find drop-grid div inside dd (depth-counted)
        grid_tag_start = dd.find('<div class="drop-grid')
        if grid_tag_start == -1:
            search_from = dd_full_end
            continue
        grid_tag_end_close = dd.find('>', grid_tag_start) + 1
        grid_end = find_div_end(dd, grid_tag_start)
        if grid_end == -1:
            search_from = dd_full_end
            continue

        grid_content = dd[grid_tag_end_close:grid_end]

        if label == 'Buy Tickets' and tickets:
            print(f'  Desktop: Buy Tickets → sub-groups', file=sys.stderr)
            new_content = rebuild_desktop_buy_tickets(grid_content, tickets)
        elif label in silo_map:
            sk = silo_map[label]
            print(f'  Desktop: {label} → {sk}', file=sys.stderr)
            new_content = rebuild_desktop_silo(grid_content, sk)
        else:
            search_from = dd_full_end
            continue

        new_dd = dd[:grid_tag_end_close] + new_content + dd[grid_end:]
        result = result[:dd_start] + new_dd + result[dd_full_end:]
        search_from = dd_start + len(new_dd)

    return result


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--tickets', default=None,
                    help='Path to tickets.md (default: auto-detect from input/<site>/)')
    ap.add_argument('--site', default=None,
                    help='Site slug (e.g. topkapi-palace) — loads input/<site>/menu_groupings.json')
    args = ap.parse_args()

    # Load site-specific article groupings
    global groupings
    groupings = load_groupings(args.site)

    # Auto-detect tickets.md
    here = Path(__file__).parent
    root = here.parent.parent
    if args.tickets:
        tickets_path = args.tickets
    elif args.site:
        candidate = root / 'input' / args.site / 'tickets.md'
        tickets_path = str(candidate) if candidate.exists() else None
    else:
        candidates = list(root.glob('input/*/tickets.md'))
        tickets_path = str(candidates[0]) if candidates else None

    tickets = []
    if tickets_path:
        try:
            tickets = parse_tickets_md(tickets_path)
            print(f'  Loaded {len(tickets)} tickets from {tickets_path}', file=sys.stderr)
        except Exception as e:
            print(f'  WARN: could not load tickets.md ({e}) — Buy Tickets group unchanged', file=sys.stderr)
    else:
        print('  WARN: no tickets.md found — Buy Tickets group unchanged', file=sys.stderr)

    html_in = sys.stdin.read()

    def process_group(m):
        group_html = m.group(0)
        summary = re.findall(r'<summary><span>([^<]+)<', group_html)
        label = re.sub(r'&amp;', '&', summary[0]).strip() if summary else ''

        if label == 'Buy Tickets':
            print(f'  Processing: Buy Tickets → tickets.md-driven sub-groups', file=sys.stderr)
            if tickets:
                return rebuild_buy_tickets(group_html, tickets)
            return group_html

        silo_key = silo_keywords.get(label)
        if not silo_key:
            print(f'  WARN: unknown group label {label!r}', file=sys.stderr)
            return group_html
        print(f'  Processing: {label} → {silo_key}', file=sys.stderr)
        return rebuild_group(group_html, silo_key)

    # Pass 1: mobile panel (details.mp-group)
    new_html = re.sub(
        r'<details class="mp-group"[^>]*>.*?</details>',
        process_group,
        html_in,
        flags=re.DOTALL
    )
    # Pass 2: desktop dropdowns (.dropdown divs)
    new_html = process_desktop_dropdowns(new_html, tickets)
    print(new_html, end='')


if __name__ == '__main__':
    main()
