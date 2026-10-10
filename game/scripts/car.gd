extends VehicleBody3D
## Drivable car built from primitives. Uses Godot's raycast vehicle model:
## rear-wheel drive, front-wheel steering.

@export var max_engine_force := 4200.0
@export var max_brake := 60.0
@export var max_steer := 0.55
@export var steer_speed := 3.0
@export var top_speed_kmh := 120.0
@export var body_color := Color(0.62, 0.10, 0.09)
## "sedan", "suv" or "pickup" (see car_mesh.gd).
@export var style := "sedan"
## Appearance of the person shown behind the wheel while driving.
@export var driver_look_seed := 1


func set_driving(on: bool) -> void:
	driving = on
	if driver != null:
		driver.visible = on

const CarMesh := preload("res://scripts/car_mesh.gd")
const Humanoid := preload("res://scripts/humanoid.gd")

var driving := false
var driver: Node3D = null
## Seat position for a driver model (feet on the floor), local space.
var driver_seat := Vector3(-0.38, 0.0, -0.2)


func _ready() -> void:
	mass = 1200.0 if style == "sedan" else 1700.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.35, 0)
	angular_damp = 0.5

	var d := CarMesh.dims(style)
	var shape := BoxShape3D.new()
	shape.size = d["box_size"] - Vector3(0.1, 0.0, 0.1)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = d["box_center"]
	add_child(cs)

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = CarMesh.build_body(style, body_color)
	add_child(body)
	driver_seat = Vector3(-0.38, d["floor"], -0.2)

	driver = Humanoid.new()
	driver.name = "Driver"
	driver.look_seed = driver_look_seed
	driver.build()
	driver.pose_seated()
	# Feet a little under the floor pan so the head clears the roof.
	driver.position = driver_seat + Vector3(0, -0.14, 0.35)
	driver.visible = false
	add_child(driver)

	var wheel_mesh := CarMesh.build_wheel(style)
	var positions := CarMesh.wheel_positions(style)
	for i in positions.size():
		_wheel(positions[i], i < 2, wheel_mesh)


func _wheel(pos: Vector3, front: bool, mesh: ArrayMesh) -> void:
	var w := VehicleWheel3D.new()
	w.position = pos + Vector3(0, 0.12, 0)
	w.use_as_steering = front
	w.use_as_traction = not front
	w.wheel_radius = CarMesh.wheel_radius(style)
	w.wheel_rest_length = 0.12
	w.suspension_travel = 0.2
	w.suspension_stiffness = 40.0
	w.suspension_max_force = 12000.0
	w.damping_compression = 2.0
	w.damping_relaxation = 2.5
	w.wheel_friction_slip = 2.8 if front else 2.5
	w.wheel_roll_influence = 0.15
	add_child(w)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
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



func reset_upright(at: Vector3) -> void:
	var yaw := global_rotation.y
	global_transform = Transform3D(Basis(Vector3.UP, yaw), at + Vector3.UP * 1.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
