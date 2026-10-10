"""Offline tests for fetch_osm.py:  python3 -m unittest discover -s tools"""

import unittest

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
