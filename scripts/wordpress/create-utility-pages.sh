#!/usr/bin/env zsh
set -euo pipefail

# ── create-utility-pages.sh ───────────────────────────────────────────────────
# Creates About Us, Contact Us pages, Footer GP Element, and Primary Menu
# for a given site using templates + site-meta.json.
#
# Usage: ./scripts/base/create-utility-pages.sh <site-slug>
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { echo "Usage: $0 <site-slug>"; exit 1; }

SITE_SLUG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# Load root .env then site .env
[[ -f "$SCRIPT_DIR/.env" ]]                          && { set -a; source "$SCRIPT_DIR/.env"; set +a; }
[[ -f "$SCRIPT_DIR/input/$SITE_SLUG/.env" ]]         && { set -a; source "$SCRIPT_DIR/input/$SITE_SLUG/.env"; set +a; }

META_FILE="$SCRIPT_DIR/input/$SITE_SLUG/site-meta.json"
[[ -f "$META_FILE" ]] || { echo "ERROR: $META_FILE not found."; exit 1; }
[[ -n "${WP_PATH:-}" ]] || { echo "ERROR: WP_PATH not set in input/$SITE_SLUG/.env"; exit 1; }

# ── SSH setup ─────────────────────────────────────────────────────────────────
if [[ "${WP_SERVER:-}" == "2" ]]; then
  _SSH_KEY="${WP_SSH_KEY2:-$HOME/.ssh/id_rsa_bluehost2}"
  _SSH_USER="${WP_SSH_USER2:-dpskbcmy}"
  _SSH_HOST="${WP_SSH_HOST2:-50.6.155.174}"
  _SSH_AUTH_SOCK=""
else
  _SSH_KEY="$HOME/.ssh/id_rsa_bluehost_old"
  _SSH_USER="${WP_SSH_USER:-kzrmeomy}"
  _SSH_HOST="${WP_SSH_HOST:-50.6.109.30}"
  _SSH_AUTH_SOCK="SSH_AUTH_SOCK="
fi

_SSH_KEY="${_SSH_KEY/#\~/$HOME}"
SSH_CMD=(env ${_SSH_AUTH_SOCK} ssh -i "$_SSH_KEY" -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15)

echo "════════════════════════════════════════════════════════════════════════════"
echo "  create-utility-pages — $SITE_SLUG"
echo "  Server: ${_SSH_USER}@${_SSH_HOST}  WP_PATH: $WP_PATH"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Render HTML from Python using site-meta.json ──────────────────────────────
ABOUT_HTML=$(python3 - "$META_FILE" << 'PYEOF'
import json, sys

m = json.load(open(sys.argv[1]))
s  = m["site_name"];  u = m["site_url"];  d = m["site_domain"]
an = m["attraction_name"]; ash = m["attraction_short"]
cover_bullets = "\n".join(f"        <li>{b}</li>" for b in m["what_we_cover"])
disc = m["disclaimer"]

print(f"""<!-- wp:html -->
<div class="tbv-about-fluid">
  <style>
    .tbv-about-fluid{{max-width:1300px;margin:0 auto;padding:18px 0;font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial;color:inherit}}
    .tbv-about-fluid *{{box-sizing:border-box}}
    .tbv-about-fluid a{{color:inherit;text-decoration:underline;text-underline-offset:3px}}
    .tbv-about-fluid a:hover{{opacity:.85}}
    .tbv-about-fluid .hero{{padding:18px 0 12px;border-bottom:1px solid rgba(0,0,0,.10);margin-bottom:18px}}
    .tbv-about-fluid h1{{margin:0 0 8px;font-size:clamp(26px,3.2vw,40px);line-height:1.15;letter-spacing:-.01em}}
    .tbv-about-fluid .sub{{margin:0;opacity:.78;max-width:78ch;line-height:1.6}}
    .tbv-about-fluid .layout{{display:grid;gap:28px;grid-template-columns:1.2fr .8fr;align-items:start}}
    @media(max-width:920px){{.tbv-about-fluid .layout{{grid-template-columns:1fr}}}}
    .tbv-about-fluid .section-title{{margin:0 0 8px;font-size:18px;letter-spacing:-.01em}}
    .tbv-about-fluid .section-sub{{margin:0 0 14px;opacity:.75;max-width:82ch}}
    .tbv-about-fluid .p{{margin:0 0 12px;opacity:.92;max-width:82ch;line-height:1.65}}
    .tbv-about-fluid .meta{{padding-left:18px;border-left:1px solid rgba(0,0,0,.10)}}
    @media(max-width:920px){{.tbv-about-fluid .meta{{padding-left:0;border-left:none;border-top:1px solid rgba(0,0,0,.10);padding-top:18px}}}}
    .tbv-about-fluid .kv{{display:grid;gap:12px;margin:0;padding:0;list-style:none}}
    .tbv-about-fluid .k{{font-size:13px;opacity:.7;margin-bottom:3px}}
    .tbv-about-fluid .v{{font-weight:750;line-height:1.35}}
    .tbv-about-fluid .small{{font-size:13px;opacity:.78;line-height:1.55}}
    .tbv-about-fluid .hr{{margin:18px 0;border-top:1px solid rgba(0,0,0,.10)}}
    .tbv-about-fluid .list{{margin:8px 0 0;padding-left:18px;opacity:.92;line-height:1.7;max-width:84ch}}
    .tbv-about-fluid .callout{{margin-top:16px;padding:14px;border:1px solid rgba(0,0,0,.10);background:rgba(0,0,0,.03);border-radius:16px}}
  </style>

  <header class="hero">
    <h1>About {s}</h1>
    <p class="sub">
      <a href="{u}/" rel="noopener">{s}</a> is an independent visitor-planning website dedicated to helping
      travellers prepare for an unforgettable visit to <strong>{an}</strong>.
      We focus on practical details like <strong>{ash} tickets</strong>, <strong>guided tours</strong>,
      <strong>opening hours</strong>, <strong>getting there</strong>, and what to expect on the day.
    </p>
  </header>

  <div class="layout">
    <section aria-labelledby="tbv-about-title">
      <h2 class="section-title" id="tbv-about-title">Who we are</h2>
      <p class="section-sub">{s} is published by <strong>Firestorm Internet</strong>.</p>
      <p class="p">Firestorm Internet was started by <strong>Jamshed V Rajan</strong> in 2016 with one simple goal:
        help travelers feel confident before they arrive — especially at places where planning, timing, and local logistics matter.</p>
      <div class="hr"></div>
      <h2 class="section-title">What we cover on {s}</h2>
      <p class="p">Our {ash} visitor guides prioritize the details people usually need before planning a visit:</p>
      <ul class="list">
{cover_bullets}
      </ul>
      <div class="hr"></div>
      <h2 class="section-title">Our editorial standard: accuracy first</h2>
      <p class="p">Our editorial standard is <strong>accuracy first</strong>. Each guide is produced using structured research,
        verification through official channels, and reliable local sources where possible. We review our guides regularly to keep information current.</p>
      <div class="callout" role="note">
        <strong>Corrections:</strong> If you spot an error, tell us.
        Email us at <a href="mailto:jamshed@firestorm-internet.com">jamshed@firestorm-internet.com</a>.
      </div>
      <div class="hr"></div>
      <h2 class="section-title">Transparency</h2>
      <p class="p">Some pages may include affiliate links or sponsored content. When they do, we disclose it clearly.
        We maintain editorial independence so recommendations stay honest and focused on what helps visitors most.</p>
    </section>
    <aside class="meta" aria-label="Company and contact details">
      <h2 class="section-title">Company details</h2>
      <ul class="kv">
        <li>
          <div class="k">Publisher</div>
          <div class="v"><a href="https://firestorm-internet.com/" target="_blank" rel="noopener">Firestorm Internet</a></div>
          <div class="small">Based in <strong>Chennai, India</strong> &bull; Founded 2016</div>
        </li>
        <li>
          <div class="k">Leadership</div>
          <div class="v">Jamshed V Rajan &mdash; CEO</div>
          <div class="small"><a href="https://www.linkedin.com/in/jamshedvrajan/" target="_blank" rel="noopener">LinkedIn</a></div>
          <div class="v" style="margin-top:10px;">Rekha Rajan &mdash; COO</div>
          <div class="small"><a href="https://www.linkedin.com/in/rekharajan1/" target="_blank" rel="noopener">LinkedIn</a></div>
        </li>
        <li>
          <div class="k">Email</div>
          <div class="v"><a href="mailto:jamshed@firestorm-internet.com">jamshed@firestorm-internet.com</a></div>
          <div class="small">For questions, corrections, partnerships, or media inquiries</div>
        </li>
        <li>
          <div class="k">GSTIN</div>
          <div class="v">33ADXPJ2389R1ZH</div>
        </li>
        <li>
          <div class="k">Important note</div>
          <div class="small">{disc}</div>
        </li>
      </ul>
    </aside>
  </div>

  <script type="application/ld+json">
  {{
    "@context":"https://schema.org",
    "@graph":[
      {{"@type":"WebSite","@id":"{u}/#website","name":"{s}","url":"{u}/","publisher":{{"@id":"{u}/#org"}}}},
      {{"@type":"Organization","@id":"{u}/#org","name":"Firestorm Internet","url":"https://firestorm-internet.com/","foundingDate":"2016","taxID":"33ADXPJ2389R1ZH","address":{{"@type":"PostalAddress","addressLocality":"Chennai","addressCountry":"IN"}},"email":"jamshed@firestorm-internet.com","founder":{{"@type":"Person","name":"Jamshed V Rajan","jobTitle":"Founder & CEO","sameAs":["https://www.linkedin.com/in/jamshedvrajan/"]}}}},
      {{"@type":"AboutPage","@id":"{u}/about-us/#aboutpage","name":"About {s}","url":"{u}/about-us/","isPartOf":{{"@id":"{u}/#website"}},"about":{{"@id":"{u}/#org"}}}}
    ]
  }}
  </script>
</div>
<!-- /wp:html -->""")
PYEOF
)

CONTACT_HTML=$(python3 - "$META_FILE" << 'PYEOF'
import json, sys

m = json.load(open(sys.argv[1]))
s  = m["site_name"];  u = m["site_url"];  d = m["site_domain"]
ash = m["attraction_short"]
tagline = m["contact_tagline"]
disc = m["disclaimer"]
pills = "\n".join(f'      <span class="pill">{p}</span>' for p in m["contact_pills"])

print(f"""<!-- wp:html -->
<div class="tbv-contact-fluid">
  <style>
    .tbv-contact-fluid{{max-width:1100px;margin:0 auto;padding:18px 0;font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial;color:inherit}}
    .tbv-contact-fluid *{{box-sizing:border-box}}
    .tbv-contact-fluid a{{color:inherit;text-decoration:underline;text-underline-offset:3px}}
    .tbv-contact-fluid .hero{{padding:18px 0 10px;border-bottom:1px solid rgba(0,0,0,.10);margin-bottom:18px}}
    .tbv-contact-fluid h1{{margin:0 0 8px;font-size:clamp(26px,3.2vw,40px);line-height:1.15;letter-spacing:-.01em}}
    .tbv-contact-fluid .sub{{margin:0;opacity:.78;max-width:72ch}}
    .tbv-contact-fluid .pillrow{{display:flex;flex-wrap:wrap;gap:10px;margin-top:12px}}
    .tbv-contact-fluid .pill{{display:inline-flex;align-items:center;padding:7px 12px;border-radius:999px;background:rgba(0,0,0,.04);border:1px solid rgba(0,0,0,.08);font-size:13px;opacity:.85;text-decoration:none}}
    .tbv-contact-fluid .layout{{display:grid;gap:28px;grid-template-columns:1.25fr .75fr;align-items:start}}
    @media(max-width:920px){{.tbv-contact-fluid .layout{{grid-template-columns:1fr}}}}
    .tbv-contact-fluid .section-title{{margin:0 0 8px;font-size:18px;letter-spacing:-.01em}}
    .tbv-contact-fluid .section-sub{{margin:0 0 14px;opacity:.75}}
    .tbv-contact-fluid .note{{font-size:12px;opacity:.72;margin-top:10px}}
    .tbv-contact-fluid .meta{{padding-left:18px;border-left:1px solid rgba(0,0,0,.10)}}
    @media(max-width:920px){{.tbv-contact-fluid .meta{{padding-left:0;border-left:none;border-top:1px solid rgba(0,0,0,.10);padding-top:18px}}}}
    .tbv-contact-fluid .kv{{display:grid;gap:12px;margin:0;padding:0;list-style:none}}
    .tbv-contact-fluid .k{{font-size:13px;opacity:.7;margin-bottom:3px}}
    .tbv-contact-fluid .v{{font-weight:700;line-height:1.35}}
    .tbv-contact-fluid .small{{font-size:13px;opacity:.75}}
    .tbv-contact-fluid .social{{display:flex;flex-wrap:wrap;gap:10px;margin-top:10px}}
    .tbv-contact-fluid .social a{{text-decoration:none;padding:7px 12px;border-radius:999px;background:rgba(0,0,0,.04);border:1px solid rgba(0,0,0,.08);font-size:13px}}
    .tbv-contact-fluid .footer{{margin-top:18px;padding-top:14px;border-top:1px solid rgba(0,0,0,.10);font-size:13px;opacity:.8}}
  </style>

  <header class="hero">
    <h1>Contact Us</h1>
    <p class="sub">{tagline}</p>
    <div class="pillrow">
{pills}
    </div>
  </header>

  <div class="layout">
    <section aria-labelledby="tbv-form-title">
      <h2 class="section-title" id="tbv-form-title">Send us a message</h2>
      <p class="section-sub">Share your plan, query, doubt, or concern &mdash; we&rsquo;ll get back to you as soon as possible.</p>
      [fluentform id="1"]
      <div class="note">By submitting this form, you agree that we may contact you back regarding your inquiry.</div>
    </section>
    <aside class="meta" aria-label="Contact details">
      <h2 class="section-title">Contact details</h2>
      <ul class="kv">
        <li>
          <div class="k">WhatsApp us</div>
          <div class="v"><a href="https://wa.me/917358808488" target="_blank" rel="noopener">+91-7358808488</a></div>
          <div class="small">Fastest for quick questions during working hours</div>
        </li>
        <li>
          <div class="k">Call us</div>
          <div class="v"><a href="tel:+917358808488">+91-7358808488</a></div>
          <div class="small">Mon&ndash;Fri: 10:00&ndash;18:00 &bull; Sat: 10:00&ndash;13:00 (IST) &bull; Sun: Closed</div>
        </li>
        <li>
          <div class="k">Email</div>
          <div class="v"><a href="mailto:jamshed@firestorm-internet.com">jamshed@firestorm-internet.com</a></div>
        </li>
        <li>
          <div class="k">Office address</div>
          <div class="v">2nd floor, 189, Work EZ &ndash; The Ark, Rajiv Gandhi Salai, OMR, Sholinganallur, Chennai, India.</div>
        </li>
        <li>
          <div class="k">Company</div>
          <div class="v"><strong>Firestorm Internet</strong> &bull; <a href="https://firestorm-internet.com/" target="_blank" rel="noopener">firestorm-internet.com</a></div>
        </li>
        <li>
          <div class="k">Social</div>
          <div class="social">
            <a href="https://www.facebook.com/thebettervacation" rel="noopener" target="_blank">Facebook</a>
            <a href="https://www.linkedin.com/company/thebettervacation/" rel="noopener" target="_blank">LinkedIn</a>
            <a href="https://www.instagram.com/thebettervacation/" rel="noopener" target="_blank">Instagram</a>
            <a href="https://twitter.com/bettervacation_" rel="noopener" target="_blank">X</a>
            <a href="https://www.youtube.com/channel/UCmSy2vAcpu2ULN0tHV6aA1A" rel="noopener" target="_blank">YouTube</a>
          </div>
        </li>
      </ul>
    </aside>
  </div>

  <script type="application/ld+json">
  {{
    "@context":"https://schema.org",
    "@type":"ContactPage",
    "name":"Contact Us",
    "url":"{u}/contact-us/",
    "mainEntity":{{
      "@type":"LocalBusiness",
      "name":"Firestorm Internet",
      "url":"https://firestorm-internet.com/",
      "telephone":"+91-7358808488",
      "email":"jamshed@firestorm-internet.com",
      "address":{{"@type":"PostalAddress","streetAddress":"2nd floor, 189, Work EZ - The Ark, Rajiv Gandhi Salai, OMR, Sholinganallur","addressLocality":"Chennai","addressCountry":"IN"}},
      "openingHoursSpecification":[
        {{"@type":"OpeningHoursSpecification","dayOfWeek":["Monday","Tuesday","Wednesday","Thursday","Friday"],"opens":"10:00","closes":"18:00"}},
        {{"@type":"OpeningHoursSpecification","dayOfWeek":"Saturday","opens":"10:00","closes":"13:00"}}
      ]
    }}
  }}
  </script>

  <div class="footer">
    <div class="note">{disc}</div>
  </div>
</div>
<!-- /wp:html -->""")
PYEOF
)

FOOTER_HTML=$(python3 - "$META_FILE" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
u = m["site_url"]
print(f"""<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css">

<footer class="site-footer">
  <div class="footer-container">
    <div class="footer-social">
      <a href="https://www.facebook.com/thebettervacation" target="_blank" rel="noopener noreferrer" aria-label="Facebook"><i class="fab fa-facebook-f facebook"></i></a>
      <a href="https://www.youtube.com/channel/UCmSy2vAcpu2ULN0tHV6aA1A" target="_blank" rel="noopener noreferrer" aria-label="YouTube"><i class="fab fa-youtube youtube"></i></a>
      <a href="https://twitter.com/bettervacation_" target="_blank" rel="noopener noreferrer" aria-label="Twitter"><i class="fab fa-twitter twitter"></i></a>
      <a href="https://www.instagram.com/thebettervacation/" target="_blank" rel="noopener noreferrer" aria-label="Instagram"><i class="fab fa-instagram instagram"></i></a>
      <a href="https://www.pinterest.com/thebettervacation/" target="_blank" rel="noopener noreferrer" aria-label="Pinterest"><i class="fab fa-pinterest-p pinterest"></i></a>
      <a href="https://www.linkedin.com/company/thebettervacation/" target="_blank" rel="noopener noreferrer" aria-label="LinkedIn"><i class="fab fa-linkedin-in linkedin"></i></a>
    </div>
    <div class="footer-center">&copy; 2026 Firestorm Internet</div>
    <div class="footer-links">
      <a href="{u}/about-us/">About Us</a>
      <a href="{u}/contact-us/">Contact Us</a>
    </div>
  </div>
</footer>

<style>
  .site-footer{{background:#ffffff!important;padding:22px 36px}}
  .footer-container{{max-width:1400px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;gap:24px;flex-wrap:wrap}}
  .footer-social,.footer-links{{display:flex;align-items:center;gap:18px;min-width:220px}}
  .footer-social a{{text-decoration:none;transition:opacity .2s ease}}
  .footer-links a{{color:#222;text-decoration:none;transition:opacity .2s ease;font-size:16px}}
  .footer-social a:hover,.footer-links a:hover{{opacity:.75}}
  .footer-social i{{font-size:20px;line-height:1}}
  .facebook{{color:#1877f2}}.youtube{{color:#ff0000}}.twitter{{color:#1da1f2}}
  .instagram{{color:#e1306c}}.pinterest{{color:#e60023}}.linkedin{{color:#0a66c2}}
  .footer-center{{flex:1;text-align:center;font-size:16px;color:#222;min-width:220px}}
  .footer-links{{justify-content:flex-end}}
  @media(max-width:900px){{.footer-container{{flex-direction:column;text-align:center}}.footer-social,.footer-links{{justify-content:center;min-width:auto}}}}
</style>""")
PYEOF
)

echo ""
echo "── Pushing to opera-garnier (Server 1) ─────────────────────────────────────"

"${SSH_CMD[@]}" "${_SSH_USER}@${_SSH_HOST}" "
WP='$WP_PATH'

# ── About Us page ─────────────────────────────────────────────────────────────
ABOUT_ID=\$(wp post list --path=\"\$WP\" --post_type=page --post_name=about-us --fields=ID --format=csv 2>/dev/null | tail -n +2)
if [[ -n \"\$ABOUT_ID\" ]]; then
  wp post update \"\$ABOUT_ID\" --post_status=publish --path=\"\$WP\" 2>/dev/null
  echo \"  ↺ About Us updated (ID \$ABOUT_ID)\"
else
  ABOUT_ID=\$(wp post create --path=\"\$WP\" --post_type=page --post_title='About Us' --post_name=about-us --post_status=publish --porcelain 2>/dev/null)
  echo \"  ✓ About Us created (ID \$ABOUT_ID)\"
fi
wp post update \"\$ABOUT_ID\" --post_content='$(echo "$ABOUT_HTML" | sed "s/'/'\\\\''/g")' --path=\"\$WP\" 2>/dev/null
wp post meta update \"\$ABOUT_ID\" _generate-disable-headline true --path=\"\$WP\" 2>/dev/null
wp post meta update \"\$ABOUT_ID\" _generate-disable-post-image true --path=\"\$WP\" 2>/dev/null

# ── Contact Us page ───────────────────────────────────────────────────────────
CONTACT_ID=\$(wp post list --path=\"\$WP\" --post_type=page --post_name=contact-us --fields=ID --format=csv 2>/dev/null | tail -n +2)
if [[ -n \"\$CONTACT_ID\" ]]; then
  wp post update \"\$CONTACT_ID\" --post_status=publish --path=\"\$WP\" 2>/dev/null
  echo \"  ↺ Contact Us updated (ID \$CONTACT_ID)\"
else
  CONTACT_ID=\$(wp post create --path=\"\$WP\" --post_type=page --post_title='Contact Us' --post_name=contact-us --post_status=publish --porcelain 2>/dev/null)
  echo \"  ✓ Contact Us created (ID \$CONTACT_ID)\"
fi
wp post update \"\$CONTACT_ID\" --post_content='$(echo "$CONTACT_HTML" | sed "s/'/'\\\\''/g")' --path=\"\$WP\" 2>/dev/null
wp post meta update \"\$CONTACT_ID\" _generate-disable-headline true --path=\"\$WP\" 2>/dev/null
wp post meta update \"\$CONTACT_ID\" _generate-disable-post-image true --path=\"\$WP\" 2>/dev/null

# ── Footer GP Element ─────────────────────────────────────────────────────────
FOOTER_ID=\$(wp post list --path=\"\$WP\" --post_type=gp_elements --post_name=footer --fields=ID --format=csv 2>/dev/null | tail -n +2)
if [[ -n \"\$FOOTER_ID\" ]]; then
  echo \"  ↺ Footer element updated (ID \$FOOTER_ID)\"
else
  FOOTER_ID=\$(wp post create --path=\"\$WP\" --post_type=gp_elements --post_title='Footer' --post_name=footer --post_status=publish --porcelain 2>/dev/null)
  echo \"  ✓ Footer element created (ID \$FOOTER_ID)\"
fi
wp post meta update \"\$FOOTER_ID\" _generate_element_type 'hook' --path=\"\$WP\" 2>/dev/null
wp post meta update \"\$FOOTER_ID\" _generate_hook 'generate_footer' --path=\"\$WP\" 2>/dev/null
wp eval \"update_post_meta(\$FOOTER_ID, '_generate_element_display_conditions', array(array('rule'=>'general:site','object'=>'0')));\" --path=\"\$WP\" 2>/dev/null
wp post meta update \"\$FOOTER_ID\" _generate_element_content '$(echo "$FOOTER_HTML" | sed "s/'/'\\\\''/g")' --path=\"\$WP\" 2>/dev/null

# ── Primary Menu ──────────────────────────────────────────────────────────────
MENU_ID=\$(wp menu list --path=\"\$WP\" --format=csv 2>/dev/null | tail -n +2 | cut -d, -f1 | head -1)
if [[ -z \"\$MENU_ID\" ]]; then
  MENU_ID=\$(wp menu create 'Primary Menu' --path=\"\$WP\" --porcelain 2>/dev/null)
  echo \"  ✓ Primary Menu created (ID \$MENU_ID)\"
else
  echo \"  ↺ Primary Menu exists (ID \$MENU_ID) — clearing items\"
  wp menu item list \"\$MENU_ID\" --path=\"\$WP\" --format=csv 2>/dev/null | tail -n +2 | cut -d, -f1 | while read iid; do
    wp menu item delete \"\$iid\" --path=\"\$WP\" 2>/dev/null || true
  done
fi

# Add 4 menu items by page slug
HOME_ID=\$(wp post list --path=\"\$WP\" --post_type=page --post_name=homepage --fields=ID --format=csv 2>/dev/null | tail -n +2)
TICKETS_ID=\$(wp post list --path=\"\$WP\" --post_type=page --post_name=tickets-tours --fields=ID --format=csv 2>/dev/null | tail -n +2)
PYV_ID=\$(wp post list --path=\"\$WP\" --post_type=page --post_name=plan-your-visit --fields=ID --format=csv 2>/dev/null | tail -n +2)
WTS_ID=\$(wp post list --path=\"\$WP\" --post_type=page --post_name=what-to-see --fields=ID --format=csv 2>/dev/null | tail -n +2)

[[ -n \"\$HOME_ID\" ]]    && wp menu item add-post \"\$MENU_ID\" \"\$HOME_ID\"    --title='Home'              --path=\"\$WP\" 2>/dev/null
[[ -n \"\$TICKETS_ID\" ]] && wp menu item add-post \"\$MENU_ID\" \"\$TICKETS_ID\" --title='Tickets &amp; Tours' --path=\"\$WP\" 2>/dev/null
[[ -n \"\$PYV_ID\" ]]     && wp menu item add-post \"\$MENU_ID\" \"\$PYV_ID\"     --title='Plan Your Visit'   --path=\"\$WP\" 2>/dev/null
[[ -n \"\$WTS_ID\" ]]     && wp menu item add-post \"\$MENU_ID\" \"\$WTS_ID\"     --title='What to See'       --path=\"\$WP\" 2>/dev/null

# Assign to primary location
wp menu location assign \"\$MENU_ID\" primary --path=\"\$WP\" 2>/dev/null && echo \"  ✓ Menu assigned to primary location\"

echo ''
echo '── Verification ────────────────────────────────────────────────────────────'
echo -n 'Pages: '; wp post list --path=\"\$WP\" --post_type=page --post_status=publish --fields=post_name --format=csv 2>/dev/null | tail -n +2 | tr '\n' ' '; echo ''
echo -n 'GP Elements: '; wp post list --path=\"\$WP\" --post_type=gp_elements --fields=post_name --format=csv 2>/dev/null | tail -n +2 | tr '\n' ' '; echo ''
echo -n 'Menu items: '; wp menu item list \"\$MENU_ID\" --path=\"\$WP\" --format=csv 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
" 2>/dev/null

echo ""
echo "✓ Done — opera-garnier utility pages deployed."
