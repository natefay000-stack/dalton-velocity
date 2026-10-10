extends CanvasLayer
## In-game overlay: control hints that fade once you know them, a street
## name banner when you turn onto a new street, a speedometer while
## driving, the clock, a "Press E" prompt and the GPS distance.

var hints: Label
var prompt: Label
var banner: Label
var speedo: Label
var speedo_unit: Label
var clock: Label
var gps: Label

var _banner_time := 0.0
var _hints_time := 0.0
var _last_street := ""
var _last_hints := ""

const BANNER_HOLD := 3.5
const HINTS_HOLD := 9.0


func _ready() -> void:
	layer = 6
	hints = _label(Vector2(16, 12), 15, HORIZONTAL_ALIGNMENT_LEFT)
	hints.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clock = _label(Vector2(0, 10), 18, HORIZONTAL_ALIGNMENT_CENTER)
	clock.set_anchors_preset(Control.PRESET_CENTER_TOP)
	clock.offset_left = -60
	clock.offset_right = 60
	clock.offset_top = 10
	prompt = _label(Vector2.ZERO, 22, HORIZONTAL_ALIGNMENT_CENTER)
	prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.offset_left = -200
	prompt.offset_right = 200
	prompt.offset_top = -120
	banner = _label(Vector2.ZERO, 34, HORIZONTAL_ALIGNMENT_LEFT)
	banner.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	banner.offset_left = 24
	banner.offset_top = -78
	banner.offset_right = 600
	banner.modulate.a = 0.0
	speedo = _label(Vector2.ZERO, 44, HORIZONTAL_ALIGNMENT_RIGHT)
	speedo.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	speedo.offset_left = -220
	speedo.offset_right = -70
	speedo.offset_top = -96
	speedo.visible = false
	speedo_unit = _label(Vector2.ZERO, 14, HORIZONTAL_ALIGNMENT_LEFT)
	speedo_unit.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	speedo_unit.offset_left = -64
	speedo_unit.offset_right = -10
	speedo_unit.offset_top = -72
	speedo_unit.text = "km/h"
	speedo_unit.visible = false
	gps = _label(Vector2.ZERO, 14, HORIZONTAL_ALIGNMENT_CENTER)
	gps.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	gps.offset_left = -246
	gps.offset_right = -16
	gps.offset_top = 272
	var credit := _label(Vector2.ZERO, 12, HORIZONTAL_ALIGNMENT_RIGHT)
	credit.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	credit.offset_left = -360
	credit.offset_right = -8
	credit.offset_top = -24
	credit.text = "Map data © OpenStreetMap contributors (ODbL)"
	credit.modulate.a = 0.7


func _label(pos: Vector2, size: int, align: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.horizontal_alignment = align
	add_child(l)
	return l


## Called every frame by main with the current state.
func update(delta: float, state: Dictionary) -> void:
	# Hints: shown on any change of mode, then fade out.
	var h: String = state.get("hints", "")
	if h != _last_hints:
		_last_hints = h
		_hints_time = 0.0
		hints.text = h
	_hints_time += delta
	hints.modulate.a = clampf(1.0 - (_hints_time - HINTS_HOLD) / 1.5, 0.0, 1.0)

	prompt.text = state.get("prompt", "")
	clock.text = state.get("clock", "")

	var street: String = state.get("street", "")
	if street != _last_street:
		_last_street = street
		if street != "":
			banner.text = street
			_banner_time = 0.0
	_banner_time += delta
	var fade_in := clampf(_banner_time / 0.35, 0.0, 1.0)
	var fade_out := clampf(1.0 - (_banner_time - BANNER_HOLD) / 1.0, 0.0, 1.0)
	banner.modulate.a = minf(fade_in, fade_out)

	var driving: bool = state.get("driving", false)
	speedo.visible = driving
	speedo_unit.visible = driving
	if driving:
		speedo.text = "%d" % roundi(absf(state.get("speed_ms", 0.0)) * 3.6)

	var dist: float = state.get("gps_m", -1.0)
	if dist < 0.0:
		gps.text = ""
	elif dist >= 1000.0:
		gps.text = "⟶ %.1f km" % (dist / 1000.0)
	else:
		gps.text = "⟶ %d m" % roundi(dist)
