#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse


ROOT = Path(__file__).resolve().parents[2]
INPUT_DIR = ROOT / "input"


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = shlex.split(value.strip())[0] if value.strip() else ""
    return env


def run(cmd: list[str], *, capture: bool = True) -> str:
    env = os.environ.copy()
    env["SSH_AUTH_SOCK"] = ""
    try:
        proc = subprocess.run(
            cmd,
            check=True,
            text=True,
            capture_output=capture,
            env=env,
        )
    except subprocess.CalledProcessError as e:
        if capture and e.stderr:
            print(f"[SSH stderr]\n{e.stderr}", file=sys.stderr)
        if capture and e.stdout:
            print(f"[SSH stdout]\n{e.stdout}", file=sys.stderr)
        raise
    return proc.stdout if capture else ""


def build_ssh_base() -> tuple[list[str], list[str]]:
    host = os.environ.get("WP_SSH_HOST")
    user = os.environ.get("WP_SSH_USER")
    key = os.environ.get("WP_SSH_KEY")
    if not host or not user:
        fail("WP_SSH_HOST and WP_SSH_USER required")

    ssh = ["ssh"]
    scp = ["scp", "-O"]  # -O forces legacy SCP protocol (required on some Bluehost servers)
    if key:
        key_path = str(Path(key).expanduser())
        ssh += ["-i", key_path, "-o", "IdentitiesOnly=yes"]
        scp += ["-i", key_path, "-o", "IdentitiesOnly=yes"]

    common = ["-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
    ssh += common + [f"{user}@{host}"]
    scp += common
    return ssh, scp


def open_control_master(ssh_base: list[str]) -> str:
    """Open a background ControlMaster SSH connection. Returns socket path."""
    import atexit
    socket = f"/tmp/firestorm-cm-{os.getpid()}.sock"
    host = ssh_base[-1]
    master_cmd = (
        ssh_base[:-1]
        + ["-o", "ControlMaster=yes", "-o", f"ControlPath={socket}",
           "-o", "ControlPersist=yes", "-N", "-f"]
        + [host]
    )
    env = os.environ.copy()
    env["SSH_AUTH_SOCK"] = ""
    subprocess.run(master_cmd, check=True, capture_output=True, env=env)

    def _cleanup():
        subprocess.run(
            ssh_base[:-1] + ["-o", f"ControlPath={socket}", "-O", "exit", host],
            capture_output=True, env=env,
        )
    atexit.register(_cleanup)
    return socket


def apply_control_path(
    ssh_base: list[str], scp_base: list[str], socket: str
) -> tuple[list[str], list[str]]:
    """Return new ssh/scp bases that reuse the existing ControlMaster socket."""
    opts = ["-o", f"ControlPath={socket}", "-o", "ControlMaster=no"]
    new_ssh = ssh_base[:-1] + opts + [ssh_base[-1]]
    new_scp = scp_base + opts
    return new_ssh, new_scp


def ssh(ssh_base: list[str], command: str) -> str:
    return run(ssh_base + [command])


def scp_to_remote(scp_base: list[str], local: Path, remote: str) -> None:
    run(scp_base + [str(local), remote], capture=False)


def parse_tickets(path: Path, campaign_prefix: str) -> list[dict[str, str]]:
    tickets: list[dict[str, str]] = []
    for raw in read_text(path).splitlines():
        line = raw.strip()
        if not line or not re.match(r"^T\d+\s+\|", line):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4:
            continue
        _, title, url, provider = parts[:4]
        tickets.append(
            {
                "title": clean_ticket_title(title),
                "url": add_affiliate_params(url, provider, f"{campaign_prefix}-menu"),
                "provider": provider,
            }
        )
    if not tickets:
        fail(f"no tickets parsed from {path}")
    return tickets


def clean_ticket_title(title: str) -> str:
    title = title.replace("+", " + ").replace("&H", "& H")
    title = re.sub(r"\s+", " ", title).strip()
    return title


def add_affiliate_params(url: str, provider: str, campaign: str) -> str:
    parsed = urlparse(url.strip())
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    p = provider.lower()
    if "gyg" in p or "getyourguide" in parsed.netloc:
        query["partner_id"] = "9BAL9K3"
        query["cmp"] = campaign
    elif "tiqets" in p or "tiqets" in parsed.netloc:
        query["partner"] = "thebettervacation"
        query["tq_campaign"] = campaign
    elif "viator" in p or "viator" in parsed.netloc:
        query["pid"] = "P00038490"
        query["mcid"] = "42383"
        query["medium"] = "link"
        query["campaign"] = campaign
    return urlunparse(parsed._replace(query=urlencode(query)))


def first_gyg_url(tickets: list[dict[str, str]], campaign_prefix: str) -> str:
    for ticket in tickets:
        if "getyourguide.com" in ticket["url"]:
            return add_affiliate_params(ticket["url"], "gyg", f"{campaign_prefix}-menu-redbutton")
    fail("no GetYourGuide URL found in tickets.md")


def php_string(text: str) -> str:
    return text.replace("\\", "\\\\").replace("'", "\\'")


def fetch_live_posts(ssh_base: list[str], wp_path: str) -> dict[str, list[dict[str, str]]]:
    php = """<?php
$cats = ['tickets','plan-your-visit','what-to-see'];
$out = [];
foreach ($cats as $cat) {
    $posts = get_posts([
        'post_type' => 'post',
        'post_status' => 'publish',
        'posts_per_page' => -1,
        'category_name' => $cat,
        'orderby' => 'date',
        'order' => 'DESC',
    ]);
    $out[$cat] = array_map(function($p) {
        return ['slug' => $p->post_name, 'title' => get_the_title($p)];
    }, $posts);
}
echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
"""
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
        tmp.write(php)
        local = Path(tmp.name)
    remote = "/tmp/gp-menu-posts.php"
    try:
        _, scp_base = build_ssh_base()
        scp_to_remote(scp_base, local, remote_target(ssh_base, remote))
        out = ssh(ssh_base, f"wp eval-file {shlex.quote(remote)} --path={shlex.quote(wp_path)} && rm -f {shlex.quote(remote)}")
    finally:
        local.unlink(missing_ok=True)
    return json.loads(out.strip())


def remote_target(ssh_base: list[str], remote_path: str) -> str:
    return f"{ssh_base[-1]}:{remote_path}"


def import_logo(ssh_base: list[str], scp_base: list[str], wp_path: str, logo_path: Path, site_name: str) -> str:
    remote_logo = "/tmp/firestorm-logo.png"
    scp_to_remote(scp_base, logo_path, remote_target(ssh_base, remote_logo))
    php = f"""<?php
require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/media.php';
require_once ABSPATH . 'wp-admin/includes/image.php';
$existing = get_posts([
    'post_type' => 'attachment',
    'post_status' => 'inherit',
    'posts_per_page' => 1,
    'meta_query' => [[
        'key' => '_wp_attached_file',
        'value' => 'firestorm-logo.png',
        'compare' => 'LIKE',
    ]],
]);
if ($existing) {{
    $id = $existing[0]->ID;
}} else {{
    $id = media_handle_sideload([
        'name' => 'firestorm-logo.png',
        'tmp_name' => '{php_string(remote_logo)}',
    ], 0, '{php_string(site_name)} Logo');
}}
if (is_wp_error($id)) {{
    fwrite(STDERR, $id->get_error_message());
    exit(1);
}}
echo wp_get_attachment_image_url((int)$id, 'full');
"""
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
        tmp.write(php)
        local = Path(tmp.name)
    remote_php = "/tmp/import-firestorm-logo.php"
    try:
        scp_to_remote(scp_base, local, remote_target(ssh_base, remote_php))
        out = ssh(
            ssh_base,
            f"wp eval-file {shlex.quote(remote_php)} --path={shlex.quote(wp_path)}; rm -f {shlex.quote(remote_php)} {shlex.quote(remote_logo)}",
        )
    finally:
        local.unlink(missing_ok=True)
    return out.strip()


def extract_style_and_script(menu_template: str) -> tuple[str, str]:
    style_match = re.search(r"<style>\s*(.*?)\s*</style>", menu_template, re.S)
    script_match = re.search(r"<script>\s*(.*?)\s*</script>", menu_template, re.S)
    if not style_match or not script_match:
        fail("could not extract style/script from input/menu.txt")
    style = style_match.group(1)
    style += """

    #site-nav .dropdown {
      max-height: calc(100vh - 90px);
      overflow-y: auto;
    }
    #site-nav .drop-item {
      white-space: normal;
      text-wrap: balance;
      min-height: 28px;
      padding: 4px 8px;
    }
    #site-nav .drop-grid {
      gap: 1px;
    }
    #site-nav .mp-links a {
      white-space: normal;
      line-height: 1.35;
    }
    #site-nav .drop-item:not(.drop-hub):not(.drop-buy) {
      font-weight: 400;
    }
    #site-nav .mp-links a:not(.mp-hub):not(.mp-cta) {
      font-weight: 400;
    }
"""
    return style, script_match.group(1)


def nice_site_name(slug: str) -> str:
    return " ".join(part.capitalize() for part in slug.split("-"))


def hub_label(cat: str) -> str:
    return {
        "tickets": "All Tickets &amp; Tours",
        "plan-your-visit": "Plan Your Visit Hub",
        "what-to-see": "What to See Hub",
    }[cat]


def dropdown_label(cat: str) -> str:
    return {
        "tickets": "Tickets &amp; Tours",
        "plan-your-visit": "Plan Your Visit",
        "what-to-see": "What to See",
    }[cat]


def short_title(title: str, site_name: str) -> str:
    t = html.unescape(title)
    t = re.sub(r"\s*[|].*$", "", t)
    t = re.sub(r"\b20\d{2}\b", "", t)
    t = re.sub(r"\(\s*(?:\w+\s+)?Guide\s*\)", "", t, flags=re.IGNORECASE)  # "(2025 Guide)" → ""
    t = re.sub(r"\(\s*\)", "", t)          # remove remaining empty parens
    t = re.sub(r"\s+—\s+.*$", "", t)
    t = re.sub(r"\s*:.*$", "", t)          # strip ": subtitle" after colon
    # Strip site_name only from the START (e.g. "Stonehenge Tickets → Tickets")
    # NOT mid-title (e.g. "Windsor, Stonehenge & Bath" must stay intact)
    t = re.sub(rf"^{re.escape(site_name)}\s*[:\-–—,]?\s*", "", t).strip(" :,-")
    t = re.sub(r"\s+", " ", t).strip()
    return t or html.unescape(title)


_CAT_TO_GROUPINGS_KEY = {
    "tickets": "tickets-tours",
    "plan-your-visit": "plan-your-visit",
    "what-to-see": "what-to-see",
}

_BUY_GROUP_ORDER = ["entry", "guided", "combo", "passes"]
_BUY_GROUP_LABELS = {
    "entry":  "Entry & Audio",
    "guided": "Guided Tours",
    "combo":  "Combo Tickets",
    "passes": "City Passes",
}


def _classify_ticket(title: str) -> str:
    t = title.lower()
    if "pass" in t:
        return "passes"
    if "combo" in t:
        return "combo"
    if any(w in t for w in ("guided", "private", "small group")):
        return "guided"
    if any(w in t for w in ("tour", "trip", "half-day", "full-day", "transfer", "cruise")) and "audio" not in t:
        return "guided"
    # Only classify as entry if it explicitly says so
    if any(w in t for w in ("entry", "admission", "skip the line", "free", "audio")):
        return "entry"
    # Multi-destination combos without "tour"/"trip" → still guided
    return "guided"


def render_ticket_items(tickets: list[dict[str, str]], buy_groupings: list | None = None) -> tuple[str, str]:
    desktop_parts: list[str] = []
    mobile_parts: list[str] = []

    def _append_ticket(ticket: dict[str, str]) -> None:
        escaped_title = html.escape(ticket["title"])
        url = html.escape(ticket["url"], quote=True)
        desktop_parts.append(
            f'<a class="drop-item drop-buy" href="{url}" role="menuitem" rel="noopener nofollow sponsored" target="_blank">'
            f'<span class="drop-buy-name">{escaped_title}</span></a>'
        )
        mobile_parts.append(
            f'<a href="{url}" rel="noopener nofollow sponsored" target="_blank">{escaped_title}</a>'
        )

    if buy_groupings:
        for group in buy_groupings:
            label = html.escape(group["label"])
            entries = group.get("tickets") or [{"index": i} for i in group.get("ticket_indexes", [])]
            group_items = []
            for entry in entries:
                idx = entry["index"]
                if 1 <= idx <= len(tickets):
                    t = dict(tickets[idx - 1])
                    if "name" in entry:
                        t["title"] = entry["name"]
                    group_items.append(t)
            if not group_items:
                continue
            desktop_parts.append(f'<div class="drop-label">{label}</div>')
            mobile_parts.append(f'<div class="mp-section-label">{label}</div>')
            for ticket in group_items:
                _append_ticket(ticket)
    else:
        classified: dict[str, list] = {gk: [] for gk in _BUY_GROUP_ORDER}
        for ticket in tickets:
            gk = _classify_ticket(ticket["title"])
            classified[gk].append(ticket)
        for gk in _BUY_GROUP_ORDER:
            items = classified[gk]
            if not items:
                continue
            label = _BUY_GROUP_LABELS[gk]
            desktop_parts.append(f'<div class="drop-label">{label}</div>')
            mobile_parts.append(f'<div class="mp-section-label">{label}</div>')
            is_combo = gk == "combo"
            for ticket in items:
                display = ticket["title"]
                if is_combo and not display.startswith("+"):
                    display = "+ " + display
                escaped_title = html.escape(display)
                url = html.escape(ticket["url"], quote=True)
                desktop_parts.append(
                    f'<a class="drop-item drop-buy" href="{url}" role="menuitem" rel="noopener nofollow sponsored" target="_blank">'
                    f'<span class="drop-buy-name">{escaped_title}</span></a>'
                )
                mobile_parts.append(
                    f'<a href="{url}" rel="noopener nofollow sponsored" target="_blank">{escaped_title}</a>'
                )

    return "\n              ".join(desktop_parts), "\n          ".join(mobile_parts)


def render_internal_items(
    posts: list[dict[str, str]],
    domain: str,
    category: str,
    site_name: str,
    groupings: dict | None = None,
) -> tuple[str, str, str]:
    hub_url = f"/{category}/"
    groupings_key = _CAT_TO_GROUPINGS_KEY.get(category)
    section_config = (groupings or {}).get(groupings_key, {}) if groupings_key else {}
    cat_groups = section_config.get("groups")
    cols_override = section_config.get("cols")
    if cols_override:
        cols = f" {cols_override}"
    elif cat_groups:
        cols = " cols-2"
    else:
        cols = " cols-3" if len(posts) > 15 else " cols-2"
    desktop: list[str] = [f'<a class="drop-item drop-hub" href="{hub_url}" role="menuitem">{hub_label(category)}</a>']
    mobile: list[str] = [f'<a href="{hub_url}" class="mp-hub">{hub_label(category)}</a>']

    def _append_post(post: dict[str, str]) -> None:
        title = html.escape(short_title(post["title"], site_name))
        url = html.escape(f"/{category}/{post['slug']}/", quote=True)
        desktop.append(f'<a class="drop-item" href="{url}" role="menuitem">{title}</a>')
        mobile.append(f'<a href="{url}">{title}</a>')

    if cat_groups:
        slug_to_post = {p["slug"]: p for p in posts}
        matched: set[str] = set()
        for group in cat_groups:
            entries = group["slugs"]
            group_items: list[tuple[dict, str | None]] = []
            for entry in entries:
                if isinstance(entry, str):
                    slug, name_override = entry, None
                else:
                    slug, name_override = entry["slug"], entry.get("name")
                if slug in slug_to_post:
                    group_items.append((slug_to_post[slug], name_override))
            if not group_items:
                continue
            label = html.escape(group["label"])
            if label:
                desktop.append(f'<div class="drop-label">{label}</div>')
                mobile.append(f'<div class="mp-section-label">{label}</div>')
            for post, name_override in group_items:
                matched.add(post["slug"])
                if name_override:
                    title = html.escape(name_override)
                    url = html.escape(f"/{category}/{post['slug']}/", quote=True)
                    desktop.append(f'<a class="drop-item" href="{url}" role="menuitem">{title}</a>')
                    mobile.append(f'<a href="{url}">{title}</a>')
                else:
                    _append_post(post)
        pass  # show only what groupings specify — no "More" fallback
    else:
        desktop.append('<div class="drop-label">Published Articles</div>')
        mobile.append('<div class="mp-section-label">Published Articles</div>')
        for post in posts:
            _append_post(post)

    return cols, "\n              ".join(desktop), "\n          ".join(mobile)


def render_menu(
    domain: str,
    site_slug: str,
    site_name: str,
    logo_url: str,
    tickets: list[dict[str, str]],
    posts_by_cat: dict[str, list[dict[str, str]]],
    style: str,
    script: str,
    red_button_url: str,
    groupings: dict | None = None,
) -> str:
    buy_config = (groupings or {}).get("buy-tickets", {})
    buy_groupings = buy_config.get("groups")
    buy_cols = buy_config.get("cols", "cols-3")
    desktop_buy, mobile_buy = render_ticket_items(tickets, buy_groupings)
    tickets_cols, tickets_desktop, tickets_mobile = render_internal_items(posts_by_cat["tickets"], domain, "tickets", site_name, groupings)
    pyv_cols, pyv_desktop, pyv_mobile = render_internal_items(posts_by_cat["plan-your-visit"], domain, "plan-your-visit", site_name, groupings)
    wts_cols, wts_desktop, wts_mobile = render_internal_items(posts_by_cat["what-to-see"], domain, "what-to-see", site_name, groupings)

    return f"""<header id="site-nav" aria-label="Primary navigation">
  <style>
{style}
  </style>

  <div class="wrap">
    <a class="brand" href="/" aria-label="{html.escape(site_name)} Guide home">
      <img src="{html.escape(logo_url, quote=True)}" width="230" height="70" alt="{html.escape(site_name)} Guide" loading="eager" fetchpriority="high" decoding="async"/>
    </a>

    <nav aria-label="Main menu">
      <ul class="att-nav-menu">
        <li class="att-nav-item">
          <button class="menu-btn" type="button" aria-haspopup="true" aria-expanded="false">
            Buy Tickets
            <svg class="chev" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
          <div class="dropdown" role="menu" aria-label="Buy Tickets">
            <div class="drop-grid {buy_cols}">
              {desktop_buy}
            </div>
          </div>
        </li>

        <li class="att-nav-item">
          <button class="menu-btn" type="button" aria-haspopup="true" aria-expanded="false">
            Tickets &amp; Tours
            <svg class="chev" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
          <div class="dropdown" role="menu" aria-label="Tickets and Tours">
            <div class="drop-grid{tickets_cols}">
              {tickets_desktop}
            </div>
          </div>
        </li>

        <li class="att-nav-item">
          <button class="menu-btn" type="button" aria-haspopup="true" aria-expanded="false">
            Plan Your Visit
            <svg class="chev" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
          <div class="dropdown" role="menu" aria-label="Plan Your Visit">
            <div class="drop-grid{pyv_cols}">
              {pyv_desktop}
            </div>
          </div>
        </li>

        <li class="att-nav-item">
          <button class="menu-btn" type="button" aria-haspopup="true" aria-expanded="false">
            What to See
            <svg class="chev" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
          <div class="dropdown" role="menu" aria-label="What to See">
            <div class="drop-grid{wts_cols}">
              {wts_desktop}
            </div>
          </div>
        </li>
      </ul>
    </nav>

    <div class="right">
      <button class="search-icon js-open-search" type="button" aria-label="Open search" aria-haspopup="dialog" aria-controls="search-overlay" aria-expanded="false">
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
      </button>
      <a class="cta" href="{html.escape(red_button_url, quote=True)}" rel="noopener nofollow sponsored" target="_blank" aria-label="Book Now">Book Now</a>
      <button class="hamburger" type="button" aria-label="Open menu" aria-expanded="false" aria-controls="mobile-panel">
        <svg viewBox="0 0 302 302" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
          <rect y="36" width="302" height="30"/><rect y="136" width="302" height="30"/><rect y="236" width="302" height="30"/>
        </svg>
      </button>
    </div>
  </div>

  <div class="mobile-panel-overlay" id="mp-overlay" aria-hidden="true"></div>

  <aside class="mobile-panel" id="mobile-panel" aria-label="Mobile menu" aria-hidden="true">
    <div class="mp-head">
      <div style="font-weight:900;letter-spacing:-0.02em;font-size:1.05rem;">Menu</div>
      <div style="display:inline-flex;align-items:center;gap:16px;">
        <button class="search-icon js-open-search" type="button" aria-label="Open search" aria-haspopup="dialog" aria-controls="search-overlay" aria-expanded="false" style="width:auto;height:auto;border-radius:0;background:transparent;border:0;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;padding:0;transition:transform 160ms ease;">
          <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" style="display:block;fill:none;stroke:#0b1220;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round;">
            <circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>
          </svg>
        </button>
        <button class="mp-close" type="button" aria-label="Close menu">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12"/><path d="M18 6 6 18"/></svg>
        </button>
      </div>
    </div>
    <div class="mp-body">
      <details class="mp-group">
        <summary><span>Buy Tickets</span><svg class="caret" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="mp-links">
          {mobile_buy}
        </div>
      </details>

      <details class="mp-group">
        <summary><span>Tickets &amp; Tours</span><svg class="caret" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="mp-links">
          {tickets_mobile}
        </div>
      </details>

      <details class="mp-group">
        <summary><span>Plan Your Visit</span><svg class="caret" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="mp-links">
          {pyv_mobile}
        </div>
      </details>

      <details class="mp-group">
        <summary><span>What to See</span><svg class="caret" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m6 9 6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="mp-links">
          {wts_mobile}
        </div>
      </details>
    </div>

    <div class="mp-contact">
      <a class="mp-cta" href="{html.escape(red_button_url, quote=True)}" rel="noopener nofollow sponsored" target="_blank">Book Now</a>
    </div>
  </aside>

  <div id="search-overlay" class="search-overlay" role="dialog" aria-modal="true" aria-label="Search">
    <div class="search-panel" role="document">
      <div class="search-body">
        <div class="search-head">
          <form class="search-field" role="search" action="/" method="get" aria-label="Site search">
            <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input class="search-input" type="search" name="s" placeholder="Search {html.escape(site_name)} tickets, tours, tips..." autocomplete="off"/>
          </form>
          <button class="search-close" type="button" aria-label="Close search">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>
          </button>
        </div>
        <p class="search-hint">Press <b>Esc</b> to close.</p>
      </div>
    </div>
  </div>

  <script>
{script}
  </script>
</header>
"""


def render_footer(footer_template: str, domain: str) -> str:
    out = footer_template
    out = out.replace("https://auschwitz-guide.com/about-us/", f"https://{domain}/about-us/")
    out = out.replace("https://auschwitz-guide.com/contact-us/", f"https://{domain}/contact-us/")
    return out


def deploy_gp_elements(
    ssh_base: list[str],
    scp_base: list[str],
    wp_path: str,
    menu_html: str,
    footer_html: str,
) -> str:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        menu_local = tmp / "menu.html"
        footer_local = tmp / "footer.html"
        menu_php = tmp / "deploy.php"
        menu_local.write_text(menu_html, encoding="utf-8")
        footer_local.write_text(footer_html, encoding="utf-8")
        menu_php.write_text(
            """<?php
function upsert_firestorm_gp_element($slug, $title, $hook, $priority, $content_path) {
    $existing = get_posts(['post_type' => 'gp_elements', 'name' => $slug, 'post_status' => 'any', 'numberposts' => 1]);
    $content = file_get_contents($content_path);
    if ($content === false) {
        fwrite(STDERR, "Could not read " . $content_path . PHP_EOL);
        exit(1);
    }
    $id = $existing ? $existing[0]->ID : wp_insert_post([
        'post_type' => 'gp_elements',
        'post_title' => $title,
        'post_name' => $slug,
        'post_status' => 'publish',
    ]);
    if (is_wp_error($id)) {
        fwrite(STDERR, $id->get_error_message() . PHP_EOL);
        exit(1);
    }
    $old = get_post_meta($id, '_generate_element_content', true);
    file_put_contents('/tmp/' . $slug . '-backup-' . date('Ymd-His') . '.html', (string) $old);
    wp_update_post(['ID' => $id, 'post_title' => $title, 'post_status' => 'publish']);
    update_post_meta($id, '_generate_element_type', 'hook');
    update_post_meta($id, '_generate_hook', $hook);
    update_post_meta($id, '_generate_hook_priority', (string) $priority);
    update_post_meta($id, '_generate_element_display_conditions', [['rule' => 'general:site', 'object' => '0']]);
    update_post_meta($id, '_generate_element_content', $content);
    echo strtoupper($slug) . "_ID:$id\n";
}

upsert_firestorm_gp_element('menu', 'Menu', 'generate_before_header', 10, '/tmp/firestorm-menu.html');
upsert_firestorm_gp_element('footer', 'Footer', 'generate_footer', 10, '/tmp/firestorm-footer.html');
""",
            encoding="utf-8",
        )
        scp_to_remote(scp_base, menu_local, remote_target(ssh_base, "/tmp/firestorm-menu.html"))
        scp_to_remote(scp_base, footer_local, remote_target(ssh_base, "/tmp/firestorm-footer.html"))
        scp_to_remote(scp_base, menu_php, remote_target(ssh_base, "/tmp/firestorm-deploy-gp.php"))
        import time; time.sleep(3)
        return ssh(
            ssh_base,
            "wp eval-file /tmp/firestorm-deploy-gp.php --path="
            + shlex.quote(wp_path)
            + " && "
            + "wp post list --post_type=gp_elements --post_status=publish --fields=ID,post_name,post_title --format=table --path="
            + shlex.quote(wp_path)
            + " && rm -f /tmp/firestorm-menu.html /tmp/firestorm-footer.html /tmp/firestorm-deploy-gp.php",
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site-slug", required=True)
    parser.add_argument("--wp-path", required=True)
    args = parser.parse_args()

    site_slug = args.site_slug
    wp_path = args.wp_path.rstrip("/")
    site_dir = INPUT_DIR / site_slug
    if not site_dir.exists():
        fail(f"site dir not found: {site_dir}")

    root_env = load_env(ROOT / ".env")
    site_env = load_env(site_dir / ".env")

    # Merge root env then site env into os.environ
    for k, v in {**root_env, **site_env}.items():
        os.environ.setdefault(k, v)
    # Apply WP_SERVER=2 routing (override SSH credentials if site uses server 2)
    if site_env.get("WP_SERVER") == "2" or os.environ.get("WP_SERVER") == "2":
        for suffix, base in [("HOST", "WP_SSH_HOST"), ("USER", "WP_SSH_USER"), ("KEY", "WP_SSH_KEY")]:
            v2 = os.environ.get(f"WP_SSH_{suffix}2")
            if v2:
                os.environ[base] = v2

    site_url = site_env.get("WP_SITE_URL") or os.environ.get("WP_SITE_URL")
    if not site_url:
        fail(f"WP_SITE_URL missing in {site_dir / '.env'}")

    domain = urlparse(site_url).netloc
    campaign_prefix = site_env.get("CAMPAIGN_PREFIX") or site_slug
    site_name = nice_site_name(site_slug)

    menu_template = read_text(INPUT_DIR / "menu.txt")
    footer_template = read_text(INPUT_DIR / "footer.txt")
    tickets = parse_tickets(site_dir / "tickets.md", campaign_prefix)

    groupings_path = site_dir / "menu_groupings.json"
    groupings = json.loads(groupings_path.read_text(encoding="utf-8")) if groupings_path.exists() else None

    ssh_base, scp_base = build_ssh_base()

    # Pre-flight: verify SSH is reachable before doing any work
    host = os.environ.get("WP_SSH_HOST", "?")
    try:
        subprocess.run(
            ssh_base[:-1] + ["-o", "ConnectTimeout=10"] + [ssh_base[-1]] + ["true"],
            check=True, capture_output=True,
            env={**os.environ, "SSH_AUTH_SOCK": ""},
        )
    except subprocess.CalledProcessError:
        fail(
            f"Cannot reach SSH host {host} — connection refused or timed out.\n"
            f"  Check that the server is up, port 22 is open, and WP_SSH_HOST/WP_SSH_KEY are correct."
        )

    # Open a single ControlMaster — all SCPs and SSH calls reuse it to avoid fail2ban
    cm_socket = open_control_master(ssh_base)
    ssh_base, scp_base = apply_control_path(ssh_base, scp_base, cm_socket)

    logo_path = site_dir / "images" / "logo.png"
    if not logo_path.exists():
        fail(f"logo not found: {logo_path}")

    posts_by_cat = fetch_live_posts(ssh_base, wp_path)
    logo_url = import_logo(ssh_base, scp_base, wp_path, logo_path, site_name)
    style, script = extract_style_and_script(menu_template)
    red_button_url = site_env.get("RED_BUTTON_URL") or first_gyg_url(tickets, campaign_prefix)

    menu_html = render_menu(domain, site_slug, site_name, logo_url, tickets, posts_by_cat, style, script, red_button_url, groupings)
    footer_html = render_footer(footer_template, domain)

    (site_dir / "menu.txt").write_text(menu_html, encoding="utf-8")
    (site_dir / "footer.txt").write_text(footer_html, encoding="utf-8")

    result = deploy_gp_elements(ssh_base, scp_base, wp_path, menu_html, footer_html)
    print(f"Generated: {site_dir / 'menu.txt'}")
    print(f"Generated: {site_dir / 'footer.txt'}")
    print(result.strip())


if __name__ == "__main__":
    main()
