extends VehicleBody3D
## Drivable car built from primitives. Uses Godot's raycast vehicle model:
## rear-wheel drive, front-wheel steering.

@export var max_engine_force := 4200.0
@export var max_brake := 60.0
@export var max_steer := 0.55
@export var steer_speed := 3.0
@export var top_speed_kmh := 120.0
@export var body_color := Color(0.80, 0.12, 0.10)

var driving := false


func _ready() -> void:
	mass = 1200.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.35, 0)
	angular_damp = 0.5

	var shape := BoxShape3D.new()
	shape.size = Vector3(1.8, 0.7, 4.2)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = 0.75
	add_child(cs)

	var paint := StandardMaterial3D.new()
	paint.albedo_color = body_color
	paint.metallic = 0.3
	paint.roughness = 0.35
	_box(Vector3(1.8, 0.6, 4.2), Vector3(0, 0.75, 0), paint)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.12, 0.15, 0.2)
	glass.roughness = 0.1
	_box(Vector3(1.6, 0.55, 2.1), Vector3(0, 1.3, 0.2), glass)
	var light := StandardMaterial3D.new()
	light.albedo_color = Color(1, 1, 0.85)
	light.emission_enabled = true
	light.emission = Color(1, 1, 0.8)
	_box(Vector3(0.35, 0.15, 0.05), Vector3(-0.6, 0.85, -2.11), light)
	_box(Vector3(0.35, 0.15, 0.05), Vector3(0.6, 0.85, -2.11), light)

	# Forward is -Z: front wheels at negative Z.
	_wheel(Vector3(-0.85, 0.45, -1.35), true)
	_wheel(Vector3(0.85, 0.45, -1.35), true)
	_wheel(Vector3(-0.85, 0.45, 1.35), false)
	_wheel(Vector3(0.85, 0.45, 1.35), false)


func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var m := BoxMesh.new()
	m.size = size
	m.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.position = pos
	add_child(mi)


func _wheel(pos: Vector3, front: bool) -> void:
	var w := VehicleWheel3D.new()
	w.position = pos
	w.use_as_steering = front
	w.use_as_traction = not front
	w.wheel_radius = 0.38
	w.wheel_rest_length = 0.15
	w.suspension_travel = 0.2
	w.suspension_stiffness = 40.0
	w.suspension_max_force = 12000.0
	w.damping_compression = 2.0
	w.damping_relaxation = 2.5
	w.wheel_friction_slip = 2.8 if front else 2.5
	w.wheel_roll_influence = 0.15
	add_child(w)

	var tire := CylinderMesh.new()
	tire.top_radius = 0.38
	tire.bottom_radius = 0.38
	tire.height = 0.25
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.08)
	tire.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = tire
	mi.rotation.z = PI / 2.0
	w.add_child(mi)


## Signed speed along the car's forward axis, m/s.
func forward_speed() -> float:
	return linear_velocity.dot(-global_basis.z)


func _physics_process(delta: float) -> void:
	var throttle := 0.0
	var steer_input := 0.0
	var handbrake := false
	if driving:
		throttle = Input.get_axis("move_back", "move_forward")
		steer_input = Input.get_axis("move_right", "move_left")
		handbrake = Input.is_action_pressed("jump")

	var v := forward_speed()
	var force := 0.0
	var brake_force := 0.0
	if throttle > 0.0:
		if v < -0.5:
			brake_force = max_brake * throttle
		elif v * 3.6 < top_speed_kmh:
			force = max_engine_force * throttle
	elif throttle < 0.0:
		if v > 0.5:
			brake_force = max_brake * -throttle
		elif v * 3.6 > -25.0:
			force = max_engine_force * 0.5 * throttle
	elif not driving:
		brake_force = max_brake * 0.5
	if handbrake:
		brake_force = max_brake * 2.0

	# Steering eases off at speed so highway lane changes aren't twitchy.
	var speed_factor := clampf(1.0 - absf(v) / 50.0, 0.35, 1.0)
	steering = move_toward(steering, steer_input * max_steer * speed_factor, steer_speed * delta)
	# VehicleBody3D drives along its local +Z; this car's nose is -Z.
	engine_force = -force
	brake = brake_force

	if global_position.y < -50.0:
		reset_upright(global_position + Vector3.UP * 60.0)


func reset_upright(at: Vector3) -> void:
	var yaw := global_rotation.y
	global_transform = Transform3D(Basis(Vector3.UP, yaw), at + Vector3.UP * 1.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
