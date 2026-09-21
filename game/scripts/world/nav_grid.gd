class_name NavGrid
extends RefCounted

## Navigation over the world grid.
##
## Cost combines distance with terrain speed and road level, exactly as the
## design doc describes: once a route wears in, travelling it is cheaper, so
## later travellers choose it, so it wears in further. That feedback loop is
## the whole point, so road level changes must actually reweight the graph —
## `apply_road_changes` is what closes it.
##
## Godot's native A* explores a route corridor rather than scanning the map.
## Large worlds cache connectivity queries and bound smoothing work per
## waypoint; small legacy maps keep their original component-label behavior.
## The 6144m benchmark exercises both memory use and a distant route.

var grid_size := Config.GRID
var _bridges: Dictionary = {}
var _deck_cells: Dictionary = {}
var _reach_cache: Dictionary = {}
var _reach_revision := -1

var astar := AStarGrid2D.new()
var _hm: Heightmap
var _wear: WearField
## How many building footprints currently claim each cell. A count rather than
## a flag because footprints overlap: two houses may legally stand close enough
## to share a 4 m cell, and with a flag, pulling either one down unblocked the
## cell belonging to the other — citizens then walked straight through the
## building still standing.
var _blocked := PackedInt32Array()
## Static obstacles that are not buildings: the stone and iron outcrops laid
## down when the world is generated. Set absolutely rather than counted, since
## a cell either holds an outcrop or does not.
var _node_blocked := PackedByteArray()
## Worked ground — crops, mostly. Passable, because the people who farm it have
## to get to it, but expensive enough that anyone merely passing by goes round.
var _cultivated := PackedByteArray()
## Changes only when walkability changes, so cached routes react immediately
## to construction while ordinary road reweighting keeps its usual cadence.
var revision := 0
var _component_revision := -1
var _components := PackedInt32Array()
var _next_component := 0


func setup(hm: Heightmap, wear: WearField) -> void:
	_hm = hm
	grid_size = hm.grid_size
	_wear = wear
	_blocked.resize(grid_size * grid_size)
	_node_blocked.resize(grid_size * grid_size)
	_cultivated.resize(grid_size * grid_size)
	_blocked.fill(0)
	_node_blocked.fill(0)
	_cultivated.fill(0)
	revision += 1

	astar.region = Rect2i(0, 0, grid_size, grid_size)
	astar.cell_size = Vector2(Config.CELL, Config.CELL)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()

	for cz in grid_size:
		for cx in grid_size:
			_refresh_cell(cx, cz)


func _refresh_cell(cx: int, cz: int) -> void:
	var p := Vector2i(cx, cz)
	var solid := not _hm.is_passable(cx, cz) and not _deck_cells.has(p)
	if not solid:
		var i := cz * grid_size + cx
		solid = _blocked[i] > 0 or _node_blocked[i] != 0
	if astar.is_point_solid(p) != solid:
		revision += 1
	astar.set_point_solid(p, solid)
	if solid:
		return
	astar.set_point_weight_scale(p, _weight(cx, cz))


## Weight is "seconds per metre" relative to open grass: slow ground costs
## more, roads cost less. Slope is folded in so people round hills rather than
## marching over them.
func _weight(cx: int, cz: int) -> float:
	var speed := surface_speed(cx, cz)
	if speed <= 0.0:
		return 1000.0
	speed *= Config.ROAD_SPEED[_wear.road_level_of_cell(cx, cz)]
	var slope := 0.0 if _deck_cells.has(Vector2i(cx, cz)) else _hm.cell_slope(cx, cz)
	var slope_penalty := 1.0 + slope * slope * 3.2
	if _cultivated[cz * grid_size + cx] != 0:
		slope_penalty *= Config.CULTIVATED_COST
	return clampf(slope_penalty / speed, 0.05, 1000.0)


func apply_road_changes(cells: Array) -> void:
	for c in cells:
		_refresh_cell(c.x, c.y)


## Re-derive every cell from the ground as it stands now.
##
## Incremental refreshes are driven by wear changing, which is the only thing
## that moves during play. Loading a save moves everything at once — the
## terrain is flattened under each restored building after the roads are laid
## down — so the incremental path has nothing to react to and the whole grid
## has to be rebuilt. Two hundred thousand cells, once, on load.
func rebuild_all() -> void:
	for cz in grid_size:
		for cx in grid_size:
			_refresh_cell(cx, cz)


## Block or clear a cell on account of something that is not a building — a
## stone outcrop, say. Absolute, not counted.
func set_blocked(cx: int, cz: int, value: bool) -> void:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return
	_node_blocked[cz * grid_size + cx] = 1 if value else 0
	_refresh_cell(cx, cz)


## Claim (or give back) the cells under a building. Every claim must be paired
## with exactly one release of the same rectangle — placement with demolition,
## and an upgrade releasing the old plan before it claims the new one.
func block_footprint(centre: Vector3, half_w: float, half_d: float,
					 value: bool) -> void:
	var c0 := world_to_cell(centre - Vector3(half_w, 0, half_d))
	var c1 := world_to_cell(centre + Vector3(half_w, 0, half_d))
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var i := cz * grid_size + cx
			_blocked[i] = maxi(0, _blocked[i] + (1 if value else -1))
			_refresh_cell(cx, cz)


## The pathfinding weight currently in force for a cell. Exposed so tests can
## assert that a road actually changed the graph, rather than only that it
## changed colour.
func weight_at(cx: int, cz: int) -> float:
	if is_solid(cx, cz):
		return INF
	return astar.get_point_weight_scale(Vector2i(cx, cz))


func expected_weight(cx: int, cz: int) -> float:
	return _weight(cx, cz)


func set_cultivated(cx: int, cz: int, value: bool) -> void:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return
	_cultivated[cz * grid_size + cx] = 1 if value else 0
	_refresh_cell(cx, cz)


func is_cultivated(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return false
	return _cultivated[cz * grid_size + cx] != 0


func is_solid(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return true
	return astar.is_point_solid(Vector2i(cx, cz))


## Nearest walkable cell to `p`, searched outward. Used when a destination
## sits inside a building footprint or on water.
func nearest_free(p: Vector3, max_radius: int = 12) -> Vector2i:
	var c := world_to_cell(p)
	if not is_solid(c.x, c.y):
		return c
	for r in range(1, max_radius + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var q := Vector2i(c.x + dx, c.y + dz)
				if in_bounds(q) and not is_solid(q.x, q.y):
					return q
	return c


# --- Path queries -----------------------------------------------------------

## A world-space path from `from` to `to`, smoothed so citizens walk lines
## rather than grid staircases. Returns [] when unreachable.
func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	Perf.begin("nav.path")
	Perf.count("nav.paths")
	var result := _find_path(from, to)
	Perf.end("nav.path")
	return result


## Route length weighted by actual walking speed. Slope and cultivation guide
## route choice, but do not slow the citizen, so their A* penalties must not be
## mistaken for extra travel time when planning a meal break.
func travel_cost(from: Vector3, to: Vector3) -> float:
	var path := find_path(from, to)
	if path.is_empty():
		return INF
	var cost := 0.0
	var previous := Vector2(from.x, from.z)
	for point in path:
		var next := Vector2(point.x, point.z)
		var distance := previous.distance_to(next)
		var steps := maxi(1, ceili(distance / (Config.CELL * 0.5)))
		for i in steps:
			var sample := previous.lerp(next, (i + 0.5) / float(steps))
			var cell := world_to_cell(Vector3(sample.x, 0.0, sample.y))
			var speed := surface_speed(cell.x, cell.y) \
					* _wear.speed_multiplier_at(sample.x, sample.y)
			if speed <= 0.0:
				return INF
			cost += distance / float(steps) / speed
		previous = next
	return cost


func _find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var a := nearest_free(from)
	var b := nearest_free(to)
	var out := PackedVector3Array()
	if is_solid(a.x, a.y) or is_solid(b.x, b.y):
		return out
	# Keep the resolved destination: restoring the original blocked point
	# here made the final path segment walk straight into buildings or water.
	var end := to
	if is_solid(world_to_cell(to).x, world_to_cell(to).y):
		end = Config.cell_to_world(b)
	if a == b:
		out.append(end)
		return out

	var cells := astar.get_id_path(a, b)
	if cells.is_empty():
		return out

	var points := PackedVector2Array()
	points.append(Vector2(from.x, from.z))
	# Keep both endpoint cell centres before smoothing. A diagonal from an
	# arbitrary position inside the first/last cell can clip its solid neighbour
	# even when the centre-to-centre A* edge is valid.
	for i in cells.size():
		var c: Vector2i = cells[i]
		points.append(Vector2((c.x + 0.5) * Config.CELL,
							  (c.y + 0.5) * Config.CELL))
	points.append(Vector2(end.x, end.z))

	for p in _smooth(points):
		out.append(Vector3(p.x, 0.0, p.y))
	return out


## Connectivity is independent of road costs. Cache connected regions instead
## of running an A* search for every possible granary on every meal tick.
func can_reach(from: Vector3, to: Vector3) -> bool:
	# Large regions do not flood-fill millions of cells in GDScript when one
	# nearby citizen asks about a granary. Native A* touches the route corridor;
	# repeated meal/job queries cache connectivity until walkability changes.
	if grid_size > Config.GRID:
		if _reach_revision != revision:
			_reach_cache.clear()
			_reach_revision = revision
		var start := nearest_free(from)
		var end := nearest_free(to)
		var key := Vector4i(start.x, start.y, end.x, end.y)
		if not _reach_cache.has(key):
			if _reach_cache.size() > 8192:
				_reach_cache.clear()
			_reach_cache[key] = not is_solid(start.x, start.y) and not is_solid(end.x, end.y) and not astar.get_id_path(start, end).is_empty()
		return _reach_cache[key]
	var a := nearest_free(from)
	var b := nearest_free(to)
	if is_solid(a.x, a.y) or is_solid(b.x, b.y):
		return false
	if _component_revision != revision:
		_components.resize(grid_size * grid_size)
		_components.fill(-1)
		_next_component = 0
		_component_revision = revision
	var ai := a.y * grid_size + a.x
	var bi := b.y * grid_size + b.x
	if _components[ai] < 0:
		_label_component(a)
	return _components[ai] == _components[bi]


func _label_component(start: Vector2i) -> void:
	var label := _next_component
	_next_component += 1
	var pending: Array[Vector2i] = [start]
	_components[start.y * grid_size + start.x] = label
	var index := 0
	while index < pending.size():
		var c := pending[index]
		index += 1
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var q := c + Vector2i(dx, dz)
				if is_solid(q.x, q.y):
					continue
				# Match AStarGrid2D's AT_LEAST_ONE_WALKABLE diagonal rule.
				if dx != 0 and dz != 0 and is_solid(c.x + dx, c.y) \
						and is_solid(c.x, c.y + dz):
					continue
				var qi := q.y * grid_size + q.x
				if _components[qi] >= 0:
					continue
				_components[qi] = label
				pending.append(q)


## String-pulling: drop a waypoint only when the shortcut is both walkable and
## no more expensive than the route it replaces.
##
## Testing only for impassable ground was actively destructive: A* would pick
## its way along a road, and smoothing would then replace that with a straight
## line across the marsh beside it, throwing away the entire reason the road
## existed. The cost check is what keeps the shortcut honest.
func _smooth(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() <= 2:
		return points
	var out := PackedVector2Array()
	out.append(points[0])
	var anchor := 0
	var i := 1
	while i < points.size() - 1:
		if (grid_size > Config.GRID and i - anchor >= 24) or not _shortcut_is_worthwhile(points, anchor, i + 1):
			out.append(points[i])
			anchor = i
		i += 1
	out.append(points[points.size() - 1])
	return out


## True when going straight from `a` to `b` is passable and costs no more than
## following the waypoints between them.
func _shortcut_is_worthwhile(points: PackedVector2Array, a: int,
							 b: int) -> bool:
	if not _clear_line(points[a], points[b]):
		return false
	var direct := _line_cost(points[a], points[b])
	if direct == INF:
		return false
	var along := 0.0
	for i in range(a, b):
		along += _line_cost(points[i], points[i + 1])
		if along == INF:
			return true
	# A little slack, or floating-point noise leaves the staircase in place.
	return direct <= along * 1.02


## Travel cost of a straight segment, using the same per-cell weights A* uses.
func _line_cost(a: Vector2, b: Vector2) -> float:
	var delta := b - a
	var dist := delta.length()
	if dist < 0.001:
		return 0.0
	var steps := maxi(1, int(dist / (Config.CELL * 0.5)))
	var seg := dist / float(steps)
	var total := 0.0
	for s in range(steps):
		var p := a + delta * ((s + 0.5) / float(steps))
		var cx := int(p.x / Config.CELL)
		var cz := int(p.y / Config.CELL)
		if is_solid(cx, cz):
			return INF
		total += seg * _weight(cx, cz)
	return total


func _clear_line(a: Vector2, b: Vector2) -> bool:
	var delta := b - a
	var c := Vector2i(floori(a.x / Config.CELL), floori(a.y / Config.CELL))
	var end := Vector2i(floori(b.x / Config.CELL), floori(b.y / Config.CELL))
	if is_solid(c.x, c.y):
		return false
	var step_x := int(signf(delta.x))
	var step_z := int(signf(delta.y))
	var dt_x := INF if step_x == 0 else Config.CELL / absf(delta.x)
	var dt_z := INF if step_z == 0 else Config.CELL / absf(delta.y)
	var next_x := INF if step_x == 0 else (
			(c.x + (1 if step_x > 0 else 0)) * Config.CELL - a.x) / delta.x
	var next_z := INF if step_z == 0 else (
			(c.y + (1 if step_z > 0 else 0)) * Config.CELL - a.y) / delta.y
	# Visit every crossed cell. Sampling every two metres missed short clips
	# across obstacle corners and could let a citizen slip through a closed wall.
	while c != end:
		# A negative-direction segment ending exactly on a grid boundary
		# belongs to the cell on that boundary's positive side. Do not step
		# past that endpoint while crossing the other axis's final boundary.
		if c.x == end.x:
			next_x = INF
		if c.y == end.y:
			next_z = INF
		if absf(next_x - next_z) < 0.0000001:
			if is_solid(c.x + step_x, c.y) and is_solid(c.x, c.y + step_z):
				return false
			c += Vector2i(step_x, step_z)
			next_x += dt_x
			next_z += dt_z
		elif next_x < next_z:
			c.x += step_x
			next_x += dt_x
		else:
			c.y += step_z
			next_z += dt_z
		if is_solid(c.x, c.y):
			return false
	return true


func world_to_cell(p: Vector3) -> Vector2i:
	return _hm.world_to_cell(p)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size


func surface_speed(cx: int, cz: int) -> float:
	if _deck_cells.has(Vector2i(cx, cz)):
		return Config.SPEED_GRASS
	return _hm.surface_speed(cx, cz)


func bridge_id_at(cell: Vector2i) -> int:
	return int(_deck_cells.get(cell, -1))


func surface_height_at(x: float, z: float) -> float:
	if _hm == null:
		return 0.0
	var id := bridge_id_at(world_to_cell(Vector3(x, 0, z)))
	if id < 0:
		return _hm.height_at(x, z)
	var rec: Dictionary = _bridges[id]
	var a: Vector3 = rec.a
	var b: Vector3 = rec.b
	var delta := Vector2(b.x - a.x, b.z - a.z)
	var t := clampf(Vector2(x - a.x, z - a.z).dot(delta) / maxf(delta.length_squared(), 0.001), 0.0, 1.0)
	return lerpf(a.y, b.y, t)


func install_bridge(id: int, a: Vector3, b: Vector3, width: float = 4.0) -> void:
	remove_bridge(id)
	var cells: Array[Vector2i] = []
	var c0 := world_to_cell(Vector3(minf(a.x, b.x) - width, 0, minf(a.z, b.z) - width))
	var c1 := world_to_cell(Vector3(maxf(a.x, b.x) + width, 0, maxf(a.z, b.z) + width))
	var start := Vector2(a.x, a.z)
	var end := Vector2(b.x, b.z)
	for z in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			var cell := Vector2i(x, z)
			var centre := Vector2((x + 0.5) * Config.CELL, (z + 0.5) * Config.CELL)
			# Rasterize the navigable deck at cell resolution. The conservative
			# half-cell margin keeps diagonal spans continuous on the nav grid.
			var nearest := Geometry2D.get_closest_point_to_segment(centre, start, end)
			if nearest.distance_to(centre) <= maxf(width * 0.5, Config.CELL * 0.72):
				_deck_cells[cell] = id
				cells.append(cell)
	_bridges[id] = {"a": a, "b": b, "width": width, "cells": cells}
	for cell in cells:
		_refresh_cell(cell.x, cell.y)
	revision += 1


func remove_bridge(id: int) -> void:
	if not _bridges.has(id):
		return
	var cells: Array = _bridges[id].cells
	_bridges.erase(id)
	for cell in cells:
		if _deck_cells.get(cell, -1) == id:
			_deck_cells.erase(cell)
		_refresh_cell(cell.x, cell.y)
	revision += 1
