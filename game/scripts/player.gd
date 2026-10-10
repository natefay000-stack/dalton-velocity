extends CharacterBody3D
## On-foot controller: camera-relative WASD, sprint, jump.

@export var walk_speed := 4.5
@export var sprint_speed := 8.0
@export var jump_velocity := 5.0
@export var acceleration := 12.0

var camera_rig: Node3D
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _body_mesh: MeshInstance3D


func _ready() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var cs := CollisionShape3D.new()
	cs.shape = capsule
	cs.position.y = 0.9
	add_child(cs)

	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.35, 0.75)
	mesh.material = mat
	_body_mesh = MeshInstance3D.new()
	_body_mesh.mesh = mesh
	_body_mesh.position.y = 0.9
	add_child(_body_mesh)

	# A "nose" so you can see which way the character faces.
	var nose := MeshInstance3D.new()
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.2, 0.12, 0.25)
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 1.5, -0.35)
	add_child(nose)

	floor_snap_length = 0.3


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
	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	var target_vel := dir * speed
	var t := clampf(acceleration * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, target_vel.x, t)
	velocity.z = lerpf(velocity.z, target_vel.z, t)

	if dir.length_squared() > 0.01:
		var face := atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, face, clampf(delta * 10.0, 0.0, 1.0))

	move_and_slide()

	# Fell through the world somehow — put back on the ground.
	if global_position.y < -50.0:
		global_position.y = 5.0
		velocity = Vector3.ZERO
