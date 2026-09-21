extends "res://tests/long_run.gd"

## Real travel, finite exchange, interruptions, citizen identity and every save phase.
func _prepare() -> SeededGame:
	var game := _new_game(42)
	if game.sim.trade == null:
		var manager := TradeRoutes.new()
		game.add_child(manager)
		manager.setup(game.sim, game.world, game.registry)
		game.sim.trade = manager
	game.sim.campaign.personality = "peaceful"
	var observer: Citizen = game.sim.citizens[0]
	var home_position := observer.global_position
	observer.global_position = game.sim.campaign.rival_position
	game.sim.scouting.refresh_visibility()
	observer.global_position = home_position
	game.sim.scouting.refresh_visibility()
	for job in game.sim.jobs.all_jobs():
		game.sim._release_reservations(job)
		game.sim.jobs.cancel(job)
	for c in game.sim.citizens:
		game.sim._release_cart(c)
		game.sim._go_idle(c)
	var market := _build(game, "market", game.world.centre() + Vector3(-45, 0, 15))
	_check(market != null, "trade has a completed origin market")
	game.sim.keep.inventory.fill(0.0)
	game.sim.keep.inventory[Config.Res.TIMBER] = 100.0
	game.sim.keep.inventory[Config.Res.FOOD] = 140.0
	return game


func _stock(game: SeededGame, res: int) -> float:
	var total := 0.0
	for b in game.sim.buildings: total += b.inventory[res]
	for b in game.sim.campaign.enemy_buildings.values(): total += b.inventory[res]
	for c in game.sim.population_members():
		if c.carrying_res == res: total += c.carrying_amount
		if res == Config.Res.FOOD and c is Soldier: total += c.rations
	total += game.sim.trade.transit(res)
	for wreck in game.sim.trade.wrecks: total += wreck.cargo[res]
	return total


func _step(game: SeededGame, delta: float = 0.25) -> void:
	game.sim.day += delta / Config.DAY_LENGTH
	game.sim.trade.tick(delta)


func _until(game: SeededGame, phase: String, limit: int = 14000) -> bool:
	for i in limit:
		if game.sim.trade.caravans.is_empty(): return phase == "finished"
		if phase != "finished" and game.sim.trade.caravans.values()[0].state == phase: return true
		_step(game)
	return false


func _round_trip() -> void:
	var game := _prepare()
	var sim := game.sim
	var person: Citizen = sim.citizens[0]
	var id := person.id
	var identity := [person.given_name, person.age, person.asset_id, person.home_id]
	var wood := _stock(game, Config.Res.TIMBER)
	var iron := _stock(game, Config.Res.IRON)
	var food := _stock(game, Config.Res.FOOD)
	var population := sim.population_members().size()
	var rival: Building = sim.campaign.trade_store()
	var quote: Dictionary = sim.trade.quotes()[0]
	_check(quote.ok and quote.import_amount == 8.0 and quote.export_amount == 24.0,
			"peaceful neighbor quotes a finite timber-for-iron barter with provisions")
	_check(sim.trade.dispatch(-1, -1, id) == "", "dispatch assigns an existing resident")
	var route: Caravan = sim.trade.caravans.values()[0]
	_check(route.merchant == person and not sim.citizens_by_id.has(id)
			and sim.population_members().size() == population and sim.citizens.size() == population - 1,
			"assignment retains the actual resident while removing one local worker")
	_check(route.cargo_amount == 0 and route.provisions == 0 and rival.reserved[Config.Res.IRON] == 8.0
			and sim.keep.inventory[Config.Res.TIMBER] == 100.0,
			"dispatch reserves promised stock without teleporting goods to the cart")
	var wear := 0.0
	for value in game.world.wear.wear: wear += value
	_check(_until(game, "outward"), "merchant physically collects provisions and timber and reaches the market")
	route = sim.trade.caravans.values()[0]
	_check(route.cargo_amount == 24 and route.provisions > 0 and route.occupied_capacity() <= Cart.CAPACITY
			and sim.keep.inventory[Config.Res.TIMBER] == 76,
			"loading debits actual export stock within the cart capacity")
	_check(_until(game, "exchange"), "loaded merchant traverses the route to the rival counter")
	_check(rival.inventory[Config.Res.IRON] == 32.0 and route.cargo_res == Config.Res.TIMBER,
			"arrival has not duplicated imports before the exchange step")
	_step(game)
	_check(route.state == "return" and route.cargo_res == Config.Res.IRON and route.cargo_amount == 8.0
			and rival.inventory[Config.Res.IRON] == 24 and rival.inventory[Config.Res.TIMBER] == 24
			and rival.reserved[Config.Res.IRON] == 0,
			"arrival exchanges finite real stock exactly once and releases its promise")
	_check(_until(game, "finished"), "merchant brings imports home and unloads before returning to civilian work")
	var returned: Citizen = sim.citizens_by_id.get(id)
	_check(returned == person and [returned.given_name, returned.age, returned.asset_id, returned.home_id] == identity
			and sim.population_members().size() == population,
			"round trip preserves resident identity, occupied home and population")
	_check(is_equal_approx(_stock(game, Config.Res.TIMBER), wood) and is_equal_approx(_stock(game, Config.Res.IRON), iron)
			and sim.stores.spendable(Config.Res.IRON) == 8,
			"every timber and iron unit is conserved across a complete round trip")
	_check(_stock(game, Config.Res.FOOD) < food, "merchant consumes real provisions while away")
	var worn := 0.0
	for value in game.world.wear.wear: worn += value
	_check(worn > wear, "actual cart passage deposits wear along the trading route")
	game.free()
	await process_frame


func _interruptions() -> void:
	var game := _prepare()
	var sim := game.sim
	var wood := _stock(game, Config.Res.TIMBER)
	var iron := _stock(game, Config.Res.IRON)
	var rival: Building = sim.campaign.trade_store()
	var start_food := sim.keep.inventory[Config.Res.FOOD]
	sim.keep.inventory[Config.Res.FOOD] = 40.0
	_check(sim.trade.dispatch() != "" and sim.trade.caravans.is_empty(), "food floor blocks a route before taking payment or a person")
	sim.keep.inventory[Config.Res.FOOD] = start_food
	_check(sim.trade.dispatch() == "", "route starts after provisions are affordable")
	_check(_until(game, "outward"), "recall scenario loads its real cart")
	var route: Caravan = sim.trade.caravans.values()[0]
	var at := route.merchant.position
	var before := sim.keep.inventory[Config.Res.TIMBER]
	_check(sim.trade.recall(route.id) == "" and route.merchant.position == at and route.cargo_amount == 24
			and sim.keep.inventory[Config.Res.TIMBER] == before and rival.reserved[Config.Res.IRON] == 0,
			"recall releases the promise without teleporting the merchant or refunding cargo")
	_check(_until(game, "finished") and is_equal_approx(_stock(game, Config.Res.TIMBER), wood),
			"canceled cargo is conserved through the physical return and unload")
	_check(sim.trade.dispatch() == "" and _until(game, "outward"), "second route departs for the war interruption")
	route = sim.trade.caravans.values()[0]
	sim.campaign.at_war = true
	_step(game)
	_check(route.state in ["return", "unloading"] and route.cargo_res == Config.Res.TIMBER and not route.promised
			and sim.trade.dispatch() != "", "active war closes access and turns paid exports home without exchanging them")
	_check(_until(game, "finished") and is_equal_approx(_stock(game, Config.Res.IRON), iron), "war interruption creates no iron")
	sim.campaign.at_war = false
	sim.campaign.personality = "loner"
	_check(sim.trade.quotes()[0].import_amount == 4 and sim.trade.dispatch() == "" and not sim.trade.quotes()[0].ok,
			"a loner offers smaller loads and limits concurrent promises")
	route = sim.trade.caravans.values()[0]
	sim.trade.recall(route.id)
	_check(_until(game, "finished"), "a recall during loading safely returns the reassigned resident")
	game.free()
	await process_frame


func _save_phases() -> void:
	var game := _prepare()
	_check(game.sim.trade.dispatch() == "", "save scenario dispatches")
	var person_id: int = game.sim.trade.caravans.values()[0].merchant.id
	for phase in ["loading", "outward", "exchange", "return", "unloading"]:
		_check(_until(game, phase), "save scenario reaches " + phase)
		var snapshot := SaveGame.capture(game)
		var before: Dictionary = game.sim.trade.capture()
		var wood := _stock(game, Config.Res.TIMBER)
		var iron := _stock(game, Config.Res.IRON)
		var error := game.restore_from(snapshot)
		_check(error == "" and game.sim.trade.capture() == before,
				"full staged save/load retains caravan identity and accounting during " + phase + ": " + error)
		_check(is_equal_approx(_stock(game, Config.Res.TIMBER), wood) and is_equal_approx(_stock(game, Config.Res.IRON), iron)
				and not game.sim.citizens_by_id.has(person_id) and game.sim.population_members().size() == 20,
				"save/load conserves goods and one merchant during " + phase)
		if phase == "exchange": _step(game)
	_check(_until(game, "finished") and game.sim.citizens_by_id.has(person_id), "restored route completes once and returns its original citizen ID")
	game.free()
	await process_frame


func _finite_stock_and_validation() -> void:
	var game := _prepare()
	var sim := game.sim
	_check(sim.trade.dispatch(-1, -1, -1, true) == "", "repeating caravan dispatches")
	var route: Caravan = sim.trade.caravans.values()[0]
	for i in 50000:
		if not is_instance_valid(route) or not sim.trade.caravans.has(route.id): break
		if route.state == "waiting" and route.completed_trips == 4: break
		_step(game)
	_check(route.completed_trips == 4 and route.state == "waiting" and sim.campaign.trade_store().inventory[Config.Res.IRON] == 0
			and sim.stores.spendable(Config.Res.IRON) == 32,
			"repeat consumes the finite initial iron stock and pauses without inventing another load")
	var snapshot: Dictionary = sim.trade.capture()
	if snapshot.caravans.is_empty():
		game.free()
		await process_frame
		return
	var invalid := snapshot.duplicate(true)
	invalid.caravans[0].cargo_res = Config.Res.IRON
	invalid.caravans[0].cargo_amount = 8.0
	_check(TradeRoutes.validate(invalid, game.world.size_m, sim.buildings_by_id) != "", "save validation rejects cargo invented in an unloaded repeat state")
	invalid = snapshot.duplicate(true)
	invalid.caravans[0].food_reserved = true
	_check(TradeRoutes.validate(invalid, game.world.size_m, sim.buildings_by_id) != "", "save validation rejects a reservation detached from its loading stage")
	_check(sim.trade.set_repeat(route.id, false) == "", "repeat can be disabled while paused")
	_step(game)
	_check(sim.trade.caravans.is_empty() and sim.citizens.size() == 20, "disabling a depleted repeat returns the resident to work")
	game.free()
	await process_frame


func _blocked_and_destroyed() -> void:
	var game := _prepare()
	var sim := game.sim
	_check(sim.trade.dispatch() == "" and _until(game, "outward"), "blocked-route scenario loads and departs")
	var route: Caravan = sim.trade.caravans.values()[0]
	var barrier := Vector3(game.world.size_m * 0.5, 0, 300)
	game.world.nav.block_footprint(barrier, game.world.size_m * 0.5, 2.0, true)
	var at := route.merchant.position
	_step(game)
	_check(route.merchant.unreachable and route.merchant.position == at and route.cargo_amount == 24
			and route.status.begins_with("Waiting: no traversable route"),
			"a newly blocked route waits visibly with its paid cargo and resident intact")
	game.world.nav.block_footprint(barrier, game.world.size_m * 0.5, 2.0, false)
	_step(game)
	_check(not route.merchant.unreachable and route.merchant.position != at,
			"route revision resumes the physical caravan after the obstruction is removed")
	var before := _stock(game, Config.Res.TIMBER)
	var target: Building = sim.campaign.trade_store()
	sim.campaign._destroy_enemy(target)
	var snapshot := SaveGame.capture(game)
	var error := game.restore_from(snapshot)
	_check(error == "", "saving immediately after the promised destination burns down remains loadable: " + error)
	sim = game.sim
	route = sim.trade.caravans.values()[0]
	_step(game)
	_check(route.state in ["return", "unloading"] and route.cargo_res == Config.Res.TIMBER and not route.promised,
			"destroyed destination cancels its promise and sends the paid timber home")
	_check(_until(game, "finished") and is_equal_approx(_stock(game, Config.Res.TIMBER), before),
			"a destroyed destination cannot eat or refund the merchant's cargo remotely")
	game.free()
	await process_frame


func _veteran_and_death() -> void:
	var game := _prepare()
	var sim := game.sim
	var veteran: Soldier = sim.add_citizen(sim.entrance_of(sim.keep, "att_cart_bay"), false,
			"citizen_male_base", -1, Soldier.Body.healthy())
	veteran.given_name = "Wren the returning merchant"
	veteran.receive_hit("arm_l", "slash", 80.0)
	veteran.rations = 1.5
	veteran.pick_up(Config.Res.STONE, 3.0, game.registry)
	var identity := veteran.id
	var body := veteran.capture_body()
	var stone := _stock(game, Config.Res.STONE)
	_check(sim.trade.dispatch(-1, -1, identity) == "", "an injured working veteran can be assigned to trade")
	var route: Caravan = sim.trade.caravans.values()[0]
	_check(route.merchant == veteran and veteran.capture_body() == body and veteran.carrying_amount == 3,
			"merchant assignment retains the veteran's actual body and existing hand cargo")
	var saved := SaveGame.capture(game)
	var error := game.restore_from(saved)
	sim = game.sim
	route = sim.trade.caravans.values()[0]
	veteran = route.merchant
	_check(error == "" and veteran.capture_body() == body and veteran.carrying_amount == 3 and veteran.rations == 1.5,
			"merchant save/load preserves missing limbs, hand cargo and personal food: " + error)
	_check(_until(game, "outward"), "loaded veteran reaches the departure phase")
	var wood := _stock(game, Config.Res.TIMBER)
	var population := sim.population_members().size()
	var incident := veteran.position
	veteran.receive_hit("head", "slash", 100.0)
	_step(game)
	_check(sim.trade.caravans.is_empty() and sim.population_members().size() == population - 1
			and not sim.citizens_by_id.has(identity) and sim.trade.wrecks.size() == 1,
			"merchant death permanently removes one resident and leaves a loaded cart")
	_check(sim.trade.wrecks[0].position == incident and is_equal_approx(_stock(game, Config.Res.TIMBER), wood)
			and is_equal_approx(_stock(game, Config.Res.STONE), stone),
			"death preserves export and personal cargo at the physical incident site")
	saved = SaveGame.capture(game)
	error = game.restore_from(saved)
	_check(error == "" and game.sim.trade.wrecks.size() == 1 and game.sim.trade.caravans.is_empty()
			and not game.sim.citizens_by_id.has(identity), "lost-cart save/load cannot resurrect its merchant: " + error)
	# Recovery uses an ordinary resident and the same carry/deposit lifecycle.
	sim = game.sim
	var wreck_id: int = sim.trade.wrecks[0].id
	var untouched: PackedFloat32Array = sim.trade.wrecks[0].cargo.duplicate()
	_check(sim.trade.request_recovery(wreck_id) == "" and sim.trade.wrecks[0].cargo == untouched,
			"requesting recovery posts work without moving any lost cargo")
	_check(sim.trade.cancel_recovery(wreck_id) == "" and sim.trade.wrecks[0].cargo == untouched,
			"canceling before pickup leaves all stock at the wreck")
	sim.trade.request_recovery(wreck_id)
	saved = SaveGame.capture(game)
	error = game.restore_from(saved)
	sim = game.sim
	_check(error == "" and sim.trade.wrecks[0].recovery_requested and sim.trade.wrecks[0].cargo == untouched,
			"recovery order survives save/load with the finite uncollected wreck stock")
	sim.trade.tick(0.25)
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.SALVAGE and job.res == Config.Res.TIMBER: job.priority = 100.0
	var worker: Citizen = sim.citizens[0]
	var worker_id := worker.id
	worker.next_meal = sim.day + 100.0
	sim._is_night = false
	sim._seek_job(worker)
	_check(worker.job != null and worker.job.kind == JobBoard.Kind.SALVAGE,
			"an existing civilian accepts the physical salvage errand")
	var origin := worker.position
	var recovery_job := worker.job
	sim.trade.tick_recovery(worker, 0.25)
	_check(worker.position != origin and worker.carrying_amount == 0
			and sim.trade.wrecks[0].cargo == untouched,
			"salvager walks toward the incident before collecting its load")
	for i in 5000:
		if worker.job == null: break
		sim.trade.tick_recovery(worker, 0.25)
	_check(worker.job == null and recovery_job.loaded and worker.carrying_res == Config.Res.TIMBER
			and worker.carrying_amount == Config.CARRY_CAPACITY
			and sim.trade.wrecks[0].cargo[Config.Res.TIMBER] == 24.0 - Config.CARRY_CAPACITY,
			"pickup transfers one finite handload exactly once at the actual wreck")
	sim.trade.cancel_recovery(wreck_id)
	var load := worker.carrying_amount
	_check(load == Config.CARRY_CAPACITY and is_equal_approx(_stock(game, Config.Res.TIMBER), wood),
			"canceling after pickup keeps the cargo on its living carrier")
	saved = SaveGame.capture(game)
	error = game.restore_from(saved)
	sim = game.sim
	worker = sim.citizens_by_id[worker_id]
	_check(error == "" and worker.carrying_amount == load and not sim.trade.wrecks[0].recovery_requested
			and is_equal_approx(_stock(game, Config.Res.TIMBER), wood),
			"save/load after pickup cannot duplicate the worker's salvage or reissue the canceled job")
	for i in 5000:
		if worker.carrying_amount <= 0: break
		sim._carry_stray_load(worker, 0.25)
	_check(worker.carrying_amount == 0 and is_equal_approx(_stock(game, Config.Res.TIMBER), wood),
			"canceled salvage still walks into real storage through ordinary delivery")
	sim.trade.request_recovery(wreck_id)
	for citizen in sim.citizens: citizen.next_meal = sim.day + 100.0
	sim._is_night = false
	for i in 6000:
		sim.trade.tick(0.25)
		for citizen in sim.citizens: sim._tick_citizen(citizen, 0.25)
		var carried := 0.0
		for citizen in sim.citizens: carried += citizen.carrying_amount
		if sim.trade.wrecks.is_empty() and carried == 0: break
	_check(sim.trade.wrecks.is_empty() and is_equal_approx(_stock(game, Config.Res.TIMBER), wood)
			and is_equal_approx(_stock(game, Config.Res.STONE), stone)
			and sim.population_members().size() == population - 1,
			"repeated salvage empties the finite cart and preserves stock and the permanent death")
	game.free()
	await process_frame


func _everyone_assigned() -> void:
	var game := _prepare()
	var sim := game.sim
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -30))
	if barracks == null:
		game.free()
		return
	sim.keep.inventory.fill(0.0)
	sim.keep.inventory[Config.Res.FOOD] = 240.0
	sim.keep.inventory[Config.Res.TOOLS] = 90.0
	sim.keep.inventory[Config.Res.TIMBER] = 64.0
	var success := true
	for i in 18: success = sim.campaign.recruit() == "" and success
	for i in 2: success = sim.trade.dispatch() == "" and success
	_check(success and sim.citizens.is_empty() and sim.campaign.friendly_ids().size() == 18
			and sim.trade.caravans.size() == 2 and sim.population_members().size() == 20,
			"eighteen soldiers and two merchants leave zero civilian workers without deleting anyone")
	var harvest := 0.0
	for b in sim.buildings:
		if b.def.is_farm(): harvest += b.inventory[Config.Res.FOOD]
	for i in 20: sim.tick(0.25)
	var after := 0.0
	var workers := 0
	for b in sim.buildings:
		workers += b.workers.size()
		if b.def.is_farm(): after += b.inventory[Config.Res.FOOD]
	_check(workers == 0 and harvest == after, "all residents assigned away means no local production")
	game.free()
	await process_frame


func _run() -> void:
	await _round_trip()
	await _interruptions()
	await _save_phases()
	await _finite_stock_and_validation()
	await _blocked_and_destroyed()
	await _veteran_and_death()
	await _everyone_assigned()
	print("Trade regression failures: %d" % _failures)
	quit(1 if _failures else 0)
