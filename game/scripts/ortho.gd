extends RefCounted
## Aerial photo for a map (<map>.ortho.png + .ortho.json from
## tools/fetch_imagery.py), mapped into the map's local metres. Used as the
## ground texture and sampled for roof colours, tree canopy and so on.

const OsmData := preload("res://scripts/osm_data.gd")

var image: Image
var texture: ImageTexture
var rect := Rect2()  # local-metre bounds (x east, y = z south)
var width := 0
var height := 0
var meters_per_px := 1.0


## Loads <base>.ortho.png / .ortho.json for the map at `osm_path`.
func load_for(osm_path: String, data: OsmData) -> Error:
	var base := osm_path.get_basename()
	var png := base + ".ortho.png"
	var meta_path := base + ".ortho.json"
	if not FileAccess.file_exists(png) or not FileAccess.file_exists(meta_path):
		return ERR_FILE_NOT_FOUND
	var meta = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	if not (meta is Dictionary) or not meta.has("south"):
		push_error("%s is not an ortho description" % meta_path)
		return ERR_INVALID_DATA
	image = Image.new()
	var err := image.load(ProjectSettings.globalize_path(png))
	if err != OK:
		push_error("Could not load %s (error %d)" % [png, err])
		return err
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGB8)
	width = image.get_width()
	height = image.get_height()
	meters_per_px = float(meta.get("meters_per_px", 1.0))
	var nw := data.project(meta["north"], meta["west"])
	var se := data.project(meta["south"], meta["east"])
	rect = Rect2(nw, se - nw)
	image.generate_mipmaps()
	texture = ImageTexture.create_from_image(image)
	return OK


func covers(p: Vector2) -> bool:
	return rect.has_point(p)


## Texture coordinate (0..1) of local (x, z).
func uv(x: float, z: float) -> Vector2:
	return Vector2((x - rect.position.x) / rect.size.x, (z - rect.position.y) / rect.size.y)


func color_at(x: float, z: float) -> Color:
	var u := uv(x, z)
	if u.x < 0.0 or u.y < 0.0 or u.x >= 1.0 or u.y >= 1.0:
		return Color(-1, -1, -1)
	return image.get_pixel(int(u.x * width), int(u.y * height))


## Average colour of the photo inside a footprint (sampled on a grid), or
## an invalid colour (negative r) if the ring is off the image.
func mean_in_ring(ring: PackedVector2Array, step_m: float = 1.0) -> Color:
	if ring.size() < 3:
		return Color(-1, -1, -1)
	var lo := ring[0]
	var hi := ring[0]
	for p in ring:
		lo = lo.min(p)
		hi = hi.max(p)
	var sum := Color(0, 0, 0)
	var n := 0
	var z := lo.y
	while z <= hi.y:
		var x := lo.x
		while x <= hi.x:
			var p := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(p, ring):
				var c := color_at(x, z)
				if c.r >= 0.0:
					sum += c
					n += 1
			x += step_m
		z += step_m
	if n == 0:
		return Color(-1, -1, -1)
	return Color(sum.r / n, sum.g / n, sum.b / n)


## Looks like tree canopy from above: green-dominant and fairly dark.
func is_canopy(x: float, z: float) -> bool:
	var c := color_at(x, z)
	if c.r < 0.0:
		return false
	return c.g > c.r * 1.12 and c.g > c.b * 1.15 and c.g < 0.55 and c.get_luminance() < 0.42


## Mown, irrigated lawn: bright green.
func is_lawn(x: float, z: float) -> bool:
	var c := color_at(x, z)
	if c.r < 0.0:
		return false
	return c.g > c.r * 1.1 and c.g > c.b * 1.2 and c.g >= 0.45


## Dry open ground or scrub (tan / olive), where sage would grow.
func is_open_ground(x: float, z: float) -> bool:
	var c := color_at(x, z)
	if c.r < 0.0:
		return false
	return c.r > c.b * 1.1 and absf(c.r - c.g) < 0.18 and c.get_luminance() > 0.3 and c.get_luminance() < 0.75
