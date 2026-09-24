extends "res://tests/bootstrap.gd"

## A paid ranching economy: no gifted cattle, hides, leather or technology.


func _wait_for_building(game: SeededGame, site: Building) -> bool:
	if site == null:
		return false
	for day_number in 12:
		if not site.under_construction:
			return true
		await _advance_day(game)
	return not site.under_construction


func _paid_build(game: SeededGame, type_id: String, offset: Vector3) -> Building:
	var site: Building
	for day_number in 12:
		game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
		if game.sim.can_afford(BuildingDefs.get_def(type_id).cost):
			site = _paid_site(game, type_id, offset)
			break
		await _advance_day(game)
	var completed := await _wait_for_building(game, site)
	_check(completed, "paid %s is built through real delivery and labour" % type_id)
	if completed:
		for res in site.build_cost:
			_check(is_equal_approx(float(site.delivered.get(res, 0.0)), float(site.build_cost[res])),
					"%s construction accounts for its %s" % [type_id, Res.display(res)])
	return site


func _research(game: SeededGame, tech_id: String) -> bool:
	game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
	var error := game.sim.research.start(tech_id, game._has_market(), game.sim.stores.try_spend)
	_check(error == "", "research %s is paid from actual available goods: %s" % [tech_id, error])
	if error != "":
		return false
	for day_number in 5:
		await _advance_day(game)
		if game.sim.research.completed.has(tech_id):
			break
	_check(game.sim.research.completed.has(tech_id), "calendar completes paid %s research" % tech_id)
	return game.sim.research.completed.has(tech_id)


func _malformed(manager: Husbandry) -> void:
	var valid := manager.capture()
	_check(Husbandry.validate(valid) == "", "live cattle and breeding progress validate")
	var cases: Array = [
		["negative age", "age_days", -1.0],
		["nonfinite age", "age_days", NAN],
		["nonfinite yaw", "yaw", INF],
		["off-map cattle", "position", Vector3(-5, 0, 40)],
		["invalid ranch", "ranch_id", -2],
		["invalid order", "marked", "yes"],
	]
	for entry in cases:
		var bad := valid.duplicate(true)
		bad.cows[0][entry[1]] = entry[2]
		_check(Husbandry.validate(bad) != "", "rejects %s without mutating the herd" % entry[0])
	var duplicate := valid.duplicate(true)
	duplicate.cows.append(duplicate.cows[0].duplicate())
	_check(Husbandry.validate(duplicate) != "", "rejects duplicate cattle IDs")


func _ranching_chain() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var manager: Husbandry = sim.husbandry
	_check(manager != null and manager.cows.size() >= 8,
			"a fresh map contains reachable wild herds before any ranch exists")
	if manager == null or manager.cows.size() < 4:
		game.free()
		return
	var wild: Cattle = manager.cows.values()[0]
	_check(wild._body.collision_layer == 16 and wild._body.get_meta("cow_id") == wild.id,
			"wild cattle are actual selectable map entities")
	_check(not sim.research.ranching_known and manager.request_domestication(wild.id) != "",
			"knowledge and cattle cannot be acquired without a staffed ranch")
	var plan: Array = [
		["logging_camp", Vector3.ZERO], ["farm", Vector3(-36, 0, 48)],
		["quarry", Vector3.ZERO], ["farm", Vector3(44, 0, 48)],
		["market", Vector3(-36, 0, -32)], ["ranch", Vector3(52, 0, -34)],
		["tannery", Vector3(-60, 0, -28)],
	]
	var ranch: Building
	var tannery: Building
	for order in plan:
		var b := await _paid_build(game, order[0], order[1])
		if b == null or b.under_construction:
			game.free()
			return
		if b.def.is_ranch(): ranch = b
		if b.type_id == "tannery": tannery = b
	_check(ranch.workers.size() == 2 and tannery.workers.size() == 2,
			"ranch and tannery employ real citizens from the civilian workforce")
	_check(sim.stores.find_store(Config.Res.FOOD, ranch.position, -1) != ranch,
			"farm overflow cannot occupy the ranch's slaughter output capacity")
	# One order takes the whole herd the picked animal grazes with.
	var selected: Array[int] = []
	for cow: Cattle in manager.cows.values():
		if manager.get_info(cow.id).can_domesticate:
			_check(manager.request_domestication(cow.id) == "", "player can order a reachable wild herd home")
			break
	for cow: Cattle in manager.cows.values():
		if cow.marked: selected.append(cow.id)
	_check(selected.size() == 4, "one order claims the picked animal's whole herd of four")
	var runs := 0
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.TAME: runs += 1
	_check(runs == 2, "the herd is shared between the ranch's two ranchers (%d runs)" % runs)
	var first_position: Vector3 = manager.cows[selected[0]].position if not selected.is_empty() else Vector3.ZERO
	_check(not sim.research.ranching_known and manager.herd_at(ranch.id).is_empty(),
			"ordering domestication does not teleport cattle or award knowledge")
	for day_number in 14:
		await _advance_day(game)
		if manager.herd_at(ranch.id).size() == 4: break
	_check(manager.herd_at(ranch.id).size() == 4 and sim.research.ranching_known,
			"ranchers approach, tame and physically lead four cattle home, earning knowledge")
	if manager.herd_at(ranch.id).size() != 4:
		print("METRIC " + JSON.stringify(manager.capture()))
		game.free()
		return
	_check(manager.cows[selected[0]].position.distance_to(first_position) > 20.0,
			"domesticated cattle walked a meaningful distance from their wild herd")
	_check(sim.total_resource(Config.Res.HIDES) == 0.0 and sim.total_resource(Config.Res.LEATHER) == 0.0,
			"taming alone creates no hides or leather")
	if not await _research(game, "ranching"):
		game.free()
		return
	for day_number in 8:
		await _advance_day(game)
		if sim.total_resource(Config.Res.HIDES) >= 4.0: break
	_check(sim.total_resource(Config.Res.HIDES) >= 4.0 and manager.herd_at(ranch.id, true).size() >= 3,
			"real slaughter supplies hides while retaining the adult breeding herd")
	if not await _research(game, "leatherworking"):
		game.free()
		return
	var births := false
	for day_number in 30:
		await _advance_day(game)
		for cow in manager.herd_at(ranch.id):
			births = births or cow.age_days < Husbandry.ADULT_DAYS
		_invariants(game, "ranching supply chain")
		if births and sim.total_resource(Config.Res.LEATHER) >= 4.0: break
	_check(births, "staffed tending produces a real calf that grows over the calendar")
	if sim.total_resource(Config.Res.LEATHER) < 4.0:
		print("METRIC " + JSON.stringify({"husbandry": manager.capture(),
			"ranch_inventory": Array(ranch.inventory), "tannery_inventory": Array(tannery.inventory),
			"tannery_workers": tannery.workers, "state": _diagnose(game, null)}))
	_check(sim.total_resource(Config.Res.LEATHER) >= 4.0,
			"haulers deliver earned hides and timber and tanners craft real leather")
	_check(manager.herd_at(ranch.id).size() <= Husbandry.RANCH_CAPACITY,
			"ranch reproduction respects its animal capacity")
	_malformed(manager)
	var saved_cattle := manager.capture()
	var ranch_id := ranch.id
	var saved := SaveGame.capture(game)
	var restore_error := game.restore_from(saved)
	_check(restore_error == "", "ranching economy survives actual staged save restoration: %s" % restore_error)
	if restore_error == "":
		manager = game.sim.husbandry
		sim = game.sim
		ranch = sim.buildings_by_id[ranch_id]
		_check(manager.capture() == saved_cattle, "save restoration preserves every animal and breeding progress")
	# A manager tick can age animals, but it cannot invent labour when ranchers
	# have been conscripted or reassigned away from this workplace.
	for job in sim.jobs.all_jobs():
		if job.dest_id == ranch.id:
			sim._release_reservations(job)
			sim.jobs.cancel(job)
	for worker_id in ranch.workers:
		var worker: Citizen = sim.citizens_by_id[worker_id]
		worker.workplace_id = -1
		sim._go_idle(worker)
	ranch.workers.clear()
	var count_before := manager.herd_at(ranch.id).size()
	var inventory_before := ranch.inventory.duplicate()
	var breeding_before := manager.breeding.duplicate()
	manager.post_ranch_jobs(ranch)
	manager.tick(Config.DAY_LENGTH * 4.0)
	_check(manager.herd_at(ranch.id).size() == count_before and ranch.inventory == inventory_before
			and manager.breeding == breeding_before,
			"an unstaffed ranch cannot breed, slaughter or create goods through manager ticks")
	sim.demolish(ranch)
	_check(manager.herd_at(ranch_id).is_empty() and not manager.breeding.has(ranch_id),
			"demolishing the ranch releases its real animals and removes breeding state")
	print("METRIC " + JSON.stringify({"phase": "ranching_chain", "day": sim.day,
		"cattle": manager.cows.size(), "hides": sim.total_resource(Config.Res.HIDES),
		"leather": sim.total_resource(Config.Res.LEATHER), "research": sim.research.completed}))
	game.free()
	await process_frame


func _controlled_output() -> void:
	# An established herd isolates exact animal/material conservation and the
	# shared capacity claims; the separate chain above pays for its opening.
	var game := _new_game(42)
	var sim := game.sim
	var manager: Husbandry = sim.husbandry
	var ranch := _build(game, "ranch", game.world.centre() + Vector3(52, 0, -34))
	if ranch == null:
		game.free()
		return
	sim.research.restore({"completed": ["ranching"], "active": "", "remaining_days": 0.0,
		"ranching_known": true})
	var worker: Citizen = sim.citizens[0]
	worker.workplace_id = ranch.id
	ranch.workers.assign([worker.id])
	worker.position = sim.entrance_of(ranch, "att_entrance")
	var assigned := 0
	for cow: Cattle in manager.cows.values():
		if assigned == 4: break
		cow.ranch_id = ranch.id
		cow.position = worker.position + Vector3(1, 0, 0)
		cow.age_days = 12.0
		assigned += 1
	ranch.inventory[Config.Res.FOOD] = 90.0
	manager.post_ranch_jobs(ranch)
	_check(sim.jobs.count_for(JobBoard.Kind.BUTCHER, ranch.id, -1) == 0,
			"insufficient output room leaves surplus cattle alive")
	ranch.inventory[Config.Res.FOOD] = 60.0
	manager.post_ranch_jobs(ranch)
	_check(ranch.production_reserved == 24.0
			and sim.jobs.count_for(JobBoard.Kind.BUTCHER, ranch.id, -1) == 1,
			"slaughter reserves the complete food-and-hide output before work starts")
	_check(ranch.add(Config.Res.FOOD, 20.0) == 16.0,
			"unrelated deposits cannot occupy slaughter's reserved output room")
	worker.position += Vector3(1, 0, 0)
	worker.job = sim.jobs.best_for(worker.id, worker.position, JobBoard.Accept.OWN_SITE_ONLY, ranch.id)
	_check(worker.job != null and worker.job.kind == JobBoard.Kind.BUTCHER,
			"an actual rancher claims the waiting slaughter job")
	if worker.job != null and worker.job.kind == JobBoard.Kind.BUTCHER:
		var count_before := manager.cows.size()
		var food_before := ranch.inventory[Config.Res.FOOD]
		var hides_before := ranch.inventory[Config.Res.HIDES]
		for tick in 100:
			if worker.job == null: break
			manager.tick_job(worker, Config.MAX_SIM_STEP)
		_check(manager.cows.size() == count_before - 1
				and ranch.inventory[Config.Res.FOOD] == food_before + Husbandry.FOOD_YIELD
				and ranch.inventory[Config.Res.HIDES] == hides_before + Husbandry.HIDE_YIELD
				and ranch.production_reserved == 0.0,
				"one consumed animal becomes exactly twenty food and four hides, releasing its claim")
		_check(manager.herd_at(ranch.id, true).size() == 3,
				"slaughter preserves three adult breeders")
		sim.production._post_delivery(ranch, Config.Res.FOOD)
		var food_haul := false
		for job in sim.jobs.all_jobs():
			food_haul = food_haul or (job.kind == JobBoard.Kind.HAUL and job.source_id == ranch.id
					and job.res == Config.Res.FOOD and job.dest_id != ranch.id)
		_check(food_haul, "ranch meat is assigned a real outbound haul to public storage")
	# A pending domestication also owns an animal slot, so births cannot use it.
	for job in sim.jobs.all_jobs():
		sim._release_reservations(job)
		sim.jobs.cancel(job)
	sim._go_idle(worker)
	for cow: Cattle in manager.cows.values():
		if cow.ranch_id < 0:
			cow.ranch_id = ranch.id
			cow.age_days = 12.0
			break
	ranch.inventory.fill(0.0)
	manager.post_ranch_jobs(ranch)
	worker.position = manager.herd_at(ranch.id, true)[0].position
	worker.job = sim.jobs.best_for(worker.id, worker.position, JobBoard.Accept.OWN_SITE_ONLY, ranch.id)
	_check(worker.job != null and worker.job.kind == JobBoard.Kind.BUTCHER,
			"enlistment fixture begins actual slaughter work")
	if worker.job != null:
		manager.tick_job(worker, Config.MAX_SIM_STEP)
	var alive_before := manager.cows.size()
	var stock_before := ranch.inventory.duplicate()
	sim.detach_for_service(worker)
	manager.tick(Config.MAX_SIM_STEP)
	_check(ranch.workers.is_empty() and ranch.production_reserved == 0.0
			and manager.cows.size() == alive_before and ranch.inventory == stock_before
			and sim.jobs.count_for(JobBoard.Kind.BUTCHER, ranch.id, -1) == 0,
			"enlisting the final rancher cancels slaughter, frees capacity and preserves cattle and goods")
	worker = sim.citizens[0]
	worker.workplace_id = ranch.id
	ranch.workers.assign([worker.id])
	for cow: Cattle in manager.cows.values():
		if manager.herd_at(ranch.id).size() == 7: break
		cow.ranch_id = ranch.id
		cow.age_days = 12.0
	var arriving: Cattle
	for cow: Cattle in manager.cows.values():
		if cow.ranch_id < 0:
			arriving = cow
			break
	_check(arriving != null, "capacity fixture has another actual wild cow")
	if arriving != null:
		var tending := manager._post(JobBoard.Kind.TEND, ranch)
		worker.position = sim.entrance_of(ranch, "att_entrance")
		worker.job = sim.jobs.best_for(worker.id, worker.position, JobBoard.Accept.OWN_SITE_ONLY, ranch.id)
		arriving.marked = true
		manager._post(JobBoard.Kind.TAME, ranch, arriving)
		manager.breeding[ranch.id] = Husbandry.BREED_WORK_DAYS - 0.0001
		manager.tick_job(worker, 1.0)
		_check(manager.herd_at(ranch.id).size() == 7 and tending.cancelled,
				"births cannot take the eighth slot promised to an incoming cow")
		worker.position = arriving.position
		worker.job = sim.jobs.best_for(worker.id, worker.position, JobBoard.Accept.OWN_SITE_ONLY, ranch.id)
		for tick in 20:
			if worker.job == null: break
			manager.tick_job(worker, Config.MAX_SIM_STEP)
		_check(worker.job != null and worker.job.kind == JobBoard.Kind.TAME and worker.job.loaded
				and arriving.marked and arriving.ranch_id == -1,
				"destruction fixture catches a tamed animal being physically led home")
		var unrelated_node := game.world.nodes.get_node_rec(arriving.id)
		if unrelated_node != null:
			unrelated_node.reserved_by = 987654
		sim.demolish(ranch)
		_check(not arriving.marked and arriving.ranch_id == -1
				and not manager._cow_has_job(arriving.id) and worker.job == null,
				"destroying a ranch releases its incoming animal and the rancher's task")
		_check(unrelated_node == null or unrelated_node.reserved_by == 987654,
				"cattle job cancellation cannot alter an unrelated resource-node claim")
	game.free()
	await process_frame


func _run() -> void:
	await _ranching_chain()
	await _controlled_output()
	print("Husbandry regression failures: %d" % _failures)
	quit(1 if _failures else 0)
