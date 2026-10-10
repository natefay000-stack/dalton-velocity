extends RefCounted
## Dresses the map with things the data doesn't contain: yard and park
## trees, hillside scrub, parked cars in driveways and along kerbs, street
## lights. Placement is seeded and uses the builder's occupancy grid so
## nothing lands on a road, house or the water. Everything is drawn with
## MultiMeshes (a handful of draw calls) with simple collision shapes.

const MapBuilder := preload("res://scripts/map_builder.gd")
const Occupancy := preload("res://scripts/occupancy.gd")
const CarMesh := preload("res://scripts/car_mesh.gd")

const TREE_TRUNK := Color(0.36, 0.26, 0.17)
const LEAF_COLORS := {
	"deciduous": Color(0.30, 0.50, 0.20), "conifer": Color(0.16, 0.34, 0.20),
	"scrub": Color(0.40, 0.46, 0.30),
}
const AREA_TREE_SPACING := {  # m² per tree
	"landuse=forest": 45.0, "natural=wood": 45.0, "leisure=park": 260.0,
	"landuse=grass": 420.0, "landuse=meadow": 700.0, "landuse=recreation_ground": 400.0,
	"landuse=cemetery": 200.0, "leisure=golf_course": 350.0,
}
const SCRUB_M2_PER := 900.0
const STREET_PARK_SPACING := 14.0
const STREET_PARK_CHANCE := 0.28
const DRIVEWAY_PARK_CHANCE := 0.55
const LIGHT_SPACING := {"tertiary": 45.0, "secondary": 40.0, "primary": 40.0, "residential": 70.0, "unclassified": 60.0}

var stats := {"trees": 0, "scrub": 0, "parked": 0, "lights": 0}
var _rng := RandomNumberGenerator.new()
var _ground: Callable
var _occ: Occupancy
var _bounds := Rect2()

# Instances collected per MultiMesh key.
## key ("deciduous", "car:sedan:3", ...) -> Array[Transform3D]; kept so tests and
## tools can read placements back (MultiMesh data is write-only headless).
var instances: Dictionary = {}
var _colors: Dictionary = {}     # key -> Array[Color]
var _shapes: Array = []          # [Shape3D, Transform3D]


func build(builder: MapBuilder, ground: Callable, seed: int = 1) -> Node3D:
	_rng.seed = seed
	_ground = ground
	_occ = builder.occupancy
	_bounds = _occ.rect.grow(-20.0)
	var root := Node3D.new()
	root.name = "Props"

	_place_yard_trees(builder.building_list)
	_place_area_trees(builder.area_list)
	_place_scrub()
	_place_parked_cars(builder.road_list)
	_place_street_lights(builder.road_list)

	var meshes := {
		"deciduous": _tree_mesh("deciduous"), "conifer": _tree_mesh("conifer"),
		"scrub": _tree_mesh("scrub"), "light": _light_mesh(),
	}
	for key in instances:
		var mesh: Mesh = meshes.get(key)
		if mesh == null and key.begins_with("car:"):
			var parts: PackedStringArray = key.split(":")
			mesh = CarMesh.build_body(parts[1], CarMesh.PAINTS[parts[2].to_int()])
		elif mesh == null and key.begins_with("wheel:"):
			mesh = CarMesh.build_wheel(key.split(":")[1])
		root.add_child(_multimesh(key, mesh))

	var body := StaticBody3D.new()
	body.name = "Collision"
	for item in _shapes:
		var cs := CollisionShape3D.new()
		cs.shape = item[0]
		cs.transform = item[1]
		body.add_child(cs)
	root.add_child(body)
	return root


# --- placement -------------------------------------------------------------

func _place_yard_trees(buildings: Array[Dictionary]) -> void:
	for b in buildings:
		if b["height"] > 12.0:
			continue
		var rect: Rect2 = b["rect"].grow(7.0)
		var planted := 0
		for attempt in 6:
			if planted >= 2:
				break
			var p := Vector2(_rng.randf_range(rect.position.x, rect.end.x), _rng.randf_range(rect.position.y, rect.end.y))
			if _rng.randf() > 0.5:
				continue
			if _try_tree(p, "deciduous" if _rng.randf() < 0.8 else "conifer", 1.6):
				planted += 1


func _place_area_trees(areas: Array[Dictionary]) -> void:
	for a in areas:
		var spacing: float = AREA_TREE_SPACING.get(a["kind"], 0.0)
		if spacing <= 0.0:
			continue
		var ring: PackedVector2Array = a["ring"]
		if ring.size() < 3:
			continue
		var rect := Rect2(ring[0], Vector2.ZERO)
		for p in ring:
			rect = rect.expand(p)
		var area := absf(_signed_area(ring))
		var want := int(area / spacing)
		var forest := spacing < 100.0
		var tries := 0
		var placed := 0
		while placed < want and tries < want * 6:
			tries += 1
			var p := Vector2(_rng.randf_range(rect.position.x, rect.end.x), _rng.randf_range(rect.position.y, rect.end.y))
			if not Geometry2D.is_point_in_polygon(p, ring):
				continue
			var kind := "conifer" if (forest and _rng.randf() < 0.6) or _rng.randf() < 0.25 else "deciduous"
			if _try_tree(p, kind, 1.5 if forest else 3.0):
				placed += 1


## Sparse sage/juniper over the open ground away from houses.
func _place_scrub() -> void:
	var want := int(_bounds.get_area() / SCRUB_M2_PER)
	for i in want:
		var p := Vector2(_rng.randf_range(_bounds.position.x, _bounds.end.x), _rng.randf_range(_bounds.position.y, _bounds.end.y))
		if not _occ.is_free(p.x, p.y, 2.0, Occupancy.BUILDING | Occupancy.ROAD | Occupancy.WATER | Occupancy.PATH | Occupancy.PROP):
			continue
		if not _occ.is_free(p.x, p.y, 10.0, Occupancy.BUILDING):
			continue
		_add_tree(p, "scrub", _rng.randf_range(0.6, 1.3))
		stats["scrub"] += 1


func _try_tree(p: Vector2, kind: String, clearance: float) -> bool:
	if not _bounds.has_point(p):
		return false
	if not _occ.is_free(p.x, p.y, clearance, Occupancy.BUILDING | Occupancy.ROAD | Occupancy.WATER | Occupancy.PATH | Occupancy.PROP):
		return false
	_add_tree(p, kind, _rng.randf_range(0.75, 1.35))
	_occ.mark_disc(p.x, p.y, 2.0, Occupancy.PROP)
	stats["trees"] += 1
	return true


func _add_tree(p: Vector2, kind: String, scale: float) -> void:
	var y: float = _ground.call(p.x, p.y)
	var xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * scale), Vector3(p.x, y - 0.1, p.y))
	var tint := Color(_rng.randf_range(0.85, 1.1), _rng.randf_range(0.85, 1.1), _rng.randf_range(0.85, 1.05))
	_push(kind, xf, tint)
	if kind != "scrub":
		var shape := CylinderShape3D.new()
		shape.radius = 0.22 * scale
		shape.height = 3.0
		_shapes.append([shape, Transform3D(Basis.IDENTITY, Vector3(p.x, y + 1.5, p.y))])


func _place_parked_cars(roads: Array[Dictionary]) -> void:
	for r in roads:
		var pts: PackedVector2Array = r["pts"]
		if r["service"] == "driveway" and pts.size() >= 2:
			if _rng.randf() > DRIVEWAY_PARK_CHANCE:
				continue
			var total := _length(pts)
			if total < 6.0:
				continue
			var at := _point_at(pts, total * 0.5)
			var dir: Vector2 = at[1]
			# Nose toward the house (away from the street end).
			var street_end := pts[0]
			if _occ.get_at(pts[pts.size() - 1].x, pts[pts.size() - 1].y) & Occupancy.ROAD and not (_occ.get_at(pts[0].x, pts[0].y) & Occupancy.ROAD):
				street_end = pts[pts.size() - 1]
			if (at[0] - street_end).dot(dir) < 0.0:
				dir = -dir
			_try_park(at[0], dir, 1.0)
		elif r["highway"] in ["residential", "unclassified", "living_street"]:
			var total := _length(pts)
			if total < 30.0:
				continue
			var half: float = r["width"] * 0.5
			var d := 10.0 + _rng.randf() * STREET_PARK_SPACING
			while d < total - 10.0:
				if _rng.randf() < STREET_PARK_CHANCE:
					var at := _point_at(pts, d)
					var dir: Vector2 = at[1]
					var side := 1.0 if _rng.randf() < 0.5 else -1.0
					# Right-hand traffic: cars on the right of the road face
					# along it, on the left face against it.
					var normal := Vector2(-dir.y, dir.x) * side
					var pos: Vector2 = at[0] + normal * (half - 1.05)
					_try_park(pos, dir if side > 0.0 else -dir, 2.8)
				d += STREET_PARK_SPACING


func _try_park(pos: Vector2, dir: Vector2, clearance: float) -> void:
	if not _bounds.has_point(pos):
		return
	if not _occ.is_free(pos.x, pos.y, clearance, Occupancy.BUILDING | Occupancy.PROP | Occupancy.DRIVEWAY | Occupancy.WATER):
		return
	var style: String = ["sedan", "sedan", "suv", "suv", "pickup"][_rng.randi() % 5]
	var paint := _rng.randi() % CarMesh.PAINTS.size()
	var y: float = _ground.call(pos.x, pos.y) + 0.12
	# Godot's forward is -Z; yaw so the nose points along dir.
	var yaw := atan2(-dir.x, -dir.y)
	var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, y, pos.y))
	_push("car:%s:%d" % [style, paint], xf, Color.WHITE)
	for w in CarMesh.wheel_positions(style):
		_push("wheel:" + style, xf * Transform3D(Basis.IDENTITY, w), Color.WHITE)
	var d := CarMesh.dims(style)
	var shape := BoxShape3D.new()
	shape.size = d["box_size"]
	_shapes.append([shape, xf * Transform3D(Basis.IDENTITY, d["box_center"])])
	_occ.mark_polyline(PackedVector2Array([pos - dir * d["length"] * 0.5, pos + dir * d["length"] * 0.5]), d["width"] * 0.5 + 0.3, Occupancy.PROP)
	stats["parked"] += 1


func _place_street_lights(roads: Array[Dictionary]) -> void:
	for r in roads:
		var spacing: float = LIGHT_SPACING.get(r["highway"], 0.0)
		if spacing <= 0.0:
			continue
		var pts: PackedVector2Array = r["pts"]
		var total := _length(pts)
		var half: float = r["width"] * 0.5
		var d := spacing * 0.5
		var side := 1.0
		while d < total:
			var at := _point_at(pts, d)
			var dir: Vector2 = at[1]
			var normal := Vector2(-dir.y, dir.x) * side
			var pos: Vector2 = at[0] + normal * (half + MapBuilder.CURB_WIDTH + 0.7)
			if _bounds.has_point(pos) and _occ.is_free(pos.x, pos.y, 0.8, Occupancy.BUILDING | Occupancy.PROP | Occupancy.WATER):
				var y: float = _ground.call(pos.x, pos.y)
				# Arm points back toward the road (-normal); the mesh's arm is along -Z.
				var yaw := atan2(normal.x, normal.y)
				var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, y, pos.y))
				_push("light", xf, Color.WHITE)
				var shape := CylinderShape3D.new()
				shape.radius = 0.12
				shape.height = 7.0
				_shapes.append([shape, Transform3D(Basis.IDENTITY, Vector3(pos.x, y + 3.5, pos.y))])
				_occ.mark_disc(pos.x, pos.y, 1.0, Occupancy.PROP)
				stats["lights"] += 1
			d += spacing
			side = -side


# --- meshes ----------------------------------------------------------------

func _tree_mesh(kind: String) -> ArrayMesh:
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaves := SurfaceTool.new()
	leaves.begin(Mesh.PRIMITIVE_TRIANGLES)
	match kind:
		"deciduous":
			trunk.append_from(_cyl(0.14, 0.22, 2.6), 0, Transform3D(Basis.IDENTITY, Vector3(0, 1.3, 0)))
			for blob in [[Vector3(0, 4.3, 0), 2.0], [Vector3(0.9, 3.5, 0.5), 1.5], [Vector3(-0.8, 3.7, -0.6), 1.4], [Vector3(0.2, 5.4, -0.3), 1.3]]:
				leaves.append_from(_sphere(blob[1]), 0, Transform3D(Basis.IDENTITY, blob[0]))
		"conifer":
			trunk.append_from(_cyl(0.10, 0.20, 2.0), 0, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))
			for tier in [[1.5, 2.2, 2.6], [3.6, 1.7, 2.6], [5.6, 1.2, 2.4]]:
				leaves.append_from(_cone(tier[1], tier[2]), 0, Transform3D(Basis.IDENTITY, Vector3(0, tier[0] + tier[2] * 0.5, 0)))
		"scrub":
			for blob in [[Vector3(0, 0.55, 0), 0.7], [Vector3(0.5, 0.45, 0.3), 0.5], [Vector3(-0.45, 0.4, -0.2), 0.45]]:
				leaves.append_from(_sphere(blob[1]), 0, Transform3D(Basis.IDENTITY, blob[0]))
	var mesh := ArrayMesh.new()
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = LEAF_COLORS[kind]
	leaf_mat.vertex_color_use_as_albedo = true  # multiplied by the instance tint
	leaf_mat.roughness = 1.0
	if kind != "scrub":
		mesh = trunk.commit()
		var bark := StandardMaterial3D.new()
		bark.albedo_color = TREE_TRUNK
		bark.vertex_color_use_as_albedo = true
		bark.roughness = 1.0
		mesh.surface_set_material(0, bark)
	mesh = leaves.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, leaf_mat)
	return mesh


func _light_mesh() -> ArrayMesh:
	var pole := SurfaceTool.new()
	pole.begin(Mesh.PRIMITIVE_TRIANGLES)
	pole.append_from(_cyl(0.07, 0.11, 7.0), 0, Transform3D(Basis.IDENTITY, Vector3(0, 3.5, 0)))
	var arm := BoxMesh.new()
	arm.size = Vector3(0.1, 0.1, 1.8)
	pole.append_from(arm, 0, Transform3D(Basis.IDENTITY, Vector3(0, 6.9, -0.9)))
	var mesh := pole.commit()
	var gray := StandardMaterial3D.new()
	gray.albedo_color = Color(0.45, 0.46, 0.48)
	gray.metallic = 0.4
	gray.roughness = 0.5
	mesh.surface_set_material(0, gray)
	var head := SurfaceTool.new()
	head.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hb := BoxMesh.new()
	hb.size = Vector3(0.35, 0.18, 0.7)
	head.append_from(hb, 0, Transform3D(Basis.IDENTITY, Vector3(0, 6.85, -1.7)))
	mesh = head.commit(mesh)
	var lamp := StandardMaterial3D.new()
	lamp.albedo_color = Color(0.9, 0.9, 0.85)
	lamp.emission_enabled = true
	lamp.emission = Color(1.0, 0.95, 0.8)
	lamp.emission_energy_multiplier = 0.6
	mesh.surface_set_material(1, lamp)
	return mesh


func _cyl(top: float, bottom: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = 7
	m.rings = 1
	return m


func _cone(radius: float, height: float) -> CylinderMesh:
	var m := _cyl(0.0, radius, height)
	m.radial_segments = 8
	return m


func _sphere(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 8
	m.rings = 5
	return m


func _multimesh(name: String, mesh: Mesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var xfs: Array = instances[name]
	var cols: Array = _colors[name]
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, cols[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name.replace(":", "_")
	mmi.multimesh = mm
	return mmi


func _push(key: String, xf: Transform3D, color: Color) -> void:
	if not instances.has(key):
		instances[key] = []
		_colors[key] = []
	instances[key].append(xf)
	_colors[key].append(color)


# --- geometry helpers ------------------------------------------------------

func _length(pts: PackedVector2Array) -> float:
	var t := 0.0
	for i in pts.size() - 1:
		t += pts[i].distance_to(pts[i + 1])
	return t


## [point, unit direction] at distance d along the polyline.
func _point_at(pts: PackedVector2Array, d: float) -> Array:
	var left := d
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if seg <= 0.0:
			continue
		if left <= seg:
			var dir := (pts[i + 1] - pts[i]) / seg
			return [pts[i] + dir * left, dir]
		left -= seg
	var n := pts.size()
	return [pts[n - 1], (pts[n - 1] - pts[n - 2]).normalized() if n >= 2 else Vector2.RIGHT]


func _signed_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5
