extends RefCounted
## Procedural surface materials: tileable noise albedo + normal maps built at
## startup with FastNoiseLite, mapped triplanar in world space so none of
## the generated geometry needs UVs. Vertex colours still carry the base
## colour; the texture adds grain and relief on top.

static var _cache: Dictionary = {}


## kind: "stucco", "asphalt", "concrete", "ground", "shingle", "bark".
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
		"shingle":
			_apply(m, 0.05, 0.8, 1.0, 0.5, 1.6)
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
