#!/usr/bin/env python3
"""Layer 2: CHECK — pure function. snapshot + spec → violations.

No SSH. No Claude. Deterministic. Same input → same output.
Usage: python3 check.py <snapshot.json> [spec.yaml] [--out violations.json]
"""
import sys, os, json, re, argparse
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


def get_nested(d, dotted_key):
    """options.foo.bar → d['options']['foo']['bar'] (None if missing)."""
    cur = d
    for k in dotted_key.split('.'):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def v(severity, vid, category, target, message, **extra):
    """Build a violation dict."""
    return {
        'id':       vid,
        'severity': severity,
        'category': category,
        'target':   target,
        'message':  message,
        **extra,
    }


def check_site(snap, spec):
    out = []
    site = snap['site']

    # Permalink structure
    expected = spec['site']['permalink_structure']
    actual   = site.get('permalink_structure')
    if actual != expected:
        out.append(v('critical', 'permalink-wrong', 'site',
                     {'type': 'option', 'key': 'permalink_structure'},
                     f"permalink_structure is {actual!r}, expected {expected!r}",
                     expected=expected, actual=actual, fixable=True))

    # Site icon
    if spec['site'].get('site_icon_required') and not site.get('site_icon'):
        out.append(v('high', 'site-icon-missing', 'site',
                     {'type': 'option', 'key': 'site_icon'},
                     "site_icon option not set", fixable=False))

    # Required categories
    existing_cats = {c['slug'] for c in snap['categories']}
    for req in spec['site']['categories_required']:
        if req not in existing_cats:
            out.append(v('critical', f'category-missing-{req}', 'site',
                         {'type': 'category', 'slug': req},
                         f"required category '{req}' does not exist", fixable=True))

    # Options required
    for dotted, expected_val in (spec['site'].get('options_required') or {}).items():
        actual_val = get_nested(site.get('options', {}), dotted)
        if expected_val is None:
            if actual_val is None:
                out.append(v('medium', f'option-missing-{dotted}', 'site',
                             {'type': 'option_nested', 'path': dotted},
                             f"option {dotted} not set"))
        elif actual_val != expected_val:
            out.append(v('medium', f'option-value-{dotted.replace(".","-")}', 'site',
                         {'type': 'option_nested', 'path': dotted},
                         f"option {dotted} is {actual_val!r}, expected {expected_val!r}",
                         expected=expected_val, actual=actual_val, fixable=True))

    return out


def check_item(item, spec_block, kind, allowed_external, published_slugs, excluded_slugs):
    """kind is 'post' or 'page'. spec_block = spec['posts'] or spec['pages']."""
    out = []
    slug = item['slug']
    if slug in excluded_slugs:
        return out
    tid = {'type': kind, 'id': item['id'], 'slug': slug}

    # Required meta
    for rule in spec_block.get('required_meta', []):
        key = rule['key']
        if not item['meta'].get(key):
            out.append(v(rule['severity'], f'meta-missing-{key}', f'{kind}-meta',
                         tid, f"{kind} '{slug}' missing meta {key}",
                         meta_key=key, fixable=True))

    # Forbidden non-empty meta
    for rule in spec_block.get('forbidden_nonempty_meta', []):
        key = rule['key']
        val = item['meta'].get(key)
        if val:
            out.append(v(rule['severity'], f'meta-forbidden-{key}', f'{kind}-meta',
                         tid, f"{kind} '{slug}' has forbidden non-empty meta {key}={val!r}",
                         meta_key=key, meta_value=val, fixable=True))

    # Featured image
    fi_rule = spec_block.get('featured_image_required')
    if fi_rule and not item['featured_image']:
        out.append(v(fi_rule['severity'], 'featured-image-missing', f'{kind}-image',
                     tid, f"{kind} '{slug}' missing featured image", fixable=False))

    # Absolute internal links (posts only)
    if kind == 'post' and spec_block.get('forbid_absolute_internal_links'):
        if item['flags'].get('has_absolute_urls') or item['links']['internal_absolute']:
            sev = spec_block['forbid_absolute_internal_links']['severity']
            out.append(v(sev, 'absolute-internal-links', 'post-content',
                         tid,
                         f"{kind} '{slug}' contains absolute internal URLs ({len(item['links']['internal_absolute'])} hrefs)",
                         sample=item['links']['internal_absolute'][:3], fixable=True))

    # Forbidden content patterns
    for rule in spec_block.get('forbidden_content_patterns', []):
        flag_name = {
            'backtick-fence':  'has_backtick_html',
            'padding-40':      'has_padding_40',
            'padding-24':      'has_padding_24',
            'placeholder-gif': 'has_placeholder_gif',
        }.get(rule['id'])
        hit = item['flags'].get(flag_name) if flag_name else (rule['pattern'] in item['content'])
        if hit:
            out.append(v(rule['severity'], rule['id'], f'{kind}-content',
                         tid, f"{kind} '{slug}' contains pattern {rule['pattern']!r}",
                         pattern=rule['pattern'], fixable=True))

    # FAQ onclick conflict
    if kind == 'post' and spec_block.get('faq_onclick_conflict'):
        if item['flags'].get('has_faq_onclick'):
            sev = spec_block['faq_onclick_conflict']['severity']
            out.append(v(sev, 'faq-onclick-conflict', 'post-content',
                         tid, f"{kind} '{slug}' has onclick= on .att-faq-item__q (conflicts with addEventListener)",
                         fixable=True))

    # External link allowlist
    host_suffix_ok = lambda h: any(h.endswith(d) or ('.' + d) in h for d in allowed_external)
    leaked = []
    for href in item['links']['external']:
        m = re.match(r'https?://([^/]+)', href)
        if not m:
            continue
        host = m.group(1).lower().split(':')[0]
        if not host_suffix_ok(host):
            leaked.append(href)
    if leaked:
        out.append(v('low', 'external-link-leak', f'{kind}-content',
                     tid, f"{kind} '{slug}' has {len(leaked)} unexpected external links",
                     sample=leaked[:3]))

    # Internal link targets must exist
    for href in item['links']['internal_relative']:
        # strip query/hash, take last non-empty segment
        path = href.split('#')[0].split('?')[0].rstrip('/')
        if not path:
            continue
        last = path.split('/')[-1]
        if not last:
            continue
        if last not in published_slugs:
            out.append(v('critical', 'broken-internal-link', f'{kind}-content',
                         tid, f"{kind} '{slug}' links to non-existent slug '{last}' (href {href})",
                         href=href, missing_slug=last, fixable=False))

    return out


HOSTNAME_TO_INPUT_SLUG = {
    'topkapipalace-guide.com':      'topkapi-palace',
    'bluemosque-guide.com':         'blue-mosque',
    'hagiasophia-guide.com':        'hagia-sofia',
    'montsaintmichel-guide.com':    'mont-saint-michel',
    'vangoghmuseum-guide.com':      'van-gogh',
    'plitvicelakes-guide.com':      'plitvice-lakes',
    'angkorwat-guide.com':          'angkor-wat',
}


def parse_tickets_md(input_dir):
    """Parse tickets.md → list of {id, name, url}."""
    tm = Path(input_dir) / 'tickets.md'
    if not tm.exists():
        return []
    tickets = []
    for line in open(tm):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) >= 3 and parts[0].startswith('T'):
            tickets.append({'id': parts[0], 'name': parts[1], 'url': parts[2]})
    return tickets


def check_menu_integrity(snap, spec):
    """Verify GP Element menu contains:
    1. All tickets.md entries as drop-buy links
    2. All published posts in their category mp-group
    3. Each article mp-group has 3-5 mp-section-label sub-groups
    4. Book Now CTA button exists with a real href
    Spec key: menu.element_title (default: 'Menu')
    """
    out = []
    menu_spec = spec.get('menu', {})
    if not menu_spec.get('check', True):
        return out

    menu_title = menu_spec.get('element_title', 'Menu')
    menu_el = next((e for e in snap.get('gp_elements', []) if e['title'] == menu_title), None)
    if not menu_el or not menu_el.get('content'):
        out.append(v('high', 'menu-element-missing', 'menu',
                     {'type': 'gp_element', 'title': menu_title},
                     f"GP Element '{menu_title}' not found or has no content — run audit after full capture"))
        return out

    html = menu_el['content']
    tid = {'type': 'gp_element', 'id': menu_el['id'], 'title': menu_title}

    # 0. Native GP header hidden — .site-header must have display:none in menu CSS
    if '.site-header' not in html or 'display: none' not in html:
        out.append(v('high', 'menu-site-header-not-hidden', 'menu',
                     tid,
                     "Menu GP element CSS missing '.site-header { display: none !important }' — "
                     "native GP header renders and creates blank gap above content",
                     fixable=True))

    # 1. Ticket affiliate links — drop-buy hrefs
    buy_hrefs = set(re.findall(r'class="drop-item drop-buy"[^>]*href="([^"]+)"', html))
    # Normalize: strip HTML entities + query params for comparison
    def norm_url(u): return re.sub(r'&amp;', '&', u).split('?')[0]
    buy_norm = {norm_url(h) for h in buy_hrefs}

    input_slug = HOSTNAME_TO_INPUT_SLUG.get(snap['site']['hostname'], '')
    input_dir = Path(__file__).parent.parent.parent / 'input' / input_slug
    tickets_md = parse_tickets_md(input_dir) if input_slug else []
    for t in tickets_md:
        url_norm = norm_url(t.get('url', ''))
        if not any(url_norm in b or b in url_norm for b in buy_norm):
            out.append(v('high', 'menu-ticket-missing', 'menu',
                         {**tid, 'ticket_id': t.get('id'), 'ticket_name': t.get('name')},
                         f"ticket '{t.get('id')} {t.get('name')}' from tickets.md not found in menu Buy Tickets dropdown",
                         fixable=False))

    # 2. Published posts in category mp-groups
    groups = re.findall(r'<details class="mp-group"[^>]*>(.*?)</details>', html, re.DOTALL)
    post_slugs_in_menu = set()
    article_groups = []
    for g in groups:
        summary = re.findall(r'<summary><span>([^<]+)<', g)
        label = re.sub(r'&amp;', '&', summary[0]) if summary else ''
        hrefs = re.findall(r'href="([^"]+)"', g)
        section_labels = re.findall(r'class="mp-section-label">([^<]+)<', g)
        # Skip the affiliate/buy-tickets group (has drop-buy links, not article links)
        if re.search(r'class="drop-item drop-buy"', g):
            continue
        article_groups.append({'label': label, 'hrefs': hrefs, 'section_labels': section_labels})
        for href in hrefs:
            parts = [p for p in href.rstrip('/').split('/') if p]
            if parts:
                post_slugs_in_menu.add(parts[-1])

    post_slugs = {p['slug'] for p in snap['posts']}
    missing_from_menu = post_slugs - post_slugs_in_menu
    for slug in sorted(missing_from_menu):
        out.append(v('medium', 'menu-post-missing', 'menu',
                     {**tid, 'slug': slug},
                     f"post '{slug}' not linked from any menu dropdown",
                     fixable=False))

    # 3. Sub-group count per article mp-group (3-5 section labels)
    min_groups = menu_spec.get('min_subgroups', 3)
    max_groups = menu_spec.get('max_subgroups', 5)
    for ag in article_groups:
        n = len(ag['section_labels'])
        if n < min_groups:
            out.append(v('medium', 'menu-subgroups-too-few', 'menu',
                         {**tid, 'dropdown': ag['label']},
                         f"menu '{ag['label']}' has {n} sub-group label(s) — need {min_groups}–{max_groups}",
                         fixable=False))
        elif n > max_groups:
            out.append(v('low', 'menu-subgroups-too-many', 'menu',
                         {**tid, 'dropdown': ag['label']},
                         f"menu '{ag['label']}' has {n} sub-group labels — max is {max_groups}"))

    # 4. Desktop dropdown sub-group counts (.drop-label divs per .dropdown)
    def _find_div_end(h, open_pos):
        tag_end = h.find('>', open_pos)
        if tag_end == -1:
            return -1
        pos = tag_end + 1
        depth = 1
        while pos < len(h) and depth > 0:
            open_m  = h.find('<div', pos)
            close_m = h.find('</div>', pos)
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

    buy_min = menu_spec.get('buy_tickets_min_subgroups', 2)
    buy_max = menu_spec.get('buy_tickets_max_subgroups', max_groups)
    desktop_silo_labels = {'Tickets and Tours', 'Plan Your Visit', 'What to See'}
    sf = 0
    while True:
        dd_start = html.find('<div class="dropdown"', sf)
        if dd_start == -1:
            break
        dd_end = _find_div_end(html, dd_start)
        if dd_end == -1:
            sf = dd_start + 20
            continue
        dd_html = html[dd_start:dd_end + 6]
        aria_m = re.search(r'aria-label="([^"]+)"', dd_html)
        sf = dd_end + 6
        if not aria_m:
            continue
        dlabel = aria_m.group(1).strip()
        drop_labels = re.findall(r'<div class="drop-label">([^<]+)</div>', dd_html)
        n = len(drop_labels)
        if dlabel == 'Buy Tickets':
            if n < buy_min:
                out.append(v('medium', 'menu-buy-subgroups-too-few-desktop', 'menu',
                             {**tid, 'dropdown': dlabel, 'device': 'desktop'},
                             f"desktop 'Buy Tickets' has {n} sub-group label(s) — need {buy_min}–{buy_max}",
                             fixable=False))
            elif n > buy_max:
                out.append(v('low', 'menu-buy-subgroups-too-many-desktop', 'menu',
                             {**tid, 'dropdown': dlabel, 'device': 'desktop'},
                             f"desktop 'Buy Tickets' has {n} sub-group labels — max is {buy_max}"))
        elif dlabel in desktop_silo_labels:
            if n < min_groups:
                out.append(v('medium', 'menu-subgroups-too-few-desktop', 'menu',
                             {**tid, 'dropdown': dlabel, 'device': 'desktop'},
                             f"desktop '{dlabel}' has {n} sub-group label(s) — need {min_groups}–{max_groups}",
                             fixable=False))
            elif n > max_groups:
                out.append(v('low', 'menu-subgroups-too-many-desktop', 'menu',
                             {**tid, 'dropdown': dlabel, 'device': 'desktop'},
                             f"desktop '{dlabel}' has {n} sub-group labels — max is {max_groups}"))

    # 5. Book Now CTA button
    cta_hrefs = re.findall(r'<a\s[^>]*class="[^"]*\bcta\b[^"]*"[^>]*href="([^"]+)"|<a\s[^>]*href="([^"]+)"[^>]*class="[^"]*\bcta\b[^"]*"', html)
    cta_flat = [h for pair in cta_hrefs for h in pair if h]
    if not cta_flat:
        out.append(v('high', 'menu-book-now-missing', 'menu',
                     tid,
                     "no 'Book Now' CTA button found in menu (class=nav-cta) — add affiliate URL",
                     fixable=False))
    else:
        placeholder_patterns = ['example.com', 'YOUR_URL', '#', 'placeholder']
        for href in cta_flat:
            if any(p in href for p in placeholder_patterns):
                out.append(v('high', 'menu-book-now-placeholder', 'menu',
                             {**tid, 'href': href},
                             f"Book Now CTA href looks like placeholder: '{href}'",
                             fixable=False))

    return out


def check_homepage_container_width(snap, spec):
    """Homepage .att-container must NOT have restrictive percentage max-width overrides.
    Older homepage templates cap .att-container at 74%/82%/88%/94% per breakpoint,
    making content look narrow vs full-width sites."""
    out = []
    homepage = next((p for p in snap.get('pages', []) if p['slug'] == 'homepage'), None)
    if not homepage:
        return out
    content = homepage.get('content', '')
    if re.search(r'\.att-container\s*\{\s*max-width:\s*[78][0-9]%', content):
        out.append(v('high', 'homepage-container-width-restricted', 'pages',
                     {'type': 'page', 'slug': 'homepage'},
                     "homepage .att-container has restrictive % max-width override (74%/82%/88%) — "
                     "content appears narrow; replace with max-width: 100%",
                     fixable=True))
    return out


def check_l1_card_hrefs(snap, spec):
    """L1 silo pages: every att-highlight card href must point to a published POST (not a page).
    Catches cases where card links to a category page slug instead of an article slug.
    Spec key: pages.l1_card_pages — list of page slugs to check."""
    out = []
    l1_slugs = set(spec['pages'].get('l1_card_pages', []))
    if not l1_slugs:
        return out

    post_slugs = {p['slug'] for p in snap['posts']}
    page_slugs = {p['slug'] for p in snap['pages']}
    pages_by_slug = {p['slug']: p for p in snap['pages']}

    href_re = re.compile(r'href="(/[^"#?]+)"')

    for pg in snap['pages']:
        if pg['slug'] not in l1_slugs:
            continue
        tid = {'type': 'page', 'id': pg['id'], 'slug': pg['slug']}
        content = pg.get('content', '')

        # Only inspect hrefs inside att-highlight blocks
        for block in re.findall(r'class="att-highlight[^"]*"[^>]*>.*?</div\s*>', content, re.DOTALL):
            for href in href_re.findall(block):
                parts = [p for p in href.rstrip('/').split('/') if p]
                if not parts:
                    continue
                last = parts[-1]
                if last in page_slugs and last not in post_slugs:
                    out.append(v('high', 'l1-card-href-points-to-page', 'page-content',
                                 tid,
                                 f"page '{pg['slug']}' card href '{href}' points to page slug '{last}' — should point to a post",
                                 href=href, bad_slug=last, fixable=True))
    return out


def check_post_structure(snap, spec):
    """Per-post structural checks:
    - att-top-tickets block present with 2-3 affiliate links
    - ticket-category posts: first h2 after top-tickets contains 'included'
    - ticket-category posts: att-buy-now-btn present
    - accent color --accent: #ff0000 in CSS
    - FAQs use <details> element, not onclick
    """
    out = []
    ticket_cat = spec['site'].get('ticket_category', 'tickets')

    # Build set of ticket-category post slugs from snapshot categories
    ticket_slugs = set()
    cats_by_slug = {c['slug']: c for c in snap.get('categories', [])}
    ticket_cat_id = cats_by_slug.get(ticket_cat, {}).get('id')
    for p in snap['posts']:
        if ticket_cat_id and ticket_cat_id in [c.get('id') for c in p.get('categories', [])]:
            ticket_slugs.add(p['slug'])

    for p in snap['posts']:
        slug = p['slug']
        content = p.get('content', '')
        tid = {'type': 'post', 'id': p['id'], 'slug': slug}
        is_ticket = slug in ticket_slugs

        # 1. Top tickets bar
        has_top_tickets = 'att-top-tickets' in content
        if not has_top_tickets:
            out.append(v('high', 'post-missing-top-tickets', 'post-content', tid,
                         f"post '{slug}' missing .att-top-tickets section", fixable=False))
        else:
            # Count affiliate links inside the top-tickets block
            tt_block = re.search(r'class="att-top-tickets".*?</div>', content, re.DOTALL)
            if tt_block:
                aff_links = re.findall(
                    r'href="https?://(?:www\.)?(?:getyourguide|viator|tiqets)\.com[^"]*"',
                    tt_block.group(0))
                if len(aff_links) < 2:
                    out.append(v('medium', 'post-top-tickets-too-few-links', 'post-content', tid,
                                 f"post '{slug}' top-tickets bar has {len(aff_links)} affiliate link(s) — need 2-3",
                                 fixable=False))

        # 2. Ticket posts: "What's Included" h2
        if is_ticket:
            h2s = re.findall(r'<h2[^>]*>(.*?)</h2>', content, re.IGNORECASE | re.DOTALL)
            # Find first h2 after top-tickets
            tt_pos = content.find('att-top-tickets')
            if tt_pos != -1:
                after_tt = content[tt_pos:]
                h2_after = re.findall(r'<h2[^>]*>(.*?)</h2>', after_tt, re.IGNORECASE | re.DOTALL)
                first_h2 = re.sub(r'<[^>]+>', '', h2_after[0]).lower() if h2_after else ''
                if 'includ' not in first_h2 and 'what' not in first_h2:
                    out.append(v('medium', 'ticket-post-missing-whats-included', 'post-content', tid,
                                 f"ticket post '{slug}' first h2 after top-tickets is '{first_h2[:60]}' — expected 'What's Included' variant",
                                 fixable=False))

            # 3. Buy-now button
            if 'att-buy-now-btn' not in content:
                out.append(v('medium', 'ticket-post-missing-buy-btn', 'post-content', tid,
                             f"ticket post '{slug}' missing .att-buy-now-btn", fixable=False))

        # 4. Accent color
        if '--accent:' in content and '#ff0000' not in content:
            # Check CSS block for wrong accent
            css_match = re.search(r'--accent:\s*([^;]+);', content)
            if css_match and '#ff0000' not in css_match.group(1):
                out.append(v('medium', 'post-wrong-accent-color', 'post-content', tid,
                             f"post '{slug}' --accent is '{css_match.group(1).strip()}' not #ff0000",
                             fixable=True))

        # 5. FAQs use <details> not onclick
        has_faq = 'att-faq' in content
        if has_faq:
            uses_details = '<details' in content
            uses_onclick = bool(re.search(r'att-faq[^"]*"[^>]*onclick', content))
            if not uses_details and uses_onclick:
                out.append(v('medium', 'post-faq-uses-onclick-not-details', 'post-content', tid,
                             f"post '{slug}' FAQ uses onclick JS pattern — should use <details> element",
                             fixable=True))

    return out


def check_affiliate_campaign_ids(snap, spec):
    """Every affiliate URL (GYG/Viator/Tiqets) must have correct partner params
    and campaign ID:
      top-tickets bar  → {prefix}-{slug}-top
      body links       → {prefix}-{slug}
    HTML entity encoding (&amp;) is normalized before checking.
    """
    out = []
    prefix = spec['site'].get('campaign_prefix', '')
    if not prefix:
        return out

    # (domain_fragment, partner_param_regex, campaign_param_regex, campaign_key)
    PARTNERS = [
        ('getyourguide.com', r'partner_id=9BAL9K3',       r'[?&]cmp=([^&"]+)',          'cmp'),
        ('viator.com',       r'pid=P00038490',             r'[?&]campaign=([^&"]+)',      'campaign'),
        ('tiqets.com',       r'partner=thebettervacation', r'[?&]tq_campaign=([^&"]+)',   'tq_campaign'),
    ]

    for p in snap['posts']:
        slug = p['slug']
        content = p.get('content', '')
        tid = {'type': 'post', 'id': p['id'], 'slug': slug}
        expected_body_cid = f"{prefix}-{slug}"
        expected_top_cid  = f"{prefix}-{slug}-top"

        # Extract top-tickets block URLs (normalized)
        tt_match = re.search(r'class="att-top-tickets".*?</ul>', content, re.DOTALL)
        tt_urls_norm = set()
        if tt_match:
            for raw in re.findall(r'href="(https?://[^"]+)"', tt_match.group(0)):
                tt_urls_norm.add(raw.replace('&amp;', '&'))

        all_aff = re.findall(
            r'href="(https?://(?:www\.)?(?:getyourguide|viator|tiqets)\.com[^"]*)"', content)

        for raw_url in all_aff:
            url = raw_url.replace('&amp;', '&')
            in_top = url in tt_urls_norm
            expected_cid = expected_top_cid if in_top else expected_body_cid

            for domain, partner_re, campaign_re, campaign_key in PARTNERS:
                if domain not in url:
                    continue

                # Check partner param
                if not re.search(partner_re, url):
                    out.append(v('high', 'affiliate-missing-partner-param', 'post-content', tid,
                                 f"post '{slug}' affiliate URL missing partner param ({domain}): {url[:80]}",
                                 url=url, fixable=True))
                    continue

                # Check campaign ID
                cid_match = re.search(campaign_re, url)
                if not cid_match:
                    out.append(v('medium', 'affiliate-missing-campaign-id', 'post-content', tid,
                                 f"post '{slug}' affiliate URL missing {campaign_key}= param: {url[:80]}",
                                 url=url, expected_campaign=expected_cid, fixable=True))
                elif cid_match.group(1) != expected_cid:
                    out.append(v('medium', 'affiliate-wrong-campaign-id', 'post-content', tid,
                                 f"post '{slug}' affiliate URL has {campaign_key}={cid_match.group(1)!r} — expected {expected_cid!r}",
                                 url=url, expected=expected_cid, actual=cid_match.group(1), fixable=True))
    return out


def check_site_setup(snap, spec):
    """Check required plugins and additional CSS are present."""
    out = []
    site = snap.get('site', {})

    # Additional CSS must contain Firestorm marker
    custom_css = site.get('custom_css', '')
    if 'FIRESTORM ADDITIONAL CSS' not in custom_css:
        out.append(v('high', 'firestorm-additional-css-missing', 'site',
                     {'type': 'site'},
                     "Firestorm additional CSS block missing — run configure-additional-css.sh",
                     fixable=False))

    # Required plugins
    active_plugins = site.get('active_plugins', [])
    plugin_str = ' '.join(active_plugins)
    required_plugins = spec['site'].get('required_plugins', [])
    for plugin in required_plugins:
        if plugin not in plugin_str:
            out.append(v('high', f'plugin-missing-{plugin}', 'site',
                         {'type': 'site'},
                         f"Required plugin '{plugin}' is not active",
                         fixable=False))
    return out


def check_utility_pages(pages, spec):
    out = []
    util = spec['pages'].get('utility', {})
    util_slugs = set(util.get('slugs', []))
    for pg in pages:
        if pg['slug'] not in util_slugs:
            continue
        tid = {'type': 'page', 'id': pg['id'], 'slug': pg['slug']}
        for rule in util.get('forbidden_nonempty_meta', []):
            key = rule['key']
            if pg['meta'].get(key):
                out.append(v(rule['severity'], f'util-forbidden-{key}', 'page-meta',
                             tid, f"utility page '{pg['slug']}' has forbidden meta {key}={pg['meta'][key]!r}",
                             meta_key=key, fixable=True))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('snapshot',  help='path to snapshot JSON')
    ap.add_argument('--spec',    default=None, help='path to spec.yaml (default: beside this script)')
    ap.add_argument('--out',     default=None, help='violations JSON output path')
    args = ap.parse_args()

    here = Path(__file__).parent
    spec_path = Path(args.spec) if args.spec else (here / 'spec.yaml')
    spec = yaml.safe_load(open(spec_path))
    snap = json.load(open(args.snapshot))

    # Override campaign_prefix from input/<site>/.env if available
    hostname = snap.get('site', {}).get('hostname', '')
    input_slug = HOSTNAME_TO_INPUT_SLUG.get(hostname)
    if input_slug:
        env_path = here.parent.parent / 'input' / input_slug / '.env'
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if line.startswith('CAMPAIGN_PREFIX='):
                    prefix = line.split('=', 1)[1].strip().strip('"').strip("'")
                    if prefix:
                        spec['site']['campaign_prefix'] = prefix
                    break

    allowed_external = set(spec['site'].get('allowed_external_domains', []))
    excluded_slugs   = set(spec['pages'].get('excluded_from_checks', []))

    # Set of all published slugs (posts + pages) for internal link validation
    published_slugs = {p['slug'] for p in snap['posts']} | {p['slug'] for p in snap['pages']}

    violations = []
    violations.extend(check_site(snap, spec))
    for p in snap['posts']:
        violations.extend(check_item(p, spec['posts'], 'post',
                                      allowed_external, published_slugs, excluded_slugs))
    for pg in snap['pages']:
        violations.extend(check_item(pg, spec['pages'], 'page',
                                      allowed_external, published_slugs, excluded_slugs))
    violations.extend(check_utility_pages(snap['pages'], spec))
    violations.extend(check_l1_card_hrefs(snap, spec))
    violations.extend(check_homepage_container_width(snap, spec))
    violations.extend(check_menu_integrity(snap, spec))
    violations.extend(check_site_setup(snap, spec))
    violations.extend(check_post_structure(snap, spec))
    violations.extend(check_affiliate_campaign_ids(snap, spec))

    # Sort by severity desc, then category
    order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
    violations.sort(key=lambda x: (order.get(x['severity'], 9), x['category'], x['id']))

    out_path = args.out
    if not out_path:
        snap_name = Path(args.snapshot).stem
        hostname = snap_name.rsplit('-', 2)[0] if '-' in snap_name else snap_name
        out_dir = here.parent.parent / 'output' / 'audit' / 'violations'
        out_dir.mkdir(parents=True, exist_ok=True)
        stamp = snap_name.rsplit('-', 2)[-2:] if '-latest' not in snap_name else ['latest']
        out_path = out_dir / f"{hostname}-{'-'.join(stamp)}.json" if stamp else out_dir / f"{hostname}.json"

    payload = {
        'snapshot':    str(args.snapshot),
        'hostname':    snap['site']['hostname'],
        'total':       len(violations),
        'by_severity': {sev: sum(1 for x in violations if x['severity']==sev)
                        for sev in ['critical', 'high', 'medium', 'low']},
        'violations':  violations,
    }
    with open(out_path, 'w') as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)

    print(f"\n=== CHECK: {snap['site']['hostname']} ===", file=sys.stderr)
    print(f"Total violations: {payload['total']}", file=sys.stderr)
    for sev, n in payload['by_severity'].items():
        marker = '!' if n > 0 else ' '
        print(f"  [{marker}] {sev:<9} {n}", file=sys.stderr)
    print(f"\nViolations: {out_path}", file=sys.stderr)


if __name__ == '__main__':
    main()
