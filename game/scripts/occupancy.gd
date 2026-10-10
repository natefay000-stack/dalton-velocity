extends RefCounted
## 1 m occupancy grid over the map: which cells are taken by roads,
## buildings, water or paths. Used to place trees, parked cars and
## pedestrians where they don't collide with the map itself.

const CELL := 1.0
const BUILDING := 1
const ROAD := 2
const WATER := 4
const PATH := 8
const PROP := 16  # trees / street furniture already placed
const DRIVEWAY := 32

var rect := Rect2()
var cols := 0
var rows := 0
var cells := PackedByteArray()


func setup(bounds: Rect2, margin: float = 20.0) -> void:
	rect = bounds.grow(margin)
	cols = maxi(1, int(ceil(rect.size.x / CELL)) + 1)
	rows = maxi(1, int(ceil(rect.size.y / CELL)) + 1)
	cells.resize(cols * rows)
	cells.fill(0)


func _index(x: float, z: float) -> int:
	var c := int((x - rect.position.x) / CELL)
	var r := int((z - rect.position.y) / CELL)
	if c < 0 or r < 0 or c >= cols or r >= rows:
		return -1
	return r * cols + c


func mark(x: float, z: float, bit: int) -> void:
	var i := _index(x, z)
	if i >= 0:
		cells[i] |= bit


func get_at(x: float, z: float) -> int:
	var i := _index(x, z)
	return cells[i] if i >= 0 else BUILDING  # outside the map counts as blocked


## True if no cell within `radius` has any of `mask` set.
func is_free(x: float, z: float, radius: float, mask: int) -> bool:
	var r := int(ceil(radius / CELL))
	var cx := int((x - rect.position.x) / CELL)
	var cz := int((z - rect.position.y) / CELL)
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dz * dz > r * r + r:
				continue
			var c := cx + dx
			var rr := cz + dz
			if c < 0 or rr < 0 or c >= cols or rr >= rows:
				return false
			if cells[rr * cols + c] & mask:
				return false
	return true


func mark_disc(x: float, z: float, radius: float, bit: int) -> void:
	var r := int(ceil(radius / CELL))
	var cx := int((x - rect.position.x) / CELL)
	var cz := int((z - rect.position.y) / CELL)
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dz * dz > r * r + r:
				continue
			var c := cx + dx
			var rr := cz + dz
			if c >= 0 and rr >= 0 and c < cols and rr < rows:
				cells[rr * cols + c] |= bit


## Marks every cell whose centre lies within `half_width` of the polyline.
func mark_polyline(pts: PackedVector2Array, half_width: float, bit: int) -> void:
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * half_width
		var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2.ONE * half_width
		var c0 := maxi(0, int((lo.x - rect.position.x) / CELL))
		var c1 := mini(cols - 1, int((hi.x - rect.position.x) / CELL))
		var r0 := maxi(0, int((lo.y - rect.position.y) / CELL))
		var r1 := mini(rows - 1, int((hi.y - rect.position.y) / CELL))
		var w2 := half_width * half_width
		for r in range(r0, r1 + 1):
			var z := rect.position.y + (r + 0.5) * CELL
			for c in range(c0, c1 + 1):
				var p := Vector2(rect.position.x + (c + 0.5) * CELL, z)
				if p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, a, b)) <= w2:
					cells[r * cols + c] |= bit


## Marks every cell whose centre lies inside the polygon (plus `grow` m).
func mark_polygon(ring: PackedVector2Array, grow: float, bit: int) -> void:
	var poly := ring
	if grow > 0.0:
		var grown := Geometry2D.offset_polygon(ring, grow)
		if not grown.is_empty():
			poly = grown[0]
	var n := poly.size()
	if n < 3:
		return
	var zmin := INF
	var zmax := -INF
	for p in poly:
		zmin = minf(zmin, p.y)
		zmax = maxf(zmax, p.y)
	var r0 := maxi(0, int((zmin - rect.position.y) / CELL))
	var r1 := mini(rows - 1, int((zmax - rect.position.y) / CELL))
	for r in range(r0, r1 + 1):
		var z := rect.position.y + (r + 0.5) * CELL
		var xs: Array[float] = []
		for i in n:
			var a := poly[i]
			var b := poly[(i + 1) % n]
			if (a.y <= z) != (b.y <= z):
				xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		for k in range(0, xs.size() - 1, 2):
			var c0 := maxi(0, int((xs[k] - rect.position.x) / CELL + 0.5))
			var c1 := mini(cols - 1, int((xs[k + 1] - rect.position.x) / CELL - 0.5))
			for c in range(c0, c1 + 1):
				cells[r * cols + c] |= bit


func count(bit: int) -> int:
	var n := 0
	for v in cells:
		if v & bit:
			n += 1
	return n
