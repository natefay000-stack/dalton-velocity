extends RefCounted
## Terrain heightfield loaded from a .height file (see tools/fetch_overture.py)
## and expressed in the map's local metres (+X east, -Z north, origin at the
## centre of the OSM bounds). Heights are shifted so the lowest point is y=0.
##
## Grid cell (c, r) sits at x = x0 + c*dx, z = z0 + r*dz; row 0 is the north
## edge. Provides height queries, polygon rasterisation (for painting and
## carving) and builds the visible mesh plus HeightMapShape3D collision.

const OsmData := preload("res://scripts/osm_data.gd")
const Surfaces := preload("res://scripts/surfaces.gd")

var cols := 0
var rows := 0
var heights := PackedFloat32Array()  # row-major, metres above `base_elevation`
var colors := PackedColorArray()     # per-vertex albedo, painted by the builder
var x0 := 0.0
var z0 := 0.0
var dx := 1.0
var dz := 1.0
var base_elevation := 0.0

const SKIRT_LENGTH := 30000.0
## Aerial photo draped as the ground texture (optional).
var ortho = null


## Loads a .height file and maps it into `data`'s local frame.
func load_file(path: String, data: OsmData) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	if f.get_length() < 48 or f.get_buffer(4).get_string_from_ascii() != "HGT1":
		push_error("%s is not a HGT1 height file" % path)
		return ERR_FILE_UNRECOGNIZED
	var south := f.get_double()
	var west := f.get_double()
	var north := f.get_double()
	var east := f.get_double()
	cols = f.get_32()
	rows = f.get_32()
	if cols < 2 or rows < 2 or cols * rows > 16_000_000 or south >= north or west >= east:
		push_error("%s has an invalid header (%dx%d)" % [path, cols, rows])
		return ERR_INVALID_DATA
	var buf := f.get_buffer(cols * rows * 4)
	if buf.size() != cols * rows * 4:
		push_error("%s is truncated" % path)
		return ERR_FILE_CORRUPT
	heights = buf.to_float32_array()

	base_elevation = INF
	for h in heights:
		if not is_finite(h) or h < -500.0 or h > 9000.0:
			push_error("%s contains invalid elevations" % path)
			return ERR_INVALID_DATA
		base_elevation = minf(base_elevation, h)
	for i in heights.size():
		heights[i] -= base_elevation

	var nw := data.project(north, west)
	var se := data.project(south, east)
	x0 = nw.x
	z0 = nw.y
	dx = (se.x - nw.x) / (cols - 1)
	dz = (se.y - nw.y) / (rows - 1)
	colors.resize(cols * rows)
	colors.fill(Color.WHITE)
	return OK


func get_rect() -> Rect2:
	return Rect2(x0, z0, dx * (cols - 1), dz * (rows - 1))


func h(c: int, r: int) -> float:
	return heights[clampi(r, 0, rows - 1) * cols + clampi(c, 0, cols - 1)]


## Height at local (x, z), matching the collision/mesh triangles (each cell
## is split along its (c+1,r)-(c,r+1) diagonal, as HeightMapShape3D does),
## clamped at the edges.
func height_at(x: float, z: float) -> float:
	var fc := clampf((x - x0) / dx, 0.0, cols - 1.001)
	var fr := clampf((z - z0) / dz, 0.0, rows - 1.001)
	var c := int(fc)
	var r := int(fr)
	var tx := fc - c
	var tz := fr - r
	var h00 := h(c, r)
	var h10 := h(c + 1, r)
	var h01 := h(c, r + 1)
	if tx + tz <= 1.0:
		return h00 + (h10 - h00) * tx + (h01 - h00) * tz
	var h11 := h(c + 1, r + 1)
	return h11 + (h01 - h11) * (1.0 - tx) + (h10 - h11) * (1.0 - tz)


func normal_at(x: float, z: float) -> Vector3:
	var e := maxf(dx, dz)
	return Vector3(
		height_at(x - e, z) - height_at(x + e, z), 2.0 * e,
		height_at(x, z - e) - height_at(x, z + e)).normalized()


## Calls `fn(c, r)` for every grid vertex inside the polygon (scanline fill).
func for_each_inside(ring: PackedVector2Array, fn: Callable) -> void:
	var n := ring.size()
	if n < 3:
		return
	var zmin := INF
	var zmax := -INF
	for p in ring:
		zmin = minf(zmin, p.y)
		zmax = maxf(zmax, p.y)
	var r0 := clampi(int(ceil((zmin - z0) / dz)), 0, rows - 1)
	var r1 := clampi(int(floor((zmax - z0) / dz)), 0, rows - 1)
	for r in range(r0, r1 + 1):
		var z := z0 + r * dz
		var xs: Array[float] = []
		for i in n:
			var a := ring[i]
			var b := ring[(i + 1) % n]
			if (a.y <= z) != (b.y <= z):
				xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		for k in range(0, xs.size() - 1, 2):
			var c0 := clampi(int(ceil((xs[k] - x0) / dx)), 0, cols - 1)
			var c1 := clampi(int(floor((xs[k + 1] - x0) / dx)), 0, cols - 1)
			for c in range(c0, c1 + 1):
				fn.call(c, r)


## Calls `fn(c, r)` for every grid vertex within `radius` of the rect.
func for_each_near(rect: Rect2, radius: float, fn: Callable) -> void:
	var g := rect.grow(radius)
	var c0 := clampi(int(ceil((g.position.x - x0) / dx)), 0, cols - 1)
	var c1 := clampi(int(floor((g.end.x - x0) / dx)), 0, cols - 1)
	var r0 := clampi(int(ceil((g.position.y - z0) / dz)), 0, rows - 1)
	var r1 := clampi(int(floor((g.end.y - z0) / dz)), 0, rows - 1)
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			fn.call(c, r)


## Road bed: sets every vertex within `half_width` of the polyline to the
## centreline's height there (sampled before any carving, via `center_h`
## per point), so a road sits on a flat, cut-and-filled strip instead of
## having the hillside poke through it. `blend` metres beyond that ease
## back to the natural ground.
func flatten_polyline(pts: PackedVector2Array, center_h: PackedFloat32Array, half_width: float, blend: float) -> void:
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len < 1e-3:
			continue
		var rect := Rect2(a, Vector2.ZERO).expand(b)
		for_each_near(rect, half_width + blend, func(c: int, r: int) -> void:
			var p := Vector2(x0 + c * dx, z0 + r * dz)
			var q := Geometry2D.get_closest_point_to_segment(p, a, b)
			var d := p.distance_to(q)
			if d > half_width + blend:
				return
			var t := a.distance_to(q) / seg_len
			var target := lerpf(center_h[i], center_h[i + 1], t)
			var idx := r * cols + c
			if d <= half_width:
				heights[idx] = target
			else:
				var k := (d - half_width) / blend  # 0 at the edge, 1 at natural
				heights[idx] = lerpf(target, heights[idx], smoothstep(0.0, 1.0, k)))


## Visible mesh + HeightMapShape3D collision.
func build_node() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Terrain"

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(cols * rows)
	norms.resize(cols * rows)
	for r in rows:
		for c in cols:
			var i := r * cols + c
			verts[i] = Vector3(x0 + c * dx, heights[i], z0 + r * dz)
			norms[i] = Vector3(
				(h(c - 1, r) - h(c + 1, r)) / (2.0 * dx), 1.0,
				(h(c, r - 1) - h(c, r + 1)) / (2.0 * dz)).normalized()
	var uvs := PackedVector2Array()
	if ortho != null:
		uvs.resize(cols * rows)
		for i in cols * rows:
			uvs[i] = ortho.uv(verts[i].x, verts[i].z)
	var idx := PackedInt32Array()
	idx.resize((cols - 1) * (rows - 1) * 6)
	var k := 0
	for r in rows - 1:
		for c in cols - 1:
			var a := r * cols + c
			var b := a + 1
			var d := a + cols
			var e := d + 1
			# Split along b-d to match height_at() and the collision shape;
			# clockwise seen from above.
			idx[k] = a; idx[k + 1] = b; idx[k + 2] = d
			idx[k + 3] = b; idx[k + 4] = e; idx[k + 5] = d
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	if ortho != null:
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _ortho_material() if ortho != null else Surfaces.material("ground"))
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	body.add_child(mi)

	body.add_child(_build_skirt())

	# HeightMapShape3D is centred on its node and spaced 1 unit; scale it.
	var shape := HeightMapShape3D.new()
	shape.map_width = cols
	shape.map_depth = rows
	shape.map_data = heights
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	cs.shape = shape
	cs.scale = Vector3(dx, 1.0, dz)
	cs.position = Vector3(x0 + dx * (cols - 1) * 0.5, 0.0, z0 + dz * (rows - 1) * 0.5)
	body.add_child(cs)

	# Invisible walls so nothing drives off the edge of the world.
	var rect := get_rect()
	var top := 0.0
	for hh in heights:
		top = maxf(top, hh)
	for side in 4:
		var wall := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var horizontal := side < 2
		box.size = Vector3(rect.size.x if horizontal else 2.0, top + 60.0, 2.0 if horizontal else rect.size.y)
		wall.shape = box
		var center := rect.get_center()
		wall.position = Vector3(
			center.x if horizontal else (rect.position.x if side == 2 else rect.end.x),
			(top + 60.0) * 0.5 - 10.0,
			(rect.position.y if side == 0 else rect.end.y) if horizontal else center.y)
		body.add_child(wall)
	return body


## Photo on the ground, with the fine ground grain kept as a normal map so
## it still catches low sun.
func _ortho_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = ortho.texture
	m.vertex_color_use_as_albedo = true  # white except where the builder dims (water beds)
	m.roughness = 1.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var grain := Surfaces.grain(0.035, 0.8, 1.0)
	m.normal_enabled = true
	m.normal_texture = grain[1]
	m.normal_scale = 0.2
	m.uv1_triplanar = false
	return m


## Visual-only apron that continues each edge vertex outward, so the world
## doesn't end in a cliff over the sky's ground colour.
func _build_skirt() -> MeshInstance3D:
	var perimeter: Array[int] = []
	for c in cols:
		perimeter.append(c)
	for r in range(1, rows):
		perimeter.append(r * cols + cols - 1)
	for c in range(cols - 2, -1, -1):
		perimeter.append((rows - 1) * cols + c)
	for r in range(rows - 2, 0, -1):
		perimeter.append(r * cols)
	var center := get_rect().get_center()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := perimeter.size()
	for k in n:
		var i0 := perimeter[k]
		var i1 := perimeter[(k + 1) % n]
		var a := Vector3(x0 + (i0 % cols) * dx, heights[i0], z0 + (i0 / cols) * dz)
		var b := Vector3(x0 + (i1 % cols) * dx, heights[i1], z0 + (i1 / cols) * dz)
		var da := Vector2(a.x - center.x, a.z - center.y).normalized() * SKIRT_LENGTH
		var db := Vector2(b.x - center.x, b.z - center.y).normalized() * SKIRT_LENGTH
		var a2 := Vector3(a.x + da.x, a.y, a.z + da.y)
		var b2 := Vector3(b.x + db.x, b.y, b.z + db.y)
		for v in [[a, colors[i0]], [b, colors[i1]], [b2, colors[i1]], [a, colors[i0]], [b2, colors[i1]], [a2, colors[i0]]]:
			st.set_color(v[1])
			st.set_normal(Vector3.UP)
			st.add_vertex(v[0])
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "Skirt"
	mi.mesh = st.commit()
	mi.mesh.surface_set_material(0, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
