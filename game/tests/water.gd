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
	var store_id := store.id
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
	_check(c.job == job and store.incoming[Config.Res.TIMBER] == 4 and c.carrying_amount == 4,
		"a drinking errand preserves the loaded delivery and its destination claim")
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
	var loaded_at_well := c.global_position
	var cargo_before := c.carrying_amount
	var timber_before := cargo_before
	for b in sim.buildings: timber_before += b.inventory[Config.Res.TIMBER]
	_check(c.job != null and c.job.dest_id == store_id and c.has_goal()
		and c._goal == sim.entrance_of(sim.buildings_by_id[store_id],"att_cart_bay") and cargo_before == 4.0,
		"finishing a drink immediately restores the actual loaded resource's delivery route")
	c.next_meal = sim.day + 2.0
	sim._tick_citizen(c,0.25)
	_check(c.global_position == loaded_at_well and c.carrying_amount == cargo_before,
		"priming the delivery route does not move the worker twice or teleport the cargo")
	for i in 2000:
		_water_step(game)
		sim._tick_citizen(c,0.25)
		if c.carrying_amount <= 0.01: break
	var timber_after := c.carrying_amount if c.carrying_res == Config.Res.TIMBER else 0.0
	var incoming := 0.0
	for b in sim.buildings:
		timber_after += b.inventory[Config.Res.TIMBER]
		incoming += b.incoming[Config.Res.TIMBER]
	_check(c.carrying_amount == 0 and c.global_position != loaded_at_well and is_equal_approx(timber_before,timber_after)
		and incoming == 0 and c.job == null,
		"after drinking, the worker physically deposits every carried unit once with no stale destination claims")
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

func _loaded_drinking_destination(construction: bool) -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var target := _build(game,"house" if construction else "blacksmith",
		game.world.centre()+Vector3(50,0,-35),not construction)
	var target_id := target.id
	var res := Config.Res.STONE if construction else Config.Res.IRON
	var amount := minf(12.0,float(target.build_cost.get(res,12.0))) if construction else 12.0
	var c: Citizen = sim.citizens[0]
	var citizen_id := c.id
	c.position = sim.entrance_of(sim.keep,"att_cart_bay")
	c.next_meal = sim.day+10.0
	sim.keep.inventory[res] = amount
	var job := sim.jobs.post(JobBoard.Kind.HAUL,c.position,1000.0)
	job.source_id = sim.keep.id
	job.dest_id = target.id
	job.res = res
	job.amount = amount
	sim.jobs.index(job)
	sim.keep.reserved[res] += amount
	target.incoming[res] += amount
	c.job = sim.jobs.best_for(c.id,c.position,JobBoard.Accept.ANY,c.workplace_id)
	sim._tick_haul(c,0.0)
	_check(job.loaded and c.carrying_amount == amount and sim.keep.inventory[res] == 0,
		"drinking delivery regression starts with goods physically collected from their source")
	# Full mixed stores cannot accept a fallback load. The workshop/site still
	# owns reserved delivery room, which must survive the water interruption.
	for b in sim.stores.buildings_storing(res):
		if b == target: continue
		b.inventory.fill(0)
		b.inventory[Config.Res.TIMBER if b.stores(Config.Res.TIMBER) else res] = b.capacity()
	_check(sim.stores.find_store(res,c.position,-1) == null,
		"saturated stores cannot conceal a lost workshop or construction destination")
	c.hydration = 0.2
	_water_step(game)
	_check(c.job == job and target.incoming[res] == amount,
		"thirst pauses a loaded %s delivery without freeing its reservation" % target.type_id)
	var error := game.restore_from(SaveGame.capture(game))
	_check(error == "","loaded drinking delivery and destination claim survive save/load: " + error)
	sim = game.sim
	c = sim.citizens_by_id[citizen_id]
	target = sim.buildings_by_id[target_id]
	for i in 4000:
		_water_step(game)
		if c.hydration >= 0.95: break
	_check(c.job != null and c.job.dest_id == target_id and not sim.water.drinkers.has(sim.water._key(c)),
		"finishing the drink retains the loaded delivery after the water order ends")
	var after_drink := SaveGame.capture(game)
	var saved_person: Dictionary = after_drink.citizens.filter(func(person): return person.id == citizen_id)[0]
	var invalid := after_drink.duplicate(true)
	var invalid_person: Dictionary = invalid.citizens.filter(func(person): return person.id == citizen_id)[0]
	invalid_person.delivery.dest_id = 999999
	_check(SaveGame.validate(invalid,game.registry).contains("unknown endpoint"),
		"a saved loaded delivery cannot reference a missing destination")
	invalid = after_drink.duplicate(true)
	invalid_person = invalid.citizens.filter(func(person): return person.id == citizen_id)[0]
	invalid_person.delivery.source_id = sim.buildings.filter(func(b): return b.type_id == "well")[0].id
	_check(SaveGame.validate(invalid,game.registry).contains("invalid source"),
		"a saved loaded delivery requires a source that could hold its actual resource")
	invalid = after_drink.duplicate(true)
	invalid_person = invalid.citizens.filter(func(person): return person.id == citizen_id)[0]
	invalid_person.carrying_amount = 0.0
	invalid_person.carrying_res = -1
	_check(SaveGame.validate(invalid,game.registry).contains("invalid loaded delivery"),
		"a delivery intent cannot recreate cargo absent from its person")
	invalid = after_drink.duplicate(true)
	for person in invalid.citizens:
		person.delivery = saved_person.delivery.duplicate()
		person.carrying_amount = amount
		person.carrying_res = res
	_check(SaveGame.validate(invalid,game.registry).contains("loaded deliveries exceed"),
		"multiple loaded deliveries cannot overpromise the destination's shared capacity")
	error = game.restore_from(after_drink)
	_check(error == "","a second save after drinking preserves the original delivery: " + error)
	sim = game.sim
	c = sim.citizens_by_id[citizen_id]
	target = sim.buildings_by_id[target_id]
	_check(c.job != null and c.job.loaded and c.job.claimed_by == c.id
		and sim.jobs.open_jobs() == 0 and target.incoming[res] == amount
		and sim.keep.reserved[res] == 0,
		"restoring a carried delivery reserves only its destination and cannot offer it to a second worker")
	for i in 4000:
		_water_step(game)
		sim._tick_citizen(c,0.25)
		if c.carrying_amount <= 0.01: break
	var delivered := float(target.delivered.get(res,0)) if construction else target.inventory[res]
	_check(c.carrying_amount == 0 and c.job == null and target.incoming[res] == 0
		and is_equal_approx(delivered,amount)
		and c.position.distance_to(sim.entrance_of(target,"att_cart_bay")) <= Config.ARRIVE_RADIUS+0.2,
		"after drinking, %s receives the full original load exactly once by physical delivery" % target.type_id)
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"completed delivery leaves no stale stock or destination claims")
	_check(not SaveGame._capture_citizen(c,sim).has("delivery"),
		"completed loads do not leave a persistent delivery that can run twice")
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
	await _loaded_drinking_destination(false)
	await _loaded_drinking_destination(true)
	await _fire_buckets()
	await _poison_and_drinkers()
	print("Water regression failures: %d" % _failures)
	quit(1 if _failures else 0)
