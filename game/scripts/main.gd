extends Node3D
## Boots the game: input map, lighting, OSM map, player, car, HUD.
##
## Map selection, first match wins:
##   1. command line:  godot --path game -- --map=/abs/path/to/area.osm
##   2. `map_path` export on this node
##   3. res://maps/neighborhood.osm if present (what tools/fetch_osm.py writes)
##   4. res://maps/sample.osm (synthetic grid that ships with the repo)

const OsmData := preload("res://scripts/osm_data.gd")
const MapBuilder := preload("res://scripts/map_builder.gd")
const PlayerScript := preload("res://scripts/player.gd")
const CarScript := preload("res://scripts/car.gd")
const CameraRig := preload("res://scripts/camera_rig.gd")

const DEFAULT_MAPS := ["res://maps/neighborhood.osm", "res://maps/sample.osm"]
const ENTER_DISTANCE := 4.0

@export_file("*.osm") var map_path := ""

var player: CharacterBody3D
var car: VehicleBody3D
var rig: Node3D
var hud: Label
var in_car := false
var map_bounds := Rect2()


func _ready() -> void:
	_setup_input()
	_setup_environment()

	var path := _resolve_map_path()
	var data := OsmData.new()
	var builder := MapBuilder.new()
	var err := data.parse_file(path) if path != "" else ERR_FILE_NOT_FOUND
	if err == OK:
		add_child(builder.build(data))
		map_bounds = data.bounds
		print("Loaded %s: %d roads, %d buildings, %d areas (%d skipped)" % [
			path, builder.stats["roads"], builder.stats["buildings"],
			builder.stats["areas"], builder.stats["skipped"]])
	else:
		push_warning("No usable map (%s). Spawning on an empty plane." % path)
		add_child(builder.make_ground(Rect2(-200, -200, 400, 400)))

	rig = CameraRig.new()
	rig.name = "CameraRig"
	add_child(rig)

	car = CarScript.new()
	car.name = "Car"
	add_child(car)
	car.global_transform = Transform3D(Basis(Vector3.UP, builder.spawn_yaw), builder.spawn_position + Vector3.UP * 0.6)

	player = PlayerScript.new()
	player.name = "Player"
	player.camera_rig = rig
	add_child(player)
	# Stand on the kerb beside the car.
	var side := Basis(Vector3.UP, builder.spawn_yaw) * Vector3(-3.0, 0.0, 0.0)
	player.global_position = builder.spawn_position + side + Vector3.UP * 0.1

	rig.set_target(player, 4.5, 1.6, false)
	rig.yaw = builder.spawn_yaw
	_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _resolve_map_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			return arg.trim_prefix("--map=")
	if map_path != "":
		return map_path
	for p in DEFAULT_MAPS:
		if FileAccess.file_exists(p):
			return p
	return ""


func _setup_input() -> void:
	var bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sprint": [KEY_SHIFT],
		"interact": [KEY_E, KEY_F],
		"reset_vehicle": [KEY_R],
		"toggle_mouse": [KEY_ESCAPE],
	}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in bindings[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.75, 0.82, 0.9)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.75, 0.82, 0.9)
	env.fog_density = 0.0015
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	hud.add_theme_constant_override("shadow_offset_x", 1)
	hud.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(hud)

	var credit := Label.new()
	credit.text = "Map data © OpenStreetMap contributors (ODbL)"
	credit.anchor_left = 1.0
	credit.anchor_right = 1.0
	credit.anchor_top = 1.0
	credit.anchor_bottom = 1.0
	credit.offset_left = -360
	credit.offset_top = -28
	credit.add_theme_font_size_override("font_size", 12)
	layer.add_child(credit)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE \
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact"):
		if in_car:
			exit_car()
		elif player.global_position.distance_to(car.global_position) < ENTER_DISTANCE:
			enter_car()
	elif event.is_action_pressed("reset_vehicle") and in_car:
		car.reset_upright(car.global_position)


func enter_car() -> void:
	in_car = true
	player.set_active(false)
	car.driving = true
	rig.set_target(car, 7.5, 2.0, true)


func exit_car() -> void:
	if car.forward_speed() > 6.0:
		return  # no bailing out at speed
	in_car = false
	car.driving = false
	var side := car.global_basis * Vector3(-2.2, 0.0, 0.0)
	player.global_position = Vector3(car.global_position.x + side.x, car.global_position.y + 0.5, car.global_position.z + side.z)
	player.set_active(true)
	rig.set_target(player, 4.5, 1.6, false)


func _process(_delta: float) -> void:
	if hud == null:
		return
	var p := car.global_position if in_car else player.global_position
	var lines := PackedStringArray()
	if in_car:
		lines.append("%d km/h" % roundi(absf(car.forward_speed()) * 3.6))
		lines.append("W/S throttle/brake  A/D steer  Space handbrake  R reset  E exit")
	else:
		lines.append("WASD move  Shift sprint  Space jump  Mouse look  Esc release mouse")
		if p.distance_to(car.global_position) < ENTER_DISTANCE:
			lines.append("Press E to drive")
	lines.append("pos %.0f, %.0f" % [p.x, p.z])
	hud.text = "\n".join(lines)
