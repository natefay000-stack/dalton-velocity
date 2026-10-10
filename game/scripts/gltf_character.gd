extends Node3D
## Wraps an imported rigged character (.glb / .gltf) so it can stand in for
## the procedural humanoid. Works with Mixamo, Quaternius, KayKit and most
## other packs: clips are matched by name ("idle", "walk", "run"/"jog"/
## "sprint", "jump"/"fall"), the model is scaled to `target_height`, its
## feet are put on y = 0 and it is turned to face -Z. Size and facing are
## measured from the skeleton (toes point forward), because skinned-mesh
## bounds and export conventions vary too much between packs to trust.
##
## Same driving interface as humanoid.gd: update_motion().

## glTF characters conventionally face +Z; ours face -Z. Used only when the
## skeleton has no foot/toe bones to infer facing from.
const DEFAULT_YAW := PI

const CLIP_KEYWORDS := {
	"idle": ["idle", "stand", "breath"],
	"walk": ["walk"],
	"run": ["run", "jog", "sprint"],
	"air": ["fall", "jump", "air"],
}
## Clips whose names contain these are never auto-picked (poses, variants).
const CLIP_EXCLUDE := ["pose", "tpose", "t-pose", "start", "land", "back", "left", "right", "crouch", "sneak"]

var target_height := 1.78
var walk_speed_ref := 1.5  # m/s at which the walk clip looks right
var run_speed_ref := 5.5

var anim: AnimationPlayer
var clips: Dictionary = {}  # role -> clip name ("" if missing)
var _current := ""


## Loads a character from a res:// scene (imported by the editor) or any
## .glb/.gltf on disk (parsed at runtime). Returns null on failure.
static func load_from(path: String) -> Node3D:
	var scene_root: Node = null
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is PackedScene:
			scene_root = res.instantiate()
	if scene_root == null:
		var abs_path := ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(abs_path):
			push_warning("Character model not found: %s" % path)
			return null
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_file(abs_path, state)
		if err != OK:
			push_warning("Could not parse character model %s (error %d)" % [path, err])
			return null
		scene_root = doc.generate_scene(state)
	if not scene_root is Node3D:
		if scene_root:
			scene_root.free()
		push_warning("Character model %s has no 3D root" % path)
		return null

	var wrapper: Node3D = load("res://scripts/gltf_character.gd").new()
	wrapper.name = "Model"
	wrapper.setup(scene_root)
	return wrapper


func setup(model: Node3D) -> void:
	add_child(model)
	var skel := _find_skeleton(model)
	if skel != null and skel.get_bone_count() > 0:
		_fit_to_skeleton(model, skel)
	else:
		model.rotation.y = DEFAULT_YAW
		_fit_to_meshes(model)
	anim = _find_animation_player(model)
	if anim == null:
		push_warning("Character model has no AnimationPlayer; it will not animate")
		return
	clips = pick_clips(anim.get_animation_list())
	for role in clips:
		var clip_name: String = clips[role]
		if clip_name != "":
			anim.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	print("Character clips: ", clips)


## Picks the best clip per role from a list of names. Pure function so it
## can be unit tested.
static func pick_clips(names: PackedStringArray) -> Dictionary:
	var out := {}
	for role in CLIP_KEYWORDS:
		out[role] = ""
		var best_len := 1 << 30
		for n in names:
			var lower := n.to_lower()
			# Strip "Armature|" style prefixes Blender exports add.
			var bare := lower.get_slice("|", lower.get_slice_count("|") - 1)
			if CLIP_EXCLUDE.any(func(x): return bare.contains(x)):
				continue
			for kw in CLIP_KEYWORDS[role]:
				# Shortest matching name wins: "Walk" beats "Walk_Carry".
				if bare.contains(kw) and bare.length() < best_len:
					out[role] = n
					best_len = bare.length()
	if out["run"] == "":
		out["run"] = out["walk"]
	if out["walk"] == "":
		out["walk"] = out["run"]
	return out


func update_motion(_delta: float, speed: float, grounded: bool, _vertical_speed: float) -> void:
	if anim == null:
		return
	var role := "idle"
	var scale_speed := 1.0
	if not grounded and clips["air"] != "":
		role = "air"
	elif speed > 3.0 and clips["run"] != "":
		role = "run"
		scale_speed = clampf(speed / run_speed_ref, 0.6, 1.6)
	elif speed > 0.15 and clips["walk"] != "":
		role = "walk"
		scale_speed = clampf(speed / walk_speed_ref, 0.5, 1.8)
	var clip: String = clips.get(role, "")
	if clip == "":
		clip = clips.get("idle", "")
	if clip == "":
		return
	if clip != _current:
		anim.play(clip, 0.2)
		_current = clip
	anim.speed_scale = scale_speed


func _find_animation_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var found := _find_animation_player(c)
		if found:
			return found
	return null


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var found := _find_skeleton(c)
		if found:
			return found
	return null


## Transform of `node` relative to `ancestor`, without needing the tree.
func _relative_xform(ancestor: Node, node: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


func _fit_to_skeleton(model: Node3D, skel: Skeleton3D) -> void:
	var to_model := _relative_xform(model, skel)
	var lo := INF
	var hi := -INF
	var has_head_end := false
	var toe_sum := Vector3.ZERO
	var foot_sum := Vector3.ZERO
	var toes := 0
	var feet := 0
	for i in skel.get_bone_count():
		var pos := to_model * skel.get_bone_global_rest(i).origin
		lo = minf(lo, pos.y)
		hi = maxf(hi, pos.y)
		var bn := skel.get_bone_name(i).to_lower()
		if bn.contains("headtop") or bn.contains("head_end") or bn.contains("head.end"):
			has_head_end = true
		if bn.contains("toe"):
			toe_sum += pos
			toes += 1
		elif bn.contains("foot") or bn.contains("ankle"):
			foot_sum += pos
			feet += 1

	# Face -Z: rotate so the ankle->toe direction points along -Z.
	var yaw := DEFAULT_YAW
	if toes > 0 and feet > 0:
		var d := toe_sum / toes - foot_sum / feet
		if Vector2(d.x, d.z).length() > 1e-4:
			yaw = PI - atan2(d.x, d.z)
	model.rotation.y = yaw

	var span := hi - lo
	if span < 1e-4:
		_fit_to_meshes(model)
		return
	# Without a head-top bone the span stops at the head joint (~88%).
	var height := span if has_head_end else span / 0.88
	var s := target_height / height
	model.scale *= s
	model.position.y -= lo * s


## Fallback for unrigged models: scale mesh bounds, feet on y = 0.
func _fit_to_meshes(model: Node3D) -> void:
	var box := _collect_aabb(model, Transform3D.IDENTITY)
	if box.size.y < 1e-4:
		return
	var s := target_height / box.size.y
	model.scale *= s
	model.position.y -= box.position.y * s


func _collect_aabb(n: Node, parent_xf: Transform3D) -> AABB:
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	var box := AABB()
	var has := false
	if n is MeshInstance3D and n.mesh:
		box = xf * n.mesh.get_aabb()
		has = true
	for c in n.get_children():
		var cb := _collect_aabb(c, xf)
		if cb.size != Vector3.ZERO:
			box = cb if not has else box.merge(cb)
			has = true
	return box
