extends "res://tests/long_run.gd"

## Whole-world integration: paid crossing, actual trade, staged saves and bounds.
func _length(path: PackedVector3Array) -> float:
	var result := 0.0
	for i in range(1, path.size()): result += path[i - 1].distance_to(path[i])
	return result


func _crossing(game: SeededGame, from: Vector3, to: Vector3) -> Dictionary:
	var world := game.world
	var baseline := _length(world.nav.find_path(from, to))
	var best := {}
	var saved := 10.0
	for z in range(world.grid_size / 2 - 42, world.grid_size / 2 + 20, 4):
		var first := -1
		var last := -1
		for x in range(world.grid_size / 2 + 20, mini(world.grid_size - 1, world.grid_size / 2 + 90)):
			if world.heightmap.cell_surface(x, z) == Heightmap.Surface.WATER:
				if first < 0: first = x
				last = x
		if first < 0: continue
		for setback in range(1, 5):
			var a := Config.cell_to_world(Vector2i(first - setback, z))
			var b := Config.cell_to_world(Vector2i(last + setback, z))
			var q: Dictionary = game.sim.bridges.quote(a, b)
			if not q.ok: continue
			world.install_bridge(9999, q.a, q.b)
			var shorter := _length(world.nav.find_path(from, to))
			world.remove_bridge(9999)
			if baseline - shorter > saved:
				saved = baseline - shorter
				best = q
				best.saved_route = saved
	return best


func _step_game(game: SeededGame) -> void:
	game.sim.tick(0.25)
	game.clock.elapsed_days += 0.25 / Config.DAY_LENGTH


func _settle_roads(game: SeededGame) -> void:
	# Match the public save action's settlement of the derived road cache.
	var changed := game.world.wear.refresh_levels()
	if not changed.is_empty(): game.world.nav.apply_road_changes(changed)


func _run() -> void:
	var game := _new_game(42)
	var previous := game.world
	_check(game.new_world(42, 1234) != "" and game.world == previous,
			"unsupported new-world size preserves the active settlement")
	_check(game.new_world(SaveGame.Validation.MAX_SEED + 1, 768) != "" and game.world == previous
			and game.new_world(-SaveGame.Validation.MAX_SEED - 1, 768) != "" and game.world == previous,
			"out-of-range integer seeds cannot replace the active settlement")
	var error := game.new_world(42, 768)
	_check(error == "" and game.world.generation_version == 2 and game.world.size_m == 768,
			"new march selects versioned river geography: " + error)
	if error != "":
		game.free(); quit(1); return
	game.sim.campaign.personality = "peaceful"
	var observer: Citizen = game.sim.citizens[0]
	var home_position := observer.global_position
	observer.global_position = game.sim.campaign.rival_position
	game.sim.scouting.refresh_visibility()
	observer.global_position = home_position
	game.sim.scouting.refresh_visibility()
	var market := _build(game, "market", game.world.centre() + Vector3(-45, 0, -20))
	game.sim.keep.inventory[Config.Res.TIMBER] = 240.0
	game.sim.keep.inventory[Config.Res.TOOLS] = 80.0
	game.sim.keep.inventory[Config.Res.FOOD] = 400.0
	var target: Building = game.sim.campaign.trade_store()
	_check(market != null and target != null, "new geography has an accessible finite-stock trading neighbor")
	if market == null or target == null:
		game.free(); quit(1); return
	var from := game.sim.entrance_of(market, "att_cart_bay")
	var to: Vector3 = game.sim.campaign._door(target)
	var initial_route := _length(game.world.nav.find_path(from, to))
	var q := _crossing(game, from, to)
	_check(not q.is_empty(), "a river crossing shortens the actual market-to-neighbor journey")
	if q.is_empty():
		game.free(); quit(1); return
	var result: Dictionary = game.sim.bridges.place(q.a, q.b)
	_check(result.ok, "river bridge order uses funded construction: " + result.reason)
	var bridge_id := int(result.get("id", -1))
	for i in 15000:
		if game.sim.bridges.info(bridge_id).get("complete", false): break
		_step_game(game)
	_check(game.sim.bridges.info(bridge_id).get("complete", false), "real civilian deliveries and work complete the generated river bridge")
	var shorter := _length(game.world.nav.find_path(from, to))
	_check(shorter + 10 < initial_route, "completed bridge makes the trading journey measurably shorter")
	var midpoint: Vector3 = (q.a + q.b) * 0.5
	_settle_roads(game)
	var baseline := SaveGame.capture(game)
	var harness: Node = load("res://scripts/core/harness.gd").new()
	harness.game = game
	var fingerprint: Dictionary = harness._fingerprint()
	error = game.restore_from(baseline)
	var drift: Array[String] = harness._state_drift("", fingerprint, harness._fingerprint())
	_check(error == "" and drift.is_empty() and game.world.bridge_id_at(midpoint.x, midpoint.z) == bridge_id,
			"full staged save restores new geography, paid bridge and exact independent state: " + error + str(drift))
	var people := game.sim.population_members().size()
	var stock_before := game.sim.stores.total(Config.Res.IRON)
	error = game.sim.trade.dispatch()
	_check(error == "", "citizen caravan can use the completed crossing: " + error)
	var route_id: int = game.sim.trade.caravans.keys()[0] if not game.sim.trade.caravans.is_empty() else -1
	var crossed := false
	var on_deck := true
	var restored_on_trip := false
	for i in 22000:
		if not game.sim.trade.caravans.has(route_id): break
		_step_game(game)
		if not game.sim.trade.caravans.has(route_id): break
		var route: Caravan = game.sim.trade.caravans[route_id]
		var at := route.merchant.global_position
		if game.world.bridge_id_at(at.x, at.z) == bridge_id:
			crossed = true
			on_deck = on_deck and absf(at.y - game.world.surface_height_at(at.x, at.z)) < 0.05
			if not restored_on_trip:
				_settle_roads(game)
				var snap := SaveGame.capture(game)
				var before: Dictionary = harness._fingerprint()
				error = game.restore_from(snap)
				drift = harness._state_drift("", before, harness._fingerprint())
				_check(error == "" and drift.is_empty(), "save mid-crossing retains merchant cargo, reservations and bridge: " + error + str(drift))
				restored_on_trip = true
	_check(crossed and restored_on_trip, "actual trading traffic uses the bridge")
	_check(on_deck, "merchant crosses on the deck rather than walking under water")
	_check(game.sim.trade.caravans.is_empty() and game.sim.population_members().size() == people,
			"full simulation returns the same merchant to the civilian workforce")
	_check(game.sim.stores.total(Config.Res.IRON) >= stock_before + 7.9,
			"imports arrive in settlement stock through the full simulation")
	_check(game.world.wear.wear_at(q.a.x, q.a.z) > 0, "trade and construction traffic wear the bridge approach")
	var bad := SaveGame.capture(game)
	bad.world_settings.size_m = 900
	previous = game.world
	_check(game.restore_from(bad) != "" and game.world == previous, "malformed map dimensions cannot replace a live world")
	for size_m in [1536, 6144]:
		var start := Time.get_ticks_msec()
		error = game.new_world(42, size_m)
		_check(error == "" and game.world.size_m == size_m and game.sim.keep.position.x > 768.0 - 1,
				"new-world lifecycle works beyond legacy bounds at %d m: %s" % [size_m, error])
		var snap := SaveGame.capture(game)
		var keep_at: Vector3 = game.sim.keep.position
		error = game.restore_from(snap)
		_check(error == "" and game.world.size_m == size_m and game.sim.keep.position == keep_at,
				"staged save/load preserves full-sized world at %d m: %s" % [size_m, error])
		print("BENCH staged_world size=%d elapsed_ms=%d memory_mb=%.1f" % [size_m, Time.get_ticks_msec() - start, float(OS.get_static_memory_usage()) / 1048576.0])
	harness.free()
	game.free()
	await process_frame
	print("Connections regression failures: %d" % _failures)
	quit(1 if _failures else 0)
