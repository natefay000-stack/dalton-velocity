#!/usr/bin/env python3
"""Download an OpenStreetMap extract for the game via the Overpass API.

Standard library only.

    # by centre point + radius (metres)
    python3 tools/fetch_osm.py --center 40.7411 -73.9897 --radius 400

    # by bounding box: south west north east
    python3 tools/fetch_osm.py --bbox 40.737 -73.995 40.745 -73.984

Writes maps/neighborhood.osm by default, which the game loads automatically.
Map data (c) OpenStreetMap contributors, ODbL.
"""

from __future__ import annotations

import argparse
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ENDPOINTS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
)
USER_AGENT = "neighborhood-godot-game/0.1 (personal, non-commercial)"
# Overpass is a shared free service; keep requests neighbourhood-sized.
MAX_AREA_KM2 = 6.0
WARN_AREA_KM2 = 2.0
RETRYABLE_HTTP = {429, 502, 503, 504}

Bbox = tuple[float, float, float, float]  # south, west, north, east


def bbox_from_center(lat: float, lon: float, radius_m: float) -> Bbox:
    if radius_m <= 0:
        raise ValueError("radius must be positive")
    dlat = radius_m / 110_574.0
    cos_lat = math.cos(math.radians(lat))
    if cos_lat < 1e-6:
        raise ValueError("centre too close to a pole")
    dlon = radius_m / (111_320.0 * cos_lat)
    return (lat - dlat, lon - dlon, lat + dlat, lon + dlon)


def validate_bbox(bbox: Bbox) -> float:
    """Raise ValueError on a malformed bbox; return its area in km^2."""
    s, w, n, e = bbox
    if not (-90 <= s < n <= 90):
        raise ValueError(f"need -90 <= south < north <= 90, got south={s} north={n}")
    if not (-180 <= w < e <= 180):
        raise ValueError(
            f"need -180 <= west < east <= 180, got west={w} east={e} "
            "(boxes crossing the antimeridian are not supported)"
        )
    height_km = (n - s) * 110.574
    width_km = (e - w) * 111.320 * math.cos(math.radians((s + n) / 2))
    return height_km * width_km


def build_query(bbox: Bbox, timeout_s: int) -> str:
    s, w, n, e = bbox
    b = f"{s:.7f},{w:.7f},{n:.7f},{e:.7f}"
    # Only what the game renders; `>` pulls in the member nodes/ways.
    return f"""[out:xml][timeout:{timeout_s}];
(
  way["highway"]({b});
  way["building"]({b});
  way["building:part"]({b});
  way["landuse"]({b});
  way["leisure"]({b});
  way["natural"]({b});
  way["amenity"="parking"]({b});
  relation["building"]({b});
  relation["type"="multipolygon"]["landuse"]({b});
  relation["type"="multipolygon"]["leisure"]({b});
  relation["type"="multipolygon"]["natural"]({b});
);
(._;>;);
out body;
"""


def fetch(query: str, timeout_s: int, retries: int = 4) -> bytes:
    data = urllib.parse.urlencode({"data": query}).encode()
    last_err: str = "no attempt made"
    for attempt in range(retries):
        endpoint = ENDPOINTS[attempt % len(ENDPOINTS)]
        req = urllib.request.Request(endpoint, data=data, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=timeout_s + 30) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            body = exc.read(500).decode("utf-8", "replace")
            last_err = f"HTTP {exc.code} from {endpoint}: {body.strip()[:200]}"
            if exc.code not in RETRYABLE_HTTP:
                break
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last_err = f"{endpoint}: {exc}"
        if attempt == retries - 1:
            break
        wait = 2 ** (attempt + 1)
        print(f"  attempt {attempt + 1} failed ({last_err}); retrying in {wait}s", file=sys.stderr)
        time.sleep(wait)
    raise RuntimeError(f"Overpass request failed: {last_err}")


def check_response(payload: bytes) -> tuple[int, int]:
    """Return (node_count, way_count); raise ValueError if not usable OSM XML."""
    head = payload[:2000].decode("utf-8", "replace")
    if "<osm" not in head:
        raise ValueError(f"response is not OSM XML: {head[:200]!r}")
    if b"<remark>" in payload and b"runtime error" in payload:
        raise ValueError("Overpass returned a runtime error (area too large or server busy)")
    nodes = payload.count(b"<node ")
    ways = payload.count(b"<way ")
    if nodes == 0:
        raise ValueError("extract contains no nodes - is the bbox correct?")
    return nodes, ways


def with_bounds(payload: bytes, bbox: Bbox) -> bytes:
    """Overpass omits <bounds>; add it so the game centres the map on the bbox."""
    s, w, n, e = bbox
    tag = f'\n  <bounds minlat="{s:.7f}" minlon="{w:.7f}" maxlat="{n:.7f}" maxlon="{e:.7f}"/>'
    text = payload.decode("utf-8")
    start = text.find("<osm")
    end = text.find(">", start)
    if start < 0 or end < 0 or "<bounds" in text[:4000]:
        return payload
    return (text[: end + 1] + tag + text[end + 1 :]).encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--center", nargs=2, type=float, metavar=("LAT", "LON"))
    where.add_argument("--bbox", nargs=4, type=float, metavar=("SOUTH", "WEST", "NORTH", "EAST"))
    ap.add_argument("--radius", type=float, default=400.0, help="metres, with --center (default 400)")
    ap.add_argument("-o", "--output", type=Path,
                    default=Path(__file__).resolve().parent.parent / "maps" / "neighborhood.osm")
    ap.add_argument("--timeout", type=int, default=90, help="server-side timeout, seconds")
    ap.add_argument("--force", action="store_true", help=f"allow areas over {MAX_AREA_KM2} km^2")
    args = ap.parse_args(argv)

    try:
        bbox: Bbox = (bbox_from_center(*args.center, args.radius) if args.center
                      else tuple(args.bbox))  # type: ignore[assignment]
        area = validate_bbox(bbox)
    except ValueError as exc:
        ap.error(str(exc))
        return 2  # unreachable; ap.error exits

    if area > MAX_AREA_KM2 and not args.force:
        print(f"error: area is {area:.2f} km^2 (limit {MAX_AREA_KM2}). "
              "Shrink it or pass --force.", file=sys.stderr)
        return 2
    if area > WARN_AREA_KM2:
        print(f"warning: {area:.2f} km^2 is large; expect a slow download and load.", file=sys.stderr)

    print(f"Fetching {area:.2f} km^2: S{bbox[0]:.5f} W{bbox[1]:.5f} N{bbox[2]:.5f} E{bbox[3]:.5f}")
    try:
        payload = fetch(build_query(bbox, args.timeout), args.timeout)
        nodes, ways = check_response(payload)
    except (RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    tmp = args.output.with_suffix(".osm.part")
    tmp.write_bytes(with_bounds(payload, bbox))
    tmp.replace(args.output)  # atomic: never leave a half-written map behind
    print(f"Wrote {args.output} ({len(payload) / 1024:.0f} KiB, {nodes} nodes, {ways} ways)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
