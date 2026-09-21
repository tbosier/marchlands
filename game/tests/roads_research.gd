extends SceneTree

## tools/godot_env.sh --headless --path game --script res://tests/roads_research.gd

var _failures := 0
var _wallet := {}
var _payments := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		_failures += 1


func _pay(cost: Dictionary) -> bool:
	_payments += 1
	for resource in cost:
		if _wallet.get(resource, 0) < cost[resource]:
			return false
	for resource in cost:
		_wallet[resource] -= cost[resource]
	return true


func _research() -> void:
	var research := RoadResearch.new()
	_check(not research.allows_road_upgrade(Config.RoadLevel.IMPROVED)
			and not research.allows_road_upgrade(Config.RoadLevel.PATH)
			and not research.allows_road_upgrade(Config.RoadLevel.PAVED),
			"all commissioned road surfaces begin locked behind research")
	_check(not research.allows_building_upgrade("house")
			and not research.allows_building_upgrade("granary")
			and not research.allows_building_upgrade("blacksmith")
			and not research.allows_building_upgrade("supply_hut"),
			"civic, forge and fort upgrades begin locked")
	_check(research.start("roadworks", false, _pay) != "" and _payments == 0,
			"an absent market rejects research before requesting payment")
	_check(research.start("paving", true, _pay) != "" and _payments == 0,
			"paving requires completed roadworks before requesting payment")
	_wallet = {Config.Res.TIMBER: 9, Config.Res.STONE: 100, Config.Res.TOOLS: 100}
	var original := _wallet.duplicate()
	var state := research.capture()
	_check(research.start("roadworks", true, _pay) != ""
			and _wallet == original and research.capture() == state,
			"insufficient resources change neither inventories nor research state")
	_wallet[Config.Res.TIMBER] = 100
	_check(research.start("roadworks", true, _pay) == ""
			and _wallet[Config.Res.TIMBER] == 90 and _wallet[Config.Res.STONE] == 95,
			"starting research pays its quoted resources exactly once")
	var paid := _wallet.duplicate()
	var payment_count := _payments
	_check(research.start("civic_building", true, _pay) != "" and _payments == payment_count,
			"busy research cannot start a second project or charge again")
	_check(research.advance(0.0) == "" and research.advance(NAN) == ""
			and research.remaining_days == 2.0,
			"paused and invalid elapsed time do not advance research")
	research.advance(1.5)
	_check(not research.allows_road_upgrade(Config.RoadLevel.IMPROVED)
			and is_equal_approx(research.quote("roadworks", true).progress, 0.75),
			"paid research stays locked until its full duration elapses")
	var restored := RoadResearch.new()
	_check(restored.restore(research.capture()) == "" and restored.capture() == research.capture(),
			"an active paid project round-trips with its exact remaining time")
	_check(restored.advance(0.5) == "roadworks"
			and restored.allows_road_upgrade(Config.RoadLevel.IMPROVED)
			and not restored.allows_road_upgrade(Config.RoadLevel.PAVED) and _wallet == paid,
			"completion after restore unlocks only its technology without another payment")
	_check(restored.start("roadworks", true, _pay) != "" and _payments == payment_count,
			"a completed technology cannot be bought a second time")
	_check(restored.start("paving", true, _pay) == "" and restored.advance(4.0) == "paving"
			and restored.allows_road_upgrade(Config.RoadLevel.PAVED),
			"paving unlocks after its prerequisite, payment and four days")
	_check(restored.start("civic_building", true, _pay) == ""
			and restored.advance(2.0) == "civic_building"
			and restored.allows_building_upgrade("house")
			and restored.allows_building_upgrade("granary")
			and not restored.allows_building_upgrade("blacksmith"),
			"civic research unlocks household and granary upgrades separately from metallurgy")
	_check(restored.start("fortification", true, _pay) == ""
			and restored.advance(3.0) == "fortification"
			and restored.allows_building_upgrade("supply_hut"),
			"fortification unlocks supply-hut upgrades after civic research")
	_check(restored.start("metallurgy", true, _pay) == ""
			and restored.advance(3.0) == "metallurgy"
			and restored.allows_building_upgrade("blacksmith"),
			"metallurgy unlocks the forge through its own paid project")
	var invalid: Array = [
		{"completed": ["paving"], "active": "", "remaining_days": 0.0},
		{"completed": ["roadworks", "roadworks"], "active": "", "remaining_days": 0.0},
		{"completed": ["unknown"], "active": "", "remaining_days": 0.0},
		{"completed": [], "active": "paving", "remaining_days": 1.0},
		{"completed": [], "active": "roadworks", "remaining_days": 3.0},
		{"completed": [], "active": "roadworks", "remaining_days": 0.0},
		{"completed": [], "active": "", "remaining_days": 1.0},
		{"completed": [], "active": "", "remaining_days": NAN},
		{"completed": [], "active": "", "remaining_days": false},
		{"completed": "roadworks", "active": "", "remaining_days": 0.0},
	]
	state = restored.capture()
	var rejected := true
	for data in invalid:
		rejected = rejected and restored.restore(data) != "" and restored.capture() == state
	_check(rejected, "invalid research saves are rejected without changing existing progress")
	_check(restored.restore({}) == "" and restored.completed.is_empty() and restored.active == "",
			"legacy saves default to unresearched technology")


func _at(x: int, y: int) -> Vector3:
	return Vector3((x + 0.5) * Config.WEAR_CELL, 0.0, (y + 0.5) * Config.WEAR_CELL)


func _set_wear(wear: WearField, x: int, y: int, value: float) -> void:
	wear.wear[y * WearField.RES + x] = value


func _connected(cells: PackedInt32Array) -> bool:
	if cells.is_empty():
		return false
	var available := {}
	for index in cells:
		available[index] = true
	var reached := {cells[0]: true}
	var queue := PackedInt32Array([cells[0]])
	var head := 0
	while head < queue.size():
		var index := queue[head]
		head += 1
		var p := Vector2i(index % WearField.RES, index / WearField.RES)
		for direction in WearField.NEIGHBOURS_8:
			var next := p + direction
			var next_index := next.y * WearField.RES + next.x
			if available.has(next_index) and not reached.has(next_index):
				reached[next_index] = true
				queue.append(next_index)
	return reached.size() == cells.size()


func _contains_all(outer: PackedInt32Array, inner: PackedInt32Array) -> bool:
	for cell in inner:
		if not outer.has(cell):
			return false
	return true


func _roads() -> void:
	var wear := WearField.new()
	for x in range(20, 100):
		_set_wear(wear, x, 50, 500.0 + 50.0 * x)
	for y in range(51, 82):
		_set_wear(wear, 35, y, 500.0)
		_set_wear(wear, 75, y, 1500.0)
	_set_wear(wear, 180, 180, 50000.0) # A busier, disconnected island cannot be selected.
	wear.apply_state(wear.capture())
	var origin := _at(20, 50)
	var small := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "busiest")
	var medium := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "local")
	var whole := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "all")
	_check(small.count == ceili(142 * 0.20) and medium.count == 71 and whole.count == 142,
			"usage scopes quote twenty, fifty and one hundred percent of the connected network")
	_check(_connected(small.route_cells) and _connected(medium.route_cells)
			and _connected(whole.route_cells), "every scope is connected")
	_check(_contains_all(medium.route_cells, small.route_cells)
			and _contains_all(whole.route_cells, medium.route_cells),
			"broader scopes contain the entire smaller selection")
	_check(small.cells.has(50 * WearField.RES + 99)
			and not whole.cells.has(180 * WearField.RES + 180),
			"selection begins on the strongest connected backbone and ignores detached islands")
	_check(small.area_m2 == small.count * Config.WEAR_CELL * Config.WEAR_CELL
			and small.cost[Config.Res.STONE] < medium.cost[Config.Res.STONE]
			and medium.cost[Config.Res.STONE] < whole.cost[Config.Res.STONE],
			"larger changed areas quote proportionally larger material costs")
	var previous_wear := wear.wear.duplicate()
	_check(wear.apply_upgrade(small) == small.count and wear.wear == previous_wear,
			"applying a quote changes exactly its cells without inflating traffic counts")
	var changed_count := 0
	for level in wear.locked:
		changed_count += int(level == Config.RoadLevel.IMPROVED)
	_check(changed_count == small.count and wear.validate_upgrade(small) != ""
			and wear.apply_upgrade(small) == 0,
			"an already applied quote cannot upgrade or charge the same cells twice")
	var repeated := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "busiest")
	_check(repeated.count == 0 and repeated.area_m2 == 0.0 and repeated.cost.is_empty(),
			"unchanged surfaces have an empty, zero-cost quote")
	var remainder := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "all")
	_check(remainder.count == whole.count - small.count and _connected(remainder.route_cells),
			"existing upgrades remain connected but are excluded from the larger area's charge")
	var quote := wear.preview_upgrade(origin, Config.RoadLevel.PAVED, "all")
	var traffic := _at(40, 50)
	wear.stamp_point(traffic.x, traffic.z, 1000.0, 0.4)
	_check(wear.validate_upgrade(quote) == "", "ordinary traffic increases preserve a quoted price and area")
	var saved_locks := wear.locked.duplicate()
	var tampered := quote.duplicate(true)
	tampered.cost[Config.Res.STONE] = 0
	_check(wear.validate_upgrade(tampered) != "" and wear.apply_upgrade(tampered) == 0
			and wear.locked == saved_locks, "a mismatched road price is rejected before any surface changes")
	wear.set_protected(_at(60, 50), Config.WEAR_CELL * 0.49, true)
	_check(wear.validate_upgrade(quote) != "" and wear.apply_upgrade(quote) == 0,
			"a newly protected connector invalidates the old quote atomically")
	_check(wear.preview_upgrade(_at(60, 50), Config.RoadLevel.PAVED).count == 0,
			"protected ground cannot be commissioned as a road")


func _natural_and_saved_surfaces() -> void:
	var wear := WearField.new()
	var p := _at(30, 30)
	wear.stamp_point(p.x, p.z, Config.ROAD_THRESHOLD[Config.RoadLevel.PAVED] * 20.0, 0.4)
	wear.refresh_levels()
	_check(wear.road_level_at(p.x, p.z) == Config.RoadLevel.DIRT
			and wear.road_level_of_cell(15, 15) == Config.RoadLevel.DIRT
			and wear.speed_multiplier_at(p.x, p.z) == Config.ROAD_SPEED[Config.RoadLevel.DIRT],
			"even extreme traffic stops at dirt in both movement and navigation")
	var quote := wear.preview_upgrade(p, Config.RoadLevel.PAVED)
	wear.apply_upgrade(quote)
	wear.decay(100000.0)
	wear.refresh_levels()
	_check(wear.wear_at(p.x, p.z) == 0.0 and wear.road_level_at(p.x, p.z) == Config.RoadLevel.PAVED,
			"paid paving survives when its traffic history decays away")
	var restored := WearField.new()
	restored.apply_state(wear.capture())
	_check(restored.road_level_of_cell(15, 15) == Config.RoadLevel.PAVED
			and restored.speed_multiplier_at(p.x, p.z) == Config.ROAD_SPEED[Config.RoadLevel.PAVED],
			"saved paid surfaces restore navigation and walking speed independently of raw wear")
	restored.flush_texture(true)
	# Headless dummy textures do not retain GPU updates; inspect the image
	# passed to the renderer so this still verifies the uploaded surface data.
	var pixel := restored._image.get_pixel(30, 30)
	_check(pixel.r == 1.0, "the restored terrain texture also displays the paid paved surface")
	var illegal := restored.preview_upgrade(Vector3(-1, 0, 2), Config.RoadLevel.PAVED)
	_check(illegal.error != "" and restored.apply_upgrade(illegal) == 0,
			"out-of-bounds proposals are rejected instead of clamped onto another route")


func _large_network() -> void:
	var wear := WearField.new()
	for y in range(10, 120):
		for x in range(10, 210):
			_set_wear(wear, x, y, 800.0)
	var origin := _at(10, 10)
	var quote := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "all")
	_check(quote.count == 22000 and wear.route_extent(origin, 6000) == 22000,
			"all connected routes includes more than both former preview and application limits")
	_check(wear.apply_upgrade(quote) == 22000,
			"the complete quoted network is exactly the network that gets upgraded")


func _run() -> void:
	_research()
	_roads()
	_natural_and_saved_surfaces()
	_large_network()
	print("Road research regression failures: %d" % _failures)
	quit(1 if _failures else 0)
