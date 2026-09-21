class_name WearField
extends RefCounted

## The world's memory of movement (design doc 2.1, 7.1, 24).
##
## Every moving entity stamps wear into a fine-grained field as it travels.
## Where wear accumulates past a threshold the ground changes state: grass
## wears, a footpath appears, a footpath becomes a dirt track. Those states
## feed both the terrain shader (what you see) and the navigation weights
## (where people prefer to walk), which is what makes useful routes reinforce
## themselves.
##
## Two resolutions are in play:
##   * the *wear* field, at WEAR_CELL metres, is what gets stamped and drawn;
##   * the *nav* grid, at CELL metres, takes the strongest wear beneath it.
## Paths therefore look like paths rather than like 4 m blocks, while
## pathfinding stays cheap.

signal road_levels_changed(cells: Array)

const RES := Config.WEAR_RES # legacy callers
var res := RES
var grid_size := Config.GRID
var world_size := Config.WORLD_SIZE
const TILE_TEXELS := 96
var _tiles: Dictionary = {}
var _hm: Heightmap

const NEIGHBOURS_4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]
const NEIGHBOURS_8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]

var wear := PackedFloat32Array()
## Player-commissioned surfaces. A cell never decays below its locked level.
var locked := PackedByteArray()
## Cached road level per nav cell, so systems do not rescan the fine field.
var nav_level := PackedByteArray()
## Used-route connectivity changes invalidate a quote; ordinary extra traffic
## does not change the already quoted cells or price.
var route_revision := 0

const SCOPE_FRACTIONS := {"busiest": 0.20, "local": 0.50, "all": 1.0}
const COST_PER_M2 := {
	Config.RoadLevel.WORN: {Config.Res.TIMBER: 0.005},
	Config.RoadLevel.PATH: {Config.Res.TIMBER: 0.01, Config.Res.STONE: 0.005},
	Config.RoadLevel.DIRT: {Config.Res.TIMBER: 0.015, Config.Res.STONE: 0.015},
	Config.RoadLevel.IMPROVED: {Config.Res.TIMBER: 0.02, Config.Res.STONE: 0.03},
	Config.RoadLevel.PAVED: {Config.Res.TIMBER: 0.01, Config.Res.STONE: 0.06},
}

var _image: Image
var _texture: ImageTexture
## The texture's raw RGBA8 bytes, written directly. Image.set_pixel costs a
## Variant round-trip per texel, which is ruinous when a full-field decay
## touches 147k of them.
var _pixels := PackedByteArray()
var _dirty_texels := PackedInt32Array()
var _is_dirty_texel := PackedByteArray()

## Indices that have ever been stamped. Decay walks this instead of the whole
## field, because the overwhelming majority of the world is never walked on.
var _active := PackedInt32Array()
var _is_active := PackedByteArray()
## Ground that refuses to record traffic — crops, chiefly. A farmer crossing
## their own field should not wear a road through it.
var _protected := PackedByteArray()

## Nav cells whose texels changed since the last level refresh.
var _touched_cells: Dictionary = {}

## Uploading the whole texture is the fixed cost here, so it is rate-limited.
const UPLOAD_INTERVAL_MS := 60
var _last_upload_ms := 0


func _init() -> void:
	setup()


func setup(size_m: float = Config.WORLD_SIZE) -> void:
	world_size = size_m
	grid_size = roundi(size_m / Config.CELL)
	res = grid_size * Config.WEAR_SCALE
	_tiles.clear()
	_active.clear()
	_touched_cells.clear()
	_dirty_texels.clear()
	wear.resize(res * res)
	locked.resize(res * res)
	_is_active.resize(res * res)
	_is_dirty_texel.resize(res * res)
	_protected.resize(res * res)
	nav_level.resize(grid_size * grid_size)
	var image_res := res if grid_size == Config.GRID else 1
	_image = Image.create(image_res, image_res, false, Image.FORMAT_RGBA8)
	_image.fill(Color(0, 0, 0, 0))
	_pixels = _image.get_data()
	_texture = ImageTexture.create_from_image(_image)


func texture() -> ImageTexture:
	return _texture


## Bake static per-cell data the shader wants (fertility) into the green
## channel once at startup.
func bake_fertility(hm: Heightmap) -> void:
	_hm = hm
	if grid_size > Config.GRID:
		return
	for y in res:
		for x in res:
			var cx := x / Config.WEAR_SCALE
			var cz := y / Config.WEAR_SCALE
			_pixels[(y * res + x) * 4 + 1] = int(
					clampf(hm.cell_fertility(cx, cz), 0.0, 1.0) * 255.0)
	_upload()


func _upload() -> void:
	if grid_size > Config.GRID:
		return
	_image.set_data(res, res, false, Image.FORMAT_RGBA8, _pixels)
	_texture.update(_image)


# --- Stamping ---------------------------------------------------------------

## Add wear along the segment a->b. `amount` is the per-metre wear rate of the
## traveller (Config.WEAR_*); `radius` is the brush width in metres.
func stamp_segment(a: Vector3, b: Vector3, amount: float, radius: float) -> void:
	var delta := Vector2(b.x - a.x, b.z - a.z)
	var dist := delta.length()
	if dist < 0.0001:
		return
	# One stamp per half-texel keeps the trail continuous at any speed.
	#
	# Stamps land at the *midpoint* of each step. Walking the endpoints instead
	# deposited steps+1 portions of steps-worth of wear, so a segment laid down
	# between 1.3x and 2x the wear it was supposed to — by a factor that
	# depended on how far the citizen had moved since the last stamp, and so on
	# the frame rate and the speed the game was running at. The same journey
	# wore a route in noticeably faster at 1x than at 16x, which is precisely
	# the comparison the headless scenarios make.
	var steps := maxi(1, int(ceil(dist / (Config.WEAR_CELL * 0.5))))
	var per_step := amount * Config.WEAR_GAIN * dist / float(steps)
	for i in steps:
		var t := (float(i) + 0.5) / float(steps)
		stamp_point(a.x + delta.x * t, a.z + delta.y * t, per_step, radius)


func stamp_point(wx: float, wz: float, amount: float, radius: float) -> void:
	var fx := wx / Config.WEAR_CELL
	var fz := wz / Config.WEAR_CELL
	var r := radius / Config.WEAR_CELL
	var x0 := maxi(0, int(floor(fx - r)))
	var x1 := mini(res - 1, int(ceil(fx + r)))
	var y0 := maxi(0, int(floor(fz - r)))
	var y1 := mini(res - 1, int(ceil(fz + r)))
	if x0 > x1 or y0 > y1:
		return

	var inv_r2 := 1.0 / maxf(r * r, 0.0001)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var dx := (x + 0.5) - fx
			var dy := (y + 0.5) - fz
			var d2 := (dx * dx + dy * dy) * inv_r2
			if d2 > 1.0:
				continue
			# Soft falloff: the centre of the track wears fastest.
			var w := (1.0 - d2)
			var idx := y * res + x
			if _protected[idx] != 0:
				continue
			var was_used := _used_route_texel(idx)
			wear[idx] += amount * w * w
			if was_used != _used_route_texel(idx):
				route_revision += 1
			if _is_active[idx] == 0:
				_is_active[idx] = 1
				_active.append(idx)
			_mark_texel(idx)
			_touched_cells[Vector2i(x / Config.WEAR_SCALE,
					y / Config.WEAR_SCALE)] = true


## Mark one texel for re-upload. Tracking individual texels rather than a
## bounding box matters once the settlement is busy: two citizens walking in
## opposite directions used to dirty a rectangle covering everything between
## them, and the flush cost grew with the size of the kingdom rather than with
## the amount that actually changed.
## Protect (or release) a square of ground from recording traffic.
##
## The upper bound is exclusive. Rounding both ends down covered one texel too
## many on each axis, so a 4 m plot claimed 3 texels instead of 2 — and since
## protecting a texel also wipes the wear on it, every change of staffing at a
## farm erased the track along the east and south edges of its field.
## `clear_existing` is what makes laying a field erase the track that ran
## across it. A load must pass false: the wear it has just restored is the
## history the save exists to preserve, and wiping it under every field as the
## farms were re-protected made a reloaded march come back with quieter roads
## than the one that was saved.
func set_protected(centre: Vector3, half: float, value: bool,
				   clear_existing: bool = true) -> void:
	var x0 := maxi(0, int(floor((centre.x - half) / Config.WEAR_CELL)))
	var x1 := mini(res - 1, int(ceil((centre.x + half) / Config.WEAR_CELL)) - 1)
	var y0 := maxi(0, int(floor((centre.z - half) / Config.WEAR_CELL)))
	var y1 := mini(res - 1, int(ceil((centre.z + half) / Config.WEAR_CELL)) - 1)
	if x0 > x1 or y0 > y1:
		return
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var idx := y * res + x
			if bool(_protected[idx]) != value:
				route_revision += 1
			_protected[idx] = 1 if value else 0
			if value and clear_existing and (wear[idx] > 0.0 or locked[idx] > 0):
				# Clear whatever track had already formed here.
				wear[idx] = 0.0
				locked[idx] = 0
				_mark_texel(idx)
				_touched_cells[Vector2i(x / Config.WEAR_SCALE,
						y / Config.WEAR_SCALE)] = true


func _mark_texel(idx: int) -> void:
	if _is_dirty_texel[idx] != 0:
		return
	_is_dirty_texel[idx] = 1
	_dirty_texels.append(idx)


# --- Queries ----------------------------------------------------------------

func wear_at_texel(x: int, y: int) -> float:
	if x < 0 or y < 0 or x >= res or y >= res:
		return 0.0
	return wear[y * res + x]


func wear_at(wx: float, wz: float) -> float:
	var x := clampi(int(wx / Config.WEAR_CELL), 0, res - 1)
	var y := clampi(int(wz / Config.WEAR_CELL), 0, res - 1)
	return wear[y * res + x]


## Road level under a world position — what a mover's speed is scaled by.
func road_level_at(wx: float, wz: float) -> int:
	var x := clampi(int(wx / Config.WEAR_CELL), 0, res - 1)
	var y := clampi(int(wz / Config.WEAR_CELL), 0, res - 1)
	return _level_at_index(y * res + x)


func _level_at_index(index: int) -> int:
	return maxi(locked[index], mini(Config.RoadLevel.DIRT,
			Config.road_level_for_wear(wear[index])))


func road_level_of_cell(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return Config.RoadLevel.NATURAL
	return nav_level[cz * grid_size + cx]


## The road level a cell *should* be at, worked out from the wear field itself
## rather than read from `nav_level`.
##
## `road_level_of_cell` returns the cache the pathfinder is built from, which
## is the right answer to ask during play and the wrong one to check the cache
## against. This is the independent measurement.
func level_from_wear(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= grid_size or cz >= grid_size:
		return Config.RoadLevel.NATURAL
	var best := Config.RoadLevel.NATURAL
	for y in range(cz * Config.WEAR_SCALE, (cz + 1) * Config.WEAR_SCALE):
		for x in range(cx * Config.WEAR_SCALE, (cx + 1) * Config.WEAR_SCALE):
			best = maxi(best, _level_at_index(y * res + x))
	return best


## Strongest wear anywhere under a nav cell. Nav costs use the best surface in
## the cell so a path narrower than the cell still speeds travel up.
func peak_wear_in_cell(cx: int, cz: int) -> float:
	var best := 0.0
	var bx := cx * Config.WEAR_SCALE
	var by := cz * Config.WEAR_SCALE
	for y in range(by, by + Config.WEAR_SCALE):
		for x in range(bx, bx + Config.WEAR_SCALE):
			best = maxf(best, wear[y * res + x])
	return best


func speed_multiplier_at(wx: float, wz: float) -> float:
	return Config.ROAD_SPEED[road_level_at(wx, wz)]


# --- Player intervention (design doc 7.3) -----------------------------------

## Quote a connected portion of the used network. All scopes start at its
## busiest texel and expand through adjacent traffic, making the 20%, 50% and
## 100% selections nested without disconnected islands. Existing surfaces are
## traversed as connectors but only cells whose surface improves are charged.
func preview_upgrade(origin: Vector3, level: int, scope: String = "all") -> Dictionary:
	var result := {"cells": PackedInt32Array(), "route_cells": PackedInt32Array(),
		"count": 0, "area_m2": 0.0, "cost": {}, "level": level, "scope": scope,
		"network_count": 0, "route_revision": route_revision,
		"previous_locked": PackedByteArray(), "error": ""}
	if not SCOPE_FRACTIONS.has(scope) or not COST_PER_M2.has(level):
		result.error = "Invalid road scope or surface"
		return result
	if not origin.is_finite() or origin.x < 0.0 or origin.z < 0.0 \
			or origin.x >= world_size or origin.z >= world_size:
		result.error = "Select a used route inside the map"
		return result
	var start := int(origin.z / Config.WEAR_CELL) * res + int(origin.x / Config.WEAR_CELL)
	var network := _route_network(start)
	result.network_count = network.size()
	if network.is_empty():
		result.error = "Select a used route"
		return result
	var wanted := maxi(1, ceili(network.size() * float(SCOPE_FRACTIONS[scope])))
	var selected := network if wanted == network.size() else _busiest_connected(network, wanted)
	result.route_cells = selected
	var changed := PackedInt32Array()
	var previous := PackedByteArray()
	for index in selected:
		if _level_at_index(index) >= level:
			continue
		changed.append(index)
		previous.append(locked[index])
	result.cells = changed
	result.previous_locked = previous
	result.count = changed.size()
	result.area_m2 = changed.size() * Config.WEAR_CELL * Config.WEAR_CELL
	result.cost = _upgrade_cost(level, result.area_m2)
	return result


func _used_route_texel(index: int) -> bool:
	return _protected[index] == 0 and (wear[index] >= Config.ROAD_THRESHOLD[Config.RoadLevel.WORN]
			or locked[index] > Config.RoadLevel.NATURAL)


func _route_network(start: int) -> PackedInt32Array:
	if not _used_route_texel(start):
		return PackedInt32Array()
	var queue := PackedInt32Array([start])
	var seen := {start: true}
	var head := 0
	while head < queue.size():
		var index := queue[head]
		head += 1
		var x := index % res
		var y := index / res
		for direction in NEIGHBOURS_8:
			var q := Vector2i(x, y) + direction
			if q.x < 0 or q.y < 0 or q.x >= res or q.y >= res:
				continue
			var next := q.y * res + q.x
			if seen.has(next) or not _used_route_texel(next):
				continue
			seen[next] = 1
			queue.append(next)
	return queue


func _busiest_connected(network: PackedInt32Array, wanted: int) -> PackedInt32Array:
	var strongest := network[0]
	for index in network:
		if _busier(index, strongest):
			strongest = index
	var queued := {strongest: true}
	var frontier: Array[int] = [strongest]
	var selected := PackedInt32Array()
	while selected.size() < wanted and not frontier.is_empty():
		var index := _pop_busiest(frontier)
		selected.append(index)
		var x := index % res
		var y := index / res
		for direction in NEIGHBOURS_8:
			var q := Vector2i(x, y) + direction
			if q.x < 0 or q.y < 0 or q.x >= res or q.y >= res:
				continue
			var next := q.y * res + q.x
			if queued.has(next) or not _used_route_texel(next):
				continue
			queued[next] = 1
			_push_busiest(frontier, next)
	return selected


func _busier(a: int, b: int) -> bool:
	return wear[a] > wear[b] or (wear[a] == wear[b] and a < b)


func _push_busiest(heap: Array[int], index: int) -> void:
	heap.append(index)
	var at := heap.size() - 1
	while at > 0:
		var parent := (at - 1) / 2
		if not _busier(heap[at], heap[parent]):
			break
		var swap := heap[parent]
		heap[parent] = heap[at]
		heap[at] = swap
		at = parent


func _pop_busiest(heap: Array[int]) -> int:
	var answer := heap[0]
	var last: int = heap.pop_back()
	if heap.is_empty():
		return answer
	heap[0] = last
	var at := 0
	while at * 2 + 1 < heap.size():
		var child := at * 2 + 1
		if child + 1 < heap.size() and _busier(heap[child + 1], heap[child]):
			child += 1
		if not _busier(heap[child], heap[at]):
			break
		var swap := heap[at]
		heap[at] = heap[child]
		heap[child] = swap
		at = child
	return answer


func _upgrade_cost(level: int, area_m2: float) -> Dictionary:
	var cost := {}
	if area_m2 <= 0.0:
		return cost
	for resource in COST_PER_M2[level]:
		cost[resource] = ceili(area_m2 * float(COST_PER_M2[level][resource]))
	return cost


## Validate before charging. Apply validates again, then changes exactly the
## quoted cells. Traffic may increase while a confirmation panel is open, but
## changed connectivity, protection, or paid surfaces require a fresh quote.
func validate_upgrade(proposal: Dictionary) -> String:
	if proposal.get("error", "") != "":
		return str(proposal.error)
	if not SCOPE_FRACTIONS.has(proposal.get("scope")) or not COST_PER_M2.has(proposal.get("level")):
		return "Invalid road proposal"
	if proposal.get("route_revision", -1) != route_revision:
		return "The route changed; review a fresh quote"
	var cells: Variant = proposal.get("cells")
	var previous: Variant = proposal.get("previous_locked")
	if not cells is PackedInt32Array or not previous is PackedByteArray \
			or cells.size() != previous.size() or proposal.get("count", -1) != cells.size():
		return "Invalid road cells"
	var area: float = cells.size() * Config.WEAR_CELL * Config.WEAR_CELL
	if proposal.get("area_m2", -1.0) != area \
			or proposal.get("cost", {}) != _upgrade_cost(proposal.level, area):
		return "The road cost does not match its area"
	var seen := {}
	for i in cells.size():
		var index: int = cells[i]
		if index < 0 or index >= wear.size() or seen.has(index):
			return "Invalid or repeated road cell"
		seen[index] = true
		if not _used_route_texel(index) or locked[index] != previous[i] \
				or _level_at_index(index) >= int(proposal.level):
			return "The road surface changed; review a fresh quote"
	return ""


func apply_upgrade(proposal: Dictionary) -> int:
	if validate_upgrade(proposal) != "":
		return 0
	for index in proposal.cells:
		locked[index] = proposal.level
		if _is_active[index] == 0:
			_is_active[index] = 1
			_active.append(index)
		_mark_texel(index)
		_touched_cells[Vector2i((index % res) / Config.WEAR_SCALE,
				(index / res) / Config.WEAR_SCALE)] = true
	# The caller refreshes once and hands the changed cells to navigation.
	return proposal.cells.size()


## Compatibility for callers commissioning the complete network. Limits used
## to make the 6,000-cell preview differ from the 20,000-cell paid operation.
func upgrade_route(origin: Vector3, level: int, _max_texels: int = 0) -> int:
	return apply_upgrade(preview_upgrade(origin, level, "all"))


func route_extent(origin: Vector3, _max_texels: int = 0) -> int:
	return int(preview_upgrade(origin, Config.RoadLevel.PAVED, "all").network_count)


# --- Per-tick maintenance ---------------------------------------------------

## Wear fades on ground nobody uses any more, so the map records living
## routes rather than every trip ever made.
func decay(in_game_days: float) -> void:
	if in_game_days <= 0.0:
		return
	Perf.begin("wear.decay")

	for i in _active:
		var w := wear[i]
		if w <= 0.0:
			continue
		var level := mini(Config.RoadLevel.DIRT, Config.road_level_for_wear(w))
		var scale: float = maxf(Config.ROAD_THRESHOLD[level], 100.0)
		var new_w: float = maxf(0.0,
				w - scale * Config.WEAR_DECAY_PER_DAY * in_game_days)
		if new_w == w:
			continue
		var was_used := _used_route_texel(i)
		wear[i] = new_w
		if was_used != _used_route_texel(i):
			route_revision += 1
		_mark_texel(i)
		_touched_cells[Vector2i((i % res) / Config.WEAR_SCALE,
				(i / res) / Config.WEAR_SCALE)] = true

	Perf.count("wear.active", _active.size())
	Perf.end("wear.decay")


## Recompute the per-nav-cell road level and report the cells that changed, so
## the navigation grid can reweight only what moved.
func refresh_levels() -> Array:
	if _touched_cells.is_empty():
		return []
	Perf.begin("wear.levels")
	var changed: Array = []
	for cell in _touched_cells:
		var c: Vector2i = cell
		var idx: int = c.y * grid_size + c.x
		var level := level_from_wear(c.x, c.y)
		if nav_level[idx] != level:
			nav_level[idx] = level
			changed.append(c)
	Perf.count("wear.cells_checked", _touched_cells.size())
	_touched_cells.clear()
	Perf.end("wear.levels")
	if not changed.is_empty():
		road_levels_changed.emit(changed)
	return changed


# --- Persistence ------------------------------------------------------------

## The two fields that are genuinely history: how much the ground has been
## walked on, and which surfaces the player paid to lay. Everything else here
## (the active index, the dirty list, the texture, the per-cell levels) is a
## cache derived from these, and is rebuilt on load.
func capture() -> Dictionary:
	return {"wear": wear.duplicate(), "locked": locked.duplicate()}


## Returns the nav cells whose road level changed, for the caller to hand to
## the pathfinder. The wear field does not know about navigation, and a load
## that quietly skipped this step left every restored road invisible to route
## planning — the settlement looked right and walked as if the roads were not
## there.
func apply_state(data: Dictionary) -> Array:
	var saved_wear: PackedFloat32Array = data.get("wear",
			PackedFloat32Array())
	var saved_locked: PackedByteArray = data.get("locked", PackedByteArray())
	if saved_wear.size() != wear.size():
		push_error("wear field is %d texels, save holds %d — ignoring it"
				% [wear.size(), saved_wear.size()])
		return []

	wear = saved_wear.duplicate()
	if saved_locked.size() == locked.size():
		locked = saved_locked.duplicate()

	# Rebuild the active index the same way stamping would have built it, so
	# decay walks exactly the ground that has been walked on and no more.
	_active.clear()
	for i in wear.size():
		if wear[i] > 0.0 or locked[i] > 0:
			_is_active[i] = 1
			_active.append(i)
			_mark_texel(i)
		else:
			_is_active[i] = 0
			# Mark it even though it is empty. A texel that was worn in this
			# session but is bare in the save would otherwise never be
			# rewritten, and the terrain would keep drawing a road that no
			# longer exists in either the wear field or the nav graph.
			if grid_size == Config.GRID:
				_mark_texel(i)
	_rebake_tiles()
	var changed := rebuild_all_levels()
	flush_texture(true)
	return changed


## Rebuild every nav cell's level from scratch. Only needed after a bulk edit
## that bypassed stamping, such as loading a save.
func rebuild_all_levels() -> Array:
	route_revision += 1
	_touched_cells.clear()
	var changed: Array = []
	for cz in grid_size:
		for cx in grid_size:
			var index := cz * grid_size + cx
			var level := level_from_wear(cx, cz)
			if nav_level[index] != level:
				nav_level[index] = level
				changed.append(Vector2i(cx, cz))
	if not changed.is_empty():
		road_levels_changed.emit(changed)
	return changed


## Push accumulated wear into the texture the terrain shader samples.
##
## Called once per rendered frame, never per simulation step: at 16x the game
## takes many simulation steps between frames, and uploading a 384x384 texture
## on each of them was pure waste — nothing can observe the intermediate
## states. Roads also change far too slowly to need a 60 Hz upload, so this is
## rate-limited as well.
func flush_texture(force: bool = false) -> void:
	if _dirty_texels.is_empty():
		return
	if not force:
		var now := Time.get_ticks_msec()
		if now - _last_upload_ms < UPLOAD_INTERVAL_MS:
			return
		_last_upload_ms = now

	Perf.begin("wear.flush")
	if grid_size > Config.GRID:
		_flush_tiles()
		Perf.end("wear.flush")
		return
	for idx in _dirty_texels:
		# R is the continuous surface level, normalised to 0..1, so each stage
		# of the road occupies an equal band in the shader.
		var natural := minf(Config.RoadLevel.DIRT, Config.road_level_continuous(wear[idx]))
		_pixels[idx * 4] = int(maxf(natural, locked[idx]) * (255.0 / 5.0))
		_pixels[idx * 4 + 2] = int(locked[idx] * (255.0 / 5.0))
		_is_dirty_texel[idx] = 0
	Perf.count("wear.texels_flushed", _dirty_texels.size())
	_dirty_texels.clear()
	_upload()
	Perf.end("wear.flush")


## Large worlds upload only visible road tiles. Simulation remains at the
## same two-metre resolution, and save data is independent of rendering.
func tile_texture(tile: Vector2i) -> ImageTexture:
	if _tiles.has(tile):
		return _tiles[tile].texture
	var size := TILE_TEXELS + 2 # one shared border texel for bilinear filtering
	var pixels := PackedByteArray()
	pixels.resize(size * size * 4)
	for y in size:
		for x in size:
			var wx := clampi(tile.x * TILE_TEXELS + x - 1, 0, res - 1)
			var wy := clampi(tile.y * TILE_TEXELS + y - 1, 0, res - 1)
			var index := wy * res + wx
			var dest := (y * size + x) * 4
			var natural := minf(Config.RoadLevel.DIRT, Config.road_level_continuous(wear[index]))
			pixels[dest] = int(maxf(natural, locked[index]) * 51.0)
			pixels[dest + 2] = int(locked[index] * 51.0)
			if _hm:
				pixels[dest + 1] = int(_hm.cell_fertility(wx / Config.WEAR_SCALE, wy / Config.WEAR_SCALE) * 255.0)
	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, pixels)
	var tex := ImageTexture.create_from_image(image)
	_tiles[tile] = {"texture": tex, "image": image, "pixels": pixels}
	return tex


func release_tile(tile: Vector2i) -> void:
	_tiles.erase(tile)


func _flush_tiles() -> void:
	var dirty := {}
	var size := TILE_TEXELS + 2
	for index in _dirty_texels:
		var x := index % res
		var y := index / res
		var main_tile := Vector2i(x / TILE_TEXELS, y / TILE_TEXELS)
		# Border pixels belong to both adjacent textures.
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var tile := main_tile + Vector2i(dx, dz)
				if not _tiles.has(tile):
					continue
				var local := Vector2i(x, y) - tile * TILE_TEXELS + Vector2i.ONE
				if local.x < 0 or local.y < 0 or local.x >= size or local.y >= size:
					continue
				# Mutate the packed array in place through the dictionary;
				# copying it to a local would trigger copy-on-write per stamp.
				var dest := (local.y * size + local.x) * 4
				var natural := minf(Config.RoadLevel.DIRT, Config.road_level_continuous(wear[index]))
				_tiles[tile].pixels[dest] = int(maxf(natural, locked[index]) * 51.0)
				_tiles[tile].pixels[dest + 2] = int(locked[index] * 51.0)
				dirty[tile] = true
		_is_dirty_texel[index] = 0
	for tile in dirty:
		var rec: Dictionary = _tiles[tile]
		rec.image.set_data(size, size, false, Image.FORMAT_RGBA8, rec.pixels)
		rec.texture.update(rec.image)
	Perf.count("wear.texels_flushed", _dirty_texels.size())
	_dirty_texels.clear()


func _rebake_tiles() -> void:
	# Existing terrain materials keep their texture objects during a load.
	# Refill those objects, including texels which became empty in the save.
	for tile in _tiles.keys():
		var original: ImageTexture = _tiles[tile].texture
		_tiles.erase(tile)
		tile_texture(tile)
		original.update(_tiles[tile].image)
		_tiles[tile].texture = original
