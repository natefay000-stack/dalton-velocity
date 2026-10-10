extends Node3D
## Procedural human: an articulated body (pelvis, spine, neck, head, arms,
## legs, hands, feet) with clothing, built from smooth primitives, plus a
## procedural idle / walk / run / airborne cycle.
##
## Origin is at the feet, facing -Z. Joint pivots are Node3Ds; a positive X
## rotation swings a hanging limb forward (toward -Z).
##
## Drive it every frame with update_motion().

## Seed for skin / hair / clothing choice. Same seed -> same person.
@export var look_seed := 1

const SKIN_TONES := [
	Color(0.96, 0.80, 0.69), Color(0.89, 0.70, 0.56), Color(0.78, 0.57, 0.42),
	Color(0.63, 0.43, 0.30), Color(0.45, 0.30, 0.21), Color(0.33, 0.22, 0.16),
]
const HAIR_COLORS := [
	Color(0.08, 0.06, 0.05), Color(0.23, 0.15, 0.09), Color(0.45, 0.30, 0.17),
	Color(0.70, 0.55, 0.32), Color(0.55, 0.25, 0.12), Color(0.55, 0.55, 0.55),
]
const SHIRT_COLORS := [
	Color(0.85, 0.85, 0.85), Color(0.12, 0.13, 0.15), Color(0.20, 0.30, 0.55),
	Color(0.55, 0.12, 0.12), Color(0.25, 0.42, 0.28), Color(0.80, 0.62, 0.25),
]
const PANTS_COLORS := [
	Color(0.18, 0.25, 0.40), Color(0.12, 0.12, 0.13), Color(0.40, 0.36, 0.28),
	Color(0.28, 0.30, 0.33),
]
const SHOE_COLORS := [Color(0.92, 0.92, 0.92), Color(0.10, 0.10, 0.10), Color(0.35, 0.22, 0.12)]

# Body dimensions (metres) for a ~1.78 m adult.
const THIGH := 0.43
const SHIN := 0.42
const ANKLE := 0.07
const HIP_DROP := 0.05  # hip joints sit this far below the pelvis pivot
const HIP_HEIGHT := THIGH + SHIN + ANKLE + HIP_DROP
const SPINE := 0.46
const UPPER_ARM := 0.30
const FOREARM := 0.26

# Stride: distance covered per full gait cycle (two steps).
const WALK_STRIDE := 1.45
const RUN_STRIDE := 2.6
const WALK_SPEED_REF := 1.6
const RUN_SPEED_REF := 6.0

var joints: Dictionary = {}  # name -> Node3D
var _pose: Dictionary = {}  # joint name -> current X angle
var _phase := 0.0
var _time := 0.0
var _hips_y := HIP_HEIGHT
var _mats: Dictionary = {}


func _ready() -> void:
	if joints.is_empty():
		build()


func build() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = look_seed
	_mats["skin"] = _mat(SKIN_TONES[rng.randi() % SKIN_TONES.size()], 0.6)
	_mats["hair"] = _mat(HAIR_COLORS[rng.randi() % HAIR_COLORS.size()], 0.8)
	_mats["shirt"] = _mat(SHIRT_COLORS[rng.randi() % SHIRT_COLORS.size()], 0.85)
	_mats["pants"] = _mat(PANTS_COLORS[rng.randi() % PANTS_COLORS.size()], 0.9)
	_mats["shoes"] = _mat(SHOE_COLORS[rng.randi() % SHOE_COLORS.size()], 0.5)
	_mats["sole"] = _mat(Color(0.15, 0.15, 0.15), 0.9)
	_mats["eye"] = _mat(Color(0.05, 0.05, 0.06), 0.2)
	_mats["eye_white"] = _mat(Color(0.95, 0.95, 0.93), 0.3)
	_mats["lip"] = _mat((_mats["skin"].albedo_color as Color).darkened(0.25), 0.5)
	var long_hair := rng.randf() < 0.4

	var hips := _joint("hips", self, Vector3(0, HIP_HEIGHT, 0))
	# Pelvis / shorts block.
	_part(hips, _capsule(0.13, 0.36), Vector3(0, -0.02, 0), Vector3(0, 0, PI / 2), Vector3(1, 1, 0.75), "pants")
	_part(hips, _cylinder(0.155, 0.15, 0.06), Vector3(0, 0.07, 0), Vector3.ZERO, Vector3(1, 1, 0.7), "pants")  # waistband

	var spine := _joint("spine", hips, Vector3(0, 0.08, 0))
	# Torso: a tapered cylinder (waist -> chest) capped by a flattened
	# capsule across the shoulders, so the silhouette narrows at the waist.
	_part(spine, _cylinder(0.175, 0.15, 0.36), Vector3(0, 0.17, 0), Vector3.ZERO, Vector3(1.0, 1, 0.62), "shirt")
	_part(spine, _capsule(0.10, 0.44), Vector3(0, 0.37, 0.0), Vector3(0, 0, PI / 2), Vector3(1, 0.9, 1.1), "shirt")
	_part(spine, _capsule(0.085, 0.36), Vector3(0, 0.02, 0), Vector3(0, 0, PI / 2), Vector3(1, 0.7, 0.62), "shirt")  # hem

	var neck := _joint("neck", spine, Vector3(0, SPINE - 0.01, 0.0))
	_part(neck, _cylinder(0.048, 0.056, 0.10), Vector3(0, 0.03, 0.005), Vector3.ZERO, Vector3.ONE, "skin")
	var head := _joint("head", neck, Vector3(0, 0.07, 0))
	_build_head(head, long_hair)

	for side in [-1, 1]:
		var s := "l" if side < 0 else "r"
		# Arms.
		var shoulder := _joint("shoulder_" + s, spine, Vector3(0.20 * side, 0.39, 0))
		_part(shoulder, _capsule(0.056, 0.21), Vector3(0, -0.06, 0), Vector3.ZERO, Vector3(1, 1, 1.05), "shirt")  # sleeve
		_part(shoulder, _capsule(0.042, UPPER_ARM), Vector3(0, -UPPER_ARM * 0.5, 0), Vector3.ZERO, Vector3.ONE, "skin")
		var elbow := _joint("elbow_" + s, shoulder, Vector3(0, -UPPER_ARM, 0))
		_part(elbow, _capsule(0.036, FOREARM + 0.03), Vector3(0, -FOREARM * 0.5, 0), Vector3.ZERO, Vector3(1, 1, 1.05), "skin")
		var wrist := _joint("wrist_" + s, elbow, Vector3(0, -FOREARM, 0))
		_part(wrist, _capsule(0.038, 0.13), Vector3(0, -0.055, 0), Vector3.ZERO, Vector3(0.65, 1, 1.15), "skin")  # palm
		_part(wrist, _capsule(0.018, 0.07), Vector3(0.0, -0.02, -0.035), Vector3(-0.6, 0, 0), Vector3.ONE, "skin")  # thumb
		shoulder.rotation.z = 0.08 * side  # arms hang slightly away from the body

		# Legs.
		var hip := _joint("hip_" + s, hips, Vector3(0.095 * side, -HIP_DROP, 0))
		_part(hip, _capsule(0.085, THIGH + 0.1), Vector3(0, -THIGH * 0.5, 0), Vector3.ZERO, Vector3(1, 1, 1.05), "pants")
		var knee := _joint("knee_" + s, hip, Vector3(0, -THIGH, 0))
		_part(knee, _capsule(0.062, SHIN + 0.06), Vector3(0, -SHIN * 0.5, 0), Vector3.ZERO, Vector3(1, 1, 1.05), "pants")
		var ankle := _joint("ankle_" + s, knee, Vector3(0, -SHIN, 0))
		# Shoe: rounded upper on a flat sole, toes toward -Z.
		_part(ankle, _capsule(0.052, 0.27), Vector3(0, -0.035, -0.055), Vector3(PI / 2, 0, 0), Vector3(1.0, 1, 0.8), "shoes")
		_part(ankle, _box(Vector3(0.10, 0.025, 0.27)), Vector3(0, -ANKLE + 0.0125, -0.055), Vector3.ZERO, Vector3.ONE, "sole")

	for j in joints:
		_pose[j] = 0.0


func _build_head(head: Node3D, long_hair: bool) -> void:
	# Skull (slightly longer front-to-back than wide) and jaw.
	_part(head, _sphere(0.095, 0.23), Vector3(0, 0.12, 0.005), Vector3.ZERO, Vector3(0.9, 1, 1.05), "skin")
	_part(head, _sphere(0.068, 0.12), Vector3(0, 0.05, -0.012), Vector3.ZERO, Vector3(1, 1, 0.95), "skin")
	# Nose, ears, eyes, brows, mouth.
	_part(head, _sphere(0.016, 0.05), Vector3(0, 0.098, -0.094), Vector3(-0.35, 0, 0), Vector3(1, 1, 1.25), "skin")
	for side in [-1, 1]:
		_part(head, _sphere(0.02, 0.05), Vector3(0.087 * side, 0.105, 0.005), Vector3.ZERO, Vector3(0.45, 1, 0.85), "skin")
		_part(head, _sphere(0.012, 0.024), Vector3(0.033 * side, 0.118, -0.089), Vector3.ZERO, Vector3(1.1, 0.7, 0.5), "eye_white")
		_part(head, _sphere(0.0065, 0.013), Vector3(0.033 * side, 0.118, -0.0945), Vector3.ZERO, Vector3(1, 1, 0.5), "eye")
		_part(head, _box(Vector3(0.032, 0.006, 0.012)), Vector3(0.034 * side, 0.138, -0.096), Vector3(0, 0, -0.12 * side), Vector3.ONE, "hair")
	_part(head, _box(Vector3(0.036, 0.008, 0.01)), Vector3(0, 0.058, -0.083), Vector3.ZERO, Vector3.ONE, "lip")
	# Hair: a cap tilted back so the hairline sits high on the forehead and
	# low at the nape.
	var cap := SphereMesh.new()
	cap.radius = 0.1
	cap.height = 0.125  # for a hemisphere this is the dome height
	cap.is_hemisphere = true
	cap.radial_segments = 24
	_part(head, cap, Vector3(0, 0.122, 0.012), Vector3(0.55, 0, 0), Vector3(0.95, 1.0, 1.12), "hair")
	if long_hair:
		_part(head, _capsule(0.085, 0.28), Vector3(0, 0.04, 0.065), Vector3(0.12, 0, 0), Vector3(1.05, 1, 0.55), "hair")


# --- Animation -------------------------------------------------------------

## speed: horizontal m/s. grounded: on floor. vertical_speed: m/s, + is up.
func update_motion(delta: float, speed: float, grounded: bool, vertical_speed: float) -> void:
	if joints.is_empty():
		return
	_time += delta
	var target := {}
	for j in _pose:
		target[j] = 0.0
	var hips_y := HIP_HEIGHT
	var lean := 0.0
	var spine_twist := 0.0

	if not grounded:
		# Airborne: knees up while rising, legs reaching down while falling.
		var rising := clampf(vertical_speed / 4.0, -1.0, 1.0)
		target["hip_l"] = 0.55 + 0.25 * rising
		target["knee_l"] = -1.0 - 0.3 * rising
		target["hip_r"] = 0.1
		target["knee_r"] = -0.5
		target["shoulder_l"] = -0.4
		target["shoulder_r"] = 0.5
		target["elbow_l"] = 0.6
		target["elbow_r"] = 0.6
		lean = -0.1
	elif speed < 0.15:
		# Idle: breathing and a slow weight shift.
		var breathe := sin(_time * 1.6)
		target["spine"] = 0.015 * breathe
		target["neck"] = -0.01 * breathe
		target["elbow_l"] = 0.12
		target["elbow_r"] = 0.12
		target["knee_l"] = -0.04
		hips_y -= 0.005
	else:
		# Run blend 0 (walk) .. 1 (run).
		var run := clampf((speed - 2.2) / 3.0, 0.0, 1.0)
		var stride := lerpf(WALK_STRIDE, RUN_STRIDE, run)
		_phase = fmod(_phase + delta * speed / stride * TAU, TAU)
		var p := _phase
		var swing := lerpf(0.42, 0.75, run) * clampf(speed / WALK_SPEED_REF, 0.3, 1.0)
		for side in [["l", 0.0], ["r", PI]]:
			var s: String = side[0]
			var ph: float = p + side[1]
			var thigh := swing * sin(ph)
			# Knee flexes most mid-swing (thigh moving forward).
			var knee := -(lerpf(0.65, 1.5, run) * maxf(0.0, cos(ph)) + lerpf(0.06, 0.3, run))
			target["hip_" + s] = thigh + lerpf(0.0, 0.2, run)
			target["knee_" + s] = knee
			# Toe-off: foot points down as the leg trails.
			target["ankle_" + s] = 0.25 * maxf(0.0, -sin(ph)) * (1.0 - run) + 0.15 * run
			# Arms counter-swing to the opposite leg.
			target["shoulder_" + s] = -thigh * lerpf(0.75, 0.7, run)
			target["elbow_" + s] = lerpf(0.2, 1.5, run) + 0.15 * maxf(0.0, -sin(ph))
		# Hips drop when legs are spread, rise over the planted foot.
		var spread := absf(sin(p))
		hips_y -= lerpf(0.035, 0.05, run) * spread + lerpf(0.0, 0.04, run)
		lean = -lerpf(0.04, 0.2, run)
		spine_twist = 0.12 * sin(p) * lerpf(1.0, 0.6, run)
		target["neck"] = -lean * 0.7

	var t := clampf(delta * 12.0, 0.0, 1.0)
	for j in _pose:
		_pose[j] = lerpf(_pose[j], target[j], t)
		if j == "spine":
			continue  # set below together with lean and twist
		var node: Node3D = joints[j]
		node.rotation.x = _pose[j]
	_hips_y = lerpf(_hips_y, hips_y, t)
	joints["hips"].position.y = _hips_y
	var spine: Node3D = joints["spine"]
	spine.rotation.x = lerpf(spine.rotation.x, lean + target["spine"], t)
	spine.rotation.y = lerpf(spine.rotation.y, spine_twist, t)
	joints["hips"].rotation.y = -spine.rotation.y * 0.5


# --- Construction helpers --------------------------------------------------

func _joint(name: String, parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.position = pos
	parent.add_child(n)
	joints[name] = n
	return n


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, rot: Vector3, scl: Vector3, mat: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mats[mat]
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	parent.add_child(mi)
	return mi


func _mat(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = maxf(height, radius * 2.0)
	m.radial_segments = 16
	m.rings = 6
	return m


func _sphere(radius: float, height: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = height
	m.radial_segments = 20
	m.rings = 10
	return m


func _cylinder(top: float, bottom: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = 16
	return m


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m
