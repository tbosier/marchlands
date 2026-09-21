extends "res://tests/scouting.gd"

func _water_step(game: SeededGame, delta: float = 0.25) -> void:
	game.sim.day += delta / Config.DAY_LENGTH
	game.sim.water.tick(delta)

func _hydration_and_claims() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var well: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	_check(water.wells.has(well.id) and water.wells[well.id].water == WaterSystem.CAPACITY,"starter well holds a finite local water reserve")
	var well_id := well.id
	var c: Citizen = sim.citizens[0]
	var citizen_id := c.id
	var store: Building = sim.buildings.filter(func(b): return b.type_id == "stockpile")[0]
	var job := sim.jobs.post(JobBoard.Kind.HAUL,c.position,1000.0)
	job.source_id = sim.keep.id
	job.dest_id = store.id
	job.res = Config.Res.TIMBER
	job.amount = 4.0
	job.loaded = true
	store.incoming[job.res] += job.amount
	c.pick_up(job.res,job.amount,game.registry)
	sim.jobs.index(job)
	c.job = sim.jobs.best_for(c.id,c.position,JobBoard.Accept.ANY,-1)
	c.hydration = 0.2
	var before := c.global_position
	_water_step(game)
	_check(c.job == null and store.incoming[Config.Res.TIMBER] == 0 and c.carrying_amount == 4,
		"a drinking errand releases hauling claims while preserving already carried cargo")
	_check(c.hydration < 0.2 and c.global_position.distance_to(before) < 2 and water.wells[well.id].water == WaterSystem.CAPACITY,
		"thirst sends the actual resident walking before any well water is consumed")
	var state := SaveGame.capture(game)
	var captured: Dictionary = water.capture()
	var error := game.restore_from(state)
	_check(error == "" and game.sim.water.capture() == captured,"drinking destination and finite reserves survive full staged save/load: " + error)
	sim = game.sim
	water = sim.water
	c = sim.citizens_by_id[citizen_id]
	for i in 2000:
		_water_step(game)
		if c.hydration >= 0.95: break
	_check(c.hydration >= 0.95 and water.wells[well_id].water < WaterSystem.CAPACITY and c.global_position.distance_to(sim.entrance_of(sim.buildings_by_id[well_id],"att_entrance")) <= Config.ARRIVE_RADIUS+0.2,
		"the resident drinks a finite amount only on reaching the well")
	var tree: ResourceNodes.NodeRec
	for rec in game.world.nodes.records:
		if rec.kind == ResourceNodes.Kind.TREE and not rec.depleted:
			tree = rec
			break
	var feller: Citizen = sim.citizens[1]
	game.world.nodes._marked.append(tree.id)
	tree.reserved_by = feller.id
	var felling := sim.jobs.post(JobBoard.Kind.FELL,tree.position,1000.0)
	felling.node_id = tree.id
	felling.res = Config.Res.TIMBER
	felling.claimed_by = feller.id
	feller.job = felling
	feller.hydration = 0.2
	_water_step(game)
	_check(feller.job == null and game.world.nodes.is_marked(tree.id) and tree.reserved_by == Simulation.FELLING_CLAIM,
		"a feller fetching water releases their worker claim without losing the player's clearing order")
	var invalid := SaveGame.capture(game)
	invalid.water.wells[0].water = WaterSystem.CAPACITY+1
	_check(SaveGame.validate(invalid,game.registry) != "","save validation rejects invented well water")
	invalid = SaveGame.capture(game)
	invalid.water.wells.clear()
	_check(SaveGame.validate(invalid,game.registry).contains("missing its finite water reserve"),"a current save cannot omit a depleted well and recreate free water on load")
	invalid = SaveGame.capture(game)
	invalid.citizens[0].hydration = NAN
	_check(SaveGame.validate(invalid,game.registry) != "","save validation rejects nonfinite hydration")
	game.free()
	await process_frame

func _fire_buckets() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var target: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	var target_id := target.id
	target.fire = 1.0
	var population := sim.population_members().size()
	var civilians := sim.citizens.size()
	_check(water.request_firefighting(target.id) == "" and water.carriers.size() == 1 and sim.citizens.size() == civilians-1 and sim.population_members().size() == population,
		"firefighting assigns an existing worker and removes their civilian production time")
	var id: int = water.carriers.keys()[0]
	var c: Citizen = water.carriers[id].person
	_check(c.water_bucket == 0 and target.fire == 1.0,"requesting a bucket neither teleports water nor instantly extinguishes fire")
	var source: Building = sim.buildings_by_id[water.carriers[id].well_id]
	c.position = sim.entrance_of(source,"att_entrance")
	c.hydration = 0.2
	_water_step(game)
	_check(c.hydration >= 0.95 and c.water_bucket == 0 and water.handles(c),
		"finishing a drinking errand cannot also fill or move a firefighting bucket in the same tick")
	for i in 2000:
		_water_step(game)
		if not water.carriers.has(id) or water.carriers[id].state == "carry": break
	_check(water.carriers.has(id) and c.water_bucket > 0 and target.fire == 1.0,"worker physically fills a bucket at a finite well before approaching the fire")
	var saved := SaveGame.capture(game)
	var carried: Dictionary = water.capture()
	var error := game.restore_from(saved)
	_check(error == "" and game.sim.water.capture() == carried and game.sim.population_members().size() == population,
		"save/load preserves the loaded bucket, worker identity and water debit: " + error)
	water = game.sim.water
	for i in 2000:
		_water_step(game)
		if water.carriers.is_empty(): break
	_check(water.carriers.is_empty() and game.sim.buildings_by_id[target_id].fire == 0 and game.sim.citizens_by_id.has(id),
		"water reaches the burning building and the same firefighter returns to work")
	game.free()
	await process_frame

func _poison_and_drinkers() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var manager: Scouting = sim.scouting
	var well: Building = sim.campaign._enemy_type("well")
	_check(well != null,"rival town has a physical well")
	_check(manager.train(manager._lodge().id) == "" and _until_scout(game,"ready"),"poison mission uses a physically trained resident scout")
	var scout: Scout = manager.scouts.values()[0]
	_check(not water.poison_quote(scout.id).can_poison,"unseen enemy well cannot be targeted through hidden state")
	var original := scout.person.global_position
	scout.person.global_position = well.global_position + Vector3(-20,0,0)
	manager.refresh_visibility()
	scout.person.global_position = original
	# Keep the actual sight snapshot for the order; success requires physically
	# walking to both the friendly counter and the enemy well afterwards.
	var tools_before := sim.keep.inventory[Config.Res.TOOLS]
	_check(water.poison(scout.id) == "" and sim.keep.inventory[Config.Res.TOOLS] == tools_before and water.wells[well.id].poison == 0,
		"poisoning reserves a real tool without consuming it or affecting a remote well")
	for unit in sim.campaign.units.values(): unit.position = sim.campaign.rival_position + Vector3(110,0,100)
	for i in 12000:
		_water_step(game)
		if water.poison_jobs.get(scout.id,{}).get("state","") == "poisoning": break
	_check(water.poison_jobs.has(scout.id) and water.poison_jobs[scout.id].state == "poisoning" and water.wells[well.id].poison == 0 and sim.campaign.at_war,
		"scout physically reaches the well and starts an overt interruptible action instead of an instant remote effect")
	_check(sim.keep.inventory[Config.Res.TOOLS] == tools_before-1 and water.transit(Config.Res.TOOLS) == 1,
		"the sabotage kit was physically collected and is counted in transit exactly once")
	var saved := SaveGame.capture(game)
	var mission: Dictionary = water.capture()
	var error := game.restore_from(saved)
	_check(error == "" and game.sim.water.capture() == mission,"save/load preserves paid sabotage progress and physical supplies: " + error)
	sim = game.sim
	water = sim.water
	well = sim.campaign._enemy_type("well")
	for i in 100:
		_water_step(game)
		if water.poison_jobs.is_empty(): break
	_check(water.poison_jobs.is_empty() and water.wells[well.id].poison > 0 and water.transit(Config.Res.TOOLS) == 0,
		"unopposed onsite work consumes the kit once and contaminates only that local well")
	var victim: Citizen = sim.campaign._workers[0]
	var untouched: Citizen = sim.campaign._workers[1]
	victim.hydration = 0.2
	victim.position = sim.entrance_of(well,"att_entrance")
	untouched.hydration = 1.0
	_water_step(game)
	_check(victim.water_sickness > 0 and untouched.water_sickness == 0,
		"only an actual drinker receives poison exposure; distant population is not hit instantly")
	var before := victim.service_health
	_water_step(game,1.0)
	_check(victim.service_health < before,"ingested poison causes persistent condition loss over time")
	var poison_state := SaveGame.capture(game)
	var sickness := victim.water_sickness
	var victim_id := victim.id
	error = game.restore_from(poison_state)
	victim = game.sim.campaign._workers.filter(func(c): return c.id == victim_id)[0]
	_check(error == "" and victim.water_sickness == sickness,"rival resident poison exposure survives a full staged load: " + error)
	var farm: Building = game.sim.campaign._enemy_type("farm")
	victim.service_health = 0
	_water_step(game)
	_check(not farm.workers.has(victim_id) and SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a poisoned grower's death removes phantom farm staffing and leaves a valid save")
	game.free()
	await process_frame

func _run() -> void:
	await _hydration_and_claims()
	await _fire_buckets()
	await _poison_and_drinkers()
	print("Water regression failures: %d" % _failures)
	quit(1 if _failures else 0)
