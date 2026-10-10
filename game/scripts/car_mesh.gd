extends RefCounted
## Builds low-poly car meshes by sweeping a chamfered cross-section along a
## side profile: bumper, hood, windshield, roof, rear glass, trunk. Three
## body styles. Surface 0 is painted bodywork, surface 1 lights and trim,
## surface 2 tinted see-through glass, so one mesh works both as the
## drivable car (driver visible inside) and as MultiMesh parked cars. The
## nose points -Z; the origin is on the ground under the centre.

## Station: [z, floor y, belt y, top y, half width, segment kind]. The kind
## describes the panel between this station and the next: "body", "bumper",
## "ws" (glass top and sides), "cabin" (glass sides, solid roof), "bed"
## (open pickup bed: no top).
const PROFILES := {
	"sedan": [
		[-2.30, 0.36, 0.58, 0.64, 0.84, "bumper"],
		[-2.15, 0.28, 0.76, 0.80, 0.90, "body"],
		[-0.80, 0.28, 0.94, 0.98, 0.91, "ws"],
		[-0.05, 0.28, 0.98, 1.50, 0.90, "cabin"],
		[0.95, 0.28, 0.98, 1.50, 0.90, "ws"],
		[1.65, 0.28, 0.98, 1.04, 0.90, "body"],
		[2.15, 0.28, 0.92, 0.98, 0.88, "bumper"],
		[2.30, 0.36, 0.58, 0.66, 0.84, "end"],
	],
	"suv": [
		[-2.40, 0.42, 0.66, 0.72, 0.90, "bumper"],
		[-2.25, 0.34, 0.90, 0.96, 0.95, "body"],
		[-0.95, 0.34, 1.06, 1.10, 0.96, "ws"],
		[-0.30, 0.34, 1.08, 1.76, 0.95, "cabin"],
		[1.90, 0.34, 1.08, 1.76, 0.95, "ws"],
		[2.25, 0.34, 1.08, 1.30, 0.93, "bumper"],
		[2.40, 0.42, 0.66, 0.74, 0.88, "end"],
	],
	"pickup": [
		[-2.70, 0.44, 0.70, 0.76, 0.92, "bumper"],
		[-2.55, 0.36, 0.96, 1.02, 0.98, "body"],
		[-1.10, 0.36, 1.10, 1.14, 0.98, "ws"],
		[-0.45, 0.36, 1.12, 1.84, 0.97, "cabin"],
		[0.55, 0.36, 1.12, 1.84, 0.97, "ws"],
		[0.65, 0.36, 1.12, 1.16, 0.97, "bed"],
		[2.55, 0.36, 1.12, 1.16, 0.97, "bumper"],
		[2.70, 0.44, 0.70, 0.78, 0.92, "end"],
	],
}

const WHEELS := {
	"sedan": {"radius": 0.34, "width": 0.22, "x": 0.80, "front_z": -1.40, "rear_z": 1.45},
	"suv": {"radius": 0.40, "width": 0.26, "x": 0.84, "front_z": -1.45, "rear_z": 1.50},
	"pickup": {"radius": 0.42, "width": 0.27, "x": 0.86, "front_z": -1.75, "rear_z": 1.70},
}

const PAINTS := [
	Color(0.86, 0.87, 0.88), Color(0.12, 0.12, 0.13), Color(0.55, 0.56, 0.58),
	Color(0.30, 0.31, 0.34), Color(0.62, 0.10, 0.09), Color(0.16, 0.26, 0.48),
	Color(0.78, 0.78, 0.76), Color(0.20, 0.34, 0.28), Color(0.52, 0.40, 0.28),
]

const GLASS := Color(0.12, 0.16, 0.20, 0.55)
const TRIM := Color(0.08, 0.08, 0.09)
const HEADLIGHT := Color(0.95, 0.95, 0.88)
const TAILLIGHT := Color(0.80, 0.08, 0.05)
const RIM := Color(0.70, 0.70, 0.72)


static func styles() -> Array:
	return PROFILES.keys()


## Overall size as [length, width, height] and the chassis box used for
## collision (centre, size).
static func dims(style: String) -> Dictionary:
	var p: Array = PROFILES[style]
	var top := 0.0
	var floor_y := INF
	var w := 0.0
	for s in p:
		top = maxf(top, s[3])
		floor_y = minf(floor_y, s[1])
		w = maxf(w, s[4])
	var z0: float = p[0][0]
	var z1: float = p[p.size() - 1][0]
	return {
		"length": z1 - z0, "width": w * 2.0, "height": top, "floor": floor_y,
		"box_center": Vector3(0, (floor_y + top) * 0.5, (z0 + z1) * 0.5),
		"box_size": Vector3(w * 2.0, top - floor_y, z1 - z0),
	}


static func wheel_positions(style: String) -> Array:
	var wd: Dictionary = WHEELS[style]
	return [
		Vector3(-wd["x"], wd["radius"], wd["front_z"]), Vector3(wd["x"], wd["radius"], wd["front_z"]),
		Vector3(-wd["x"], wd["radius"], wd["rear_z"]), Vector3(wd["x"], wd["radius"], wd["rear_z"]),
	]


static func wheel_radius(style: String) -> float:
	return WHEELS[style]["radius"]


## Body with glass, lights and mirrors (no wheels).
static func build_body(style: String, paint: Color) -> ArrayMesh:
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trim := SurfaceTool.new()
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glass_st := SurfaceTool.new()
	glass_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p: Array = PROFILES[style]
	var sections: Array = []
	for s in p:
		sections.append(_section(s))

	for i in p.size() - 1:
		var kind: String = p[i][5]
		var a: Array = sections[i]
		var b: Array = sections[i + 1]
		var n := a.size()
		for k in n:
			var a0: Vector3 = a[k]
			var a1: Vector3 = a[(k + 1) % n]
			var b0: Vector3 = b[k]
			var b1: Vector3 = b[(k + 1) % n]
			var panel := _panel_kind(k, n)
			var glass := (kind == "ws" and panel != "bottom") or (kind == "cabin" and panel == "side_upper")
			if kind == "bed" and panel == "top":
				continue
			var col := paint
			var st := body
			if glass:
				col = GLASS
				st = glass_st
			elif kind == "bumper" and panel in ["bottom", "side_lower"]:
				col = TRIM
				st = trim
			elif panel == "bottom":
				col = TRIM
				st = trim
			elif panel == "top":
				col = paint.lightened(0.08)
			elif panel == "side_lower":
				col = paint.darkened(0.06)
			var hint := _outward_hint(panel, a0 + a1)
			_quad(st, a0, a1, b1, b0, hint, col)

	# End caps (grille and tail) as fans around the section centre.
	_cap(body, sections[0], Vector3.FORWARD, paint.darkened(0.25))
	_cap(body, sections[sections.size() - 1], Vector3.BACK, paint.darkened(0.15))
	if style == "pickup":
		_bed(body, p, paint)

	# Lights and mirrors.
	var front: Array = p[0]
	var rear: Array = p[p.size() - 1]
	for sx in [-1.0, 1.0]:
		var hw: float = front[4]
		_box(trim, Vector3(sx * (hw - 0.30), (front[2] + front[3]) * 0.5 + 0.06, front[0] - 0.01),
			Vector3(0.36, 0.16, 0.06), HEADLIGHT)
		var rw: float = rear[4]
		_box(trim, Vector3(sx * (rw - 0.28), (rear[2] + rear[3]) * 0.5 + 0.1, rear[0] + 0.01),
			Vector3(0.34, 0.14, 0.06), TAILLIGHT)
		# Mirror at the base of the A-pillar.
		var ws := _station_of_kind(p, "ws")
		_box(trim, Vector3(sx * (ws[4] + 0.12), ws[2] + 0.12, ws[0] + 0.15), Vector3(0.22, 0.12, 0.10), paint)

	var mesh := body.commit()
	var paint_mat := StandardMaterial3D.new()
	paint_mat.vertex_color_use_as_albedo = true
	paint_mat.metallic = 0.45
	paint_mat.roughness = 0.35
	paint_mat.metallic_specular = 0.6
	mesh.surface_set_material(0, paint_mat)
	mesh = trim.commit(mesh)
	var trim_mat := StandardMaterial3D.new()
	trim_mat.vertex_color_use_as_albedo = true
	trim_mat.metallic = 0.2
	trim_mat.roughness = 0.4
	mesh.surface_set_material(1, trim_mat)
	mesh = glass_st.commit(mesh)
	var glass_mat := StandardMaterial3D.new()
	glass_mat.vertex_color_use_as_albedo = true
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.metallic = 0.6
	glass_mat.roughness = 0.08
	glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(2, glass_mat)
	return mesh


## Tire with a lighter rim disc, axle along X, centred on the origin.
static func build_wheel(style: String) -> ArrayMesh:
	var wd: Dictionary = WHEELS[style]
	var r: float = wd["radius"]
	var w: float = wd["width"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 18
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var p0 := Vector3(0, cos(a0) * r, sin(a0) * r)
		var p1 := Vector3(0, cos(a1) * r, sin(a1) * r)
		var l := Vector3(-w * 0.5, 0, 0)
		var rt := Vector3(w * 0.5, 0, 0)
		_quad(st, p0 + l, p1 + l, p1 + rt, p0 + rt, (p0 + p1).normalized(), TRIM)
		# Sidewalls (tire) and rim discs.
		var q0 := p0 * 0.62
		var q1 := p1 * 0.62
		_quad(st, p1 + l, p0 + l, q0 + l, q1 + l, Vector3.LEFT, Color(0.12, 0.12, 0.12))
		_quad(st, p0 + rt, p1 + rt, q1 + rt, q0 + rt, Vector3.RIGHT, Color(0.12, 0.12, 0.12))
		var c := Vector3.ZERO
		var il := l * 0.9
		var ir := rt * 0.9
		_tri(st, q1 + il, q0 + il, c + il, Vector3.LEFT, RIM if i % 3 else RIM.darkened(0.3))
		_tri(st, q0 + ir, q1 + ir, c + ir, Vector3.RIGHT, RIM if i % 3 else RIM.darkened(0.3))
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	mesh.surface_set_material(0, mat)
	return mesh


# --- internals -------------------------------------------------------------

## Eight-point chamfered cross-section, counter-clockwise seen from the front
## (nose), starting bottom-left.
static func _section(s: Array) -> Array:
	var z: float = s[0]
	var yb: float = s[1]
	var belt: float = s[2]
	var top: float = s[3]
	var w: float = s[4]
	var has_cabin := top > belt + 0.08
	var wu1 := w * 0.90 if has_cabin else w
	var wu2 := w * 0.80 if has_cabin else w * 0.96
	var ch := 0.08  # bottom chamfer
	return [
		Vector3(-w + ch, yb, z), Vector3(w - ch, yb, z),
		Vector3(w, yb + ch, z), Vector3(w, belt, z),
		Vector3(wu1, belt + (0.03 if has_cabin else 0.0), z), Vector3(wu2, top, z),
		Vector3(-wu2, top, z), Vector3(-wu1, belt + (0.03 if has_cabin else 0.0), z),
		Vector3(-w, belt, z), Vector3(-w, yb + ch, z),
	]


static func _panel_kind(k: int, n: int) -> String:
	match k:
		0: return "bottom"
		1, 9: return "chamfer"
		2, 8: return "side_lower"
		3, 7: return "belt"
		4, 6: return "side_upper"
		5: return "top"
	return "body"


static func _outward_hint(panel: String, mid: Vector3) -> Vector3:
	match panel:
		"bottom": return Vector3.DOWN
		"top": return Vector3.UP
	return Vector3(signf(mid.x), 0.2, 0.0)


static func _station_of_kind(p: Array, kind: String) -> Array:
	for s in p:
		if s[5] == kind:
			return s
	return p[0]


static func _cap(st: SurfaceTool, sec: Array, hint: Vector3, col: Color) -> void:
	var c := Vector3.ZERO
	for v in sec:
		c += v
	c /= sec.size()
	for k in sec.size():
		_tri(st, sec[k], sec[(k + 1) % sec.size()], c, hint, col)


## Pickup bed: floor and inner walls between the "bed" station and the next.
static func _bed(st: SurfaceTool, p: Array, paint: Color) -> void:
	var i := 0
	for k in p.size():
		if p[k][5] == "bed":
			i = k
	var z0: float = p[i][0]
	var z1: float = p[i + 1][0]
	var w: float = p[i][4] * 0.80 - 0.05
	var floor_y: float = p[i][2] - 0.45
	var top: float = p[i][3]
	var dark := paint.darkened(0.35)
	_quad(st, Vector3(-w, floor_y, z0), Vector3(w, floor_y, z0), Vector3(w, floor_y, z1), Vector3(-w, floor_y, z1), Vector3.UP, dark)
	_quad(st, Vector3(-w, floor_y, z0), Vector3(-w, top, z0), Vector3(-w, top, z1), Vector3(-w, floor_y, z1), Vector3.RIGHT, dark)
	_quad(st, Vector3(w, floor_y, z0), Vector3(w, top, z0), Vector3(w, top, z1), Vector3(w, floor_y, z1), Vector3.LEFT, dark)
	_quad(st, Vector3(-w, floor_y, z0), Vector3(w, floor_y, z0), Vector3(w, top, z0), Vector3(-w, top, z0), Vector3.BACK, dark)
	_quad(st, Vector3(-w, floor_y, z1), Vector3(w, floor_y, z1), Vector3(w, top, z1), Vector3(-w, top, z1), Vector3.FORWARD, dark)


static func _box(st: SurfaceTool, center: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var c := center
	var v := [
		c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(-h.x, h.y, -h.z),
		c + Vector3(-h.x, -h.y, h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z),
	]
	_quad(st, v[0], v[1], v[2], v[3], Vector3.FORWARD, col)
	_quad(st, v[5], v[4], v[7], v[6], Vector3.BACK, col)
	_quad(st, v[4], v[0], v[3], v[7], Vector3.LEFT, col)
	_quad(st, v[1], v[5], v[6], v[2], Vector3.RIGHT, col)
	_quad(st, v[3], v[2], v[6], v[7], Vector3.UP, col)
	_quad(st, v[4], v[5], v[1], v[0], Vector3.DOWN, col)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, hint: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-10:
		n = (c - a).cross(d - a)
	if n.length_squared() < 1e-10:
		return
	n = n.normalized()
	if n.dot(hint) < 0.0:
		n = -n
	_tri(st, a, b, c, n, col)
	_tri(st, a, c, d, n, col)


## Front face is clockwise seen from the normal side.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, col: Color) -> void:
	if (b - a).cross(c - a).length_squared() < 1e-12:
		return
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_color(col)
		st.set_normal(normal)
		st.add_vertex(v)
