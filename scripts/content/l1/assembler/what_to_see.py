#!/usr/bin/env python3
"""
what_to_see.py — L1 What-to-See HTML assembler.

Usage:
  python3 -m scripts.content.l1_assembler.what_to_see <site-slug> [--force]

Generates output/<site>/l1-pages/what-to-see.html following the template
structure exactly. Claude writes content strings; Python controls all structure.

Key design rules:
  - _e()   → html.escape() for URLs in href attributes (& → &amp;)
  - _raw() → str() for display text from config/Claude (preserves &ndash; etc.)
  - All internal links are relative (start with /)
  - Featured articles (2 top highlights) excluded from article group sections
  - FAQ section uses button/div accordion (not <details>/<summary>)
  - Banner ticket URL from env RED_BANNER_TICKET, else gyg_url
"""

import argparse
import html
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

PLACEHOLDER_IMG = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-what-to-see-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent


# ─── Text helpers ─────────────────────────────────────────────────────────────

def _e(text: str) -> str:
    return html.escape(str(text), quote=True)


def _raw(text: str) -> str:
    return str(text)


# ─── Env loading ─────────────────────────────────────────────────────────────

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


# ─── Affiliate URL ────────────────────────────────────────────────────────────

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


# ─── CSS + JS extraction ──────────────────────────────────────────────────────

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


def _load_accordion_js() -> str:
    content = TEMPLATE_PATH.read_text(encoding="utf-8")
    m = re.search(r"<script>(.*?)</script>", content, re.DOTALL)
    return f"<script>{m.group(1)}</script>" if m else ""


# ─── Section renderers ────────────────────────────────────────────────────────

def _render_hero(h1: str, desc: str) -> str:
    return f"""  <section class="att-hero">
    <div class="att-container">
      <div class="att-hero__inner">
        <div class="att-hero__content">
          <div class="att-hero__badge att-animate">What to See</div>
          <h1 class="att-animate att-delay-1">{_raw(h1)}</h1>
          <p class="att-hero__desc att-animate att-delay-2">{_raw(desc)}</p>
          <div class="att-hero__actions att-animate att-delay-3">
            <a href="#wts-top" class="att-btn att-btn--primary">Top Highlights &rarr;</a>
            <a href="#wts-faqs" class="att-btn att-btn--outline">Read FAQs</a>
          </div>
        </div>
        <div class="att-hero__image-wrap att-animate att-delay-2">
          <img class="att-hero__img" src="{PLACEHOLDER_IMG}" alt="{_e(h1)}" loading="eager" />
        </div>
      </div>
    </div>
  </section>"""


def _render_featured_card(article: dict) -> str:
    title = _raw(article.get("card_title") or article["title"])
    url_e = _e(article["url"])
    desc = _raw(article.get("featured_desc") or article.get("description") or article.get("meta_desc") or "")
    tags_html = "".join(
        f'<span class="att-featured__tag">{_raw(t)}</span>'
        for t in article.get("tags", [])[:3]
    )
    return f"""        <div class="att-featured">
          <img class="att-featured__img" src="{PLACEHOLDER_IMG}" alt="{_e(article['title'])}" />
          <div class="att-featured__body">
            <div class="att-featured__tags">{tags_html}</div>
            <h3><a href="{url_e}">{title}</a></h3>
            <p class="att-featured__desc">{desc}</p>
            <a href="{url_e}" class="att-featured__link">Explore &rarr;</a>
          </div>
        </div>"""


def _render_top_highlights(attraction: str, featured: list[dict]) -> str:
    cards = "\n".join(_render_featured_card(a) for a in featured)
    return f"""  <section id="wts-top" class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Top Highlights at {_raw(attraction)}</h2>
        <p>The headline sights and experiences most visitors want to see first.</p>
      </div>
      <div class="att-featured-grid">
{cards}
      </div>
    </div>
  </section>"""


def _render_article_card(article: dict) -> str:
    title = _raw(article.get("card_title") or article["title"])
    url_e = _e(article["url"])
    brief = _raw(article.get("description") or article.get("meta_desc") or "")
    tags_html = "".join(
        f'<span class="att-article-card__tag">{_raw(t)}</span>'
        for t in article.get("tags", [])[:4]
    )
    return f"""        <div class="att-article-card">
          <img class="att-article-card__img" src="{PLACEHOLDER_IMG}" alt="{_e(article['title'])}" />
          <div class="att-article-card__body">
            <div class="att-article-card__tags">{tags_html}</div>
            <h3><a href="{url_e}">{title}</a></h3>
            <p class="att-article-card__desc">{brief}</p>
            <a href="{url_e}" class="att-article-card__link">Read guide &rarr;</a>
          </div>
        </div>"""


def _normalise_h2(h2: str) -> str:
    """Replace 'Attraction: Section' colon-join with an em dash."""
    return re.sub(r"^([A-Z][^:]{5,}):\s+", r"\1 — ", h2)


def _render_article_section(group: dict) -> str:
    cards = "\n".join(_render_article_card(a) for a in group["articles"])
    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{_raw(_normalise_h2(group["h2"]))}</h2>
        <p>{_raw(group.get("desc", ""))}</p>
      </div>
      <div class="att-articles-grid">
{cards}
      </div>
    </div>
  </section>"""


def _render_how_to_choose(attraction: str, cards: list[dict]) -> str:
    parts = ""
    for c in cards:
        items_html = ""
        for item in c.get("items", []):
            items_html += f"            <li>{_raw(item)}</li>\n"
        rec_html = ""
        if c.get("rec_url") and c.get("rec_link_label"):
            rec_html = f"""          <div class="att-guide-card__rec">
            <strong>{_raw(c.get("rec_text", "Best pick:"))}</strong>
            <a href="{_e(c['rec_url'])}">{_raw(c['rec_link_label'])}</a>
          </div>\n"""
        parts += f"""        <div class="att-guide-card">
          <h3>{_raw(c.get("h3", ""))}</h3>
          <p>{_raw(c.get("p", ""))}</p>
          <ul>
{items_html}          </ul>
{rec_html}        </div>\n"""
    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>How to Choose What to See at {_raw(attraction)}</h2>
        <p>A quick guide based on your interests and visit style.</p>
      </div>
      <div class="att-guide-grid">
{parts}      </div>
    </div>
  </section>"""


def _render_continue_exploring(attraction: str, xlinks: list, crosslinks: dict) -> str:
    tickets_url = "/tickets/"
    pyv_url = "/plan-your-visit/"
    tickets_link_text = "Explore ticket options &rarr;"
    pyv_link_text = "Read the visitor guide &rarr;"
    tickets_desc = crosslinks.get("tickets_desc", f"Compare all ticket options for {attraction}.")
    pyv_desc = crosslinks.get("pyv_desc", f"Opening hours, getting there, and practical tips for your {attraction} visit.")

    for xlink in xlinks:
        if len(xlink) < 3:
            continue
        t, u, d = xlink[0], xlink[1], xlink[2]
        if "/tickets" in u:
            tickets_desc = d
            if len(xlink) >= 4:
                tickets_link_text = _raw(xlink[3]) + " &rarr;"
        elif "/plan-your-visit" in u:
            pyv_desc = d
            if len(xlink) >= 4:
                pyv_link_text = _raw(xlink[3]) + " &rarr;"

    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Continue Exploring {_raw(attraction)}</h2>
        <p>Book your tickets and plan the practical details of your visit.</p>
      </div>
      <div class="att-crosslinks">
        <div class="att-crosslink">
          <img class="att-crosslink__img" src="{PLACEHOLDER_IMG}" alt="Tickets &amp; Tours" />
          <div class="att-crosslink__body">
            <h3><a href="{tickets_url}">Tickets &amp; Tours</a></h3>
            <p class="att-crosslink__desc">{_raw(tickets_desc)}</p>
            <a href="{tickets_url}" class="att-crosslink__link">{tickets_link_text}</a>
          </div>
        </div>
        <div class="att-crosslink">
          <img class="att-crosslink__img" src="{PLACEHOLDER_IMG}" alt="Plan Your Visit" />
          <div class="att-crosslink__body">
            <h3><a href="{pyv_url}">Plan Your Visit</a></h3>
            <p class="att-crosslink__desc">{_raw(pyv_desc)}</p>
            <a href="{pyv_url}" class="att-crosslink__link">{pyv_link_text}</a>
          </div>
        </div>
      </div>
    </div>
  </section>"""


def _render_cta_banner(banner: dict, ticket_url: str) -> str:
    return f"""  <section class="att-cta-banner">
    <h2>{_raw(banner.get("h2", "Ready to book your tickets?"))}</h2>
    <p>{_raw(banner.get("desc", "Secure your preferred time slot online."))}</p>
    <a href="{_e(ticket_url)}" class="att-btn att-btn--white">View All Tickets &amp; Tours</a>
  </section>"""


def _render_faqs_wts(faqs: list, attraction: str = "", faq_url: str = "/faqs/") -> str:
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

    return f"""  <section id="wts-faqs" class="att-section">
    <div class="att-container">
      <div class="att-section-header att-section-header--center">
        <h2>Frequently Asked Questions</h2>
        <p>Common questions about what to see and prioritise.</p>
      </div>
      <div class="att-faq" itemscope itemtype="https://schema.org/FAQPage">
{items_html}      </div>
      <div class="att-section-link">
        <a href="{_e(faq_url)}">View All FAQs about {_e(attraction)} &rarr;</a>
      </div>
    </div>
  </section>"""


def _build_faq_jsonld(faqs: list) -> str:
    entities = []
    for faq in faqs:
        if isinstance(faq, dict):
            q, a = faq.get("question", ""), faq.get("answer", "")
        elif isinstance(faq, (list, tuple)) and len(faq) >= 2:
            q, a = faq[0], faq[1]
        else:
            continue
        if q and a:
            q_plain = re.sub(r"&[a-z]+;|&#\d+;", lambda m: _decode_entity(m.group(0)), q)
            a_plain = re.sub(r"&[a-z]+;|&#\d+;", lambda m: _decode_entity(m.group(0)), a)
            entities.append({
                "@type": "Question",
                "name": q_plain,
                "acceptedAnswer": {"@type": "Answer", "text": a_plain},
            })
    if not entities:
        return ""
    schema = {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": entities}
    return f'<script type="application/ld+json">\n{json.dumps(schema, ensure_ascii=False, indent=2)}\n</script>'


def _decode_entity(entity: str) -> str:
    import html as _html_mod
    try:
        return _html_mod.unescape(entity)
    except Exception:
        return entity


# ─── Main render ─────────────────────────────────────────────────────────────

def _extract_attraction_name(h1: str, site_slug: str) -> str:
    for prefix in ("What to See at ", "What To See at ", "What to see at "):
        if h1.startswith(prefix):
            return h1[len(prefix):]
    return site_slug.replace("-", " ").title()


def render(site_slug: str, force: bool = False) -> Path:
    from . import article_source, content_generator, validator, verifier

    output_dir = REPO_ROOT / "output" / site_slug / "l1-pages"
    output_path = output_dir / "what-to-see.html"

    if output_path.exists() and not force:
        print(f"[{site_slug}] what-to-see.html already exists. Use --force to regenerate.")
        return output_path

    config_path = REPO_ROOT / "input" / site_slug / "l1-config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"l1-config.json not found: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    pages = config.get("pages", {})
    wts_cfg = pages.get("What to See") or pages.get("What To See") or {}
    env = _load_env(site_slug)

    attraction = _extract_attraction_name(wts_cfg.get("h1", ""), site_slug)
    print(f"[{site_slug}] Attraction: {attraction}")

    articles = article_source.load_what_to_see_articles(site_slug, str(REPO_ROOT))
    print(f"[{site_slug}] Loaded {len(articles)} what-to-see articles")
    if not articles:
        raise ValueError(f"No what-to-see articles found for {site_slug}")

    # Top highlights — 2 featured articles
    print(f"[{site_slug}] Picking top highlights...")
    if force:
        config.pop("_top_highlights_wts", None)
    featured_slugs = content_generator.generate_top_highlights(attraction, articles, config, force)
    config["_top_highlights_wts"] = featured_slugs
    featured_set = set(featured_slugs)
    featured = [dict(a) for a in articles if a["url_slug"] in featured_set]
    non_featured = [a for a in articles if a["url_slug"] not in featured_set]
    print(f"[{site_slug}] {len(featured)} featured, {len(non_featured)} in groups")

    # Generate 3-4 sentence descriptions for featured cards
    print(f"[{site_slug}] Generating featured card descriptions...")
    for a in featured:
        a["_site_slug"] = site_slug
        a["featured_desc"] = content_generator.generate_featured_desc_wts(
            attraction, a, str(REPO_ROOT), config, force
        )

    # Article groups (non-featured only)
    print(f"[{site_slug}] Grouping articles...")
    h2_cache = config.get("_h2_rewrites_wts", {})
    groups = content_generator.generate_article_groups(
        attraction, non_featured, h2_cache=h2_cache, force=force, category="what-to-see"
    )
    config["_h2_rewrites_wts"] = h2_cache
    print(f"[{site_slug}] {len(groups)} article sections")

    # How to Choose guide cards
    print(f"[{site_slug}] Generating How to Choose cards...")
    if force:
        config.pop("_how_to_choose_wts", None)
    guide_cards = content_generator.generate_how_to_choose(attraction, articles, config, force)
    config["_how_to_choose_wts"] = guide_cards

    # FAQs — prefer pre-configured, then cache, then Claude
    faqs = (not force and wts_cfg.get("faqs")) or config.get("_faqs_wts")
    if not faqs:
        print(f"[{site_slug}] Generating FAQs...")
        faqs = content_generator.generate_faqs_wts(attraction, articles, config, force)
        config["_faqs_wts"] = faqs
    else:
        print(f"[{site_slug}] Using FAQs ({len(faqs)} items)")

    # Banner
    if wts_cfg.get("cta_h") and wts_cfg.get("cta_d"):
        banner = {"h2": wts_cfg["cta_h"], "desc": wts_cfg["cta_d"]}
    else:
        banner = config.get("_banner_wts") or content_generator.generate_banner_wts(attraction, config, force)
        config["_banner_wts"] = banner

    # Crosslinks
    xlinks = wts_cfg.get("xlinks", [])
    crosslinks = config.get("_crosslinks_wts") or content_generator.generate_crosslinks_wts(attraction, config, force)
    config["_crosslinks_wts"] = crosslinks

    # Banner ticket URL
    raw_ticket_url = (
        env.get("RED_BANNER_TICKET")
        or env.get("red_banner_ticket")
        or env.get("RED_BUTTON_URL")
        or config.get("gyg_url")
        or (wts_cfg.get("cta1", ["", ""])[1] if isinstance(wts_cfg.get("cta1"), list) else "")
    )
    campaign_id = f"{site_slug}-what-to-see"
    if raw_ticket_url and not raw_ticket_url.startswith("/"):
        ticket_url = _stamp_campaign(raw_ticket_url, campaign_id)
    else:
        ticket_url = raw_ticket_url or "#"
    print(f"[{site_slug}] Banner ticket URL: {ticket_url[:80]}")

    # Save updated config
    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")

    # SEO metadata
    seo_title = wts_cfg.get("seo_t", f"What to See at {attraction}")
    seo_desc = wts_cfg.get("seo_d", "")
    seo_url = f"https://{config.get('domain', '')}/what-to-see/"
    css = _load_css()
    accordion_js = _load_accordion_js()
    faq_url = article_source.get_faq_url(site_slug, str(REPO_ROOT))

    print(f"[{site_slug}] Assembling HTML...")
    html_out = _assemble(
        seo_title=seo_title, seo_desc=seo_desc, seo_url=seo_url, css=css,
        h1=wts_cfg.get("h1", f"What to See at {attraction}"),
        desc=wts_cfg.get("desc", ""),
        featured=featured, groups=groups, guide_cards=guide_cards,
        xlinks=xlinks, crosslinks=crosslinks, attraction=attraction,
        banner=banner, ticket_url=ticket_url, faqs=faqs,
        accordion_js=accordion_js, faq_url=faq_url,
    )

    # Mechanical validation
    ok, reasons, _info = validator.validate_wts(html_out, articles, site_slug, config, ticket_url)
    if not ok:
        print(f"[{site_slug}] VALIDATION FAILED ({len(reasons)} issues):")
        for r in reasons:
            print(f"  ✗ {r}")
        sys.exit(1)
    print(f"[{site_slug}] Validation passed.")

    # Claude semantic verification
    print(f"[{site_slug}] Running semantic verifier...")
    v_ok, issues = verifier.verify_wts(html_out, articles, attraction, config)
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
    seo_title, seo_desc, seo_url, css, h1, desc,
    featured, groups, guide_cards,
    xlinks, crosslinks, attraction, banner, ticket_url, faqs,
    accordion_js, faq_url="/faqs/",
) -> str:
    parts = [
        f"<!-- SEO\ntitle: {seo_title}\ndescription: {seo_desc}\ncanonical: {seo_url}\n-->",
        f"<style>{css}\n\n/* Inline article links — match template accent color */\n.att-see-page .att-section a,\n.att-see-page .att-guide-card a {{\n    color: var(--accent);\n    text-decoration: none;\n}}\n.att-see-page .att-section a:hover,\n.att-see-page .att-guide-card a:hover {{\n    text-decoration: underline;\n}}</style>",
        "",
        '<div class="att-see-page">',
        _render_hero(h1, desc),
        "",
        _render_top_highlights(attraction, featured),
        "",
    ]
    for group in groups:
        parts.append(_render_article_section(group))
        parts.append("")
    if guide_cards:
        parts.append(_render_how_to_choose(attraction, guide_cards))
        parts.append("")
    parts.append(_render_continue_exploring(attraction, xlinks, crosslinks))
    parts.append("")
    parts.append(_render_cta_banner(banner, ticket_url))
    parts.append("")
    if faqs:
        parts.append(_render_faqs_wts(faqs, attraction, faq_url))
        parts.append("")
    parts.append("</div>")
    parts.append("")
    parts.append(accordion_js)
    jsonld = _build_faq_jsonld(faqs)
    if jsonld:
        parts.append(jsonld)
    return "\n".join(parts)


# ─── CLI ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Generate L1 what-to-see page")
    p.add_argument("site_slug", help="Site slug (e.g. amsterdam-canal-cruise)")
    p.add_argument("--force", action="store_true")
    args = p.parse_args()
    render(args.site_slug, force=args.force)
