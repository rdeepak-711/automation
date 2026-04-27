#!/usr/bin/env python3
"""
tickets_tours.py — L1 Tickets & Tours HTML assembler.

Usage:
  python3 -m scripts.content.l1_assembler.tickets_tours <site-slug> [--force]

Section order:
  1. Hero + rec-strip callouts
  2. Top Experiences (featured tickets, TOP_TICKET_INDEXES)
  3. Ticket article groups (1–3 groups, each with ticket cards)
  4. Comparison table
  5. How to pick — decision guide (4 cards)
  6. Informational article groups (1–3 groups, guide cards)
  7. Continue Exploring crosslinks
  8. Red CTA banner
  9. FAQs (button-accordion with Schema.org JSON-LD)
"""

import argparse
import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

PLACEHOLDER_IMG = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-tickets-tours-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent


# ─── Text helpers ─────────────────────────────────────────────────────────────

def _e(text: str) -> str:
    return html.escape(str(text), quote=True)


def _raw(text: str) -> str:
    return str(text)


# ─── Env loading ──────────────────────────────────────────────────────────────

def _load_env(site_slug: str) -> dict:
    env = {}
    for env_path in [REPO_ROOT / ".env", REPO_ROOT / "input" / site_slug / ".env"]:
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ─── Affiliate URL stamping ────────────────────────────────────────────────────

def _stamp_campaign(base_url: str, campaign_id: str) -> str:
    if base_url.startswith("/"):
        return base_url
    parsed = urlparse(base_url)
    host = parsed.hostname or ""
    params = parse_qs(parsed.query, keep_blank_values=True)
    for k in list(params):
        if k in ("partner_id", "cmp", "partner", "tq_campaign", "pid", "mcid", "medium", "campaign"):
            del params[k]
    clean = {k: v[0] if len(v) == 1 else v for k, v in params.items()}
    if "getyourguide.com" in host:
        clean["partner_id"] = "9BAL9K3"
        clean["cmp"] = campaign_id
    elif "tiqets.com" in host:
        clean["partner"] = "thebettervacation"
        clean["tq_campaign"] = campaign_id
    elif "viator.com" in host:
        clean["pid"] = "P00038490"
        clean["mcid"] = "42383"
        clean["medium"] = "link"
        clean["campaign"] = campaign_id
    else:
        clean["cmp"] = campaign_id
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, urlencode(clean, doseq=True), parsed.fragment))


def _is_affiliate(url: str) -> bool:
    return url.startswith("http") and any(d in url for d in ("getyourguide", "tiqets", "viator"))


# ─── CSS extraction ───────────────────────────────────────────────────────────

def _load_css() -> str:
    content = TEMPLATE_PATH.read_text(encoding="utf-8")
    m = re.search(r"<style>(.*?)</style>", content, re.DOTALL)
    if not m:
        return ""
    css = m.group(1)
    # CSS spec: @import must precede all other rules. Move it to the top.
    imp = re.search(r"[ \t]*@import\s+url\([^)]+\);[ \t]*\n?", css)
    if imp:
        css = imp.group(0).lstrip() + css[:imp.start()] + css[imp.end():]
    return css


# ─── Section renderers ─────────────────────────────────────────────────────────

def _render_hero(cfg: dict, h1_override: str | None = None, campaign_id: str = "") -> str:
    badge = _raw(cfg.get("badge", "Tickets &amp; Tours"))
    h1 = _raw(h1_override or cfg.get("h1", "Tickets &amp; Tours"))
    desc = _raw(cfg.get("desc", ""))
    # Hero always uses fixed anchor buttons matching the template
    cta1_label = "Explore Ticket Options"
    cta1_url = "#tt-top-picks"
    cta2_label = "Read FAQs"
    cta2_url = "#tt-faqs"
    return f"""  <section class="att-hero">
    <div class="att-container">
      <div class="att-hero__inner">
        <div class="att-hero__content">
          <div class="att-hero__badge att-animate">{badge}</div>
          <h1 class="att-animate att-delay-1">{h1}</h1>
          <p class="att-hero__desc att-animate att-delay-2">{desc}</p>
          <div class="att-hero__actions att-animate att-delay-3">
            <a href="{cta1_url}" class="att-btn att-btn--primary">{cta1_label} &rarr;</a>
            <a href="{cta2_url}" class="att-btn att-btn--outline">{cta2_label}</a>
          </div>
        </div>
        <div class="att-hero__image-wrap att-animate att-delay-2">
          <img class="att-hero__img" src="{PLACEHOLDER_IMG}" alt="{_e(cfg.get('h1',''))}" loading="eager" />
        </div>
      </div>"""


def _render_recs_strip(recs: list[dict]) -> str:
    items = ""
    for r in recs[:4]:
        label = _raw(r.get("label", ""))
        desc = _raw(r.get("desc", ""))
        items += f"""        <div class="att-rec-callout">
          <div class="att-rec-callout__label">{label}</div>
          <p>{desc}</p>
        </div>\n"""
    return f"""      <div class="att-recs-strip att-animate att-delay-3">
{items}      </div>
    </div>
  </section>"""



def _render_featured_with_attraction(featured: list[dict], campaign_id: str, attraction: str) -> str:
    if not featured:
        return ""
    cards = ""
    for ticket in featured:
        raw_title = _raw(ticket.get("card_title") or ticket["title"])
        desc_text = _raw(ticket.get("description") or f"A top {attraction} experience.")
        tags = ticket.get("tags") or []
        tags_html = "".join(
            f'<span class="att-featured__tag">{_raw(t)}</span>'
            for t in tags[:3]
        )
        if not tags_html:
            tags_html = '<span class="att-featured__tag">Top Pick</span>'
        aff_url = ticket.get("affiliate_url", "")
        article_url = _e(ticket.get("article_url") or ticket.get("url", "#"))
        is_external = _is_affiliate(aff_url) and not aff_url.startswith("/")
        if is_external:
            stamped_url = _stamp_campaign(aff_url, campaign_id)
            cta_attrs = 'rel="nofollow sponsored" target="_blank"'
            cta_label = "Check Availability &rarr;"
        else:
            stamped_url = article_url
            cta_attrs = ""
            cta_label = "See Options &rarr;"
        cards += f"""
        <div class="att-featured">
          <img class="att-featured__img" src="{PLACEHOLDER_IMG}" alt="{_e(ticket['title'])}" />
          <div class="att-featured__body">
            <div class="att-featured__tags">{tags_html}</div>
            <h3><a href="{article_url}">{raw_title}</a></h3>
            <p class="att-featured__desc">{desc_text}</p>
            <div class="att-featured__actions">
              <a href="{_e(stamped_url)}" class="att-btn att-btn--primary att-btn--sm" {cta_attrs}>{cta_label}</a>
              <a href="{article_url}" class="att-featured__more">Read Full Guide</a>
            </div>
          </div>
        </div>"""

    return f"""  <section id="tt-top-picks" class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Top {_raw(attraction)} Experiences</h2>
        <p>Start with these standout options &mdash; the most popular and most complete experiences.</p>
      </div>
      <div class="att-featured-grid">
{cards}
      </div>
    </div>
  </section>"""


def _render_ticket_card(ticket: dict, campaign_id: str) -> str:
    title = ticket["title"]
    raw_title = _raw(ticket.get("card_title") or title)
    tags = ticket.get("tags") or []
    tags_html = "".join(
        f'<span class="att-ticket__tag">{_raw(t)}</span>'
        for t in tags[:3]
    )
    desc_text = _raw(ticket.get("description") or ticket.get("meta_desc") or f"Book your {title} online.")
    body_html = f'            <p class="att-ticket__desc">{desc_text}</p>'
    aff_url = ticket.get("affiliate_url", "")
    article_url = _e(ticket.get("article_url", "#"))
    if _is_affiliate(aff_url):
        cta_href = _e(_stamp_campaign(aff_url, campaign_id))
        cta_attrs = 'rel="nofollow sponsored" target="_blank"'
    else:
        cta_href = article_url
        cta_attrs = ""
    cta_label = "Check Availability &rarr;"
    return f"""        <div class="att-ticket">
          <img class="att-ticket__img" src="{PLACEHOLDER_IMG}" alt="{_e(title)}" />
          <div class="att-ticket__body">
            <div class="att-ticket__tags">{tags_html}</div>
            <h3><a href="{article_url}">{raw_title}</a></h3>
{body_html}
          </div>
          <div class="att-ticket__footer">
            <a href="{cta_href}" class="att-ticket__cta" {cta_attrs}>{cta_label}</a>
            <a href="{article_url}" class="att-ticket__more">Read More &rarr;</a>
          </div>
        </div>"""


def _render_ticket_groups(groups: list[dict], tickets_by_tid: dict, campaign_id: str, featured_tids: set | None = None) -> str:
    exclude = featured_tids or set()
    parts = []
    for i, group in enumerate(groups):
        h2 = _raw(group.get("h2", "Ticket Options"))
        desc = _raw(group.get("desc", ""))
        tids = group.get("tids", [])
        cards = "\n".join(
            _render_ticket_card(tickets_by_tid[tid], campaign_id)
            for tid in tids
            if tid in tickets_by_tid and tid not in exclude
        )
        section_id = ' id="tt-tickets"' if i == 0 else ""
        parts.append(f"""  <section{section_id} class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{h2}</h2>
        <p>{desc}</p>
      </div>
      <div class="att-tickets-grid">
{cards}
      </div>
    </div>
  </section>""")
    return "\n\n".join(parts)


def _render_comparison_table(compare_rows: list[dict], tickets: list[dict], tickets_by_tid: dict, campaign_id: str, attraction: str) -> str:
    rows_html = ""
    for row in compare_rows:
        tid = row.get("tid", "")
        ticket = tickets_by_tid.get(tid)
        if not ticket:
            continue
        title = _raw(ticket["title"])
        subtitle = _raw(row.get("subtitle", ""))
        best_for = _raw(row.get("best_for", ""))
        aff_url = ticket.get("affiliate_url", "")
        stamped_url = _stamp_campaign(aff_url, campaign_id) if _is_affiliate(aff_url) else aff_url
        subtitle_html = f"<span>{subtitle}</span>" if subtitle else ""
        rows_html += f"""            <tr class="att-compare-row">
              <td>{title}{subtitle_html}</td>
              <td>{best_for}</td>
              <td><a href="{_e(stamped_url)}" class="att-table-btn" rel="nofollow sponsored" target="_blank">Book Now</a></td>
            </tr>\n"""

    return f"""  <section class="att-section att-section--warm">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Which {_raw(attraction)} Ticket Should You Choose?</h2>
        <p>Use this quick comparison to match the ticket type to your travel style.</p>
      </div>
      <div class="att-compare-wrap">
        <table class="att-compare-table">
          <thead>
            <tr>
              <th>Ticket</th>
              <th>Best For</th>
              <th>Book</th>
            </tr>
          </thead>
          <tbody>
{rows_html}          </tbody>
        </table>
      </div>
    </div>
  </section>"""


def _render_decision_guide(decision: list[dict], attraction: str) -> str:
    cards = ""
    for card in decision[:4]:
        h3 = _raw(card.get("h3", ""))
        bullets = card.get("bullets", [])
        bullets_html = "".join(f"            <li>{_raw(b)}</li>\n" for b in bullets[:4])
        cards += f"""        <div class="att-guide-card">
          <h3>{h3}</h3>
          <ul>
{bullets_html}          </ul>
        </div>\n"""

    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>How to Pick the Right {_raw(attraction)} Experience</h2>
        <p>A few simple ways to decide based on your timing, travel style, and what kind of visit you want.</p>
      </div>
      <div class="att-guide-grid">
{cards}      </div>
    </div>
  </section>"""


def _render_guide_card(article: dict) -> str:
    title = article["title"]
    raw_title = _raw(article.get("card_title") or title)
    url_e = _e(article["url"])
    summary = _raw(article.get("description") or article.get("summary") or article.get("meta_desc") or f"A practical guide to {title}.")
    tags = article.get("tags") or []
    tags_html = "".join(
        f'<span class="att-ticket__tag">{_raw(t)}</span>'
        for t in tags[:3]
    )
    return f"""        <div class="att-ticket">
          <img class="att-ticket__img" src="{PLACEHOLDER_IMG}" alt="{_e(title)}" />
          <div class="att-ticket__body">
            <div class="att-ticket__tags">{tags_html}</div>
            <h3><a href="{url_e}">{raw_title}</a></h3>
            <p class="att-ticket__desc">{summary}</p>
          </div>
          <div class="att-ticket__footer">
            <a href="{url_e}" class="att-ticket__cta">Read More &rarr;</a>
          </div>
        </div>"""


def _render_guide_groups(groups: list[dict], info_by_slug: dict) -> str:
    parts = []
    for group in groups:
        h2 = _raw(group.get("h2", "Planning Guides"))
        desc = _raw(group.get("desc", ""))
        slugs = group.get("slugs", [])
        cards = "\n".join(
            _render_guide_card(info_by_slug[s])
            for s in slugs
            if s in info_by_slug
        )
        if not cards:
            continue
        parts.append(f"""  <section class="att-section att-section--warm">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{h2}</h2>
        <p>{desc}</p>
      </div>
      <div class="att-tickets-grid">
{cards}
      </div>
    </div>
  </section>""")
    return "\n\n".join(parts)


def _render_crosslinks(cfg: dict, attraction: str, crosslinks: dict) -> str:
    xlinks = cfg.get("xlinks", [])
    pyv_url = "/plan-your-visit/"
    what_url = "/what-to-see/"
    pyv_desc = crosslinks.get("pyv_desc", f"Opening hours, transport, tips, and everything to plan your {attraction} visit.")
    what_desc = crosslinks.get("what_to_see_desc", f"Discover the must-see highlights and masterpieces at {attraction}.")
    pyv_link_text = "Read the visitor guide &rarr;"
    what_link_text = "Explore highlights &rarr;"

    for xlink in xlinks:
        if len(xlink) < 3:
            continue
        t, u, d = xlink[0], xlink[1], xlink[2]
        if "/plan-your-visit" in u:
            pyv_desc = d
            if len(xlink) >= 4:
                pyv_link_text = _raw(xlink[3]) + " &rarr;"
        elif "/what-to-see" in u:
            what_desc = d
            if len(xlink) >= 4:
                what_link_text = _raw(xlink[3]) + " &rarr;"

    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Continue Exploring {_raw(attraction)}</h2>
        <p>Plan the rest of your visit with these guides.</p>
      </div>
      <div class="att-crosslinks">
        <div class="att-crosslink">
          <img class="att-crosslink__img" src="{PLACEHOLDER_IMG}" alt="Plan Your Visit" />
          <div class="att-crosslink__body">
            <h3><a href="{pyv_url}">Plan Your Visit</a></h3>
            <p class="att-crosslink__desc">{_raw(pyv_desc)}</p>
            <a href="{pyv_url}" class="att-crosslink__link">{pyv_link_text}</a>
          </div>
        </div>
        <div class="att-crosslink">
          <img class="att-crosslink__img" src="{PLACEHOLDER_IMG}" alt="What to See" />
          <div class="att-crosslink__body">
            <h3><a href="{what_url}">What to See</a></h3>
            <p class="att-crosslink__desc">{_raw(what_desc)}</p>
            <a href="{what_url}" class="att-crosslink__link">{what_link_text}</a>
          </div>
        </div>
      </div>
    </div>
  </section>"""


def _render_banner(banner: dict, banner_url: str) -> str:
    h2 = _raw(banner.get("h2", "Ready to book your tickets?"))
    desc = _raw(banner.get("desc", "Secure your preferred time slot online and skip the queues."))
    return f"""  <section class="att-cta-banner">
    <h2>{h2}</h2>
    <p>{desc}</p>
    <a href="{_e(banner_url)}" class="att-btn att-btn--white" rel="nofollow sponsored" target="_blank">Explore All Ticket Options</a>
  </section>"""


def _render_faqs(faqs: list, attraction: str = "") -> str:
    items_html = ""
    for faq in faqs:
        if isinstance(faq, dict):
            q, a = faq.get("question", ""), faq.get("answer", "")
        elif isinstance(faq, (list, tuple)) and len(faq) >= 2:
            q, a = faq[0], faq[1]
        else:
            continue
        items_html += f"""        <div class="att-faq-item" itemscope itemprop="mainEntity" itemtype="https://schema.org/Question">
          <button class="att-faq-item__q">
            <span itemprop="name">{_raw(q)}</span>
            <span class="att-faq-item__icon">+</span>
          </button>
          <div class="att-faq-item__a" itemscope itemprop="acceptedAnswer" itemtype="https://schema.org/Answer">
            <span itemprop="text">{_raw(a)}</span>
          </div>
        </div>\n"""

    return f"""  <section id="tt-faqs" class="att-section">
    <div class="att-container">
      <div class="att-section-header att-section-header--center">
        <h2>Frequently Asked Questions</h2>
        <p>Common questions about tours, combos, and choosing the right ticket.</p>
      </div>
      <div class="att-faq" itemscope itemtype="https://schema.org/FAQPage">
{items_html}      </div>
      <div class="att-section-link">
        <a href="/faqs/">View All FAQs about {_e(attraction)} &rarr;</a>
      </div>
    </div>
  </section>"""


def _build_faq_jsonld(faqs: list) -> str:
    import html as _html_mod
    entities = []
    for faq in faqs:
        if isinstance(faq, dict):
            q, a = faq.get("question", ""), faq.get("answer", "")
        elif isinstance(faq, (list, tuple)) and len(faq) >= 2:
            q, a = faq[0], faq[1]
        else:
            continue
        if q and a:
            q_plain = _html_mod.unescape(re.sub(r"<[^>]+>", "", q))
            a_plain = _html_mod.unescape(re.sub(r"<[^>]+>", "", a))
            entities.append({
                "@type": "Question",
                "name": q_plain,
                "acceptedAnswer": {"@type": "Answer", "text": a_plain},
            })
    if not entities:
        return ""
    schema = {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": entities}
    return f'<script type="application/ld+json">\n{json.dumps(schema, ensure_ascii=False, indent=2)}\n</script>'


def _faq_js() -> str:
    return """<script>
(function() {
  'use strict';
  document.querySelectorAll('.att-tickets-page .att-faq-item__q').forEach(function(btn) {
    btn.addEventListener('click', function() {
      var item = this.parentElement;
      var wasOpen = item.classList.contains('open');
      document.querySelectorAll('.att-tickets-page .att-faq-item').forEach(function(el) { el.classList.remove('open'); });
      if (!wasOpen) item.classList.add('open');
    });
  });
  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function(entries) {
      entries.forEach(function(e) { if (e.isIntersecting) { e.target.style.animationPlayState = 'running'; observer.unobserve(e.target); } });
    }, { threshold: 0.1 });
    document.querySelectorAll('.att-tickets-page .att-animate').forEach(function(el) {
      el.style.animationPlayState = 'paused'; observer.observe(el);
    });
  }
})();
</script>"""


# ─── Attraction name extraction ───────────────────────────────────────────────

def _extract_attraction_name(h1: str, site_slug: str) -> str:
    for prefix in ("Tickets & Tours — ", "Tickets & Tours for ", "Tickets and Tours — ", "Tickets for "):
        if h1.startswith(prefix):
            return h1[len(prefix):]
    # Strip " Tickets & Tours" suffix
    for suffix in (" Tickets &amp; Tours", " Tickets & Tours", " Tickets and Tours"):
        if h1.endswith(suffix):
            return h1[: -len(suffix)]
    return site_slug.replace("-", " ").title()


# ─── Main render ──────────────────────────────────────────────────────────────

def render(site_slug: str, force: bool = False) -> Path:
    from . import article_source, content_generator, tickets_validator, tickets_verifier

    output_dir = REPO_ROOT / "output" / site_slug / "l1-pages"
    output_path = output_dir / "tickets-tours.html"

    if output_path.exists() and not force:
        print(f"[{site_slug}] tickets-tours.html already exists. Use --force to regenerate.")
        return output_path

    config_path = REPO_ROOT / "input" / site_slug / "l1-config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"l1-config.json not found: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    tt_cfg = config.get("pages", {}).get("Tickets & Tours", {})
    env = _load_env(site_slug)

    attraction = _extract_attraction_name(tt_cfg.get("h1", ""), site_slug)
    print(f"[{site_slug}] Attraction: {attraction}")

    # Load articles
    bundle = article_source.load_tickets_tours_articles(site_slug, str(REPO_ROOT), force=force)
    tickets = bundle["tickets"]           # editorial ticket-type articles
    informational = bundle["informational"]
    featured = bundle["featured"]
    tickets_by_tid = bundle["tickets_by_tid"]   # editorial articles keyed by E-TID
    affiliate_tickets = bundle.get("affiliate_tickets", [])          # GYG products (table)
    affiliate_tickets_by_tid = bundle.get("affiliate_tickets_by_tid", {})
    print(f"[{site_slug}] Loaded {len(tickets)} ticket articles, {len(informational)} informational, {len(featured)} featured")

    campaign_id = f"{site_slug}-tickets"

    # ── Content generation with caching ──────────────────────────────────────
    h2_cache = config.get("_h2_rewrites", {})

    # Rec callouts — use editorial articles (have real article URLs)
    all_editorial = featured + tickets + informational
    recs = (not force and config.get("_recs_tt")) or None
    if not recs:
        print(f"[{site_slug}] Generating rec callouts...")
        recs = content_generator.generate_rec_callouts(attraction, all_editorial, config, force)
    else:
        print(f"[{site_slug}] Cached rec callouts")

    # ticket_list is already pre-split (featured excluded by article_source)
    non_featured_tickets = tickets

    # Ticket sections (non-featured only, 2–4 sections)
    ticket_groups = (not force and config.get("_ticket_sections_tt")) or None
    if not ticket_groups:
        print(f"[{site_slug}] Grouping {len(non_featured_tickets)} non-featured ticket articles...")
        ticket_groups = content_generator.generate_ticket_sections(attraction, featured, non_featured_tickets, config, force)
    else:
        print(f"[{site_slug}] Cached ticket sections ({len(ticket_groups)} sections)")

    # Info sections (3–5 sections)
    guide_groups = (not force and config.get("_info_sections_tt")) or None
    if not guide_groups and informational:
        print(f"[{site_slug}] Grouping {len(informational)} informational articles...")
        guide_groups = content_generator.generate_info_sections(attraction, informational, config, force)
    elif not informational:
        guide_groups = []
    else:
        print(f"[{site_slug}] Cached info sections ({len(guide_groups)} sections)")

    # Comparison table rows — use affiliate_tickets (53 GYG products)
    compare_rows = (not force and config.get("_compare_tt")) or None
    if not compare_rows:
        print(f"[{site_slug}] Generating comparison table...")
        compare_rows = content_generator.generate_comparison_rows(attraction, affiliate_tickets, config, force)
    else:
        print(f"[{site_slug}] Cached comparison rows ({len(compare_rows)} rows)")

    # Decision guide — use affiliate_tickets (product variety context)
    decision = (not force and config.get("_decision_tt")) or None
    if not decision:
        print(f"[{site_slug}] Generating decision guide...")
        decision = content_generator.generate_decision_guide(attraction, affiliate_tickets, config, force)
    else:
        print(f"[{site_slug}] Cached decision guide ({len(decision)} cards)")

    # FAQs — prefer cached in tt_cfg, else cached in root, else generate
    faqs = (not force and tt_cfg.get("faqs")) or (not force and config.get("_faqs_tt")) or None
    if not faqs:
        print(f"[{site_slug}] Generating FAQs...")
        faqs = content_generator.generate_faqs_tickets(attraction, affiliate_tickets, config, force)
    else:
        print(f"[{site_slug}] Cached FAQs ({len(faqs)} items)")

    # Banner
    if tt_cfg.get("cta_h") and tt_cfg.get("cta_d"):
        banner = {"h2": tt_cfg["cta_h"], "desc": tt_cfg["cta_d"]}
    else:
        banner = (not force and config.get("_banner_tt")) or None
        if not banner:
            banner = content_generator.generate_banner_tickets(attraction, config, force)

    # Crosslinks
    crosslinks = (not force and config.get("_crosslinks_tt")) or None
    if not crosslinks:
        crosslinks = content_generator.generate_crosslinks_tt(attraction, config, force)

    # Banner URL with campaign stamp
    raw_banner_url = (
        env.get("RED_BANNER_TICKET")
        or env.get("red_banner_ticket")
        or env.get("RED_BUTTON_URL")
        or config.get("gyg_url")
        or (tt_cfg.get("cta1", ["", ""])[1] if isinstance(tt_cfg.get("cta1"), list) else "")
    )
    if raw_banner_url and not raw_banner_url.startswith("/"):
        banner_url = _stamp_campaign(raw_banner_url, campaign_id)
    else:
        banner_url = raw_banner_url or "#tt-top-picks"

    config["_h2_rewrites"] = h2_cache

    # Save updated config
    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")

    # ── SEO metadata ──────────────────────────────────────────────────────────
    seo_title = tt_cfg.get("seo_t", f"{attraction} Tickets &amp; Tours — Compare &amp; Book Online")
    seo_desc = tt_cfg.get("seo_d", "")
    seo_url = f"https://{config.get('domain', '')}/tickets/"
    css = _load_css()

    # ── Assemble ──────────────────────────────────────────────────────────────
    print(f"[{site_slug}] Assembling HTML...")
    info_by_slug = {a["url_slug"]: a for a in informational}
    html_out = _assemble(
        seo_title=seo_title, seo_desc=seo_desc, seo_url=seo_url, css=css,
        tt_cfg=tt_cfg, attraction=attraction,
        recs=recs, featured=featured, campaign_id=campaign_id,
        ticket_groups=ticket_groups, tickets_by_tid=tickets_by_tid,
        compare_rows=compare_rows, tickets=affiliate_tickets,
        affiliate_tickets_by_tid=affiliate_tickets_by_tid,
        decision=decision,
        guide_groups=guide_groups, info_by_slug=info_by_slug,
        xlinks_cfg=tt_cfg, crosslinks=crosslinks,
        banner=banner, banner_url=banner_url,
        faqs=faqs,
    )

    # ── Mechanical validation ─────────────────────────────────────────────────
    ok, reasons, _info = tickets_validator.validate(html_out, bundle, site_slug, config, banner_url)
    if not ok:
        print(f"[{site_slug}] VALIDATION FAILED ({len(reasons)} issues):")
        for r in reasons:
            print(f"  ✗ {r}")
        sys.exit(1)
    print(f"[{site_slug}] Validation passed.")

    # ── Claude semantic verifier ──────────────────────────────────────────────
    print(f"[{site_slug}] Running semantic verifier...")
    v_ok, issues = tickets_verifier.verify(html_out, bundle, attraction, config)
    for i in issues:
        sev = i.get("severity", "?")
        area = i.get("area", "")
        where = i.get("where", "")
        desc = i.get("description", "")
        print(f"  [{sev}] {area} — {where}: {desc}")
    if not v_ok:
        print(f"[{site_slug}] VERIFIER FAILED — blockers found.")
        sys.exit(1)
    print(f"[{site_slug}] Verifier passed.")

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html_out, encoding="utf-8")
    print(f"[{site_slug}] Wrote {output_path} ({len(html_out.encode())} bytes)")
    return output_path


def _assemble(
    seo_title, seo_desc, seo_url, css, tt_cfg, attraction,
    recs, featured, campaign_id,
    ticket_groups, tickets_by_tid,
    compare_rows, tickets, affiliate_tickets_by_tid,
    decision,
    guide_groups, info_by_slug,
    xlinks_cfg, crosslinks,
    banner, banner_url, faqs,
) -> str:
    extra_css = """
.att-tickets-page .att-ticket h3 a,
.att-tickets-page .att-featured h3 a {
  color: inherit;
  text-decoration: none;
}
.att-tickets-page .att-ticket h3 a:hover,
.att-tickets-page .att-featured h3 a:hover {
  color: var(--accent, #c0392b);
}
.att-tickets-page .att-featured__body {
  display: flex;
  flex-direction: column;
}
.att-tickets-page .att-featured__actions {
  margin-top: auto;
  padding-top: 1rem;
}
.att-tickets-page .att-ticket__desc {
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.att-tickets-page .att-section--warm,
.att-rec-strip,
.att-tickets-page .att-faq-item.open {
  background: #fff;
}
"""
    parts = [
        f"<!-- SEO\ntitle: {seo_title}\ndescription: {seo_desc}\ncanonical: {seo_url}\n-->",
        f"<style>{css}{extra_css}</style>",
        "",
        '<div class="att-tickets-page">',
        "",
        # 1. Hero
        _render_hero(tt_cfg, campaign_id=campaign_id),
        # 2. Rec strip (inside hero section)
        _render_recs_strip(recs),
        "",
        # 3. Featured tickets
        _render_featured_with_attraction(featured, campaign_id, attraction),
        "",
        # 4. Ticket article groups (exclude featured to avoid repeats)
        _render_ticket_groups(ticket_groups, tickets_by_tid, campaign_id),
        "",
        # 5. Comparison table (uses affiliate GYG tickets, not editorial articles)
        _render_comparison_table(compare_rows, tickets, affiliate_tickets_by_tid, campaign_id, attraction),
        "",
        # 6. Decision guide
        _render_decision_guide(decision, attraction),
        "",
    ]
    # 7. Informational guide groups
    if guide_groups:
        parts.append(_render_guide_groups(guide_groups, info_by_slug))
        parts.append("")
    # 8. Crosslinks
    parts.append(_render_crosslinks(xlinks_cfg, attraction, crosslinks))
    parts.append("")
    # 9. CTA banner
    parts.append(_render_banner(banner, banner_url))
    parts.append("")
    # 10. FAQs
    if faqs:
        parts.append(_render_faqs(faqs, attraction))
        parts.append("")
    parts.append("</div>")
    parts.append("")
    # FAQ JSON-LD
    jsonld = _build_faq_jsonld(faqs)
    if jsonld:
        parts.append(jsonld)
        parts.append("")
    # JS
    parts.append(_faq_js())
    return "\n".join(parts)


# ─── CLI ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Generate L1 tickets-tours page")
    p.add_argument("site_slug", help="Site slug (e.g. museo-del-prado)")
    p.add_argument("--force", action="store_true")
    args = p.parse_args()
    render(args.site_slug, force=args.force)
