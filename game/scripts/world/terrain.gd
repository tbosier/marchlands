class_name Terrain
extends Node3D

## Builds and owns the visible ground: a chunked mesh generated from the
## heightmap, plus the water plane.
##
## Chunking exists for two reasons: frustum culling, and the ability to rebuild
## only the region a building flattened rather than the whole 192x192 field.

const CHUNKS := 8
const CHUNK_CELLS := Config.GRID / CHUNKS
## Decorative ground continues beyond the simulation grid and meets the sea.
## It never contributes cells, resources or placement targets.
const BACKDROP_WIDTH := 512.0
const BACKDROP_FLOOR := Config.SEA_LEVEL - 32.0
## Beyond the camera's 2200 m far plane, including its orbit outside the map.
const WATER_MARGIN := 3000.0

var _hm: Heightmap
var _wear: WearField
var chunk_cells := CHUNK_CELLS
var chunks := CHUNKS
var _detail_chunks: Dictionary = {}
var _detail_materials: Dictionary = {}
var _shore_chunks: Dictionary = {}
var _detail_update := 0.0
var _last_focus := Vector2i(-9999, -9999)
var _material: ShaderMaterial
var _chunks: Array[MeshInstance3D] = []
var _water: MeshInstance3D
var _backdrop: MeshInstance3D
var _seabed: MeshInstance3D


func build(hm: Heightmap, wear: WearField) -> void:
	_hm = hm
	_wear = wear
	if hm.grid_size > Config.GRID:
		chunk_cells = WearField.TILE_TEXELS / Config.WEAR_SCALE
		chunks = hm.grid_size / chunk_cells

	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/terrain.gdshader")
	_material.set_shader_parameter("wear_map", wear.texture())
	_material.set_shader_parameter("fertility_map", wear.fertility_texture())
	_material.set_shader_parameter("world_size", _hm.world_size)
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

	for cj in chunks:
		for ci in chunks:
			var mi := MeshInstance3D.new()
			mi.name = "chunk_%d_%d" % [ci, cj]
			mi.mesh = _build_chunk_mesh(ci, cj, 1 if _hm.grid_size == Config.GRID else 4)
			mi.material_override = _material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if _hm.grid_size > Config.GRID:
				mi.visibility_range_end = 1700.0
			add_child(mi)
			_chunks.append(mi)

	_backdrop = MeshInstance3D.new()
	_backdrop.name = "boundary_landscape"
	_backdrop.mesh = _build_backdrop_mesh()
	_backdrop.material_override = _material
	add_child(_backdrop)
	_build_water()
	if _hm.grid_size > Config.GRID:
		update_detail(Vector3(_hm.world_size * 0.5, 0, _hm.world_size * 0.5), true)


## The camera uses this same continuation when its orbit crosses the boundary.
static func presentation_height(hm: Heightmap, x: float, z: float) -> float:
	var inside := Vector2(clampf(x, 0.0, hm.world_size),
			clampf(z, 0.0, hm.world_size))
	var beyond := Vector2(x, z).distance_to(inside)
	var edge_height := hm.height_at(inside.x, inside.y)
	return lerpf(edge_height, BACKDROP_FLOOR,
			smoothstep(0.0, BACKDROP_WIDTH, beyond))


func _build_backdrop_mesh() -> ArrayMesh:
	# Keep every boundary sample: a coarse skirt would leave cracks where it
	# skips a hill between corners. Only the off-map spacing grows coarser.
	var axis := PackedFloat32Array([-512, -256, -128, -64, -32, -16, -8])
	for i in _hm.n:
		axis.append(i * Config.CELL)
	for offset in [8, 16, 32, 64, 128, 256, 512]:
		axis.append(_hm.world_size + offset)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_ids: Dictionary = {}
	for j in axis.size() - 1:
		for i in axis.size() - 1:
			if axis[i] >= 0.0 and axis[i + 1] <= _hm.world_size \
					and axis[j] >= 0.0 and axis[j + 1] <= _hm.world_size:
				continue
			var quad: Array[int] = []
			for grid in [Vector2i(i, j), Vector2i(i + 1, j),
					Vector2i(i, j + 1), Vector2i(i + 1, j + 1)]:
				if not vertex_ids.has(grid):
					var x := axis[grid.x]
					var z := axis[grid.y]
					var h := presentation_height(_hm, x, z)
					var normal := Vector3(
							presentation_height(_hm, x - 2.0, z) - presentation_height(_hm, x + 2.0, z),
							4.0,
							presentation_height(_hm, x, z - 2.0) - presentation_height(_hm, x, z + 2.0)).normalized()
					if x >= 0.0 and x <= _hm.world_size and z >= 0.0 and z <= _hm.world_size:
						h = _hm.corner(roundi(x / Config.CELL), roundi(z / Config.CELL))
						normal = _hm.normal_at(x, z)
					vertex_ids[grid] = verts.size()
					verts.append(Vector3(x, h, z))
					normals.append(normal)
				quad.append(vertex_ids[grid])
			indices.append_array([quad[0], quad[3], quad[2], quad[0], quad[1], quad[3]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_chunk_mesh(ci: int, cj: int, stride: int = 1) -> ArrayMesh:
	# A 16 m sample grid can bridge over an 18 m river, creating visible dams
	# and disconnected tributaries as the camera moves. Keep bank geometry at
	# simulation resolution; broad inland terrain can still use coarse meshes.
	if stride > 1 and _contains_shore(ci, cj):
		stride = 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var i0 := ci * chunk_cells
	var j0 := cj * chunk_cells
	var divisions := chunk_cells / stride
	var n := divisions + 1

	for j in n:
		for i in n:
			var gi := i0 + i * stride
			var gj := j0 + j * stride
			var x := gi * Config.CELL
			var z := gj * Config.CELL
			var y := _hm.corner(gi, gj)
			verts.append(Vector3(x, y, z))
			normals.append(_hm.normal_at(x, z))
			uvs.append(Vector2(x / _hm.world_size, z / _hm.world_size))

	for j in divisions:
		for i in divisions:
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

	if _hm.grid_size > Config.GRID:
		# Fine and coarse neighbours sample the same heightfield at different
		# intervals. Skirts hide the resulting T-junction cracks during LOD
		# transitions without rebuilding neighbouring chunks or flattening hills.
		var border := PackedInt32Array()
		for x in n:
			border.append(x)
		for y in range(1, n):
			border.append(y * n + n - 1)
		for x in range(n - 2, -1, -1):
			border.append((n - 1) * n + x)
		for y in range(n - 2, 0, -1):
			border.append(y * n)
		var bottom_start := verts.size()
		for top in border:
			verts.append(verts[top] - Vector3.UP * 24.0)
			normals.append(normals[top])
			uvs.append(uvs[top])
		for edge in border.size():
			var next := (edge + 1) % border.size()
			indices.append_array([border[edge], bottom_start + next, border[next],
					border[edge], bottom_start + edge, bottom_start + next])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _contains_shore(ci: int, cj: int) -> bool:
	var key := Vector2i(ci, cj)
	if _shore_chunks.has(key): return _shore_chunks[key]
	var wet := false
	var dry := false
	for z in range(cj * chunk_cells, (cj + 1) * chunk_cells + 1):
		for x in range(ci * chunk_cells, (ci + 1) * chunk_cells + 1):
			var height := _hm.corner(x, z)
			wet = wet or height < Config.SEA_LEVEL
			dry = dry or height >= Config.SEA_LEVEL
			if wet and dry:
				_shore_chunks[key] = true
				return true
	_shore_chunks[key] = false
	return false


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
	for mat in _detail_materials.values():
		mat.set_shader_parameter("season_tint", Vector3(tint.r, tint.g, tint.b))
		mat.set_shader_parameter("season_dry", clampf(dryness, 0.0, 1.0))
		mat.set_shader_parameter("season_frost", clampf(frost, 0.0, 1.0))


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * (_hm.world_size + WATER_MARGIN * 2.0)
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
	_water.position = Vector3(_hm.world_size * 0.5, Config.SEA_LEVEL,
							  _hm.world_size * 0.5)
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water)
	# Transparent water needs a real bed outside the heightfield too; otherwise
	# the sky shows through it and reveals where the terrain mesh stops.
	var bed := PlaneMesh.new()
	bed.size = plane.size
	var bed_mat := StandardMaterial3D.new()
	bed_mat.albedo_color = Config.COLOR_WATER.darkened(0.45)
	bed_mat.roughness = 1.0
	_seabed = MeshInstance3D.new()
	_seabed.name = "seabed"
	_seabed.mesh = bed
	_seabed.material_override = bed_mat
	_seabed.position = Vector3(_hm.world_size * 0.5,
			BACKDROP_FLOOR - 8.0, _hm.world_size * 0.5)
	_seabed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_seabed)


## Rebuild the chunks overlapping a world-space rectangle. Called after a
## building flattens its pad.
func rebuild_region(centre: Vector3, half_w: float, half_d: float) -> void:
	var span := _hm.world_size / chunks
	var i0 := clampi(int((centre.x - half_w) / span), 0, chunks - 1)
	var i1 := clampi(int((centre.x + half_w) / span), 0, chunks - 1)
	var j0 := clampi(int((centre.z - half_d) / span), 0, chunks - 1)
	var j1 := clampi(int((centre.z + half_d) / span), 0, chunks - 1)
	for cj in range(j0, j1 + 1):
		for ci in range(i0, i1 + 1):
			_shore_chunks.erase(Vector2i(ci, cj))
			_chunks[cj * chunks + ci].mesh = _build_chunk_mesh(ci, cj,
					1 if _hm.grid_size == Config.GRID or _detail_chunks.has(Vector2i(ci, cj)) else 4)
	if i0 == 0 or j0 == 0 or i1 == chunks - 1 or j1 == chunks - 1:
		_backdrop.mesh = _build_backdrop_mesh()


## Analytic ray/terrain intersection.
##
## Marching the heightmap is cheaper and more reliable than giving 74k
## triangles a collision shape, and it lets the cursor read the ground even
## where a building sits on top of it.
func raycast(origin: Vector3, direction: Vector3,
			 max_distance: float = 4000.0) -> Dictionary:
	# Clip the ray to the playable square. height_at() clamps outside samples;
	# treating that clamped height as ground invented selectable land off-map.
	var start := 0.0
	for axis in [0, 2]:
		if absf(direction[axis]) < 0.000001:
			if origin[axis] < 0.0 or origin[axis] > _hm.world_size:
				return {"hit": false}
			continue
		var a := -origin[axis] / direction[axis]
		var b := (_hm.world_size - origin[axis]) / direction[axis]
		start = maxf(start, minf(a, b))
		max_distance = minf(max_distance, maxf(a, b))
	if start >= max_distance:
		return {"hit": false}
	var step := Config.CELL * 0.5
	var t := start
	var prev := origin + direction * start
	var prev_diff := prev.y - _hm.height_at(prev.x, prev.z)

	while t < max_distance:
		t = minf(t + step, max_distance)
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


func _process(delta: float) -> void:
	if _hm == null or _hm.grid_size == Config.GRID:
		return
	_detail_update += delta
	if _detail_update < 0.2:
		return
	_detail_update = 0.0
	var camera := get_viewport().get_camera_3d()
	if camera:
		update_detail(camera.global_position)


## High detail follows the camera; distant chunks have 1/16 the triangles.
## Only two chunks are rebuilt in one frame after a camera move. The world
## retains a complete coarse surface while its new close view is populated.
func update_detail(focus: Vector3, immediate: bool = false) -> void:
	if _hm.grid_size == Config.GRID:
		return
	var span := chunk_cells * Config.CELL
	var centre := Vector2i(floori(focus.x / span), floori(focus.z / span))
	if centre == _last_focus:
		return
	var wanted := {}
	for z in range(maxi(0, centre.y - 2), mini(chunks, centre.y + 3)):
		for x in range(maxi(0, centre.x - 2), mini(chunks, centre.x + 3)):
			wanted[Vector2i(x, z)] = true
	for tile in _detail_chunks.keys():
		if wanted.has(tile):
			continue
		_chunks[tile.y * chunks + tile.x].mesh = _build_chunk_mesh(tile.x, tile.y, 4)
		_chunks[tile.y * chunks + tile.x].material_override = _material
		_detail_chunks.erase(tile)
		_detail_materials.erase(tile)
		_wear.release_tile(tile)
	var built := 0
	for tile in wanted:
		if _detail_chunks.has(tile):
			continue
		var mesh := _chunks[tile.y * chunks + tile.x]
		mesh.mesh = _build_chunk_mesh(tile.x, tile.y)
		var mat := _material.duplicate() as ShaderMaterial
		mat.set_shader_parameter("wear_map", _wear.tile_texture(tile))
		mat.set_shader_parameter("wear_origin", Vector2(tile.x * span - Config.WEAR_CELL,
				tile.y * span - Config.WEAR_CELL))
		mat.set_shader_parameter("wear_size", span + Config.WEAR_CELL * 2.0)
		mesh.material_override = mat
		_detail_materials[tile] = mat
		_detail_chunks[tile] = true
		built += 1
		if not immediate and built >= 2:
			return
	_last_focus = centre
