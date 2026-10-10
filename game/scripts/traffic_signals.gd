extends Node3D
## Traffic lights at the builder's signalised junctions. Arms are split into
## two phases by heading (roughly parallel arms share a phase); each phase
## gets green, then amber, then the other goes. One head per approach on
## the right-hand kerb, lamps lit by swapping materials.

const SNAP := 1.5
const GREEN_T := 11.0
const AMBER_T := 3.0

var junctions: Dictionary = {}  # key -> {phase_of: {arm index -> 0/1}, arms, t, offset, heads: [[MeshInstance3D, phase]]}
var _lit := {}
var _unlit := {}
var _pole_mesh: ArrayMesh
var _head_mesh: ArrayMesh
var _ground: Callable


func setup(signal_junctions: Dictionary, ground: Callable, seed: int = 1) -> void:
	_ground = ground
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_make_materials()
	_pole_mesh = _make_pole()
	_head_mesh = _make_head()
	for key in signal_junctions:
		var j: Dictionary = signal_junctions[key]
		var arms: Array = j["arms"]
		var ref: Vector2 = arms[0]["out"]
		var phases: Array[int] = []
		for a in arms:
			phases.append(0 if absf((a["out"] as Vector2).dot(ref)) > 0.7 else 1)
		var heads: Array = []
		for i in arms.size():
			var a: Dictionary = arms[i]
			var out: Vector2 = a["out"]
			var right := Vector2(out.y, -out.x)  # right of traffic driving *toward* the junction
			var pos: Vector2 = a["p"] + out * (a["width"] * 0.5 + 2.5) + right * (a["width"] * 0.5 + 0.8)
			var y: float = _ground.call(pos.x, pos.y)
			var node := Node3D.new()
			node.position = Vector3(pos.x, y, pos.y)
			node.rotation.y = atan2(-out.x, -out.y) + PI  # face oncoming traffic (which drives along -out)
			var pole := MeshInstance3D.new()
			pole.mesh = _pole_mesh
			node.add_child(pole)
			var head := MeshInstance3D.new()
			head.mesh = _head_mesh
			head.position = Vector3(-1.6, 4.6, 0.0)
			node.add_child(head)
			add_child(node)
			heads.append([head, phases[i]])
		junctions[key] = {"arms": arms, "phases": phases, "t": rng.randf() * (GREEN_T + AMBER_T) * 2.0, "heads": heads, "state": ["", ""]}
		_apply(junctions[key])


func _process(delta: float) -> void:
	for key in junctions:
		var j: Dictionary = junctions[key]
		j["t"] = fmod(j["t"] + delta, (GREEN_T + AMBER_T) * 2.0)
		_apply(j)


## Phase states [phase 0, phase 1] for cycle time t.
static func phase_states(t: float) -> Array:
	var cycle := GREEN_T + AMBER_T
	var a := "red"
	var b := "red"
	if t < GREEN_T:
		a = "green"
	elif t < cycle:
		a = "amber"
	elif t < cycle + GREEN_T:
		b = "green"
	else:
		b = "amber"
	return [a, b]


func _apply(j: Dictionary) -> void:
	var states := phase_states(j["t"])
	if states[0] == j["state"][0] and states[1] == j["state"][1]:
		return
	j["state"] = states
	for h in j["heads"]:
		var mi: MeshInstance3D = h[0]
		var st: String = states[h[1]]
		mi.set_surface_override_material(1, _lit["red"] if st == "red" else _unlit["red"])
		mi.set_surface_override_material(2, _lit["amber"] if st == "amber" else _unlit["amber"])
		mi.set_surface_override_material(3, _lit["green"] if st == "green" else _unlit["green"])


## Light for traffic arriving at junction point `p` heading `heading`
## (direction of travel); "green" where there is no signal.
func state_for(p: Vector2, heading: Vector2) -> String:
	var key := Vector2i(roundi(p.x / SNAP), roundi(p.y / SNAP))
	if not junctions.has(key):
		return "green"
	var j: Dictionary = junctions[key]
	var arms: Array = j["arms"]
	# The arm we're on is the one whose `out` points back the way we came.
	var best := -2.0
	var arm := 0
	for i in arms.size():
		var d: float = -(arms[i]["out"] as Vector2).dot(heading)
		if d > best:
			best = d
			arm = i
	return j["state"][j["phases"][arm]]


func _make_materials() -> void:
	for pair in [["red", Color(1.0, 0.1, 0.05)], ["amber", Color(1.0, 0.65, 0.05)], ["green", Color(0.1, 1.0, 0.3)]]:
		var on := StandardMaterial3D.new()
		on.albedo_color = pair[1]
		on.emission_enabled = true
		on.emission = pair[1]
		on.emission_energy_multiplier = 2.5
		_lit[pair[0]] = on
		var off := StandardMaterial3D.new()
		off.albedo_color = (pair[1] as Color).darkened(0.7)
		_unlit[pair[0]] = off


func _make_pole() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.09
	pole.bottom_radius = 0.12
	pole.height = 5.2
	pole.radial_segments = 8
	st.append_from(pole, 0, Transform3D(Basis.IDENTITY, Vector3(0, 2.6, 0)))
	var arm := CylinderMesh.new()
	arm.top_radius = 0.06
	arm.bottom_radius = 0.07
	arm.height = 3.4
	arm.radial_segments = 6
	st.append_from(arm, 0, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(-1.7, 5.0, 0)))
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.36, 0.33)
	mat.metallic = 0.3
	mesh.surface_set_material(0, mat)
	return mesh


func _make_head() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var box := BoxMesh.new()
	box.size = Vector3(0.36, 1.05, 0.3)
	st.append_from(box, 0, Transform3D.IDENTITY)
	var mesh := st.commit()
	var housing := StandardMaterial3D.new()
	housing.albedo_color = Color(0.1, 0.1, 0.1)
	mesh.surface_set_material(0, housing)
	var ys := [0.33, 0.0, -0.33]
	for i in 3:
		var lamp := SurfaceTool.new()
		lamp.begin(Mesh.PRIMITIVE_TRIANGLES)
		var disc := CylinderMesh.new()
		disc.top_radius = 0.12
		disc.bottom_radius = 0.12
		disc.height = 0.04
		disc.radial_segments = 10
		# Faces +Z (toward the traffic the head is turned to).
		lamp.append_from(disc, 0, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, ys[i], 0.16)))
		mesh = lamp.commit(mesh)
	return mesh
