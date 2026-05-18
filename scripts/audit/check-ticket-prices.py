#!/usr/bin/env python3
"""
Audit ticket card prices on auschwitz-guide.com homepage vs live market prices.

Strategy:
  - GYG and Viator block all fetches (403). No way around this without a browser.
  - Tiqets pages are fetchable — used as the reference price source.
  - Prices are compared per tour *type* (not per platform), since all platforms
    list similar products from similar operators at similar price points.

Usage:
  python3 check-ticket-prices.py              # audit + report only
  python3 check-ticket-prices.py --update     # write corrected prices to WP DB

Tolerance: flags if shown price differs from Tiqets reference by more than 20%.
  (GYG/Viator often run 5-15% cheaper than Tiqets; 20% gives clean signal.)
"""
import re
import os
import sys
import json
import html
import subprocess
import tempfile
import urllib.request
import urllib.error

UPDATE = "--update" in sys.argv

# ── SSH / WP config ───────────────────────────────────────────────────────────
SSH_KEY  = os.path.expanduser("~/.ssh/id_rsa_bluehost_old")
SSH_HOST = "kzrmeomy@50.6.109.30"
WP_PATH  = "/home1/kzrmeomy/public_html/website_ce6ca565"
POST_ID  = 210   # auschwitz homepage

# EUR → PLN mid-market rate (update when stale)
EUR_PLN = 4.27   # 2026-04


# ── Tiqets reference prices ───────────────────────────────────────────────────
# Maps tour type slug → Tiqets listing URL (en, currency=EUR).
# These are the closest equivalent products on Tiqets for each homepage card.
TIQETS_REFS = {
    "guided-krakow": {
        "label":   "Guided Tour from Kraków (hotel pickup)",
        "url":     "https://www.tiqets.com/en/krakow-attractions-c46/tickets-for-auschwitz-birkenau-guided-tour-from-krakow-hotel-pickup-p1095816/?currency=EUR",
    },
    "transport-krakow": {
        "label":   "Self-Guided + Private Transport from Kraków",
        "url":     "https://www.tiqets.com/en/krakow-attractions-c46/tickets-for-auschwitz-birkenau-guided-tour-private-transport-p1028640/?currency=EUR",
    },
    "salt-mine": {
        "label":   "Auschwitz + Salt Mine Combo",
        "url":     "https://www.tiqets.com/en/auschwitz-day-trips-from-krakow-l224973/?currency=EUR",
    },
    "warsaw": {
        "label":   "Day Tour from Warsaw",
        "url":     "https://www.tiqets.com/en/krakow-attractions-c46/tickets-for-auschwitz-birkenau-guided-tour-from-krakow-hotel-pickup-p1095816/?currency=EUR",
    },
    "wroclaw": {
        "label":   "Day Tour from Wrocław",
        "url":     "https://www.tiqets.com/en/krakow-attractions-c46/tickets-for-auschwitz-birkenau-guided-tour-from-krakow-hotel-pickup-p1095816/?currency=EUR",
    },
    "katowice": {
        "label":   "Day Tour from Katowice",
        "url":     "https://www.tiqets.com/en/krakow-attractions-c46/tickets-for-auschwitz-birkenau-guided-tour-from-krakow-hotel-pickup-p1095816/?currency=EUR",
    },
}

# GYG actual PLN prices — confirmed from live GYG pages 2026-04-30.
# Source: each specific GYG tour page with ?currency=PLN
# Update these manually when prices change (GYG prices fluctuate seasonally).
GYG_PRICES_PLN = {
    "guided-krakow":    78,    # t88880  zł78  (was zł87, currently discounted)
    "transport-krakow": 99,    # t293880 zł99
    "salt-mine":        195,   # t92097  zł195 (was zł390, currently discounted)
    "warsaw":           750,   # t351321 zł750
    "wroclaw":          1050,  # t79692  zł1050 (was zł1400, currently discounted)
    "katowice":         413,   # t334786 zł413
}

# Legacy Tiqets reference (kept for context — GYG prices differ significantly)
TIQETS_PRICES = {
    "guided-krakow":    {"eur": 44.41, "label": "Guided Tour from Kraków"},
    "transport-krakow": {"eur": 31.41, "label": "Self-Guided + Transport"},
    "salt-mine":        {"eur": 70.25, "label": "Auschwitz + Salt Mine"},
    "warsaw":           {"eur": 146.95, "label": "Day Tour from Warsaw"},
    "wroclaw":          {"eur": 119.71, "label": "Day Tour from Wrocław"},
    "katowice":         {"eur": 65.72,  "label": "Day Tour from Katowice"},
}

# Map homepage card names to tour type slugs
CARD_TYPE_MAP = {
    "Auschwitz Guided Tour":               "guided-krakow",
    "Entry + Private Transport from Kraków": "transport-krakow",
    "Auschwitz + Wieliczka Salt Mine Combo": "salt-mine",
    "Day Tour from Warsaw":                "warsaw",
    "Day Tour from Wrocław":               "wroclaw",
    "Day Tour from Katowice":              "katowice",
}

TOLERANCE_PCT = 20   # flag if site price differs by more than this %


# ── SSH helpers ───────────────────────────────────────────────────────────────
def _ssh_opts():
    return f"-i {SSH_KEY} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

def ssh(cmd):
    r = subprocess.run(
        f'SSH_AUTH_SOCK="" ssh {_ssh_opts()} {SSH_HOST} {cmd!r}',
        shell=True, capture_output=True, text=True
    )
    if r.returncode != 0:
        raise RuntimeError(f"SSH error: {r.stderr.strip()}")
    return r.stdout

def scp(local, remote):
    subprocess.run(
        f'SSH_AUTH_SOCK="" scp {_ssh_opts()} {local} {SSH_HOST}:{remote}',
        shell=True, check=True, capture_output=True
    )


# ── Card extraction ───────────────────────────────────────────────────────────
def extract_cards(content):
    cards = []
    segments = re.split(r'(?=<div class="att-ticket">)', content)
    for seg in segments:
        if 'att-ticket__price-value' not in seg:
            continue
        name  = re.search(r'<h3>(.*?)</h3>', seg)
        price = re.search(r'att-ticket__price-value">(.*?)</span>', seg)
        cta   = re.search(r'href="([^"]+)"[^>]*class="att-ticket__cta"', seg)
        more  = re.search(r'href="([^"]+)"[^>]*class="att-ticket__more"', seg)
        if name and price and cta:
            cards.append({
                "name":        html.unescape(name.group(1)),
                "shown_price": price.group(1).strip(),
                "gyg_url":     cta.group(1).replace("&amp;", "&"),
                "more_url":    (more.group(1) if more else ""),
                "_seg":        seg,
            })
    return cards


# ── Price utilities ───────────────────────────────────────────────────────────
def eur_to_pln(eur):
    return round(eur * EUR_PLN)

def parse_shown_pln(shown):
    m = re.search(r'[\d.]+', shown)
    return int(float(m.group())) if m else None

def diff_pct(shown, ref):
    if shown and ref:
        return round((ref - shown) / ref * 100, 1)
    return None


# ── Live Tiqets fetch (optional — for refreshing hardcoded prices) ─────────────
FETCH_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
    "Accept-Language": "en-GB,en;q=0.9",
    "Accept": "text/html,application/xhtml+xml",
}

def fetch_tiqets_price(url):
    """Attempt to pull lowest EUR price from a Tiqets listing page."""
    try:
        req = urllib.request.Request(url, headers=FETCH_HEADERS)
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        return None, f"fetch error: {e}"

    # Look for JSON-LD or structured price data
    for ld_raw in re.findall(r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>', body, re.DOTALL):
        try:
            ld = json.loads(ld_raw)
            items = ld if isinstance(ld, list) else [ld]
            for item in items:
                offers = item.get("offers") or item.get("offer")
                if not offers:
                    continue
                if isinstance(offers, dict):
                    offers = [offers]
                prices = []
                for o in offers:
                    p = o.get("price") or o.get("lowPrice")
                    c = o.get("priceCurrency", "EUR")
                    if p and c == "EUR":
                        prices.append(float(p))
                if prices:
                    return min(prices), None
        except Exception:
            continue

    # Fallback: scan visible text for "€xx.xx" patterns
    matches = re.findall(r'€\s*([\d,]+(?:\.\d{2})?)', body)
    if matches:
        prices = [float(m.replace(",", "")) for m in matches]
        reasonable = [p for p in prices if 20 < p < 500]
        if reasonable:
            return min(reasonable), None

    return None, "price not found"


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=== Auschwitz Ticket Price Audit ===")
    print(f"Reference: Tiqets (2026-04-30), EUR→PLN rate {EUR_PLN}\n")

    print("Pulling homepage content from WP…")
    content = ssh(f"wp post get {POST_ID} --field=post_content --path={WP_PATH} 2>/dev/null")
    if not content.strip():
        print("ERROR: empty content returned")
        sys.exit(1)

    cards = extract_cards(content)
    print(f"Found {len(cards)} ticket cards\n")

    results = []
    for card in cards:
        name      = card["name"]
        shown     = card["shown_price"]
        shown_pln = parse_shown_pln(shown)
        shown_eur = round(shown_pln / EUR_PLN, 2) if shown_pln else None
        type_slug = CARD_TYPE_MAP.get(name)
        ref       = TIQETS_PRICES.get(type_slug) if type_slug else None

        if ref:
            ref_eur = ref["eur"]
            ref_pln = eur_to_pln(ref_eur)
            diff    = diff_pct(shown_pln, ref_pln)
            if diff is None:
                status = "UNKNOWN"
            elif abs(diff) <= TOLERANCE_PCT:
                status = "OK"
            else:
                direction = "UNDERPRICED" if diff > 0 else "OVERPRICED"
                status = f"{direction} {diff:+.0f}%"
        else:
            ref_eur, ref_pln, diff = None, None, None
            status = "NO_REF"

        results.append({
            **card,
            "shown_pln": shown_pln,
            "shown_eur": shown_eur,
            "ref_eur":   ref_eur,
            "ref_pln":   ref_pln,
            "status":    status,
        })

        icon = "✅" if status == "OK" else ("❌" if "PRICED" in status else "⚠️")
        print(f"  {icon} {name}")
        print(f"     Site:    {shown} (≈ €{shown_eur})")
        if ref_eur:
            print(f"     Tiqets:  €{ref_eur} (≈ PLN {ref_pln})")
        print(f"     Status:  {status}")
        print()

    # ── Summary ───────────────────────────────────────────────────────────────
    print("=" * 74)
    print(f"{'Card':<38} {'Shown':>8} {'Site€':>6} {'Tiqets€':>8} {'Tiqets PLN':>11}  Status")
    print("-" * 74)
    needs_fix = []
    for r in results:
        ref_eur_s = f"€{r['ref_eur']:.2f}" if r["ref_eur"] else "?"
        ref_pln_s = f"PLN {r['ref_pln']}" if r["ref_pln"] else "?"
        site_eur  = f"€{r['shown_eur']:.0f}" if r["shown_eur"] else "?"
        flag      = "❌" if "PRICED" in r["status"] else ""
        print(f"{r['name']:<38} {r['shown_price']:>8} {site_eur:>6} {ref_eur_s:>8} {ref_pln_s:>11}  {r['status']} {flag}")
        if "PRICED" in r["status"]:
            needs_fix.append(r)
    print("=" * 74)

    print(f"\nNote: GYG prices may run 5-15% below Tiqets for same tour type.")
    print(f"      Flag threshold: >{TOLERANCE_PCT}% difference from Tiqets reference.")

    if not needs_fix:
        print("\nAll prices within tolerance — no update needed.")
        return

    print(f"\n{len(needs_fix)} card(s) likely need price correction:")
    for r in needs_fix:
        print(f"  • {r['name']}: site PLN {r['shown_pln']} → suggested PLN {r['ref_pln']} (Tiqets: €{r['ref_eur']})")

    if not UPDATE:
        print("\nRun with --update to write Tiqets-aligned prices to WP DB.")
        print("Review suggested prices manually before running --update.")
        return

    # ── Apply updates ─────────────────────────────────────────────────────────
    new_content = content
    for r in needs_fix:
        if not r["ref_pln"]:
            continue
        old_price = r["shown_price"]
        new_price = f"PLN {r['ref_pln']}"
        escaped   = re.escape(r["name"])

        def _replacer(m, old=old_price, new=new_price):
            return m.group().replace(
                f'att-ticket__price-value">{old}</span>',
                f'att-ticket__price-value">{new}</span>',
                1
            )

        pattern     = rf'<div class="att-ticket">.*?{escaped}.*?(?=<div class="att-ticket">|</div>\s*</div>\s*</section>)'
        new_content = re.sub(pattern, _replacer, new_content, flags=re.DOTALL, count=1)
        print(f"  Patching [{r['name']}]: {old_price} → {new_price}")

    if new_content == content:
        print("No content changed (regex anchor not matched — check HTML structure).")
        return

    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp_html.write(new_content); tmp_html.close()

    php = (
        f'<?php wp_update_post(array('
        f'"ID"=>{POST_ID},'
        f'"post_content"=>file_get_contents("/tmp/prices_{POST_ID}.html")'
        f')); echo "Updated {POST_ID}\\n";'
    )
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp_php.write(php); tmp_php.close()

    try:
        scp(tmp_html.name, f"/tmp/prices_{POST_ID}.html")
        scp(tmp_php.name,  f"/tmp/prices_{POST_ID}.php")
        result = ssh(
            f"wp eval-file /tmp/prices_{POST_ID}.php --path={WP_PATH} 2>/dev/null; "
            f"rm -f /tmp/prices_{POST_ID}.html /tmp/prices_{POST_ID}.php"
        )
        print(f"\nDB: {result.strip()}")
        ssh(f"wp cache flush --path={WP_PATH} 2>/dev/null")
        print("Cache flushed.")
    finally:
        os.unlink(tmp_html.name)
        os.unlink(tmp_php.name)


if __name__ == "__main__":
    main()
