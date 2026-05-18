#!/usr/bin/env python3
"""
Update ticket card prices on a site's homepage.

Prices are fetched manually from GYG/Tiqets/Viator (those platforms block scrapers)
and passed in card order. The currency symbol is part of the price string you supply.

Usage:
  python3 update-ticket-prices.py --site hagia --dry-run
  python3 update-ticket-prices.py --site hagia --prices "₺ 2,736" "₺ 1,532" "₺ 3,114" "₺ 1,888" "₺ 1,368" "₺ 1,532"
  python3 update-ticket-prices.py --site auschwitz --prices "zł 78" "zł 99" "zł 195" "zł 750" "zł 1,050" "zł 413"
  python3 update-ticket-prices.py --site msm --prices "€ 16" "€ 109" "€ 95" "€ 220" "€ 251" "€ 130"

--dry-run  shows current card names + prices, no writes.
"""
import re
import os
import sys
import html
import subprocess
import tempfile

DRY_RUN     = "--dry-run" in sys.argv
SITE_FILTER = next((sys.argv[i+1] for i, a in enumerate(sys.argv) if a == "--site"), None)

# Collect --prices args (everything after --prices flag)
PRICES = []
if "--prices" in sys.argv:
    idx = sys.argv.index("--prices")
    PRICES = sys.argv[idx+1:]
    PRICES = [p for p in PRICES if not p.startswith("--")]

# ── SSH credentials ───────────────────────────────────────────────────────────
SSH_KEY_S1  = os.path.expanduser("~/.ssh/id_rsa_bluehost_old")
SSH_HOST_S1 = "kzrmeomy@50.6.109.30"

SSH_KEY_S2  = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
SSH_HOST_S2 = "dpskbcmy@50.6.155.174"

# ── Site registry ─────────────────────────────────────────────────────────────
SITES = [
    {
        "name":        "auschwitz-guide.com",
        "ssh_key":     SSH_KEY_S1,
        "ssh_host":    SSH_HOST_S1,
        "wp_path":     "/home1/kzrmeomy/public_html/website_ce6ca565",
        "homepage_id": 210,
    },
    {
        "name":        "operagarnier-guide.com",
        "ssh_key":     SSH_KEY_S1,
        "ssh_host":    SSH_HOST_S1,
        "wp_path":     "/home1/kzrmeomy/public_html/website_b9cdec12",
        "homepage_id": 129,
    },
    {
        "name":        "montsaintmichel-guide.com",
        "ssh_key":     SSH_KEY_S2,
        "ssh_host":    SSH_HOST_S2,
        "wp_path":     "/home1/dpskbcmy/public_html/website_58b542cb",
        "homepage_id": 65,
    },
    {
        "name":        "hagiasofia-guide.com",
        "ssh_key":     SSH_KEY_S2,
        "ssh_host":    SSH_HOST_S2,
        "wp_path":     "/home1/dpskbcmy/public_html/website_204db6f9",
        "homepage_id": 219,
    },
]


# ── SSH helpers ───────────────────────────────────────────────────────────────
def _opts(key):
    return f"-i {key} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

def ssh(host, key, cmd):
    r = subprocess.run(
        f'SSH_AUTH_SOCK="" ssh {_opts(key)} {host} {cmd!r}',
        shell=True, capture_output=True, text=True
    )
    if r.returncode != 0:
        raise RuntimeError(f"SSH error [{r.returncode}]: {r.stderr.strip()}")
    return r.stdout.strip()

def scp(key, local, host, remote):
    subprocess.run(
        f'SSH_AUTH_SOCK="" scp {_opts(key)} {local} {host}:{remote}',
        shell=True, check=True, capture_output=True
    )


# ── Card extraction ───────────────────────────────────────────────────────────
def extract_cards(content):
    cards = []
    segs = re.split(r'(?=<div class="att-ticket">)', content)
    for seg in segs:
        name  = re.search(r'<h3>(.*?)</h3>', seg)
        price = re.search(r'att-ticket__price-value">(.*?)</span>', seg)
        if name and price:
            cards.append({
                "name":  html.unescape(name.group(1)),
                "price": price.group(1).strip(),
                # store raw name as it appears in HTML (may have &amp; etc.)
                "raw_name": name.group(1),
            })
    return cards


# ── Price replacement ─────────────────────────────────────────────────────────
def apply_prices(content, cards, new_prices):
    fixed = content
    for card, new_price in zip(cards, new_prices):
        escaped = re.escape(card["raw_name"])
        pattern = (
            rf'(<div class="att-ticket">(?:(?!<div class="att-ticket">).)*?'
            rf'<h3>{escaped}</h3>(?:(?!<div class="att-ticket">).)*?'
            rf'att-ticket__price-value">)([^<]+)(</span>)'
        )
        def replacer(m, np=new_price):
            return m.group(1) + np + m.group(3)
        new, count = re.subn(pattern, replacer, fixed, flags=re.DOTALL)
        if count:
            fixed = new
        else:
            print(f"  WARN: regex missed card '{card['name']}' — check HTML structure")
    return fixed


# ── Write to DB ───────────────────────────────────────────────────────────────
def write_to_db(host, key, wp, pid, content):
    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp_html.write(content); tmp_html.close()

    php = (
        f'<?php wp_update_post(array('
        f'"ID"=>{pid},'
        f'"post_content"=>file_get_contents("/tmp/utp_{pid}.html")'
        f')); echo "Updated {pid}\\n";'
    )
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp_php.write(php); tmp_php.close()

    try:
        scp(key, tmp_html.name, host, f"/tmp/utp_{pid}.html")
        scp(key, tmp_php.name,  host, f"/tmp/utp_{pid}.php")
        result = ssh(host, key,
            f"wp eval-file /tmp/utp_{pid}.php --path={wp} 2>/dev/null; "
            f"rm -f /tmp/utp_{pid}.html /tmp/utp_{pid}.php"
        )
        print(f"  DB: {result}")
        ssh(host, key,
            f"wp cache flush --path={wp} 2>/dev/null; "
            f"rm -rf {wp}/wp-content/cache/wp-rocket/ 2>/dev/null || true"
        )
        print(f"  Cache flushed.")
    finally:
        os.unlink(tmp_html.name)
        os.unlink(tmp_php.name)


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    if not SITE_FILTER:
        print("ERROR: --site <name> required")
        sys.exit(1)

    sites = [s for s in SITES if SITE_FILTER in s["name"]]
    if not sites:
        print(f"ERROR: no site matched '{SITE_FILTER}'")
        sys.exit(1)

    site = sites[0]
    host = site["ssh_host"]
    key  = site["ssh_key"]
    wp   = site["wp_path"]
    pid  = site["homepage_id"]

    print(f"Site: {site['name']}  (post {pid})")

    content = ssh(host, key,
        f"wp post get {pid} --field=post_content --path={wp} 2>/dev/null"
    )
    if not content:
        print("ERROR: empty content returned")
        sys.exit(1)

    cards = extract_cards(content)
    if not cards:
        print("ERROR: no att-ticket cards found in post content")
        sys.exit(1)

    print(f"\n{len(cards)} ticket cards found:\n")
    for i, card in enumerate(cards):
        new = PRICES[i] if i < len(PRICES) else "(no price given)"
        arrow = f"→ {new}" if PRICES and i < len(PRICES) else ""
        print(f"  {i+1}. {card['name']:<45} {card['price']:>12}  {arrow}")

    if DRY_RUN or not PRICES:
        print("\nDry-run / no prices given — no changes written.")
        if not PRICES:
            print("Pass prices with: --prices \"€ 16\" \"€ 109\" ...")
        return

    if len(PRICES) != len(cards):
        print(f"\nWARN: {len(PRICES)} prices given but {len(cards)} cards exist.")
        print("Prices applied in order — missing cards left unchanged.\n")

    fixed = apply_prices(content, cards, PRICES)
    if fixed == content:
        print("\nNo changes made — check card names match exactly.")
        return

    print(f"\nApplying {min(len(PRICES), len(cards))} price update(s)…")
    write_to_db(host, key, wp, pid, fixed)


if __name__ == "__main__":
    main()
