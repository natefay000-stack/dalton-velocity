extends CanvasLayer
## Esc pauses the game with a simple menu: resume, controls, time of day,
## quit. Runs while the tree is paused.

signal resumed
signal time_chosen(hour: float)

var open := false
var _root: Control
var _controls: Label


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	_root.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	_button(box, "Resume", func() -> void: close())
	var times := HBoxContainer.new()
	times.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(times)
	for t in [["Dawn", 6.5], ["Noon", 12.0], ["Dusk", 19.5], ["Night", 23.0]]:
		var b := Button.new()
		b.text = t[0]
		b.pressed.connect(func() -> void: time_chosen.emit(t[1]))
		times.add_child(b)
	_controls = Label.new()
	_controls.add_theme_font_size_override("font_size", 13)
	_controls.text = "\n".join([
		"On foot:  WASD / left stick move,  Shift sprint,  Ctrl walk,  Space / A jump",
		"Car:  W/S / triggers throttle & brake,  A/D / left stick steer,",
		"      Space / A handbrake,  H / Y horn,  R reset",
		"E / X  get in or out of the car         M / Back  map (click sets a waypoint)",
		"Mouse / right stick  look                 [ ]  time of day",
		"Esc / Start  this menu",
	])
	box.add_child(_controls)
	_button(box, "Quit", func() -> void: get_tree().quit())


func _button(parent: Node, text: String, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(200, 36)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(on_press)
	parent.add_child(b)


func toggle() -> void:
	if open:
		close()
	else:
		show_menu()


func show_menu() -> void:
	open = true
	_root.visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	open = false
	_root.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()
