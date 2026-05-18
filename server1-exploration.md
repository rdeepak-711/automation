# Server 1 Exploration

## SSH Credentials

| Key | Value |
|-----|-------|
| Host | `50.6.109.30` |
| User | `kzrmeomy` |
| SSH Key | `~/.ssh/id_rsa_bluehost_old` |
| Base path | `/home1/kzrmeomy/public_html/` |

> **Note:** `id_rsa_bluehost2` does NOT work for Server 1. Use `id_rsa_bluehost_old`.
> Also disable SSH agent to avoid "too many authentication failures": prefix commands with `SSH_AUTH_SOCK=""`.

**SSH command pattern:**
```bash
SSH_AUTH_SOCK="" ssh -i ~/.ssh/id_rsa_bluehost_old -o StrictHostKeyChecking=no -o IdentitiesOnly=yes kzrmeomy@50.6.109.30 "COMMAND"
```

**WP-CLI pattern for any site:**
```bash
SSH_AUTH_SOCK="" ssh -i ~/.ssh/id_rsa_bluehost_old -o StrictHostKeyChecking=no -o IdentitiesOnly=yes kzrmeomy@50.6.109.30 \
  "wp <command> --path=/home1/kzrmeomy/public_html/<website_dir>/"
```

---

## Site Map — All Folders → URLs

| Folder | Site URL |
|--------|----------|
| `/home1/kzrmeomy/public_html/` (root) | https://alcazar-seville.co |
| `website_007b635a/` | https://iguazufalls-tickets.org |
| `website_018a6c8c/` | https://hooverdam-tours.co |
| `website_0232f6ec/` | https://firestorm-internet.com |
| `website_02791e70/` | https://bosphoruscruise-tickets.com |
| `website_0cd793f0/` | https://statueofliberty-tickets.org |
| `website_157bc914/` | https://santa-maria-delle-grazie.co |
| `website_17963224/` | https://triggertrips.com |
| `website_189e0e3b/` | https://universalstudioshollywood-tickets.co |
| `website_1cdb4543/` | https://riverthames-cruise.co |
| `website_2784a30f/` | https://edinburghcastle-tickets.com |
| `website_29b66b10/` | https://gameofthrones-tours.co |
| `website_345b9dcc/` | https://harrypotter-studio.com |
| `website_354853d7/` | https://paris-notredame.com |
| `website_3630bf36/` | https://siena-cathedral.com |
| `website_3da824b8/` | https://tickets-disneyland.co |
| `website_40f61a48/` | https://dubrovnik-tickets.co |
| `website_511662ed/` | https://tickets-duomodimilano.co |
| `website_54c40891/` | https://neuschwanstein-tickets.co |
| `website_576f3548/` | https://rhearajan.com |
| `website_5bbe9cf6/` | https://tickets-burjkhalifa.com |
| `website_63dbacf5/` | https://bluelagooniceland-tickets.com |
| `website_69b91c3d/` | https://duomodimilano-tickets.org |
| `website_6ea10d32/` | https://alcatraz-island.com |
| `website_71cb5b6e/` | https://ouchmytoe.com |
| `website_772082ae/` | https://toorists.com |
| `website_7c76d1bd/` | https://highroller-vegas.com |
| `website_7cc1f6b6/` | https://tickets-toweroflondon.com |
| `website_85e526b7/` | https://belvedere-tickets.org |
| `website_87118d9c/` | https://decks-nyc.com |
| `website_8a99cfdf/` | https://montsaintmichel-guide.com |
| `website_97258f86/` | https://vegas-shows.co |
| `website_a66d90f5/` | https://seville-cathedral.co |
| `website_b03dd482/` | (fail — empty/broken) |
| `website_b22c081f/` | https://alhambra-palace.org |
| `website_b9cdec12/` | https://operagarnier-guide.com |
| `website_c022fab1/` | https://orlando-themeparks.com |
| `website_ce6ca565/` | https://auschwitz-guide.com |
| `website_d3d982be/` | https://tickets-sagradafamilia.co |
| `website_d75797ad/` | https://tickets-palaceofversailles.com |
| `website_d84dd896/` | https://sail-amsterdam.co |
| `website_e1977d91/` | https://tickets-istanbul.co |
| `website_e38b9b21/` | https://schonbrunn-tickets.org |
| `website_e61e7941/` | https://tickets-acropolis.org |
| `website_e8037892/` | https://helicopterthrills.com |
| `website_e90439e9/` | https://alcatraz-island.com (duplicate) |
| `website_eb073c74/` | https://uffizigallery-tickets.org |
| `website_f10c6053/` | https://seinecruise-tickets.org |
| `website_f57ab06d/` | https://cappadocia-tours.co |
| `website_fb917f7a/` | https://lisbon-tickets.com |
| multiple folders | (fail — empty/broken installs) |

---

## Sites of Interest (auto-create-site projects)

| Site | Directory | Domain |
|---|---|---|
| Auschwitz | `website_ce6ca565` | auschwitz-guide.com |
| Opera Garnier | `website_b9cdec12` | operagarnier-guide.com |
| Mont-Saint-Michel (copy) | `website_8a99cfdf` | montsaintmichel-guide.com |

---

## auschwitz-guide.com

**WP_PATH:** `/home1/kzrmeomy/public_html/website_ce6ca565`

### Counts
- Posts: **50** published
- Pages: **6** published
- Permalink: `/%category%/%postname%/` ✓

### Categories
| ID | Name | Slug | Post Count |
|----|------|------|-----------|
| 15 | Plan Your Visit | plan-your-visit | 21 |
| 1 | Tickets & Tours | tickets-tours | 17 |
| 14 | What To See | what-to-see | 12 |

### Posts (50 published)

| ID | Title | Slug |
|----|-------|------|
| 66 | What is Auschwitz-Birkenau? History, Significance & Visitor Overview | what-is-auschwitz-birkenau |
| 70 | Best Time to Visit Auschwitz-Birkenau: Season, Month & Crowd Guide (2025–2026) | best-time-to-visit |
| 71 | How Long Does a Visit to Auschwitz-Birkenau Take? All Tour Durations Explained | how-long-does-a-visit-take |
| 72 | What to Expect at Auschwitz-Birkenau: An Honest First-Time Visitor's Guide | what-to-expect |
| 73 | What to Wear and Bring to Auschwitz-Birkenau: The Complete Packing Guide | what-to-wear-and-bring |
| 74 | Accessibility at Auschwitz-Birkenau: Wheelchairs, Mobility & Disability Guide | accessibility |
| 75 | Visiting Auschwitz with Children: Age Guide, What to Expect & Key Tips | visiting-with-children |
| 76 | Group Visits & School Tours to Auschwitz-Birkenau: How to Book & What to Know | group-visits-school-tours |
| 93 | Getting to Auschwitz from Kraków: Bus, Train, Car & Guided Tour Options | getting-there-from-krakow |
| 95 | Getting to Auschwitz from Warsaw: Train, Car & Guided Tour Options | getting-there-from-warsaw |
| 96 | Getting to Auschwitz by Bus: Lajkonik Schedule, Stops & Tickets (2025–2026) | getting-there-by-bus |
| 97 | Getting to Auschwitz by Train: PKP Route, Timetables & Station Guide | getting-there-by-train |
| 98 | Driving to Auschwitz-Birkenau: Routes, Parking & Everything You Need to Know | driving-and-parking |
| 99 | Getting to Auschwitz from the Airport: Kraków & Katowice Transfer Guide | getting-there-from-airports |
| 100 | Where to Stay Near Auschwitz-Birkenau: Oświęcim, Kraków & Best Base Options | where-to-stay |
| 101 | Auschwitz-Birkenau Opening Hours 2025–2026: Full Monthly Schedule & What to Know | opening-hours |
| 102 | Rules of Conduct at Auschwitz-Birkenau: What Every Visitor Must Know | rules-of-conduct |
| 103 | Photography Rules at Auschwitz-Birkenau: What You Can and Cannot Photograph | photography-rules |
| 104 | The Free Shuttle Bus Between Auschwitz I and Birkenau: How It Works | shuttle-bus-between-sites |
| 105 | Auschwitz-Birkenau On-Site Facilities: Café, Bookshop, Toilets & Luggage Storage | on-site-facilities |
| 106 | After Visiting Auschwitz-Birkenau: How to Process the Experience & What to Read Next | after-your-visit |
| 107 | Auschwitz-Birkenau Entry Passes Explained: Free Passes vs Paid Guided Tours | entry-passes-explained |
| 108 | How to Book Auschwitz-Birkenau Tickets: Complete Step-by-Step Guide (2025–2026) | how-to-book-tickets |
| 109 | How Far in Advance to Book Auschwitz-Birkenau: Season-by-Season Booking Guide | how-far-in-advance-to-book |
| 110 | Auschwitz: Organised Tour vs Booking Direct — Which Is Right for You? | organised-tour-vs-booking-direct |
| 111 | Auschwitz-Birkenau Prices, Concessions & Free Entry: Complete Cost Guide (2025–2026) | prices-and-concessions |
| 112 | Languages Available at Auschwitz-Birkenau: Guided Tours in 20+ Languages | languages-available |
| 113 | Online Virtual Tour of Auschwitz-Birkenau: How to Book & What to Expect | online-virtual-tours |
| 114 | Auschwitz-Birkenau Tour Types: Which Guided Tour Should You Choose? | tour-types |
| 115 | Auschwitz-Birkenau Guided Tour with Hotel Pickup from Kraków: Complete Guide | guided-tour-hotel-pickup-krakow |
| 116 | Auschwitz-Birkenau Entry + Private Transport from Kraków: Transport-Only Tour Guide | entry-private-transport-krakow |
| 117 | Auschwitz-Birkenau: Guided Tour vs Self-Guided Visit — Which Is Right for You? | guided-vs-self-guided |
| 118 | Auschwitz-Birkenau & Wieliczka Salt Mine Guided Tour from Kraków: Is the Combo Worth It? | auschwitz-salt-mine-combo-tour |
| 119 | Day Tours from Kraków to Auschwitz-Birkenau: All Options Compared (2025–2026) | tours-from-krakow |
| 120 | Day Tours from Warsaw to Auschwitz-Birkenau: Train Tour, Car & What to Expect | tours-from-warsaw |
| 121 | Day Tours from Wrocław to Auschwitz-Birkenau: Full Guide & What to Expect | tours-from-wroclaw |
| 122 | Day Tours from Katowice to Auschwitz-Birkenau: Skip-the-Line Guided Tour Guide | tours-from-katowice |
| 123 | Day Tours from Prague to Auschwitz-Birkenau: Private Full-Day Trip Guide | tours-from-prague |
| 124 | Auschwitz I: Complete Visitor Guide to the Main Camp (What to See & Know) | auschwitz-i-complete-guide |
| 125 | The "Arbeit Macht Frei" Gate at Auschwitz: History, Significance & What to Know | arbeit-macht-frei-gate |
| 126 | Block 11 at Auschwitz: The Death Block — History, Standing Cells & What to Know | block-11-death-block |
| 127 | The Gas Chamber & Crematorium I at Auschwitz: History & Visitor Guide | gas-chamber-crematorium-i |
| 128 | The Prisoner Exhibitions at Auschwitz I: Blocks 4, 5 & 6 Explained | prisoner-exhibitions |
| 129 | Auschwitz II-Birkenau: Complete Visitor Guide to the Extermination Camp | auschwitz-ii-birkenau-complete-guide |
| 130 | The Railway Ramp at Birkenau: History, the Selection Process & Visitor Guide | railway-ramp-birkenau |
| 131 | The Gas Chambers & Crematoria at Birkenau: History & What Visitors See Today | gas-chambers-crematoria-birkenau |
| 132 | The Prisoner Barracks at Birkenau: History, Conditions & What You See Today | prisoner-barracks-birkenau |
| 133 | The International Monument at Auschwitz-Birkenau: History & Visitor Guide | international-monument |
| 134 | The Kanada Warehouses at Birkenau: History, Significance & Visitor Guide | kanada-warehouses |
| 135 | Auschwitz-Birkenau FAQ: Every Question Answered Before You Visit | faq |

### Pages (6 published)

| ID | Title | Slug |
|----|-------|------|
| 137 | Auschwitz-Birkenau Tickets & Tours \| Compare All Options | tickets-tours |
| 136 | Plan Your Visit to Auschwitz-Birkenau \| Complete Visitor Guide | plan-your-visit |
| 138 | What to See at Auschwitz-Birkenau \| Complete Site Guide | what-to-see |
| 210 | Auschwitz-Birkenau — Visitor Guide, Tickets & Tours \| auschwitz-guide.com | homepage |
| 580 | About Us | about-us |
| 582 | Contact Us | contact-us |

---

## operagarnier-guide.com

**WP_PATH:** `/home1/kzrmeomy/public_html/website_b9cdec12`

### Counts
- Posts: **46** published
- Pages: **4** published
- Permalink: `/%category%/%postname%/` ✓

### Categories
| ID | Name | Slug | Post Count |
|----|------|------|-----------|
| 21 | Plan Your Visit | plan-your-visit | 19 |
| 22 | Tickets & Tours | tickets-tours | 13 |
| 23 | What to See | what-to-see | 14 |

### Posts (46 published)

| ID | Title | Slug |
|----|-------|------|
| 76 | Accessibility at Opera Garnier: Wheelchair, Mobility & Disability Guide 2026 | accessibility |
| 77 | Arc de Triomphe + Opera Garnier Combo Ticket 2026: Two Icons, One Day | arc-de-triomphe-combo |
| 78 | Opera Garnier Architecture Style: Beaux-Arts Eclecticism Explained | architecture-style |
| 85 | After Your Opera Garnier Visit: What to Do & See Nearby (2026) | after-your-visit |
| 86 | Best Time to Visit Opera Garnier in 2026 | best-time-to-visit |
| 87 | Getting to Opera Garnier from CDG Airport (2026): Cheapest & Fastest Routes | getting-there-from-cdg |
| 88 | Getting to Opera Garnier from Orly Airport (2026): All Routes Explained | getting-there-from-orly |
| 89 | Best Hotels Near Opera Garnier 2026: Where to Stay in the 9th Arrondissement | hotels-nearby |
| 90 | How Long to Spend at Opera Garnier in 2026 | how-long-to-spend |
| 91 | How to Get to Opera Garnier: Every Transport Option (2026) | how-to-get-there |
| 92 | Is Opera Garnier Worth Visiting? An Honest Guide (2026) | is-it-worth-visiting |
| 93 | Nearest Metro to Opera Garnier: Lines, Exits & Directions (2026) | nearest-metro |
| 94 | Opera Garnier On-Site Facilities: Café, Shop, Cloakroom & More (2026) | on-site-facilities |
| 95 | Opera Garnier Opening Hours 2026: Full Schedule, Closures & Best Times | opening-hours |
| 96 | Parking Near Opera Garnier: Car Parks, Rates & Honest Advice (2026) | parking |
| 97 | Photography Rules at Opera Garnier 2026: What's Allowed & What Isn't | photography-rules |
| 98 | Best Restaurants Near Opera Garnier 2026: Where to Eat Before & After | restaurants-nearby |
| 99 | Opera Garnier Visitor Guide 2026: Everything You Need to Know | visitor-guide |
| 100 | Opera Garnier with Kids: Family Visit Guide 2026 | visiting-with-kids |
| 101 | What to Bring to Opera Garnier: Packing List 2026 | what-to-bring |
| 102 | What to Wear to Opera Garnier: Dress Code Guide 2026 | what-to-wear |
| 104 | Opera Garnier Audio Guide 2026: Languages, Cost, What It Covers & Is It Worth It? | audio-guide |
| 105 | Opera Garnier Entry Ticket 2026: Reserved Access Guide & Booking Tips | entry-ticket |
| 106 | Free & Discounted Entry to Opera Garnier 2026: Who Qualifies & How | free-and-discounted-entry |
| 107 | Guided Tours of Opera Garnier 2026: All Options Compared | guided-tours-overview |
| 108 | How to Buy Opera Garnier Tickets Online in 2026: Step-by-Step Guide | how-to-buy-tickets |
| 109 | Musée d'Orsay + Opera Garnier Combo Ticket 2026: Is It Worth It? | musee-dorsay-combo |
| 110 | Opera Garnier Private Guided Tour 2026: Expert Guide, Entry Included | private-guided-tour |
| 111 | Opera Garnier Private Tour with Ballet Artist Show 2026: The Premium Experience | private-tour-ballet-show |
| 112 | Seine River Cruise + Opera Garnier Combo Ticket 2026: Plan Your Perfect Paris Day | seine-cruise-combo |
| 113 | Self-Guided vs Guided Tour at Opera Garnier: Which Is Better? (2026) | self-guided-vs-guided |
| 114 | Skip the Line at Opera Garnier: Does It Exist & How to Do It (2026) | skip-the-line |
| 115 | Opera Garnier Tickets 2026: All Options, Prices & What's Included | tickets-overview |
| 116 | Opera Garnier Auditorium & Chagall Ceiling: The Complete Guide (2026) | auditorium-chagall-ceiling |
| 117 | Charles Garnier: The Architect of Opera Garnier (Life, Career & Legacy) | charles-garnier-architect |
| 118 | Famous Performances & Milestones at Opera Garnier: A Cultural Timeline | famous-performances |
| 119 | Opera Garnier FAQ 2026: Every Question Answered (Mega-Guide) | faq |
| 120 | Opera Garnier vs Opéra Bastille: Which Should You Visit? (2026) | garnier-vs-bastille |
| 121 | The Grand Foyer of Opera Garnier: Art, Architecture & What to Look For (2026) | grand-foyer |
| 122 | The Grand Staircase of Opera Garnier: Architecture, History & Visitor Guide (2026) | grand-staircase |
| 123 | History of Opera Garnier: From Napoleon III to Today (Complete Guide) | history |
| 124 | Opera Garnier Library & Museum (Bibliothèque-Musée): What's Inside (2026) | library-and-museum |
| 125 | Napoleon III & Opera Garnier: Why the Emperor Built the Most Opulent Opera House in the World | napoleon-iii-and-the-opera |
| 126 | The Phantom of the Opera — The Real Story Behind Opera Garnier (2026) | phantom-of-the-opera |
| 127 | Opera Garnier Rooftop Terrace: Views, Access & What to Expect (2026) | rooftop-terrace |
| 128 | The Underground Lake at Opera Garnier: Real History & Phantom Mythology | underground-lake |

### Pages (4 published)

| ID | Title | Slug |
|----|-------|------|
| 129 | Opera Garnier — Visitor Guide, Tickets & Tours \| operagarnier-guide.com | homepage |
| 130 | Plan Your Visit to Opera Garnier \| Complete Visitor Guide 2026 | plan-your-visit |
| 131 | Opera Garnier Tickets & Tours 2026 \| Compare All Options | tickets-tours |
| 132 | What to See at Opera Garnier \| Complete Guide to Palais Garnier | what-to-see |
