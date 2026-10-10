extends RefCounted
## Turns parsed OSM data into renderable, collidable geometry:
## ground, land-use patches, road ribbons and extruded buildings.
##
## Everything of one kind is merged into a single mesh so a few thousand
## buildings stay at a handful of draw calls.

const OsmData := preload("res://scripts/osm_data.gd")
const Terrain := preload("res://scripts/terrain.gd")
const Occupancy := preload("res://scripts/occupancy.gd")
const Surfaces := preload("res://scripts/surfaces.gd")
const Ortho := preload("res://scripts/ortho.gd")

const ROAD_WIDTHS := {
	"motorway": 14.0, "trunk": 12.0, "primary": 10.0, "secondary": 9.0,
	"tertiary": 8.0, "unclassified": 6.5, "residential": 6.5,
	"living_street": 5.0, "service": 4.0, "motorway_link": 7.0,
	"trunk_link": 7.0, "primary_link": 7.0, "secondary_link": 6.0,
	"tertiary_link": 6.0, "track": 3.0,
	"footway": 2.0, "path": 1.5, "cycleway": 2.0, "pedestrian": 4.0,
	"steps": 2.0,
}
const FOOT_TYPES := ["footway", "path", "cycleway", "pedestrian", "steps", "track"]
const DRIVABLE_TYPES := [
	"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
	"residential", "living_street", "motorway_link", "trunk_link",
	"primary_link", "secondary_link", "tertiary_link",
]

const LEVEL_HEIGHT := 3.2
const GROUND_MARGIN := 300.0

const COLOR_ROAD := Color(0.22, 0.22, 0.24)
const COLOR_PATH := Color(0.62, 0.58, 0.52)
const COLOR_SIDEWALK := Color(0.72, 0.71, 0.68)
const COLOR_CURB := Color(0.66, 0.65, 0.62)
const COLOR_LANE_YELLOW := Color(0.85, 0.70, 0.15)
const COLOR_LANE_WHITE := Color(0.88, 0.88, 0.85)
const COLOR_WINDOW := Color(0.30, 0.40, 0.50)
const COLOR_FRAME := Color(0.93, 0.93, 0.90)
const COLOR_DOOR := Color(0.32, 0.18, 0.12)
const COLOR_GARAGE := Color(0.88, 0.86, 0.82)
const ROAD_Y := 0.12
const CURB_HEIGHT := 0.12
const CURB_WIDTH := 0.28
const SIDEWALK_Y := 0.17
const MARKING_Y := 0.135
const CURB_TYPES := ["primary", "secondary", "tertiary", "unclassified", "residential", "living_street"]
const CENTER_LINE_TYPES := ["motorway", "trunk", "primary", "secondary", "tertiary"]
const EDGE_LINE_TYPES := ["motorway", "trunk", "primary", "secondary"]
const LEVEL_HEIGHT_FACADE := 2.9
const DRIVEWAY_WIDTH := 4.0
const DRIVEWAY_MAX := 28.0
const ROAD_BLEND := 6.0  # metres of slope between a road bed and natural ground
const COLOR_GRASS := Color(0.36, 0.55, 0.28)
const COLOR_WATER := Color(0.22, 0.42, 0.62)
const COLOR_PAVED := Color(0.55, 0.55, 0.55)
const COLOR_GROUND := Color(0.45, 0.50, 0.38)
const COLOR_HILLSIDE := Color(0.62, 0.55, 0.40)
const COLOR_SAGE := Color(0.47, 0.48, 0.35)
const COLOR_ROCK := Color(0.50, 0.46, 0.40)
const COLOR_LAWN := Color(0.30, 0.48, 0.22)
const YARD_RADIUS := 9.0
const ROOF_PALETTE := [
	Color(0.28, 0.27, 0.27), Color(0.36, 0.30, 0.26), Color(0.42, 0.40, 0.38),
	Color(0.30, 0.24, 0.20), Color(0.22, 0.23, 0.26),
]
const HIP_PITCH := 0.45  # rise/run, ~24 degrees
const HIP_MIN_FILL := 0.6  # footprint area / bounding-box area (L-shapes get boxed)
const ROOF_OVERHANG := 0.4
const WATER_DEPTH := 2.5  # metres below the surface away from the shore
const WATER_SHELF := 10.0  # metres from the shore to full depth
## Max segment length when draping roads over terrain.
const DRAPE_STEP := 3.0
const BUILDING_PALETTE := [
	Color(0.85, 0.80, 0.70), Color(0.75, 0.68, 0.60), Color(0.80, 0.55, 0.45),
	Color(0.70, 0.72, 0.75), Color(0.92, 0.90, 0.85), Color(0.60, 0.50, 0.42),
]

const LANDUSE_COLORS := {
	"landuse=grass": COLOR_GRASS, "landuse=meadow": COLOR_GRASS,
	"landuse=forest": Color(0.20, 0.40, 0.20), "natural=wood": Color(0.20, 0.40, 0.20),
	"leisure=park": COLOR_GRASS, "leisure=pitch": Color(0.30, 0.60, 0.30),
	"leisure=playground": Color(0.65, 0.55, 0.40), "landuse=recreation_ground": COLOR_GRASS,
	"leisure=golf_course": Color(0.32, 0.58, 0.28), "amenity=school": Color(0.55, 0.53, 0.48),
	"landuse=cemetery": Color(0.35, 0.50, 0.30), "landuse=basin": COLOR_WATER,
	"leisure=swimming_pool": Color(0.35, 0.75, 0.85),
	"natural=water": COLOR_WATER, "landuse=reservoir": COLOR_WATER,
	"amenity=parking": COLOR_PAVED, "landuse=residential": Color(0.36, 0.50, 0.28),
	"landuse=commercial": Color(0.55, 0.52, 0.50), "landuse=retail": Color(0.55, 0.52, 0.50),
}

## Populated by build(): a point on a drivable road and the road's heading
## (radians, Godot Y rotation) — used to place the player and a car.
var spawn_position := Vector3.ZERO
var spawn_yaw := 0.0
var stats := {"roads": 0, "buildings": 0, "areas": 0, "skipped": 0}
var _terrain: Terrain = null
## Aerial photo (optional): roof colours come from it and the ground is
## left unpainted so the photo shows.
var ortho: Ortho = null
## Windows, doors and garage doors on walls (off for geometry tests).
var facades := true
## Where things are, for props and pedestrians (filled by build()).
var occupancy: Occupancy = Occupancy.new()
## {pts, highway, width, name, service} for every road/path ribbon.
var road_list: Array[Dictionary] = []
## {ring (PackedVector2Array), rect, front (edge index or -1), height} per building.
var building_list: Array[Dictionary] = []
## {ring, kind} for parks, grass, forest etc. (not water).
var area_list: Array[Dictionary] = []
## Outer rings of lakes and ponds (for the minimap).
var water_rings: Array[PackedVector2Array] = []
## Lot boundaries (parcel=yes ways), when the map has them.
var parcel_list: Array[PackedVector2Array] = []
var _driveways: Array[PackedVector2Array] = []
var _walks: Array = []  # [door point, outward dir]
var _paving: SurfaceTool
var _bricks: SurfaceTool
var _roofs: SurfaceTool
var _trim: SurfaceTool
var _windows: SurfaceTool
## Window-pane material; emission is switched on at night by Daylight.
var window_material: StandardMaterial3D
const BRICK_PALETTE := [Color(0.62, 0.32, 0.24), Color(0.70, 0.45, 0.34), Color(0.55, 0.30, 0.25), Color(0.75, 0.62, 0.50)]


func build(data: OsmData, terrain: Terrain = null) -> Node3D:
	_terrain = terrain
	occupancy.setup(data.bounds)
	var root := Node3D.new()
	root.name = "Map"

	var roads := _st()
	_paving = _st()
	var areas := _st()
	var water := _st()
	var buildings := _st()  # plain walls
	_bricks = _st()
	_roofs = _st()
	_trim = _st()
	_windows = _st()

	# Pass 1: areas (and, with terrain, building yards) shape and paint the
	# ground before anything is draped onto it.
	var area_rings: Array = []  # [PackedVector2Array, Color, is_water]
	var footprints: Array[Rect2] = []
	for way in data.ways:
		var tags: Dictionary = way["tags"]
		if not data.is_closed(way):
			continue
		if tags.has("building") or tags.has("building:part"):
			var pts := data.way_points(way)
			if pts.size() >= 3:
				footprints.append(_rect_of(pts))
			continue
		if tags.has("highway"):
			continue
		if tags.get("parcel") == "yes":
			var ring := _clean_ring(data.way_points(way))
			if ring.size() >= 3:
				parcel_list.append(ring)
			continue
		var color = _area_color(tags)
		if color != null:
			area_rings.append([data.way_points(way), color, _is_water(tags)])
			if not _is_water(tags):
				area_list.append({"ring": data.way_points(way), "kind": _area_kind(tags)})
	for rel in data.relations:
		var tags: Dictionary = rel["tags"]
		if tags.get("type") != "multipolygon" or tags.has("building"):
			continue
		var color = _area_color(tags)
		if color != null:
			for ring in data.relation_outer_rings(rel):
				area_rings.append([data.ids_to_points(ring), color, _is_water(tags)])

	for item in area_rings:
		var ok := false
		if _terrain != null:
			ok = _paint_area(water, item[0], item[1], item[2])
		else:
			ok = _add_flat_polygon(water if item[2] else areas, item[0], 0.015, item[1])
		if ok:
			stats["areas"] += 1
			if item[2]:
				occupancy.mark_polygon(_clean_ring(item[0]), 1.0, Occupancy.WATER)
				water_rings.append(_clean_ring(item[0]))
	if _terrain != null and ortho == null:
		_paint_terrain_base(footprints)

	# Pass 2: roads (with curbs and markings) on the final ground. They go
	# before buildings so facades can tell which side faces the street.
	# With terrain, the ground is first cut and filled flat under every
	# drivable road (heights sampled along the centreline before any carving,
	# so crossing roads agree).
	if _terrain != null:
		var beds: Array = []
		for way in data.ways:
			var tags: Dictionary = way["tags"]
			if not (tags.has("highway") and tags["highway"] in DRIVABLE_TYPES + ["service"] and tags.get("area") != "yes"):
				continue
			var pts := _subdivide(data.way_points(way), DRAPE_STEP) if data.way_points(way).size() >= 2 else PackedVector2Array()
			if pts.size() < 2:
				continue
			var hs := PackedFloat32Array()
			for p in pts:
				hs.append(_terrain.height_at(p.x, p.y))
			# Smooth along the road so it doesn't follow every 4 m bump.
			var sm := hs.duplicate()
			for i in range(1, hs.size() - 1):
				sm[i] = (hs[i - 1] + hs[i] * 2.0 + hs[i + 1]) * 0.25
			beds.append([pts, sm, _road_width(tags) * 0.5 + CURB_WIDTH + 0.5])
		for bed in beds:
			_terrain.flatten_polyline(bed[0], bed[1], bed[2], ROAD_BLEND)
		stats["road_beds"] = beds.size()
	var best_spawn_score := -INF
	var center := data.bounds.get_center()
	for way in data.ways:
		var tags: Dictionary = way["tags"]
		if not (tags.has("highway") and ROAD_WIDTHS.has(tags["highway"]) and tags.get("area") != "yes"):
			continue
		var pts := data.way_points(way)
		if pts.size() < 2:
			stats["skipped"] += 1
			continue
		var hw: String = tags["highway"]
		var width := _road_width(tags)
		_add_road(roads, pts, hw, width)
		road_list.append({"pts": pts, "highway": hw, "width": width,
			"name": tags.get("name", ""), "service": tags.get("service", "")})
		var foot := hw in FOOT_TYPES
		occupancy.mark_polyline(pts, width * 0.5 + (0.3 if foot else 1.2), Occupancy.PATH if foot else Occupancy.ROAD)
		if tags.get("service") == "driveway":
			occupancy.mark_polyline(pts, width * 0.5 + 0.5, Occupancy.DRIVEWAY)
		stats["roads"] += 1
		if hw in DRIVABLE_TYPES:
			var score := _spawn_score(pts, center)
			if score > best_spawn_score:
				best_spawn_score = score
				_set_spawn(pts)

	# Pass 3: buildings.
	for way in data.ways:
		var tags: Dictionary = way["tags"]
		if (tags.has("building") or tags.has("building:part")) and data.is_closed(way):
			if _add_building(buildings, data.way_points(way), tags, way["id"]):
				stats["buildings"] += 1
			else:
				stats["skipped"] += 1
	for rel in data.relations:
		var tags: Dictionary = rel["tags"]
		if (tags.get("type") == "multipolygon" or tags.get("type") == "building") and tags.has("building"):
			for ring in data.relation_outer_rings(rel):
				if _add_building(buildings, data.ids_to_points(ring), tags, rel["id"]):
					stats["buildings"] += 1

	# Driveways from garages to the street (the data rarely has them).
	for dw in _driveways:
		_add_ribbon(_paving, _subdivide(dw, DRAPE_STEP) if _terrain != null else dw, DRIVEWAY_WIDTH, SIDEWALK_Y - 0.02, COLOR_SIDEWALK.darkened(0.06))
		occupancy.mark_polyline(dw, DRIVEWAY_WIDTH * 0.5 + 0.5, Occupancy.DRIVEWAY)
		road_list.append({"pts": dw, "highway": "service", "width": DRIVEWAY_WIDTH, "name": "", "service": "driveway"})
		stats["driveways"] = stats.get("driveways", 0) + 1
	# Front steps and a walk from each front door to the driveway/sidewalk.
	for w in _walks:
		var from: Vector2 = w[0]
		var out2: Vector2 = w[1]
		_add_ribbon(_paving, PackedVector2Array([from - out2 * 0.1, from + out2 * 1.1]), 1.7, SIDEWALK_Y + 0.06, COLOR_SIDEWALK)
		var d := 1.0
		while d < 25.0:
			var p := from + out2 * d
			var cell := occupancy.get_at(p.x, p.y)
			if cell & (Occupancy.DRIVEWAY | Occupancy.PATH | Occupancy.ROAD):
				var walk := PackedVector2Array([from + out2 * 1.0, p])
				_add_ribbon(_paving, _subdivide(walk, DRAPE_STEP) if _terrain != null else walk, 1.0, SIDEWALK_Y - 0.03, COLOR_SIDEWALK)
				occupancy.mark_polyline(walk, 0.8, Occupancy.PATH)
				stats["walks"] = stats.get("walks", 0) + 1
				break
			if cell & (Occupancy.BUILDING | Occupancy.WATER):
				break
			d += 1.0

	root.add_child(_terrain.build_node() if _terrain != null else make_ground(data.bounds))
	_attach(root, "Areas", areas, false, "ground")
	_attach(root, "Roads", roads, false, "road")
	_attach(root, "Paving", _paving, false, "concrete")
	_attach_water(root, water)
	window_material = StandardMaterial3D.new()
	window_material.vertex_color_use_as_albedo = true
	window_material.roughness = 0.2
	window_material.metallic = 0.3
	window_material.emission_enabled = true
	window_material.emission = Color(1.0, 0.80, 0.55)
	window_material.emission_energy_multiplier = 0.0
	_attach_multi(root, "Buildings", [[buildings, "stucco", true], [_bricks, "brick", true], [_roofs, "shingle", true], [_trim, "", false], [_windows, window_material, false]])
	return root


func _st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


func _ground(x: float, z: float) -> float:
	return _terrain.height_at(x, z) if _terrain != null else 0.0


func _area_kind(tags: Dictionary) -> String:
	for k in ["leisure", "natural", "landuse", "amenity"]:
		if tags.has(k):
			return "%s=%s" % [k, tags[k]]
	return ""


func _is_water(tags: Dictionary) -> bool:
	return tags.get("natural") == "water" or tags.get("landuse") == "reservoir" \
		or tags.get("landuse") == "basin" or tags.get("leisure") == "swimming_pool"


func _rect_of(pts: PackedVector2Array) -> Rect2:
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


## Terrain: paint an area's colour onto the ground; water is also carved
## below its shoreline and gets a flat surface.
func _paint_area(water_st: SurfaceTool, pts: PackedVector2Array, color: Color, is_water: bool) -> bool:
	var ring := _clean_ring(pts)
	if ring.size() < 3:
		return false
	var t := _terrain
	if not is_water:
		if ortho == null:
			t.for_each_inside(ring, func(c: int, r: int) -> void:
				t.colors[r * t.cols + c] = color)
		return true
	# Elevation data records a lake's surface as flat ground, so the water
	# level is set just above the typical height inside the outline and the
	# bed deepens gradually away from the shore. The waterline then follows
	# the real bank instead of the grid.
	var inside: Array[int] = []
	t.for_each_inside(ring, func(c: int, r: int) -> void:
		inside.append(r * t.cols + c))
	var level := INF
	if inside.is_empty():
		for p in ring:
			level = minf(level, t.height_at(p.x, p.y))
		level -= 0.2
	else:
		var hs: Array[float] = []
		for i in inside:
			hs.append(t.heights[i])
		hs.sort()
		level = hs[hs.size() / 2] + 0.25
	var pool := color == LANDUSE_COLORS["leisure=swimming_pool"]
	for i in inside:
		var p := Vector2(t.x0 + (i % t.cols) * t.dx, t.z0 + (i / t.cols) * t.dz)
		var depth := 1.5 if pool else WATER_DEPTH * smoothstep(0.0, WATER_SHELF, _dist_to_ring(p, ring))
		t.heights[i] = minf(t.heights[i], level - 0.15 - depth)
		t.colors[i] = Color(0.75, 0.85, 0.9) if pool else (Color(0.5, 0.5, 0.5) if ortho != null else Color(0.30, 0.28, 0.20))
	if pool:
		stats["pools"] = stats.get("pools", 0) + 1
	# Draw the surface a few metres into the bank: it then meets the shore
	# along the terrain's contour instead of the grid's stair-steps.
	var surface := ring
	var grown := Geometry2D.offset_polygon(ring, 0.3 if pool else 4.0)
	if not grown.is_empty() and absf(_signed_area(grown[0])) > absf(_signed_area(ring)):
		surface = grown[0]
	if pool:
		# Concrete deck: a 1.5 m apron around the water.
		var apron := Geometry2D.offset_polygon(ring, 1.5)
		if not apron.is_empty():
			for strip in Geometry2D.clip_polygons(apron[0], surface):
				if _add_flat_polygon(_paving, strip, level + 0.08, COLOR_SIDEWALK):
					stats["pool_decks"] = stats.get("pool_decks", 0) + 1
	return _add_flat_polygon(water_st, surface, level, color if pool else COLOR_WATER)


func _dist_to_ring(p: Vector2, ring: PackedVector2Array) -> float:
	var best := INF
	for i in ring.size():
		var q := Geometry2D.get_closest_point_to_segment(p, ring[i], ring[(i + 1) % ring.size()])
		best = minf(best, p.distance_squared_to(q))
	return sqrt(best)


func _signed_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


## Natural ground colour (dry foothill grass/sage, rockier where steep),
## lawns around buildings, then the painted areas on top. Area colours are
## already in `colors`; untouched vertices are still white.
func _paint_terrain_base(footprints: Array[Rect2]) -> void:
	var t := _terrain
	var painted := PackedByteArray()
	painted.resize(t.colors.size())
	for i in t.colors.size():
		painted[i] = 0 if t.colors[i] == Color.WHITE else 1
	for i in t.colors.size():
		if painted[i]:
			continue
		var c := i % t.cols
		var r := i / t.cols
		var n := Vector3(
			(t.h(c - 1, r) - t.h(c + 1, r)) / (2.0 * t.dx), 1.0,
			(t.h(c, r - 1) - t.h(c, r + 1)) / (2.0 * t.dz)).normalized()
		var steep := clampf((1.0 - n.y) * 6.0, 0.0, 1.0)
		var noise := float(absi(hash(Vector2i(c / 3, r / 3))) % 1000) / 1000.0
		var col := COLOR_HILLSIDE.lerp(COLOR_SAGE, noise * 0.7)
		t.colors[i] = col.lerp(COLOR_ROCK, steep)
	# Yards: irrigated lawn within a few metres of houses.
	for rect in footprints:
		t.for_each_near(rect, YARD_RADIUS, func(c: int, r: int) -> void:
			var i := r * t.cols + c
			if not painted[i]:
				t.colors[i] = COLOR_LAWN)


func _road_width(tags: Dictionary) -> float:
	var w := String(tags.get("width", "")).replace("m", "").strip_edges()
	if w.is_valid_float() and w.to_float() > 0.5:
		return w.to_float()
	var lanes := String(tags.get("lanes", ""))
	if lanes.is_valid_int() and lanes.to_int() > 0:
		return lanes.to_int() * 3.25
	return ROAD_WIDTHS[tags["highway"]]


func _area_color(tags: Dictionary):
	for k in ["leisure", "natural", "landuse", "amenity"]:
		if tags.has(k):
			var key := "%s=%s" % [k, tags[k]]
			if LANDUSE_COLORS.has(key):
				return LANDUSE_COLORS[key]
	return null


func _spawn_score(pts: PackedVector2Array, center: Vector2) -> float:
	# Prefer long road segments near the centre of the map.
	var mid := pts[pts.size() / 2]
	var seg := pts[pts.size() / 2] - pts[pts.size() / 2 - 1]
	return seg.length() * 0.5 - mid.distance_to(center)


func _set_spawn(pts: PackedVector2Array) -> void:
	var i := pts.size() / 2
	var a := pts[i - 1]
	var b := pts[i]
	var mid := (a + b) * 0.5
	spawn_position = Vector3(mid.x, _ground(mid.x, mid.y), mid.y)
	var dir := (b - a).normalized()
	# Godot's forward is -Z; yaw so that -Z points along the road.
	spawn_yaw = atan2(-dir.x, -dir.y)


## Road surface plus curbs and lane markings by road class. Footways are
## drawn as concrete sidewalks a little above road level.
func _add_road(st: SurfaceTool, pts: PackedVector2Array, hw: String, width: float) -> void:
	if _terrain != null:
		pts = _subdivide(pts, DRAPE_STEP)
	if hw in FOOT_TYPES:
		var concrete := hw in ["footway", "pedestrian", "steps"]
		_add_ribbon(_paving, pts, width, SIDEWALK_Y if concrete else 0.09, COLOR_SIDEWALK if concrete else COLOR_PATH)
		return
	if hw == "service":
		_add_ribbon(_paving, pts, width, ROAD_Y, COLOR_ROAD.lightened(0.15))
		return
	_add_ribbon(st, pts, width, ROAD_Y, COLOR_ROAD, true)
	var half := width * 0.5
	if hw in CURB_TYPES:
		for side in [-1.0, 1.0]:
			var inner := _offset_polyline(pts, side * half)
			var outer := _offset_polyline(pts, side * (half + CURB_WIDTH))
			_add_strip(_paving, inner, outer, ROAD_Y, ROAD_Y + CURB_HEIGHT, COLOR_CURB)
	if hw in CENTER_LINE_TYPES:
		for side in [-1.0, 1.0]:
			_add_ribbon(_paving, _offset_polyline(pts, side * 0.12), 0.1, MARKING_Y, COLOR_LANE_YELLOW)
	if hw in EDGE_LINE_TYPES:
		for side in [-1.0, 1.0]:
			_add_ribbon(_paving, _offset_polyline(pts, side * (half - 0.35)), 0.1, MARKING_Y, COLOR_LANE_WHITE)


## Polyline shifted sideways by `offset` (positive = left of travel),
## mitred at joints with the miter length clamped so sharp corners don't
## spike.
func _offset_polyline(pts: PackedVector2Array, offset: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var d_in := (pts[i] - pts[i - 1]).normalized() if i > 0 else Vector2.ZERO
		var d_out := (pts[i + 1] - pts[i]).normalized() if i < n - 1 else Vector2.ZERO
		var d := (d_in + d_out)
		if d.length_squared() < 1e-8:
			d = d_out if d_out != Vector2.ZERO else d_in
		d = d.normalized()
		var normal := Vector2(-d.y, d.x)
		var scale := 1.0
		if d_in != Vector2.ZERO and d_out != Vector2.ZERO:
			var c := normal.dot(Vector2(-d_out.y, d_out.x))
			scale = clampf(1.0 / maxf(c, 0.01), 1.0, 2.0)
		out.append(pts[i] + normal * offset * scale)
	return out


## Surface between two polylines of equal length, draped on the terrain,
## with (possibly different) heights above ground on each side.
func _add_strip(st: SurfaceTool, a: PackedVector2Array, b: PackedVector2Array, ya: float, yb: float, color: Color) -> void:
	var n := mini(a.size(), b.size())
	for i in n - 1:
		if a[i].distance_squared_to(a[i + 1]) < 1e-6:
			continue
		var a0 := Vector3(a[i].x, _ground(a[i].x, a[i].y) + ya, a[i].y)
		var a1 := Vector3(a[i + 1].x, _ground(a[i + 1].x, a[i + 1].y) + ya, a[i + 1].y)
		var b0 := Vector3(b[i].x, _ground(b[i].x, b[i].y) + yb, b[i].y)
		var b1 := Vector3(b[i + 1].x, _ground(b[i + 1].x, b[i + 1].y) + yb, b[i + 1].y)
		_tri_up(st, a0, b0, b1, color)
		_tri_up(st, a0, b1, a1, color)


## Flat strip along a polyline, mitred at joints (miter length clamped so
## sharp corners don't spike).
## With `uv`, U runs 0..1 across the strip and V along it in tile units.
func _add_ribbon(st: SurfaceTool, pts: PackedVector2Array, width: float, y: float, color: Color, uv: bool = false) -> void:
	var half := width * 0.5
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	var along := PackedFloat32Array()
	var n := pts.size()
	var dist := 0.0
	for i in n:
		if i > 0:
			dist += pts[i].distance_to(pts[i - 1])
		along.append(dist / Surfaces.TILE_M)
		var d_in := (pts[i] - pts[i - 1]).normalized() if i > 0 else Vector2.ZERO
		var d_out := (pts[i + 1] - pts[i]).normalized() if i < n - 1 else Vector2.ZERO
		var d := (d_in + d_out)
		if d.length_squared() < 1e-8:
			d = d_out if d_out != Vector2.ZERO else d_in
		d = d.normalized()
		var normal := Vector2(-d.y, d.x)
		var scale := 1.0
		if d_in != Vector2.ZERO and d_out != Vector2.ZERO:
			var c := normal.dot(Vector2(-d_out.y, d_out.x))
			scale = clampf(1.0 / maxf(c, 0.01), 1.0, 2.0)
		var off := normal * half * scale
		var l := pts[i] + off
		var r := pts[i] - off
		left.append(Vector3(l.x, _ground(l.x, l.y) + y, l.y))
		right.append(Vector3(r.x, _ground(r.x, r.y) + y, r.y))

	for i in n - 1:
		if pts[i].distance_squared_to(pts[i + 1]) < 1e-6:
			continue
		if uv:
			_tri_up(st, left[i], right[i], right[i + 1], color, Vector2(0, along[i]), Vector2(1, along[i]), Vector2(1, along[i + 1]))
			_tri_up(st, left[i], right[i + 1], left[i + 1], color, Vector2(0, along[i]), Vector2(1, along[i + 1]), Vector2(0, along[i + 1]))
		else:
			_tri_up(st, left[i], right[i], right[i + 1], color)
			_tri_up(st, left[i], right[i + 1], left[i + 1], color)


## Splits long segments so draped geometry follows the terrain.
func _subdivide(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var pieces := maxi(1, int(ceil(a.distance_to(b) / step)))
		for k in pieces:
			out.append(a.lerp(b, float(k) / pieces))
	out.append(pts[pts.size() - 1])
	return out


## Triangle facing upward (for ground-hugging surfaces on slopes).
func _tri_up(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color, uva := Vector2.ZERO, uvb := Vector2.ZERO, uvc := Vector2.ZERO) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	_tri(st, a, b, c, n if n.y >= 0.0 else -n, color, uva, uvb, uvc)


## Adds a triangle whose front face points along `normal`, whatever order
## the vertices arrive in. Godot treats clockwise winding (seen from the
## front) as front-facing, i.e. (b-a)x(c-a) points away from the viewer.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color, uva := Vector2.ZERO, uvb := Vector2.ZERO, uvc := Vector2.ZERO) -> void:
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var t := b
		b = c
		c = t
		var tu := uvb
		uvb = uvc
		uvc = tu
	st.set_color(color)
	st.set_normal(normal)
	st.set_uv(uva)
	st.add_vertex(a)
	st.set_color(color)
	st.set_normal(normal)
	st.set_uv(uvb)
	st.add_vertex(b)
	st.set_color(color)
	st.set_normal(normal)
	st.set_uv(uvc)
	st.add_vertex(c)


func _clean_ring(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-4:
			out.append(p)
	if out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) <= 1e-4:
		out.remove_at(out.size() - 1)
	return out


func _add_flat_polygon(st: SurfaceTool, pts: PackedVector2Array, y: float, color: Color) -> bool:
	var ring := _clean_ring(pts)
	if ring.size() < 3:
		return false
	var idx := Geometry2D.triangulate_polygon(ring)
	if idx.is_empty():
		return false
	for t in range(0, idx.size(), 3):
		var a := ring[idx[t]]
		var b := ring[idx[t + 1]]
		var c := ring[idx[t + 2]]
		_tri(st, Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), Vector3(c.x, y, c.y), Vector3.UP, color)
	return true


func _building_height(tags: Dictionary, id: int) -> Array:
	var height := -1.0
	var h := String(tags.get("height", "")).replace("m", "").strip_edges()
	if h.is_valid_float():
		height = h.to_float()
	var levels := String(tags.get("building:levels", ""))
	if height <= 0.0 and levels.is_valid_float():
		height = levels.to_float() * LEVEL_HEIGHT + 1.0
	if height <= 0.0:
		# Deterministic pseudo-random 1–3 storeys so untagged blocks vary.
		height = (1 + absi(hash(id)) % 3) * LEVEL_HEIGHT + 1.0
	var min_h := 0.0
	var mh := String(tags.get("min_height", "")).replace("m", "").strip_edges()
	if mh.is_valid_float():
		min_h = mh.to_float()
	return [min_h, maxf(height, min_h + 1.0)]


func _add_building(st: SurfaceTool, pts: PackedVector2Array, tags: Dictionary, id: int) -> bool:
	var ring := _clean_ring(pts)
	if ring.size() < 3:
		return false
	var hs := _building_height(tags, id)
	# On a slope: walls start below the lowest corner (so no gap shows on the
	# downhill side) and the height is measured from the average ground.
	var g_min := INF
	var g_max := -INF
	var g_sum := 0.0
	for p in ring:
		var g := _ground(p.x, p.y)
		g_min = minf(g_min, g)
		g_max = maxf(g_max, g)
		g_sum += g
	var g_mean := g_sum / ring.size()
	var y0: float = hs[0] + (g_min - 0.5 if _terrain != null else 0.0)
	var y1: float = hs[1] + (g_mean if _terrain != null else 0.0)
	var color: Color = BUILDING_PALETTE[absi(hash(id)) % BUILDING_PALETTE.size()]
	var base := g_mean if _terrain != null else 0.0
	# On a sloped lot the eaves still clear the uphill side by a full storey,
	# so the uphill wall keeps room for its door and garage.
	var eave_min: float = (g_max if _terrain != null else 0.0) + 2.7
	y1 = maxf(y1, eave_min)
	# A quarter of the houses are brick.
	var brick: bool = absi(hash(id * 7 + 3)) % 4 == 0 and hs[1] < 12.0
	if brick:
		color = BRICK_PALETTE[absi(hash(id)) % BRICK_PALETTE.size()]
		st = _bricks

	# House-sized, roughly rectangular footprints get a pitched roof (hip or
	# gable); walls stop at the eaves and the height tag is treated as the
	# ridge height.
	var hip := _hip_rect(ring, tags, hs[1])
	var ridge := 0.0
	var gable := false
	if not hip.is_empty():
		ring = hip["corners"]
		var rise: float = minf(hip["hw"] * HIP_PITCH, 3.5)
		y1 = maxf(eave_min, y1 - rise)
		ridge = y1 + rise
		gable = tags.get("roof:shape") == "gabled" or (tags.get("roof:shape") == null and absi(hash(id * 31)) % 5 < 2)
		stats["hip_roofs"] = stats.get("hip_roofs", 0) + 1

	occupancy.mark_polygon(ring, 1.0, Occupancy.BUILDING)
	var front := _front_edge(ring)
	building_list.append({"ring": ring, "rect": _rect_of(ring), "front": front, "height": y1 - base, "front_dir": Vector2.ZERO})

	# Walls: outward normal depends on ring orientation. Note the ring lives
	# in (x, z) with +z pointing south, so it is mirrored relative to the
	# y-up convention Geometry2D.is_polygon_clockwise() assumes.
	var ccw := Geometry2D.is_polygon_clockwise(ring)
	var n := ring.size()
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var e := b - a
		if e.length_squared() < 1e-6:
			continue
		# Right-hand perpendicular of the edge; flip for CCW rings.
		var out2 := Vector2(e.y, -e.x).normalized()
		if ccw:
			out2 = -out2
		var normal := Vector3(out2.x, 0.0, out2.y)
		var shade := color.darkened(0.12 * absf(out2.x))
		var a0 := Vector3(a.x, y0, a.y)
		var b0 := Vector3(b.x, y0, b.y)
		var a1 := Vector3(a.x, y1, a.y)
		var b1 := Vector3(b.x, y1, b.y)
		_tri(st, a0, b0, b1, normal, shade)
		_tri(st, a0, b1, a1, normal, shade)
		# Gable end: triangle up to the ridge on the two short walls.
		if gable and not hip.is_empty() and i % 2 == 1:
			var m := (a + b) * 0.5
			_tri(st, a1, b1, Vector3(m.x, ridge, m.y), normal, shade)
		var ground_here := maxf(_ground(a.x, a.y), _ground(b.x, b.y)) if _terrain != null else 0.0
		if hs[0] <= 0.0 and facades:
			var garage_at := _add_facade(_trim, a, b, out2, ground_here, y1, i == front, color)
			if garage_at >= 0.0:
				var dw := _driveway(a + (b - a).normalized() * garage_at, out2)
				if not dw.is_empty():
					_driveways.append(dw)
		if i == front:
			building_list[building_list.size() - 1]["front_dir"] = out2

	if not hip.is_empty():
		_add_hip_roof(_roofs, hip, y1, ridge, _roof_color(ring, id), gable)
		return true

	# Flat roof (gravel/membrane; world-mapped UVs). If triangulation fails
	# (self-intersecting footprint) we still keep the walls.
	var idx := Geometry2D.triangulate_polygon(ring)
	var roof := Color(0.55, 0.53, 0.50)
	for t in range(0, idx.size(), 3):
		var p := ring[idx[t]]
		var q := ring[idx[t + 1]]
		var r := ring[idx[t + 2]]
		_tri(_roofs, Vector3(p.x, y1, p.y), Vector3(q.x, y1, q.y), Vector3(r.x, y1, r.y), Vector3.UP, roof,
			p / Surfaces.TILE_M, q / Surfaces.TILE_M, r / Surfaces.TILE_M)
	return true


## Roof colour: the photo's average over the footprint when there is one
## (most of a footprint seen from above is roof), else from the palette.
func _roof_color(ring: PackedVector2Array, id: int) -> Color:
	if ortho != null:
		var c := ortho.mean_in_ring(ring, 1.5)
		if c.r >= 0.0:
			# Photos are lit; pull toward a mid tone so shading still shows.
			return c.lerp(Color(0.5, 0.5, 0.5), 0.15).clamp(Color(0.1, 0.1, 0.1), Color(0.85, 0.85, 0.85))
	return ROOF_PALETTE[absi(hash(id + 7)) % ROOF_PALETTE.size()]


## If the footprint is a small, nearly rectangular building, returns its
## oriented bounding box {corners, center, u, v, hl, hw} (u = long axis);
## otherwise {}.
func _hip_rect(ring: PackedVector2Array, tags: Dictionary, height: float) -> Dictionary:
	var shape := String(tags.get("roof:shape", ""))
	if shape != "" and shape != "hipped" and shape != "gabled":
		return {}
	if height > 12.0:
		return {}
	ring = _simplify_ring(ring, 0.7)
	if ring.size() > 24:
		return {}
	var area := 0.0
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		area += a.x * b.y - b.x * a.y
	area = absf(area) * 0.5
	if area < 25.0 or area > 900.0:
		return {}
	# Minimum-area box over the footprint's own edge directions.
	var best := {}
	var best_area := INF
	for i in ring.size():
		var e := ring[(i + 1) % ring.size()] - ring[i]
		if e.length_squared() < 0.25:
			continue
		var u := e.normalized()
		var v := Vector2(-u.y, u.x)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in ring:
			var q := Vector2(p.dot(u), p.dot(v))
			lo = lo.min(q)
			hi = hi.max(q)
		var box := (hi - lo).x * (hi - lo).y
		if box < best_area:
			best_area = box
			var mid := (lo + hi) * 0.5
			var ext := (hi - lo) * 0.5
			if ext.x < ext.y:  # make u the long axis
				best = {"u": v, "v": -u, "hl": ext.y, "hw": ext.x, "center": u * mid.x + v * mid.y}
			else:
				best = {"u": u, "v": v, "hl": ext.x, "hw": ext.y, "center": u * mid.x + v * mid.y}
	if best.is_empty() or area / best_area < HIP_MIN_FILL:
		return {}
	var c: Vector2 = best["center"]
	var bu: Vector2 = best["u"] * best["hl"]
	var bv: Vector2 = best["v"] * best["hw"]
	best["corners"] = PackedVector2Array([c + bu + bv, c - bu + bv, c - bu - bv, c + bu - bv])
	return best


func _add_hip_roof(st: SurfaceTool, hip: Dictionary, eave: float, ridge: float, color: Color, gable: bool = false) -> void:
	var c: Vector2 = hip["center"]
	var u: Vector2 = hip["u"]
	var v: Vector2 = hip["v"]
	var hl: float = hip["hl"] + ROOF_OVERHANG
	var hw: float = hip["hw"] + ROOF_OVERHANG
	var ey := eave - ROOF_OVERHANG * HIP_PITCH  # eaves droop with the pitch
	var ridge_half := hl if gable else maxf(hip["hl"] - hip["hw"], 0.0)
	var e := func(su: float, sv: float) -> Vector3:
		var p := c + u * hl * su + v * hw * sv
		return Vector3(p.x, ey, p.y)
	var r1 := Vector3((c + u * ridge_half).x, ridge, (c + u * ridge_half).y)
	var r2 := Vector3((c - u * ridge_half).x, ridge, (c - u * ridge_half).y)
	var dark := color.darkened(0.15)
	# Shingle rows run parallel to the eave: texture V is the up-slope
	# coordinate (across v for the long sides, across u for the hip ends).
	var uv_long := func(p: Vector3) -> Vector2:
		var q := Vector2(p.x, p.z) - c
		return Vector2(q.dot(u), q.dot(v)) / Surfaces.TILE_M
	var uv_end := func(p: Vector3) -> Vector2:
		var q := Vector2(p.x, p.z) - c
		return Vector2(q.dot(v), q.dot(u)) / Surfaces.TILE_M
	# Long sides (trapezoids) and hip ends (triangles).
	var a1: Vector3 = e.call(1, 1)
	var a2: Vector3 = e.call(-1, 1)
	var b1: Vector3 = e.call(-1, -1)
	var b2: Vector3 = e.call(1, -1)
	_tri_up(st, a1, a2, r2, color, uv_long.call(a1), uv_long.call(a2), uv_long.call(r2))
	_tri_up(st, a1, r2, r1, color, uv_long.call(a1), uv_long.call(r2), uv_long.call(r1))
	_tri_up(st, b1, b2, r1, dark, uv_long.call(b1), uv_long.call(b2), uv_long.call(r1))
	_tri_up(st, b1, r1, r2, dark, uv_long.call(b1), uv_long.call(r1), uv_long.call(r2))
	if not gable:
		_tri_up(st, b2, a1, r1, color.darkened(0.07), uv_end.call(b2), uv_end.call(a1), uv_end.call(r1))
		_tri_up(st, a2, b1, r2, color.darkened(0.07), uv_end.call(a2), uv_end.call(b1), uv_end.call(r2))


## Douglas-Peucker on a closed ring: drops the jitter real footprints carry.
func _simplify_ring(ring: PackedVector2Array, tol: float) -> PackedVector2Array:
	if ring.size() <= 4:
		return ring
	# Split at the two points furthest apart so each half is an open line.
	var far := 0
	var best := -1.0
	for i in ring.size():
		var d := ring[0].distance_squared_to(ring[i])
		if d > best:
			best = d
			far = i
	var a := _dp(ring.slice(0, far + 1), tol)
	var b_part := ring.slice(far)
	b_part.append(ring[0])
	var b := _dp(b_part, tol)
	var out := PackedVector2Array()
	out.append_array(a)
	out.append_array(b.slice(1, b.size() - 1))
	return out if out.size() >= 3 else ring


func _dp(line: PackedVector2Array, tol: float) -> PackedVector2Array:
	if line.size() < 3:
		return line
	var a := line[0]
	var b := line[line.size() - 1]
	var worst := 0.0
	var idx := 0
	for i in range(1, line.size() - 1):
		var d := line[i].distance_to(Geometry2D.get_closest_point_to_segment(line[i], a, b))
		if d > worst:
			worst = d
			idx = i
	if worst <= tol:
		return PackedVector2Array([a, b])
	var left := _dp(line.slice(0, idx + 1), tol)
	var right := _dp(line.slice(idx), tol)
	left.append_array(right.slice(1))
	return left


## Index of the wall edge that faces the nearest road (-1 if none within
## reach), found by stepping outward from each edge's midpoint.
func _front_edge(ring: PackedVector2Array) -> int:
	var ccw := Geometry2D.is_polygon_clockwise(ring)
	var best := -1
	var best_d := INF
	var n := ring.size()
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		if a.distance_to(b) < 3.5:
			continue
		var e := b - a
		var out2 := Vector2(e.y, -e.x).normalized()
		if ccw:
			out2 = -out2
		var m := (a + b) * 0.5
		for step in range(2, 30, 2):
			var p := m + out2 * step
			if occupancy.get_at(p.x, p.y) & Occupancy.ROAD:
				# Prefer longer walls when two are about as close.
				var d := step - a.distance_to(b) * 0.1
				if d < best_d:
					best_d = d
					best = i
				break
	return best


## Straight driveway from a garage door out to the nearest road, or empty
## if no road is found within DRIVEWAY_MAX metres in that direction.
func _driveway(from: Vector2, out2: Vector2) -> PackedVector2Array:
	var d := 1.0
	while d < DRIVEWAY_MAX:
		var p := from + out2 * d
		if occupancy.get_at(p.x, p.y) & Occupancy.ROAD:
			return PackedVector2Array([from + out2 * 0.2, p + out2 * 0.5])
		if occupancy.get_at(p.x, p.y) & (Occupancy.BUILDING | Occupancy.WATER) and d > 2.0:
			return PackedVector2Array()
		d += 1.0
	return PackedVector2Array()


## Windows on every wall; on the street-facing wall also a front door and,
## on houses wide enough, a garage door. Quads float 3 cm off the wall.
## Returns the garage door's centre distance along the wall, or -1.
func _add_facade(st: SurfaceTool, a: Vector2, b: Vector2, out2: Vector2, ground: float, top: float, is_front: bool, wall: Color) -> float:
	var garage_at := -1.0
	var length := a.distance_to(b)
	if length < 2.2 or top - ground < 2.4:
		return garage_at
	var dir := (b - a) / length
	var levels := maxi(1, int((top - ground) / LEVEL_HEIGHT_FACADE))
	var lh := (top - ground) / levels
	var n3 := Vector3(out2.x, 0.0, out2.y)
	var place := func(s0: float, s1: float, y0: float, y1: float, col: Color, depth: float) -> void:
		var p0 := a + dir * s0 + out2 * depth
		var p1 := a + dir * s1 + out2 * depth
		_quad_wall(st, Vector3(p0.x, y0, p0.y), Vector3(p1.x, y0, p1.y), Vector3(p1.x, y1, p1.y), Vector3(p0.x, y1, p0.y), n3, col)
	var win := func(s: float, y_base: float) -> void:
		place.call(s - 0.62, s + 0.62, y_base + 0.95, y_base + 2.25, COLOR_FRAME, 0.02)
		var p0 := a + dir * (s - 0.55) + out2 * 0.035
		var p1 := a + dir * (s + 0.55) + out2 * 0.035
		_quad_wall(_windows, Vector3(p0.x, y_base + 1.02, p0.y), Vector3(p1.x, y_base + 1.02, p1.y),
			Vector3(p1.x, y_base + 2.18, p1.y), Vector3(p0.x, y_base + 2.18, p0.y), n3, COLOR_WINDOW)

	for level in levels:
		var y_base := ground + level * lh
		var cursor := 0.7
		var end := length - 0.7
		if level == 0 and is_front:
			# Garage (2 bays) where the photo shows the driveway's concrete,
			# else at one end; front door beside it; windows in the gaps.
			var g0 := -1.0
			var g1 := -1.0
			if length >= 9.0:
				var gc := _garage_from_photo(a, dir, out2, length)
				if gc < 0.0:
					gc = cursor + 2.45
				g0 = gc - 2.45
				g1 = gc + 2.45
				place.call(g0, g1, y_base + 0.05, y_base + 2.25, COLOR_GARAGE, 0.03)
				for seam in [0.6, 1.2, 1.8]:
					place.call(g0 + 0.05, g1 - 0.05, y_base + seam - 0.015, y_base + seam + 0.015, COLOR_GARAGE.darkened(0.25), 0.04)
				garage_at = gc
			# Door in the larger remaining span, right next to the garage.
			var left_span := (g0 - cursor) if g0 >= 0.0 else 0.0
			var right_span := (end - g1) if g1 >= 0.0 else (end - cursor)
			var door_s := -1.0
			if g0 < 0.0:
				if right_span >= 1.6:
					door_s = cursor + 0.6
			elif right_span >= left_span and right_span >= 1.6:
				door_s = g1 + 0.6 + 0.48
			elif left_span >= 1.6:
				door_s = g0 - 0.6 - 0.48
			if door_s >= 0.0:
				place.call(door_s - 0.48, door_s + 0.48, y_base + 0.05, y_base + 2.1, COLOR_DOOR, 0.03)
				_walks.append([a + dir * door_s + out2 * 0.05, out2])
			# Windows in whatever is left, in order along the wall.
			var blocks: Array = []
			if g0 >= 0.0:
				blocks.append([g0 - 0.6, g1 + 0.6])
			if door_s >= 0.0:
				blocks.append([door_s - 1.1, door_s + 1.1])
			blocks.sort_custom(func(p, q): return p[0] < q[0])
			var at := cursor
			for blk in blocks:
				_fill_windows(win, at, minf(blk[0], end), y_base)
				at = maxf(at, blk[1])
			_fill_windows(win, at, end, y_base)
			continue
		_fill_windows(win, cursor, end, y_base)
	return garage_at


func _fill_windows(win: Callable, s0: float, s1: float, y_base: float) -> void:
	var span := s1 - s0
	if span < 1.5:
		return
	var count := maxi(1, int(span / 2.7))
	for k in count:
		win.call(s0 + span * (k + 0.5) / count, y_base)


## Centre (along the wall from `a`) of the driveway's concrete in the photo,
## found by scanning outward from each point of the front wall toward the
## street; -1 if the photo has no clear strip.
func _garage_from_photo(a: Vector2, dir: Vector2, out2: Vector2, length: float) -> float:
	if ortho == null:
		return -1.0
	var best_s := -1.0
	var best := 0
	var s := 2.6
	while s <= length - 2.6:
		var hits := 0
		var d := 1.5
		while d < 20.0:
			var p := a + dir * s + out2 * d
			if occupancy.get_at(p.x, p.y) & Occupancy.ROAD:
				break
			if ortho.is_concrete(p.x, p.y):
				hits += 1
			d += 1.5
		if hits > best:
			best = hits
			best_s = s
		s += 0.5
	return best_s if best >= 3 else -1.0


func _quad_wall(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, normal: Vector3, col: Color) -> void:
	_tri(st, p0, p1, p2, normal, col)
	_tri(st, p0, p2, p3, normal, col)


func make_ground(bounds: Rect2) -> StaticBody3D:
	var size := bounds.size + Vector2.ONE * GROUND_MARGIN * 2.0
	var center := bounds.get_center()
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.position = Vector3(center.x, 0.0, center.y)

	var mesh := PlaneMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR_GROUND
	mat.roughness = 1.0
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)

	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, 2.0, size.y)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = -1.0
	body.add_child(cs)
	return body


func _attach(root: Node3D, name: String, st: SurfaceTool, collide: bool, surface: String = "") -> void:
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, Surfaces.material(surface))

	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	if not collide:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
		return

	var body := StaticBody3D.new()
	body.name = name
	mi.name = "Mesh"
	body.add_child(mi)
	# Non-indexed triangle list, so the vertex array is already the face list.
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(arrays[Mesh.ARRAY_VERTEX])
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)


## Several surfaces in one mesh (one draw call each); collision is built
## from the surfaces flagged for it.
func _attach_multi(root: Node3D, name: String, parts: Array, collide: bool = true) -> void:
	var mesh := ArrayMesh.new()
	var faces := PackedVector3Array()
	for part in parts:
		var arrays: Array = (part[0] as SurfaceTool).commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, part[1] if part[1] is Material else Surfaces.material(part[1]))
		if part[2]:
			faces.append_array(arrays[Mesh.ARRAY_VERTEX])
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if not collide or faces.is_empty():
		mi.name = name
		root.add_child(mi)
		return
	var body := StaticBody3D.new()
	body.name = name
	mi.name = "Mesh"
	body.add_child(mi)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)


func _attach_water(root: Node3D, st: SurfaceTool) -> void:
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.30, 0.38, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	mat.metallic = 0.3
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
