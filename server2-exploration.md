# Server 2 Exploration

**Last updated:** 2026-04-16

## SSH Credentials

| Key | Value |
|-----|-------|
| Host | `50.6.155.174` |
| User | `dpskbcmy` |
| Key | `~/.ssh/id_rsa_bluehost2` |
| Base path | `/home1/dpskbcmy/public_html/` |

SSH pattern:
```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 'COMMAND'
```

## Quick-Reference: WP-CLI per Site

```bash
# Reusable alias
SSH="ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no -o ConnectTimeout=15 dpskbcmy@50.6.155.174"

# Blue Mosque       → root install
$SSH "wp <command> --path=/home1/dpskbcmy/public_html"

# Mont-Saint-Michel → website_58b542cb
$SSH "wp <command> --path=/home1/dpskbcmy/public_html/website_58b542cb"

# Plitvice Lakes    → website_plitvice
$SSH "wp <command> --path=/home1/dpskbcmy/public_html/website_plitvice"

# Hagia Sophia      → website_204db6f9
$SSH "wp <command> --path=/home1/dpskbcmy/public_html/website_204db6f9"

# Van Gogh Museum   → website_da6eadef
$SSH "wp <command> --path=/home1/dpskbcmy/public_html/website_da6eadef"

# Topkapi Palace    → website_topkapi
$SSH "wp <command> --path=/home1/dpskbcmy/public_html/website_topkapi"

# Angkor Wat        → website_angkorwat
$SSH "wp <command> --path=/home1/dpskbcmy/public_html/website_angkorwat"
```

---

## Complete Site Inventory (as of 2026-04-16)

| Folder | Domain | Posts (published) | Pages (published) | Status |
|--------|--------|:-----------------:|:-----------------:|--------|
| `/public_html/` (root) | bluemosque-guide.com ¹ | 26 | 4 | Live — WP-CLI works |
| `website_182e0b08/` | — | — | — | Empty (only cgi-bin + error_log + wp-config.php.bak) |
| `website_204db6f9/` | hagiasophia-guide.com ² | 47 | 6 | Live — WP-CLI works |
| `website_34029298/` | museodelprado-guide.com | 1 | 1 | Stub — framework only |
| `website_345ac148/` | chichenitza-guide.com | 1 | 1 | Stub — framework only |
| `website_58b542cb/` | montsaintmichel-guide.com | 41 | 6 | Live — WP-CLI works |
| `website_5a378865/` | citypass-guide.com | 1 | 1 | Stub — framework only |
| `website_5e3ec5d6/` | halongbaycruise-guide.com ³ | 1 | 1 | Broken siteurl (path suffix) |
| `website_amsterdam/` | amsterdamcanalcruise-guide.com | 1 | 1 | Stub — framework only |
| `website_angkorwat/` | angkorwat-guide.com | 60 | 7 | Live — WP-CLI works |
| `website_bbb90802/` | — | — | — | Empty (only cgi-bin + error_log + wp-config.php.bak) |
| `website_da6eadef/` | vangoghmuseum-guide.com | 32 | 6 | Live — WP-CLI works |
| `website_fee4b963/` | — | — | — | Empty (only cgi-bin + error_log + wp-config.php.bak) |
| `website_plitvice/` | plitvicelakes-guide.com | 53 | 7 | Live — WP-CLI works |
| `website_pyramids/` | pyramidsofgiza-guide.com | 1 | 1 | Stub — framework only |
| `website_stonehenge/` | guide-stonehenge.com | 1 | 1 | Stub — framework only |
| `website_topkapi/` | topkapipalace-guide.com | 47 | 7 | Live — WP-CLI works |

**¹ Root domain:** WP reports siteurl = `https://dps.kbc.mybluehost.me` (Bluehost staging domain). The WP blogname option is "Blue Mosque". DNS for bluemosque-guide.com presumably points here; the siteurl may need updating for proper permalink operation.

**² Hagia Sophia domain:** The live domain is `hagiasophia-guide.com` (with two 'h's — hagia**s**o**ph**ia). The previous exploration doc recorded it as `hagiasofia-guide.com` (one 'h' — hagia**so**fia). The agent spec also lists `hagiasofia-guide.com`. The actual registered siteurl is `hagiasophia-guide.com` — the spec needs updating.

**³ Halong Bay siteurl bug:** `wp option get siteurl` returns `https://halongbaycruise-guide.com/website_5e3ec5d6` — the subfolder path is embedded in the URL. This will break all permalinks. Needs fix:
```bash
wp option update siteurl 'https://halongbaycruise-guide.com' --path=/home1/dpskbcmy/public_html/website_5e3ec5d6/
wp option update home 'https://halongbaycruise-guide.com' --path=/home1/dpskbcmy/public_html/website_5e3ec5d6/
```

---

## Summary by Status

### Fully Live Sites (7 — content published)

| Site | Domain | WP_PATH | Posts | Pages |
|------|--------|---------|:-----:|:-----:|
| Blue Mosque | bluemosque-guide.com | `/public_html/` | 26 | 4 |
| Hagia Sophia | hagiasophia-guide.com | `website_204db6f9/` | 47 | 6 |
| Mont-Saint-Michel | montsaintmichel-guide.com | `website_58b542cb/` | 41 | 6 |
| Angkor Wat | angkorwat-guide.com | `website_angkorwat/` | 60 | 7 |
| Van Gogh Museum | vangoghmuseum-guide.com | `website_da6eadef/` | 32 | 6 |
| Plitvice Lakes | plitvicelakes-guide.com | `website_plitvice/` | 53 | 7 |
| Topkapi Palace | topkapipalace-guide.com | `website_topkapi/` | 47 | 7 |

**Total published posts across live sites: 306**

### Stub/Framework-Only Installs (6 — WP installed but no content yet)

| Site | Domain | WP_PATH | Notes |
|------|--------|---------|-------|
| Museo del Prado | museodelprado-guide.com | `website_34029298/` | 1 stub post |
| Amsterdam Canal | amsterdamcanalcruise-guide.com | `website_amsterdam/` | 1 stub post |
| Stonehenge | guide-stonehenge.com | `website_stonehenge/` | 1 stub post |
| Chichen Itza | chichenitza-guide.com | `website_345ac148/` | 1 stub post |
| City Pass Guide | citypass-guide.com | `website_5a378865/` | 1 stub post |
| Pyramids of Giza | pyramidsofgiza-guide.com | `website_pyramids/` | 1 stub post |

### Broken Installs (1 — siteurl misconfigured)

| Site | Domain | WP_PATH | Issue |
|------|--------|---------|-------|
| Halong Bay Cruise | halongbaycruise-guide.com | `website_5e3ec5d6/` | siteurl has `/website_5e3ec5d6` path suffix embedded |

### Empty Directories (3 — no WordPress)

| Folder | Contents |
|--------|---------|
| `website_182e0b08/` | cgi-bin, error_log, wp-config.php.bak only |
| `website_bbb90802/` | cgi-bin, error_log, wp-config.php.bak only |
| `website_fee4b963/` | cgi-bin, error_log, wp-config.php.bak only |

---

## Hagia Sophia — Post & Page Inventory (from earlier exploration)

### Posts (49 published at time of previous exploration; now shows 47)

| ID | Title | Status |
|----|-------|--------|
| 209 | Hagia Sophia vs Blue Mosque 2026: Differences, Which Is Better & Which to Visit First | publish |
| 114 | What to See Inside Hagia Sophia 2026: Complete Guide to Every Highlight | publish |
| 113 | History of Hagia Sophia: From Byzantine Cathedral to Ottoman Mosque — Complete Timeline | publish |
| 111 | Hagia Sophia Upper Gallery 2026: What to See, How to Access It & Is It Worth Visiting? | publish |
| 110 | Hagia Sophia Mosaics 2026: Complete Guide — History, What They Show & Where to Find Them | publish |
| 109 | Hidden Details at Hagia Sophia 2026: Secrets & Things Most Visitors Walk Past | publish |
| 108 | The Deesis Mosaic at Hagia Sophia 2026: Complete Guide to the Most Famous Byzantine Artwork | publish |
| 107 | Hagia Sophia at Night 2026: Evening Visits, Exterior Lighting & Late Entry Tips | publish |
| 106 | Hagia Sophia Architecture 2026: The Engineering & Design That Changed the World | publish |
| 105 | Attractions Near Hagia Sophia 2026: Complete Guide to Sultanahmet's Best Landmarks | publish |
| 104 | Istanbul Tourist Pass 2026: Does It Cover Hagia Sophia? Full Review & Is It Worth It? | publish |
| 103 | Half-Day Istanbul Morning Tour 2026: Hagia Sophia, Blue Mosque, Hippodrome & Grand Bazaar Review | publish |
| 102 | Is Hagia Sophia Free? Entry Fees & Ticket Costs Explained (2026) | publish |
| 101 | Hagia Sophia + Topkapi Palace Combo Tickets 2026: Full Review & Is It Worth It? | publish |
| 100 | Hagia Sophia Tickets 2026: Every Option Compared & Reviewed | publish |
| 99 | Hagia Sophia Ticket Prices 2026: Entry Fees, Combos & Tours Explained | publish |
| 98 | Hagia Sophia Skip-the-Line Tickets 2026: Are They Worth It? | publish |
| 97 | Hagia Sophia Self-Guided Entry Ticket Review 2026: Skip-the-Line, Worth It? | publish |
| 96 | Hagia Sophia Private Tours 2026: Are They Worth It? Honest Review & Best Options | publish |
| 95 | Hagia Sophia Private Guided Tour 2026: Full Review, What to Expect & Is It Worth It? | publish |
| 94 | Hagia Sophia Mosque + History Museum Combo Ticket 2026: Is It Worth It? | publish |
| 93 | Hagia Sophia History Museum Only Ticket 2026: Full Review — No Mosque Entry | publish |
| 92 | Hagia Sophia Guided Tour 2026: Full Review — What to Expect & Is It Worth Booking? | publish |
| 91 | Hagia Sophia + Bosphorus Cruise Combo 2026: Full Review & Is It Worth Booking? | publish |
| 90 | Hagia Sophia, Blue Mosque & Hippodrome Guided Tour 2026: Full Review & Is It Worth It? | publish |
| 89 | Hagia Sophia & Blue Mosque Guided Tour 2026: Full Review — Is It Worth Booking? | publish |
| 88 | Hagia Sophia, Blue Mosque & Grand Bazaar Tour 2026: Full Review & Is It Worth Booking? | publish |
| 87 | Hagia Sophia + Blue Mosque Combo Ticket 2026: Full Review & Is It Worth It? | publish |
| 86 | Hagia Sophia + Blue Mosque + Basilica Cistern Combo 2026: Full Review & Is It Worth It? | publish |
| 85 | Hagia Sophia + Basilica Cistern Combo Ticket 2026: Full Review & Is It Worth It? | publish |
| 84 | Hagia Sophia Audio Guide 2026: Is It Worth It? Options, Costs & Honest Review | publish |
| 83 | Hagia Sophia 4-Attraction Super Combo 2026: Full Review — Is It Worth It? | publish |
| 82 | Dolmabahce Palace, Hagia Sophia & Galata Tower Combo 2026: Full Review & Is It Worth It? | publish |
| 81 | Blue Mosque, Hagia Sophia & Sultanahmet Tour 2026: Full Review & Is It Worth Booking? | publish |
| 80 | Blue Mosque, Hagia Sophia & Old Town Walking Tour 2026: Full Review & Is It Worth Booking? | publish |
| 79 | Best Hagia Sophia Guided Tours 2026: Small-Group, Private & Combo Tours Compared | publish |
| 78 | Visiting Hagia Sophia with Kids 2026: Family Tips, What Children Love & What to Skip | publish |
| 77 | How to Get to Hagia Sophia 2026: Tram, Bus, Taxi & Walking Directions | publish |
| 76 | How Long to Spend at Hagia Sophia 2026: Realistic Time Estimates for Every Visit Type | publish |
| 75 | Hagia Sophia Tips for First-Time Visitors 2026: 15 Things to Know Before You Go | publish |
| 74 | Hagia Sophia Photography Guide 2026: Rules, Best Spots & Tips for Great Shots | publish |
| 73 | Hagia Sophia Opening Hours 2026: Full Schedule, Friday Closure & Seasonal Changes | publish |
| 72 | Hagia Sophia Dress Code 2026: What to Wear, Rules & What Happens If You Get It Wrong | publish |
| 71 | Hagia Sophia Crowds 2026: When Is It Least Busy? Queue Times & Crowd Guide | publish |
| 70 | Hagia Sophia Accessibility Guide 2026: Wheelchair Access, Ramps & Visitor Information | publish |
| 69 | Best Time to Visit Hagia Sophia 2026: By Hour, Day & Season Guide | publish |

### Pages (4 in previous exploration; now shows 6)

| ID | Title | Status |
|----|-------|--------|
| 213 | Plan Your Visit to Hagia Sophia — Opening Hours, Dress Code & Tips (2026) | publish |
| 214 | Hagia Sophia Tickets & Tours — Compare Prices & Book Online (2026) | publish |
| 219 | Hagia Sophia — Visitor Guide, Tickets & Tours \| hagiasofia-guide.com | publish |
| 215 | What to See at Hagia Sophia — Mosaics, Architecture, Upper Gallery & More (2026) | publish |

---

## Issues Found

### 1. Agent Spec Domain Typo — Hagia Sophia
- **Agent spec says:** `hagiasofia-guide.com` (one h)
- **Actual siteurl:** `hagiasophia-guide.com` (two h's — correct spelling)
- **Action needed:** Update agent spec `wp-site-auditor.md` line 78 and memory files

### 2. Root Install Siteurl Mismatch — Blue Mosque
- **Actual siteurl option:** `https://dps.kbc.mybluehost.me` (Bluehost default)
- **Expected:** `https://bluemosque-guide.com`
- **Action needed:** Run `wp option update siteurl/home` to set the real domain, or verify DNS and domain mapping are correct in Bluehost cPanel

### 3. Halong Bay siteurl Bug
- **Actual siteurl:** `https://halongbaycruise-guide.com/website_5e3ec5d6`
- **Fix:** `wp option update siteurl 'https://halongbaycruise-guide.com'` and same for `home`

### 4. New Directories Not in Agent Spec
The following were discovered in this audit but are missing from the agent spec's Server 2 table:
- `website_345ac148/` → chichenitza-guide.com
- `website_5a378865/` → citypass-guide.com
- `website_5e3ec5d6/` → halongbaycruise-guide.com
- `website_pyramids/` → pyramidsofgiza-guide.com
- Empty: `website_182e0b08/`, `website_bbb90802/`, `website_fee4b963/`

### 5. Hagia Sophia Post Count Discrepancy
- Previous exploration recorded 49 posts; current count is 47. Two posts appear to have been removed or unpublished since the previous audit.
