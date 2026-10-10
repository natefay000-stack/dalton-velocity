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
