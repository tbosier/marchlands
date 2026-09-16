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

const RES := Config.WEAR_RES

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
	wear.resize(RES * RES)
	locked.resize(RES * RES)
	_is_active.resize(RES * RES)
	_is_dirty_texel.resize(RES * RES)
	_protected.resize(RES * RES)
	nav_level.resize(Config.GRID * Config.GRID)
	_image = Image.create(RES, RES, false, Image.FORMAT_RGBA8)
	_image.fill(Color(0, 0, 0, 0))
	_pixels = _image.get_data()
	_texture = ImageTexture.create_from_image(_image)


func texture() -> ImageTexture:
	return _texture


## Bake static per-cell data the shader wants (fertility) into the green
## channel once at startup.
func bake_fertility(hm: Heightmap) -> void:
	for y in RES:
		for x in RES:
			var cx := x / Config.WEAR_SCALE
			var cz := y / Config.WEAR_SCALE
			_pixels[(y * RES + x) * 4 + 1] = int(
					clampf(hm.cell_fertility(cx, cz), 0.0, 1.0) * 255.0)
	_upload()


func _upload() -> void:
	_image.set_data(RES, RES, false, Image.FORMAT_RGBA8, _pixels)
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
	var x1 := mini(RES - 1, int(ceil(fx + r)))
	var y0 := maxi(0, int(floor(fz - r)))
	var y1 := mini(RES - 1, int(ceil(fz + r)))
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
			var idx := y * RES + x
			if _protected[idx] != 0:
				continue
			wear[idx] += amount * w * w
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
	var x1 := mini(RES - 1, int(ceil((centre.x + half) / Config.WEAR_CELL)) - 1)
	var y0 := maxi(0, int(floor((centre.z - half) / Config.WEAR_CELL)))
	var y1 := mini(RES - 1, int(ceil((centre.z + half) / Config.WEAR_CELL)) - 1)
	if x0 > x1 or y0 > y1:
		return
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var idx := y * RES + x
			_protected[idx] = 1 if value else 0
			if value and clear_existing and wear[idx] > 0.0:
				# Clear whatever track had already formed here.
				wear[idx] = 0.0
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
	if x < 0 or y < 0 or x >= RES or y >= RES:
		return 0.0
	return wear[y * RES + x]


func wear_at(wx: float, wz: float) -> float:
	var x := clampi(int(wx / Config.WEAR_CELL), 0, RES - 1)
	var y := clampi(int(wz / Config.WEAR_CELL), 0, RES - 1)
	return wear[y * RES + x]


## Road level under a world position — what a mover's speed is scaled by.
func road_level_at(wx: float, wz: float) -> int:
	return Config.road_level_for_wear(wear_at(wx, wz))


func road_level_of_cell(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= Config.GRID or cz >= Config.GRID:
		return Config.RoadLevel.NATURAL
	return nav_level[cz * Config.GRID + cx]


## The road level a cell *should* be at, worked out from the wear field itself
## rather than read from `nav_level`.
##
## `road_level_of_cell` returns the cache the pathfinder is built from, which
## is the right answer to ask during play and the wrong one to check the cache
## against. This is the independent measurement.
func level_from_wear(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= Config.GRID or cz >= Config.GRID:
		return Config.RoadLevel.NATURAL
	return Config.road_level_for_wear(peak_wear_in_cell(cx, cz))


## Strongest wear anywhere under a nav cell. Nav costs use the best surface in
## the cell so a path narrower than the cell still speeds travel up.
func peak_wear_in_cell(cx: int, cz: int) -> float:
	var best := 0.0
	var bx := cx * Config.WEAR_SCALE
	var by := cz * Config.WEAR_SCALE
	for y in range(by, by + Config.WEAR_SCALE):
		for x in range(bx, bx + Config.WEAR_SCALE):
			best = maxf(best, wear[y * RES + x])
	return best


func speed_multiplier_at(wx: float, wz: float) -> float:
	return Config.ROAD_SPEED[road_level_at(wx, wz)]


# --- Player intervention (design doc 7.3) -----------------------------------

## Raise every cell in the route cluster containing `origin` to `level`, and
## lock it there. Returns the number of texels changed.
##
## Only ground that already carries a path is eligible, which is what makes
## organic routes cheaper than commissioning a road from nothing: the player
## is paying to improve a route the settlement has already proven it wants.
func upgrade_route(origin: Vector3, level: int, max_texels: int = 20000) -> int:
	var start := Vector2i(
		clampi(int(origin.x / Config.WEAR_CELL), 0, RES - 1),
		clampi(int(origin.z / Config.WEAR_CELL), 0, RES - 1)
	)
	# Follow the route, not the trampled ground around it. The fill is limited
	# to ground at least as well used as the spot the player picked, so
	# upgrading a track through a settlement improves the track rather than
	# paving the whole village green.
	var from_level := Config.road_level_for_wear(
			wear[start.y * RES + start.x])
	if from_level < Config.RoadLevel.WORN:
		return 0
	var min_wear: float = Config.ROAD_THRESHOLD[from_level] * 0.92

	var target: float = Config.ROAD_THRESHOLD[level] * 1.04
	var seen := {}
	var queue: Array[Vector2i] = [start]
	seen[start] = true
	var changed := 0

	while not queue.is_empty() and changed < max_texels:
		var p: Vector2i = queue.pop_front()
		var idx := p.y * RES + p.x
		if wear[idx] < target:
			wear[idx] = target
		locked[idx] = maxi(locked[idx], level)
		if _is_active[idx] == 0:
			_is_active[idx] = 1
			_active.append(idx)
		_mark_texel(idx)
		_touched_cells[Vector2i(p.x / Config.WEAR_SCALE,
				p.y / Config.WEAR_SCALE)] = true
		changed += 1

		for d in NEIGHBOURS_8:
			var q: Vector2i = p + d
			if q.x < 0 or q.y < 0 or q.x >= RES or q.y >= RES:
				continue
			if seen.has(q):
				continue
			if wear[q.y * RES + q.x] < min_wear:
				continue
			seen[q] = true
			queue.push_back(q)

	# Deliberately does NOT call refresh_levels(): that clears the touched-cell
	# set, so the caller's own refresh returned nothing and the navigation
	# graph never learned about the new road. Paying to upgrade a route looked
	# like it worked and changed nothing about where people walked.
	return changed


## Preview which texels an upgrade would touch, without changing anything.
##
## Walks with the same eight-neighbour connectivity `upgrade_route` fills with.
## Walking four while the fill walked eight meant the panel quoted an extent
## systematically smaller than the stretch the player was about to pay for.
func route_extent(origin: Vector3, max_texels: int = 20000) -> int:
	var start := Vector2i(
		clampi(int(origin.x / Config.WEAR_CELL), 0, RES - 1),
		clampi(int(origin.z / Config.WEAR_CELL), 0, RES - 1)
	)
	var from_level := Config.road_level_for_wear(
			wear[start.y * RES + start.x])
	if from_level < Config.RoadLevel.WORN:
		return 0
	var min_wear: float = Config.ROAD_THRESHOLD[from_level] * 0.92
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	var count := 0
	while not queue.is_empty() and count < max_texels:
		var p: Vector2i = queue.pop_front()
		count += 1
		for d in NEIGHBOURS_8:
			var q: Vector2i = p + d
			if q.x < 0 or q.y < 0 or q.x >= RES or q.y >= RES:
				continue
			if seen.has(q) or wear[q.y * RES + q.x] < min_wear:
				continue
			seen[q] = true
			queue.push_back(q)
	return count


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
		var lock_level := locked[i]
		var floor_wear: float = (Config.ROAD_THRESHOLD[lock_level]
				if lock_level > 0 else 0.0)
		if w <= floor_wear:
			continue
		var level := Config.road_level_for_wear(w)
		var scale: float = maxf(Config.ROAD_THRESHOLD[level], 100.0)
		var new_w: float = maxf(floor_wear,
				w - scale * Config.WEAR_DECAY_PER_DAY * in_game_days)
		if new_w == w:
			continue
		wear[i] = new_w
		_mark_texel(i)
		_touched_cells[Vector2i((i % RES) / Config.WEAR_SCALE,
				(i / RES) / Config.WEAR_SCALE)] = true

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
		var idx: int = c.y * Config.GRID + c.x
		var level := Config.road_level_for_wear(peak_wear_in_cell(c.x, c.y))
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
			_mark_texel(i)
	var changed := rebuild_all_levels()
	flush_texture(true)
	return changed


## Rebuild every nav cell's level from scratch. Only needed after a bulk edit
## that bypassed stamping, such as loading a save.
func rebuild_all_levels() -> Array:
	_touched_cells.clear()
	for cz in Config.GRID:
		for cx in Config.GRID:
			_touched_cells[Vector2i(cx, cz)] = true
	return refresh_levels()


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
	for idx in _dirty_texels:
		# R is the continuous surface level, normalised to 0..1, so each stage
		# of the road occupies an equal band in the shader.
		_pixels[idx * 4] = int(
				Config.road_level_continuous(wear[idx]) * (255.0 / 5.0))
		_pixels[idx * 4 + 2] = int(locked[idx] * (255.0 / 5.0))
		_is_dirty_texel[idx] = 0
	Perf.count("wear.texels_flushed", _dirty_texels.size())
	_dirty_texels.clear()
	_upload()
	Perf.end("wear.flush")
