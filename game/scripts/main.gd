extends Node3D
## Boots the game: input map, lighting, OSM map, player, car, HUD.
##
## Map selection, first match wins:
##   1. command line:  godot --path game -- --map=/abs/path/to/area.osm
##   2. `map_path` export on this node
##   3. res://maps/neighborhood.osm if present (what tools/fetch_osm.py writes)
##   4. any other .osm in res://maps/ (alphabetical), e.g. from fetch_overture.py
##   5. res://maps/sample.osm (synthetic grid that ships with the repo)
## A <map>.height file next to the .osm adds terrain.

const OsmData := preload("res://scripts/osm_data.gd")
const MapBuilder := preload("res://scripts/map_builder.gd")
const PlayerScript := preload("res://scripts/player.gd")
const CarScript := preload("res://scripts/car.gd")
const CameraRig := preload("res://scripts/camera_rig.gd")
const Terrain := preload("res://scripts/terrain.gd")
const PropsBuilder := preload("res://scripts/props_builder.gd")
const Pedestrians := preload("res://scripts/pedestrians.gd")
const Traffic := preload("res://scripts/traffic.gd")
const CarMesh := preload("res://scripts/car_mesh.gd")
const Daylight := preload("res://scripts/daylight.gd")
const Minimap := preload("res://scripts/minimap.gd")
const Hud := preload("res://scripts/hud.gd")
const GameAudio := preload("res://scripts/audio.gd")
const Ortho := preload("res://scripts/ortho.gd")

const DEFAULT_MAPS := ["res://maps/neighborhood.osm", "res://maps/sample.osm"]
const ENTER_DISTANCE := 4.0

@export_file("*.osm") var map_path := ""

var player: CharacterBody3D
var car: VehicleBody3D
var rig: Node3D
var hud: Label  # the hint lines (kept for tools); the overlay is `overlay`
var overlay: CanvasLayer
var audio: Node
var in_car := false
var map_bounds := Rect2()
var terrain: Terrain = null
var spawn_point := Vector3.ZERO
var _builder: MapBuilder
var pedestrians: Node3D = null
var traffic: Node3D = null
var daylight: Node = null
var minimap: CanvasLayer = null
## Clock at start, hours (0-24). [ and ] shift it by an hour in play.
@export var start_hour := 10.0
## AI cars on the roads (0 to disable).
@export var traffic_count := 24
## Walkers on the footpaths (0 to disable).
@export var pedestrian_count := 40
@export var player_look_seed := 1


func _ready() -> void:
	_setup_input()
	_setup_environment()

	var path := _resolve_map_path()
	var data := OsmData.new()
	var builder := MapBuilder.new()
	_builder = builder
	var err := data.parse_file(path) if path != "" else ERR_FILE_NOT_FOUND
	if err == OK:
		var height_path := path.get_basename() + ".height"
		if FileAccess.file_exists(height_path):
			terrain = Terrain.new()
			if terrain.load_file(height_path, data) != OK:
				push_warning("Ignoring unreadable terrain %s" % height_path)
				terrain = null
		var ortho := Ortho.new()
		if ortho.load_for(path, data) == OK:
			builder.ortho = ortho
			if terrain != null:
				terrain.ortho = ortho
			print("Aerial photo %dx%d px" % [ortho.width, ortho.height])
		var t0 := Time.get_ticks_msec()
		add_child(builder.build(data, terrain))
		print("Built map in %d ms%s" % [Time.get_ticks_msec() - t0,
			" (terrain %dx%d, base %.0f m)" % [terrain.cols, terrain.rows, terrain.base_elevation] if terrain else ""])
		t0 = Time.get_ticks_msec()
		# Keep the spawn clear of parked cars and trees.
		builder.occupancy.mark_disc(builder.spawn_position.x, builder.spawn_position.z, 9.0, builder.Occupancy.PROP)
		var props := PropsBuilder.new()
		add_child(props.build(builder, ground_height, hash(path)))
		print("Props in %d ms: %s" % [Time.get_ticks_msec() - t0, props.stats])
		var heads := PackedVector3Array()
		for xf in props.instances.get("light", []):
			heads.append((xf as Transform3D) * Vector3(0, 6.6, -1.7))
		daylight.set_lamp_positions(heads)
		daylight.add_night_material(props.lamp_material)
		daylight.add_night_material(builder.window_material)
		daylight.add_night_material(CarMesh.headlight_material)
		daylight.add_night_material(CarMesh.taillight_material)
		if pedestrian_count > 0:
			pedestrians = Pedestrians.new()
			pedestrians.name = "Pedestrians"
			pedestrians.setup(builder.road_list, ground_height, pedestrian_count, hash(path))
			add_child(pedestrians)
		if traffic_count > 0:
			traffic = Traffic.new()
			traffic.name = "Traffic"
			traffic.setup(builder.road_list, ground_height, traffic_count, hash(path) + 1)
			add_child(traffic)
			traffic.set_night(daylight.is_night)
		if pedestrians != null:
			pedestrians.set_threats([traffic] if traffic != null else [])
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
	car.driver_look_seed = player_look_seed
	add_child(car)
	car.global_transform = Transform3D(Basis(Vector3.UP, builder.spawn_yaw), builder.spawn_position + Vector3.UP * 0.6)

	player = PlayerScript.new()
	player.name = "Player"
	player.look_seed = player_look_seed
	player.camera_rig = rig
	add_child(player)
	# Stand on the kerb beside the car.
	var side := Basis(Vector3.UP, builder.spawn_yaw) * Vector3(-3.0, 0.0, 0.0)
	spawn_point = builder.spawn_position + side
	spawn_point.y = ground_height(spawn_point.x, spawn_point.z) + 0.1
	player.global_position = spawn_point

	rig.set_target(player, 4.5, 1.6, false)
	rig.yaw = builder.spawn_yaw
	_register_player_car()
	_build_hud()
	audio = GameAudio.new()
	audio.name = "Audio"
	add_child(audio)
	if map_bounds.size.x > 0.0:
		minimap = Minimap.new()
		minimap.name = "Minimap"
		add_child(minimap)
		minimap.setup(_builder, map_bounds, player, traffic, pedestrians)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func ground_height(x: float, z: float) -> float:
	return terrain.height_at(x, z) if terrain != null else 0.0


func _resolve_map_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			return arg.trim_prefix("--map=")
	if map_path != "":
		return map_path
	if FileAccess.file_exists(DEFAULT_MAPS[0]):
		return DEFAULT_MAPS[0]
	var found := PackedStringArray()
	for f in DirAccess.get_files_at("res://maps"):
		if f.get_extension() == "osm" and "res://maps/" + f != DEFAULT_MAPS[1]:
			found.append("res://maps/" + f)
	found.sort()
	if not found.is_empty():
		return found[0]
	return DEFAULT_MAPS[1] if FileAccess.file_exists(DEFAULT_MAPS[1]) else ""


func _setup_input() -> void:
	var bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sprint": [KEY_SHIFT],
		"walk": [KEY_CTRL, KEY_ALT],
		"interact": [KEY_E, KEY_F],
		"reset_vehicle": [KEY_R],
		"toggle_map": [KEY_M],
		"toggle_mouse": [KEY_ESCAPE],
		"time_back": [KEY_BRACKETLEFT],
		"time_forward": [KEY_BRACKETRIGHT],
		"horn": [KEY_H],
	}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in bindings[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


func _setup_environment() -> void:
	daylight = Daylight.new()
	daylight.name = "Daylight"
	daylight.hour = start_hour
	add_child(daylight)
	daylight.setup(self)
	daylight.night_changed.connect(func(night: bool) -> void:
		if car != null:
			car.set_headlights(night)
		if traffic != null:
			traffic.set_night(night))


func _build_hud() -> void:
	overlay = Hud.new()
	overlay.name = "HUD"
	add_child(overlay)
	hud = overlay.hints


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE \
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and not (minimap != null and minimap.full_open):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact"):
		if in_car:
			exit_car()
		elif player.global_position.distance_to(car.global_position) < ENTER_DISTANCE:
			enter_car()
	elif event.is_action_pressed("toggle_map") and minimap != null:
		minimap.toggle_full()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if minimap.full_open else Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("time_forward"):
		daylight.hour = fmod(daylight.hour + 1.0, 24.0)
	elif event.is_action_pressed("time_back"):
		daylight.hour = fmod(daylight.hour + 23.0, 24.0)
	elif event.is_action_pressed("reset_vehicle") and in_car:
		car.reset_upright(car.global_position)


func enter_car() -> void:
	in_car = true
	player.set_active(false)
	car.set_driving(true)
	rig.set_target(car, 7.5, 2.0, true)


func exit_car() -> void:
	if car.forward_speed() > 6.0:
		return  # no bailing out at speed
	in_car = false
	car.set_driving(false)
	var side := car.global_basis * Vector3(-2.2, 0.0, 0.0)
	player.global_position = Vector3(car.global_position.x + side.x, car.global_position.y + 0.5, car.global_position.z + side.z)
	player.set_active(true)
	rig.set_target(player, 4.5, 1.6, false)


func _register_player_car() -> void:
	if pedestrians != null:
		var threats: Array = [car]
		if traffic != null:
			threats.append(traffic)
		pedestrians.set_threats(threats)


func _process(delta: float) -> void:
	# Safety net: anything that falls out of the world comes back to spawn.
	if car.global_position.y < -50.0:
		car.reset_upright(spawn_point + Vector3.UP * 2.0)
	if player.global_position.y < -50.0:
		player.global_position = spawn_point + Vector3.UP
		player.velocity = Vector3.ZERO
	if hud == null:
		return
	var p := car.global_position if in_car else player.global_position
	if pedestrians != null:
		pedestrians.set_focus(p)
	if traffic != null:
		traffic.set_focus(p)
		for d in traffic.take_honks():
			audio.ai_honk(d)
	if in_car and Input.is_action_just_pressed("horn") and pedestrians != null:
		pedestrians.honk(car.global_position)
	daylight.set_focus(p)
	var state := {
		"clock": daylight.clock_text(),
		"driving": in_car,
		"speed_ms": car.forward_speed() if in_car else 0.0,
		"street": minimap.nearest_street(Vector2(p.x, p.z)) if minimap != null else "",
		"gps_m": minimap.gps_distance() if minimap != null else -1.0,
	}
	if in_car:
		state["hints"] = "W/S throttle/brake   A/D steer   Space handbrake   R reset   E exit   M map"
		state["prompt"] = ""
	else:
		state["hints"] = "WASD move   Shift sprint   Ctrl walk   Space jump   Mouse look   M map   Esc release mouse"
		state["prompt"] = "Press E to drive" if p.distance_to(car.global_position) < ENTER_DISTANCE else ""
	overlay.update(delta, state)
	audio.state = {
		"driving": in_car,
		"speed": absf(car.forward_speed()) if in_car else Vector2(player.velocity.x, player.velocity.z).length(),
		"throttle": absf(Input.get_axis("move_back", "move_forward")) if in_car else 0.0,
		"handbrake": in_car and Input.is_action_pressed("jump"),
		"foot_speed": Vector2(player.velocity.x, player.velocity.z).length() if not in_car else 0.0,
		"grounded": player.is_on_floor(),
		"night": daylight.is_night,
		"horn": in_car and Input.is_action_pressed("horn"),
	}
