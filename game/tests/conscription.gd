extends "res://tests/long_run.gd"


func _soldier_for(campaign: FrontierCampaign, civilian_id: int) -> Soldier:
	for id in campaign.friendly_ids():
		if campaign._civilian_ids[id] == civilian_id:
			return campaign.units[id]
	return null


func _fund(sim: Simulation) -> void:
	sim.keep.inventory[Config.Res.TOOLS] = 250.0
	sim.keep.inventory[Config.Res.FOOD] = 350.0


func _population_transfer() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	campaign.set_personality("peaceful")
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -10))
	var farm := _build(game, "farm", game.world.centre() + Vector3(-35, 0, 55))
	if barracks == null or farm == null:
		game.free()
		return
	_fund(sim)
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	farm.sync_fields_to_workers()
	var homes := {}
	var identities := {}
	for person in sim.citizens:
		identities[person.id] = [person.given_name, person.age, person.asset_id, person.home_id]
	for building in sim.buildings:
		homes[building.id] = building.residents.duplicate()
	var original_spare: int = sim.population.appeal(sim.buildings, sim.population_members()).spare_housing
	var all_recruited := true
	for i in 10:
		all_recruited = campaign.recruit() == "" and all_recruited
	_check(all_recruited and sim.citizens.size() == 10 and campaign.friendly_ids().size() == 10
			and sim.population_members().size() == 20,
			"recruiting ten of twenty residents produces ten civilians and ten soldiers")
	var preserved := true
	for id in campaign.friendly_ids():
		var unit: Soldier = campaign.units[id]
		preserved = preserved and identities[campaign._civilian_ids[id]] \
				== [unit.given_name, unit.age, unit.asset_id, unit.home_id]
	for building in sim.buildings:
		preserved = preserved and building.residents == homes[building.id]
	_check(preserved and sim.population.appeal(sim.buildings, sim.population_members()).spare_housing == original_spare,
			"military service preserves identity and home occupancy without inventing immigration vacancies")
	for i in 10:
		all_recruited = campaign.recruit() == "" and all_recruited
	var empty_workplaces := true
	for building in sim.buildings:
		empty_workplaces = empty_workplaces and building.workers.is_empty()
	_check(all_recruited and sim.citizens.is_empty() and campaign.friendly_ids().size() == 20
			and empty_workplaces and farm.field_count() == 0,
			"recruiting everybody leaves zero civilian workers and no worked fields")
	var wallet := sim.keep.inventory.duplicate()
	_check(not campaign.can_recruit() and campaign.recruit() != "" and sim.keep.inventory == wallet,
			"an empty civilian population cannot create another recruit or charge supplies")
	var owned := sim.stores.total(Config.Res.TIMBER)
	var farm_food := farm.inventory[Config.Res.FOOD]
	for i in 36:
		sim.tick(0.5)
	_check(sim.citizens.is_empty() and farm.inventory[Config.Res.FOOD] == farm_food
			and sim.stores.total(Config.Res.TIMBER) == owned,
			"with all residents serving, simulation ticks produce no civilian harvest or timber")
	var snapshot := SaveGame.capture(game)
	var error := SaveGame.validate(snapshot, game.registry)
	_check(error == "", "a fully conscripted town has a valid save with military residents: " + error)
	error = game.restore_from(snapshot)
	_check(error == "" and game.sim.citizens.is_empty()
			and game.sim.campaign.friendly_ids().size() == 20
			and game.sim.campaign.capture() == snapshot.campaign,
			"full staged load preserves twenty soldiers and zero invented civilians: " + error)
	game.free()
	await process_frame


func _release_claims() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -10))
	if barracks == null:
		game.free()
		return
	_fund(sim)
	var store: Building = sim.buildings.filter(func(b): return b.type_id == "stockpile")[0]
	var citizen := sim.citizens[0]
	var civilian_id := citizen.id
	var job := sim.jobs.post(JobBoard.Kind.HAUL, citizen.position, 1000.0)
	job.source_id = sim.keep.id
	job.dest_id = store.id
	job.res = Config.Res.TIMBER
	job.amount = 12.0
	job.uses_cart = true
	sim.keep.reserved[job.res] += job.amount
	store.incoming[job.res] += job.amount
	sim.jobs.index(job)
	citizen.job = sim.jobs.best_for(citizen.id, citizen.position, JobBoard.Accept.ANY, -1)
	sim.cart.take(citizen)
	_check(sim.campaign.recruit(civilian_id) == "" and sim.jobs.total_jobs() == 0
			and sim.keep.reserved[Config.Res.TIMBER] == 0.0
			and store.incoming[Config.Res.TIMBER] == 0.0
			and sim.cart.is_free() and not sim.jobs.cart_promised(),
			"conscription releases a hauler's source, destination, job and cart claims")
	citizen = sim.citizens[0]
	civilian_id = citizen.id
	job = sim.jobs.post(JobBoard.Kind.HAUL, citizen.position, 1000.0)
	job.source_id = sim.keep.id
	job.dest_id = store.id
	job.res = Config.Res.TIMBER
	job.amount = 12.0
	job.loaded = true
	store.incoming[job.res] += job.amount
	sim.keep.remove(job.res, job.amount)
	citizen.pick_up(job.res, job.amount, game.registry)
	sim.jobs.index(job)
	citizen.job = sim.jobs.best_for(citizen.id, citizen.position, JobBoard.Accept.ANY, -1)
	sim.stores.refresh_totals(sim.population_members(), sim.buildings)
	var timber := sim.stores.total(Config.Res.TIMBER)
	var recruited: bool = sim.campaign.recruit(civilian_id) == ""
	var soldier := _soldier_for(sim.campaign, civilian_id)
	_check(recruited and soldier.carrying_amount == 12.0 and soldier.carrying_res == Config.Res.TIMBER
			and sim.jobs.total_jobs() == 0 and store.incoming[Config.Res.TIMBER] == 0.0
			and sim.stores.total(Config.Res.TIMBER) == timber,
			"a conscript keeps an already loaded cargo without duplicate reservations or lost accounting")
	_check(sim.campaign.demobilize(soldier.id) == ""
			and sim.citizens_by_id[civilian_id].carrying_amount == 12.0
			and sim.stores.total(Config.Res.TIMBER) == timber,
			"discharge returns that same citizen and cargo to civilian logistics")
	var node := game.world.nodes.find_nearest(ResourceNodes.Kind.TREE, game.world.centre(), 300, false)
	var camp := _build(game, "logging_camp", node.position)
	if camp != null:
		citizen = sim.citizens[0]
		citizen.workplace_id = camp.id
		camp.workers.append(citizen.id)
		job = sim.jobs.post(JobBoard.Kind.GATHER, node.position, 1000.0)
		job.node_id = node.id
		job.dest_id = camp.id
		job.res = Config.Res.TIMBER
		job.output_reserved = Config.CARRY_CAPACITY
		camp.production_reserved = job.output_reserved
		node.reserved_by = camp.id
		sim.jobs.index(job)
		citizen.job = sim.jobs.best_for(citizen.id, node.position, JobBoard.Accept.ANY, camp.id)
		civilian_id = citizen.id
		_check(sim.campaign.recruit(civilian_id) == "" and node.reserved_by == -1
				and camp.production_reserved == 0.0 and not camp.workers.has(civilian_id),
				"conscripting a gatherer releases the resource node, output space and employment slot")
	game.free()
	await process_frame


func _veterans_and_losses() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -10))
	if barracks == null:
		game.free()
		return
	_fund(sim)
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	var citizen := sim.citizens[0]
	var civilian_id := citizen.id
	var identity := [citizen.given_name, citizen.age, citizen.asset_id, citizen.home_id]
	_check(sim.campaign.recruit(civilian_id) == "", "a named resident can be explicitly conscripted")
	var unit := _soldier_for(sim.campaign, civilian_id)
	var enemy: Soldier = sim.campaign.units.values().filter(func(u): return u.faction == 1)[0]
	var safe_position := unit.position
	unit.position = enemy.position + Vector3(1, 0, 0)
	sim.campaign.at_war = true
	var force: int = sim.campaign.friendly_ids().size()
	_check(sim.campaign.demobilize(unit.id) != "" and sim.campaign.friendly_ids().size() == force
			and not sim.citizens_by_id.has(civilian_id),
			"a soldier in contact with an enemy cannot become an immune civilian mid-fight")
	unit.position = safe_position
	sim.campaign.at_war = false
	unit.receive_hit("arm_r", "slash", 80.0)
	unit.receive_hit("leg_l", "slash", 80.0)
	unit.rations = 2.5
	var body := unit.capture_body()
	_check(sim.campaign.demobilize(unit.id) == "" and sim.citizens.size() == 20
			and sim.campaign.friendly_ids().is_empty(), "demobilization restores the original civilian count")
	var veteran: Soldier = sim.citizens_by_id[civilian_id]
	_check([veteran.given_name, veteran.age, veteran.asset_id, veteran.home_id] == identity
			and veteran.capture_body() == body and veteran.workability() < 1.0
			and veteran.mobility_scale() < 1.0 and not veteran.can_strike(),
			"a discharged veteran retains name, age, home, missing limbs and reduced civilian abilities")
	var snapshot := SaveGame.capture(game)
	var error := game.restore_from(snapshot)
	veteran = game.sim.citizens_by_id[civilian_id]
	_check(error == "" and veteran.capture_body() == body and veteran.rations == 2.5
			and [veteran.given_name, veteran.age, veteran.asset_id, veteran.home_id] == identity,
			"civilian veteran injuries, identity and unused rations survive staged save/load: " + error)
	sim = game.sim
	veteran.next_meal = sim.day - 0.1
	var meals := veteran.meals_taken
	sim._tick_citizen(veteran, 0.1)
	_check(veteran.meals_taken == meals + 1 and veteran.rations == 2.5 - Config.MEAL_FOOD,
			"a discharged veteran eats existing pack food before drawing another household meal")
	_check(sim.campaign.recruit(civilian_id) == "", "a veteran can reenlist without being duplicated")
	unit = _soldier_for(sim.campaign, civilian_id)
	_check(unit.capture_body() == body and unit.given_name == identity[0]
			and sim.population_members().size() == 20,
			"reenlistment cannot regrow limbs or create another resident")
	unit.receive_hit("arm_l", "slash", 80.0)
	_check(sim.campaign.demobilize(unit.id) == "", "a severely injured survivor can leave service")
	veteran = sim.citizens_by_id[civilian_id]
	var site := _build(game, "house", game.world.centre() + Vector3(45, 0, 35), false)
	if site != null:
		for res in site.build_cost:
			site.deliver_material(res, site.build_cost[res])
		veteran.position = sim.entrance_of(site, "att_entrance")
		veteran.next_meal = sim.day + 1.0
		var progress := site.build_progress
		for i in 10:
			sim._tick_citizen(veteran, 0.5)
		_check(veteran.workability() == 0.0 and veteran.job == null and site.build_progress == progress,
				"a civilian with both arms disabled cannot carry on construction or claim work")
		var home: Building = sim.buildings_by_id.get(veteran.home_id)
		if home != null:
			home.larder = 0.0
			if home.stores(Config.Res.FOOD): home.inventory[Config.Res.FOOD] = 0.0
		veteran.rations = 0.0
		veteran.next_meal = sim.day - 0.1
		var counter := _build(game, "granary", game.world.centre() + Vector3(65, 0, -35))
		if counter != null:
			counter.inventory[Config.Res.FOOD] = 20.0
			veteran.position = sim.entrance_of(counter, "att_cart_bay")
			meals = veteran.meals_taken
			sim._tick_citizen(veteran, 0.1)
			_check(veteran.meals_taken == meals + 1 and veteran.carrying_amount == 0.0
					and counter.inventory[Config.Res.FOOD] == 20.0 - Config.MEAL_FOOD,
					"a resident with unusable arms eats at a counter without hauling a larder load")
	_check(sim.campaign.recruit(civilian_id) == "", "reenlisting an injured resident still transfers one person")
	unit = _soldier_for(sim.campaign, civilian_id)
	var unit_id := unit.id
	unit.receive_hit("head", "slash", 100.0)
	sim.campaign.tick(0.1)
	var home: Building = sim.buildings_by_id.get(identity[3])
	_check(not sim.campaign.units.has(unit_id) and not sim.citizens_by_id.has(civilian_id)
			and sim.population_members().size() == 19
			and (home == null or not home.residents.has(civilian_id)),
			"a battlefield death permanently removes the resident and releases their home")
	_check(sim.campaign.demobilize(unit_id) != "", "a casualty cannot be revived by demobilization")
	game.free()
	await process_frame


func _large_force_and_legacy() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -10))
	if barracks == null:
		game.free()
		return
	_fund(sim)
	for i in 6:
		sim.add_citizen(sim.entrance_of(sim.keep, "att_entrance"))
	var all_recruited := true
	for i in 26:
		all_recruited = sim.campaign.recruit() == "" and all_recruited
	_check(all_recruited and sim.citizens.is_empty() and sim.campaign.friendly_ids().size() == 26,
			"recruiting existing residents is not capped at the old twenty-four generated soldiers")
	var legacy := SaveGame.capture(game)
	for unit in legacy.campaign.units:
		unit.erase("civilian")
		unit.erase("body")
	for building in legacy.buildings:
		building.residents.clear()
	var error := game.restore_from(legacy)
	var migrated := SaveGame.capture(game)
	var valid := SaveGame.validate(migrated, game.registry)
	_check(error == "" and valid == "" and game.sim.population_members().size() == 26
			and game.sim.citizens.is_empty(),
			"legacy soldiers gain unique civilian identities without creating extra living people: " + error + valid)
	game.free()
	await process_frame


func _rival_manpower() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	var farm := campaign._enemy_type("farm")
	var keep := campaign._enemy_type("keep")
	var initial_population := campaign.town_population + campaign.units.size()
	var worker: Citizen = campaign._workers.back()
	worker.given_name = "Rival veteran"
	worker.age = 37
	worker.position = campaign.rival_position + Vector3(50, 0, 50)
	worker.position.y = game.world.heightmap.height_at(worker.position.x, worker.position.z)
	worker.pick_up(Config.Res.FOOD, 7.0, game.registry)
	campaign._worker_leg[worker.id] = 1
	var worker_id := worker.id
	var identity := [worker.given_name, worker.age, worker.asset_id, worker.position]
	campaign.at_war = true
	campaign._time = campaign._recruit_at
	var before := keep.inventory[Config.Res.FOOD]
	campaign._tick_town(0.0)
	var recruit: Soldier = campaign.units.get(worker_id)
	_check(recruit != null and campaign._workers.size() == 2 and campaign.town_population == 7
			and campaign.units.size() == 4 and farm.field_count() == 2
			and not farm.workers.has(worker_id)
			and keep.inventory[Config.Res.FOOD] == before - 12.0,
			"rival reinforcement enlists one real grower, pays supplies and reduces worked farmland")
	if recruit != null:
		_check(identity == [recruit.given_name, recruit.age, recruit.asset_id, recruit.position]
				and recruit.carrying_res == Config.Res.FOOD and recruit.carrying_amount == 7.0,
				"a rival recruit retains the grower's identifier, name, age, appearance and carried food")
	for i in 2:
		campaign._time = campaign._recruit_at
		campaign._tick_town(0.0)
	_check(campaign._workers.is_empty() and farm.workers.is_empty() and farm.field_count() == 0
			and campaign.town_population + campaign.units.size() == initial_population,
			"rival enlistment preserves total population while exhausting its available growers")
	var saved := SaveGame.capture(game)
	var error := game.restore_from(saved)
	_check(error == "" and game.sim.campaign.capture() == saved.campaign,
			"the rival's reduced workforce, identities and loaded recruits survive a full staged load: " + error)
	campaign = game.sim.campaign
	farm = campaign._enemy_type("farm")
	keep = campaign._enemy_type("keep")
	# A vacant military slot must not turn food into an invented new person.
	var casualty: Soldier = campaign.units.values()[0]
	campaign._remove_unit(casualty)
	before = keep.inventory[Config.Res.FOOD]
	var harvest := farm.inventory[Config.Res.FOOD]
	campaign._time = campaign._recruit_at
	campaign._tick_town(Config.DAY_LENGTH)
	_check(campaign.units.size() == 5 and campaign._workers.is_empty()
			and farm.inventory[Config.Res.FOOD] == harvest
			and keep.inventory[Config.Res.FOOD] == before - campaign.town_population,
			"after growers are exhausted, casualties stay permanent and unworked farms produce no food")
	game.free()
	await process_frame


func _run() -> void:
	await _population_transfer()
	await _release_claims()
	await _veterans_and_losses()
	await _large_force_and_legacy()
	await _rival_manpower()
	print("Conscription regression failures: %d" % _failures)
	quit(1 if _failures else 0)
