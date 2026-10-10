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

# Gait. Stride = distance per full cycle (two steps); duty = fraction of the
# cycle a foot is on the ground (>0.5 walking, <0.5 running = flight phase).
const WALK_STRIDE := 1.2
const RUN_STRIDE := 2.3
const WALK_DUTY := 0.6
const RUN_DUTY := 0.34
const SWING_LIFT := 0.07
const TOE_OFF_PITCH := 0.5  # rad, foot angle at the end of stance
const FOOT_BALL := 0.19  # ankle -> toe tip (pivot when the heel lifts)
const FOOT_HEEL := 0.085  # ankle -> back of heel (pivot at heel strike)
const FOOT_SPREAD := 0.095  # = lateral hip joint offset, feet under hips
const IDLE_SPEED := 0.15
const SETTLE_DISTANCE := 0.12
const SETTLE_TIME := 0.28
const SHOULDER_ROLL := 0.08
## Ground probe range above/below the character's floor height.
const PROBE_UP := 0.9
const PROBE_DOWN := 1.2
## Ignore floor contact blips shorter than this (CharacterBody3D can report
## is_on_floor() false for a frame on seams).
const AIR_GRACE := 0.12

var joints: Dictionary = {}  # name -> Node3D
var _pose: Dictionary = {}  # joint name -> current X angle
var _phase := 0.0  # 0..1 through the gait cycle
## side -> {pos: world ankle target, from, planted, lift, pitch, settle}
var _feet: Dictionary = {}
var _was_airborne := false
var _air_time := 0.0
var _idle := true
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
		shoulder.rotation.z = SHOULDER_ROLL * side  # arms hang slightly away from the body

		# Legs.
		var hip := _joint("hip_" + s, hips, Vector3(0.095 * side, -HIP_DROP, 0))
		_part(hip, _capsule(0.085, THIGH + 0.1), Vector3(0, -THIGH * 0.5, 0), Vector3.ZERO, Vector3(1, 1, 1.05), "pants")
		var knee := _joint("knee_" + s, hip, Vector3(0, -THIGH, 0))
		_part(knee, _capsule(0.062, SHIN + 0.06), Vector3(0, -SHIN * 0.5, 0), Vector3.ZERO, Vector3(1, 1, 1.05), "pants")
		var ankle := _joint("ankle_" + s, knee, Vector3(0, -SHIN, 0))
		# Shoe: rounded upper on a flat sole, toes toward -Z.
		_part(ankle, _capsule(0.052, 0.27), Vector3(0, -0.028, -0.055), Vector3(PI / 2, 0, 0), Vector3(1.0, 1, 0.8), "shoes")
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
#
# Legs use foot planting: each foot has a world-space ankle target. While a
# foot is in stance its target is locked to the ground, so it cannot slide or
# sink; during swing it arcs to a predicted landing spot. A two-bone IK solve
# per leg turns targets into hip/knee/ankle rotations, and the pelvis lowers
# just enough that both targets stay reachable (which also gives the natural
# up-and-down bob of a walk). Arms, spine and head stay procedural.

## velocity: body velocity in world space (m/s). grounded: on floor.
func update_motion(delta: float, velocity: Vector3, grounded: bool) -> void:
	if joints.is_empty() or delta <= 0.0:
		return
	_time += delta
	var flat_vel := Vector3(velocity.x, 0.0, velocity.z)
	var speed := flat_vel.length()
	var t := clampf(delta * 12.0, 0.0, 1.0)

	_air_time = 0.0 if grounded else _air_time + delta
	if _air_time > AIR_GRACE:
		_was_airborne = true
		_air_pose(velocity.y, t)
		return
	if _was_airborne or not _feet_valid():
		_was_airborne = false
		_reset_feet()

	var run := clampf((speed - 2.2) / 3.0, 0.0, 1.0)
	var lean := 0.0
	var spine_twist := 0.0
	var hips_target := HIP_HEIGHT - 0.008
	var arm_target := {"l": 0.0, "r": 0.0}

	if speed < IDLE_SPEED:
		_idle = true
		_settle_feet(delta)
		var breathe := sin(_time * 1.6)
		_pose["spine"] = lerpf(_pose["spine"], 0.015 * breathe, t)
		_pose["neck"] = lerpf(_pose["neck"], -0.01 * breathe, t)
	else:
		if _idle:
			# Moving off from standing: both feet are under the body, which
			# matches mid-stance of the left foot (and mid-swing of the right).
			_idle = false
			_phase = lerpf(WALK_DUTY, RUN_DUTY, run) * 0.5
		_cancel_settle()
		var stride := lerpf(WALK_STRIDE, RUN_STRIDE, run)
		var duty := lerpf(WALK_DUTY, RUN_DUTY, run)
		var cycle := stride / speed
		_phase = fmod(_phase + delta / cycle, 1.0)
		for side in ["l", "r"]:
			_gait_foot(side, fmod(_phase + (0.0 if side == "l" else 0.5), 1.0), duty, cycle, flat_vel, run)
		hips_target -= lerpf(0.0, 0.05, run)
		lean = -lerpf(0.04, 0.2, run)
		spine_twist = 0.12 * sin(_phase * TAU) * lerpf(1.0, 0.6, run)
		_pose["neck"] = lerpf(_pose["neck"], -lean * 0.7, t)
		_pose["spine"] = lerpf(_pose["spine"], 0.0, t)

	# Pelvis: as high as wanted, but never so high a foot can't reach.
	var hips: Node3D = joints["hips"]
	var hips_max := _max_reachable_hips_y()
	# Floor: past this a foot is simply out of reach (sudden turn/stop) and
	# the IK clamps rather than the body crouching to the ground.
	_hips_y = maxf(minf(lerpf(_hips_y, hips_target, t), hips_max), HIP_HEIGHT - 0.16)
	hips.position.y = _hips_y
	var spine: Node3D = joints["spine"]
	spine.rotation.x = lerpf(spine.rotation.x, lean + _pose["spine"], t)
	spine.rotation.y = lerpf(spine.rotation.y, spine_twist, t)
	hips.rotation = Vector3(0.0, -spine.rotation.y * 0.5, 0.0)
	joints["neck"].rotation.x = _pose["neck"]

	for side in ["l", "r"]:
		var thigh := _solve_leg(side)
		arm_target["r" if side == "l" else "l"] = -thigh

	# Arms counter-swing with the opposite leg.
	for side in ["l", "r"]:
		var swing: float = arm_target[side] * lerpf(0.75, 0.7, run) if speed >= IDLE_SPEED else 0.0
		_pose["shoulder_" + side] = lerpf(_pose["shoulder_" + side], swing, t)
		var elbow := lerpf(0.2, 1.5, run) if speed >= IDLE_SPEED else 0.12
		_pose["elbow_" + side] = lerpf(_pose["elbow_" + side], elbow, t)
		joints["shoulder_" + side].rotation.x = _pose["shoulder_" + side]
		joints["elbow_" + side].rotation.x = _pose["elbow_" + side]


## Updates one foot's target for walking/running. u: 0..1 position in the
## gait cycle; [0, duty) is stance, [duty, 1) swing.
func _gait_foot(side: String, u: float, duty: float, cycle: float, vel: Vector3, run: float) -> void:
	var f: Dictionary = _feet[side]
	if u < duty:
		if not f["planted"]:
			f["planted"] = true  # touchdown: lock where the swing ended
			_snap_to_ground(f)
		# Late stance: heel peels off while the ball of the foot stays down.
		var q := u / duty
		f["pitch"] = smoothstep(0.55, 1.0, q) * TOE_OFF_PITCH
		if q < 0.12:
			f["pitch"] = -0.2 * (1.0 - q / 0.12) * (1.0 - run)  # heel strike, toes up
		f["lift"] = _pivot_lift(f["pitch"])
	else:
		if f["planted"]:
			f["planted"] = false
			f["from"] = f["pos"]
		var s := (u - duty) / (1.0 - duty)
		# Land half a stance ahead of where the body will be at touchdown.
		var remaining := (1.0 - s) * (1.0 - duty) * cycle
		var land := global_position + vel * (remaining + duty * cycle * 0.5) + _rest_offset(side)
		var hit := _probe(land)
		land = hit[0] + hit[1] * ANKLE
		var k := smoothstep(0.0, 1.0, s)
		var p: Vector3 = (f["from"] as Vector3).lerp(land, k)
		p.y += sin(PI * s) * lerpf(SWING_LIFT, SWING_LIFT * 2.2, run)
		f["pos"] = p
		f["n"] = (f["n"] as Vector3).slerp(hit[1], k)
		f["pitch"] = lerpf(TOE_OFF_PITCH, 0.0, smoothstep(0.0, 0.6, s)) - 0.15 * smoothstep(0.6, 1.0, s)
		f["lift"] = _pivot_lift(f["pitch"])


## Standing still: step any foot that ended up away from its rest spot
## (stopping mid-stride, turning on the spot), one foot at a time.
func _settle_feet(delta: float) -> void:
	for side in ["l", "r"]:
		var f: Dictionary = _feet[side]
		f["pitch"] = lerpf(f["pitch"], 0.0, clampf(delta * 10.0, 0.0, 1.0))
		f["lift"] = _pivot_lift(f["pitch"])
		if f["settle"] >= 0.0:
			f["settle"] += delta / SETTLE_TIME
			var s := minf(f["settle"], 1.0)
			var rest := _rest_world(side)
			var p: Vector3 = (f["from"] as Vector3).lerp(rest, smoothstep(0.0, 1.0, s))
			p.y += sin(PI * s) * SWING_LIFT
			f["pos"] = p
			f["planted"] = false
			if s >= 1.0:
				f["settle"] = -1.0
				f["planted"] = true
				_snap_to_ground(f)
			return  # one foot steps at a time
	for side in ["l", "r"]:
		var f: Dictionary = _feet[side]
		var rest := _rest_world(side)
		var off := Vector2(f["pos"].x - rest.x, f["pos"].z - rest.z).length()
		if off > SETTLE_DISTANCE or not f["planted"]:
			f["settle"] = 0.0
			f["from"] = f["pos"]
			return


## How far the ankle must rise so a foot pitched by `pitch` rests on its
## ball (toes down, +) or heel (toes up, -) instead of cutting into the floor.
func _pivot_lift(pitch: float) -> float:
	var arm := FOOT_BALL if pitch > 0.0 else FOOT_HEEL
	return arm * sin(absf(pitch)) - ANKLE * (1.0 - cos(pitch))


func _cancel_settle() -> void:
	for side in ["l", "r"]:
		var f: Dictionary = _feet[side]
		if f["settle"] >= 0.0:
			f["settle"] = -1.0
			f["planted"] = false
			f["from"] = f["pos"]


func _rest_offset(side: String) -> Vector3:
	return global_basis * Vector3(FOOT_SPREAD * (-1.0 if side == "l" else 1.0), 0.0, 0.0)


func _rest_world(side: String) -> Vector3:
	var hit := _probe(global_position + _rest_offset(side))
	return hit[0] + hit[1] * ANKLE


## [ground point, ground normal] under `at` (world xz). Raycasts against
## everything except our own body; without a hit (no physics world, off the
## edge) the character's floor is assumed flat at its own height.
func _probe(at: Vector3) -> Array:
	var ref_y := global_position.y
	if is_inside_tree():
		var space := get_world_3d().direct_space_state
		if space != null:
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(at.x, ref_y + PROBE_UP, at.z), Vector3(at.x, ref_y - PROBE_DOWN, at.z))
			var body := get_parent() as CollisionObject3D
			if body != null:
				q.exclude = [body.get_rid()]
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and (hit["normal"] as Vector3).y > 0.5:
				return [hit["position"], hit["normal"]]
	return [Vector3(at.x, ref_y, at.z), Vector3.UP]


## Puts a foot that is touching down exactly on the ground below it.
func _snap_to_ground(f: Dictionary) -> void:
	var hit := _probe(f["pos"])
	f["pos"] = hit[0] + hit[1] * ANKLE
	f["n"] = hit[1]


func _reset_feet() -> void:
	for side in ["l", "r"]:
		var hit := _probe(global_position + _rest_offset(side))
		var p: Vector3 = hit[0] + hit[1] * ANKLE
		_feet[side] = {
			"pos": p, "from": p, "planted": true, "n": hit[1],
			"lift": 0.0, "pitch": 0.0, "settle": -1.0,
		}


## False after a teleport (or before the first frame): planted feet are
## nowhere near the body.
func _feet_valid() -> bool:
	if _feet.is_empty():
		return false
	for side in ["l", "r"]:
		var p: Vector3 = _feet[side]["pos"]
		if Vector2(p.x - global_position.x, p.z - global_position.z).length() > 1.5 \
				or absf(p.y - global_position.y) > 1.0:
			return false
	return true


## Ankle target in the hips' local space, including heel lift.
func _target_local(side: String) -> Vector3:
	var f: Dictionary = _feet[side]
	var world: Vector3 = f["pos"] + Vector3(0.0, f["lift"], 0.0)
	return joints["hips"].get_parent().global_transform.affine_inverse() * world


## Highest pelvis (model space) from which both ankle targets are reachable
## with the knee very slightly bent.
func _max_reachable_hips_y() -> float:
	var reach := (THIGH + SHIN) * 0.985
	var best := HIP_HEIGHT
	for side in ["l", "r"]:
		var tgt := _target_local(side)
		var hip_x := FOOT_SPREAD * (-1.0 if side == "l" else 1.0)
		var horiz := Vector2(tgt.x - hip_x, tgt.z).length()
		if horiz >= reach:
			best = minf(best, tgt.y + HIP_DROP + 0.05)
			continue
		best = minf(best, tgt.y + sqrt(reach * reach - horiz * horiz) + HIP_DROP)
	return best


## Two-bone IK for one leg. Returns the thigh swing angle (for arm swing).
func _solve_leg(side: String) -> float:
	var hips: Node3D = joints["hips"]
	var hip: Node3D = joints["hip_" + side]
	var knee: Node3D = joints["knee_" + side]
	var ankle: Node3D = joints["ankle_" + side]
	var d: Vector3 = hips.global_transform.affine_inverse() * (_feet[side]["pos"] + Vector3(0.0, _feet[side]["lift"], 0.0)) - hip.position

	# Roll the leg plane sideways so it contains the target, then solve in it.
	var roll := clampf(atan2(d.x, -d.y), -0.35, 0.35)
	var in_plane := Basis(Vector3.BACK, -roll) * d
	var dist := clampf(in_plane.length(), absf(THIGH - SHIN) + 0.01, THIGH + SHIN - 0.0005)
	var to_target := atan2(-in_plane.z, -in_plane.y)
	var cos_alpha := (THIGH * THIGH + dist * dist - SHIN * SHIN) / (2.0 * THIGH * dist)
	var cos_knee := (THIGH * THIGH + SHIN * SHIN - dist * dist) / (2.0 * THIGH * SHIN)
	var thigh := to_target + acos(clampf(cos_alpha, -1.0, 1.0))
	var bend := -(PI - acos(clampf(cos_knee, -1.0, 1.0)))

	hip.basis = Basis(Vector3.BACK, roll) * Basis(Vector3.RIGHT, thigh)
	knee.basis = Basis(Vector3.RIGHT, bend)
	# Sole parallel to the ground under it (facing where the body faces),
	# plus heel/toe pitch. Solved in world space, then made local.
	var up: Vector3 = _feet[side]["n"]
	var fwd := global_basis.z.slide(up).normalized()
	if fwd.length_squared() < 0.5:
		fwd = global_basis.z
	var foot_world := Basis(up.cross(fwd).normalized(), up, fwd)
	var parent_world: Basis = hips.global_basis * hip.basis * knee.basis
	ankle.basis = parent_world.orthonormalized().inverse() * foot_world \
		* Basis(Vector3.RIGHT, -_feet[side]["pitch"])  # +pitch = toes down
	_pose["hip_" + side] = thigh
	_pose["knee_" + side] = bend
	return thigh


## Airborne: knees up while rising, legs reaching down while falling.
func _air_pose(vertical_speed: float, t: float) -> void:
	var rising := clampf(vertical_speed / 4.0, -1.0, 1.0)
	var target := {
		"hip_l": 0.55 + 0.25 * rising, "knee_l": -1.0 - 0.3 * rising,
		"hip_r": 0.1, "knee_r": -0.5, "ankle_l": 0.0, "ankle_r": 0.0,
		"shoulder_l": -0.4, "shoulder_r": 0.5, "elbow_l": 0.6, "elbow_r": 0.6,
		"neck": 0.0, "spine": 0.0,
	}
	for j in target:
		_pose[j] = lerpf(_pose[j], target[j], t)
		if j != "spine":
			var roll := 0.0
			if j.begins_with("shoulder"):
				roll = SHOULDER_ROLL * (-1.0 if j.ends_with("_l") else 1.0)
			(joints[j] as Node3D).rotation = Vector3(_pose[j], 0.0, roll)
	var spine: Node3D = joints["spine"]
	spine.rotation.x = lerpf(spine.rotation.x, -0.1, t)
	_hips_y = lerpf(_hips_y, HIP_HEIGHT, t)
	joints["hips"].position.y = _hips_y


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
