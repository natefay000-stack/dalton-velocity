#!/usr/bin/env python3
"""Add parcel (lot) boundaries to a map from Utah's public parcel data.

Fences, yards and setbacks then follow real property lines instead of a
guessed box behind each house.

Two ways to get the data:

  1. Online, from the Utah SGID feature service (default URL below; pass
     --url if the state moves it):
        python3 tools/fetch_parcels.py game/maps/herriman.osm

  2. From a file you downloaded yourself (GeoJSON), e.g. "Utah Parcels" or
     the Salt Lake County parcel layer from https://opendata.gis.utah.gov:
        python3 tools/fetch_parcels.py game/maps/herriman.osm --geojson ~/Downloads/Parcels.geojson

Parcels overlapping the map's bounds are clipped to it and appended to the
.osm as closed ways tagged parcel=yes (repeatable: an earlier run's parcels
are replaced). Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_URL = ("https://services1.arcgis.com/99lidPhWCzftIe9K/arcgis/rest/services/"
               "UtahStatewideParcels/FeatureServer/0/query")
PAGE = 1000
MIN_AREA_DEG2 = 1e-10  # ~1 m² at this latitude; drops slivers


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


_SSL = _ssl_context()

Bbox = tuple[float, float, float, float]  # south, west, north, east
Ring = list[tuple[float, float]]           # (lon, lat), closed


def read_bounds(osm_path: Path) -> Bbox:
    head = osm_path.read_text(encoding="utf-8")[:4000]
    m = re.search(r'<bounds minlat="([^"]+)" minlon="([^"]+)" maxlat="([^"]+)" maxlon="([^"]+)"', head)
    if not m:
        raise ValueError(f"{osm_path} has no <bounds>; re-run fetch_overture.py")
    s, w, n, e = (float(v) for v in m.groups())
    return s, w, n, e


# --------------------------------------------------------------------------
# Sources

def fetch_arcgis(url: str, bbox: Bbox) -> list[dict]:
    """All features of an ArcGIS FeatureServer layer intersecting bbox, as
    GeoJSON features (paged)."""
    s, w, n, e = bbox
    features: list[dict] = []
    offset = 0
    while True:
        params = {
            "where": "1=1", "geometry": f"{w},{s},{e},{n}", "geometryType": "esriGeometryEnvelope",
            "inSR": "4326", "spatialRel": "esriSpatialRelIntersects", "outFields": "",
            "returnGeometry": "true", "outSR": "4326", "f": "geojson",
            "resultOffset": str(offset), "resultRecordCount": str(PAGE),
        }
        full = url + "?" + urllib.parse.urlencode(params)
        last: Exception | None = None
        body = b""
        for attempt in range(4):
            try:
                with urllib.request.urlopen(full, timeout=120, context=_SSL) as resp:
                    body = resp.read()
                break
            except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
                last = exc
                time.sleep(2 ** attempt)
        else:
            raise RuntimeError(f"parcel service unreachable: {last}\n"
                               f"Download the parcels as GeoJSON from https://opendata.gis.utah.gov "
                               f"and pass --geojson <file> instead.")
        data = json.loads(body.decode("utf-8"))
        if "error" in data:
            raise RuntimeError(f"parcel service error: {data['error']}\n"
                               f"Try --url with the current SGID parcel layer, or --geojson <file>.")
        page = data.get("features", [])
        features.extend(page)
        if len(page) < PAGE or not data.get("properties", {}).get("exceededTransferLimit", len(page) == PAGE):
            if len(page) < PAGE:
                break
        offset += PAGE
        if offset > 200_000:
            break
    return features


def load_geojson(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("type") == "FeatureCollection":
        return data.get("features", [])
    if data.get("type") == "Feature":
        return [data]
    raise ValueError(f"{path} is not GeoJSON")


# --------------------------------------------------------------------------
# Geometry

def outer_rings(feature: dict) -> list[Ring]:
    geom = feature.get("geometry") or {}
    t = geom.get("type")
    coords = geom.get("coordinates") or []
    polys = []
    if t == "Polygon":
        polys = [coords]
    elif t == "MultiPolygon":
        polys = coords
    rings = []
    for poly in polys:
        if poly and len(poly[0]) >= 4:
            rings.append([(float(x), float(y)) for x, y, *_ in poly[0]])
    return rings


def clip_ring(ring: Ring, bbox: Bbox) -> Ring:
    """Sutherland-Hodgman clip to the bbox; [] if nothing is left."""
    s, w, n, e = bbox
    edges = (
        (lambda p: p[0] >= w, lambda a, b: (w, a[1] + (w - a[0]) * (b[1] - a[1]) / (b[0] - a[0]))),
        (lambda p: p[0] <= e, lambda a, b: (e, a[1] + (e - a[0]) * (b[1] - a[1]) / (b[0] - a[0]))),
        (lambda p: p[1] >= s, lambda a, b: (a[0] + (s - a[1]) * (b[0] - a[0]) / (b[1] - a[1]), s)),
        (lambda p: p[1] <= n, lambda a, b: (a[0] + (n - a[1]) * (b[0] - a[0]) / (b[1] - a[1]), n)),
    )
    out = ring[:-1] if ring[0] == ring[-1] else list(ring)
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


def ring_area(ring: Ring) -> float:
    a = 0.0
    for i in range(len(ring) - 1):
        a += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
    return abs(a) * 0.5


def parcels_in_bbox(features: list[dict], bbox: Bbox) -> list[Ring]:
    out = []
    for f in features:
        for ring in outer_rings(f):
            clipped = clip_ring(ring, bbox)
            if clipped and ring_area(clipped) > MIN_AREA_DEG2:
                out.append(clipped)
    return out


# --------------------------------------------------------------------------
# OSM output

def write_parcels(osm_path: Path, rings: list[Ring]) -> int:
    text = osm_path.read_text(encoding="utf-8")
    text = re.sub(r'  <way id="\d+">(?:(?!</way>).)*?<tag k="parcel" v="yes"/>.*?</way>\n', "", text, flags=re.S)
    text = re.sub(r'  <node id="\d+" lat="[^"]+" lon="[^"]+" parcel="1"/>\n', "", text)
    ids = [int(i) for i in re.findall(r'<(?:node|way) id="(\d+)"', text)]
    next_id = max(ids) + 1 if ids else 1
    lines = []
    for ring in rings:
        refs = []
        for lon, lat in ring[:-1]:
            lines.append(f'  <node id="{next_id}" lat="{lat:.7f}" lon="{lon:.7f}" parcel="1"/>')
            refs.append(next_id)
            next_id += 1
        refs.append(refs[0])
        lines.append(f'  <way id="{next_id}">')
        next_id += 1
        lines += [f'    <nd ref="{r}"/>' for r in refs]
        lines.append('    <tag k="parcel" v="yes"/>')
        lines.append("  </way>")
    text = text.replace("</osm>", "\n".join(lines) + "\n</osm>" if lines else "</osm>")
    osm_path.write_text(text, encoding="utf-8")
    return len(rings)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("osm", type=Path)
    ap.add_argument("--geojson", type=Path, help="use a downloaded GeoJSON file instead of the service")
    ap.add_argument("--url", default=DEFAULT_URL, help="ArcGIS FeatureServer layer query URL")
    args = ap.parse_args(argv)
    if not args.osm.exists():
        print(f"error: {args.osm} not found", file=sys.stderr)
        return 2
    try:
        bbox = read_bounds(args.osm)
        if args.geojson:
            features = load_geojson(args.geojson)
        else:
            print(f"Querying {args.url}")
            features = fetch_arcgis(args.url, bbox)
        rings = parcels_in_bbox(features, bbox)
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if not rings:
        print("error: no parcels overlap the map bounds", file=sys.stderr)
        return 1
    n = write_parcels(args.osm, rings)
    print(f"Wrote {n} parcels into {args.osm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
