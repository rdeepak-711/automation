#!/usr/bin/env python3
"""
homepage.py — L0 Homepage HTML assembler.

Reads article-metas.json + l1-config.json + tickets.md to build homepage.html.
CSS/JS extracted from attraction-homepage-template.html.

Usage:
  python3 scripts/content/l1_assembler/homepage.py <site-slug> [--force]

Sections:
  1. Hero
  2. Top Tickets (6 editorial ticket articles)
  3. Plan Your Visit (6 PYV articles)
  4. Things to Know (6 tips)
  5. What to See (6 WTS articles, top highlights first)
  6. CTA Banner
  7. FAQ
"""

import argparse
import html as _html
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

PLACEHOLDER_IMG = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
TEMPLATE_PATH = Path(__file__).parent.parent.parent.parent.parent / "docs" / "Four Pages" / "attraction-homepage-template.html"
REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
MODEL = os.environ.get("CLAUDE_L1_MODEL", "claude-haiku-4-5-20251001")


# ─── Text helpers ─────────────────────────────────────────────────────────────

def _e(text: str) -> str:
    return _html.escape(str(text), quote=True)


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


# ─── Claude helper ────────────────────────────────────────────────────────────

def _call_claude(prompt: str, timeout: int = 90) -> str | None:
    try:
        r = subprocess.run(
            ["claude", "--print", "--model", MODEL],
            input=prompt, capture_output=True, text=True, timeout=timeout,
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def _parse_json(raw: str | None):
    if not raw:
        return None
    raw = raw.strip()
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)
    raw = raw.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        for pattern in [r"\[.*\]", r"\{.*\}"]:
            m = re.search(pattern, raw, re.DOTALL)
            if m:
                try:
                    return json.loads(m.group(0))
                except json.JSONDecodeError:
                    pass
    return None


# ─── CSS/JS extraction ────────────────────────────────────────────────────────

def _load_css_js() -> tuple[str, str]:
    """Return (css_block, js_block) from homepage template."""
    content = TEMPLATE_PATH.read_text(encoding="utf-8")
    # Use specific pattern to skip the <style> reference inside the HTML comment
    css_m = re.search(r"<style>\s*(?:/\*|:root)", content, re.DOTALL)
    if css_m:
        css_start = css_m.start()
        css_end = content.find("</style>", css_start) + len("</style>")
        css = content[css_start:css_end]
    else:
        css = "<style></style>"
    js_m = re.search(r"<script>.*?</script>", content, re.DOTALL)
    js = js_m.group(0) if js_m else ""
    return css, js


# ─── Data loaders ─────────────────────────────────────────────────────────────

def _load_metas(site_slug: str) -> dict:
    """Load output/<site>/article-metas.json."""
    p = REPO_ROOT / "output" / site_slug / "article-metas.json"
    if not p.exists():
        print(f"[{site_slug}] ERROR: article-metas.json not found. Run build-article-metas.py first.", file=sys.stderr)
        sys.exit(1)
    return json.loads(p.read_text(encoding="utf-8"))


def _load_cfg(site_slug: str) -> dict:
    """Load input/<site>/l1-config.json."""
    p = REPO_ROOT / "input" / site_slug / "l1-config.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def _save_cfg(site_slug: str, cfg: dict) -> None:
    """Write l1-config.json back."""
    p = REPO_ROOT / "input" / site_slug / "l1-config.json"
    p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")


def _parse_tickets_md(site_slug: str) -> list[dict]:
    """Parse tickets.md — pipe-delimited: Tid | Title | URL | token | /slug/path/
    Returns list of {tid, title, affiliate_url, article_slug}."""
    tickets_path = REPO_ROOT / "input" / site_slug / "tickets.md"
    tickets = []
    if not tickets_path.exists():
        return tickets
    for line in tickets_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or not line[0].upper().startswith("T") or "|" not in line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 5:
            continue
        tid = parts[0]
        title = re.sub(r"\s+[Pp]\d{4,}$", "", parts[1]).strip()
        affiliate_url = parts[2]
        col5 = parts[4]
        article_slug = col5.rstrip("/").rsplit("/", 1)[-1] if "/" in col5.rstrip("/") else col5
        tickets.append({
            "tid": tid,
            "title": title,
            "affiliate_url": affiliate_url,
            "article_slug": article_slug,
        })
    return tickets


# ─── Article selection ────────────────────────────────────────────────────────

def _select_ticket_articles(metas: dict, cfg: dict, tickets_by_tid: dict) -> list[dict]:
    """Return up to 6 editorial ticket articles with affiliate data attached.

    Order: top tickets first (from _featured_match, TID insertion order),
    then fill from _editorial_affiliate_map, then remaining TT metas.

    Each returned dict has all metas fields plus:
      slug, article_url, tid, affiliate_url, affiliate_title
    """
    featured_match = cfg.get("_featured_match", {})
    editorial_affiliate = cfg.get("_editorial_affiliate_map", {})

    # Build slug -> tid map: featured_match takes priority
    slug_to_tid: dict[str, str] = {v: k for k, v in featured_match.items()}
    for slug, tid in editorial_affiliate.items():
        if slug not in slug_to_tid:
            slug_to_tid[slug] = tid

    top_slugs = list(featured_match.values())
    result = []
    seen: set[str] = set()

    def _add(slug: str) -> bool:
        if slug in seen or len(result) >= 6:
            return False
        m = metas.get(slug)
        if not m or m.get("category") != "tickets-tours":
            return False
        tid = slug_to_tid.get(slug, "")
        aff_row = tickets_by_tid.get(tid, {})
        result.append({
            **m,
            "slug": slug,
            "article_url": f"/{slug}/",
            "tid": tid,
            "affiliate_url": aff_row.get("affiliate_url", ""),
            "affiliate_title": aff_row.get("title", ""),
        })
        seen.add(slug)
        return True

    for slug in top_slugs:
        _add(slug)
    for slug in editorial_affiliate:
        if len(result) >= 6:
            break
        _add(slug)
    for slug in metas:
        if len(result) >= 6:
            break
        if metas[slug].get("category") == "tickets-tours":
            _add(slug)

    return result


def _select_pyv_articles(metas: dict) -> list[dict]:
    """Return first 6 plan-your-visit articles in metas insertion order."""
    result = []
    for slug, m in metas.items():
        if m.get("category") == "plan-your-visit":
            result.append({**m, "slug": slug, "article_url": f"/{slug}/"})
            if len(result) >= 6:
                break
    return result


def _select_wts_articles(metas: dict, cfg: dict) -> list[dict]:
    """Return up to 6 WTS articles — top highlights first, then fill."""
    top_slugs = cfg.get("_top_highlights_wts", [])
    result = []
    seen: set[str] = set()

    def _add(slug: str) -> bool:
        if slug in seen or len(result) >= 6:
            return False
        m = metas.get(slug)
        if not m or m.get("category") != "what-to-see":
            return False
        result.append({**m, "slug": slug, "article_url": f"/{slug}/"})
        seen.add(slug)
        return True

    for slug in top_slugs:
        _add(slug)
    for slug in metas:
        if len(result) >= 6:
            break
        if metas[slug].get("category") == "what-to-see":
            _add(slug)

    return result


# ─── Ticket card enrichment ───────────────────────────────────────────────────

def _enrich_ticket_cards(
    ticket_articles: list[dict],
    cfg: dict,
    site_slug: str,
    attraction: str,
    currency: str,
    force: bool = False,
) -> dict[str, dict]:
    """Return {slug: {price, duration, lang, tag}} for each ticket article.

    Cached in l1-config under '_homepage_ticket_enrichment'.
    price like 'from €16', duration like '1 hour', lang like 'English'.
    tag is one of: Best Seller, Best Value, Skip the Line, Top Rated,
                   Most Popular, Guided Tour, Private Tour, Combo Deal,
                   Evening Tour, Family Friendly.
    """
    CACHE_KEY = "_homepage_ticket_enrichment"
    cached: dict = cfg.get(CACHE_KEY, {})

    slugs_needed = [a["slug"] for a in ticket_articles if force or a["slug"] not in cached]
    if not slugs_needed:
        return cached

    articles_block = "\n".join(
        f'  {a["slug"]}: editorial="{a.get("card_title", a["slug"])}", '
        f'affiliate="{a.get("affiliate_title", "")}"'
        for a in ticket_articles
        if a["slug"] in slugs_needed
    )

    prompt = f"""For each tour/ticket product below, generate realistic card metadata for {attraction}.

{articles_block}

For EACH item return a JSON object with:
  "price": string like "from {currency}25" — realistic market price for this type of experience
  "duration": string like "1 hour", "1.5–2 hrs", "Half day", "Full day"
  "lang": string like "English", "Multi-language", "Audio guide"
  "tag": one of exactly: Best Seller, Best Value, Skip the Line, Top Rated, Most Popular, Guided Tour, Private Tour, Combo Deal, Evening Tour, Family Friendly

Return ONLY a JSON object: {{"slug": {{"price": "...", "duration": "...", "lang": "...", "tag": "..."}}, ...}}
Use exact slugs as shown. No markdown."""

    raw = _call_claude(prompt, timeout=60)
    result = _parse_json(raw)
    if isinstance(result, dict):
        for slug, data in result.items():
            if isinstance(data, dict):
                cached[slug] = data
        cfg[CACHE_KEY] = cached
        _save_cfg(site_slug, cfg)

    return cached


# ─── Claude content generators ────────────────────────────────────────────────

def _gen_hero(attraction: str, cfg: dict, site_slug: str, force: bool = False) -> dict:
    """Generate hero section content. Cached under '_homepage_hero'."""
    CACHE_KEY = "_homepage_hero"
    if not force and CACHE_KEY in cfg:
        return cfg[CACHE_KEY]
    prompt = (
        f"Write homepage hero content for a travel website about '{attraction}'.\n"
        f"Return ONLY JSON:\n"
        f'{{"badge": "City, Country (3-4 words)", '
        f'"h1": "8-12 word title like \'{attraction} — Tickets, Tours & Visitor Guide\'", '
        f'"desc": "2-3 sentence paragraph, 40-55 words, compelling intro covering what makes it special", '
        f'"cta_tickets": "View Tickets — from €XX →", '
        f'"cta_plan": "Plan Your Visit"}}'
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict) and "h1" in result:
        cfg[CACHE_KEY] = result
        _save_cfg(site_slug, cfg)
        return result
    return {
        "badge": attraction,
        "h1": f"{attraction} — Tickets, Tours & Visitor Guide",
        "desc": f"Everything you need to plan a perfect visit to {attraction}.",
        "cta_tickets": "View Tickets →",
        "cta_plan": "Plan Your Visit",
    }


def _gen_section_headings(attraction: str, cfg: dict, site_slug: str, force: bool = False) -> dict:
    """Generate all section H2s and short descs. Cached under '_homepage_headings'."""
    CACHE_KEY = "_homepage_headings"
    if not force and CACHE_KEY in cfg:
        return cfg[CACHE_KEY]
    prompt = (
        f"Write section headings and one-line descriptions for a '{attraction}' homepage.\n"
        f"Return ONLY JSON with these exact keys:\n"
        f"tickets_h2, tickets_desc, pyv_h2, pyv_desc, tips_h2, tips_desc, "
        f"wts_h2, wts_desc, faq_h2, faq_desc\n"
        f"Each h2: 5-8 words. Each desc: 1 sentence, ≤15 words."
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict) and "tickets_h2" in result:
        cfg[CACHE_KEY] = result
        _save_cfg(site_slug, cfg)
        return result
    return {
        "tickets_h2": f"Top {attraction} Tickets & Tours",
        "tickets_desc": "Compare options and book the right ticket for your visit.",
        "pyv_h2": f"Planning Your Visit to {attraction}",
        "pyv_desc": "Everything you need to know before you go.",
        "tips_h2": "Things to Know Before You Book",
        "tips_desc": "Practical tips to make the most of your visit.",
        "wts_h2": f"What to See at {attraction}",
        "wts_desc": "Don't miss these highlights during your visit.",
        "faq_h2": "Frequently Asked Questions",
        "faq_desc": f"Common questions about visiting {attraction}.",
    }


def _gen_tips(attraction: str, cfg: dict, site_slug: str, force: bool = False) -> list[dict]:
    """Generate 6 tip cards. Cached under '_homepage_tips'."""
    CACHE_KEY = "_homepage_tips"
    if not force and CACHE_KEY in cfg:
        return cfg[CACHE_KEY]
    sys.path.insert(0, str(REPO_ROOT / "scripts" / "content" / "l1" / "assembler"))
    from content_generator import generate_know_tips
    tips = generate_know_tips(attraction)
    if tips:
        cfg[CACHE_KEY] = tips
        _save_cfg(site_slug, cfg)
    return tips or []


def _gen_faqs(attraction: str, cfg: dict, site_slug: str, force: bool = False) -> list[dict]:
    """Generate 10 FAQ items. Cached under '_homepage_faqs'."""
    CACHE_KEY = "_homepage_faqs"
    if not force and CACHE_KEY in cfg:
        return cfg[CACHE_KEY]
    prompt = (
        f"Generate 10 FAQ items for the homepage of a travel site about '{attraction}'.\n"
        f"Cover: tickets, hours, getting there, tips, accessibility, photography, language, cancellation.\n"
        f"Each answer: 1-3 sentences, factual.\n"
        f'Return ONLY a JSON array: [{{"question": "...", "answer": "..."}}]'
    )
    raw = _call_claude(prompt, timeout=90)
    result = _parse_json(raw)
    if isinstance(result, list) and result:
        faqs = result[:10]
        cfg[CACHE_KEY] = faqs
        _save_cfg(site_slug, cfg)
        return faqs
    return []


def _gen_banner(attraction: str, cfg: dict, site_slug: str, force: bool = False) -> dict:
    """Generate CTA banner. Cached under '_homepage_banner'."""
    CACHE_KEY = "_homepage_banner"
    if not force and CACHE_KEY in cfg:
        return cfg[CACHE_KEY]
    prompt = (
        f"Write a CTA banner for '{attraction}' homepage.\n"
        f'Return ONLY JSON: {{"h2": "6-10 word call to action", "desc": "1 sentence ≤20 words", "btn": "3-5 word button label"}}'
    )
    raw = _call_claude(prompt, timeout=30)
    result = _parse_json(raw)
    if isinstance(result, dict) and "h2" in result:
        cfg[CACHE_KEY] = result
        _save_cfg(site_slug, cfg)
        return result
    return {
        "h2": f"Ready to visit {attraction}?",
        "desc": "Book your tickets in advance and skip the queues.",
        "btn": "Check Availability",
    }


# ─── Section renderers ────────────────────────────────────────────────────────

def _render_ticket_card(article: dict, enrich: dict, campaign_id: str) -> str:
    slug = article["slug"]
    e_data = enrich.get(slug, {})
    tag = _e(e_data.get("tag", "Popular"))
    title = _e(article.get("card_title") or slug.replace("-", " ").title())
    price_raw = e_data.get("price", "")
    price = _e(price_raw) if price_raw else ""
    duration = _e(e_data.get("duration", ""))
    lang = _e(e_data.get("lang", ""))
    article_url = _e(article.get("article_url", f"/{slug}/"))

    aff_url = article.get("affiliate_url", "")
    if aff_url:
        cta_href = _e(_stamp_campaign(aff_url, campaign_id))
        cta_rel = ' rel="nofollow sponsored" target="_blank"'
    else:
        cta_href = article_url
        cta_rel = ""

    bullets = article.get("bullets", [])
    bullets_html = "".join(f"<li>{_e(b)}</li>" for b in bullets[:4])

    price_block = (
        f'<div class="att-ticket__price">'
        f'<span class="att-ticket__price-label">from</span>'
        f'<span class="att-ticket__price-value">{price}</span>'
        f'</div>'
    ) if price else ""

    meta_parts = []
    if duration:
        meta_parts.append(f"<span>{duration}</span>")
    if lang:
        meta_parts.append(f"<span>{lang}</span>")
    meta_block = f'<div class="att-ticket__meta">{"".join(meta_parts)}</div>' if meta_parts else ""

    return f'''
      <div class="att-ticket">
        <img class="att-ticket__img" src="{PLACEHOLDER_IMG}" alt="{title}" loading="lazy" />
        <div class="att-ticket__body">
          <span class="att-ticket__tag att-ticket__tag--popular">{tag}</span>
          <h3>{title}</h3>
          {price_block}
          <ul class="att-ticket__bullets">{bullets_html}</ul>
        </div>
        <div class="att-ticket__footer">
          {meta_block}
          <a href="{cta_href}" class="att-ticket__cta"{cta_rel}>Check Availability &rarr;</a>
          <a href="{article_url}" class="att-ticket__more">Learn more &rarr;</a>
        </div>
      </div>'''


def _render_highlight_card(article: dict, cta_text: str = "Read guide &rarr;") -> str:
    slug = article["slug"]
    title = _e(article.get("card_title") or slug.replace("-", " ").title())
    desc = _e(article.get("description", ""))
    url = _e(article.get("article_url", f"/{slug}/"))
    return f'''
      <div class="att-highlight">
        <img class="att-highlight__img" src="{PLACEHOLDER_IMG}" alt="{title}" loading="lazy" />
        <div class="att-highlight__body">
          <h3>{title}</h3>
          <p>{desc}</p>
          <a href="{url}">{cta_text}</a>
        </div>
      </div>'''


def _render_tip(tip: dict) -> str:
    emoji = _e(tip.get("emoji", "💡"))
    label = _raw(tip.get("label", ""))
    desc = _raw(tip.get("desc", ""))
    return f'''
      <div class="att-tip">
        <span class="att-tip__icon">{emoji}</span>
        <span><strong>{label}</strong> {desc}</span>
      </div>'''


def _render_faq(item: dict) -> str:
    q = _e(item.get("question", ""))
    a = _e(item.get("answer", ""))
    return f'''
        <div class="att-faq-item" itemscope itemprop="mainEntity" itemtype="https://schema.org/Question">
          <button class="att-faq-item__q">
            <span itemprop="name">{q}</span>
            <span class="att-faq-item__icon">+</span>
          </button>
          <div class="att-faq-item__a" itemscope itemprop="acceptedAnswer" itemtype="https://schema.org/Answer">
            <span itemprop="text">{a}</span>
          </div>
        </div>'''


def _assemble(
    site_slug: str,
    attraction: str,
    domain: str,
    campaign_id: str,
    cta_url: str,
    faq_url: str,
    hero: dict,
    headings: dict,
    ticket_articles: list[dict],
    ticket_enrich: dict,
    pyv_articles: list[dict],
    wts_articles: list[dict],
    tips: list[dict],
    faqs: list[dict],
    banner: dict,
    css: str,
    js: str,
) -> str:
    tickets_html = "".join(_render_ticket_card(a, ticket_enrich, campaign_id) for a in ticket_articles)
    pyv_html = "".join(_render_highlight_card(a, "Know more &rarr;") for a in pyv_articles)
    wts_html = "".join(_render_highlight_card(a, "Know more &rarr;") for a in wts_articles)
    tips_html = "".join(_render_tip(t) for t in tips)
    faqs_html = "".join(_render_faq(f) for f in faqs)

    cta_aff = _e(_stamp_campaign(cta_url, campaign_id)) if cta_url.startswith("http") else _e(cta_url)
    domain_esc = re.escape(domain)

    seo_title = hero.get("h1", f"{attraction} — Tickets, Tours & Visitor Guide")
    seo_desc = f"Everything you need to plan your {attraction} visit — compare tickets, discover highlights, and get practical tips."

    page = f"""<!-- SEO
title: {seo_title}
description: {seo_desc}
canonical: https://{domain}
-->

{css}
<style>
.att-homepage .att-highlights-grid .att-highlight__body p {{
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}}
</style>

<div class="att-homepage">

  <section class="att-hero">
    <div class="att-container">
      <div class="att-hero__inner">
        <div class="att-hero__content">
          <div class="att-hero__badge att-animate">{_e(hero.get("badge", attraction))}</div>
          <h1 class="att-animate att-delay-1">{_e(hero.get("h1", attraction))}</h1>
          <p class="att-hero__desc att-animate att-delay-2">{_e(hero.get("desc", ""))}</p>
          <div class="att-hero__actions att-animate att-delay-3">
            <a href="#att-tickets" class="att-btn att-btn--primary">{_raw(hero.get("cta_tickets", "View Tickets &rarr;"))}</a>
            <a href="#att-plan" class="att-btn att-btn--outline">{_e(hero.get("cta_plan", "Plan Your Visit"))}</a>
          </div>
        </div>
        <div class="att-hero__image-wrap att-animate att-delay-2">
          <img class="att-hero__img" src="{PLACEHOLDER_IMG}" alt="{_e(hero.get('h1', attraction))}" loading="eager" />
        </div>
      </div>
    </div>
  </section>

  <section id="att-tickets" class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{_e(headings.get("tickets_h2", "Top Tickets & Tours"))}</h2>
        <p>{_e(headings.get("tickets_desc", ""))}</p>
      </div>
      <div class="att-tickets-grid">{tickets_html}
      </div>
      <div class="att-section-link"><a href="/tickets/">View All Tickets &amp; Tours &rarr;</a></div>
    </div>
  </section>

  <section id="att-plan" class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{_e(headings.get("pyv_h2", "Plan Your Visit"))}</h2>
        <p>{_e(headings.get("pyv_desc", ""))}</p>
      </div>
      <div class="att-highlights-grid">{pyv_html}
      </div>
      <div class="att-section-link"><a href="/plan-your-visit/">View Complete Visitor Guide &rarr;</a></div>
    </div>
  </section>

  <section class="att-section att-section--alt">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{_e(headings.get("tips_h2", "Things to Know Before You Book"))}</h2>
        <p>{_e(headings.get("tips_desc", ""))}</p>
      </div>
      <div class="att-tips-grid">{tips_html}
      </div>
    </div>
  </section>

  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header">
        <h2>{_e(headings.get("wts_h2", "What to See"))}</h2>
        <p>{_e(headings.get("wts_desc", ""))}</p>
      </div>
      <div class="att-highlights-grid">{wts_html}
      </div>
      <div class="att-section-link"><a href="/what-to-see/">Explore Everything to See &rarr;</a></div>
    </div>
  </section>

  <section class="att-cta-banner">
    <h2>{_e(banner.get("h2", f"Ready to visit {attraction}?"))}</h2>
    <p>{_e(banner.get("desc", ""))}</p>
    <a href="{cta_aff}" class="att-btn att-btn--white" rel="nofollow sponsored" target="_blank">{_e(banner.get("btn", "Check Availability"))} &rarr;</a>
  </section>

  <section class="att-section">
    <div class="att-container">
      <div class="att-section-header att-section-header--center">
        <h2>{_e(headings.get("faq_h2", "Frequently Asked Questions"))}</h2>
        <p>{_e(headings.get("faq_desc", ""))}</p>
      </div>
      <div class="att-faq" itemscope itemtype="https://schema.org/FAQPage">{faqs_html}
      </div>
      <div class="att-section-link">
        <a href="{_e(faq_url)}">View All Frequently Asked Questions &rarr;</a>
      </div>
    </div>
  </section>

</div>

{js}
"""

    if domain:
        page = re.sub(r'https?://(?:www\.)?' + domain_esc + r'(/[^"\'>\s]*)', r'\1', page)

    return page


# ─── Attraction name extraction ───────────────────────────────────────────────

def _extract_attraction_name(h1: str, site_slug: str) -> str:
    """Extract attraction name from L1 page H1."""
    for prefix in ("Tickets & Tours — ", "Tickets & Tours for ", "Tickets and Tours — ", "Tickets for "):
        if h1.startswith(prefix):
            return h1[len(prefix):]
    for suffix in (" Tickets &amp; Tours", " Tickets & Tours", " Tickets and Tours"):
        if h1.endswith(suffix):
            return h1[: -len(suffix)]
    return site_slug.replace("-", " ").title()


# ─── Entry point ──────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description="Generate homepage.html for a site")
    p.add_argument("site_slug", help="e.g. amsterdam-canal-cruise")
    p.add_argument("--force", action="store_true", help="Regenerate cached Claude content")
    args = p.parse_args()

    site_slug = args.site_slug
    force = args.force

    print(f"[{site_slug}] Generating homepage...")

    env = _load_env(site_slug)
    cfg = _load_cfg(site_slug)

    tt_h1 = cfg.get("pages", {}).get("Tickets & Tours", {}).get("h1", "")
    attraction = _extract_attraction_name(tt_h1, site_slug)
    print(f"[{site_slug}] Attraction: {attraction}")

    domain = cfg.get("domain", "")
    cta_url = cfg.get("gyg_url", "/tickets/")
    campaign_id = f"{site_slug}-homepage"
    currency = env.get("CURRENCY", "€")

    metas = _load_metas(site_slug)
    tickets_by_tid = {t["tid"]: t for t in _parse_tickets_md(site_slug)}
    css, js = _load_css_js()

    ticket_articles = _select_ticket_articles(metas, cfg, tickets_by_tid)
    pyv_articles = _select_pyv_articles(metas)
    wts_articles = _select_wts_articles(metas, cfg)
    print(f"[{site_slug}] Selected: {len(ticket_articles)} tickets, {len(pyv_articles)} PYV, {len(wts_articles)} WTS")

    ticket_enrich = _enrich_ticket_cards(ticket_articles, cfg, site_slug, attraction, currency, force)

    hero = _gen_hero(attraction, cfg, site_slug, force)
    headings = _gen_section_headings(attraction, cfg, site_slug, force)
    tips = _gen_tips(attraction, cfg, site_slug, force)
    faqs = _gen_faqs(attraction, cfg, site_slug, force)
    banner = _gen_banner(attraction, cfg, site_slug, force)

    faq_slug = next(
        (s for s, v in metas.items() if v.get("category") == "plan-your-visit" and "faq" in s),
        None,
    )
    faq_url = f"/{faq_slug}/" if faq_slug else "/faq/"

    print(f"[{site_slug}] Assembling HTML...")
    page = _assemble(
        site_slug=site_slug,
        attraction=attraction,
        domain=domain,
        campaign_id=campaign_id,
        cta_url=cta_url,
        faq_url=faq_url,
        hero=hero,
        headings=headings,
        ticket_articles=ticket_articles,
        ticket_enrich=ticket_enrich,
        pyv_articles=pyv_articles,
        wts_articles=wts_articles,
        tips=tips,
        faqs=faqs,
        banner=banner,
        css=css,
        js=js,
    )

    out_dir = REPO_ROOT / "output" / site_slug
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "homepage.html"
    out_file.write_text(page, encoding="utf-8")
    print(f"[{site_slug}] Wrote {out_file} ({len(page):,} bytes)")


if __name__ == "__main__":
    main()
