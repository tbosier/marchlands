class_name Terrain
extends Node3D

## Builds and owns the visible ground: a chunked mesh generated from the
## heightmap, plus the water plane.
##
## Chunking exists for two reasons: frustum culling, and the ability to rebuild
## only the region a building flattened rather than the whole 192x192 field.

const CHUNKS := 8
const CHUNK_CELLS := Config.GRID / CHUNKS

var _hm: Heightmap
var _material: ShaderMaterial
var _chunks: Array[MeshInstance3D] = []
var _water: MeshInstance3D


func build(hm: Heightmap, wear: WearField) -> void:
	_hm = hm

	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/terrain.gdshader")
	_material.set_shader_parameter("wear_map", wear.texture())
	_material.set_shader_parameter("world_size", Config.WORLD_SIZE)
	_material.set_shader_parameter("sea_level", Config.SEA_LEVEL)
	# The shader consumes these as linear values, so the authored sRGB
	# constants have to be converted or the whole landscape reads washed out.
	var palette := {
		"color_grass": Config.COLOR_GRASS,
		"color_grass_dry": Config.COLOR_GRASS_DRY,
		"color_soil": Config.COLOR_SOIL,
		"color_rock": Config.COLOR_ROCK,
		"color_sand": Config.COLOR_SAND,
		"color_path": Config.COLOR_PATH,
		"color_track": Config.COLOR_TRACK,
		"color_improved": Config.COLOR_IMPROVED,
		"color_paved": Config.COLOR_PAVED,
		"color_marsh": Config.COLOR_MARSH,
	}
	for key in palette:
		var value: Color = palette[key]
		_material.set_shader_parameter(key, value.srgb_to_linear())
	set_season(Color(0.97, 1.08, 0.88), 0.12, 0.04)

	for cj in CHUNKS:
		for ci in CHUNKS:
			var mi := MeshInstance3D.new()
			mi.name = "chunk_%d_%d" % [ci, cj]
			mi.mesh = _build_chunk_mesh(ci, cj)
			mi.material_override = _material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			add_child(mi)
			_chunks.append(mi)

	_build_water()


func _build_chunk_mesh(ci: int, cj: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var i0 := ci * CHUNK_CELLS
	var j0 := cj * CHUNK_CELLS
	var n := CHUNK_CELLS + 1

	for j in n:
		for i in n:
			var gi := i0 + i
			var gj := j0 + j
			var x := gi * Config.CELL
			var z := gj * Config.CELL
			var y := _hm.corner(gi, gj)
			verts.append(Vector3(x, y, z))
			normals.append(_hm.normal_at(x, z))
			uvs.append(Vector2(x / Config.WORLD_SIZE, z / Config.WORLD_SIZE))

	for j in CHUNK_CELLS:
		for i in CHUNK_CELLS:
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			# Split each quad along its shorter diagonal so ridges stay sharp.
			# Godot's ArrayMesh treats clockwise winding as front-facing, so
			# these are wound the opposite way round to the usual convention.
			if absf(verts[a].y - verts[d].y) <= absf(verts[b].y - verts[c].y):
				indices.append_array([a, d, c, a, b, d])
			else:
				indices.append_array([a, b, c, b, d, c])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Grade the ground with the calendar. Called by World as the year turns; the
## three parameters are a multiplier on the living ground's colour, how far
## the meadow has gone over to straw, and how hard the winter is biting.
func set_season(tint: Color, dryness: float, frost: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("season_tint",
			Vector3(tint.r, tint.g, tint.b))
	_material.set_shader_parameter("season_dry", clampf(dryness, 0.0, 1.0))
	_material.set_shader_parameter("season_frost", clampf(frost, 0.0, 1.0))


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(Config.WORLD_SIZE * 1.6, Config.WORLD_SIZE * 1.6)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1

	# A stylised analytic water surface rather than a flat translucent quad:
	# it drifts, it turns to sky at a grazing angle and darkens when looked
	# straight down into, and it carries a thread of foam on the crests. None
	# of it reads the depth buffer or any render target, so it behaves the same
	# on the Compatibility renderer as anywhere else.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/water.gdshader")
	mat.set_shader_parameter("color_body",
			Config.COLOR_WATER.srgb_to_linear())
	mat.set_shader_parameter("color_surface",
			Color(0.24, 0.44, 0.46).srgb_to_linear())
	mat.set_shader_parameter("color_foam",
			Color(0.80, 0.85, 0.83).srgb_to_linear())

	_water = MeshInstance3D.new()
	_water.name = "water"
	_water.mesh = plane
	_water.material_override = mat
	_water.position = Vector3(Config.WORLD_SIZE * 0.5, Config.SEA_LEVEL,
							  Config.WORLD_SIZE * 0.5)
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water)


## Rebuild the chunks overlapping a world-space rectangle. Called after a
## building flattens its pad.
func rebuild_region(centre: Vector3, half_w: float, half_d: float) -> void:
	var span := Config.WORLD_SIZE / CHUNKS
	var i0 := clampi(int((centre.x - half_w) / span), 0, CHUNKS - 1)
	var i1 := clampi(int((centre.x + half_w) / span), 0, CHUNKS - 1)
	var j0 := clampi(int((centre.z - half_d) / span), 0, CHUNKS - 1)
	var j1 := clampi(int((centre.z + half_d) / span), 0, CHUNKS - 1)
	for cj in range(j0, j1 + 1):
		for ci in range(i0, i1 + 1):
			_chunks[cj * CHUNKS + ci].mesh = _build_chunk_mesh(ci, cj)


## Analytic ray/terrain intersection.
##
## Marching the heightmap is cheaper and more reliable than giving 74k
## triangles a collision shape, and it lets the cursor read the ground even
## where a building sits on top of it.
func raycast(origin: Vector3, direction: Vector3,
			 max_distance: float = 4000.0) -> Dictionary:
	var step := Config.CELL * 0.5
	var t := 0.0
	var prev := origin
	var prev_diff := origin.y - _hm.height_at(origin.x, origin.z)

	while t < max_distance:
		t += step
		var p := origin + direction * t
		if p.y > 200.0 and direction.y > 0.0:
			break
		var diff := p.y - _hm.height_at(p.x, p.z)
		if diff <= 0.0 and prev_diff > 0.0:
			# Bisect for a clean hit point.
			var lo := prev
			var hi := p
			for _i in 8:
				var mid := (lo + hi) * 0.5
				if mid.y - _hm.height_at(mid.x, mid.z) > 0.0:
					lo = mid
				else:
					hi = mid
			var hit := (lo + hi) * 0.5
			hit.y = _hm.height_at(hit.x, hit.z)
			return {"hit": true, "position": hit,
					"normal": _hm.normal_at(hit.x, hit.z)}
		prev = p
		prev_diff = diff
		# Longer strides once we are clearly above the ground.
		step = clampf(diff * 0.6, Config.CELL * 0.5, 24.0)
	return {"hit": false}
