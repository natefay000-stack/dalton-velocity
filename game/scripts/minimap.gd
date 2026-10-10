extends CanvasLayer
## Corner minimap and full-screen map (M). The map image is rendered once
## from the builder's road, building and area lists into a texture; the
## minimap shows a north-up crop around the player with a heading arrow and
## the name of the nearest street. Traffic and pedestrians appear as dots.

const MapBuilder := preload("res://scripts/map_builder.gd")

const MINI_SIZE := 230.0
const MINI_RADIUS_M := 140.0  # metres from player to the minimap edge
const MARGIN := 16.0
const PX_PER_M := 1.5
const MAX_TEXTURE := 4096

const C_GROUND := Color(0.80, 0.78, 0.70)
const C_LAWN := Color(0.70, 0.78, 0.58)
const C_PARK := Color(0.60, 0.76, 0.50)
const C_WATER := Color(0.45, 0.62, 0.80)
const C_BUILDING := Color(0.62, 0.58, 0.52)
const C_ROAD := Color(1.0, 1.0, 1.0)
const C_MAIN_ROAD := Color(1.0, 0.92, 0.65)
const C_PATH := Color(0.90, 0.88, 0.82)
const C_PLAYER := Color(0.10, 0.45, 0.95)
const C_TRAFFIC := Color(0.85, 0.15, 0.15)
const C_PED := Color(0.95, 0.65, 0.10)

var bounds := Rect2()
var texture: Texture2D
var scale_px := PX_PER_M
var full_open := false

var _roads: Array[Dictionary] = []
var _player: Node3D
var _traffic: Node3D
var _pedestrians: Node3D
var _mini: Control
var _full: Control
var _street_label: Label
var _street_timer := 0.0
var _street := ""


func setup(builder: MapBuilder, map_bounds: Rect2, player: Node3D, traffic: Node3D, pedestrians: Node3D) -> void:
	bounds = map_bounds
	_roads = builder.road_list
	_player = player
	_traffic = traffic
	_pedestrians = pedestrians
	layer = 5
	_render_map(builder)

	_mini = Control.new()
	_mini.name = "Minimap"
	_mini.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_mini.position = Vector2(-MINI_SIZE - MARGIN, MARGIN)
	_mini.size = Vector2(MINI_SIZE, MINI_SIZE + 26.0)
	_mini.draw.connect(_draw_mini)
	add_child(_mini)
	_street_label = Label.new()
	_street_label.position = Vector2(0, MINI_SIZE + 4.0)
	_street_label.size = Vector2(MINI_SIZE, 22.0)
	_street_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_street_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_street_label.add_theme_constant_override("shadow_offset_x", 1)
	_street_label.add_theme_constant_override("shadow_offset_y", 1)
	_mini.add_child(_street_label)

	_full = Control.new()
	_full.name = "FullMap"
	_full.set_anchors_preset(Control.PRESET_FULL_RECT)
	_full.visible = false
	_full.draw.connect(_draw_full)
	add_child(_full)


func toggle_full() -> void:
	full_open = not full_open
	_full.visible = full_open
	_mini.visible = not full_open


func _process(delta: float) -> void:
	if _player == null:
		return
	_mini.queue_redraw()
	if full_open:
		_full.queue_redraw()
	_street_timer -= delta
	if _street_timer <= 0.0:
		_street_timer = 0.5
		_street = nearest_street(Vector2(_player.global_position.x, _player.global_position.z))
		_street_label.text = _street


## World (x, z) -> pixel in the map texture.
func to_px(p: Vector2) -> Vector2:
	return (p - bounds.position) * scale_px


## Name of the closest named road within 40 m, else "".
func nearest_street(p: Vector2) -> String:
	var best := 40.0 * 40.0
	var name := ""
	for r in _roads:
		if r["name"] == "":
			continue
		var pts: PackedVector2Array = r["pts"]
		for i in pts.size() - 1:
			var d := p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1]))
			if d < best:
				best = d
				name = r["name"]
	return name


# --- map texture ------------------------------------------------------------

func _render_map(builder: MapBuilder) -> void:
	var size_m := bounds.size
	scale_px = minf(PX_PER_M, MAX_TEXTURE / maxf(size_m.x, size_m.y))
	var size := Vector2i(int(size_m.x * scale_px), int(size_m.y * scale_px))
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var canvas := Node2D.new()
	canvas.draw.connect(func() -> void: _draw_world(canvas, builder))
	vp.add_child(canvas)
	add_child(vp)
	texture = vp.get_texture()


func _draw_world(c: Node2D, builder: MapBuilder) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, bounds.size * scale_px), C_GROUND)
	# With an aerial photo, it is the map: only roads go on top of it.
	if builder.ortho != null:
		var o = builder.ortho
		c.draw_texture_rect(o.texture, Rect2(to_px(o.rect.position), o.rect.size * scale_px), false)
		_draw_roads(c, builder)
		return
	for a in builder.area_list:
		var ring: PackedVector2Array = a["ring"]
		if ring.size() < 3:
			continue
		var kind: String = a["kind"]
		var col := C_LAWN if kind.begins_with("landuse=residential") else C_PARK
		var poly := PackedVector2Array()
		for p in ring:
			poly.append(to_px(p))
		var idx := Geometry2D.triangulate_polygon(poly)
		if not idx.is_empty():
			c.draw_polygon(poly, PackedColorArray([col]))
	for w in builder.water_rings:
		var poly := PackedVector2Array()
		for p in w:
			poly.append(to_px(p))
		if Geometry2D.triangulate_polygon(poly).size() > 0:
			c.draw_polygon(poly, PackedColorArray([C_WATER]))
	for b in builder.building_list:
		var poly := PackedVector2Array()
		for p in b["ring"]:
			poly.append(to_px(p))
		if poly.size() >= 3 and Geometry2D.triangulate_polygon(poly).size() > 0:
			c.draw_polygon(poly, PackedColorArray([C_BUILDING]))
	_draw_roads(c, builder)


func _draw_roads(c: Node2D, builder: MapBuilder) -> void:
	for r in builder.road_list:
		var pts: PackedVector2Array = r["pts"]
		if pts.size() < 2:
			continue
		var hw: String = r["highway"]
		var col := C_ROAD
		var width: float = r["width"] * scale_px
		if hw in ["footway", "path", "cycleway", "pedestrian", "steps", "track"]:
			col = C_PATH
			width = maxf(width, 1.0)
		elif hw in ["primary", "secondary", "tertiary"]:
			col = C_MAIN_ROAD
		elif hw == "service":
			col = C_PATH
		var line := PackedVector2Array()
		for p in pts:
			line.append(to_px(p))
		c.draw_polyline(line, col, maxf(width, 1.5), true)


# --- overlays ---------------------------------------------------------------

func _draw_mini() -> void:
	if texture == null:
		return
	var centre := Vector2(MINI_SIZE, MINI_SIZE) * 0.5
	var p := Vector2(_player.global_position.x, _player.global_position.z)
	var px := to_px(p)
	var half_px := MINI_RADIUS_M * scale_px
	var src := Rect2(px - Vector2.ONE * half_px, Vector2.ONE * half_px * 2.0)
	var dst := Rect2(Vector2.ZERO, Vector2(MINI_SIZE, MINI_SIZE))
	_mini.draw_rect(dst, Color(0, 0, 0, 0.55))
	_mini.draw_texture_rect_region(texture, dst, src, Color(1, 1, 1, 0.92))
	var k := MINI_SIZE / (half_px * 2.0)  # texture px -> minimap px
	# Traffic and walkers.
	if _traffic != null:
		for car in _traffic.cars:
			var cp: Vector3 = car["node"].global_position
			var d := (to_px(Vector2(cp.x, cp.z)) - px) * k + centre
			if dst.has_point(d):
				_mini.draw_circle(d, 3.0, C_TRAFFIC)
	if _pedestrians != null:
		for w in _pedestrians.walkers:
			var wp: Vector3 = w["node"].global_position
			var d := (to_px(Vector2(wp.x, wp.z)) - px) * k + centre
			if dst.has_point(d):
				_mini.draw_circle(d, 2.0, C_PED)
	# Player heading arrow (map is north-up; -Z is north).
	var yaw: float = _player.global_rotation.y
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var side := Vector2(-fwd.y, fwd.x)
	var tri := PackedVector2Array([centre + fwd * 9.0, centre - fwd * 6.0 + side * 6.0, centre - fwd * 6.0 - side * 6.0])
	_mini.draw_polygon(tri, PackedColorArray([C_PLAYER]))
	_mini.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color.WHITE, 1.5)
	_mini.draw_rect(dst, Color(1, 1, 1, 0.8), false, 2.0)
	_mini.draw_string(ThemeDB.fallback_font, Vector2(MINI_SIZE * 0.5 - 4, 16), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)


func _draw_full() -> void:
	if texture == null:
		return
	var view := _full.size
	var tex_size := Vector2(texture.get_size())
	var fit := minf((view.x - 80.0) / tex_size.x, (view.y - 80.0) / tex_size.y)
	var dst_size := tex_size * fit
	var origin := (view - dst_size) * 0.5
	_full.draw_rect(Rect2(Vector2.ZERO, view), Color(0, 0, 0, 0.7))
	_full.draw_texture_rect(texture, Rect2(origin, dst_size), false)
	var p := Vector2(_player.global_position.x, _player.global_position.z)
	var d := origin + to_px(p) * fit
	_full.draw_circle(d, 7.0, Color.WHITE)
	_full.draw_circle(d, 5.0, C_PLAYER)
	if _traffic != null:
		for car in _traffic.cars:
			var cp: Vector3 = car["node"].global_position
			_full.draw_circle(origin + to_px(Vector2(cp.x, cp.z)) * fit, 3.0, C_TRAFFIC)
	_full.draw_string(ThemeDB.fallback_font, origin + Vector2(0, dst_size.y + 22), "M to close   %s" % _street, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
