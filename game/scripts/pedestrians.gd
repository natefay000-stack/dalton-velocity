extends Node3D
## Walkers on the footpath network. Footways are joined into a graph at
## shared endpoints; each pedestrian follows a path to its end, picks
## another path from that junction (never doubling back when it can help
## it) and carries on. Far from the camera they only move, not animate.

const Humanoid := preload("res://scripts/humanoid.gd")

const WALK_TYPES := ["footway", "path", "pedestrian", "cycleway"]
const ANIMATE_DISTANCE := 160.0
const HIDE_DISTANCE := 700.0
const SNAP := 1.0  # metres; endpoints closer than this are one junction

var ground: Callable
var walkers: Array[Dictionary] = []
var _edges: Array[Dictionary] = []  # {pts, length}
var _junctions: Dictionary = {}     # Vector2i key -> Array of [edge, at_end]
var _focus := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
## Moving cars walkers keep an eye on: the player's car plus traffic nodes.
var _threats: Array = []
var _horn_at := Vector3.ZERO
var _horn_time := -10.0


func setup(roads: Array[Dictionary], ground_fn: Callable, count: int, seed: int = 1) -> void:
	ground = ground_fn
	_rng.seed = seed
	for r in roads:
		if not (r["highway"] in WALK_TYPES):
			continue
		var pts: PackedVector2Array = r["pts"]
		var length := 0.0
		for i in pts.size() - 1:
			length += pts[i].distance_to(pts[i + 1])
		if length < 4.0:
			continue
		var e := {"pts": pts, "length": length}
		_edges.append(e)
		var idx := _edges.size() - 1
		_junction(pts[0]).append([idx, false])
		_junction(pts[pts.size() - 1]).append([idx, true])
	if _edges.is_empty():
		return
	# Spawn proportional to path length so long trails get their share.
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
		_spawn(edge, _rng.randf() * _edges[edge]["length"], 1 if _rng.randf() < 0.5 else -1, i)


func _junction(p: Vector2) -> Array:
	var key := Vector2i(roundi(p.x / SNAP), roundi(p.y / SNAP))
	if not _junctions.has(key):
		_junctions[key] = []
	return _junctions[key]


func _spawn(edge: int, dist: float, dir: int, seed: int) -> void:
	var h: Node3D = Humanoid.new()
	h.look_seed = seed * 7919 + 13
	h.build()
	h.scale = Vector3.ONE * _rng.randf_range(0.92, 1.06)
	# A kinematic capsule so the player and cars can't pass through them.
	var body := AnimatableBody3D.new()
	body.sync_to_physics = true
	var shape := CapsuleShape3D.new()
	shape.radius = 0.28
	shape.height = 1.75
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = 0.9
	body.add_child(cs)
	h.add_child(body)
	h.probe_exclude.append(body.get_rid())
	add_child(h)
	var w := {"node": h, "edge": edge, "dist": dist, "dir": dir,
		"speed": _rng.randf_range(1.15, 1.7), "prev_edge": -1,
		"react": 0.0, "side": 0.0, "look": Vector3.ZERO}
	walkers.append(w)
	if is_inside_tree():
		_place(w, 0.0)


func _ready() -> void:
	for w in walkers:
		_place(w, 0.0)


## Cars that walkers step aside for (RigidBody3D or Traffic node).
func set_threats(cars: Array) -> void:
	_threats = cars


## A horn sounded at `p`: walkers nearby stop and look.
func honk(p: Vector3) -> void:
	_horn_at = p
	_horn_time = Time.get_ticks_msec() / 1000.0


## Nearest moving car to `pos` as [position, velocity], or [] if none near.
func _nearest_car(pos: Vector3) -> Array:
	var best := 18.0 * 18.0
	var out: Array = []
	for t in _threats:
		if t is RigidBody3D:
			var d: float = t.global_position.distance_squared_to(pos)
			if d < best and t.linear_velocity.length() > 2.0:
				best = d
				out = [t.global_position, t.linear_velocity]
		elif t != null and "cars" in t:
			for c in t.cars:
				var n: Node3D = c["node"]
				var d: float = n.global_position.distance_squared_to(pos)
				if d < best and c["speed"] > 2.0:
					best = d
					var fwd: Vector3 = -n.global_basis.z
					out = [n.global_position, fwd * c["speed"]]
	return out


## Camera/player position: walkers near it animate, far ones just slide.
func set_focus(p: Vector3) -> void:
	_focus = p


func _physics_process(delta: float) -> void:
	for w in walkers:
		_step(w, delta)


func _step(w: Dictionary, delta: float) -> void:
	var e: Dictionary = _edges[w["edge"]]
	var node: Node3D = w["node"]
	var pos: Vector3 = node.global_position
	# Only walkers near the player bother reacting (the rest just walk).
	if pos.distance_squared_to(_focus) < 90.0 * 90.0:
		if w["react"] <= 0.0:
			var car := _nearest_car(pos)
			if not car.is_empty():
				var to_me: Vector3 = pos - car[0]
				var vel: Vector3 = car[1]
				var closing := vel.dot(to_me.normalized())
				# Coming my way and will pass within 3 m: stop and step back.
				var lateral := (to_me - vel.normalized() * to_me.dot(vel.normalized())).length()
				if closing > 3.0 and lateral < 3.0:
					w["react"] = 2.2
					var right := Vector3(-vel.z, 0.0, vel.x).normalized()
					w["side"] = 1.3 * (1.0 if right.dot(to_me) >= 0.0 else -1.0)
					w["look"] = car[0]
			var since_horn := Time.get_ticks_msec() / 1000.0 - _horn_time
			if since_horn < 0.3 and pos.distance_to(_horn_at) < 25.0:
				w["react"] = 1.6
				w["look"] = _horn_at
	if w["react"] > 0.0:
		w["react"] -= delta
		_place(w, delta)
		return
	w["side"] = move_toward(w["side"], 0.0, delta * 1.5)
	w["dist"] += w["speed"] * delta * w["dir"]
	if w["dist"] < 0.0 or w["dist"] > e["length"]:
		_next_edge(w)
	_place(w, delta)


func _next_edge(w: Dictionary) -> void:
	var e: Dictionary = _edges[w["edge"]]
	var at_end: bool = w["dir"] > 0
	var pts: PackedVector2Array = e["pts"]
	var options: Array = _junction(pts[pts.size() - 1] if at_end else pts[0])
	var candidates: Array = []
	for o in options:
		if o[0] != w["edge"]:
			candidates.append(o)
	if candidates.is_empty():
		# Dead end: turn around.
		w["dir"] = -w["dir"]
		w["dist"] = clampf(w["dist"], 0.0, e["length"])
		return
	var pick: Array = candidates[_rng.randi() % candidates.size()]
	w["prev_edge"] = w["edge"]
	w["edge"] = pick[0]
	# Arrived at that edge's end -> walk it backwards.
	w["dir"] = -1 if pick[1] else 1
	w["dist"] = _edges[pick[0]]["length"] if pick[1] else 0.0


func _place(w: Dictionary, delta: float) -> void:
	var e: Dictionary = _edges[w["edge"]]
	var at := _point_at(e["pts"], clampf(w["dist"], 0.0, e["length"]))
	var p: Vector2 = at[0]
	var dir: Vector2 = at[1] * w["dir"]
	var node: Node3D = w["node"]
	var reacting: bool = w["react"] > 0.0
	# Side-step away from a car (perpendicular to the path).
	var side: float = w["side"]
	if reacting and absf(side) > 0.01:
		var cur := Vector2(node.global_position.x, node.global_position.z) - p
		var perp := Vector2(-dir.y, dir.x)
		var want := perp * side
		var step := (want - cur).limit_length(delta * 2.0)
		p += cur + step
	var y: float = ground.call(p.x, p.y)
	var pos := Vector3(p.x, y, p.y)
	var dist_to_focus := pos.distance_to(_focus)
	node.visible = dist_to_focus < HIDE_DISTANCE
	var vel: Vector3 = Vector3(dir.x, 0.0, dir.y) * w["speed"]
	if reacting:
		vel = (pos - node.global_position) / maxf(delta, 1e-3) if delta > 0.0 else Vector3.ZERO
	node.global_position = pos
	if reacting:
		var look: Vector3 = w["look"]
		var to := Vector2(look.x - pos.x, look.z - pos.z)
		if to.length_squared() > 0.1:
			node.rotation.y = lerp_angle(node.rotation.y, atan2(-to.x, -to.y), clampf(delta * 6.0, 0.0, 1.0))
	else:
		node.rotation.y = atan2(-dir.x, -dir.y)
	if delta > 0.0 and dist_to_focus < ANIMATE_DISTANCE and node.visible:
		node.update_motion(delta, vel, true)


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
