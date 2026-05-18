#!/usr/bin/env python3
"""
Update Plan Your Visit and What to See card sections on site homepages.

Each section holds 6 att-highlight cards (image + title + description + link).
Card content is defined per site in the SITES registry below.

Usage:
  python3 update-homepage-sections.py --site hagia --dry-run
  python3 update-homepage-sections.py --site hagia --section plan
  python3 update-homepage-sections.py --site hagia --section what
  python3 update-homepage-sections.py --site hagia                   # both sections
"""
import re
import os
import sys
import subprocess
import tempfile

DRY_RUN        = "--dry-run" in sys.argv
SITE_FILTER    = next((sys.argv[i+1] for i, a in enumerate(sys.argv) if a == "--site"),    None)
SECTION_FILTER = next((sys.argv[i+1] for i, a in enumerate(sys.argv) if a == "--section"), None)

# ── SSH credentials ───────────────────────────────────────────────────────────
SSH_KEY_S1  = os.path.expanduser("~/.ssh/id_rsa_bluehost_old")
SSH_HOST_S1 = "kzrmeomy@50.6.109.30"

SSH_KEY_S2  = os.path.expanduser("~/.ssh/id_rsa_bluehost2")
SSH_HOST_S2 = "dpskbcmy@50.6.155.174"


# ── Card helpers ──────────────────────────────────────────────────────────────
def card(img_url, alt, href, title, desc):
    """Build one att-highlight card HTML block."""
    return (
        f'        <div class="att-highlight">\n'
        f'          <img class="att-highlight__img" src="{img_url}" alt="{alt}" />\n'
        f'          <div class="att-highlight__body">'
        f'<h3><a href="{href}">{title}</a></h3>'
        f'<p>{desc}</p>'
        f'<a href="{href}">Read guide &rarr;</a>'
        f'</div>\n'
        f'        </div>'
    )


# ── Site registry ─────────────────────────────────────────────────────────────
def _hagia_cards():
    b = "https://hagiasophia-guide.com/wp-content/uploads/2026/04"
    plan = [
        card(f"{b}/hagia-sophia-mosque.avif", "Hagia Sophia Opening Hours",
             "/plan-your-visit/hagia-sophia-opening-hours/",
             "Hagia Sophia Opening Hours &amp; Days",
             "Opens at 9 AM daily. Closes five times for prayer &mdash; each lasting 30&ndash;90 minutes. Friday midday prayers cause the longest gap. Last entry is 30 minutes before closing."),
        card(f"{b}/hagia-sophia-morning-light.avif", "Best Time to Visit Hagia Sophia",
             "/plan-your-visit/best-time-to-visit-hagia-sophia/",
             "Best Time to Visit Hagia Sophia",
             "April to June and September to October offer the ideal balance of weather and manageable crowds. July and August are peak season with the longest queues. November to March is quietest, though cooler."),
        card(f"{b}/aerial-view-of-sultanahmet-istanbul-coastline.avif", "How to Get to Hagia Sophia",
             "/plan-your-visit/how-to-get-to-hagia-sophia/",
             "How to Get to Hagia Sophia",
             "Take the T1 tram to Sultanahmet &mdash; the entrance is a 3-minute walk. Buses, ferries from Eminön&uuml;, and taxis from all major Istanbul districts are also options."),
        card(f"{b}/hagia-sophia-exterior-courtyard.avif", "Hagia Sophia Official Website",
             "/plan-your-visit/official-website/",
             "Hagia Sophia Official Website",
             "Where to book entry, check prayer-time closures, and find current visitor rules. A guide to navigating the official Turkish ministry site."),
        card(f"{b}/hagia-sophia-garden-walkway-view.avif", "Hagia Sophia Entrances",
             "/plan-your-visit/",
             "Hagia Sophia Entrances &amp; Entry Points",
             "The main visitor entrance faces Sultanahmet Square on the western side. A separate entrance is used by worshippers during prayer times. Queue management points change seasonally."),
        card(f"{b}/wheelchair-user-inside-hagia-sophia.avif", "Hagia Sophia Accessibility",
             "/plan-your-visit/hagia-sophia-accessibility-guide/",
             "Hagia Sophia Accessibility Guide",
             "The ground floor is fully wheelchair accessible. Free wheelchairs available at the entrance. The upper gallery is reached via a steep ramp &mdash; contact the museum in advance."),
    ]
    what = [
        card(f"{b}/hagia-sophia-interior-prayer-hall.avif", "What to See Inside Hagia Sophia",
             "/what-to-see/what-to-see-inside-hagia-sophia/",
             "What to See Inside Hagia Sophia: Complete Guide",
             "The dome, the mosaics, the nave, the upper gallery &mdash; a room-by-room breakdown of everything worth seeing on a single visit."),
        card(f"{b}/hagia-sophia-jesus-mosaic-wall.avif", "Hagia Sophia Mosaics",
             "/what-to-see/hagia-sophia-mosaics/",
             "The Mosaics: History &amp; Where to Find Them",
             "Byzantine gold-tessera mosaics survive across the nave and upper gallery. Most date from the 9th&ndash;14th centuries and survived centuries of whitewash."),
        card(f"{b}/hagia-sophia-grand-interior-hall.avif", "Hagia Sophia Architecture",
             "/what-to-see/hagia-sophia-architecture/",
             "Architecture: What Makes It Extraordinary",
             "The 55-metre dome appears to float on a ring of light. Built in 537 AD, it held the record for the world&rsquo;s largest dome for nearly a thousand years."),
        card(f"{b}/hagia-sophia-dome-view.avif", "Hagia Sophia Upper Gallery",
             "/what-to-see/hagia-sophia-upper-gallery/",
             "The Upper Gallery: Views &amp; Best Mosaics",
             "The upper gallery offers bird's-eye views of the nave and houses the finest surviving Byzantine mosaics, including the Deesis and the Empress Zoe panel."),
        card(f"{b}/hagia-sophia-deesis-mosaic.avif", "Hagia Sophia Deesis Mosaic",
             "/what-to-see/hagia-sophia-deesis-mosaic/",
             "The Deesis Mosaic: Byzantine Masterpiece",
             "Considered one of the greatest works of Byzantine art &mdash; Christ flanked by the Virgin Mary and John the Baptist, rendered in extraordinary detail around 1261 AD."),
        card(f"{b}/hagia-sophia-dome-calligraphy-ceiling.avif", "Hagia Sophia Hidden Details",
             "/what-to-see/hagia-sophia-hidden-details/",
             "Hidden Details Most Visitors Miss",
             "Viking graffiti in the gallery, the weeping column, rare purple Porphyry stone, and a cat who calls the mosque home &mdash; details hiding in plain sight."),
    ]
    return plan, what


# ── Angkor Wat Plan Your Visit — Priority List ───────────────────────────────
# Cards are selected top-down; first 6 with a live post are shown on the homepage.
# Priority order:
#   1. Opening hours          → /plan-your-visit/opening-hours/
#   2. Best time to visit     → /plan-your-visit/best-time-to-visit/
#   3. How to reach           → /plan-your-visit/getting-there-from-siem-reap/
#   4. Official Site          → /plan-your-visit/official-website/
#   5. Entrances              → /plan-your-visit/  (no dedicated article)
#   6. Accessibility          → /plan-your-visit/accessibility/
#   7. Dress code             → /plan-your-visit/dress-code/
#   8. Map                    → /plan-your-visit/angkor-wat-map/
#   9. Parking                → /plan-your-visit/parking/  (no article yet)

def _angkorwat_cards():
    b = "https://angkorwat-guide.com/wp-content/uploads/2026/04"
    plan = [
        card(f"{b}/Angkor-Wat-Lotus-Pond.avif", "Angkor Wat Opening Hours",
             "/plan-your-visit/opening-hours/",
             "Angkor Wat Opening Hours",
             "Opens daily from 5:00 AM to 6:00 PM. Arrive before sunrise for the most spectacular views &mdash; the complex lights up from 5:30 AM."),
        card(f"{b}/Monks-at-Angkor-Temple-Entrance.avif", "Best Time to Visit Angkor Wat",
             "/plan-your-visit/best-time-to-visit/",
             "Best Time to Visit Angkor Wat",
             "November to February offers cooler temperatures and lower humidity. July and August bring peak crowds and the longest queues."),
        card(f"{b}/Angkor-Wat-Outer-Gallery.avif", "How to Get to Angkor Wat",
             "/plan-your-visit/getting-there-from-siem-reap/",
             "How to Get to Angkor Wat from Siem Reap",
             "Angkor Wat is 5.5 km from Siem Reap. Hire a tuk-tuk, rent a bike, or join a guided tour &mdash; most hotels can arrange transport."),
        card(f"{b}/Angkor-Wat-Reflection-View.avif", "Angkor Wat Official Website",
             "/plan-your-visit/official-website/",
             "Angkor Wat Official Website",
             "Where to buy the official Angkor Pass, check current entry prices, and find visitor rules before you go."),
        card(f"{b}/Angkor-Wat-Central-Tower.avif", "Angkor Wat Entrances",
             "/plan-your-visit/",
             "Angkor Wat Entrances &amp; Entry Points",
             "The main visitor entrance faces the grand causeway on the western side. Ticket checks happen at the outer gate before you cross."),
        card(f"{b}/Angkor-Wat-Accessibility.avif", "Angkor Wat Accessibility",
             "/plan-your-visit/accessibility/",
             "Angkor Wat Accessibility Guide",
             "The ground floor and main causeway are wheelchair accessible. Steep staircases limit upper-level access &mdash; plan ahead for specific needs."),
    ]
    what = [
        card(f"{b}/Angkor-Wat-Central-Tower.avif", "Angkor Wat Towers",
             "/what-to-see/angkor-wat-towers/",
             "Angkor Wat Towers &mdash; The Central Sanctuary",
             "The five iconic towers represent Mount Meru, home of the gods. The central tower rises 65 metres and is the spiritual heart of the complex."),
        card(f"{b}/Jungle-Face-Temple-Gate.avif", "Bayon Temple",
             "/what-to-see/bayon-temple/",
             "Bayon Temple &mdash; The Faces of the Gods",
             "Explore the 54 towers carved with over 200 giant smiling faces &mdash; one of the most photographed sights in all of Southeast Asia."),
        card(f"{b}/Ta-Prohm-Temple-Entrance.avif", "Ta Prohm Temple",
             "/what-to-see/ta-prohm-temple/",
             "Ta Prohm &mdash; The Jungle Temple",
             "Walk through the atmospheric temple where giant strangler figs and silk-cotton trees reclaim ancient stone corridors and collapsed galleries."),
        card(f"{b}/Angkor-Wat-Bas-Relief-Carving.avif", "Angkor Wat Bas-Reliefs",
             "/what-to-see/angkor-wat-bas-reliefs/",
             "The Bas-Reliefs of Angkor Wat",
             "Over 800 metres of intricate carved stone panels depicting Hindu mythology, battle scenes, and everyday Khmer life from the 12th century."),
        card(f"{b}/Angkor-Wat-Sunrise.avif", "Angkor Wat Sunrise",
             "/what-to-see/angkor-wat-sunrise/",
             "Angkor Wat Sunrise",
             "The reflection of Angkor Wat&rsquo;s towers in the moat at dawn is one of the world&rsquo;s great travel experiences. Arrive by 5:00 AM for the best spot."),
        card(f"{b}/Angkor-Wat-Reflection-View.avif", "Angkor Wat Main Temple Highlights",
             "/what-to-see/angkor-wat-main-temple/",
             "Angkor Wat Main Temple &mdash; Top Highlights",
             "A room-by-room guide to the essential sights inside the main complex &mdash; what to see, where to walk, and what most visitors miss."),
    ]
    return plan, what


SITES = [
    {
        "name":        "hagiasofia-guide.com",
        "ssh_key":     SSH_KEY_S2,
        "ssh_host":    SSH_HOST_S2,
        "wp_path":     "/home1/dpskbcmy/public_html/website_204db6f9",
        "homepage_id": 219,
        # Section heading text used to locate each block in post content
        "plan_heading": "Plan Your Visit to Hagia Sophia",
        "what_heading": "What to See at Hagia Sophia",
        "cards": _hagia_cards,   # callable → (plan_cards, what_cards)
    },
    {
        "name":        "angkorwat-guide.com",
        "ssh_key":     SSH_KEY_S2,
        "ssh_host":    SSH_HOST_S2,
        "wp_path":     "/home1/dpskbcmy/public_html/website_angkorwat",
        "homepage_id": 111,
        "plan_heading": "Plan Your Visit to Angkor Wat",
        "what_heading": "What to See at Angkor Wat",
        "cards": _angkorwat_cards,
    },
    # ── Add more sites here following the same pattern ────────────────────────
    # {
    #     "name":        "auschwitz-guide.com",
    #     "ssh_key":     SSH_KEY_S1,
    #     "ssh_host":    SSH_HOST_S1,
    #     "wp_path":     "/home1/kzrmeomy/public_html/website_ce6ca565",
    #     "homepage_id": 210,
    #     "plan_heading": "Plan Your Visit to Auschwitz",
    #     "what_heading": "What to See at Auschwitz",
    #     "cards": _auschwitz_cards,
    # },
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


# ── Section rewriter ──────────────────────────────────────────────────────────
def rewrite_section(content, heading, new_cards):
    """Replace att-highlights-grid block under the given h2 heading."""
    heading_pos = content.find(heading)
    if heading_pos == -1:
        return None, f"heading '{heading}' not found"

    grid_start = content.find('<div class="att-highlights-grid">', heading_pos)
    if grid_start == -1:
        return None, "att-highlights-grid not found after heading"

    grid_content_start = content.index('\n', grid_start) + 1
    section_link       = content.find('<div class="att-section-link">', grid_start)
    if section_link == -1:
        return None, "att-section-link not found — can't determine block end"

    grid_end = section_link
    while content[grid_end - 1] in ' \n':
        grid_end -= 1

    new_block = '\n' + '\n'.join(new_cards) + '\n      '
    fixed = content[:grid_content_start] + new_block + content[grid_end:]
    return fixed, None


# ── Write to DB ───────────────────────────────────────────────────────────────
def write_to_db(host, key, wp, pid, content):
    tmp_html = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp_html.write(content); tmp_html.close()

    php = (
        f'<?php wp_update_post(array('
        f'"ID"=>{pid},'
        f'"post_content"=>file_get_contents("/tmp/uhs_{pid}.html")'
        f')); echo "Updated {pid}\\n";'
    )
    tmp_php = tempfile.NamedTemporaryFile(delete=False, suffix=".php", mode="w", encoding="utf-8")
    tmp_php.write(php); tmp_php.close()

    try:
        scp(key, tmp_html.name, host, f"/tmp/uhs_{pid}.html")
        scp(key, tmp_php.name,  host, f"/tmp/uhs_{pid}.php")
        result = ssh(host, key,
            f"wp eval-file /tmp/uhs_{pid}.php --path={wp} 2>/dev/null; "
            f"rm -f /tmp/uhs_{pid}.html /tmp/uhs_{pid}.php"
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

    plan_cards, what_cards = site["cards"]()

    do_plan = SECTION_FILTER in (None, "plan")
    do_what = SECTION_FILTER in (None, "what")

    print(f"Site: {site['name']}  (post {pid})")
    mode = "DRY-RUN" if DRY_RUN else "APPLY"
    print(f"Mode: {mode}")
    if SECTION_FILTER:
        print(f"Section: {SECTION_FILTER}")
    print()

    content = ssh(host, key,
        f"wp post get {pid} --field=post_content --path={wp} 2>/dev/null"
    )
    if not content:
        print("ERROR: empty content returned")
        sys.exit(1)

    fixed = content

    if do_plan:
        result, err = rewrite_section(fixed, site["plan_heading"], plan_cards)
        if err:
            print(f"  Plan section ERROR: {err}")
        else:
            print(f"  Plan Your Visit: {len(plan_cards)} cards queued")
            fixed = result

    if do_what:
        result, err = rewrite_section(fixed, site["what_heading"], what_cards)
        if err:
            print(f"  What to See section ERROR: {err}")
        else:
            print(f"  What to See: {len(what_cards)} cards queued")
            fixed = result

    if fixed == content:
        print("No changes — sections not found or already up to date.")
        return

    if DRY_RUN:
        print("\nDry-run — no changes written.")
        return

    write_to_db(host, key, wp, pid, fixed)


if __name__ == "__main__":
    main()
