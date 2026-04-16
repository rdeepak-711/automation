# GYG Image Fetcher — Design Spec

## Context

auto-create-site generates WordPress affiliate sites for tourist attractions. Each site links to GYG tours but currently uses placeholder images. This script fetches real tour photos from the GYG Partner API, converts them to web-optimized formats, and produces a manifest mapping tours to local image files.

## Input

```bash
./scripts/fetch-gyg-images.sh <site-slug> "<attraction-name>"
# Example:
./scripts/fetch-gyg-images.sh opera-garnier "Opera Garnier"
```

- `site-slug` — matches `input/<slug>/` directory
- `attraction-name` — human-readable name used for GYG search query + match filtering

## Flow

1. **Collect known tour IDs** — scan `input/<slug>/homepage-config.json` and `input/<slug>/l1-config.json` for GYG tour IDs (regex: `t\d+` patterns from `id` and `url` fields)
2. **Fetch known tours** — `GET /1/tours/{id}?cnt_language=en&currency=EUR` for each known ID
3. **Search for more** — `GET /1/tours?q=<attraction>&cnt_language=en&currency=EUR&limit=50`
4. **Filter search results** — keep tours where title OR description contains any name variant (case-insensitive). Variants derived from input: e.g. "Opera Garnier" produces `["opera garnier", "palais garnier", "opéra garnier"]`. User can pass additional aliases via `--alias`.
5. **Deduplicate** — merge by tour_id, known IDs take priority
6. **Fetch reviews** — `GET /1/reviews/tour/{id}` for each tour, extract any image URLs if present
7. **Download** — fetch all image URLs (tour photos + review images)
8. **Convert** — JPG → PNG + WebP + AVIF (via Pillow). If AVIF unsupported, skip with warning.
9. **Write manifest** — `images/<slug>/manifest.json`

## API Details

- **Base URL:** `https://api.getyourguide.com/1`
- **Auth:** `X-ACCESS-TOKEN: {GYG_API_KEY}` header
- **Photo URLs:** contain `[format_id]` placeholder — replace with `100` for 2050x1066 hi-res
- **Rate limiting:** 300ms sleep between requests
- **Retry:** exponential backoff on 429/5xx (3 retries, 1.5s base)

## Output

```
auto-create-site/images/<slug>/
  manifest.json
  <tour-slug>-01.png
  <tour-slug>-01.webp
  <tour-slug>-01.avif   (if Pillow supports)
  <tour-slug>-02.png
  ...
```

### Tour slug derivation

From tour title: lowercase, strip non-alphanumeric, replace spaces with hyphens, truncate to 40 chars. E.g. "Opera Garnier Reserved Access Entrance Ticket" → `opera-garnier-reserved-access-entrance`.

### Manifest format

```json
{
  "attraction": "Opera Garnier",
  "slug": "opera-garnier",
  "fetched_at": "2026-04-05T14:30:00Z",
  "tours": [
    {
      "tour_id": "t81297",
      "title": "Opera Garnier Reserved Access Entrance Ticket",
      "url": "https://www.getyourguide.com/...",
      "rating": 4.6,
      "review_count": 523,
      "source": "known|search",
      "images": [
        {
          "original_url": "https://cdn.getyourguide.com/...",
          "type": "tour_photo|review_photo",
          "files": [
            "opera-garnier-reserved-access-entrance-01.png",
            "opera-garnier-reserved-access-entrance-01.webp",
            "opera-garnier-reserved-access-entrance-01.avif"
          ]
        }
      ]
    }
  ],
  "summary": {
    "tours_found": 8,
    "images_downloaded": 47,
    "formats": ["png", "webp", "avif"]
  }
}
```

## Tech

- **Language:** Python 3 (self-contained, no cross-project imports)
- **Dependencies:** `requests`, `Pillow` (both likely already installed)
- **AVIF:** Try `image.save(..., format='AVIF')`. If `KeyError`/`OSError`, disable AVIF for the run and warn.
- **Shell wrapper:** thin `fetch-gyg-images.sh` that loads `.env` for `GYG_API_KEY` and calls the Python script

## Matching logic

```python
name_variants = [attraction_name.lower()]
# Add known aliases
ALIASES = {
    "opera garnier": ["palais garnier", "opéra garnier"],
    "auschwitz": ["auschwitz-birkenau", "auschwitz birkenau"],
}
variants = name_variants + ALIASES.get(attraction_name.lower(), [])
text = (tour['title'] + ' ' + tour.get('description', '')).lower()
match = any(v in text for v in variants)
```

Additional aliases can be passed via `--alias "Palais Garnier" --alias "Opéra Garnier"`.

## Edge cases

- **Tour detail 404** — skip with warning, continue
- **No photos on tour** — include in manifest with empty images array
- **Duplicate images across tours** — download once, reference in both manifest entries (by URL dedup)
- **Existing images dir** — skip already-downloaded files (by filename check), re-download with `--force`
