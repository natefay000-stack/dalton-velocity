extends Node
## Time of day: drives the sun, sky, ambient light and fog, and switches the
## night lighting (street lamps, house windows, headlights) on at dusk.
##
## A pool of real OmniLight3Ds is parked on the street lamps nearest the
## player, so a map with hundreds of lamps costs a couple of dozen lights.

signal night_changed(is_night: bool)

## Game hours per real second (default: a full day in 24 minutes).
@export var speed := 1.0 / 60.0
## Clock in hours, 0..24.
@export var hour := 10.0
@export var lamp_pool_size := 24
@export var lamp_range := 22.0

const DAWN := 6.0
const DUSK := 19.0

var sun: DirectionalLight3D
var environment: Environment
var sky: ProceduralSkyMaterial
var is_night := false
var _lamps: Array[OmniLight3D] = []
var _lamp_positions: PackedVector3Array = PackedVector3Array()
var _focus := Vector3.ZERO
var _refresh := 0.0
var _night_materials: Array[StandardMaterial3D] = []


func setup(parent: Node3D) -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	parent.add_child(sun)

	sky = ProceduralSkyMaterial.new()
	var sky_res := Sky.new()
	sky_res.sky_material = sky
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky_res
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true
	environment.fog_density = 0.00035
	environment.glow_enabled = true
	environment.glow_intensity = 0.4
	environment.glow_bloom = 0.1
	var we := WorldEnvironment.new()
	we.environment = environment
	parent.add_child(we)

	for i in lamp_pool_size:
		var l := OmniLight3D.new()
		l.omni_range = lamp_range
		l.light_color = Color(1.0, 0.88, 0.65)
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		parent.add_child(l)
		_lamps.append(l)
	apply()


## World positions of the lamp heads (from the props builder).
func set_lamp_positions(positions: PackedVector3Array) -> void:
	_lamp_positions = positions
	_refresh = 0.0


## Materials whose emission should come on at night (windows, lamp heads).
func add_night_material(m: StandardMaterial3D) -> void:
	_night_materials.append(m)


func set_focus(p: Vector3) -> void:
	_focus = p


func _process(delta: float) -> void:
	hour = fmod(hour + delta * speed, 24.0)
	apply()
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = 0.5
		_place_lamps()


## Sun height above the horizon, -1..1 (0 at 06:00 and 18:00, 1 at noon).
func elevation() -> float:
	return sin((hour - 6.0) / 12.0 * PI)


## Light level 0 (night) .. 1 (full day); lingers a little past sunset.
func daylight() -> float:
	return clampf(elevation() * 1.1 + 0.1, 0.0, 1.0)


func apply() -> void:
	var day := daylight()
	var elev := elevation()
	var dusk := clampf(elev / 0.25, 0.0, 1.0)   # sun strength ramps up after rising
	var warmth := clampf(elev / 0.45, 0.0, 1.0)  # golden while low
	# Sun path: rises in the east (+X), sets in the west.
	var angle := (hour - 6.0) / 12.0 * PI  # 0 at 06:00, PI at 18:00
	sun.rotation = Vector3(-sin(angle) * deg_to_rad(65.0) - deg_to_rad(5.0), deg_to_rad(90.0) - angle, 0.0)
	var warm := Color(1.0, 0.72, 0.45)
	var noon := Color(1.0, 0.97, 0.92)
	sun.light_color = warm.lerp(noon, warmth)
	sun.light_energy = lerpf(0.0, 1.25, dusk)
	sun.visible = dusk > 0.01

	var top_night := Color(0.02, 0.03, 0.07)
	var top_day := Color(0.35, 0.55, 0.85)
	var hor_night := Color(0.08, 0.08, 0.14)
	var hor_dusk := Color(0.95, 0.55, 0.30)
	var hor_day := Color(0.75, 0.82, 0.9)
	var horizon := hor_night.lerp(hor_dusk, clampf(day * 3.0, 0.0, 1.0)).lerp(hor_day, warmth)
	sky.sky_top_color = top_night.lerp(top_day, day)
	sky.sky_horizon_color = horizon
	sky.ground_horizon_color = horizon
	sky.ground_bottom_color = Color(0.1, 0.1, 0.1).lerp(Color(0.55, 0.52, 0.42), dusk)
	sky.sun_angle_max = 30.0
	sky.sun_curve = 0.15
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = lerpf(0.12, 1.0, day)
	environment.fog_light_color = horizon.darkened(0.1 * (1.0 - day))

	var night_now := day < 0.2
	if night_now != is_night:
		is_night = night_now
		for m in _night_materials:
			m.emission_energy_multiplier = 1.6 if is_night else 0.0
		for l in _lamps:
			l.visible = is_night
			l.light_energy = 2.6 if is_night else 0.0
		night_changed.emit(is_night)


func _place_lamps() -> void:
	if not is_night or _lamp_positions.is_empty():
		return
	# Nearest lamps to the focus get the pool.
	var order: Array = []
	for i in _lamp_positions.size():
		var d := _lamp_positions[i].distance_squared_to(_focus)
		if d < 250.0 * 250.0:
			order.append([d, i])
	order.sort_custom(func(a, b): return a[0] < b[0])
	for k in _lamps.size():
		if k < order.size():
			_lamps[k].global_position = _lamp_positions[order[k][1]]
			_lamps[k].visible = true
		else:
			_lamps[k].visible = false


func clock_text() -> String:
	return "%02d:%02d" % [int(hour), int(fmod(hour, 1.0) * 60.0)]
