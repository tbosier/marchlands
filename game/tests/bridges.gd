extends "res://tests/navigation.gd"

## Controlled river geography exercises real JobBoard carrying/building and
## the same navigator and pedestrian movement used by a caravan merchant.
var _bridges: Bridges
var _source: Building
var _a := Vector3(198, 9.35, 202)
var _b := Vector3(210, 9.35, 202)


func _river() -> void:
	for z in range(30, 81):
		for x in [50, 51]:
			_world.heightmap.surface[z * _world.grid_size + x] = Heightmap.Surface.WATER
	_world.nav.rebuild_all()
	_bridges = Bridges.new()
	_sim.add_child(_bridges)
	_bridges.setup(_sim, _world, _registry)
	_sim.bridges = _bridges
	_source = _sim.place_building("keep", Vector3(160, 9, 160), 0, true)
	for i in 3:
		var c := _sim.add_citizen(Vector3(185 + i, 9, 185))
		c.next_meal = 1000
		c.speed_scale = 1.0
	_sim._is_night = false


func _step() -> void:
	_bridges.tick(0.1)
	for c in _sim.citizens:
		_sim._tick_citizen(c, 0.1)


func _stock(res: int) -> float:
	var total := _source.inventory[res]
	for c in _sim.citizens:
		if c.carrying_res == res:
			total += c.carrying_amount
	for record in _bridges.bridges.values():
		total += float(record.delivered.get(res, 0.0))
	return total


func _route_length() -> float:
	var path := _world.nav.find_path(_a, _b)
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	return length


func _build() -> int:
	var quote := _bridges.quote(_a, _b)
	_check(quote.ok and quote.detour_saved > 100.0, "bank preview explains a real river detour")
	_check(not _bridges.quote(_a, _a + Vector3(100, 0, 0)).ok, "timber span rejects bridges over 64 metres")
	_check(not _bridges.quote(Vector3(190, 9, 100), Vector3(214, 9, 100)).ok,
		"bridge placement requires water between dry banks")
	_check(not _bridges.place(_a, _b).ok and _bridges.bridges.is_empty(),
		"an unaffordable bridge cannot be commissioned")
	# A finite opening stock pays both construction resources. No resource is
	# gifted after this point, and all conservation checks include carried loads.
	_source.inventory[Config.Res.TIMBER] = 120.0
	_source.inventory[Config.Res.TOOLS] = 20.0
	var before := _route_length()
	var placed := _bridges.place(_a, _b)
	_check(placed.ok, "basic bridge is available without research")
	if not placed.ok:
		return -1
	var id: int = placed.id
	_check(_route_length() == before and _world.nav.is_solid(50, 50),
		"ordering a bridge never opens an unpaid crossing")
	_check(not _bridges.quote(_a, _b).ok, "overlapping construction sites are rejected")
	_check(not _sim.can_place("house", _a - Vector3(8, 0, 0)).ok,
		"later buildings cannot block or flatten bridge approaches")
	var carrying := false
	for i in 1200:
		_step()
		for c in _sim.citizens:
			carrying = carrying or c.carrying_amount > 0.0
		if carrying:
			break
	_check(carrying and _bridges.info(id).work == 0.0,
		"real citizens load materials before any bridge labor begins")
	var saved := _bridges.capture()
	_check(Bridges.validate(saved, _world.size_m) == "" and _bridges.restore(saved) == "",
		"an unfinished bridge restores while goods are in transit")
	_check(_stock(Config.Res.TIMBER) == 120.0 and _stock(Config.Res.TOOLS) == 20.0,
		"restore and reservation release preserve material on carriers")
	var partial := false
	for i in 5000:
		_step()
		var info := _bridges.info(id)
		if info.work > 0 and not partial:
			partial = true
			saved = _bridges.capture()
			var work: float = info.work
			_check(_bridges.restore(saved) == "" and _bridges.info(id).work == work,
				"delivered costs and accumulated bank labor survive a construction save")
		if _bridges.info(id).complete:
			break
	_check(_bridges.info(id).complete and partial, "paid hauling and bank labor finish a real bridge")
	_check(_stock(Config.Res.TIMBER) == 120.0 and _stock(Config.Res.TOOLS) == 20.0,
		"finished bridge accounts for every paid timber and tool")
	_check(not _world.nav.is_solid(50, 50) and _route_length() < before * 0.3,
		"completion opens the bridge and routes traffic over the shorter crossing")
	return id


func _validation(id: int) -> void:
	var saved := _bridges.capture()
	var bad := saved.duplicate(true)
	bad.bridges.append(bad.bridges[0].duplicate(true))
	_check(Bridges.validate(bad, _world.size_m) != "", "save rejects duplicate bridge IDs")
	bad = saved.duplicate(true)
	bad.bridges[0].a.x = -1
	_check(Bridges.validate(bad, _world.size_m) != "", "save rejects out-of-world banks")
	bad = saved.duplicate(true)
	bad.bridges[0].delivered[Config.Res.TIMBER] = 999.0
	_check(Bridges.validate(bad, _world.size_m) != "", "save rejects unpaid or duplicated bridge material")
	bad = saved.duplicate(true)
	bad.bridges[0].work = NAN
	_check(Bridges.validate(bad, _world.size_m) != "", "save rejects nonfinite construction work")
	bad = saved.duplicate(true)
	bad.bridges[0].a += Vector3(0, 0, 150)
	bad.bridges[0].b += Vector3(0, 0, 150)
	_check(_bridges.restore(bad) != "" and _bridges.capture() == saved,
		"geographic validation rejects invented banks without mutating live bridges")
	_check(_bridges.restore(saved) == "" and _world.bridge_id_at(204, 202) == id,
		"restoring a complete bridge rebuilds its navigation overlay")


func _traffic_and_demolition(id: int) -> void:
	for c in _sim.citizens:
		c.position = Vector3(180, 9, 180)
		c.clear_goal()
	var traveler := _sim.citizens[0]
	traveler.position = _a - Vector3(8, 0, 0)
	traveler.set_goal(_b + Vector3(8, 0, 0))
	var on_deck := false
	var deck_height := true
	var refused := false
	for i in 500:
		traveler.advance(0.1, _world)
		if _world.bridge_id_at(traveler.position.x, traveler.position.z) == id:
			on_deck = true
			deck_height = deck_height and absf(traveler.position.y - 9.35) < 0.01
			if not refused:
				refused = not _bridges.remove(id).ok
		if traveler.has_arrived():
			break
	_check(on_deck and deck_height and traveler.has_arrived(),
		"citizens physically cross on the timber deck surface")
	_check(refused and _bridges.bridges.has(id), "demolition refuses an occupied bridge")
	traveler.position = Vector3(180, 9, 180)
	traveler.clear_goal()
	var revision := _world.nav.revision
	var result := _bridges.remove(id)
	_check(result.ok and _world.nav.is_solid(50, 50) and _world.nav.revision > revision,
		"empty bridge demolition immediately removes crossing routes")
	_check(_stock(Config.Res.TIMBER) == 120.0 and _stock(Config.Res.TOOLS) == 20.0,
		"demolition refunds delivered materials exactly once")
	_check(not _bridges.remove(id).ok, "repeating demolition cannot duplicate a refund")


func _destruction() -> void:
	var result := _bridges.place(_a, _b)
	if not result.ok:
		_check(false, "refunded stock can pay for a replacement crossing")
		return
	var id: int = result.id
	for i in 5000:
		_step()
		if _bridges.info(id).complete:
			break
	_check(_bridges.info(id).complete, "replacement bridge also requires real delivery and labor")
	var c := _sim.citizens[0]
	c.position = Vector3(204, 9.35, 202)
	c.pick_up(Config.Res.TIMBER, _source.remove(Config.Res.TIMBER, 3.0), _registry)
	c.set_goal(_b)
	var trade := TradeRoutes.new()
	_sim.add_child(trade)
	trade.setup(_sim, _world, _registry)
	_sim.trade = trade
	var merchant: Citizen = _sim.citizens.back()
	_sim.detach_for_service(merchant)
	merchant.position = _a.lerp(_b, 0.5)
	var route := Caravan.new()
	trade.add_child(route)
	route.setup(1, merchant, _registry)
	route.cargo_res = Config.Res.TIMBER
	route.cargo_amount = _source.remove(Config.Res.TIMBER, 24.0)
	route.health = 0.0
	trade.caravans[route.id] = route
	trade._next_id = 2
	trade.tick(0.1)
	await process_frame
	_check(trade.wrecks.size() == 1 and trade.wrecks[0].cargo[Config.Res.TIMBER] == 24.0,
		"merchant death leaves its finite cargo on the bridge")
	var wreck: Dictionary = trade.wrecks[0]
	trade.request_recovery(wreck.id)
	var recovery_jobs := 0
	for job in _sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.SALVAGE: recovery_jobs += 1
	_check(recovery_jobs > 0, "recovery can already be ordered before the bridge is destroyed")
	var recovery_worker: Citizen = _sim.citizens[1]
	recovery_worker.position = _a - Vector3(16, 0, 0)
	_sim._seek_job(recovery_worker)
	_check(recovery_worker.job != null and recovery_worker.job.kind == JobBoard.Kind.SALVAGE,
		"an existing civilian starts towards the wreck before evacuation")
	trade.tick_recovery(recovery_worker, 0.1)
	var before := _stock(Config.Res.TIMBER)
	var paid: float = _bridges.info(id).delivered[Config.Res.TIMBER]
	result = _bridges.destroy_bridge(id)
	var cell := _world.world_to_cell(c.position)
	_check(result.ok and result.evacuated > 0 and not _world.nav.is_solid(cell.x, cell.y),
		"destruction evacuates deck occupants to a clear bank")
	_check(c.carrying_amount == 3.0 and _stock(Config.Res.TIMBER) == before - paid,
		"destruction preserves people and carried goods while losing only the destroyed materials")
	var cart: Cart = trade.get_node("lost_cart_%d" % wreck.id)
	cell = _world.world_to_cell(wreck.position)
	_check(not _world.nav.is_solid(cell.x, cell.y) and wreck.position == cart.global_position
		and wreck.position == cart.parked_at and wreck.cargo[Config.Res.TIMBER] == 24.0,
		"wreck evacuation moves the cargo record and visible cart to the same clear bank")
	for job in _sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.SALVAGE:
			_check(job.position == wreck.position, "existing recovery jobs follow the evacuated wreck")
	_check(not recovery_worker.has_goal() and not recovery_worker.unreachable,
		"evacuation invalidates the salvager's old path and unreachable state")
	var saved := trade.capture()
	var error := trade.restore(saved)
	_check(error == "" and trade.capture() == saved
		and trade.get_node("lost_cart_%d" % wreck.id).global_position == wreck.position,
		"saving and restoring the evacuated wreck retains its bank position and cargo: " + error)
	for i in 8000:
		trade.tick(0.1)
		_step()
		var carried := 0.0
		for citizen in _sim.citizens: carried += citizen.carrying_amount
		if trade.wrecks.is_empty() and carried == 0.0: break
	_check(trade.wrecks.is_empty() and _stock(Config.Res.TIMBER) == before - paid + 24.0,
		"real civilian salvage recovers all evacuated cargo without rebuilding the bridge")
	await process_frame


func _cancel_loading() -> void:
	# Carrying survivors return their real load before taking another job.
	for i in 500:
		_step()
	var before_timber := _stock(Config.Res.TIMBER)
	var before_tools := _stock(Config.Res.TOOLS)
	var placed := _bridges.place(_a, _b)
	_check(placed.ok, "remaining real stock can commission an unfinished crossing")
	if not placed.ok:
		return
	var loaded := false
	for i in 1000:
		_step()
		for c in _sim.citizens:
			if c.job != null and c.job.kind == JobBoard.Kind.BRIDGE_HAUL and c.job.loaded:
				loaded = true
		if loaded:
			break
	var delivered: Dictionary = _bridges.info(placed.id).delivered.duplicate()
	var result := _bridges.remove(placed.id)
	_check(loaded and result.ok and result.refunded == delivered,
		"canceling construction refunds only materials delivered to its bank")
	_check(_stock(Config.Res.TIMBER) == before_timber and _stock(Config.Res.TOOLS) == before_tools,
		"canceling an in-flight haul keeps its goods on the original carrier")
	_check(_source.reserved[Config.Res.TIMBER] == 0 and _source.reserved[Config.Res.TOOLS] == 0,
		"cancellation releases source reservations without duplicating carried goods")


func _rendered_shot() -> void:
	var world := World.new()
	root.add_child(world)
	world.generate(_registry, 42, {"size_m": 768.0, "generation_version": 2})
	world.set_time_of_day(0.38)
	var sim := Simulation.new()
	root.add_child(sim)
	sim.setup(world, _registry, 42)
	var manager := Bridges.new()
	sim.add_child(manager)
	manager.setup(sim, world, _registry)
	sim.bridges = manager
	var crossing := {}
	for z in range(60, 110, 3):
		var first := -1
		var last := -1
		for x in range(110, 170):
			if world.heightmap.cell_surface(x, z) == Heightmap.Surface.WATER:
				if first < 0: first = x
				last = x
		if first < 0: continue
		for setback in range(1, 5):
			var q := manager.quote(Config.cell_to_world(Vector2i(first - setback, z)),
				Config.cell_to_world(Vector2i(last + setback, z)))
			if q.ok:
				crossing = q
				break
		if not crossing.is_empty(): break
	_check(not crossing.is_empty(), "rendered scene finds banks in the current generated terrain")
	if crossing.is_empty():
		sim.free()
		world.free()
		return
	var a: Vector3 = crossing.a
	var b: Vector3 = crossing.b
	var source := sim.place_building("keep", a - Vector3(42, 0, 0), 0, true)
	source.inventory[Config.Res.TIMBER] = 120.0
	source.inventory[Config.Res.TOOLS] = 20.0
	for i in 4:
		var c := sim.add_citizen(a - Vector3(16, 0, 4 + i))
		c.next_meal = 1000.0
	sim._is_night = false
	var placed := manager.place(a, b)
	_check(placed.ok, "generated river accepts a paid timber crossing for the rendered scene")
	if placed.ok:
		for i in 9000:
			manager.tick(0.1)
			for c in sim.citizens:
				sim._tick_citizen(c, 0.1)
			if manager.info(placed.id).complete:
				break
		_check(manager.info(placed.id).complete, "rendered river bridge was finished by real haulers and builders")
		var data := manager.info(placed.id)
		var camera := RTSCamera.new()
		root.add_child(camera)
		camera.set_process(false)
		camera.bind_terrain(world.heightmap)
		camera.camera().current = true
		camera.yaw = -0.4
		camera.look_at_position(data.position, 62.0)
		var cart := Cart.new()
		world.effects_root.add_child(cart)
		cart.setup(_registry, data.a)
		sim.set_cart(cart)
		var traveler := sim.citizens[0]
		traveler.position = data.a
		traveler.set_goal(data.b)
		cart.take(traveler)
		for i in 80:
			traveler.advance(0.1, world)
			cart.follow(world.heightmap, 0.1, world)
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var directory := ProjectSettings.globalize_path("res://../artifacts/bridges")
		DirAccess.make_dir_recursive_absolute(directory)
		var path := directory.path_join("paid_timber_crossing.png")
		_check(root.get_texture().get_image().save_png(path) == OK, "rendered timber crossing screenshot saved")
		print("SHOT ", path)
		camera.free()
	sim.free()
	world.free()


func _run() -> void:
	_registry.load_all()
	_flat_world()
	_river()
	var id := _build()
	if id >= 0 and _bridges.info(id).complete:
		_validation(id)
		_traffic_and_demolition(id)
		await _destruction()
		_cancel_loading()
	_sim.free()
	_world.free()
	if "--bridge-shot" in OS.get_cmdline_user_args():
		await _rendered_shot()
	print("Bridge regression failures: %d" % _failures)
	quit(1 if _failures else 0)
