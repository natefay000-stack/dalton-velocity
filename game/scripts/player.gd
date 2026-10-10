extends CharacterBody3D
## On-foot controller: camera-relative WASD, sprint, jump.

## Default on-foot pace is a jog; hold Ctrl to walk, Shift to sprint.
@export var walk_speed := 1.6
@export var jog_speed := 4.0
@export var sprint_speed := 7.0
@export var jump_velocity := 5.0
@export var acceleration := 12.0

## Optional rigged character (.glb/.gltf). Empty -> CHARACTER_PATHS, then
## the procedural humanoid.
@export_file("*.glb", "*.gltf") var character_path := ""
## Look of the procedural humanoid (skin, hair, clothes).
@export var look_seed := 1

const Humanoid := preload("res://scripts/humanoid.gd")
const GltfCharacter := preload("res://scripts/gltf_character.gd")
const CHARACTER_PATHS := [
	"res://assets/characters/player.glb", "res://assets/characters/player.gltf",
]

var camera_rig: Node3D
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
## The visual body; has update_motion(delta, speed, grounded, vertical_speed).
var model: Node3D


func _ready() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	var cs := CollisionShape3D.new()
	cs.shape = capsule
	cs.position.y = 0.9
	add_child(cs)

	model = _make_model()
	add_child(model)

	floor_snap_length = 0.3


func _make_model() -> Node3D:
	var paths: Array = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--character="):
			paths.append(arg.trim_prefix("--character="))
	if character_path != "":
		paths.append(character_path)
	for p in CHARACTER_PATHS:
		if FileAccess.file_exists(p) or ResourceLoader.exists(p):
			paths.append(p)
	for p in paths:
		var m := GltfCharacter.load_from(p)
		if m != null:
			return m
	var h: Node3D = Humanoid.new()
	h.name = "Model"
	h.look_seed = look_seed
	h.build()
	return h


func set_active(active: bool) -> void:
	visible = active
	set_physics_process(active)
	for c in get_children():
		if c is CollisionShape3D:
			c.disabled = not active
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := Vector3(input.x, 0.0, input.y)
	if camera_rig != null:
		dir = camera_rig.flat_basis() * dir
	var speed := jog_speed
	if Input.is_action_pressed("sprint"):
		speed = sprint_speed
	elif Input.is_action_pressed("walk"):
		speed = walk_speed
	var target_vel := dir * speed
	var t := clampf(acceleration * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, target_vel.x, t)
	velocity.z = lerpf(velocity.z, target_vel.z, t)

	if dir.length_squared() > 0.01:
		var face := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, face, clampf(delta * 10.0, 0.0, 1.0))

	move_and_slide()
	model.update_motion(delta, Vector2(velocity.x, velocity.z).length(), is_on_floor(), velocity.y)

	# Fell through the world somehow — put back on the ground.
	if global_position.y < -50.0:
		global_position.y = 5.0
		velocity = Vector3.ZERO
