#!/usr/bin/env python3
"""
Fetch GYG tour images for an attraction, convert to png/webp/avif, write manifest.

Usage:
    python3 fetch-gyg-images.py <site-slug> "<attraction-name>" [--alias "Name"] [--force]
"""

import argparse, json, os, re, sys, time, hashlib
from datetime import datetime, timezone
from pathlib import Path
from io import BytesIO
from urllib.parse import urlparse

import requests
from PIL import Image

# ── AVIF support detection ──────────────────────────────────────────────────
AVIF_OK = False
try:
    import pillow_avif  # noqa: F401
    _t = Image.new("RGB", (1, 1))
    _b = BytesIO()
    _t.save(_b, format="AVIF")
    AVIF_OK = True
except Exception:
    pass

# ── Constants ───────────────────────────────────────────────────────────────
API_BASE = "https://api.getyourguide.com/1"
PHOTO_FORMAT_ID = "100"  # 2050x1066 hi-res
RATE_LIMIT_SLEEP = 0.3
RETRY_BASE = 1.5
MAX_RETRIES = 3
RETRYABLE = {429, 500, 502, 503, 504}

KNOWN_ALIASES = {
    "opera garnier": ["palais garnier", "opéra garnier"],
    "auschwitz": ["auschwitz-birkenau", "auschwitz birkenau"],
    "mont-saint-michel": ["mont saint michel", "le mont-saint-michel", "abbey mont-saint-michel"],
}


# ── API helpers ─────────────────────────────────────────────────────────────
def api_get(path: str, params: dict | None = None) -> dict | None:
    """GET from GYG API with retry + rate limiting."""
    api_key = os.environ.get("GYG_API_KEY", "")
    headers = {"X-ACCESS-TOKEN": api_key, "Accept": "application/json"}
    url = f"{API_BASE}{path}"

    for attempt in range(MAX_RETRIES + 1):
        try:
            time.sleep(RATE_LIMIT_SLEEP)
            r = requests.get(url, headers=headers, params=params, timeout=45)
            if r.status_code == 200:
                return r.json()
            if r.status_code in RETRYABLE and attempt < MAX_RETRIES:
                wait = RETRY_BASE * (2 ** attempt)
                print(f"    HTTP {r.status_code}, retry in {wait:.1f}s...")
                time.sleep(wait)
                continue
            print(f"    HTTP {r.status_code} for {path} — skipping")
            return None
        except requests.RequestException as e:
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BASE * (2 ** attempt))
                continue
            print(f"    Request failed for {path}: {e}")
            return None
    return None


def fetch_tour(tour_id: str) -> dict | None:
    """Fetch a single tour by numeric ID."""
    data = api_get(f"/tours/{tour_id}", {"cnt_language": "en", "currency": "EUR", "preformatted": "full"})
    if not data or "data" not in data:
        return None
    d = data["data"]
    if "tours" in d and d["tours"]:
        return d["tours"][0]
    if "tour" in d:
        return d["tour"]
    return None


def search_tours(query: str) -> list[dict]:
    """Search tours by query string."""
    data = api_get("/tours", {
        "q": query,
        "cnt_language": "en",
        "currency": "EUR",
        "limit": 50,
        "preformatted": "full",
    })
    if data and "data" in data and "tours" in data["data"]:
        return data["data"]["tours"]
    return []


def fetch_reviews(tour_id: str) -> list[dict]:
    """Fetch reviews for a tour."""
    data = api_get(f"/reviews/tour/{tour_id}")
    if not data or "data" not in data:
        return []
    reviews_data = data["data"]
    if isinstance(reviews_data, dict) and "reviews" in reviews_data:
        reviews_data = reviews_data["reviews"]
    if isinstance(reviews_data, dict) and "review_items" in reviews_data:
        return reviews_data["review_items"]
    if isinstance(reviews_data, list):
        return reviews_data
    return []


# ── Photo URL helpers ───────────────────────────────────────────────────────
def resolve_photo_url(url: str) -> str:
    return url.replace("[format_id]", PHOTO_FORMAT_ID)


def extract_photo_urls(tour: dict) -> list[str]:
    urls = []
    for pic in tour.get("pictures") or []:
        u = pic.get("ssl_url") or pic.get("url") or ""
        if u:
            urls.append(resolve_photo_url(u))
    return urls


def extract_review_image_urls(reviews: list[dict]) -> list[str]:
    urls = []
    for rev in reviews:
        for key in ("photos", "images", "pictures", "media"):
            for item in rev.get(key) or []:
                if isinstance(item, str):
                    urls.append(item)
                elif isinstance(item, dict):
                    u = item.get("url") or item.get("ssl_url") or item.get("src") or ""
                    if u:
                        urls.append(u)
    return urls


# ── Slug / naming helpers ──────────────────────────────────────────────────
def slugify(text: str, max_len: int = 40) -> str:
    s = text.lower()
    s = re.sub(r"[^a-z0-9\s-]", "", s)
    s = re.sub(r"[\s-]+", "-", s).strip("-")
    return s[:max_len].rstrip("-")


# ── Collect known tour IDs from config files ────────────────────────────────
def collect_known_ids(input_dir: Path) -> list[str]:
    ids = set()
    for fname in ["homepage-config.json", "l1-config.json"]:
        fp = input_dir / fname
        if not fp.exists():
            continue
        text = fp.read_text()
        # Match GYG tour IDs: tNNNNN in URLs or id fields
        for m in re.finditer(r'\bt(\d{4,})', text):
            ids.add(m.group(1))
    return sorted(ids)


# ── Matching logic ──────────────────────────────────────────────────────────
def matches_attraction(tour: dict, variants: list[str]) -> bool:
    text = (
        (tour.get("title") or "")
        + " "
        + (tour.get("abstract") or "")
        + " "
        + (tour.get("description") or "")
    ).lower()
    return any(v in text for v in variants)


# ── Image download + convert ────────────────────────────────────────────────
def download_and_convert(
    url: str, base_path: Path, base_name: str, formats: list[str]
) -> list[str]:
    """Download image URL and save as multiple formats. Returns list of filenames."""
    try:
        time.sleep(RATE_LIMIT_SLEEP)
        r = requests.get(url, timeout=60)
        if r.status_code != 200:
            print(f"    Failed to download {url} (HTTP {r.status_code})")
            return []
        img = Image.open(BytesIO(r.content))
        if img.mode in ("RGBA", "P"):
            img = img.convert("RGB")
    except Exception as e:
        print(f"    Failed to process {url}: {e}")
        return []

    saved = []
    for fmt in formats:
        ext = fmt.lower()
        fmt_dir = base_path / ext
        fmt_dir.mkdir(exist_ok=True)
        fname = f"{ext}/{base_name}.{ext}"
        fpath = base_path / fname
        try:
            save_kwargs = {}
            if ext == "webp":
                save_kwargs = {"quality": 85}
            elif ext == "avif":
                save_kwargs = {"quality": 75}
            img.save(str(fpath), format=fmt.upper(), **save_kwargs)
            saved.append(fname)
        except Exception as e:
            print(f"    Could not save {fname}: {e}")
    return saved


# ── Main ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Fetch GYG tour images for an attraction")
    parser.add_argument("site_slug", help="Site slug (e.g. opera-garnier)")
    parser.add_argument("attraction_name", help="Attraction name for search + matching")
    parser.add_argument("--alias", action="append", default=[], help="Additional name variants")
    parser.add_argument("--force", action="store_true", help="Re-download existing images")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    input_dir = repo_root / "input" / args.site_slug
    images_dir = repo_root / "images" / args.site_slug
    manifest_path = images_dir / "manifest.json"

    if not input_dir.exists():
        print(f"Error: input directory not found: {input_dir}")
        sys.exit(1)

    images_dir.mkdir(parents=True, exist_ok=True)

    # Build name variants
    base = args.attraction_name.lower()
    variants = [base] + [a.lower() for a in args.alias]
    variants += KNOWN_ALIASES.get(base, [])
    variants = list(dict.fromkeys(variants))  # dedupe preserving order

    # Determine output formats (no PNG — only webp + avif)
    formats = ["webp"]
    if AVIF_OK:
        formats.append("avif")
    else:
        print("  Note: AVIF not supported by Pillow, skipping AVIF output")

    print("=" * 65)
    print(f"  Fetch GYG Images — {args.site_slug}")
    print(f"  Attraction: {args.attraction_name}")
    print(f"  Variants:   {variants}")
    print(f"  Formats:    {formats}")
    print(f"  Output:     {images_dir}")
    print("=" * 65)

    # Step 1: Collect known tour IDs
    known_ids = collect_known_ids(input_dir)
    print(f"\n  Known GYG tour IDs from config: {known_ids or 'none'}")

    # Step 2: Fetch known tours
    tours_by_id: dict[str, dict] = {}
    tour_sources: dict[str, str] = {}

    if known_ids:
        print(f"\n── Fetching {len(known_ids)} known tours ──")
        for tid in known_ids:
            print(f"  Fetching tour {tid}...", end=" ")
            tour = fetch_tour(tid)
            if tour:
                tours_by_id[str(tour.get("tour_id", tid))] = tour
                tour_sources[str(tour.get("tour_id", tid))] = "known"
                print(f"✓ {tour.get('title', '?')}")
            else:
                print("✗ not found")

    # Step 3: Search for more tours
    print(f"\n── Searching GYG for \"{args.attraction_name}\" ──")
    search_results = search_tours(args.attraction_name)
    print(f"  Found {len(search_results)} results")

    # Step 4: Filter by name match
    matched = 0
    for tour in search_results:
        tid = str(tour.get("tour_id", ""))
        if tid in tours_by_id:
            continue  # already have it from known IDs
        if matches_attraction(tour, variants):
            tours_by_id[tid] = tour
            tour_sources[tid] = "search"
            matched += 1
            print(f"  ✓ {tour.get('title', '?')}")
        else:
            print(f"  ✗ skipped: {tour.get('title', '?')}")
    print(f"  Matched {matched} new tours from search")

    if not tours_by_id:
        print("\n  No tours found. Check attraction name or API key.")
        sys.exit(1)

    print(f"\n  Total tours: {len(tours_by_id)}")

    # Step 5: Download images for each tour
    print(f"\n── Downloading images ──")
    manifest_tours = []
    total_images = 0
    seen_urls: dict[str, str] = {}  # url -> base_name for dedup

    for tid, tour in tours_by_id.items():
        title = tour.get("title") or f"tour-{tid}"
        tour_slug = f"{slugify(title)}-{tid}"
        rating = tour.get("overall_rating") or tour.get("rating") or 0
        review_count = tour.get("number_of_ratings") or tour.get("review_count") or 0
        tour_url = tour.get("url") or f"https://www.getyourguide.com/p/{tid}"

        print(f"\n  [{tid}] {title}")

        # Collect all image URLs
        photo_urls = extract_photo_urls(tour)
        print(f"    Tour photos: {len(photo_urls)}")

        # Fetch reviews for possible images
        reviews = fetch_reviews(tid)
        review_img_urls = extract_review_image_urls(reviews)
        if review_img_urls:
            print(f"    Review images: {len(review_img_urls)}")

        # Build image entries
        all_images = (
            [(u, "tour_photo") for u in photo_urls]
            + [(u, "review_photo") for u in review_img_urls]
        )

        image_entries = []
        idx = 0
        for url, img_type in all_images:
            idx += 1
            base_name = f"{tour_slug}-{idx:02d}"

            # Dedup by URL
            url_hash = hashlib.md5(url.encode()).hexdigest()
            if url_hash in seen_urls:
                # Reference existing files
                existing_base = seen_urls[url_hash]
                files = [f"{fmt}/{existing_base}.{fmt}" for fmt in formats
                         if (images_dir / fmt / f"{existing_base}.{fmt}").exists()]
                if files:
                    image_entries.append({
                        "original_url": url,
                        "type": img_type,
                        "files": files,
                    })
                    continue

            # Skip if exists and not --force
            existing_files = [f for fmt in formats
                              if (f := f"{fmt}/{base_name}.{fmt}") and (images_dir / f).exists()]
            if existing_files and not args.force:
                print(f"    {base_name}: exists, skipping")
                seen_urls[url_hash] = base_name
                image_entries.append({
                    "original_url": url,
                    "type": img_type,
                    "files": existing_files,
                })
                total_images += 1
                continue

            # Download and convert
            files = download_and_convert(url, images_dir, base_name, formats)
            if files:
                seen_urls[url_hash] = base_name
                image_entries.append({
                    "original_url": url,
                    "type": img_type,
                    "files": files,
                })
                total_images += 1
                print(f"    ✓ {base_name} ({len(files)} formats)")
            else:
                print(f"    ✗ {base_name}: download failed")

        manifest_tours.append({
            "tour_id": f"t{tid}",
            "title": title,
            "url": tour_url,
            "rating": rating,
            "review_count": review_count,
            "source": tour_sources.get(tid, "unknown"),
            "images": image_entries,
        })

    # Step 6: Write manifest
    manifest = {
        "attraction": args.attraction_name,
        "slug": args.site_slug,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "tours": manifest_tours,
        "summary": {
            "tours_found": len(manifest_tours),
            "images_downloaded": total_images,
            "formats": formats,
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False))

    print(f"\n{'=' * 65}")
    print(f"  Done — {args.site_slug}")
    print(f"  Tours: {len(manifest_tours)}")
    print(f"  Images: {total_images}")
    print(f"  Formats: {', '.join(formats)}")
    print(f"  Manifest: {manifest_path}")
    print(f"{'=' * 65}")


if __name__ == "__main__":
    main()
