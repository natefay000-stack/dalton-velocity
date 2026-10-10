#!/usr/bin/env python3
"""Fetch aerial imagery for a map and derive pools from it.

Pulls the USGS National Map orthophoto (public domain, no key) for the same
bbox as the map, mosaics it at about 0.6 m/pixel and writes:

    <map>.ortho.png    the photo (RGB)
    <map>.ortho.json   its bounds, so the game can drape it on the terrain

With --pools it also looks for swimming pools (blue blobs inside lots, away
from buildings and lakes) and appends them to <map>.osm as
leisure=swimming_pool ways.

    python3 tools/fetch_imagery.py game/maps/herriman.osm --pools

Standard library only. The .osm must exist (from fetch_overture.py); its
<bounds> element gives the area.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

EXPORT_URL = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/export"
METERS_PER_PX = 0.6
TILE_PX = 2048  # ArcGIS export limit is 4096; smaller requests are kinder
POOL_MIN_M2 = 14.0
POOL_MAX_M2 = 160.0


# --------------------------------------------------------------------------
# HTTP

def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


_SSL = _ssl_context()


def http_get(url: str, timeout: int = 180) -> bytes:
    last: Exception | None = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=timeout, context=_SSL) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504):
                raise
            last = exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last = exc
        time.sleep(2 ** attempt)
    raise RuntimeError(f"GET {url} failed: {last}")


# --------------------------------------------------------------------------
# PNG (decode + encode, 8-bit RGB/RGBA, non-interlaced)

def decode_png(data: bytes) -> tuple[int, int, int, bytearray]:
    """Returns (width, height, channels, unfiltered pixel rows concatenated)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat = 8, bytearray()
    width = height = channels = 0
    while pos < len(data):
        (length,) = struct.unpack_from(">I", data, pos)
        ctype = data[pos + 4: pos + 8]
        chunk = data[pos + 8: pos + 8 + length]
        if ctype == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or color not in (2, 6) or interlace:
                raise ValueError(f"unsupported PNG (depth={depth} color={color} interlace={interlace})")
            channels = 3 if color == 2 else 4
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * channels)
    prev = bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1: (y + 1) * (stride + 1)])
        if f == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        out[y * stride: (y + 1) * stride] = line
        prev = line
    return width, height, channels, out


def encode_png_rgb(width: int, height: int, rgb: bytes | bytearray) -> bytes:
    def chunk(t: bytes, d: bytes) -> bytes:
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride: (y + 1) * stride]
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


# --------------------------------------------------------------------------
# Imagery

Bbox = tuple[float, float, float, float]  # south, west, north, east


def read_bounds(osm_path: Path) -> Bbox:
    head = osm_path.read_text(encoding="utf-8")[:4000]
    m = re.search(r'<bounds minlat="([^"]+)" minlon="([^"]+)" maxlat="([^"]+)" maxlon="([^"]+)"', head)
    if not m:
        raise ValueError(f"{osm_path} has no <bounds>; re-run fetch_overture.py")
    s, w, n, e = (float(v) for v in m.groups())
    return s, w, n, e


def plan_grid(bbox: Bbox, meters_per_px: float) -> tuple[int, int, float, float]:
    """Total pixel size and metres-per-degree for the bbox."""
    s, w, n, e = bbox
    lat_m = 110_574.0
    lon_m = 111_320.0 * math.cos(math.radians((s + n) / 2))
    width = int(round((e - w) * lon_m / meters_per_px))
    height = int(round((n - s) * lat_m / meters_per_px))
    return width, height, lat_m, lon_m


def fetch_mosaic(bbox: Bbox, meters_per_px: float = METERS_PER_PX, tile_px: int = TILE_PX,
                 workers: int = 4) -> tuple[int, int, bytearray]:
    s, w, n, e = bbox
    width, height, _, _ = plan_grid(bbox, meters_per_px)
    cols = math.ceil(width / tile_px)
    rows = math.ceil(height / tile_px)
    out = bytearray(width * height * 3)
    jobs = []
    for r in rows_range(rows):
        for c in range(cols):
            x0 = c * tile_px
            y0 = r * tile_px
            tw = min(tile_px, width - x0)
            th = min(tile_px, height - y0)
            lon0 = w + (e - w) * x0 / width
            lon1 = w + (e - w) * (x0 + tw) / width
            lat1 = n - (n - s) * y0 / height
            lat0 = n - (n - s) * (y0 + th) / height
            jobs.append((x0, y0, tw, th, (lat0, lon0, lat1, lon1)))
    print(f"  imagery: {width}x{height} px in {len(jobs)} tiles", flush=True)

    def fetch(job):
        x0, y0, tw, th, (lat0, lon0, lat1, lon1) = job
        params = {
            "bbox": f"{lon0},{lat0},{lon1},{lat1}", "bboxSR": "4326", "imageSR": "4326",
            "size": f"{tw},{th}", "format": "png32", "f": "image",
        }
        png = http_get(EXPORT_URL + "?" + urllib.parse.urlencode(params))
        pw, ph, ch, px = decode_png(png)
        if (pw, ph) != (tw, th):
            raise RuntimeError(f"tile came back {pw}x{ph}, wanted {tw}x{th}")
        return x0, y0, tw, th, ch, px

    with ThreadPoolExecutor(workers) as pool:
        for x0, y0, tw, th, ch, px in pool.map(fetch, jobs):
            for y in range(th):
                src = px[y * tw * ch: (y + 1) * tw * ch]
                dst = ((y0 + y) * width + x0) * 3
                if ch == 3:
                    out[dst: dst + tw * 3] = src
                else:
                    for x in range(tw):
                        out[dst + x * 3: dst + x * 3 + 3] = src[x * 4: x * 4 + 3]
    return width, height, out


def rows_range(rows: int) -> range:
    return range(rows)


# --------------------------------------------------------------------------
# Pools

def is_pool_blue(r: int, g: int, b: int) -> bool:
    """Chlorinated water from above: blue/cyan, clearly bluer than red."""
    return b > 115 and b > r + 45 and g > r + 10 and b >= g - 20


def find_pools(width: int, height: int, rgb: bytes | bytearray, meters_per_px: float,
               min_m2: float = POOL_MIN_M2, max_m2: float = POOL_MAX_M2) -> list[tuple[float, float, float, float]]:
    """Connected blue blobs as pixel boxes (x0, y0, x1, y1), filtered by size
    and compactness."""
    mask = bytearray(width * height)
    for i in range(width * height):
        r, g, b = rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]
        if is_pool_blue(r, g, b):
            mask[i] = 1
    px_area = meters_per_px * meters_per_px
    min_px = int(min_m2 / px_area)
    max_px = int(max_m2 / px_area)
    seen = bytearray(width * height)
    pools = []
    for start in range(width * height):
        if not mask[start] or seen[start]:
            continue
        stack = [start]
        seen[start] = 1
        count = 0
        x0 = x1 = start % width
        y0 = y1 = start // width
        while stack:
            i = stack.pop()
            count += 1
            x, y = i % width, i // width
            x0, x1 = min(x0, x), max(x1, x)
            y0, y1 = min(y0, y), max(y1, y)
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if 0 <= nx < width and 0 <= ny < height:
                    j = ny * width + nx
                    if mask[j] and not seen[j]:
                        seen[j] = 1
                        stack.append(j)
        if count < min_px or count > max_px:
            continue
        box = (x1 - x0 + 1) * (y1 - y0 + 1)
        if count / box < 0.45:  # ragged: a stream, a shadow, a tarp edge
            continue
        pools.append((x0, y0, x1 + 1, y1 + 1))
    return pools


def point_in_ring(p: tuple[float, float], ring: list[tuple[float, float]]) -> bool:
    x, y = p
    inside = False
    for i in range(len(ring) - 1):
        (ax, ay), (bx, by) = ring[i], ring[i + 1]
        if (ay > y) != (by > y) and x < ax + (y - ay) / (by - ay) * (bx - ax):
            inside = not inside
    return inside


def osm_rings(osm_text: str, key: str, value: str | None = None) -> list[list[tuple[float, float]]]:
    """Closed ways with tag key(=value) as (lon, lat) rings."""
    nodes = {int(i): (float(lo), float(la)) for i, la, lo in
             re.findall(r'<node id="(\d+)" lat="([^"]+)" lon="([^"]+)"', osm_text)}
    rings = []
    for body in re.findall(r"<way id=\"\d+\">(.*?)</way>", osm_text, re.S):
        tags = dict(re.findall(r'<tag k="([^"]+)" v="([^"]*)"/>', body))
        if key not in tags or (value is not None and tags[key] != value):
            continue
        refs = [int(r) for r in re.findall(r'<nd ref="(\d+)"/>', body)]
        if len(refs) >= 4 and refs[0] == refs[-1] and all(r in nodes for r in refs):
            rings.append([nodes[r] for r in refs])
    return rings


def append_pools(osm_path: Path, pools_lonlat: list[list[tuple[float, float]]]) -> int:
    text = osm_path.read_text(encoding="utf-8")
    # Drop pools from an earlier run so this is repeatable.
    text = re.sub(r'  <way id="\d+">(?:(?!</way>).)*?<tag k="leisure" v="swimming_pool"/>.*?</way>\n', "", text, flags=re.S)
    text = re.sub(r'  <node id="\d+" lat="[^"]+" lon="[^"]+" pool="1"/>\n', "", text)
    ids = [int(i) for i in re.findall(r'<(?:node|way) id="(\d+)"', text)]
    next_id = max(ids) + 1 if ids else 1
    lines = []
    for ring in pools_lonlat:
        refs = []
        for lon, lat in ring:
            lines.append(f'  <node id="{next_id}" lat="{lat:.7f}" lon="{lon:.7f}" pool="1"/>')
            refs.append(next_id)
            next_id += 1
        refs.append(refs[0])
        lines.append(f'  <way id="{next_id}">')
        next_id += 1
        lines += [f'    <nd ref="{r}"/>' for r in refs]
        lines.append('    <tag k="leisure" v="swimming_pool"/>')
        lines.append("  </way>")
    text = text.replace("</osm>", "\n".join(lines) + "\n</osm>" if lines else "</osm>")
    osm_path.write_text(text, encoding="utf-8")
    return len(pools_lonlat)


def pools_to_rings(pools_px: list[tuple[float, float, float, float]], bbox: Bbox, width: int, height: int,
                   buildings: list[list[tuple[float, float]]], water: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    s, w, n, e = bbox
    rings = []
    for x0, y0, x1, y1 in pools_px:
        corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        ring = [(w + (e - w) * x / width, n - (n - s) * y / height) for x, y in corners]
        cx = sum(p[0] for p in ring) / 4
        cy = sum(p[1] for p in ring) / 4
        if any(point_in_ring((cx, cy), b) for b in buildings):
            continue  # a blue roof or tarp
        if any(point_in_ring((cx, cy), wr) for wr in water):
            continue  # part of a lake
        rings.append(ring)
    return rings


# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("osm", type=Path, help="the map's .osm (bounds are read from it)")
    ap.add_argument("--meters-per-px", type=float, default=METERS_PER_PX)
    ap.add_argument("--pools", action="store_true", help="detect pools and add them to the .osm")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args(argv)

    if not args.osm.exists():
        print(f"error: {args.osm} not found", file=sys.stderr)
        return 2
    try:
        bbox = read_bounds(args.osm)
        width, height, rgb = fetch_mosaic(bbox, args.meters_per_px, workers=args.workers)
    except (RuntimeError, ValueError, urllib.error.URLError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    png_path = args.osm.with_suffix(".ortho.png")
    tmp = png_path.with_suffix(".png.part")
    tmp.write_bytes(encode_png_rgb(width, height, rgb))
    tmp.replace(png_path)
    meta = {"south": bbox[0], "west": bbox[1], "north": bbox[2], "east": bbox[3],
            "width": width, "height": height, "meters_per_px": args.meters_per_px,
            "source": "USGS National Map (USGSImageryOnly), public domain"}
    args.osm.with_suffix(".ortho.json").write_text(json.dumps(meta, indent=1))
    print(f"Wrote {png_path} ({width}x{height}, {png_path.stat().st_size / 1e6:.1f} MB)")

    if args.pools:
        text = args.osm.read_text(encoding="utf-8")
        buildings = osm_rings(text, "building")
        water = osm_rings(text, "natural", "water")
        boxes = find_pools(width, height, rgb, args.meters_per_px)
        rings = pools_to_rings(boxes, bbox, width, height, buildings, water)
        n = append_pools(args.osm, rings)
        print(f"Pools: {len(boxes)} blue blobs, {n} kept and written to {args.osm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
