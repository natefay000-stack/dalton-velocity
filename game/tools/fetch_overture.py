#!/usr/bin/env python3
"""Build a game map from Overture Maps data plus terrain elevation.

Use this when the Overpass API is unreachable or too sparse. Overture's
roads and water come from OpenStreetMap; its buildings merge OSM with
Microsoft/Google ML footprints, so suburbs are usually far more complete.

    pip install pyarrow          # only dependency, for reading GeoParquet
    python3 tools/fetch_overture.py --bbox 40.470 -112.032 40.489 -112.006 -o maps/herriman.osm

Writes:
  <out>.osm     roads, buildings, water, parks/land use as OSM XML (what the
                game's loader already reads)
  <out>.height  terrain grid from AWS Terrain Tiles (Mapzen terrarium,
                ~3-10 m source data in the US); skip with --no-terrain

Data: (c) OpenStreetMap contributors (ODbL), Overture Maps Foundation,
Microsoft & Google building footprints (ODbL/CDLA). Terrain: AWS Open Data
Terrain Tiles (USGS 3DEP and others).
"""

from __future__ import annotations

import argparse
import io
import math
import re
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Iterable
from xml.sax.saxutils import quoteattr

try:
    import pyarrow.parquet as pq
except ImportError:  # pragma: no cover - exercised manually
    pq = None

BUCKET = "https://overturemaps-us-west-2.s3.amazonaws.com"
TERRAIN_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
TERRAIN_ZOOM = 15
MAX_AREA_KM2 = 12.0
WORKERS = 24

Bbox = tuple[float, float, float, float]  # south, west, north, east

# Overture segment class -> OSM highway value the game understands.
ROAD_CLASSES = {
    "motorway": "motorway", "trunk": "trunk", "primary": "primary",
    "secondary": "secondary", "tertiary": "tertiary", "residential": "residential",
    "living_street": "living_street", "unclassified": "unclassified",
    "unknown": "unclassified", "service": "service", "pedestrian": "pedestrian",
    "footway": "footway", "sidewalk": "footway", "crosswalk": "footway",
    "steps": "steps", "path": "path", "track": "track", "cycleway": "cycleway",
    "bridleway": "path",
}
# Overture land_use class -> (OSM key, value).
LAND_USE = {
    "park": ("leisure", "park"), "playground": ("leisure", "playground"),
    "pitch": ("leisure", "pitch"), "golf_course": ("leisure", "golf_course"),
    "grass": ("landuse", "grass"), "meadow": ("landuse", "meadow"),
    "recreation_ground": ("landuse", "recreation_ground"),
    "residential": ("landuse", "residential"), "commercial": ("landuse", "commercial"),
    "retail": ("landuse", "retail"), "school": ("amenity", "school"),
    "cemetery": ("landuse", "cemetery"), "forest": ("landuse", "forest"),
    "parking": ("amenity", "parking"),
}


# --------------------------------------------------------------------------
# HTTP

def http_get(url: str, headers: dict[str, str] | None = None, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers=headers or {})
    last: Exception | None = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504):
                raise
            last = exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last = exc
        time.sleep(2 ** attempt)
    raise RuntimeError(f"GET {url} failed: {last}")


class HttpRangeFile(io.RawIOBase):
    """Seekable read-only file over HTTP range requests (for ParquetFile)."""

    def __init__(self, url: str, size: int) -> None:
        super().__init__()
        self.url = url
        self.size = size
        self.pos = 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, offset: int, whence: int = 0) -> int:
        base = {0: 0, 1: self.pos, 2: self.size}[whence]
        self.pos = max(0, base + offset)
        return self.pos

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.size, self.pos + n) - 1
        data = http_get(self.url, {"Range": f"bytes={self.pos}-{end}"})
        self.pos += len(data)
        return data

    def readinto(self, buf: Any) -> int:
        data = self.read(len(buf))
        buf[: len(data)] = data
        return len(data)


def latest_release() -> str:
    xml = http_get(f"{BUCKET}/?list-type=2&prefix=release/&delimiter=/").decode()
    releases = sorted(re.findall(r"<Prefix>release/([^<]+)/</Prefix>", xml))
    if not releases:
        raise RuntimeError("could not list Overture releases")
    return releases[-1]


def list_files(release: str, theme_type: str) -> list[tuple[str, int]]:
    out: list[tuple[str, int]] = []
    token = ""
    while True:
        url = f"{BUCKET}/?list-type=2&prefix=release/{release}/{theme_type}/"
        if token:
            url += "&continuation-token=" + urllib.request.quote(token, safe="")
        xml = http_get(url).decode()
        for key, size in re.findall(r"<Key>([^<]+)</Key>.*?<Size>(\d+)</Size>", xml, re.S):
            if key.endswith(".parquet"):
                out.append((key, int(size)))
        m = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", xml)
        if not m:
            return out
        token = m.group(1)


# --------------------------------------------------------------------------
# Overture GeoParquet

def _overlaps(stats: dict[str, Any], bbox: Bbox) -> bool:
    s, w, n, e = bbox
    try:
        return (stats["bbox.xmin"].min <= e and stats["bbox.xmax"].max >= w
                and stats["bbox.ymin"].min <= n and stats["bbox.ymax"].max >= s)
    except (AttributeError, TypeError):
        return True  # no statistics: can't rule it out


def _scan_file(key: str, size: int, bbox: Bbox) -> tuple[str, int, list[int]]:
    pf = pq.ParquetFile(HttpRangeFile(f"{BUCKET}/{key}", size))
    md = pf.metadata
    paths = [md.schema.column(i).path for i in range(md.num_columns)]
    cols = {p: paths.index(p) for p in ("bbox.xmin", "bbox.xmax", "bbox.ymin", "bbox.ymax") if p in paths}
    groups = []
    for g in range(md.num_row_groups):
        rg = md.row_group(g)
        stats = {p: rg.column(i).statistics for p, i in cols.items()}
        if len(stats) < 4 or _overlaps(stats, bbox):
            groups.append(g)
    return key, size, groups


def read_features(release: str, theme_type: str, bbox: Bbox, columns: list[str]) -> list[dict[str, Any]]:
    """Rows of one Overture type whose bbox intersects ours."""
    files = list_files(release, theme_type)
    if not files:
        raise RuntimeError(f"no files for {theme_type} in release {release}")
    print(f"  {theme_type}: scanning {len(files)} file footers", flush=True)
    with ThreadPoolExecutor(WORKERS) as pool:
        scans = list(pool.map(lambda f: _scan_file(f[0], f[1], bbox), files))
    hits = [(k, size, g) for k, size, g in scans if g]
    s, w, n, e = bbox
    rows: list[dict[str, Any]] = []
    for key, size, groups in hits:
        pf = pq.ParquetFile(HttpRangeFile(f"{BUCKET}/{key}", size))
        available = set(pf.schema_arrow.names)
        table = pf.read_row_groups(groups, columns=[c for c in columns if c in available])
        for row in table.to_pylist():
            b = row.get("bbox") or {}
            if b and (b["xmin"] > e or b["xmax"] < w or b["ymin"] > n or b["ymax"] < s):
                continue
            rows.append(row)
    print(f"  {theme_type}: {len(rows)} features from {sum(len(g) for _, _, g in hits)} row groups", flush=True)
    return rows


# --------------------------------------------------------------------------
# WKB

def parse_wkb(data: bytes) -> tuple[str, list]:
    """Minimal WKB reader: Point/LineString/Polygon and their Multi* forms.

    Returns (kind, parts) where kind is "line" (parts = list of coord lists)
    or "polygon" (parts = list of rings-lists; ring 0 is the outer ring).
    """
    view = memoryview(data)

    def read(off: int) -> tuple[str, list, int]:
        order = "<" if view[off] == 1 else ">"
        (gtype,) = struct.unpack_from(order + "I", view, off + 1)
        off += 5
        gtype %= 1000  # drop Z/M flags (ISO WKB)
        if gtype == 1:
            return "point", [], off + 16
        if gtype == 2:
            (n,) = struct.unpack_from(order + "I", view, off)
            off += 4
            pts = [struct.unpack_from(order + "dd", view, off + 16 * i) for i in range(n)]
            return "line", [pts], off + 16 * n
        if gtype == 3:
            (nr,) = struct.unpack_from(order + "I", view, off)
            off += 4
            rings = []
            for _ in range(nr):
                (n,) = struct.unpack_from(order + "I", view, off)
                off += 4
                rings.append([struct.unpack_from(order + "dd", view, off + 16 * i) for i in range(n)])
                off += 16 * n
            return "polygon", [rings], off
        if gtype in (4, 5, 6):
            (count,) = struct.unpack_from(order + "I", view, off)
            off += 4
            kind = "point"
            parts: list = []
            for _ in range(count):
                kind, sub, off = read(off)
                parts.extend(sub)
            return kind, parts, off
        raise ValueError(f"unsupported WKB geometry type {gtype}")

    kind, parts, _ = read(0)
    return kind, parts


# --------------------------------------------------------------------------
# Clipping to the bbox (lon/lat space)

Coord = tuple[float, float]


def clip_line(pts: list[Coord], bbox: Bbox) -> list[list[Coord]]:
    """Clip a polyline to the bbox (Liang-Barsky per segment); returns pieces."""
    s, w, n, e = bbox
    pieces: list[list[Coord]] = []
    cur: list[Coord] = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        t0, t1 = 0.0, 1.0
        dx, dy = x1 - x0, y1 - y0
        ok = True
        for p, q in ((-dx, x0 - w), (dx, e - x0), (-dy, y0 - s), (dy, n - y0)):
            if p == 0:
                if q < 0:
                    ok = False
                    break
                continue
            r = q / p
            if p < 0:
                t0 = max(t0, r)
            else:
                t1 = min(t1, r)
            if t0 > t1:
                ok = False
                break
        if not ok:
            if len(cur) >= 2:
                pieces.append(cur)
            cur = []
            continue
        a = (x0 + t0 * dx, y0 + t0 * dy)
        b = (x0 + t1 * dx, y0 + t1 * dy)
        if not cur or cur[-1] != a:
            if len(cur) >= 2:
                pieces.append(cur)
            cur = [a]
        cur.append(b)
        if t1 < 1.0:
            pieces.append(cur)
            cur = []
    if len(cur) >= 2:
        pieces.append(cur)
    return pieces


def clip_ring(ring: list[Coord], bbox: Bbox) -> list[Coord]:
    """Sutherland-Hodgman clip of a ring to the bbox. Returns [] if outside."""
    s, w, n, e = bbox
    edges = (
        (lambda p: p[0] >= w, lambda a, b: (w, a[1] + (w - a[0]) * (b[1] - a[1]) / (b[0] - a[0]))),
        (lambda p: p[0] <= e, lambda a, b: (e, a[1] + (e - a[0]) * (b[1] - a[1]) / (b[0] - a[0]))),
        (lambda p: p[1] >= s, lambda a, b: (a[0] + (s - a[1]) * (b[0] - a[0]) / (b[1] - a[1]), s)),
        (lambda p: p[1] <= n, lambda a, b: (a[0] + (n - a[1]) * (b[0] - a[0]) / (b[1] - a[1]), n)),
    )
    out = ring[:-1] if len(ring) > 1 and ring[0] == ring[-1] else list(ring)
    for inside, cross in edges:
        if not out:
            return []
        src, out = out, []
        for i, cur in enumerate(src):
            prev = src[i - 1]
            if inside(cur):
                if not inside(prev):
                    out.append(cross(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(cross(prev, cur))
    return out + out[:1] if len(out) >= 3 else []


# --------------------------------------------------------------------------
# OSM XML output

class OsmWriter:
    def __init__(self) -> None:
        self.nodes: dict[tuple[int, int], int] = {}
        self.node_list: list[tuple[int, float, float]] = []
        self.ways: list[tuple[int, list[int], dict[str, str]]] = []

    def node(self, lon: float, lat: float) -> int:
        key = (round(lon * 1e7), round(lat * 1e7))  # shared vertices -> shared node
        nid = self.nodes.get(key)
        if nid is None:
            nid = len(self.node_list) + 1
            self.nodes[key] = nid
            self.node_list.append((nid, lat, lon))
        return nid

    def way(self, coords: Iterable[tuple[float, float]], tags: dict[str, str], closed: bool = False) -> None:
        refs: list[int] = []
        for lon, lat in coords:
            nid = self.node(lon, lat)
            if not refs or refs[-1] != nid:
                refs.append(nid)
        if closed and refs and refs[0] != refs[-1]:
            refs.append(refs[0])
        if len(refs) >= (4 if closed else 2):
            self.ways.append((len(self.ways) + 1, refs, tags))

    def write(self, path: Path, bbox: Bbox, generator: str) -> None:
        s, w, n, e = bbox
        lines = ['<?xml version="1.0" encoding="UTF-8"?>',
                 f'<osm version="0.6" generator={quoteattr(generator)}>',
                 f'  <bounds minlat="{s:.7f}" minlon="{w:.7f}" maxlat="{n:.7f}" maxlon="{e:.7f}"/>']
        lines += [f'  <node id="{i}" lat="{la:.7f}" lon="{lo:.7f}"/>' for i, la, lo in self.node_list]
        for wid, refs, tags in self.ways:
            lines.append(f'  <way id="{wid}">')
            lines += [f'    <nd ref="{r}"/>' for r in refs]
            lines += [f"    <tag k={quoteattr(k)} v={quoteattr(v)}/>" for k, v in tags.items()]
            lines.append("  </way>")
        lines.append("</osm>")
        tmp = path.with_suffix(path.suffix + ".part")
        tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
        tmp.replace(path)


def _name(row: dict[str, Any]) -> str:
    names = row.get("names") or {}
    return (names.get("primary") or "") if isinstance(names, dict) else ""


def add_roads(osm: OsmWriter, rows: list[dict[str, Any]], bbox: Bbox) -> int:
    count = 0
    for row in rows:
        if row.get("subtype") != "road" or not row.get("geometry"):
            continue
        cls = row.get("class") or "unknown"
        highway = ROAD_CLASSES.get(row.get("subclass") or "", None) or ROAD_CLASSES.get(cls)
        if highway is None:
            continue
        if row.get("subclass") in ("driveway", "parking_aisle", "alley"):
            highway = "service"
        kind, parts = parse_wkb(row["geometry"])
        if kind != "line":
            continue
        tags = {"highway": highway}
        if _name(row):
            tags["name"] = _name(row)
        for part in parts:
            for piece in clip_line(part, bbox):
                osm.way(piece, tags)
                count += 1
    return count


def _num(value: Any) -> float | None:
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) and v > 0 else None


def add_buildings(osm: OsmWriter, rows: list[dict[str, Any]], bbox: Bbox) -> int:
    s, w, n, e = bbox
    count = 0
    for row in rows:
        if not row.get("geometry"):
            continue
        kind, parts = parse_wkb(row["geometry"])
        if kind != "polygon":
            continue
        tags = {"building": row.get("class") or row.get("subtype") or "yes"}
        if (h := _num(row.get("height"))) is not None:
            tags["height"] = f"{h:.1f}"
        if (f := _num(row.get("num_floors"))) is not None:
            tags["building:levels"] = str(int(f))
        if (mh := _num(row.get("min_height"))) is not None:
            tags["min_height"] = f"{mh:.1f}"
        for rings in parts:
            outer = rings[0]
            cx = sum(p[0] for p in outer) / len(outer)
            cy = sum(p[1] for p in outer) / len(outer)
            if w <= cx <= e and s <= cy <= n:  # keep whole houses, not slices
                osm.way(outer, tags, closed=True)
                count += 1
    return count


def add_areas(osm: OsmWriter, rows: list[dict[str, Any]], water: bool, bbox: Bbox) -> int:
    count = 0
    for row in rows:
        if not row.get("geometry"):
            continue
        if water:
            tag = ("natural", "water")
        else:
            tag = LAND_USE.get(row.get("class") or "") or LAND_USE.get(row.get("subtype") or "")
            if tag is None:
                continue
        kind, parts = parse_wkb(row["geometry"])
        if kind != "polygon":
            continue
        tags = {tag[0]: tag[1]}
        if _name(row):
            tags["name"] = _name(row)
        for rings in parts:
            ring = clip_ring(rings[0], bbox)
            if ring:
                osm.way(ring, tags, closed=True)
                count += 1
    return count


# --------------------------------------------------------------------------
# Terrain (terrarium PNG tiles)

def decode_png_rgb(data: bytes) -> tuple[int, int, list[bytes]]:
    """Decode an 8-bit RGB/RGBA non-interlaced PNG. Returns (w, h, rows)."""
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
    rows: list[bytes] = []
    prev = bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1: (y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xFF
            elif f == 2:
                line[i] = (line[i] + b) & 0xFF
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        rows.append(bytes(line))
        prev = line
    return width, height, [bytes(r[i] for i in range(len(r)) if i % channels < 3) for r in rows] if channels == 4 else rows


def _tile_xy(lat: float, lon: float, z: int) -> tuple[float, float]:
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def fetch_terrain(bbox: Bbox, spacing_m: float, path: Path) -> tuple[int, int, float, float]:
    """Sample terrain on a regular lat/lon grid covering bbox; write .height.

    File layout (little-endian): b"HGT1", south, west, north, east (float64),
    cols, rows (int32), then rows*cols float32 metres, row 0 = north edge.
    """
    s, w, n, e = bbox
    z = TERRAIN_ZOOM
    x0, y0 = _tile_xy(n, w, z)
    x1, y1 = _tile_xy(s, e, z)
    tiles: dict[tuple[int, int], list[bytes]] = {}
    # Pad by a pixel so bilinear sampling at the edges has its neighbours.
    pad = 2.0 / 256.0
    coords = [(tx, ty) for tx in range(int(x0 - pad), int(x1 + pad) + 1)
              for ty in range(int(y0 - pad), int(y1 + pad) + 1)]
    print(f"  terrain: {len(coords)} tiles at z{z}", flush=True)

    def load(c: tuple[int, int]) -> tuple[tuple[int, int], list[bytes]]:
        png = http_get(TERRAIN_URL.format(z=z, x=c[0], y=c[1]))
        return c, decode_png_rgb(png)[2]

    with ThreadPoolExecutor(8) as pool:
        tiles.update(pool.map(load, coords))

    def elev_px(px: int, py: int) -> float:
        row = tiles[(px // 256, py // 256)][py % 256]
        i = (px % 256) * 3
        return row[i] * 256.0 + row[i + 1] + row[i + 2] / 256.0 - 32768.0

    lat_m = 110_574.0
    lon_m = 111_320.0 * math.cos(math.radians((s + n) / 2))
    cols = max(2, int(round((e - w) * lon_m / spacing_m)) + 1)
    rows = max(2, int(round((n - s) * lat_m / spacing_m)) + 1)
    out = bytearray(b"HGT1" + struct.pack("<4d2i", s, w, n, e, cols, rows))
    lo, hi = math.inf, -math.inf
    for r in range(rows):
        lat = n - (n - s) * r / (rows - 1)
        for c in range(cols):
            lon = w + (e - w) * c / (cols - 1)
            fx, fy = _tile_xy(lat, lon, z)
            fx, fy = fx * 256 - 0.5, fy * 256 - 0.5
            ix, iy = int(math.floor(fx)), int(math.floor(fy))
            tx, ty = fx - ix, fy - iy
            h = ((elev_px(ix, iy) * (1 - tx) + elev_px(ix + 1, iy) * tx) * (1 - ty)
                 + (elev_px(ix, iy + 1) * (1 - tx) + elev_px(ix + 1, iy + 1) * tx) * ty)
            lo, hi = min(lo, h), max(hi, h)
            out += struct.pack("<f", h)
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_bytes(bytes(out))
    tmp.replace(path)
    return cols, rows, lo, hi


# --------------------------------------------------------------------------

def validate_bbox(bbox: Bbox) -> float:
    s, w, n, e = bbox
    if not (-85 <= s < n <= 85 and -180 <= w < e <= 180):
        raise ValueError(f"bad bbox {bbox}: need south < north, west < east")
    return (n - s) * 110.574 * (e - w) * 111.320 * math.cos(math.radians((s + n) / 2))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bbox", nargs=4, type=float, required=True, metavar=("SOUTH", "WEST", "NORTH", "EAST"))
    ap.add_argument("-o", "--output", type=Path, required=True, help="output .osm path")
    ap.add_argument("--release", help="Overture release (default: latest)")
    ap.add_argument("--no-terrain", action="store_true")
    ap.add_argument("--terrain-spacing", type=float, default=4.0, help="metres (default 4)")
    ap.add_argument("--force", action="store_true", help=f"allow areas over {MAX_AREA_KM2} km^2")
    args = ap.parse_args(argv)

    if pq is None:
        print("error: needs pyarrow (pip install pyarrow)", file=sys.stderr)
        return 2
    bbox: Bbox = tuple(args.bbox)  # type: ignore[assignment]
    try:
        area = validate_bbox(bbox)
    except ValueError as exc:
        ap.error(str(exc))
    if area > MAX_AREA_KM2 and not args.force:
        print(f"error: {area:.1f} km^2 exceeds {MAX_AREA_KM2}; use --force", file=sys.stderr)
        return 2
    if not args.output.suffix == ".osm":
        ap.error("output must end in .osm")
    args.output.parent.mkdir(parents=True, exist_ok=True)

    try:
        release = args.release or latest_release()
        print(f"Overture {release}, {area:.2f} km^2")
        osm = OsmWriter()
        segs = read_features(release, "theme=transportation/type=segment", bbox,
                             ["bbox", "geometry", "subtype", "class", "subclass", "names"])
        n_roads = add_roads(osm, segs, bbox)
        water = read_features(release, "theme=base/type=water", bbox, ["bbox", "geometry", "subtype", "class", "names"])
        n_water = add_areas(osm, water, True, bbox)
        land = read_features(release, "theme=base/type=land_use", bbox, ["bbox", "geometry", "subtype", "class", "names"])
        n_land = add_areas(osm, land, False, bbox)
        blds = read_features(release, "theme=buildings/type=building", bbox,
                             ["bbox", "geometry", "subtype", "class", "height", "num_floors", "min_height"])
        n_bld = add_buildings(osm, blds, bbox)
        if n_roads == 0 and n_bld == 0:
            print("error: no roads or buildings in that bbox", file=sys.stderr)
            return 1
        osm.write(args.output, bbox, f"fetch_overture.py (Overture {release})")
        print(f"Wrote {args.output}: {n_roads} roads, {n_bld} buildings, {n_water} water, {n_land} land-use areas")

        if not args.no_terrain:
            hpath = args.output.with_suffix(".height")
            cols, rows, lo, hi = fetch_terrain(bbox, args.terrain_spacing, hpath)
            print(f"Wrote {hpath}: {cols}x{rows} grid, elevation {lo:.0f}-{hi:.0f} m")
    except (RuntimeError, ValueError, urllib.error.URLError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
