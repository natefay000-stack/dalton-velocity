extends RefCounted
## Parses an OpenStreetMap XML (.osm) file and projects it into local meters.
##
## Coordinates: +X = east, -Z = north, origin = centre of the map bounds.
## Lat/lon are kept as 64-bit floats until projection; Vector2 is 32-bit and
## would lose ~1 m of precision on raw degrees.

const METERS_PER_DEG_LAT := 110_574.0
const METERS_PER_DEG_LON_EQUATOR := 111_320.0

var _lat: Dictionary = {}  # node id -> float
var _lon: Dictionary = {}  # node id -> float

## node id -> Vector2(x, z) in meters. Filled by parse_file().
var points: Dictionary = {}
## Array of { id: int, nodes: PackedInt64Array, tags: Dictionary }
var ways: Array[Dictionary] = []
## Array of { id: int, members: Array[{type, ref, role}], tags: Dictionary }
var relations: Array[Dictionary] = []

var origin_lat := 0.0
var origin_lon := 0.0
var m_per_lon := METERS_PER_DEG_LON_EQUATOR
## Local-space bounds (meters) of all projected nodes.
var bounds := Rect2()

var _bounds_tag: Dictionary = {}
var _way_index: Dictionary = {}  # way id -> index in ways


## Returns OK, or an Error code with a message pushed via push_error().
func parse_file(path: String) -> Error:
	if not FileAccess.file_exists(path):
		push_error("OSM file not found: %s" % path)
		return ERR_FILE_NOT_FOUND

	var parser := XMLParser.new()
	var err := parser.open(path)
	if err != OK:
		push_error("Cannot open OSM file %s (error %d)" % [path, err])
		return err

	var current: Dictionary = {}
	var current_kind := ""  # "node", "way", "relation" or ""

	while true:
		err = parser.read()
		if err == ERR_FILE_EOF:
			break
		if err != OK:
			push_error("Malformed OSM XML in %s near byte %d" % [path, parser.get_node_offset()])
			return ERR_PARSE_ERROR

		var type := parser.get_node_type()
		if type == XMLParser.NODE_ELEMENT:
			var name := parser.get_node_name()
			match name:
				"bounds":
					_bounds_tag = {
						"minlat": parser.get_named_attribute_value_safe("minlat").to_float(),
						"minlon": parser.get_named_attribute_value_safe("minlon").to_float(),
						"maxlat": parser.get_named_attribute_value_safe("maxlat").to_float(),
						"maxlon": parser.get_named_attribute_value_safe("maxlon").to_float(),
					}
				"node":
					var lat_s := parser.get_named_attribute_value_safe("lat")
					var lon_s := parser.get_named_attribute_value_safe("lon")
					if lat_s.is_valid_float() and lon_s.is_valid_float():
						var nid := parser.get_named_attribute_value_safe("id").to_int()
						_lat[nid] = lat_s.to_float()
						_lon[nid] = lon_s.to_float()
					current_kind = ""
				"way":
					current = {
						"id": parser.get_named_attribute_value_safe("id").to_int(),
						"nodes": PackedInt64Array(),
						"tags": {},
					}
					current_kind = "way"
					if parser.is_empty():
						_finish(current, current_kind)
						current_kind = ""
				"relation":
					current = {
						"id": parser.get_named_attribute_value_safe("id").to_int(),
						"members": [],
						"tags": {},
					}
					current_kind = "relation"
					if parser.is_empty():
						_finish(current, current_kind)
						current_kind = ""
				"nd":
					if current_kind == "way":
						current["nodes"].append(parser.get_named_attribute_value_safe("ref").to_int())
				"member":
					if current_kind == "relation":
						current["members"].append({
							"type": parser.get_named_attribute_value_safe("type"),
							"ref": parser.get_named_attribute_value_safe("ref").to_int(),
							"role": parser.get_named_attribute_value_safe("role"),
						})
				"tag":
					if current_kind != "":
						current["tags"][parser.get_named_attribute_value_safe("k")] = \
							parser.get_named_attribute_value_safe("v")
		elif type == XMLParser.NODE_ELEMENT_END:
			var end_name := parser.get_node_name()
			if end_name == current_kind:
				_finish(current, current_kind)
				current_kind = ""

	if _lat.is_empty():
		push_error("OSM file %s contains no nodes" % path)
		return ERR_INVALID_DATA

	_project()
	return OK


func _finish(item: Dictionary, kind: String) -> void:
	if kind == "way":
		_way_index[item["id"]] = ways.size()
		ways.append(item)
	elif kind == "relation":
		relations.append(item)


func _project() -> void:
	if not _bounds_tag.is_empty():
		origin_lat = (_bounds_tag["minlat"] + _bounds_tag["maxlat"]) * 0.5
		origin_lon = (_bounds_tag["minlon"] + _bounds_tag["maxlon"]) * 0.5
	else:
		var lat_sum := 0.0
		var lon_sum := 0.0
		for id in _lat:
			lat_sum += _lat[id]
			lon_sum += _lon[id]
		origin_lat = lat_sum / _lat.size()
		origin_lon = lon_sum / _lat.size()

	# Equirectangular projection around the origin. Error is negligible at
	# neighbourhood scale (a few km).
	m_per_lon = METERS_PER_DEG_LON_EQUATOR * cos(deg_to_rad(origin_lat))
	var first := true
	for id in _lat:
		var p := project(_lat[id], _lon[id])
		points[id] = p
		if first:
			bounds = Rect2(p, Vector2.ZERO)
			first = false
		else:
			bounds = bounds.expand(p)
	_lat.clear()
	_lon.clear()
	# Extracts include whole ways that cross the edge; the declared <bounds>
	# is the area the map is about.
	if not _bounds_tag.is_empty():
		var nw := project(_bounds_tag["maxlat"], _bounds_tag["minlon"])
		var se := project(_bounds_tag["minlat"], _bounds_tag["maxlon"])
		bounds = Rect2(nw, se - nw)


## Lat/lon -> local metres (x east, y = z south). Valid after parse_file().
func project(lat: float, lon: float) -> Vector2:
	return Vector2((lon - origin_lon) * m_per_lon, -(lat - origin_lat) * METERS_PER_DEG_LAT)


## Returns the projected polyline for a way, skipping nodes that are missing
## from the extract (common at the edge of a bbox download).
func way_points(way: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for nid in way["nodes"]:
		if points.has(nid):
			out.append(points[nid])
	return out


func is_closed(way: Dictionary) -> bool:
	var n: PackedInt64Array = way["nodes"]
	return n.size() >= 4 and n[0] == n[n.size() - 1]


func get_way(id: int) -> Dictionary:
	var i: int = _way_index.get(id, -1)
	return ways[i] if i >= 0 else {}


## Assembles the outer rings of a multipolygon relation by joining member
## ways end to end. Inner rings (courtyards) are ignored. Returns closed rings
## as node-id arrays; unclosable fragments are dropped.
func relation_outer_rings(rel: Dictionary) -> Array[PackedInt64Array]:
	var segments: Array[PackedInt64Array] = []
	for m in rel["members"]:
		if m["type"] != "way" or m["role"] == "inner":
			continue
		var w := get_way(m["ref"])
		if not w.is_empty() and w["nodes"].size() >= 2:
			segments.append(w["nodes"].duplicate())

	var rings: Array[PackedInt64Array] = []
	while not segments.is_empty():
		var ring: PackedInt64Array = segments.pop_back()
		var progressed := true
		while ring[0] != ring[ring.size() - 1] and progressed:
			progressed = false
			for i in segments.size():
				var s: PackedInt64Array = segments[i]
				var tail := ring[ring.size() - 1]
				if s[0] == tail:
					ring.append_array(s.slice(1))
				elif s[s.size() - 1] == tail:
					var r := s.duplicate()
					r.reverse()
					ring.append_array(r.slice(1))
				else:
					continue
				segments.remove_at(i)
				progressed = true
				break
		if ring.size() >= 4 and ring[0] == ring[ring.size() - 1]:
			rings.append(ring)
	return rings


func ids_to_points(ids: PackedInt64Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for nid in ids:
		if points.has(nid):
			out.append(points[nid])
	return out
