extends "res://tests/long_run.gd"

## Storage pressure must stop new output before it strands the whole workforce.
## Exercise the actual job lifecycle, including rejection, deposits and retirement.


func _clear_jobs(sim: Simulation) -> void:
	for job in sim.jobs.all_jobs():
		sim._release_reservations(job)
		sim.jobs.cancel(job)
	for citizen in sim.citizens:
		sim._release_cart(citizen)
		sim._go_idle(citizen)


func _gather_capacity(game: SeededGame) -> void:
	var sim := game.sim
	var node := game.world.nodes.find_nearest(ResourceNodes.Kind.TREE,
			game.world.centre(), 350.0, false)
	_check(node != null, "capacity fixture has timber to harvest")
	if node == null:
		return
	var camp := _build(game, "logging_camp", node.position)
	if camp == null:
		return
	_clear_jobs(sim)
	var res := Config.Res.TIMBER
	camp.inventory[res] = camp.capacity() - 1.0
	for i in camp.def.worker_slots:
		sim.production._post_gathering(camp)
	_check(sim.jobs.total_jobs() == 0 and camp.production_reserved == 0.0,
			"one free slot cannot launch three full timber loads")

	camp.inventory[res] = camp.capacity() - Config.CARRY_CAPACITY
	for i in camp.def.worker_slots:
		sim.production._post_gathering(camp)
	_check(sim.jobs.count_for(JobBoard.Kind.GATHER, camp.id, res) == 1
			and camp.production_reserved == Config.CARRY_CAPACITY and camp.space_for(res) == 0.0,
			"one returning load owns the yard's final capacity")
	if sim.jobs.total_jobs() == 0:
		return
	var job := sim.jobs.all_jobs()[0]
	var citizen := sim.citizens[0]
	citizen.workplace_id = camp.id
	citizen.position = job.position
	citizen.job = sim.jobs.best_for(citizen.id, citizen.position, JobBoard.Accept.ANY, camp.id)
	_check(citizen.job == job, "gatherer claims the capacity-backed order")
	sim._abandon(citizen)
	_check(job.claimed_by == -1 and camp.production_reserved == Config.CARRY_CAPACITY,
			"releasing a worker retains the open job's output claim")
	_check(camp.add(res, 5.0) == 0.0,
			"an unrelated deposit cannot steal a returning worker's slot")

	citizen.job = sim.jobs.best_for(citizen.id, job.position, JobBoard.Accept.ANY, camp.id)
	citizen.state = Citizen.State.TRAVELLING
	citizen.pick_up(res, Config.CARRY_CAPACITY, game.registry)
	citizen.position = sim.entrance_of(camp, "att_stock_0")
	citizen.set_goal(citizen.position)
	sim._tick_gather(citizen, 0.1)
	_check(citizen.carrying_amount == 0.0 and citizen.job == null
			and camp.inventory[res] == camp.capacity() and camp.production_reserved == 0.0,
			"returning gatherer deposits in its own slot without stranded overflow")
	sim.production._post_gathering(camp)
	_check(sim.jobs.total_jobs() == 0, "a full producer rests without issuing futile gathering")
	camp.remove(res, Config.CARRY_CAPACITY)
	sim.production._post_gathering(camp)
	_check(sim.jobs.total_jobs() == 1, "spending a load restarts production")
	if sim.jobs.total_jobs() > 0:
		job = sim.jobs.all_jobs()[0]
		citizen.position = job.position
		citizen.job = sim.jobs.best_for(citizen.id, job.position, JobBoard.Accept.ANY, camp.id)
		sim._retire_job(citizen)
		_check(camp.production_reserved == 0.0 and camp.space_for(res) == Config.CARRY_CAPACITY,
				"retiring an invalid gathering job returns its capacity")
		sim._release_reservations(job)
		_check(camp.production_reserved == 0.0, "releasing an output claim twice is harmless")


func _harvest_capacity(game: SeededGame) -> void:
	var sim := game.sim
	_clear_jobs(sim)
	var farm := _build(game, "farm", game.world.centre() + Vector3(-36, 0, 48))
	if farm == null:
		return
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	farm.sync_fields_to_workers()
	var res := Config.Res.FOOD
	var maximum := Config.harvest_load(1.0)
	farm.crop_growth = Config.FARM_HARVEST_AT
	farm.inventory[res] = farm.capacity() - maximum
	for i in farm.def.worker_slots:
		sim.production._post_gathering(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, res) == 1
			and farm.production_reserved == maximum,
			"harvest reserves the ripe yield even when posted before full maturity")
	_check(farm.add(res, 1.0) == 0.0, "incoming food cannot consume promised harvest room")
	if sim.jobs.total_jobs() == 0:
		return
	var job := sim.jobs.all_jobs()[0]
	var citizen := sim.citizens[0]
	citizen.workplace_id = farm.id
	citizen.position = job.position
	citizen.job = sim.jobs.best_for(citizen.id, citizen.position, JobBoard.Accept.ANY, farm.id)
	citizen.state = Citizen.State.TRAVELLING
	citizen.pick_up(res, maximum, game.registry)
	citizen.position = sim.entrance_of(farm, "att_entrance")
	citizen.set_goal(citizen.position)
	sim._tick_harvest(citizen, 0.1)
	_check(citizen.carrying_amount == 0.0 and farm.inventory[res] == farm.capacity()
			and farm.production_reserved == 0.0,
			"a fully ripe harvest fits its reserved capacity exactly")
	farm.remove(res, maximum)
	sim.production._post_gathering(farm)
	_check(farm.production_reserved == maximum, "another harvest reserves newly freed room")
	sim.demolish(farm)
	_check(farm.production_reserved == 0.0 and sim.jobs.total_jobs() == 0,
			"demolition releases production claims and their jobs")


func _workshop_sources(game: SeededGame) -> void:
	var sim := game.sim
	_clear_jobs(sim)
	var shop := _build(game, "blacksmith", game.world.centre() + Vector3(-55, 0, 16))
	if shop == null:
		return
	shop.inventory[Config.Res.IRON] = 6.0  # Less than the eight-iron batch.
	shop.inventory[Config.Res.TIMBER] = 8.0
	for store in sim.stores.buildings_storing(Config.Res.IRON):
		if store != shop:
			store.inventory[Config.Res.IRON] = 0.0
	sim.production._post_crafting(shop)
	_check(sim.jobs.total_jobs() == 0, "an iron-starved workshop does not haul its own input to itself")
	_clear_jobs(sim)
	sim.keep.inventory[Config.Res.IRON] = 12.0
	sim.production._post_crafting(shop)
	var incoming := sim.jobs.all_jobs()
	_check(incoming.size() == 1 and incoming[0].source_id == sim.keep.id
			and incoming[0].dest_id == shop.id and incoming[0].res == Config.Res.IRON,
			"a short workshop sources fresh iron from another store")
	_clear_jobs(sim)


func _incoming_capacity(game: SeededGame) -> void:
	var keep := game.sim.keep
	for res in Config.RES_COUNT:
		keep.inventory[res] = 0.0
	keep.inventory[Config.Res.TIMBER] = keep.capacity() - 12.0
	keep.incoming[Config.Res.STONE] = 12.0
	_check(keep.add(Config.Res.TIMBER, 4.0) == 0.0,
			"stray goods cannot steal capacity promised to a different resource")
	keep.incoming[Config.Res.STONE] = 0.0
	_check(keep.add(Config.Res.STONE, 12.0) == 12.0,
			"the arriving haul fits after releasing its own claim")
	game.sim.cart.load_goods(Config.Res.TIMBER)
	_check(game.sim.cart._load_visual.position == game.registry.attachment("wood_cart", "att_stock_0"),
			"cart cargo follows the generated bed attachment")


func _atomic_payment() -> void:
	var stores := Stores.new()
	var keep := Building.new()
	keep.def = BuildingDefs.get_def("keep")
	keep.inventory.resize(Config.RES_COUNT)
	keep.reserved.resize(Config.RES_COUNT)
	stores.register(keep)
	keep.inventory[Config.Res.TIMBER] = 20.0
	keep.inventory[Config.Res.STONE] = 10.0
	keep.reserved[Config.Res.TIMBER] = 15.0
	var cost := {Config.Res.TIMBER: 6.0, Config.Res.STONE: 2.0}
	_check(not stores.try_spend(cost) and keep.inventory[Config.Res.TIMBER] == 20.0
			and keep.inventory[Config.Res.STONE] == 10.0,
			"payment cannot spend reserved goods or partially charge another resource")
	keep.reserved[Config.Res.TIMBER] = 14.0
	_check(stores.try_spend(cost) and keep.inventory[Config.Res.TIMBER] == 14.0
			and keep.inventory[Config.Res.STONE] == 8.0,
			"payment sees current stock before the next UI totals refresh")
	_check(not stores.try_spend(cost) and keep.inventory[Config.Res.STONE] == 8.0,
			"a second payment cannot reuse spent stock")
	keep.free()


func _fractional_construction(source_amount: float) -> void:
	var game := _new_game(42)
	var sim := game.sim
	var site := _build(game, "house", game.world.centre() + Vector3(-50, 0, -35), false)
	if site == null:
		game.free()
		return
	_clear_jobs(sim)
	var stone := Config.Res.STONE
	var remaining := 0.203575
	for res in site.build_cost:
		site.delivered[res] = float(site.build_cost[res])
	site.delivered[stone] -= remaining
	for store in sim.stores.buildings_storing(stone):
		store.inventory[stone] = 0.0
	sim.keep.inventory[stone] = source_amount
	sim.production._post_construction(site)
	var posted := sim.jobs.all_jobs()
	_check(posted.size() == 1 and posted[0].kind == JobBoard.Kind.HAUL
			and posted[0].source_id == sim.keep.id and posted[0].dest_id == site.id
			and is_equal_approx(posted[0].amount, remaining),
			"construction posts its final fractional load from %.2f available stone" % source_amount)
	if posted.size() != 1:
		game.free()
		return
	var carrier: Citizen = sim.citizens[0]
	carrier.position = sim.entrance_of(sim.keep, "att_cart_bay")
	carrier.job = sim.jobs.best_for(carrier.id, carrier.position, JobBoard.Accept.ANY, -1)
	for tick in 1600:
		if carrier.job == null:
			break
		sim._tick_haul(carrier, Config.MAX_SIM_STEP)
	_check(carrier.job == null and carrier.carrying_amount == 0.0
			and site.materials_complete()
			and absf(sim.keep.inventory[stone] - (source_amount - remaining)) < 0.00001,
			"fractional stone is physically hauled and accounted for without rounding it away")
	sim.production._post_construction(site)
	carrier.job = sim.jobs.best_for(carrier.id, carrier.position, JobBoard.Accept.ANY, -1)
	for tick in 1600:
		if not site.under_construction or carrier.job == null:
			break
		sim._tick_build(carrier, Config.MAX_SIM_STEP)
	_check(not site.under_construction and site.build_progress == 1.0,
			"builders complete the site after its fractional final delivery")
	game.free()


func _run() -> void:
	_atomic_payment()
	_fractional_construction(2.0)
	_fractional_construction(0.25)
	var game := _new_game(42)
	_gather_capacity(game)
	_harvest_capacity(game)
	_workshop_sources(game)
	_incoming_capacity(game)
	game.free()
	await process_frame
	print("Production regression failures: %d" % _failures)
	quit(1 if _failures else 0)
