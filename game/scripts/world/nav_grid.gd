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
## Godot's AStarGrid2D is native code, which keeps a 192x192 graph fast enough
## to repath dozens of citizens without a hierarchical scheme.

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


func setup(hm: Heightmap, wear: WearField) -> void:
	_hm = hm
	_wear = wear
	_blocked.resize(Config.GRID * Config.GRID)
	_node_blocked.resize(Config.GRID * Config.GRID)
	_cultivated.resize(Config.GRID * Config.GRID)

	astar.region = Rect2i(0, 0, Config.GRID, Config.GRID)
	astar.cell_size = Vector2(Config.CELL, Config.CELL)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()

	for cz in Config.GRID:
		for cx in Config.GRID:
			_refresh_cell(cx, cz)


func _refresh_cell(cx: int, cz: int) -> void:
	var p := Vector2i(cx, cz)
	var solid := not _hm.is_passable(cx, cz)
	if not solid:
		var i := cz * Config.GRID + cx
		solid = _blocked[i] > 0 or _node_blocked[i] != 0
	astar.set_point_solid(p, solid)
	if solid:
		return
	astar.set_point_weight_scale(p, _weight(cx, cz))


## Weight is "seconds per metre" relative to open grass: slow ground costs
## more, roads cost less. Slope is folded in so people round hills rather than
## marching over them.
func _weight(cx: int, cz: int) -> float:
	var speed := _hm.surface_speed(cx, cz)
	if speed <= 0.0:
		return 1000.0
	speed *= Config.ROAD_SPEED[_wear.road_level_of_cell(cx, cz)]
	var slope := _hm.cell_slope(cx, cz)
	var slope_penalty := 1.0 + slope * slope * 3.2
	if _cultivated[cz * Config.GRID + cx] != 0:
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
	for cz in Config.GRID:
		for cx in Config.GRID:
			_refresh_cell(cx, cz)


## Block or clear a cell on account of something that is not a building — a
## stone outcrop, say. Absolute, not counted.
func set_blocked(cx: int, cz: int, value: bool) -> void:
	if cx < 0 or cz < 0 or cx >= Config.GRID or cz >= Config.GRID:
		return
	_node_blocked[cz * Config.GRID + cx] = 1 if value else 0
	_refresh_cell(cx, cz)


## Claim (or give back) the cells under a building. Every claim must be paired
## with exactly one release of the same rectangle — placement with demolition,
## and an upgrade releasing the old plan before it claims the new one.
func block_footprint(centre: Vector3, half_w: float, half_d: float,
					 value: bool) -> void:
	var c0 := Config.world_to_cell(centre - Vector3(half_w, 0, half_d))
	var c1 := Config.world_to_cell(centre + Vector3(half_w, 0, half_d))
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var i := cz * Config.GRID + cx
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
	if cx < 0 or cz < 0 or cx >= Config.GRID or cz >= Config.GRID:
		return
	_cultivated[cz * Config.GRID + cx] = 1 if value else 0
	_refresh_cell(cx, cz)


func is_cultivated(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx >= Config.GRID or cz >= Config.GRID:
		return false
	return _cultivated[cz * Config.GRID + cx] != 0


func is_solid(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx >= Config.GRID or cz >= Config.GRID:
		return true
	return astar.is_point_solid(Vector2i(cx, cz))


## Nearest walkable cell to `p`, searched outward. Used when a destination
## sits inside a building footprint or on water.
func nearest_free(p: Vector3, max_radius: int = 12) -> Vector2i:
	var c := Config.world_to_cell(p)
	if not is_solid(c.x, c.y):
		return c
	for r in range(1, max_radius + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var q := Vector2i(c.x + dx, c.y + dz)
				if Config.in_bounds(q) and not is_solid(q.x, q.y):
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


func _find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var a := nearest_free(from)
	var b := nearest_free(to)
	var out := PackedVector3Array()
	if a == b:
		out.append(to)
		return out

	var cells := astar.get_id_path(a, b)
	if cells.is_empty():
		return out

	var points := PackedVector2Array()
	points.append(Vector2(from.x, from.z))
	for i in range(1, cells.size()):
		var c: Vector2i = cells[i]
		points.append(Vector2((c.x + 0.5) * Config.CELL,
							  (c.y + 0.5) * Config.CELL))
	points[points.size() - 1] = Vector2(to.x, to.z)

	for p in _smooth(points):
		out.append(Vector3(p.x, 0.0, p.y))
	return out


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
		if not _shortcut_is_worthwhile(points, anchor, i + 1):
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
	var dist := delta.length()
	var steps := maxi(1, int(dist / (Config.CELL * 0.5)))
	for s in range(steps + 1):
		var t := float(s) / float(steps)
		var p := a + delta * t
		var cx := int(p.x / Config.CELL)
		var cz := int(p.y / Config.CELL)
		if is_solid(cx, cz):
			return false
	return true
