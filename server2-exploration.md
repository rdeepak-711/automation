# Server 2 Exploration

## SSH Credentials (from .env)

| Key | Value |
|-----|-------|
| Host | `50.6.155.174` |
| User | `dpskbcmy` |
| Key | `~/.ssh/id_rsa_bluehost2` |

## Step 1 — Connect & List Root

```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 \
  "ls /home1/dpskbcmy/public_html/"
```

Root contains: `wp-*` files (WordPress root install) + `website_*` subdirectories.

## Step 2 — Map Folders to Sites (mirrors main.sh step 2 logic)

`main.sh` step 2 calls `scripts/base/find-wp-path.sh`, which iterates `website_*/` subfolders and runs:
```bash
wp option get siteurl --path="$d"
```
to match folder → URL. Same logic used here:

```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 "
root=/home1/dpskbcmy/public_html
echo '=== ROOT ==='
wp option get siteurl --path=\"\$root\" 2>/dev/null || echo '(no wp at root)'
for d in \$root/website_*/; do
  url=\$(wp option get siteurl --path=\"\$d\" 2>/dev/null) || url='(fail)'
  echo \"\$d => \$url\"
done
"
```

### Results

| Folder | Site URL |
|--------|----------|
| `/home1/dpskbcmy/public_html/` (root) | https://bluemosque-guide.com |
| `website_204db6f9/` | https://hagiasofia-guide.com |
| `website_34029298/` | https://museodelprado-guide.com |
| `website_58b542cb/` | https://montsaintmichel-guide.com |
| `website_amsterdam/` | https://amsterdamcanalcruise-guide.com |
| `website_angkorwat/` | https://angkorwat-guide.com |
| `website_bbb90802/` | (wp-cli fail — likely empty/broken install) |
| `website_da6eadef/` | https://vangoghmuseum-guide.com |
| `website_fee4b963/` | (wp-cli fail — likely empty/broken install) |
| `website_plitvice/` | https://plitvicelakes-guide.com |
| `website_stonehenge/` | https://guide-stonehenge.com |
| `website_topkapi/` | https://topkapipalace-guide.com |

## Step 3 — Hagia Sofia WP_PATH

`hagiasofia-guide.com` lives at:
```
WP_PATH=/home1/dpskbcmy/public_html/website_204db6f9
```

## Step 4 — Fetch All Post & Page Titles

```bash
ssh -i ~/.ssh/id_rsa_bluehost2 -o StrictHostKeyChecking=no dpskbcmy@50.6.155.174 "
WP_PATH=/home1/dpskbcmy/public_html/website_204db6f9
echo '=== POSTS ==='
wp post list --path=\"\$WP_PATH\" --post_type=post --post_status=any \
  --fields=ID,post_title,post_status --format=table 2>/dev/null
echo ''
echo '=== PAGES ==='
wp post list --path=\"\$WP_PATH\" --post_type=page --post_status=any \
  --fields=ID,post_title,post_status --format=table 2>/dev/null
"
```

### Posts (49 published)

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

### Pages (4 published)

| ID | Title | Status |
|----|-------|--------|
| 213 | Plan Your Visit to Hagia Sophia — Opening Hours, Dress Code & Tips (2026) | publish |
| 214 | Hagia Sophia Tickets & Tours — Compare Prices & Book Online (2026) | publish |
| 219 | Hagia Sophia — Visitor Guide, Tickets & Tours \| hagiasofia-guide.com | publish |
| 215 | What to See at Hagia Sophia — Mosaics, Architecture, Upper Gallery & More (2026) | publish |
