extends RefCounted
## Turns parsed OSM data into renderable, collidable geometry:
## ground, land-use patches, road ribbons and extruded buildings.
##
## Everything of one kind is merged into a single mesh so a few thousand
## buildings stay at a handful of draw calls.

const OsmData := preload("res://scripts/osm_data.gd")

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
const COLOR_GRASS := Color(0.36, 0.55, 0.28)
const COLOR_WATER := Color(0.22, 0.42, 0.62)
const COLOR_PAVED := Color(0.55, 0.55, 0.55)
const COLOR_GROUND := Color(0.45, 0.50, 0.38)
const BUILDING_PALETTE := [
	Color(0.85, 0.80, 0.70), Color(0.75, 0.68, 0.60), Color(0.80, 0.55, 0.45),
	Color(0.70, 0.72, 0.75), Color(0.92, 0.90, 0.85), Color(0.60, 0.50, 0.42),
]

const LANDUSE_COLORS := {
	"landuse=grass": COLOR_GRASS, "landuse=meadow": COLOR_GRASS,
	"landuse=forest": Color(0.20, 0.40, 0.20), "natural=wood": Color(0.20, 0.40, 0.20),
	"leisure=park": COLOR_GRASS, "leisure=pitch": Color(0.30, 0.60, 0.30),
	"leisure=playground": Color(0.65, 0.55, 0.40), "landuse=recreation_ground": COLOR_GRASS,
	"natural=water": COLOR_WATER, "landuse=reservoir": COLOR_WATER,
	"amenity=parking": COLOR_PAVED, "landuse=residential": Color(0.50, 0.53, 0.45),
	"landuse=commercial": Color(0.55, 0.52, 0.50), "landuse=retail": Color(0.55, 0.52, 0.50),
}

## Populated by build(): a point on a drivable road and the road's heading
## (radians, Godot Y rotation) — used to place the player and a car.
var spawn_position := Vector3.ZERO
var spawn_yaw := 0.0
var stats := {"roads": 0, "buildings": 0, "areas": 0, "skipped": 0}


func build(data: OsmData) -> Node3D:
	var root := Node3D.new()
	root.name = "Map"

	var roads := SurfaceTool.new()
	roads.begin(Mesh.PRIMITIVE_TRIANGLES)
	var areas := SurfaceTool.new()
	areas.begin(Mesh.PRIMITIVE_TRIANGLES)
	var buildings := SurfaceTool.new()
	buildings.begin(Mesh.PRIMITIVE_TRIANGLES)

	var best_spawn_score := -INF
	var center := data.bounds.get_center()

	for way in data.ways:
		var tags: Dictionary = way["tags"]
		if tags.has("highway") and ROAD_WIDTHS.has(tags["highway"]) and tags.get("area") != "yes":
			var pts := data.way_points(way)
			if pts.size() < 2:
				stats["skipped"] += 1
				continue
			var hw: String = tags["highway"]
			var width := _road_width(tags)
			var foot := hw in FOOT_TYPES
			# Footpaths sit slightly lower so roads win where they overlap.
			_add_ribbon(roads, pts, width, 0.03 if foot else 0.05, COLOR_PATH if foot else COLOR_ROAD)
			stats["roads"] += 1
			if hw in DRIVABLE_TYPES:
				var score := _spawn_score(pts, center)
				if score > best_spawn_score:
					best_spawn_score = score
					_set_spawn(pts)
		elif (tags.has("building") or tags.has("building:part")) and data.is_closed(way):
			if _add_building(buildings, data.way_points(way), tags, way["id"]):
				stats["buildings"] += 1
			else:
				stats["skipped"] += 1
		elif data.is_closed(way):
			var color = _area_color(tags)
			if color != null and _add_flat_polygon(areas, data.way_points(way), 0.015, color):
				stats["areas"] += 1

	for rel in data.relations:
		var tags: Dictionary = rel["tags"]
		if tags.get("type") != "multipolygon" and tags.get("type") != "building":
			continue
		var is_building := tags.has("building")
		var color = null if is_building else _area_color(tags)
		if not is_building and color == null:
			continue
		for ring in data.relation_outer_rings(rel):
			var pts := data.ids_to_points(ring)
			if is_building:
				if _add_building(buildings, pts, tags, rel["id"]):
					stats["buildings"] += 1
			elif _add_flat_polygon(areas, pts, 0.015, color):
				stats["areas"] += 1

	root.add_child(make_ground(data.bounds))
	_attach(root, "Areas", areas, false)
	_attach(root, "Roads", roads, false)
	_attach(root, "Buildings", buildings, true)
	return root


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
	spawn_position = Vector3(mid.x, 0.0, mid.y)
	var dir := (b - a).normalized()
	# Godot's forward is -Z; yaw so that -Z points along the road.
	spawn_yaw = atan2(-dir.x, -dir.y)


## Flat strip along a polyline, mitred at joints (miter length clamped so
## sharp corners don't spike).
func _add_ribbon(st: SurfaceTool, pts: PackedVector2Array, width: float, y: float, color: Color) -> void:
	var half := width * 0.5
	var left := PackedVector3Array()
	var right := PackedVector3Array()
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
		var off := normal * half * scale
		left.append(Vector3(pts[i].x + off.x, y, pts[i].y + off.y))
		right.append(Vector3(pts[i].x - off.x, y, pts[i].y - off.y))

	for i in n - 1:
		if pts[i].distance_squared_to(pts[i + 1]) < 1e-6:
			continue
		_tri(st, left[i], right[i], right[i + 1], Vector3.UP, color)
		_tri(st, left[i], right[i + 1], left[i + 1], Vector3.UP, color)


## Adds a triangle whose front face points along `normal`, whatever order
## the vertices arrive in. Godot treats clockwise winding (seen from the
## front) as front-facing, i.e. (b-a)x(c-a) points away from the viewer.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color) -> void:
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var t := b
		b = c
		c = t
	st.set_color(color)
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_color(color)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_color(color)
	st.set_normal(normal)
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
	var y0: float = hs[0]
	var y1: float = hs[1]
	var color: Color = BUILDING_PALETTE[absi(hash(id)) % BUILDING_PALETTE.size()]

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

	# Flat roof. If triangulation fails (self-intersecting footprint) we
	# still keep the walls.
	var idx := Geometry2D.triangulate_polygon(ring)
	var roof := color.darkened(0.35)
	for t in range(0, idx.size(), 3):
		var p := ring[idx[t]]
		var q := ring[idx[t + 1]]
		var r := ring[idx[t + 2]]
		_tri(st, Vector3(p.x, y1, p.y), Vector3(q.x, y1, q.y), Vector3(r.x, y1, r.y), Vector3.UP, roof)
	return true


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


func _attach(root: Node3D, name: String, st: SurfaceTool, collide: bool) -> void:
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mesh.surface_set_material(0, mat)

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
