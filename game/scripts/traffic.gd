extends Node3D
## AI cars driving the road network. Roads are joined into a graph at shared
## endpoints; each car keeps to the right-hand lane of its current road,
## slows for corners and junctions, stops behind anything in its lane
## (other traffic, the player, a pedestrian) and picks a new road at each
## junction, preferring to carry straight on.
##
## Cars are kinematic (AnimatableBody3D) so the player's car collides with
## them solidly; they are not knocked about themselves.

const CarMesh := preload("res://scripts/car_mesh.gd")

const DRIVE_TYPES := {
	"primary": 16.0, "secondary": 14.0, "tertiary": 12.0, "unclassified": 9.0,
	"residential": 8.0, "living_street": 5.0,
}
const SNAP := 1.5
const LOOK_AHEAD := 14.0
const FOLLOW_GAP := 3.5
const ACCEL := 3.0
const BRAKE := 7.0
const ANIMATE_DISTANCE := 500.0

var ground: Callable
var cars: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _junctions: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _focus := Vector3.ZERO
var _meshes: Dictionary = {}


func setup(roads: Array[Dictionary], ground_fn: Callable, count: int, seed: int = 1) -> void:
	ground = ground_fn
	_rng.seed = seed
	for r in roads:
		if not DRIVE_TYPES.has(r["highway"]):
			continue
		var pts: PackedVector2Array = r["pts"]
		var length := 0.0
		for i in pts.size() - 1:
			length += pts[i].distance_to(pts[i + 1])
		if length < 8.0:
			continue
		_edges.append({"pts": pts, "length": length, "lane": maxf(r["width"] * 0.25, 1.4),
			"limit": DRIVE_TYPES[r["highway"]]})
		var idx := _edges.size() - 1
		_junction(pts[0]).append([idx, false])
		_junction(pts[pts.size() - 1]).append([idx, true])
	if _edges.is_empty():
		return
	var total := 0.0
	for e in _edges:
		total += e["length"]
	for i in count:
		var pick := _rng.randf() * total
		var edge := 0
		for k in _edges.size():
			pick -= _edges[k]["length"]
			if pick <= 0.0:
				edge = k
				break
		_spawn(edge, _rng.randf_range(0.1, 0.9) * _edges[edge]["length"], 1 if _rng.randf() < 0.5 else -1)


func _junction(p: Vector2) -> Array:
	var key := Vector2i(roundi(p.x / SNAP), roundi(p.y / SNAP))
	if not _junctions.has(key):
		_junctions[key] = []
	return _junctions[key]


func _spawn(edge: int, dist: float, dir: int) -> void:
	var style: String = ["sedan", "sedan", "suv", "pickup"][_rng.randi() % 4]
	var paint := _rng.randi() % CarMesh.PAINTS.size()
	var key := "%s:%d" % [style, paint]
	if not _meshes.has(key):
		_meshes[key] = CarMesh.build_body(style, CarMesh.PAINTS[paint])
	var body := AnimatableBody3D.new()
	body.sync_to_physics = true
	var d := CarMesh.dims(style)
	var shape := BoxShape3D.new()
	shape.size = d["box_size"]
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = d["box_center"]
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _meshes[key]
	body.add_child(mi)
	var wheel_key := "wheel:" + style
	if not _meshes.has(wheel_key):
		_meshes[wheel_key] = CarMesh.build_wheel(style)
	var wheels: Array[MeshInstance3D] = []
	for wp in CarMesh.wheel_positions(style):
		var w := MeshInstance3D.new()
		w.mesh = _meshes[wheel_key]
		w.position = wp
		body.add_child(w)
		wheels.append(w)
	var ray := RayCast3D.new()
	ray.position = Vector3(0, 0.6, -d["length"] * 0.5)
	ray.target_position = Vector3(0, 0, -LOOK_AHEAD)
	ray.collision_mask = 1
	ray.add_exception(body)
	body.add_child(ray)
	add_child(body)
	var car := {"node": body, "edge": edge, "dist": dist, "dir": dir, "speed": 0.0,
		"wheels": wheels, "ray": ray, "radius": CarMesh.wheel_radius(style), "roll": 0.0,
		"stuck": 0.0, "pass_until": -1.0, "offset": 0.0}
	cars.append(car)
	_place(car, 0.0)


func set_focus(p: Vector3) -> void:
	_focus = p


func _physics_process(delta: float) -> void:
	for c in cars:
		_drive(c, delta)


func _drive(c: Dictionary, delta: float) -> void:
	var e: Dictionary = _edges[c["edge"]]
	var remaining: float = e["length"] - c["dist"] if c["dir"] > 0 else c["dist"]
	# Target speed: the road's limit, eased down toward the next junction and
	# through bends; zero when something is in the way.
	var target: float = e["limit"]
	target = minf(target, 3.0 + remaining * 0.6)
	var at := _point_at(e["pts"], clampf(c["dist"] + c["dir"] * 6.0, 0.0, e["length"]))
	var here := _point_at(e["pts"], clampf(c["dist"], 0.0, e["length"]))
	var turn: float = absf((at[1] as Vector2).angle_to(here[1]))
	target = minf(target, lerpf(e["limit"], 3.0, clampf(turn / 0.6, 0.0, 1.0)))
	var ray: RayCast3D = c["ray"]
	var passing: bool = c["pass_until"] > 0.0 and (c["pass_until"] - c["dist"]) * c["dir"] > 0.0
	if ray.is_colliding():
		var gap := ray.get_collision_point().distance_to(ray.global_position)
		if not passing or gap < 2.5:
			target = minf(target, maxf(0.0, (gap - FOLLOW_GAP) * 1.2))
	# Blocked for a while (parked car, stopped player): pull toward the
	# centre line and go around.
	if c["speed"] < 0.3 and ray.is_colliding():
		c["stuck"] += delta
		if c["stuck"] > 2.5 and not passing:
			c["pass_until"] = c["dist"] + c["dir"] * 30.0
			c["stuck"] = 0.0
			passing = true
	else:
		c["stuck"] = 0.0
	if passing:
		target = maxf(target, 2.0)
	c["offset"] = move_toward(c["offset"], -1.5 if passing else 0.0, delta * 1.2)
	if target > c["speed"]:
		c["speed"] = minf(target, c["speed"] + ACCEL * delta)
	else:
		c["speed"] = maxf(target, c["speed"] - BRAKE * delta)
	c["dist"] += c["speed"] * delta * c["dir"]
	if c["dist"] < 0.0 or c["dist"] > e["length"]:
		_next_edge(c)
	_place(c, delta)


func _next_edge(c: Dictionary) -> void:
	var e: Dictionary = _edges[c["edge"]]
	var at_end: bool = c["dir"] > 0
	var pts: PackedVector2Array = e["pts"]
	var options: Array = _junction(pts[pts.size() - 1] if at_end else pts[0])
	var heading: Vector2 = (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized() if at_end else (pts[0] - pts[1]).normalized()
	var best: Array = []
	var weights: Array[float] = []
	for o in options:
		if o[0] == c["edge"]:
			continue
		var ne: Dictionary = _edges[o[0]]
		var npts: PackedVector2Array = ne["pts"]
		# Direction we'd leave the junction in.
		var out: Vector2 = (npts[npts.size() - 2] - npts[npts.size() - 1]).normalized() if o[1] else (npts[1] - npts[0]).normalized()
		best.append(o)
		weights.append(1.0 + 3.0 * maxf(0.0, heading.dot(out)))  # prefer straight on
	if best.is_empty():
		c["dir"] = -c["dir"]  # dead end: U-turn
		c["dist"] = clampf(c["dist"], 0.0, e["length"])
		c["speed"] = 0.0
		return
	var total := 0.0
	for w in weights:
		total += w
	var pick := _rng.randf() * total
	var chosen: Array = best[0]
	for i in best.size():
		pick -= weights[i]
		if pick <= 0.0:
			chosen = best[i]
			break
	c["edge"] = chosen[0]
	c["dir"] = -1 if chosen[1] else 1
	c["dist"] = _edges[chosen[0]]["length"] if chosen[1] else 0.0


func _place(c: Dictionary, delta: float) -> void:
	var e: Dictionary = _edges[c["edge"]]
	var at := _point_at(e["pts"], clampf(c["dist"], 0.0, e["length"]))
	var dir: Vector2 = at[1] * c["dir"]
	# Right-hand lane: offset to the right of the direction of travel.
	var right := Vector2(-dir.y, dir.x)
	var p: Vector2 = at[0] + right * (e["lane"] + c["offset"])
	var y: float = ground.call(p.x, p.y) + 0.12
	var node: AnimatableBody3D = c["node"]
	var pos := Vector3(p.x, y, p.y)
	node.visible = pos.distance_to(_focus) < ANIMATE_DISTANCE * 1.6
	# Pitch with the road so the car isn't half-buried on hills.
	var ahead: Vector2 = p + dir * 2.0
	var behind: Vector2 = p - dir * 2.0
	var slope: float = atan2(ground.call(ahead.x, ahead.y) - ground.call(behind.x, behind.y), 4.0)
	var yaw := atan2(-dir.x, -dir.y)
	node.global_transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, slope), pos)
	if delta > 0.0 and node.visible:
		c["roll"] += c["speed"] * delta / c["radius"]
		for w in c["wheels"]:
			w.rotation.x = -c["roll"]


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
	return [pts[n - 1], (pts[n - 1] - pts[n - 2]).normalized()]
