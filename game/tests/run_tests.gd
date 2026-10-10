extends SceneTree
## Headless test runner:
##   godot --headless --path game --script res://tests/run_tests.gd
## Exits non-zero on failure.

const OsmData := preload("res://scripts/osm_data.gd")
const MapBuilder := preload("res://scripts/map_builder.gd")
const Humanoid := preload("res://scripts/humanoid.gd")
const GltfCharacter := preload("res://scripts/gltf_character.gd")

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
	print("physics")
	await test_gameplay()
	print("%s (%d failure%s)" % ["PASSED" if failures == 0 else "FAILED", failures, "" if failures == 1 else "s"])
	quit(1 if failures else 0)


func test_sample_parse() -> void:
	var d := OsmData.new()
	check(d.parse_file("res://maps/sample.osm") == OK, "sample.osm parses")
	check(d.points.size() == 567, "all 567 nodes projected (got %d)" % d.points.size())
	check(d.ways.size() == 140, "all 140 ways read (got %d)" % d.ways.size())
	# Grid is 4 x 110 m blocks centred on the origin.
	check(absf(d.bounds.size.x - 440.0) < 1.0, "east-west extent ~440 m (got %.2f)" % d.bounds.size.x)
	check(absf(d.bounds.size.y - 440.0) < 1.0, "north-south extent ~440 m (got %.2f)" % d.bounds.size.y)
	check(d.bounds.get_center().length() < 1.0, "map centred on origin")
	# Node 1 is the north-west grid corner: x = -220 (west), z = -220 (north).
	var p: Vector2 = d.points[1]
	check(p.distance_to(Vector2(-220, -220)) < 0.5, "north-west corner projects to (-220,-220) (got %s)" % p)

	var b := MapBuilder.new()
	var root := b.build(d)
	check(b.stats["roads"] == 11, "10 streets + 1 footway (got %d)" % b.stats["roads"])
	check(b.stats["buildings"] == 127, "120 houses + 7 L-shaped blocks (got %d)" % b.stats["buildings"])
	check(b.stats["areas"] == 2, "park + pond (got %d)" % b.stats["areas"])
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


func _lowest_mesh_y(n: Node) -> float:
	var lo := INF
	if n is MeshInstance3D:
		lo = (n.global_transform * n.get_aabb()).position.y
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
	for i in 30:
		h.update_motion(1.0 / 60.0, 0.0, true, 0.0)
	var low := _lowest_mesh_y(h)
	var high := _highest_mesh_y(h)
	check(absf(low) < 0.02, "idle: soles on the ground (lowest y=%.3f)" % low)
	check(high > 1.70 and high < 1.90, "adult height (top y=%.2f)" % high)

	# Walking: legs alternate, feet never sink far below the ground.
	var hip_l: Node3D = h.joints["hip_l"]
	var min_a := INF
	var max_a := -INF
	var lowest := INF
	for i in 120:
		h.update_motion(1.0 / 60.0, 1.6, true, 0.0)
		min_a = minf(min_a, hip_l.rotation.x)
		max_a = maxf(max_a, hip_l.rotation.x)
		lowest = minf(lowest, _lowest_mesh_y(h))
	check(max_a > 0.25 and min_a < -0.25, "walk: left thigh swings %.2f..%.2f rad" % [min_a, max_a])
	check(lowest > -0.08, "walk: feet stay near the ground (min y=%.3f)" % lowest)

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


func test_gameplay() -> void:
	var main: Node3D = load("res://main.tscn").instantiate()
	root.add_child(main)
	for i in 120:
		await physics_frame
	var car: VehicleBody3D = main.car
	var player: CharacterBody3D = main.player
	check(player.is_on_floor(), "player standing on ground (y=%.2f)" % player.global_position.y)
	check(car.global_position.y > -0.2 and car.global_position.y < 1.0, "car settled on suspension (y=%.2f)" % car.global_position.y)
	check(car.global_basis.y.dot(Vector3.UP) > 0.98, "car upright")

	# Walk forward for a second.
	var start := player.global_position
	Input.action_press("move_forward")
	for i in 120:
		await physics_frame
	Input.action_release("move_forward")
	check(player.global_position.distance_to(start) > 2.0, "player walks (moved %.1f m)" % player.global_position.distance_to(start))

	# Walk north into the first house of the NW block; its south wall is
	# somewhere in z = [-199, -189] for x in [-211, -192].
	main.rig.yaw = 0.0
	player.global_position = Vector3(-201, 0.1, -180)
	Input.action_press("move_forward")
	for i in 600:
		await physics_frame
	Input.action_release("move_forward")
	check(player.global_position.z > -199.0 and player.global_position.z < -185.0, "wall stops player (z=%.1f)" % player.global_position.z)

	# Teleport next to the car, get in, drive.
	player.global_position = car.global_position + car.global_basis * Vector3(-2.5, 0.2, 0)
	var ev := InputEventAction.new()
	ev.action = "interact"
	ev.pressed = true
	main._unhandled_input(ev)
	check(main.in_car, "entered car")
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
