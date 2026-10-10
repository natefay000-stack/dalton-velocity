extends Node3D
## Mule deer on the open ground around the neighbourhood and a flock of
## birds overhead. Deer graze, wander a little, and bolt when you (on foot
## or in the car) come within FLEE_RADIUS; they keep off roads, houses
## and water using the occupancy grid.

const Occupancy := preload("res://scripts/occupancy.gd")

const FLEE_RADIUS := 28.0
const FLEE_SPEED := 9.0
const WANDER_SPEED := 1.1
const ANIMATE_DISTANCE := 220.0
const BLOCKED := Occupancy.BUILDING | Occupancy.ROAD | Occupancy.WATER | Occupancy.PATH | Occupancy.DRIVEWAY | Occupancy.FENCE

var deer: Array[Dictionary] = []
var birds: Array[Dictionary] = []
var ground: Callable
var _occ: Occupancy
var _ortho = null
var _bounds := Rect2()
var _focus := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _bird_mm: MultiMeshInstance3D
var _bird_time := 0.0
var _bird_centre := Vector3.ZERO


func setup(occupancy: Occupancy, ortho, ground_fn: Callable, deer_count: int, seed: int = 3) -> void:
	_occ = occupancy
	_ortho = ortho
	ground = ground_fn
	_bounds = occupancy.rect.grow(-30.0)
	_rng.seed = seed
	var mesh := _deer_mesh()
	var tries := 0
	while deer.size() < deer_count and tries < deer_count * 400:
		tries += 1
		var p := Vector2(_rng.randf_range(_bounds.position.x, _bounds.end.x), _rng.randf_range(_bounds.position.y, _bounds.end.y))
		if not _open_at(p):
			continue
		# Favour the open ground nearest the neighbourhood, so you meet them.
		var near := clampf(1.0 - p.distance_to(_bounds.get_center()) / 700.0, 0.12, 1.0)
		if _rng.randf() > near:
			continue
		# Small groups: a few more near the first of each cluster.
		var n := _rng.randi_range(1, 3)
		for k in n:
			var q := p + Vector2(_rng.randf_range(-6.0, 6.0), _rng.randf_range(-6.0, 6.0))
			if deer.size() < deer_count and _open_at(q):
				_spawn_deer(q, mesh)
	_spawn_birds()


## Open ground: nothing built within 25 m, not a lawn (by photo when there
## is one; by the occupancy grid otherwise).
func _open_at(p: Vector2) -> bool:
	if not _bounds.has_point(p):
		return false
	if not _occ.is_free(p.x, p.y, 3.0, BLOCKED | Occupancy.PROP):
		return false
	if not _occ.is_free(p.x, p.y, 25.0, Occupancy.BUILDING | Occupancy.ROAD):
		return false
	if _ortho != null and not _ortho.is_open_ground(p.x, p.y):
		return false
	return true


func _spawn_deer(p: Vector2, mesh: ArrayMesh) -> void:
	var node := Node3D.new()
	var body := MeshInstance3D.new()
	body.mesh = mesh
	node.add_child(body)
	var legs: Array[MeshInstance3D] = []
	var leg_mesh := _leg_mesh()
	for lx in [-0.22, 0.22]:
		for lz in [-0.45, 0.45]:
			var leg := MeshInstance3D.new()
			leg.mesh = leg_mesh
			leg.position = Vector3(lx, 0.78, lz)
			node.add_child(leg)
			legs.append(leg)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 1.3, 1.6)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = 0.75
	var sb := AnimatableBody3D.new()
	sb.sync_to_physics = true
	sb.add_child(cs)
	node.add_child(sb)
	add_child(node)
	var scale := _rng.randf_range(0.85, 1.1)
	node.scale = Vector3.ONE * scale
	var y: float = ground.call(p.x, p.y)
	node.global_position = Vector3(p.x, y, p.y)
	node.rotation.y = _rng.randf() * TAU
	deer.append({"node": node, "legs": legs, "pos": p, "target": p, "state": "graze",
		"timer": _rng.randf_range(2.0, 8.0), "phase": _rng.randf() * TAU, "speed": 0.0})


func set_focus(p: Vector3) -> void:
	_focus = p


func _physics_process(delta: float) -> void:
	var f2 := Vector2(_focus.x, _focus.z)
	for d in deer:
		_step_deer(d, delta, f2)
	_step_birds(delta)


func _step_deer(d: Dictionary, delta: float, focus: Vector2) -> void:
	var node: Node3D = d["node"]
	var p: Vector2 = d["pos"]
	var to_focus := p - focus
	var dist := to_focus.length()
	d["timer"] -= delta
	var speed := 0.0
	if dist < FLEE_RADIUS and d["state"] != "flee":
		d["state"] = "flee"
		d["timer"] = _rng.randf_range(3.0, 5.0)
	match d["state"]:
		"flee":
			# Away from the threat, bending round anything blocked.
			var away := to_focus.normalized() if dist > 0.1 else Vector2.RIGHT
			var dir := _steer(p, away)
			speed = FLEE_SPEED
			p += dir * speed * delta
			if d["timer"] <= 0.0 and dist > FLEE_RADIUS * 1.5:
				d["state"] = "graze"
				d["timer"] = _rng.randf_range(3.0, 9.0)
		"wander":
			var to_t: Vector2 = d["target"] - p
			if to_t.length() < 0.5 or d["timer"] <= 0.0:
				d["state"] = "graze"
				d["timer"] = _rng.randf_range(3.0, 9.0)
			else:
				var dir := _steer(p, to_t.normalized())
				speed = WANDER_SPEED
				p += dir * speed * delta
		_:
			if d["timer"] <= 0.0:
				var t := p + Vector2(_rng.randf_range(-12.0, 12.0), _rng.randf_range(-12.0, 12.0))
				if _bounds.has_point(t) and _occ.is_free(t.x, t.y, 2.0, BLOCKED):
					d["target"] = t
					d["state"] = "wander"
					d["timer"] = 15.0
				else:
					d["timer"] = 2.0
	if not _bounds.has_point(p):
		p = p.clamp(_bounds.position, _bounds.end)
	d["pos"] = p
	d["speed"] = speed
	var y: float = ground.call(p.x, p.y)
	node.global_position = Vector3(p.x, y, p.y)
	if speed > 0.0:
		var dir2: Vector2 = (d["target"] - p) if d["state"] == "wander" else (p - focus)
		if dir2.length_squared() > 0.01:
			node.rotation.y = lerp_angle(node.rotation.y, atan2(-dir2.x, -dir2.y), clampf(delta * 6.0, 0.0, 1.0))
	# Legs swing when moving; a grazing deer dips its head now and then.
	if node.global_position.distance_to(_focus) < ANIMATE_DISTANCE:
		d["phase"] += delta * (speed * 2.2 + 0.0)
		var legs: Array = d["legs"]
		for i in legs.size():
			var leg: MeshInstance3D = legs[i]
			var sw := sin(d["phase"] + (PI if i % 3 == 0 else 0.0)) * clampf(speed / 4.0, 0.0, 0.7)
			leg.rotation.x = sw


## Direction `want`, or the nearest free alternative within +-90 degrees.
func _steer(p: Vector2, want: Vector2) -> Vector2:
	for k in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5]:
		var dir := want.rotated(k)
		var ahead := p + dir * 3.0
		if _bounds.has_point(ahead) and _occ.is_free(ahead.x, ahead.y, 1.0, BLOCKED):
			return dir
	return Vector2.ZERO


# --- birds -----------------------------------------------------------------

func _spawn_birds() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Two wings as a shallow V; flapping is done by scaling y in the transform.
	var c := Color(0.12, 0.12, 0.13)
	for sx in [-1.0, 1.0]:
		st.set_color(c)
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(0, 0, -0.12))
		st.set_color(c)
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(sx * 0.45, 0.12, 0.05))
		st.set_color(c)
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(0, 0, 0.1))
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 14
	_bird_mm = MultiMeshInstance3D.new()
	_bird_mm.multimesh = mm
	add_child(_bird_mm)
	for i in mm.instance_count:
		birds.append({"angle": _rng.randf() * TAU, "radius": _rng.randf_range(25.0, 60.0),
			"height": _rng.randf_range(35.0, 70.0), "flap": _rng.randf() * TAU, "rate": _rng.randf_range(0.5, 0.8)})
	_bird_centre = Vector3(_bounds.get_center().x, 0.0, _bounds.get_center().y)


func _step_birds(delta: float) -> void:
	if _bird_mm == null:
		return
	_bird_time += delta
	# The flock drifts slowly toward wherever the player is.
	_bird_centre = _bird_centre.lerp(Vector3(_focus.x, 0.0, _focus.z), clampf(delta * 0.05, 0.0, 1.0))
	var mm := _bird_mm.multimesh
	for i in birds.size():
		var b: Dictionary = birds[i]
		b["angle"] += delta * b["rate"] * (40.0 / b["radius"])
		b["flap"] += delta * 9.0
		var pos := _bird_centre + Vector3(cos(b["angle"]) * b["radius"], b["height"] + sin(_bird_time * 0.3 + i) * 3.0, sin(b["angle"]) * b["radius"])
		var heading := Vector3(-sin(b["angle"]), 0.0, cos(b["angle"]))
		var basis := Basis.looking_at(heading, Vector3.UP)
		var flap := 1.0 + sin(b["flap"]) * 0.9  # wings beat by squashing the V
		basis = basis.scaled(Vector3(1.0, flap, 1.0))
		mm.set_instance_transform(i, Transform3D(basis, pos))


# --- meshes ----------------------------------------------------------------

func _deer_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var brown := Color(0.52, 0.40, 0.28)
	var body := BoxMesh.new()
	body.size = Vector3(0.5, 0.55, 1.3)
	st.append_from(body, 0, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))
	var neck := BoxMesh.new()
	neck.size = Vector3(0.22, 0.6, 0.26)
	st.append_from(neck, 0, Transform3D(Basis(Vector3.RIGHT, -0.5), Vector3(0, 1.4, -0.7)))
	var head := BoxMesh.new()
	head.size = Vector3(0.2, 0.22, 0.42)
	st.append_from(head, 0, Transform3D(Basis.IDENTITY, Vector3(0, 1.62, -0.95)))
	for sx in [-0.12, 0.12]:
		var ear := BoxMesh.new()
		ear.size = Vector3(0.06, 0.18, 0.08)
		st.append_from(ear, 0, Transform3D(Basis.IDENTITY, Vector3(sx, 1.8, -0.85)))
	var tail := BoxMesh.new()
	tail.size = Vector3(0.1, 0.18, 0.1)
	st.append_from(tail, 0, Transform3D(Basis.IDENTITY, Vector3(0, 1.1, 0.68)))
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = brown
	mat.roughness = 0.95
	mesh.surface_set_material(0, mat)
	var white := SurfaceTool.new()
	white.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rump := BoxMesh.new()
	rump.size = Vector3(0.42, 0.3, 0.1)
	white.append_from(rump, 0, Transform3D(Basis.IDENTITY, Vector3(0, 0.95, 0.62)))
	mesh = white.commit(mesh)
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.9, 0.88, 0.82)
	mesh.surface_set_material(1, wm)
	return mesh


func _leg_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.09, 0.8, 0.1)
	st.append_from(leg, 0, Transform3D(Basis.IDENTITY, Vector3(0, -0.4, 0)))  # pivot at the hip
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.34, 0.24)
	mesh.surface_set_material(0, mat)
	return mesh
