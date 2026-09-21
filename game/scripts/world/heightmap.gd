class_name Heightmap
extends RefCounted

## The terrain elevation field, plus the derived surface classification
## (water / marsh / grass / forest / rock) every other system queries.
##
## Heights live in a flat PackedFloat32Array on the nav grid, one sample per
## cell corner, so terrain, navigation and building placement all agree on what
## the ground is doing without resampling noise.

const N := Config.GRID + 1   # corner samples per side

enum Surface { WATER, MARSH, GRASS, FOREST, ROCK }

var grid_size := Config.GRID
var n := N
var world_size := Config.WORLD_SIZE
var generation_version := 1

var heights := PackedFloat32Array()
var surface := PackedByteArray()
var fertility := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()


func generate(seed_value: int, size_m: float = Config.WORLD_SIZE, version: int = 1) -> void:
	world_size = size_m
	grid_size = roundi(size_m / Config.CELL)
	n = grid_size + 1
	generation_version = version
	edits.clear()
	if version >= 2:
		_generate_geography(seed_value)
		return
	_rng.seed = seed_value
	heights.resize(n * n)
	surface.resize(grid_size * grid_size)
	fertility.resize(grid_size * grid_size)

	var ridge := FastNoiseLite.new()
	ridge.seed = seed_value
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge.frequency = 0.0022
	ridge.fractal_octaves = 5
	ridge.fractal_gain = 0.48

	var detail := FastNoiseLite.new()
	detail.seed = seed_value + 17
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 0.011
	detail.fractal_octaves = 3

	var moisture := FastNoiseLite.new()
	moisture.seed = seed_value + 91
	moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	moisture.frequency = 0.0035
	moisture.fractal_octaves = 3

	var half := world_size * 0.5

	for j in n:
		for i in n:
			var wx := i * Config.CELL
			var wz := j * Config.CELL

			# Base relief: rolling country that rises toward the north-west,
			# which is where the design doc puts the stone and iron.
			var nx := (wx - half) / half
			var nz := (wz - half) / half
			var rise := clampf((-nz * 0.65 - nx * 0.45), -1.0, 1.0)

			var h := 6.0
			h += ridge.get_noise_2d(wx, wz) * 17.0
			h += detail.get_noise_2d(wx, wz) * 2.6
			h += rise * 13.0

			# A shallow basin in the south-east holds the lake, and the
			# ground flattens toward it so the shoreline is gentle.
			var basin := clampf((nz * 0.8 + nx * 0.5), 0.0, 1.0)
			h = lerpf(h, 1.2 + ridge.get_noise_2d(wx * 0.5, wz * 0.5) * 1.5,
					  smoothstep(0.35, 0.95, basin) * 0.8)

			# Flatten the very centre: the keep needs somewhere to stand.
			var d_centre := Vector2(wx - half, wz - half).length()
			var flat := 1.0 - smoothstep(30.0, 110.0, d_centre)
			h = lerpf(h, 9.5, flat * 0.85)

			heights[j * n + i] = h

	_classify(moisture)


func _classify(moisture: FastNoiseLite) -> void:
	for cz in grid_size:
		for cx in grid_size:
			var idx := cz * grid_size + cx
			var h := cell_height(cx, cz)
			var s := cell_slope(cx, cz)
			var wx := (cx + 0.5) * Config.CELL
			var wz := (cz + 0.5) * Config.CELL
			var wet := moisture.get_noise_2d(wx, wz) * 0.5 + 0.5

			var kind := Surface.GRASS
			if h < Config.SEA_LEVEL:
				kind = Surface.WATER
			elif h < Config.SEA_LEVEL + 1.4 and wet > 0.45:
				kind = Surface.MARSH
			elif s > 0.62 or h > 26.0:
				kind = Surface.ROCK
			elif wet > 0.58 and s < 0.45 and h < 24.0:
				kind = Surface.FOREST

			surface[idx] = kind

			# Fertility drives where farms are worth placing: low, flat,
			# reasonably damp ground away from rock.
			var fert := 1.0
			fert *= 1.0 - smoothstep(0.10, 0.40, s)
			fert *= 1.0 - smoothstep(16.0, 28.0, h)
			fert *= smoothstep(0.20, 0.55, wet)
			if kind == Surface.WATER or kind == Surface.ROCK:
				fert = 0.0
			fertility[idx] = clampf(fert, 0.0, 1.0)


# --- Sampling ---------------------------------------------------------------

func corner(i: int, j: int) -> float:
	i = clampi(i, 0, n - 1)
	j = clampi(j, 0, n - 1)
	return heights[j * n + i]


## Height at an arbitrary world position, bilinearly interpolated so units
## walk smoothly rather than stepping between cells.
func height_at(x: float, z: float) -> float:
	var fx := clampf(x / Config.CELL, 0.0, float(n - 1) - 0.0001)
	var fz := clampf(z / Config.CELL, 0.0, float(n - 1) - 0.0001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var h00 := corner(i, j)
	var h10 := corner(i + 1, j)
	var h01 := corner(i, j + 1)
	var h11 := corner(i + 1, j + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func height_at_v(p: Vector3) -> float:
	return height_at(p.x, p.z)


func normal_at(x: float, z: float) -> Vector3:
	var e := Config.CELL * 0.5
	var hl := height_at(x - e, z)
	var hr := height_at(x + e, z)
	var hd := height_at(x, z - e)
	var hu := height_at(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


func cell_height(cx: int, cz: int) -> float:
	return (corner(cx, cz) + corner(cx + 1, cz)
			+ corner(cx, cz + 1) + corner(cx + 1, cz + 1)) * 0.25


## Maximum rise/run across the cell — the number building placement checks.
func cell_slope(cx: int, cz: int) -> float:
	var a := corner(cx, cz)
	var b := corner(cx + 1, cz)
	var c := corner(cx, cz + 1)
	var d := corner(cx + 1, cz + 1)
	var lo: float = min(min(a, b), min(c, d))
	var hi: float = max(max(a, b), max(c, d))
	return (hi - lo) / Config.CELL


func cell_surface(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return Surface.WATER
	return surface[cz * grid_size + cx]


func surface_at(p: Vector3) -> int:
	var c := world_to_cell(p)
	return cell_surface(c.x, c.y)


func cell_fertility(cx: int, cz: int) -> float:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return 0.0
	return fertility[cz * grid_size + cx]


## Base movement multiplier for a cell, before roads are considered.
func surface_speed(cx: int, cz: int) -> float:
	match cell_surface(cx, cz):
		Surface.WATER: return Config.SPEED_WATER
		Surface.MARSH: return Config.SPEED_MARSH
		Surface.FOREST: return Config.SPEED_FOREST
		Surface.ROCK: return Config.SPEED_ROCK
		_: return Config.SPEED_GRASS


func is_passable(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return false
	if cell_surface(cx, cz) == Surface.WATER:
		return false
	return cell_slope(cx, cz) <= 0.95


## Flatten a footprint to a single height — what happens when a building is
## sited on uneven ground (design doc 6.1).
## Every flattening this map has been through, in order.
##
## Placing a building permanently reshapes the ground under it, and pulling the
## building down does not put the ground back. A save that recorded only the
## surviving buildings therefore came back to a different landscape: the pads
## of demolished structures reappeared as hillside, and the buildings next to
## them were re-seated on ground that no longer matched. The terrain is still
## derived rather than stored — this is the list of edits to replay over it.
var edits: Array = []


func capture() -> Array:
	return edits.duplicate()


func _has_edit(centre: Vector3, half_w: float, half_d: float) -> bool:
	for e in edits:
		if (is_equal_approx(e["x"], centre.x)
				and is_equal_approx(e["z"], centre.z)
				and is_equal_approx(e["half_w"], half_w)
				and is_equal_approx(e["half_d"], half_d)):
			return true
	return false


func apply_state(saved: Array) -> void:
	edits.clear()
	for e in saved:
		flatten(Vector3(float(e["x"]), 0.0, float(e["z"])),
				float(e["half_w"]), float(e["half_d"]))


func flatten(centre: Vector3, half_w: float, half_d: float) -> float:
	# Flattening the same pad twice is not the same as flattening it once: the
	# apron is a blend, so a second pass pulls it further in. That matters
	# because loading a save replays the edit list and *then* re-places the
	# buildings that made it. Repeating an edit already in the list returns the
	# level without touching the ground again, which keeps a march the same
	# shape however many times it is saved and reloaded.
	# Recorded without the height: flattening only ever reads the horizontal
	# extent, and a restored building arrives with its ground level already
	# baked into the position it is placed at, which would otherwise make the
	# same pad look like a new one.
	var repeat := _has_edit(centre, half_w, half_d)
	if not repeat:
		edits.append({"x": centre.x, "z": centre.z,
				"half_w": half_w, "half_d": half_d})
	var i0 := clampi(int(floor((centre.x - half_w) / Config.CELL)), 0, n - 1)
	var i1 := clampi(int(ceil((centre.x + half_w) / Config.CELL)), 0, n - 1)
	var j0 := clampi(int(floor((centre.z - half_d) / Config.CELL)), 0, n - 1)
	var j1 := clampi(int(ceil((centre.z + half_d) / Config.CELL)), 0, n - 1)

	var total := 0.0
	var count := 0
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			total += heights[j * n + i]
			count += 1
	var target: float = total / maxf(1.0, float(count))
	if repeat:
		return target

	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			# Blend rather than snap, so the pad meets the surrounding
			# ground in a shallow apron instead of a cliff.
			var dx := absf(i * Config.CELL - centre.x) / maxf(half_w, 0.001)
			var dz := absf(j * Config.CELL - centre.z) / maxf(half_d, 0.001)
			var t := 1.0 - smoothstep(0.85, 1.45, maxf(dx, dz))
			var k := j * n + i
			heights[k] = lerpf(heights[k], target, t)
	return target


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(clampi(floori(p.x / Config.CELL), 0, grid_size - 1),
			clampi(floori(p.z / Config.CELL), 0, grid_size - 1))


## Versioned regional geography: winding connected drainage, parallel ridges
## broken by broad passes, and a guaranteed fertile clearing at the start.
## Physical feature widths remain in metres as the region gets larger.
func _generate_geography(seed_value: int) -> void:
	heights.resize(n * n)
	surface.resize(grid_size * grid_size)
	fertility.resize(grid_size * grid_size)
	var detail := FastNoiseLite.new()
	detail.seed = seed_value
	detail.frequency = 0.006
	detail.fractal_octaves = 3
	var moisture := FastNoiseLite.new()
	moisture.seed = seed_value + 91
	moisture.frequency = 0.006
	moisture.fractal_octaves = 2
	var phase := float(posmod(seed_value, 997)) / 997.0 * TAU
	var half := world_size * 0.5
	var river_start := half - 210.0
	for j in n:
		var z := j * Config.CELL
		var river_x := river_centre(z, phase)
		var ridge_shift := sin(z / 220.0 + phase) * 46.0
		var pass_distance := absf(fposmod(z - half + 384.0, 768.0) - 384.0)
		var pass_strength := smoothstep(32.0, 125.0, pass_distance)
		for i in n:
			var x := i * Config.CELL
			var ridge_distance := absf(fposmod(x - half + 230.0 + ridge_shift, 768.0) - 384.0)
			var ridge := (1.0 - smoothstep(0.0, 115.0, ridge_distance))
			var h := 11.0 + detail.get_noise_2d(x, z) * 4.0
			h += ridge * ridge * (8.0 + 50.0 * pass_strength)
			# One continuous meandering river drains to the southern outlet.
			# A rounded headwater permits a legible overland detour upstream.
			var river_distance := Vector2(x - river_x, minf(0.0, z - river_start)).length()
			# A river cuts a broad low valley through the ridge first, then
			# its channel. This leaves real dry approaches on both banks;
			# carving sea-level water straight into a summit made cliffs.
			h = lerpf(h, 8.5, 1.0 - smoothstep(44.0, 145.0, river_distance))
			h = lerpf(0.3, h, smoothstep(9.0, 36.0, river_distance))
			# Connected tributaries add additional valleys in larger regions.
			if world_size >= 1536.0:
				var tributary_z := half + 310.0 + sin(x / 190.0 + phase) * 42.0
				var join_x := river_centre(tributary_z, phase)
				if x <= join_x:
					var branch_distance := Vector2(maxf(0.0, world_size * 0.18 - x), z - tributary_z).length()
					h = lerpf(h, 8.5, 1.0 - smoothstep(40.0, 130.0, branch_distance))
					h = lerpf(0.3, h, smoothstep(7.0, 32.0, branch_distance))
			var from_start := Vector2(x - half, z - half).length()
			h = lerpf(h, 10.0, 1.0 - smoothstep(85.0, 135.0, from_start))
			heights[j * n + i] = h
	_classify(moisture)
	# Fertile, clear plots are available before scouting or trade. This is
	# generation data, so old seeds and their saves retain their old ground.
	for cz in range(maxi(0, grid_size / 2 - 22), mini(grid_size, grid_size / 2 + 22)):
		for cx in range(maxi(0, grid_size / 2 - 22), mini(grid_size, grid_size / 2 + 22)):
			var idx := cz * grid_size + cx
			var distance := Vector2((cx + 0.5) * Config.CELL - half,
					(cz + 0.5) * Config.CELL - half).length()
			if cell_slope(cx, cz) < 0.25 and distance < 85.0:
				surface[idx] = Surface.GRASS
				fertility[idx] = lerpf(fertility[idx], 0.85,
						1.0 - smoothstep(58.0, 85.0, distance))


func river_centre(z: float, phase: float) -> float:
	return world_size * 0.5 + 190.0 + sin(z / 170.0 + phase) * 44.0
