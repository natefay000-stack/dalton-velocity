"""Offline tests for fetch_osm.py:  python3 -m unittest discover -s tools"""

import unittest
from pathlib import Path

import fetch_osm as f

OVERPASS_LIKE = b"""<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="Overpass API">
<note>The data included in this document is from www.openstreetmap.org.</note>
  <node id="1" lat="40.0" lon="-100.0"/>
  <node id="2" lat="40.001" lon="-100.0"/>
  <way id="3"><nd ref="1"/><nd ref="2"/><tag k="highway" v="residential"/></way>
</osm>
"""


class BboxTests(unittest.TestCase):
    def test_center_radius_is_square_in_metres(self) -> None:
        s, w, n, e = f.bbox_from_center(40.0, -100.0, 500)
        self.assertAlmostEqual(f.validate_bbox((s, w, n, e)), 1.0, places=2)

    def test_rejects_bad_boxes(self) -> None:
        for bad in [(41, -73, 40, -72), (40, -72, 41, -73), (-91, 0, 0, 1), (0, 179, 1, 181)]:
            with self.assertRaises(ValueError):
                f.validate_bbox(bad)
        with self.assertRaises(ValueError):
            f.bbox_from_center(40, -100, 0)


class ResponseTests(unittest.TestCase):
    def test_counts(self) -> None:
        self.assertEqual(f.check_response(OVERPASS_LIKE), (2, 1))

    def test_rejects_html_error_page(self) -> None:
        with self.assertRaises(ValueError):
            f.check_response(b"<html><body>Too Many Requests</body></html>")

    def test_rejects_runtime_error(self) -> None:
        payload = b'<osm version="0.6"><remark> runtime error: Query timed out </remark></osm>'
        with self.assertRaises(ValueError):
            f.check_response(payload)

    def test_rejects_empty_extract(self) -> None:
        with self.assertRaises(ValueError):
            f.check_response(b'<?xml version="1.0"?><osm version="0.6"></osm>')

    def test_bounds_inserted_once(self) -> None:
        out = f.with_bounds(OVERPASS_LIKE, (40.0, -100.1, 40.1, -100.0))
        self.assertEqual(out.count(b"<bounds "), 1)
        self.assertLess(out.index(b"<bounds "), out.index(b"<node "))
        self.assertEqual(f.with_bounds(out, (0, 0, 1, 1)).count(b"<bounds "), 1)


if __name__ == "__main__":
    unittest.main()


class ClipTests(unittest.TestCase):
    """fetch_overture's bbox clipping (stdlib-only parts; no pyarrow needed)."""

    BBOX = (0.0, 0.0, 1.0, 1.0)  # south, west, north, east

    def setUp(self) -> None:
        import importlib
        self.fo = importlib.import_module("fetch_overture")

    def test_line_crossing_box_is_trimmed(self) -> None:
        pieces = self.fo.clip_line([(-1.0, 0.5), (2.0, 0.5)], self.BBOX)
        self.assertEqual(pieces, [[(0.0, 0.5), (1.0, 0.5)]])

    def test_line_leaving_and_reentering_splits(self) -> None:
        pts = [(0.5, 0.5), (0.5, 2.0), (0.6, 2.0), (0.6, 0.5)]
        self.assertEqual(len(self.fo.clip_line(pts, self.BBOX)), 2)

    def test_line_outside_dropped(self) -> None:
        self.assertEqual(self.fo.clip_line([(2.0, 2.0), (3.0, 3.0)], self.BBOX), [])

    def test_ring_clipped_and_closed(self) -> None:
        ring = [(-1.0, -1.0), (0.5, -1.0), (0.5, 0.5), (-1.0, 0.5), (-1.0, -1.0)]
        out = self.fo.clip_ring(ring, self.BBOX)
        self.assertEqual(out[0], out[-1])
        self.assertEqual(sorted(set(out)), [(0.0, 0.0), (0.0, 0.5), (0.5, 0.0), (0.5, 0.5)])
        self.assertEqual(self.fo.clip_ring([(2, 2), (3, 2), (3, 3), (2, 2)], self.BBOX), [])

    def test_wkb_linestring_and_polygon(self) -> None:
        import struct
        line = b"\x01" + struct.pack("<II", 2, 2) + struct.pack("<4d", 0, 0, 1, 1)
        self.assertEqual(self.fo.parse_wkb(line), ("line", [[(0.0, 0.0), (1.0, 1.0)]]))
        ring = [(0, 0), (1, 0), (1, 1), (0, 0)]
        poly = b"\x01" + struct.pack("<III", 3, 1, 4) + b"".join(struct.pack("<2d", *p) for p in ring)
        kind, parts = self.fo.parse_wkb(poly)
        self.assertEqual(kind, "polygon")
        self.assertEqual(parts[0][0], [tuple(map(float, p)) for p in ring])

    def test_png_decoder_terrarium_pixel(self) -> None:
        import struct, zlib
        # 2x1 RGB image, filter 1 (sub) on the row: pixels (128,0,0) and (128,10,0).
        raw = bytes([1, 128, 0, 0, 0, 10, 0])
        def chunk(t: bytes, d: bytes) -> bytes:
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
        w, h, rows = self.fo.decode_png_rgb(png)
        self.assertEqual((w, h), (2, 1))
        self.assertEqual(rows[0], bytes([128, 0, 0, 128, 10, 0]))  # -> 0 m and 10 m


class ImageryTests(unittest.TestCase):
    """fetch_imagery.py: PNG round trip and pool detection on synthetic data."""

    def setUp(self) -> None:
        import importlib
        self.fi = importlib.import_module("fetch_imagery")

    def _image(self, w: int, h: int, fill=(90, 120, 60)):
        return bytearray(bytes(fill) * (w * h))

    def _paint(self, img, w, x0, y0, x1, y1, color):
        for y in range(y0, y1):
            for x in range(x0, x1):
                img[(y * w + x) * 3: (y * w + x) * 3 + 3] = bytes(color)

    def test_png_round_trip(self) -> None:
        w, h = 7, 5
        img = self._image(w, h)
        self._paint(img, w, 2, 1, 5, 4, (10, 200, 250))
        png = self.fi.encode_png_rgb(w, h, img)
        pw, ph, ch, px = self.fi.decode_png(png)
        self.assertEqual((pw, ph, ch), (w, h, 3))
        self.assertEqual(bytes(px), bytes(img))

    def test_pool_detection_filters_size_and_shape(self) -> None:
        w, h = 120, 120
        img = self._image(w, h)
        self._paint(img, w, 10, 10, 20, 18, (70, 160, 210))     # 10x8 px = 28.8 m² at 0.6 m: pool
        self._paint(img, w, 40, 40, 43, 43, (70, 160, 210))     # 3x3 = 3.2 m²: too small
        self._paint(img, w, 60, 60, 110, 110, (70, 160, 210))   # 50x50 = 900 m²: a pond
        for i in range(30):                                     # a thin blue line: ragged
            self._paint(img, w, 5 + i, 100 + (i % 2), 6 + i, 101 + (i % 2), (70, 160, 210))
        pools = self.fi.find_pools(w, h, img, 0.6)
        self.assertEqual(pools, [(10, 10, 20, 18)])

    def test_pool_blue_rejects_grass_roof_sky(self) -> None:
        self.assertTrue(self.fi.is_pool_blue(60, 150, 200))
        self.assertFalse(self.fi.is_pool_blue(90, 120, 60))     # lawn
        self.assertFalse(self.fi.is_pool_blue(110, 110, 120))   # grey roof
        self.assertFalse(self.fi.is_pool_blue(200, 210, 240))   # white-ish concrete

    def test_pools_dropped_on_buildings_and_lakes(self) -> None:
        bbox = (0.0, 0.0, 1.0, 1.0)
        boxes = [(10, 10, 20, 20), (50, 50, 60, 60), (80, 80, 90, 90)]
        bld = [[(0.0, 0.8), (0.3, 0.8), (0.3, 1.0), (0.0, 1.0), (0.0, 0.8)]]       # covers first box (y near top)
        lake = [[(0.7, 0.0), (1.0, 0.0), (1.0, 0.3), (0.7, 0.3), (0.7, 0.0)]]      # covers third box
        rings = self.fi.pools_to_rings(boxes, bbox, 100, 100, bld, lake)
        self.assertEqual(len(rings), 1)
        self.assertAlmostEqual(rings[0][0][0], 0.5)

    def test_append_pools_is_repeatable(self) -> None:
        import tempfile, os
        osm = '<?xml version="1.0"?>\n<osm version="0.6">\n  <node id="1" lat="0" lon="0"/>\n</osm>\n'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.osm"
            p.write_text(osm)
            ring = [(0.1, 0.1), (0.2, 0.1), (0.2, 0.2), (0.1, 0.2)]
            self.assertEqual(self.fi.append_pools(p, [ring]), 1)
            self.assertEqual(self.fi.append_pools(p, [ring, ring]), 2)
            text = p.read_text()
            self.assertEqual(text.count('v="swimming_pool"'), 2)
            self.assertEqual(text.count("<node"), 9)
            self.assertTrue(text.rstrip().endswith("</osm>"))
