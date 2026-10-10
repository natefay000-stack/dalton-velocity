extends SceneTree
## Headless test runner:
##   godot --headless --path game --script res://tests/run_tests.gd
## Exits non-zero on failure.

const OsmData := preload("res://scripts/osm_data.gd")
const MapBuilder := preload("res://scripts/map_builder.gd")
const Humanoid := preload("res://scripts/humanoid.gd")
const GltfCharacter := preload("res://scripts/gltf_character.gd")
const Terrain := preload("res://scripts/terrain.gd")
const Occupancy := preload("res://scripts/occupancy.gd")
const PropsBuilder := preload("res://scripts/props_builder.gd")
const Pedestrians := preload("res://scripts/pedestrians.gd")
const CarMesh := preload("res://scripts/car_mesh.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Daylight := preload("res://scripts/daylight.gd")
const Ortho := preload("res://scripts/ortho.gd")

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failures += 1
		printerr("  FAIL ", msg)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("parser")
	test_sample_parse()
	test_bad_inputs()
	test_multipolygon()
	print("character")
	test_humanoid()
	test_clip_matching()
	print("terrain")
	await test_terrain()
	print("props")
	await test_props()
	print("ortho")
	await test_ortho()
	print("daylight")
	test_daylight()
	print("physics")
	await test_gameplay()
	print("%s (%d failure%s)" % ["PASSED" if failures == 0 else "FAILED", failures, "" if failures == 1 else "s"])
	quit(1 if failures else 0)


func test_sample_parse() -> void:
	var d := OsmData.new()
	check(d.parse_file("res://maps/sample.osm") == OK, "sample.osm parses")
	check(d.points.size() == 1051, "all 1051 nodes projected (got %d)" % d.points.size())
	check(d.ways.size() == 291, "all 291 ways read (got %d)" % d.ways.size())
	# Grid is 4 x 110 m blocks centred on the origin.
	# Grid is 440 m; the declared <bounds> adds a 60 m margin each side.
	check(absf(d.bounds.size.x - 560.0) < 1.0, "east-west extent from <bounds> ~560 m (got %.2f)" % d.bounds.size.x)
	check(absf(d.bounds.size.y - 560.0) < 1.0, "north-south extent from <bounds> ~560 m (got %.2f)" % d.bounds.size.y)
	check(d.bounds.get_center().length() < 1.0, "map centred on origin")
	# Node 1 is the north-west grid corner: x = -220 (west), z = -220 (north).
	var p: Vector2 = d.points[1]
	check(p.distance_to(Vector2(-220, -220)) < 0.5, "north-west corner projects to (-220,-220) (got %s)" % p)

	var b := MapBuilder.new()
	var root := b.build(d)
	check(b.stats["roads"] == 41, "10 streets in 4 blocks each + 1 footway (got %d)" % b.stats["roads"])
	check(b.stats["buildings"] == 127, "120 houses + 7 L-shaped blocks (got %d)" % b.stats["buildings"])
	check(b.stats["areas"] == 3, "park + pond + pool (got %d)" % b.stats["areas"])
	check(b.stats["skipped"] == 0, "nothing skipped")
	check(root.has_node("Buildings/Mesh") and root.has_node("Roads") and root.has_node("Ground"), "scene nodes built")
	var faces: PackedVector3Array = (root.get_node("Buildings/CollisionShape3D") as CollisionShape3D).shape.get_faces()
	check(faces.size() > 1000 and faces.size() % 3 == 0, "building collision has %d tris" % (faces.size() / 3))
	check(b.spawn_position.length() < 120.0, "spawn near map centre (%s)" % b.spawn_position)
	root.free()


func test_bad_inputs() -> void:
	check(OsmData.new().parse_file("res://maps/does_not_exist.osm") == ERR_FILE_NOT_FOUND, "missing file -> ERR_FILE_NOT_FOUND")
	var path := "user://empty_test.osm"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string('<?xml version="1.0"?><osm version="0.6"></osm>')
	f.close()
	check(OsmData.new().parse_file(path) == ERR_INVALID_DATA, "file with no nodes -> ERR_INVALID_DATA")

	# Way referencing nodes outside the extract must not crash the builder.
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("""<osm><node id="1" lat="0" lon="0"/><node id="2" lat="0.0001" lon="0"/>
<way id="1"><nd ref="1"/><nd ref="999"/><tag k="highway" v="residential"/></way>
<way id="2"><nd ref="1"/><nd ref="2"/><nd ref="998"/><nd ref="1"/><tag k="building" v="yes"/></way>
<way id="3"><nd ref="1"/><nd ref="2"/><tag k="highway" v="residential"/></way></osm>""")
	f.close()
	var d := OsmData.new()
	check(d.parse_file(path) == OK, "partial extract parses")
	var b := MapBuilder.new()
	var root := b.build(d)
	check(b.stats["roads"] == 1 and b.stats["skipped"] == 2, "dangling refs skipped (roads=%d skipped=%d)" % [b.stats["roads"], b.stats["skipped"]])
	root.free()


func test_multipolygon() -> void:
	# Square building split across two unclosed outer ways, one reversed.
	var path := "user://mp_test.osm"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("""<osm>
<node id="1" lat="0" lon="0"/><node id="2" lat="0" lon="0.0002"/>
<node id="3" lat="0.0002" lon="0.0002"/><node id="4" lat="0.0002" lon="0"/>
<way id="10"><nd ref="1"/><nd ref="2"/><nd ref="3"/></way>
<way id="11"><nd ref="1"/><nd ref="4"/><nd ref="3"/></way>
<relation id="5"><member type="way" ref="10" role="outer"/><member type="way" ref="11" role="outer"/>
<tag k="type" v="multipolygon"/><tag k="building" v="yes"/></relation></osm>""")
	f.close()
	var d := OsmData.new()
	d.parse_file(path)
	var rings := d.relation_outer_rings(d.relations[0])
	check(rings.size() == 1 and rings[0].size() == 5, "two half-rings join into one closed ring")
	var b := MapBuilder.new()
	var root := b.build(d)
	check(b.stats["buildings"] == 1, "multipolygon building extruded")

	# Every face must point outward (normal away from the footprint centre,
	# roof up) and be wound so Godot renders it from that side: clockwise
	# front faces mean (b-a)x(c-a) points against the normal.
	var mesh: ArrayMesh = (root.get_node("Buildings/Mesh") as MeshInstance3D).mesh
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var centre := Vector3.ZERO
	for p in v:
		centre += p
	centre /= v.size()
	var outward := true
	var wound := true
	for t in range(0, v.size(), 3):
		var face_mid := (v[t] + v[t + 1] + v[t + 2]) / 3.0
		var away := face_mid - centre
		away.y = maxf(away.y, 0.0) if n[t].y > 0.5 else 0.0
		outward = outward and n[t].dot(away) > 0.0
		wound = wound and (v[t + 1] - v[t]).cross(v[t + 2] - v[t]).dot(n[t]) < 0.0
	check(outward, "building normals point outward")
	check(wound, "building triangles front-face outward")
	root.free()


## Lowest actual vertex (not bounding box) of all meshes under `n`.
func _lowest_mesh_y(n: Node) -> float:
	var lo := INF
	if n is MeshInstance3D:
		var xf: Transform3D = n.global_transform
		for v in n.mesh.get_faces():
			lo = minf(lo, (xf * v).y)
	for c in n.get_children():
		lo = minf(lo, _lowest_mesh_y(c))
	return lo


func _highest_mesh_y(n: Node) -> float:
	var hi := -INF
	if n is MeshInstance3D:
		var b: AABB = n.global_transform * n.get_aabb()
		hi = b.end.y
	for c in n.get_children():
		hi = maxf(hi, _highest_mesh_y(c))
	return hi


func test_humanoid() -> void:
	var h: Node3D = Humanoid.new()
	h.build()
	root.add_child(h)
	var dt := 1.0 / 60.0
	for i in 30:
		h.update_motion(dt, Vector3.ZERO, true)
	var low := _lowest_mesh_y(h)
	var high := _highest_mesh_y(h)
	check(absf(low) < 0.005, "idle: soles on the ground (lowest y=%.3f)" % low)
	check(high > 1.70 and high < 1.90, "adult height (top y=%.2f)" % high)

	for case in [["walk", 1.6, 0.0], ["jog", 4.0, 0.0], ["sprint", 7.0, 0.0], ["walk+turn", 1.6, 0.6]]:
		_check_planting(h, case[0], case[1], case[2])

	# Stop mid-stride: feet step back under the body and stay put.
	for i in 90:
		h.update_motion(dt, Vector3.ZERO, true)
	var off := 0.0
	for side in ["l", "r"]:
		var a: Vector3 = h.joints["ankle_" + side].global_position
		off = maxf(off, Vector2(a.x - h._rest_world(side).x, a.z - h._rest_world(side).z).length())
	check(off < h.SETTLE_DISTANCE + 0.01, "stopping: feet settle under body (max offset %.3f m)" % off)

	# Teleport (e.g. leaving the car): feet follow instead of stretching.
	h.global_position += Vector3(25, 0, -10)
	h.update_motion(dt, Vector3.ZERO, true)
	var a: Vector3 = h.joints["ankle_l"].global_position
	check(a.distance_to(h._rest_world("l")) < 0.05, "teleport: feet reset to body")

	# Same seed -> same look; the look varies across seeds.
	var colors := {}
	for seed in 8:
		var hh: Node3D = Humanoid.new()
		hh.look_seed = seed
		hh.build()
		colors[str(hh._mats["skin"].albedo_color, hh._mats["shirt"].albedo_color)] = true
		hh.free()
	check(colors.size() > 3, "look_seed varies appearance (%d distinct looks of 8)" % colors.size())
	h.free()


## Moves the humanoid at `speed` (turning at `turn_rate` rad/s) for 4 s and
## checks that planted feet neither slide nor sink, and the IK hits its
## targets.
func _check_planting(h: Node3D, label: String, speed: float, turn_rate: float) -> void:
	var dt := 1.0 / 60.0
	var max_slide := 0.0
	var max_ik_err := 0.0
	var lowest := INF
	var stance_low := -INF
	var planted_frames := 0
	var thigh_min := INF
	var thigh_max := -INF
	var prev := {}
	for i in 240:
		h.rotation.y += turn_rate * dt
		var vel: Vector3 = h.global_basis * Vector3(0, 0, -speed)
		h.global_position += vel * dt
		h.update_motion(dt, vel, true)
		lowest = minf(lowest, _lowest_mesh_y(h))
		thigh_min = minf(thigh_min, h._pose["hip_l"])
		thigh_max = maxf(thigh_max, h._pose["hip_l"])
		for side in ["l", "r"]:
			var f: Dictionary = h._feet[side]
			var ankle: Vector3 = h.joints["ankle_" + side].global_position
			var want: Vector3 = f["pos"] + Vector3(0, f["lift"], 0)
			if i > 30:
				max_ik_err = maxf(max_ik_err, ankle.distance_to(want))
			if f["planted"] and prev.get(side) != null and i > 30:
				var p: Vector3 = prev[side]
				max_slide = maxf(max_slide, Vector2(ankle.x - p.x, ankle.z - p.z).length())
				planted_frames += 1
				stance_low = maxf(stance_low, ankle.y - f["lift"])
			prev[side] = ankle if f["planted"] else null
	check(planted_frames > 60, "%s: feet spend time planted (%d foot-frames)" % [label, planted_frames])
	check(max_slide < 0.003, "%s: planted feet don't slide (max %.1f mm/frame)" % [label, max_slide * 1000.0])
	check(max_ik_err < 0.01, "%s: IK reaches foot targets (max error %.1f mm)" % [label, max_ik_err * 1000.0])
	check(lowest > -0.005, "%s: nothing sinks below the ground (lowest y=%.3f)" % [label, lowest])
	check(absf(stance_low - h.ANKLE) < 0.005, "%s: stance ankle at ground height" % label)
	check(thigh_max - thigh_min > 0.4, "%s: legs swing (%.2f..%.2f rad)" % [label, thigh_min, thigh_max])


func test_clip_matching() -> void:
	var mixamo := GltfCharacter.pick_clips(PackedStringArray(["Idle", "Run", "TPose", "Walk"]))
	check(mixamo == {"idle": "Idle", "walk": "Walk", "run": "Run", "air": ""}, "Mixamo-style names %s" % mixamo)
	var blender := GltfCharacter.pick_clips(PackedStringArray([
		"Armature|Idle_Loop", "Armature|Walk_Loop", "Armature|Walk_Carry_Loop",
		"Armature|Jog_Fwd_Loop", "Armature|Jump_Start", "Armature|Jump_Loop", "Armature|T-Pose"]))
	check(blender["walk"] == "Armature|Walk_Loop", "shortest walk clip wins (%s)" % blender["walk"])
	check(blender["run"] == "Armature|Jog_Fwd_Loop", "jog counts as run (%s)" % blender["run"])
	check(blender["air"] == "Armature|Jump_Loop", "jump start excluded (%s)" % blender["air"])
	var walk_only := GltfCharacter.pick_clips(PackedStringArray(["walking"]))
	check(walk_only["run"] == "walking" and walk_only["idle"] == "", "missing run falls back to walk")
	check(GltfCharacter.load_from("res://does/not/exist.glb") == null, "missing model -> null (procedural fallback)")


## Writes a .height file over the sample map: a 12% east-up slope with
## north-south undulation, so every terrain path is exercised without
## downloaded data.
func _write_test_height(d: OsmData, path: String) -> void:
	var b: Dictionary = d._bounds_tag
	var cols := 141
	var rows := 141
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("HGT1".to_ascii_buffer())
	for v in [b["minlat"], b["minlon"], b["maxlat"], b["maxlon"]]:
		f.store_double(v)
	f.store_32(cols)
	f.store_32(rows)
	for r in rows:
		for c in cols:
			var x := 560.0 * c / (cols - 1)
			var z := 560.0 * r / (rows - 1)
			f.store_float(1400.0 + 0.12 * x + 4.0 * sin(z / 35.0))
	f.close()


func test_terrain() -> void:
	var d := OsmData.new()
	d.parse_file("res://maps/sample.osm")
	var path := "user://terrain_test.height"
	_write_test_height(d, path)
	var t := Terrain.new()
	check(t.load_file(path, d) == OK, "height file loads")
	check(absf(t.base_elevation - 1396.0) < 0.5, "base elevation subtracted (%.1f)" % t.base_elevation)
	check(t.get_rect().grow(1.0).encloses(d.bounds), "terrain covers the map bounds")
	var bad := "user://bad.height"
	var bf := FileAccess.open(bad, FileAccess.WRITE)
	bf.store_buffer("NOPE".to_ascii_buffer())
	bf.close()
	check(Terrain.new().load_file(bad, d) != OK, "corrupt height file rejected")

	var b := MapBuilder.new()
	b.facades = false  # bare walls, so wall corners can be told apart below
	var map := b.build(d, t)
	root.add_child(map)
	await physics_frame
	await physics_frame

	# Collision surface == height_at() everywhere (same triangle split).
	var space := map.get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	var rect := t.get_rect().grow(-2.0)
	for i in 200:
		var x := rng.randf_range(rect.position.x, rect.end.x)
		var z := rng.randf_range(rect.position.y, rect.end.y)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 500, z), Vector3(x, -50, z))
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and hit["collider"].name == "Terrain":
			worst = maxf(worst, absf(hit["position"].y - t.height_at(x, z)))
	check(worst < 0.01, "terrain collision matches height_at (worst %.4f m)" % worst)

	# Roads draped just above the ground; buildings reach into it.
	var road_v: PackedVector3Array = (map.get_node("Roads") as MeshInstance3D).mesh.get_faces()
	var lo := INF
	var hi := -INF
	for v in road_v:
		var gap := v.y - t.height_at(v.x, v.z)
		lo = minf(lo, gap)
		hi = maxf(hi, gap)
	check(lo > 0.03 and hi < 0.25, "roads hug the terrain (gap %.3f..%.3f m)" % [lo, hi])
	# Road beds are flat across: left and right edges of a road at the
	# same station sit at the same height even on the 12% cross-slope.
	var worst_tilt := 0.0
	for r in b.road_list:
		if r["highway"] != "residential":
			continue
		var pts: PackedVector2Array = r["pts"]
		for i in range(1, pts.size() - 1, 3):
			var dir2 := (pts[i + 1] - pts[i - 1]).normalized()
			var n: Vector2 = Vector2(-dir2.y, dir2.x) * (r["width"] * 0.5)
			var left: Vector2 = pts[i] + n
			var right: Vector2 = pts[i] - n
			worst_tilt = maxf(worst_tilt, absf(t.height_at(left.x, left.y) - t.height_at(right.x, right.y)))
	check(worst_tilt < 0.12, "road beds flat across the slope (worst edge difference %.2f m)" % worst_tilt)
	check(b.stats.get("road_beds", 0) >= 40, "road beds cut (%d)" % b.stats.get("road_beds", 0))
	var floating := 0
	var bld: PackedVector3Array = (map.get_node("Buildings/Mesh") as MeshInstance3D).mesh.get_faces()
	# Wall corners are the xz columns holding both a bottom and a top vertex
	# (roof overhangs and ridges are single-height columns).
	var col_min := {}
	var col_max := {}
	for v in bld:
		var key := Vector2i(roundi(v.x * 10), roundi(v.z * 10))
		col_min[key] = minf(col_min.get(key, INF), v.y)
		col_max[key] = maxf(col_max.get(key, -INF), v.y)
	var walls := 0
	for key in col_min:
		# Door, garage and window quads span at most 2.3 m; walls span more.
		if col_max[key] - col_min[key] < 2.5:
			continue
		walls += 1
		if col_min[key] > t.height_at(key.x / 10.0, key.y / 10.0) + 0.01:
			floating += 1
	check(walls > 400, "found wall corners to check (%d)" % walls)
	check(floating == 0, "no building corner floats above the slope (%d)" % floating)
	check(b.stats.get("hip_roofs", 0) >= 115, "houses incl. L-shapes get pitched roofs; only tall blocks stay flat (%d)" % b.stats.get("hip_roofs", 0))
	check(absf(b.spawn_position.y - t.height_at(b.spawn_position.x, b.spawn_position.z)) < 0.01, "spawn on the ground")

	# Walking uphill: planted feet sit on the slope, don't slide or sink.
	var h: Node3D = Humanoid.new()
	h.build()
	root.add_child(h)
	var start := Vector3(-150, 0, 40)
	start.y = t.height_at(start.x, start.z)
	h.global_position = start
	h.rotation.y = -PI / 2  # face +X = uphill
	var dt := 1.0 / 60.0
	for i in 20:
		h.update_motion(dt, Vector3.ZERO, true)
	var vel := Vector3(1.6, 0, 0)
	var max_slide := 0.0
	var max_sink := 0.0
	var max_gap := 0.0
	var prev := {}
	for i in 240:
		var p := h.global_position + vel * dt
		p.y = t.height_at(p.x, p.z)
		h.global_position = p
		h.update_motion(dt, vel, true)
		await physics_frame
		for side in ["l", "r"]:
			var f: Dictionary = h._feet[side]
			var ankle: Vector3 = h.joints["ankle_" + side].global_position
			if f["planted"] and i > 40:
				var g := t.height_at(f["pos"].x, f["pos"].z)
				max_gap = maxf(max_gap, absf(f["pos"].y - (g + h.ANKLE * (f["n"] as Vector3).y)))
				if prev.get(side) != null:
					# Horizontal only: the heel rising at toe-off is intended.
					var pv: Vector3 = prev[side]
					max_slide = maxf(max_slide, Vector2(ankle.x - pv.x, ankle.z - pv.z).length())
			prev[side] = ankle if f["planted"] else null
		if i > 40 and i % 4 == 0:
			for side in ["l", "r"]:
				var ankle_node: Node3D = h.joints["ankle_" + side]
				for mi in ankle_node.get_children():
					var xf: Transform3D = mi.global_transform
					for v in (mi as MeshInstance3D).mesh.get_faces():
						var w: Vector3 = xf * v
						max_sink = maxf(max_sink, t.height_at(w.x, w.z) - w.y)
	check(max_gap < 0.03, "slope: planted ankles at ground height (max gap %.3f m)" % max_gap)
	check(max_slide < 0.003, "slope: planted feet don't slide (max %.1f mm/frame)" % (max_slide * 1000.0))
	check(max_sink < 0.03, "slope: shoes don't sink into the hill (max %.3f m)" % max_sink)
	h.free()
	map.queue_free()
	await process_frame


func test_props() -> void:
	var d := OsmData.new()
	d.parse_file("res://maps/sample.osm")
	var b := MapBuilder.new()
	var map := b.build(d)
	root.add_child(map)
	check(b.occupancy.count(Occupancy.ROAD) > 20000, "occupancy: roads rasterised (%d cells)" % b.occupancy.count(Occupancy.ROAD))
	check(b.occupancy.count(Occupancy.BUILDING) > 30000, "occupancy: buildings rasterised (%d cells)" % b.occupancy.count(Occupancy.BUILDING))
	check(b.stats.get("driveways", 0) > 60, "garages get driveways to the street (%d)" % b.stats.get("driveways", 0))
	var fronts := 0
	for bl in b.building_list:
		if bl["front"] >= 0:
			fronts += 1
	check(fronts > b.building_list.size() * 0.9, "street-facing wall found for %d/%d buildings" % [fronts, b.building_list.size()])

	var props := PropsBuilder.new()
	var node := props.build(b, func(_x, _z): return 0.0, 3)
	root.add_child(node)
	check(props.stats["trees"] > 60 and props.stats["parked"] > 20 and props.stats["lights"] > 10,
		"props placed: %s" % props.stats)
	check(props.stats["mailboxes"] > 30 and props.stats["fence_panels"] > 200, "mailboxes and fences placed (%d, %d)" % [props.stats["mailboxes"], props.stats["fence_panels"]])
	check(props.stats["stop_signs"] >= 8, "stop signs at the primary/secondary crossings (%d)" % props.stats["stop_signs"])
	var fence_bad := 0
	for xf in props.instances.get("fence", []):
		var o: Vector3 = xf.origin
		if b.occupancy.get_at(o.x, o.z) & (Occupancy.ROAD | Occupancy.BUILDING | Occupancy.DRIVEWAY):
			fence_bad += 1
	check(fence_bad == 0, "no fence post on a road, house or driveway (%d)" % fence_bad)
	check(b.parcel_list.size() == 120, "parcels read (%d)" % b.parcel_list.size())
	# Lot-line fences: on the shared side line x = -188 of the NW block
	# (between the first two lots) behind the setback, and never within 9 m
	# of a street.
	var on_line := 0
	var near_street := 0
	for xf in props.instances.get("fence", []):
		var o: Vector3 = (xf as Transform3D) * Vector3(0, 0, -1.2)  # panel middle
		if absf(o.x + 188.0) < 0.2 and o.z > -205.0 and o.z < -170.0:
			on_line += 1
		if not b.occupancy.is_free(o.x, o.z, 8.0, Occupancy.ROAD):
			near_street += 1
	check(on_line >= 6, "fences follow the lot line between neighbours (%d panels)" % on_line)
	check(near_street == 0, "no lot-line fence in the front setback (%d)" % near_street)
	check(b.stats.get("walks", 0) > 60, "front walks laid (%d)" % b.stats.get("walks", 0))
	# Nothing may stand on a road, in a house or in the pond; cars must be
	# on pavement (street or driveway).
	var bad_trees := 0
	var bad_cars := 0
	var cars := 0
	for key in props.instances:
		var is_car: bool = key.begins_with("car:")
		var is_tree: bool = key in ["deciduous", "conifer", "scrub"]
		if not (is_car or is_tree):
			continue
		for xf in props.instances[key]:
			var o: Vector3 = xf.origin
			var cell := b.occupancy.get_at(o.x, o.z)
			if is_tree and cell & (Occupancy.ROAD | Occupancy.BUILDING | Occupancy.WATER):
				bad_trees += 1
			if is_car:
				cars += 1
				if cell & (Occupancy.BUILDING | Occupancy.WATER) or not (cell & (Occupancy.ROAD | Occupancy.DRIVEWAY)):
					bad_cars += 1
	check(bad_trees == 0, "no tree on a road, house or water (%d)" % bad_trees)
	check(cars > 0 and bad_cars == 0, "all %d parked cars on street or driveway, none in a house (%d bad)" % [cars, bad_cars])
	var shapes := node.get_node("Collision").get_child_count()
	check(shapes >= props.stats["trees"] + props.stats["parked"] + props.stats["lights"], "trees, cars and poles have collision (%d shapes)" % shapes)

	# Pedestrians stay on the paths and keep moving.
	var peds := Pedestrians.new()
	peds.setup(b.road_list, func(_x, _z): return 0.0, 12, 5)
	root.add_child(peds)
	var starts := []
	for w in peds.walkers:
		starts.append(w["node"].global_position)
	peds.set_focus(Vector3.ZERO)
	for i in 600:
		await physics_frame
	var off_path := 0
	var moved := 0
	for k in peds.walkers.size():
		var p: Vector3 = peds.walkers[k]["node"].global_position
		if not (b.occupancy.get_at(p.x, p.z) & Occupancy.PATH):
			off_path += 1
		if p.distance_to(starts[k]) > 3.0:
			moved += 1
	check(peds.walkers.size() == 12, "12 pedestrians spawned")
	check(off_path == 0, "pedestrians stay on footways after 10 s (%d off)" % off_path)
	check(moved == 12, "pedestrians keep walking (%d moved)" % moved)
	var bodies := 0
	for w in peds.walkers:
		for ch in w["node"].get_children():
			if ch is AnimatableBody3D:
				bodies += 1
	check(bodies == 12, "pedestrians have collision bodies (%d)" % bodies)
	peds.queue_free()

	# Traffic keeps to the roads, obeys limits and keeps moving.
	var tr := Traffic.new()
	tr.setup(b.road_list, func(_x, _z): return 0.0, 10, 9)
	root.add_child(tr)
	var car_starts := []
	for c in tr.cars:
		car_starts.append(c["node"].global_position)
	var off_road := 0
	var speeding := 0
	for i in 900:
		await physics_frame
		if i % 30 == 0:
			for c in tr.cars:
				var p: Vector3 = c["node"].global_position
				if not (b.occupancy.get_at(p.x, p.z) & Occupancy.ROAD):
					off_road += 1
				if c["speed"] > tr._edges[c["edge"]]["limit"] + 0.01:
					speeding += 1
	var driving := 0
	for k in tr.cars.size():
		if tr.cars[k]["node"].global_position.distance_to(car_starts[k]) > 10.0:
			driving += 1
	check(tr.cars.size() == 10, "10 AI cars spawned")
	check(off_road == 0, "AI cars stay on roads over 15 s (%d samples off)" % off_road)
	check(speeding == 0, "AI cars respect speed limits (%d samples over)" % speeding)
	check(driving == 10, "AI cars keep driving (%d moved >10 m)" % driving)
	# Night: the nearest cars carry real headlights, the lamps glow.
	tr.set_focus(tr.cars[0]["node"].global_position)
	tr.set_night(true)
	tr._assign_beams()
	var lit_cars := 0
	for c in tr.cars:
		for ch in c["node"].get_children():
			if ch is SpotLight3D and ch.visible:
				lit_cars += 1
				break
	check(lit_cars == Traffic.HEADLIGHT_CARS, "nearest %d AI cars get headlight beams at night (%d)" % [Traffic.HEADLIGHT_CARS, lit_cars])
	tr.set_night(false)
	var any_on := false
	for l in tr._beams:
		any_on = any_on or l.visible
	check(not any_on, "beams go off by day")
	var lit_mesh: ArrayMesh = CarMesh.build_body("sedan", Color.WHITE)
	var parked_mesh: ArrayMesh = CarMesh.build_body("sedan", Color.WHITE, false)
	check(lit_mesh.surface_get_material(3) == CarMesh.headlight_material and lit_mesh.surface_get_material(4) == CarMesh.taillight_material, "moving cars share the emissive lamp materials")
	check(parked_mesh.surface_get_material(3) != CarMesh.headlight_material, "parked cars have unlit lamps")
	tr.queue_free()
	node.queue_free()
	map.queue_free()
	await process_frame


## Synthetic aerial photo over the sample map: lawn green everywhere, a
## dark canopy patch, a red patch over the NW house, blue over the pool.
func _write_test_ortho(d: OsmData, base: String) -> void:
	var b: Dictionary = d._bounds_tag
	var w := 280
	var h := 280
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.45, 0.62, 0.30))
	for y in h:
		for x in w:
			# Map 560 m across 280 px (2 m/px); the NW house spans x -211..-192, z -211..-189
			var mx := -280.0 + x * 2.0
			var mz := -280.0 + y * 2.0
			if mx > -211.0 and mx < -192.0 and mz > -211.0 and mz < -189.0:
				img.set_pixel(x, y, Color(0.6, 0.15, 0.1))
			elif mx > -100.0 and mx < -60.0 and mz > -180.0 and mz < -140.0:
				img.set_pixel(x, y, Color(0.15, 0.32, 0.12))  # canopy
			elif mx > 120.0 and mz > 120.0:
				img.set_pixel(x, y, Color(0.62, 0.55, 0.40))  # dry ground
			elif mx > -197.0 and mx < -193.0 and mz > -220.0 and mz < -211.0:
				img.set_pixel(x, y, Color(0.80, 0.80, 0.78))  # driveway concrete, NW house
	img.save_png(base + ".ortho.png")
	var f := FileAccess.open(base + ".ortho.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"south": b["minlat"], "west": b["minlon"], "north": b["maxlat"], "east": b["maxlon"],
		"width": w, "height": h, "meters_per_px": 2.0}))
	f.close()


func test_ortho() -> void:
	var d := OsmData.new()
	d.parse_file("res://maps/sample.osm")
	var base := "user://ortho_test"
	_write_test_ortho(d, base)
	var o := Ortho.new()
	check(o.load_for(base + ".osm", d) == OK, "ortho loads from <map>.ortho.png/json")
	check(o.rect.grow(1.0).encloses(d.bounds), "ortho covers the map bounds")
	check(o.uv(-280.0, -280.0).length() < 0.01 and (o.uv(280.0, 280.0) - Vector2.ONE).length() < 0.01, "uv mapping spans the photo")
	check(o.is_canopy(-80.0, -160.0) and not o.is_canopy(0.0, 0.0), "canopy detected where the photo is dark green")
	check(o.is_lawn(0.0, 0.0) and not o.is_lawn(200.0, 200.0), "lawn vs dry ground")
	check(o.is_open_ground(200.0, 200.0), "open ground where the photo is tan")
	check(Ortho.new().load_for("user://nope.osm", d) == ERR_FILE_NOT_FOUND, "missing photo is a clean miss")

	var path := "user://ortho_terrain.height"
	_write_test_height(d, path)
	var t := Terrain.new()
	t.load_file(path, d)
	t.ortho = o
	var b := MapBuilder.new()
	b.ortho = o
	var map := b.build(d, t)
	root.add_child(map)
	await physics_frame
	var tmesh: ArrayMesh = (map.get_node("Terrain/Mesh") as MeshInstance3D).mesh
	var arrays := tmesh.surface_get_arrays(0)
	check(arrays[Mesh.ARRAY_TEX_UV] != null and arrays[Mesh.ARRAY_TEX_UV].size() == t.cols * t.rows, "terrain mesh carries photo UVs")
	check(tmesh.surface_get_material(0).albedo_texture == o.texture, "terrain is textured with the photo")
	# The NW house's roof takes the red from the photo.
	var bmesh: ArrayMesh = (map.get_node("Buildings/Mesh") as MeshInstance3D).mesh
	var roofs := bmesh.surface_get_arrays(2)  # walls, brick, roofs, ...
	var rv: PackedVector3Array = roofs[Mesh.ARRAY_VERTEX]
	var rc: PackedColorArray = roofs[Mesh.ARRAY_COLOR]
	var red := 0
	var checked := 0
	for i in rv.size():
		if rv[i].x > -213.0 and rv[i].x < -190.0 and rv[i].z > -213.0 and rv[i].z < -187.0:
			checked += 1
			if rc[i].r > rc[i].g * 2.0:
				red += 1
	check(checked > 0 and red == checked, "roof colour sampled from the photo (%d/%d red)" % [red, checked])
	check(b.stats.get("pools", 0) == 1, "pool carved from leisure=swimming_pool (%d)" % b.stats.get("pools", 0))
	check(b.stats.get("pool_decks", 0) >= 1, "pool gets a concrete deck")
	check(b.stats.get("porches", 0) >= 10 and b.stats.get("chimneys", 0) >= 3, "houses get porches and chimneys (%d, %d)" % [b.stats.get("porches", 0), b.stats.get("chimneys", 0)])
	check(b.stats.get("crosswalks", 0) >= 8, "crosswalks striped at junctions (%d)" % b.stats.get("crosswalks", 0))
	var drive_x := INF
	for r in b.road_list:
		if r["service"] == "driveway" and r["pts"][0].y < -205.0 and r["pts"][0].x < -185.0 and r["pts"][0].x > -215.0:
			drive_x = r["pts"][0].x
	check(absf(drive_x + 195.0) < 1.5, "garage/driveway placed on the photo's concrete strip (x=%.1f)" % drive_x)
	# Trees land on the canopy patch (x -100..-60, z -180..-140) and nowhere on plain lawn.
	var props := PropsBuilder.new()
	var node := props.build(b, func(_x, _z): return 0.0, 3)
	root.add_child(node)
	check(props.stats.get("hoops", 0) >= 8 and props.stats.get("bins", 0) >= 15 and props.stats.get("trampolines", 0) >= 8 and props.stats.get("porch_lights", 0) >= 60,
		"suburb props placed: %d hoops, %d bins, %d trampolines, %d porch lights" % [props.stats.get("hoops", 0), props.stats.get("bins", 0), props.stats.get("trampolines", 0), props.stats.get("porch_lights", 0)])
	var tramp_bad := 0
	for xf in props.instances.get("trampoline", []):
		var to: Vector3 = (xf as Transform3D).origin
		if not b.occupancy.is_free(to.x, to.z, 2.0, Occupancy.BUILDING | Occupancy.ROAD | Occupancy.WATER):
			tramp_bad += 1
	check(tramp_bad == 0, "trampolines clear of houses, roads and water (%d bad)" % tramp_bad)
	var in_patch := 0
	var outside := 0
	for key in ["deciduous", "conifer"]:
		for xf in props.instances.get(key, []):
			var org: Vector3 = xf.origin
			if org.x > -102.0 and org.x < -58.0 and org.z > -182.0 and org.z < -138.0:
				in_patch += 1
			else:
				outside += 1
	check(in_patch >= 6 and outside == 0, "trees only where the photo has canopy (%d in patch, %d elsewhere)" % [in_patch, outside])
	node.queue_free()
	check(b.occupancy.get_at(-201.0, -181.0) & Occupancy.WATER, "pool is water in the occupancy grid")
	map.queue_free()
	await process_frame


func test_daylight() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var d := Daylight.new()
	holder.add_child(d)
	d.hour = 12.0
	d.setup(holder)
	check(d.daylight() > 0.9 and d.sun.light_energy > 0.9 and not d.is_night, "noon: sun up, not night")
	var m := StandardMaterial3D.new()
	m.emission_enabled = true
	d.add_night_material(m)
	var lamps := PackedVector3Array()
	for i in 60:
		lamps.append(Vector3(i * 10.0, 7.0, 0.0))
	d.set_lamp_positions(lamps)
	d.set_focus(Vector3(300, 0, 0))
	d.hour = 22.0
	d.apply()
	d._place_lamps()
	check(d.is_night and d.sun.light_energy < 0.05 and m.emission_energy_multiplier > 1.0, "22:00: night, sun off, windows lit")
	var lit := 0
	var far := 0
	for l in d._lamps:
		if l.visible:
			lit += 1
			if l.global_position.distance_to(Vector3(300, 7, 0)) > 400.0:
				far += 1
	check(lit == d.lamp_pool_size and far == 0, "night: %d nearest lamps lit, none far away" % lit)
	d.hour = 6.5
	d.apply()
	check(d.sun.light_color.b < 0.6 and d.sun.light_energy > 0.0, "dawn: warm low sun")
	check(d.clock_text() == "06:30", "clock text %s" % d.clock_text())
	holder.free()


func test_gameplay() -> void:
	var main: Node3D = load("res://main.tscn").instantiate()
	main.map_path = "res://maps/sample.osm"  # not whatever map is installed locally
	root.add_child(main)
	for i in 120:
		await physics_frame
	var car: VehicleBody3D = main.car
	var player: CharacterBody3D = main.player
	check(player.is_on_floor(), "player standing on ground (y=%.2f)" % player.global_position.y)
	var near_car := INF
	for sb in main.get_node("Props/Collision").get_children():
		if sb.shape is BoxShape3D:  # parked cars are the only boxes
			near_car = minf(near_car, Vector2(sb.global_position.x - player.global_position.x, sb.global_position.z - player.global_position.z).length())
	check(near_car > 6.0, "no parked car at the spawn (nearest %.1f m)" % near_car)
	check(car.global_position.y > -0.2 and car.global_position.y < 1.0, "car settled on suspension (y=%.2f)" % car.global_position.y)
	check(car.global_basis.y.dot(Vector3.UP) > 0.98, "car upright")

	# Walk forward for a second.
	var start := player.global_position
	Input.action_press("move_forward")
	for i in 120:
		await physics_frame
	Input.action_release("move_forward")
	check(player.global_position.distance_to(start) > 2.0, "player walks (moved %.1f m)" % player.global_position.distance_to(start))

	# Walk south from the street into the front wall of the first house of
	# the NW block (its north wall is at z = -211, x in [-211, -192]).
	main.rig.yaw = PI
	player.global_position = Vector3(-201, 0.1, -216)
	Input.action_press("move_forward")
	for i in 600:
		await physics_frame
	Input.action_release("move_forward")
	check(player.global_position.z > -212.0 and player.global_position.z < -209.5, "wall stops player (z=%.1f)" % player.global_position.z)

	# Teleport next to the car, get in, drive.
	player.global_position = car.global_position + car.global_basis * Vector3(-2.5, 0.2, 0)
	var ev := InputEventAction.new()
	ev.action = "interact"
	ev.pressed = true
	main._unhandled_input(ev)
	var mm = main.minimap
	check(mm != null and mm.texture != null, "minimap built")
	var street: String = mm.nearest_street(Vector2(30.0, -3.0))
	check(street == "Main Street", "nearest street beside Main Street (got '%s')" % street)
	check(mm.nearest_street(Vector2(-150.0, -150.0)) == "", "no street name far from roads")
	var px: Vector2 = mm.to_px(Vector2(-280.0, -280.0))
	check(px.length() < 0.1, "map pixel origin at the north-west corner (%s)" % px)
	mm.toggle_full()
	check(mm.full_open and mm._full.visible and not mm._mini.visible, "M opens the full map")
	mm.toggle_full()
	check(main.in_car, "entered car")
	check(car.driver.visible and not player.visible, "driver shown in the car, player hidden")
	var head_top := -INF
	for mi in car.driver.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = mi.global_transform * mi.get_aabb()
		head_top = maxf(head_top, (car.global_transform.affine_inverse() * bb.end).y)
	check(head_top < 1.52, "driver's head below the roof (top %.2f m)" % head_top)
	var car_start := car.global_position
	Input.action_press("move_forward")
	for i in 240:
		await physics_frame
	Input.action_release("move_forward")
	var moved := car.global_position - car_start
	check(car.forward_speed() > 5.0, "car accelerates forward (%.1f m/s)" % car.forward_speed())
	check(moved.dot(-car.global_basis.z) > 5.0, "car travels along its nose (%.1f m)" % moved.dot(-car.global_basis.z))

	# Steer left (A) for a bit: yaw should increase (counter-clockwise from above).
	var yaw0 := car.global_rotation.y
	Input.action_press("move_forward")
	Input.action_press("move_left")
	for i in 90:
		await physics_frame
	Input.action_release("move_left")
	Input.action_release("move_forward")
	check(angle_difference(yaw0, car.global_rotation.y) > 0.2, "A steers left (yaw +%.2f rad)" % angle_difference(yaw0, car.global_rotation.y))

	Input.action_press("move_back")
	for i in 360:
		await physics_frame
	Input.action_release("move_back")
	check(car.forward_speed() < 1.0, "brakes / reverses (%.1f m/s)" % car.forward_speed())

	for i in 240:
		await physics_frame
	main._unhandled_input(ev)
	check(not main.in_car and player.visible, "exited car")
	main.queue_free()
	await process_frame
