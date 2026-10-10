extends RefCounted
## Procedural surface materials: tileable noise albedo + normal maps built at
## startup with FastNoiseLite, mapped triplanar in world space so none of
## the generated geometry needs UVs. Vertex colours still carry the base
## colour; the texture adds grain and relief on top.

static var _cache: Dictionary = {}


## Triplanar (world-mapped) kinds: "stucco", "brick", "asphalt", "concrete",
## "ground". UV-mapped kinds (the mesh supplies UVs in metres/TILE_M):
## "shingle" (rows along V), "road" (U across the road, V along it).
const TILE_M := 2.0

static func material(kind: String) -> StandardMaterial3D:
	if _cache.has(kind):
		return _cache[kind]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	match kind:
		"stucco":
			_apply(m, 0.07, 0.9, 1.0, 0.45, 2.1)
			m.roughness = 0.9
		"brick":
			_apply_pattern(m, "brick", 0.6, 1.0)
			m.roughness = 0.95
		"shingle":
			m.uv1_triplanar = false
			m.uv1_world_triplanar = false
			_apply_pattern(m, "shingle", 0.7, 1.0)
			m.roughness = 0.95
		"road":
			m.uv1_triplanar = false
			m.uv1_world_triplanar = false
			_apply_pattern(m, "road", 0.3, 1.0)
			m.roughness = 0.95
		"asphalt":
			_apply(m, 0.16, 0.84, 1.0, 0.35, 2.8)
			m.roughness = 0.95
		"concrete":
			_apply(m, 0.10, 0.9, 1.0, 0.3, 1.4)
			m.roughness = 0.9
		"ground":
			_apply(m, 0.035, 0.80, 1.0, 0.25, 0.14)
			m.roughness = 1.0
		_:
			m.roughness = 0.9
	_cache[kind] = m
	return m


## frequency: noise detail; lo/hi: brightness range of the grain; normal
## strength; triplanar tiles per metre (uv1_scale).
static func _apply(m: StandardMaterial3D, frequency: float, lo: float, hi: float, normal: float, tiles: float) -> void:
	var tex := grain(frequency, lo, hi)
	m.albedo_texture = tex[0]
	m.normal_enabled = true
	m.normal_texture = tex[1]
	m.normal_scale = normal
	m.uv1_scale = Vector3.ONE * tiles
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


static func _apply_pattern(m: StandardMaterial3D, kind: String, normal: float, tiles: float) -> void:
	var tex := pattern(kind)
	m.albedo_texture = tex[0]
	m.normal_enabled = true
	m.normal_texture = tex[1]
	m.normal_scale = normal
	m.uv1_scale = Vector3.ONE * tiles
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


## Patterned textures; one tile covers TILE_M metres. Returns [albedo, normal].
static func pattern(kind: String) -> Array:
	var key := "pattern:" + kind
	if _cache.has(key):
		return _cache[key]
	var size := 256
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = kind.hash()
	noise.frequency = 0.08
	noise.fractal_octaves = 3
	var grain := noise.get_seamless_image(size, size, false, false, 0.1)
	var height := Image.create(size, size, false, Image.FORMAT_RGB8)
	var albedo := Image.create(size, size, true, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var g := grain.get_pixel(x, y).r
			var h := 0.0  # relief 0..1
			var b := 1.0  # brightness
			var fx := float(x) / size  # 0..1 across one tile
			var fy := float(y) / size
			match kind:
				"brick":
					# Courses 0.075 m, bricks 0.23 m, running bond; mortar recessed.
					var row := fy * TILE_M / 0.075
					var r := int(row)
					var col := (fx * TILE_M / 0.23) + (0.5 if r % 2 else 0.0)
					var in_mortar := fmod(row, 1.0) < 0.14 or fmod(col, 1.0) < 0.05
					h = 0.2 if in_mortar else 0.85 + 0.15 * g
					b = 0.86 + 0.14 * g if in_mortar else 0.9 + 0.12 * (g - 0.5) + 0.08 * fmod(float(hash(Vector2i(int(col) + r * 97, r))) / 1e6, 1.0)
					if in_mortar:
						b = 1.2
				"shingle":
					# Tabs 0.25 m high with a shadow line under each row and
					# staggered vertical slots.
					var row := fy * TILE_M / 0.25
					var r := int(row)
					var fr := fmod(row, 1.0)
					var col := fx * TILE_M / 0.3 + (0.5 if r % 2 else 0.0)
					var slot := fmod(col, 1.0) < 0.06 and fr > 0.45
					h = 0.3 if fr < 0.12 else 0.75 + 0.25 * g
					b = 0.78 + 0.22 * fr if fr < 0.12 else 0.9 + 0.16 * (g - 0.5)
					if slot:
						h = 0.35
						b *= 0.85
				"road":
					# Tyre wear in each lane, a lighter crown, fine aggregate.
					var wear := 0.0
					for lane_c in [0.20, 0.36, 0.64, 0.80]:
						wear = maxf(wear, exp(-pow((fx - lane_c) / 0.055, 2.0)))
					h = 0.5 + 0.5 * g
					b = 0.92 + 0.12 * (g - 0.5) + 0.07 * (1.0 - absf(fx - 0.5) * 2.0) - 0.16 * wear
			height.set_pixel(x, y, Color(h, h, h))
			albedo.set_pixel(x, y, Color(b, b, b))
	albedo.generate_mipmaps()
	height.bump_map_to_normal_map(3.0)
	height.generate_mipmaps()
	var out := [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(height)]
	_cache[key] = out
	return out


## [albedo, normal] seamless 256² textures of layered noise.
static func grain(frequency: float, lo: float, hi: float) -> Array:
	var key := "grain:%f:%f:%f" % [frequency, lo, hi]
	if _cache.has(key):
		return _cache[key]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = int(frequency * 1000.0)
	noise.frequency = frequency
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.2
	noise.fractal_gain = 0.55
	var size := 256
	var img := noise.get_seamless_image(size, size, false, false, 0.1)
	var albedo := Image.create(size, size, true, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var v := img.get_pixel(x, y).r  # 0..1
			var b := lerpf(lo, hi, v)
			albedo.set_pixel(x, y, Color(b, b, b))
	albedo.generate_mipmaps()
	var bump := img.duplicate()
	bump.bump_map_to_normal_map(2.0)
	bump.generate_mipmaps()
	var out := [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(bump)]
	_cache[key] = out
	return out
