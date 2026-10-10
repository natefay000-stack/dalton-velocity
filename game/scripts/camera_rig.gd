extends Node3D
## Third-person orbit camera. Follows `target`, mouse controls yaw/pitch, a
## SpringArm3D pulls the camera in when a wall gets between it and the target.

@export var target: Node3D
@export var distance := 5.0
@export var height := 1.6
@export var mouse_sensitivity := 0.003
## While driving, gently swing the camera behind the vehicle.
@export var auto_align := false

var yaw := 0.0
var pitch := -0.25
var _arm: SpringArm3D
var _camera: Camera3D
var _idle_mouse_time := 0.0


func _ready() -> void:
	_arm = SpringArm3D.new()
	_arm.spring_length = distance
	_arm.margin = 0.3
	var probe := SphereShape3D.new()
	probe.radius = 0.25
	_arm.shape = probe
	add_child(_arm)
	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.far = 3000.0
	_arm.add_child(_camera)
	_camera.make_current()


func set_target(node: Node3D, follow_distance: float, follow_height: float, align: bool) -> void:
	target = node
	distance = follow_distance
	height = follow_height
	auto_align = align
	_arm.spring_length = distance
	# Physics bodies the camera follows shouldn't block the spring arm.
	_arm.clear_excluded_objects()
	if node is CollisionObject3D:
		_arm.add_excluded_object(node.get_rid())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch = clampf(pitch - event.relative.y * mouse_sensitivity, -1.2, 0.5)
		_idle_mouse_time = 0.0


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	_idle_mouse_time += delta
	# Right stick look.
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.15:
		yaw -= stick.x * delta * 2.6
		pitch = clampf(pitch - stick.y * delta * 1.8, -1.2, 0.5)
		_idle_mouse_time = 0.0
	# Field of view opens up with speed for a sense of pace.
	var speed := 0.0
	if target is RigidBody3D:
		speed = target.linear_velocity.length()
	elif target is CharacterBody3D:
		speed = target.velocity.length()
	var fov_target := 70.0 + clampf(speed / 30.0, 0.0, 1.0) * 14.0
	_camera.fov = lerpf(_camera.fov, fov_target, clampf(delta * 3.0, 0.0, 1.0))
	if auto_align and _idle_mouse_time > 1.0 and target is RigidBody3D:
		var vel: Vector3 = target.linear_velocity
		if Vector2(vel.x, vel.z).length() > 2.0:
			var behind := atan2(vel.x, vel.z) + PI
			yaw = lerp_angle(yaw, behind, clampf(delta * 2.0, 0.0, 1.0))
	global_position = global_position.lerp(target.global_position + Vector3.UP * height, clampf(delta * 12.0, 0.0, 1.0))
	rotation = Vector3(pitch, yaw, 0.0)


## Horizontal basis used to make WASD camera-relative.
func flat_basis() -> Basis:
	return Basis(Vector3.UP, yaw)
