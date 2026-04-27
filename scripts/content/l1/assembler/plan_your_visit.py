#!/usr/bin/env python3
"""
plan_your_visit.py — L1 Plan-Your-Visit HTML assembler.

Usage:
  python3 -m scripts.content.l1_assembler.plan_your_visit <site-slug> [--force]

Generates output/<site>/l1-pages/plan-your-visit.html following the template
structure exactly. Claude writes content strings; Python controls all structure.

Key design rules:
  - _e()   → html.escape() for URLs in href attributes (& → &amp;)
  - _raw() → str() for display text from config/Claude (preserves &ndash; etc.)
  - All internal links are relative (start with /)
  - Banner ticket URL from env RED_BANNER_TICKET (per-site .env), else gyg_url
  - L2 articles linked from quicktips, practical cards, and know-tips sections
"""

import argparse
import html
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

PLACEHOLDER_IMG = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-plan-your-visit-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent


# ─── Text helpers ─────────────────────────────────────────────────────────────

def _e(text: str) -> str:
    """Escape for use in HTML attribute values (href, alt, etc.)."""
    return html.escape(str(text), quote=True)


def _raw(text: str) -> str:
    """Pass trusted config/Claude content through as-is (preserves HTML entities)."""
    return str(text)


# ─── Env loading ─────────────────────────────────────────────────────────────

def _load_env(site_slug: str) -> dict:
    """Load root .env then per-site .env, return merged dict of key=value pairs."""
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
    """Stamp correct affiliate partner ID + campaign ID onto GYG/Tiqets/Viator URL."""
    if base_url.startswith("/"):
        return base_url  # relative — no affiliate params
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


# ─── CSS extraction ───────────────────────────────────────────────────────────

def _load_css() -> str:
    content = TEMPLATE_PATH.read_text(encoding="utf-8")
    m = re.search(r"<style>(.*?)</style>", content, re.DOTALL)
    return m.group(1) if m else ""


# ─── Section renderers ────────────────────────────────────────────────────────

def _render_hero(h1: str, desc: str) -> str:
    return f"""  <section class="att-hero">
    <div class="att-container">
      <div class="att-hero__inner">
        <div class="att-hero__content">
          <div class="att-hero__badge att-animate">Plan Your Visit</div>
          <h1 class="att-animate att-delay-1">{_raw(h1)}</h1>
          <p class="att-hero__desc att-animate att-delay-2">{_raw(desc)}</p>
          <div class="att-hero__actions att-animate att-delay-3">
            <a href="#pyv-essentials" class="att-btn att-btn--primary">Essential Guides &rarr;</a>
            <a href="#pyv-faqs" class="att-btn att-btn--outline">Read FAQs</a>
          </div>
        </div>
        <div class="att-hero__image-wrap att-animate att-delay-2">
          <img class="att-hero__img" src="{PLACEHOLDER_IMG}" alt="{_e(h1)}" loading="eager" />
        </div>
      </div>"""


def _render_quicktips(tips: list[dict]) -> str:
    items = ""
    for t in tips[:4]:
        label_text = t.get("label", "")
        desc_text = t.get("desc", "")
        label_html = _raw(label_text)
        items += f"""        <div class="att-quicktip">
          <div class="att-quicktip__label">{label_html}</div>
          <p>{_raw(desc_text)}</p>
        </div>\n"""
    return f"""      <div class="att-quicktips att-animate att-delay-3">
{items}      </div>"""


def _render_article_card(article: dict) -> str:
    title = _raw(article["title"])
    url_e = _e(article["url"])
    brief = _raw(article.get("brief") or article.get("meta_desc") or "")
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


def _render_article_section(group: dict, first: bool = False) -> str:
    section_id = ' id="pyv-essentials"' if first else ""
    cards = "\n".join(_render_article_card(a) for a in group["articles"])
    return f"""  <section{section_id} class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{_raw(group["h2"])}</h2>
        <p>{_raw(group.get("desc", ""))}</p>
      </div>
      <div class="att-articles-grid">
{cards}
      </div>
    </div>
  </section>"""


def _render_practical(cards: list[dict]) -> str:
    parts = ""
    for c in cards[:4]:
        items_html = ""
        for item in c.get("items", []):
            items_html += f"            <li>{_raw(item)}</li>\n"
        parts += f"""        <div class="att-practical-card">
          <h3>{_raw(c.get("h3", ""))}</h3>
          <p>{_raw(c.get("p", ""))}</p>
          <ul>
{items_html}          </ul>
        </div>\n"""
    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Practical Information</h2>
        <p>Quick-read guidance for scheduling, pacing, and general comfort during your visit.</p>
      </div>
      <div class="att-practical-grid">
{parts}      </div>
    </div>
  </section>"""


def _render_know_tips(tips: list) -> str:
    items_html = ""
    for t in tips[:6]:
        if isinstance(t, dict):
            emoji = t.get("emoji", "")
            label = t.get("label", "")
            desc = t.get("desc", "")
        elif isinstance(t, (list, tuple)) and len(t) >= 3:
            emoji, label, desc = t[0], t[1], t[2]
        else:
            continue
        items_html += f"""        <div class="att-tip">
          <span class="att-tip__icon">{_raw(emoji)}</span>
          <span><strong>{_raw(label)}</strong> {_raw(desc)}</span>
        </div>\n"""
    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Things to Know Before You Book</h2>
        <p>Key reminders for a hassle-free visit.</p>
      </div>
      <div class="att-tips-grid">
{items_html}      </div>
    </div>
  </section>"""


def _render_continue_exploring(attraction: str, xlinks: list, crosslinks: dict) -> str:
    tickets_url = "/tickets/"
    what_url = "/what-to-see/"
    tickets_link_text = "Explore ticket options &rarr;"
    what_link_text = "Explore highlights &rarr;"
    tickets_desc = crosslinks.get("tickets_desc", f"Compare all ticket options for {attraction}.")
    what_desc = crosslinks.get("what_to_see_desc", f"Discover the must-see highlights at {attraction}.")

    for xlink in xlinks:
        if len(xlink) < 3:
            continue
        t, u, d = xlink[0], xlink[1], xlink[2]
        if "/tickets" in u:
            tickets_desc = d
            if len(xlink) >= 4:
                tickets_link_text = _raw(xlink[3]) + " &rarr;"
        elif "/what-to-see" in u:
            what_desc = d
            if len(xlink) >= 4:
                what_link_text = _raw(xlink[3]) + " &rarr;"

    return f"""  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>Continue Exploring {_raw(attraction)}</h2>
        <p>Discover what to see inside and find the right ticket for your visit.</p>
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


def _render_cta_banner(banner: dict, ticket_url: str) -> str:
    return f"""  <section class="att-cta-banner">
    <h2>{_raw(banner.get("h2", "Ready to book your tickets?"))}</h2>
    <p>{_raw(banner.get("desc", "Secure your preferred time slot online."))}</p>
    <a href="{_e(ticket_url)}" class="att-btn att-btn--white">View All Tickets &amp; Tours</a>
  </section>"""


def _render_faqs(faqs: list) -> str:
    items_html = ""
    for faq in faqs:
        if isinstance(faq, dict):
            q, a = faq.get("question", ""), faq.get("answer", "")
        elif isinstance(faq, (list, tuple)) and len(faq) >= 2:
            q, a = faq[0], faq[1]
        else:
            continue
        items_html += f"""        <details class="att-faq-item" itemscope itemprop="mainEntity" itemtype="https://schema.org/Question">
          <summary class="att-faq-item__q">
            <span itemprop="name">{_raw(q)}</span>
          </summary>
          <div class="att-faq-item__a" itemscope itemprop="acceptedAnswer" itemtype="https://schema.org/Answer">
            <span itemprop="text">{_raw(a)}</span>
          </div>
        </details>\n"""

    return f"""  <section id="pyv-faqs" class="att-section">
    <div class="att-container">
      <div class="att-section-header att-section-header--center">
        <h2>Frequently Asked Questions</h2>
        <p>Common questions visitors ask when planning their trip.</p>
      </div>
      <div class="att-faq" itemscope itemtype="https://schema.org/FAQPage">
{items_html}      </div>
      <div class="att-section-link">
        <a href="/faqs/">View All FAQs &rarr;</a>
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
            # Strip HTML entities for JSON-LD (schema expects plain text)
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


# ─── Validator (mechanical) + Verifier (Claude semantic) ─────────────────────
# Imported from submodules — see validator.py and verifier.py


# ─── Main render ─────────────────────────────────────────────────────────────

def _extract_attraction_name(h1: str, site_slug: str) -> str:
    for prefix in ("Plan Your Visit to ", "Plan your visit to "):
        if h1.startswith(prefix):
            return h1[len(prefix):]
    return site_slug.replace("-", " ").title()


def render(site_slug: str, force: bool = False) -> Path:
    from . import article_source, content_generator, validator, verifier

    output_dir = REPO_ROOT / "output" / site_slug / "l1-pages"
    output_path = output_dir / "plan-your-visit.html"

    if output_path.exists() and not force:
        print(f"[{site_slug}] plan-your-visit.html already exists. Use --force to regenerate.")
        return output_path

    config_path = REPO_ROOT / "input" / site_slug / "l1-config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"l1-config.json not found: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    pyv_cfg = config.get("pages", {}).get("Plan Your Visit", {})
    env = _load_env(site_slug)

    attraction = _extract_attraction_name(pyv_cfg.get("h1", ""), site_slug)
    print(f"[{site_slug}] Attraction: {attraction}")

    articles = article_source.load_plan_your_visit_articles(site_slug, str(REPO_ROOT))
    print(f"[{site_slug}] Loaded {len(articles)} plan-your-visit articles")
    if not articles:
        raise ValueError(f"No plan-your-visit articles found for {site_slug}")

    # Generate card briefs (use meta_desc if present, else Claude)
    print(f"[{site_slug}] Generating card briefs...")
    _cached_briefs = config.get("_card_briefs", {})
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {}
        for a in articles:
            if a["meta_desc"]:
                a["brief"] = a["meta_desc"]
            elif a["title"] in _cached_briefs:
                a["brief"] = _cached_briefs[a["title"]]
            else:
                fut = pool.submit(content_generator.generate_card_brief, attraction, a["title"])
                futures[fut] = a
        for fut in as_completed(futures):
            a = futures[fut]
            a["brief"] = fut.result()
            _cached_briefs[a["title"]] = a["brief"]

    config["_card_briefs"] = _cached_briefs

    # Group articles (pass h2_cache so rewrite_group_h2 can cache without re-calling Claude)
    print(f"[{site_slug}] Grouping articles...")
    h2_cache = config.get("_h2_rewrites", {})
    groups = content_generator.generate_article_groups(attraction, articles, h2_cache=h2_cache, force=force)
    config["_h2_rewrites"] = h2_cache
    groups = sorted(groups, key=lambda g: len(g["articles"]), reverse=True)
    print(f"[{site_slug}] {len(groups)} sections")

    # Quicktips
    quicktips = (not force and config.get("_quicktips")) or content_generator.generate_quicktips(attraction, articles)
    config["_quicktips"] = quicktips

    # Practical info — skip pyv_cfg cache when force (regenerate with new prompts)
    practical = (not force and pyv_cfg.get("practical")) or config.get("_practical_pyv")
    if not practical:
        print(f"[{site_slug}] Generating practical info...")
        practical = content_generator.generate_practical_info(attraction, articles)
        config["_practical_pyv"] = practical
    else:
        print(f"[{site_slug}] Cached practical info ({len(practical)} cards)")

    # Know tips — same
    know_tips = (not force and pyv_cfg.get("know_tips")) or config.get("_know_tips_pyv")
    if not know_tips:
        print(f"[{site_slug}] Generating know tips...")
        know_tips = content_generator.generate_know_tips(attraction, articles)
        config["_know_tips_pyv"] = know_tips
    else:
        print(f"[{site_slug}] Cached know tips ({len(know_tips)} items)")

    # FAQs
    faqs = (not force and pyv_cfg.get("faqs")) or config.get("_faqs_pyv")
    if not faqs:
        print(f"[{site_slug}] Generating FAQs...")
        faqs = content_generator.generate_faqs(attraction, articles)
        config["_faqs_pyv"] = faqs
    else:
        print(f"[{site_slug}] Cached FAQs ({len(faqs)} items)")

    # Banner
    if pyv_cfg.get("cta_h") and pyv_cfg.get("cta_d"):
        banner = {"h2": pyv_cfg["cta_h"], "desc": pyv_cfg["cta_d"]}
    else:
        banner = config.get("_banner_pyv") or content_generator.generate_banner(attraction)
        if not config.get("_banner_pyv"):
            config["_banner_pyv"] = banner

    # Crosslinks
    xlinks = pyv_cfg.get("xlinks", [])
    crosslinks = config.get("_crosslinks_pyv") or content_generator.generate_crosslinks(attraction)
    if not config.get("_crosslinks_pyv"):
        config["_crosslinks_pyv"] = crosslinks

    # Banner ticket URL — from env RED_BANNER_TICKET first, then gyg_url with campaign
    raw_ticket_url = (
        env.get("RED_BANNER_TICKET")
        or env.get("red_banner_ticket")
        or config.get("gyg_url")
        or (pyv_cfg.get("cta1", ["", ""])[1] if isinstance(pyv_cfg.get("cta1"), list) else "")
    )
    campaign_id = f"{site_slug}-plan-your-visit"
    if raw_ticket_url and not raw_ticket_url.startswith("/"):
        ticket_url = _stamp_campaign(raw_ticket_url, campaign_id)
    else:
        ticket_url = raw_ticket_url or "#"
    print(f"[{site_slug}] Banner ticket URL: {ticket_url[:80]}")

    # Save updated config
    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")

    # SEO metadata
    seo_title = pyv_cfg.get("seo_t", f"Plan Your Visit to {attraction}")
    seo_desc = pyv_cfg.get("seo_d", "")
    seo_url = f"https://{config.get('domain', '')}/plan-your-visit/"
    css = _load_css()

    # Assemble
    print(f"[{site_slug}] Assembling HTML...")
    html_out = _assemble(
        seo_title=seo_title, seo_desc=seo_desc, seo_url=seo_url, css=css,
        h1=pyv_cfg.get("h1", f"Plan Your Visit to {attraction}"),
        desc=pyv_cfg.get("desc", ""),
        quicktips=quicktips, groups=groups,
        practical=practical, know_tips=know_tips,
        xlinks=xlinks, crosslinks=crosslinks, attraction=attraction,
        banner=banner, ticket_url=ticket_url, faqs=faqs,
    )

    # Mechanical validation
    ok, reasons, _info = validator.validate(html_out, articles, site_slug, config, ticket_url)
    if not ok:
        print(f"[{site_slug}] VALIDATION FAILED ({len(reasons)} issues):")
        for r in reasons:
            print(f"  ✗ {r}")
        sys.exit(1)
    print(f"[{site_slug}] Validation passed.")

    # Claude semantic verification
    print(f"[{site_slug}] Running semantic verifier...")
    v_ok, issues = verifier.verify(html_out, articles, attraction, config)
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
    quicktips, groups, practical, know_tips,
    xlinks, crosslinks, attraction, banner, ticket_url, faqs,
) -> str:
    parts = [
        f"<!-- SEO\ntitle: {seo_title}\ndescription: {seo_desc}\ncanonical: {seo_url}\n-->",
        f"<style>{css}\n\n/* Inline article links — match template accent color */\n.att-plan-page .att-section a,\n.att-plan-page .att-quicktip a,\n.att-plan-page .att-practical-card a,\n.att-plan-page .att-tips-grid a {{\n    color: var(--accent);\n    text-decoration: none;\n}}\n.att-plan-page .att-section a:hover,\n.att-plan-page .att-quicktip a:hover,\n.att-plan-page .att-practical-card a:hover,\n.att-plan-page .att-tips-grid a:hover {{\n    text-decoration: underline;\n}}</style>",
        "",
        '<div class="att-plan-page">',
        _render_hero(h1, desc),
        _render_quicktips(quicktips),
        "    </div>",
        "  </section>",
        "",
    ]
    for i, group in enumerate(groups):
        parts.append(_render_article_section(group, first=(i == 0)))
        parts.append("")
    if practical:
        parts.append(_render_practical(practical))
        parts.append("")
    if know_tips:
        parts.append(_render_know_tips(know_tips))
        parts.append("")
    parts.append(_render_continue_exploring(attraction, xlinks, crosslinks))
    parts.append("")
    parts.append(_render_cta_banner(banner, ticket_url))
    parts.append("")
    if faqs:
        parts.append(_render_faqs(faqs))
        parts.append("")
    parts.append("</div>")
    jsonld = _build_faq_jsonld(faqs)
    if jsonld:
        parts.append(jsonld)
    return "\n".join(parts)


# ─── CLI ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Generate L1 plan-your-visit page")
    p.add_argument("site_slug", help="Site slug (e.g. museo-del-prado)")
    p.add_argument("--force", action="store_true")
    args = p.parse_args()
    render(args.site_slug, force=args.force)
