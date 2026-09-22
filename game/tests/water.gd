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


func _purge_well() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var well: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	var well_id := well.id
	var enemy_well: Building = sim.campaign._enemy_type("well")
	# Poisoned, so the refusal can only be about whose well it is.
	water.wells[enemy_well.id].poison = 1.0
	water.wells[enemy_well.id].poison_days = WaterSystem.POISON_DAYS
	_check(not water.purge_quote(enemy_well.id).can_purge and water.request_purge(enemy_well.id) != ""
		and water.carriers.is_empty(),
		"a purge cannot be ordered onto the rival's well even when it is poisoned")
	water.wells[enemy_well.id].poison = 0.0
	water.wells[enemy_well.id].poison_days = 0.0
	_check(not water.purge_quote(well_id).can_purge and water.request_purge(well_id) != "",
		"a clean well offers nothing to scrub out")
	water.wells[well_id].poison = 1.0
	water.wells[well_id].poison_days = WaterSystem.POISON_DAYS
	var civilians := sim.citizens.size()
	var population := sim.population_members().size()
	_check(water.purge_quote(well_id).can_purge and water.request_purge(well_id) == "",
		"a poisoned well of our own can be ordered scrubbed out")
	_check(sim.citizens.size() == civilians-1 and sim.population_members().size() == population,
		"the purge takes a real resident off other work without removing them from the population")
	var id: int = water.carriers.keys().filter(func(k): return water.carriers[k].state in WaterSystem.PURGE_STATES)[0]
	var c: Citizen = water.carriers[id].person
	_check(water.wells[well_id].poison == 1.0 and water.wells[well_id].water == WaterSystem.CAPACITY,
		"ordering a purge neither cleans the well nor empties it from a distance")
	_check(water.request_purge(well_id) != "","a second purge cannot be stacked on the same well")
	for i in 4000:
		_water_step(game)
		if water.carriers.get(id,{}).get("state","") == "purging": break
	_check(water.carriers.has(id) and water.carriers[id].state == "purging"
		and c.global_position.distance_to(sim.entrance_of(sim.buildings_by_id[well_id],"att_entrance")) <= Config.ARRIVE_RADIUS+0.2,
		"the worker physically walks to the well before any scrubbing starts")
	_check(water.wells[well_id].water == 0.0 and water.wells[well_id].poison == 1.0
		and water.well_info(well_id).purging,
		"arriving bales the shaft dry while the water in it is still poisoned")
	var thirsty: Citizen = sim.citizens[0]
	thirsty.hydration = 0.2
	_check(water._well_for(thirsty,0) == null,
		"a well held empty for scrubbing is not offered to a thirsty resident")
	# A person who was already walking there when the shaft was baled out must be
	# let go rather than left standing at a well that will not refill for a
	# minute and a half.
	water.drinkers[water._key(thirsty)] = {"faction":0,"person_id":water._identity(thirsty),"well_id":well_id}
	_water_step(game)
	_check(not water.drinkers.has(water._key(thirsty)),
		"a drinking trip already under way is released when the well is baled dry")
	for i in 8: _water_step(game)
	_check(water.carriers[id].progress > 0.0 and water.carriers[id].progress < WaterSystem.PURGE_SECONDS
		and water.wells[well_id].poison == 1.0 and water.wells[well_id].water == 0.0,
		"onsite time accumulates, the shaft stays dry, and the well is not clean before the work is finished")
	var saved := SaveGame.capture(game)
	var mission: Dictionary = water.capture()
	_check(SaveGame.validate(saved,game.registry) == "","a purge in progress captures a valid save")
	var error := game.restore_from(saved)
	_check(error == "" and game.sim.water.capture() == mission
		and game.sim.population_members().size() == population,
		"save/load preserves the purge worker, their onsite progress and the dry well: " + error)
	sim = game.sim
	water = sim.water
	id = water.carriers.keys()[0]
	var progress: float = water.carriers[id].progress
	_check(progress > 0.0 and water.carriers[id].state == "purging",
		"restored purge resumes from the work already done, not from zero")
	_water_step(game)
	_check(water.wells[well_id].water == 0.0 and water.wells[well_id].poison == 1.0,
		"a loaded purge goes on holding the shaft dry instead of letting it refill")
	var partial := SaveGame.capture(game)
	partial.water.carriers[0].progress = WaterSystem.PURGE_SECONDS+1.0
	_check(SaveGame.validate(partial,game.registry) != "","save validation rejects invented purge progress")
	partial = SaveGame.capture(game)
	partial.water.carriers[0].state = "approach"
	_check(SaveGame.validate(partial,game.registry) != "",
		"a purge cannot bank onsite progress it never stood at the well for")
	# A save written before this feature has carrier records with no `progress` at
	# all. Validating is not enough; it has to restore, and to mean zero.
	partial = SaveGame.capture(game)
	partial.water.carriers[0].erase("progress")
	_check(SaveGame.validate(partial,game.registry) == "",
		"a carrier record without the optional purge progress passes validation")
	error = game.restore_from(partial)
	_check(error == "" and game.sim.water.carriers.size() == 1
		and game.sim.water.carriers.values()[0].progress == 0.0
		and game.sim.water.carriers.values()[0].state == "purging",
		"a carrier record without progress restores and means no work done yet: " + error)
	# Put the banked progress back and carry on from there.
	error = game.restore_from(saved)
	_check(error == "","the purge save reloads after the legacy probe: " + error)
	sim = game.sim
	water = sim.water
	id = water.carriers.keys()[0]
	# Recall halfway: the worker must come home, and the well must be left in the
	# state the settlement actually put it in - poisoned and empty.
	_check(water.cancel_purge(well_id) == "" and water.carriers.is_empty()
		and sim.citizens_by_id.has(id) and sim.citizens.size() == civilians,
		"recalling the worker returns the same resident to ordinary work")
	_check(water.wells[well_id].poison == 1.0,"a recalled purge leaves the well poisoned")
	_check(water.cancel_purge(well_id) != "","recalling twice reports that nobody is there")
	_water_step(game)
	_check(water.wells[well_id].water > 0.0,"an abandoned well starts refilling again")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a cancelled purge leaves a valid save and no detached people")
	# Order it again and let it run to the end.
	# Urgent hunger sends the worker home rather than stranding them at the well.
	_check(water.request_purge(well_id) == "","the well can be ordered scrubbed after the first recall")
	var hungry_id: int = water.carriers.keys()[0]
	water.carriers[hungry_id].person.hunger = 1.0
	_water_step(game)
	_check(water.carriers.is_empty() and sim.citizens_by_id.has(hungry_id),
		"a worker who grows too hungry to stay is returned rather than abandoned at the well")
	# The poison expiring on its own while they walk also ends the job.
	water.wells[well_id].poison_days = 0.01
	_check(water.request_purge(well_id) == "","a purge can be ordered late in the poison's life")
	var late_id: int = water.carriers.keys()[0]
	for i in 40:
		_water_step(game)
		if water.carriers.is_empty(): break
	_check(water.carriers.is_empty() and sim.citizens_by_id.has(late_id) and water.wells[well_id].poison == 0.0,
		"poison expiring on its own ends the purge and returns the worker")
	# A worker who dies on the job is buried, not silently kept detached.
	water.wells[well_id].poison = 1.0
	water.wells[well_id].poison_days = WaterSystem.POISON_DAYS
	_check(water.request_purge(well_id) == "","the well can be ordered scrubbed a second time")
	var dead_id: int = water.carriers.keys()[0]
	water.carriers[dead_id].person.service_health = 0.0
	_water_step(game)
	_check(water.carriers.is_empty() and not sim.citizens_by_id.has(dead_id)
		and sim.population_members().size() == population-1,
		"a worker who dies on the job leaves no detached person behind")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a purge worker's death leaves a valid save")
	_check(water.request_purge(well_id) == "","the well can be ordered scrubbed again after a death")
	id = water.carriers.keys()[0]
	var worker_id := id
	var onsite := 0.0
	for i in 8000:
		_water_step(game)
		if water.carriers.has(worker_id) and water.carriers[worker_id].state == "purging": onsite += 0.25
		if water.carriers.is_empty(): break
	# Both halves of the design bargain, as numbers: a real stretch of one
	# worker's day on site, and still plainly quicker than waiting the poison out.
	_check(onsite >= WaterSystem.PURGE_SECONDS and onsite >= Config.DAY_LENGTH*0.25
		and onsite < Config.DAY_LENGTH*WaterSystem.POISON_DAYS,
		"clearing the poison cost a real stretch of labour and still beat waiting it out")
	_check(water.carriers.is_empty() and water.wells[well_id].poison == 0.0 and water.wells[well_id].poison_days == 0.0,
		"finished work clears the poison outright instead of waiting it out")
	_check(sim.citizens_by_id.has(worker_id) and sim.citizens.size() == civilians-1
		and sim.population_members().size() == population-1,
		"the same worker returns to the settlement when the well is clean")
	for i in 400: _water_step(game)
	_check(water.wells[well_id].water > 0.0 and water._well_for(sim.citizens[0],0) != null,
		"the scrubbed well refills from its own inflow and is drinkable again")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a completed purge leaves a valid save")
	game.free()
	await process_frame

## A bucket carrier is handed one well when the order is made and used to keep it
## for the length of the fire. Wells do not stay full: a purge pins one to zero
## for ninety seconds, and an ordinary well can simply be drunk down. A carrier
## standing at an empty head waited for water that was not coming, and because
## the fire already had a carrier no second one could be sent -- the building
## burned to nothing with another well full a short walk away.
func _firefighter_source_changes() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var first: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	var second := _build(game,"well",first.global_position+Vector3(40,0,40))
	var target: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	target.fire = 1.0
	_check(water.request_firefighting(target.id) == "" and water.carriers.size() == 1,
		"a burning building draws a bucket carrier while two wells stand full")
	var fid: int = water.carriers.keys()[0]
	var source_id: int = water.carriers[fid].well_id
	var spare_id: int = second.id if source_id == first.id else first.id
	var source: Building = sim.buildings_by_id[source_id]
	water.wells[source_id].poison = 1.0
	water.wells[source_id].poison_days = WaterSystem.POISON_DAYS
	var purger := water._purge_worker(source)
	_check(purger != null and purger != water.carriers[fid].person,
		"a second resident, not the firefighter, is available to scrub that well")
	purger.global_position = sim.entrance_of(source,"att_entrance")
	_check(water.request_purge(source_id) == "",
		"the well the firefighter draws from can be ordered scrubbed out")
	for i in 8000:
		_water_step(game)
		if water._scrubbing(source_id): break
	_check(water._scrubbing(source_id) and water.wells[source_id].water == 0.0
		and water.wells[spare_id].water > 0.0 and target.fire == 1.0,
		"the carrier's own source is baled dry while the other well is still full and the fire still burns")
	_check(water.request_firefighting(target.id) != "",
		"no second carrier can be sent to a fire that already has one")
	var switched := false
	for i in 8000:
		_water_step(game)
		if water.carriers.has(fid) and water.carriers[fid].well_id == spare_id: switched = true
		if target.fire <= 0.0: break
	_check(switched and target.fire == 0.0,
		"a firefighter whose well is baled dry fetches from the other one instead of letting the building burn")
	for i in 400:
		_water_step(game)
		if not water.carriers.has(fid): break
	_check(not water.carriers.has(fid) and sim.citizens_by_id.has(fid),
		"the reassigned firefighter still comes home when the fire is out")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a firefighter that changed wells leaves a valid save")
	game.free()
	await process_frame

## The other half of the same bargain. A purge is bought with an empty shaft, so
## nothing may tip water back into one while the scrubbing is under way -- four
## units returned by a stood-down firefighter were four the settlement could then
## be offered a drink from, out of a well it was holding dry on purpose.
func _firefighter_cannot_refill_a_scrubbed_well() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var first: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	_build(game,"well",first.global_position+Vector3(40,0,40))
	var target: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	target.fire = 1.0
	_check(water.request_firefighting(target.id) == "","a burning building draws a bucket carrier")
	var fid: int = water.carriers.keys()[0]
	for i in 8000:
		_water_step(game)
		if water.carriers[fid].state == "carry": break
	var source_id: int = water.carriers[fid].well_id
	var source: Building = sim.buildings_by_id[source_id]
	_check(water.carriers[fid].state == "carry" and water.carriers[fid].person.water_bucket > 0,
		"the carrier is holding water it physically drew from that well")
	water.wells[source_id].poison = 1.0
	water.wells[source_id].poison_days = WaterSystem.POISON_DAYS
	var purger := water._purge_worker(source)
	purger.global_position = sim.entrance_of(source,"att_entrance")
	_check(water.request_purge(source_id) == "","that same well can be ordered scrubbed out")
	for i in 8000:
		_water_step(game)
		if water._scrubbing(source_id): break
	_check(water._scrubbing(source_id) and water.wells[source_id].water == 0.0,
		"the shaft is baled dry with the carrier's bucket already full")
	# The fire goes out by itself, which is what sends the carrier home with water
	# it never used.
	target.fire = 0.0
	for i in 8000:
		_water_step(game)
		if not water.carriers.has(fid): break
	_check(not water.carriers.has(fid) and sim.citizens_by_id.has(fid),
		"the stood-down firefighter returns to ordinary work")
	_check(water._scrubbing(source_id) and water.wells[source_id].water == 0.0,
		"an unused bucket is never tipped back into a well being held dry for scrubbing")
	var thirsty: Citizen = sim.citizens[0]
	thirsty.hydration = 0.2
	_check(water._well_for(thirsty,0) != null and water._well_for(thirsty,0).id != source_id,
		"the scrubbed well is still not offered to a thirsty resident")
	game.free()
	await process_frame

## The same ending, reached while the carrier is away drinking. Nothing may make
## a detached person wait on a trip that has no guaranteed end before it hands
## them back: that is how a purger was lost for good, and a bucket carrier is
## detached by the same call.
func _firefighter_returns_while_drinking() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var first: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	_build(game,"well",first.global_position+Vector3(40,0,40))
	var target: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	target.fire = 1.0
	_check(water.request_firefighting(target.id) == "","a burning building draws a bucket carrier")
	var fid: int = water.carriers.keys()[0]
	var c: Citizen = water.carriers[fid].person
	for i in 8000:
		_water_step(game)
		if water.carriers[fid].state == "carry": break
	# A few steps off the wellhead, so thirst is a journey rather than a sip.
	for i in 6:
		_water_step(game)
		if water.carriers[fid].state != "carry": break
	_check(water.carriers[fid].state == "carry" and c.water_bucket > 0,
		"the carrier is walking to the fire with a full bucket")
	c.hydration = 0.2
	_water_step(game)
	_check(water.drinkers.has(water._key(c)) and water.carriers.has(fid) and not sim.citizens_by_id.has(fid),
		"a thirsty carrier goes for a drink while still detached into water service")
	# The fire goes out by itself while they are away at the well.
	target.fire = 0.0
	_water_step(game)
	_check(water.carriers.is_empty() and sim.citizens_by_id.has(fid) and c.water_bucket == 0,
		"a bucket carrier with nothing left to fight is handed back the same tick, drinking or not")
	_check(water.drinkers.has(water._key(c)),
		"and finishes the drink they were part way through as an ordinary resident")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"standing a drinking carrier down leaves a valid save")
	game.free()
	await process_frame

## A purge worker is still a person: with their own well baled dry they walk to
## another one when they get thirsty. While they were away the job stopped
## listening to everything that ends it -- so a well whose poison expired stayed
## pinned dry for the rest of the game, and a well demolished under them left the
## worker in `carriers` and out of `citizens_by_id` for good.
func _purge_ends_while_its_worker_drinks() -> void:
	for scenario in ["poison expired","well demolished"]:
		var game := _prepare_scouts()
		var sim := game.sim
		var water: WaterSystem = sim.water
		var well: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
		var well_id := well.id
		var spare := _build(game,"well",well.global_position+Vector3(40,0,40))
		water.wells[well_id].poison = 1.0
		water.wells[well_id].poison_days = WaterSystem.POISON_DAYS
		_check(water.request_purge(well_id) == "","a poisoned well is ordered scrubbed out (%s)" % scenario)
		var id: int = water.carriers.keys()[0]
		var c: Citizen = water.carriers[id].person
		for i in 8000:
			_water_step(game)
			if water.carriers[id].state == "purging": break
		_check(water.carriers[id].state == "purging" and water.wells[well_id].water == 0.0,
			"the worker reaches the well and bales it dry (%s)" % scenario)
		c.hydration = 0.2
		_water_step(game)
		_check(water.drinkers.get(water._key(c),{}).get("well_id",-1) == spare.id
			and water.carriers.has(id) and not sim.citizens_by_id.has(id),
			"the thirsty purger walks to the other well while still detached into water service (%s)" % scenario)
		if scenario == "poison expired":
			water.wells[well_id].poison = 0.0
			water.wells[well_id].poison_days = 0.0
			for i in 20: _water_step(game)
			_check(water.drinkers.has(water._key(c)),
				"the drinking trip is still under way when the poison goes (%s)" % scenario)
			_check(water.carriers.is_empty() and sim.citizens_by_id.has(id)
				and not water._scrubbing(well_id) and water.wells[well_id].water > 0.0,
				"poison expiring under an absent purger ends the job and lets the well refill")
		else:
			sim.demolish(well)
			_water_step(game)
			_check(water.carriers.is_empty() and sim.citizens_by_id.has(id),
				"demolishing the well an absent purger was scrubbing brings the worker home instead of losing them")
		_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
			"the settlement still saves after a purge ended mid-drink (%s)" % scenario)
		game.free()
		await process_frame

## `detach_for_service` hands the cart back but leaves the load on the person's
## back, so who may be sent to a well is also a question about what the save can
## hold: a carter taken off a cartload arrived in `carriers` holding four times
## what a pair of hands may, and `validate` refused the settlement outright until
## the order was cancelled.
func _purge_never_takes_a_loaded_carter() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var well: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	var store: Building = sim.buildings.filter(func(b): return b.type_id == "stockpile")[0]
	var c: Citizen = sim.citizens[0]
	sim.keep.inventory[Config.Res.TIMBER] = Cart.CAPACITY
	var job := sim.jobs.post(JobBoard.Kind.HAUL,c.position,1000.0)
	job.source_id = sim.keep.id
	job.dest_id = store.id
	job.res = Config.Res.TIMBER
	job.amount = Cart.CAPACITY
	job.uses_cart = true
	sim.jobs.index(job)
	sim.keep.reserved[Config.Res.TIMBER] += Cart.CAPACITY
	store.incoming[Config.Res.TIMBER] += Cart.CAPACITY
	c.job = sim.jobs.best_for(c.id,c.position,JobBoard.Accept.ANY,-1)
	_check(c.job == job,"the first resident claims the cart haul")
	for i in 8000:
		sim._tick_haul(c,0.25)
		if c.carrying_amount > 0.0: break
	_check(c.has_cart() and c.carrying_amount > Config.CARRY_CAPACITY,
		"the carter physically collects a cartload, more than a pair of hands may hold")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a loaded carter is by itself a valid thing to save")
	water.wells[well.id].poison = 1.0
	water.wells[well.id].poison_days = WaterSystem.POISON_DAYS
	_check(water._purge_worker(well) != null and water._purge_worker(well) != c,
		"the purge passes over the loaded carter and finds a resident with free hands")
	_check(water.purge_quote(well.id).can_purge and water.request_purge(well.id) == ""
		and water.carriers.values()[0].person != c,
		"the order is still available and takes that other resident, not the one under a cartload")
	_check(c.carrying_amount > Config.CARRY_CAPACITY and c.job == job and sim.citizens_by_id.get(c.id) == c,
		"the carter keeps their load, their delivery and their place in the settlement")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"ordering a purge never leaves a settlement that cannot be saved")
	game.free()
	await process_frame

## A purge pins its well to zero for the whole ninety seconds, and a march begins
## with exactly one well. Held dry, `_well_for` skips it, `_fire_source` returns
## null and `request_firefighting` refused every candidate -- so one purge
## disarmed the settlement's entire firefighting response, and the automatic
## dispatcher at the top of `_tick` went on failing at it every two seconds with
## nobody told. Measured with fire spread live, the keep ended on 39 of 800 HP
## against 746 with no purge ordered: not a slower answer, a lost game. Fire
## outranks scrubbing -- the purge is broken off and the buckets wait on the
## shaft refilling.
func _fire_outranks_a_purge() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	# The purge can also end by hunger, demolition or the poison expiring, and
	# none of those scrub the well either -- so "still poisoned" alone does not
	# say the fire was what ended it. The alert does.
	var alerts: Array = []
	sim.alert.connect(func(text: String, _at: Vector3): alerts.append(text))
	var only: Array = sim.buildings.filter(func(b): return b.type_id == "well")
	_check(only.size() == 1,"the settlement under test has exactly one well")
	var well: Building = only[0]
	var well_id := well.id
	_check(water.purge_quote(well_id).sole_well and water.well_info(well_id).sole_well,
		"the order and the panel both report this is the settlement's only well")
	water.wells[well_id].poison = 1.0
	water.wells[well_id].poison_days = WaterSystem.POISON_DAYS
	var purger := water._purge_worker(well)
	_check(purger != null,"a resident with free hands can reach the poisoned well")
	var purger_id := purger.id
	purger.global_position = sim.entrance_of(well,"att_entrance")
	_check(water.request_purge(well_id) == "","the settlement's only well can be ordered scrubbed out")
	for i in 8000:
		_water_step(game)
		if water._scrubbing(well_id): break
	_check(water._scrubbing(well_id) and water.wells[well_id].water == 0.0,
		"the only well is baled dry for the scrubbing")
	var target: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	var target_id := target.id
	target.fire = 1.0
	_check(water._fire_crew(target).is_empty() and water._scrubbing(well_id)
		and water.carriers.values()[0].progress < WaterSystem.PURGE_SECONDS*0.5,
		"the shaft is empty, the scrubbing has most of its ninety seconds to run, and no resident can fill a bucket anywhere")
	# Deliberately not a player order: this is the settlement's own dispatcher,
	# the path that was failing silently every two seconds. And deliberately
	# bounded -- an unbounded loop passes on a settlement that simply waits the
	# purge out and fights the fire eighty seconds later, which is the defect.
	# The loop runs ten seconds; the assertion demands six, so the bound is a real
	# one and not just the loop's own ceiling restated. Six is the dispatcher's
	# two-second cadence with room to spare over the four seconds this measures.
	var waited := 0.0
	for i in 40:
		if water._firefighters() > 0: break
		_water_step(game)
		waited += 0.25
	_check(water._firefighters() > 0 and waited <= 6.0,
		"a burning building gets a bucket carrier within seconds of catching, not when the purge ends (waited %.2fs)" % waited)
	_check(not water._scrubbing(well_id) and water.wells[well_id].water > 0.0,
		"the purge gave way and the shaft is refilling")
	_check(water.wells[well_id].poison == 1.0,"breaking the purge off scrubbed nothing -- the well is still poisoned")
	_check(sim.citizens_by_id.has(purger_id),"the purge worker went back to ordinary work rather than being lost")
	_check(water.purge_quote(well_id).can_purge,"the player can order the purge again once the fire is answered")
	for i in 20000:
		_water_step(game)
		if sim.buildings_by_id[target_id].fire <= 0.0: break
	_check(sim.buildings_by_id[target_id].fire == 0.0,
		"the fire is actually put out with water drawn from the released well")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a purge broken off by a fire leaves a valid save")
	_check(alerts.count("Well scrubbing broken off to fight the fire — the shaft is refilling, and the water is still poisoned.") == 1,
		"the player is told once that the fire broke the scrubbing off, so the fire is what ended it")
	# And the negative control: a purge must not be cancelled for a shortage it is
	# no part of. `_fire_crew` comes back empty just as readily when every pair of
	# hands in the settlement is full, and the well being scrubbed is no more the
	# cause of that than any other well is.
	var spare := _build(game,"well",well.global_position+Vector3(40,0,40))
	_water_step(game)
	_check(water.wells[spare.id].water > 0.0 and not water.purge_quote(well_id).sole_well
		and not water.well_info(well_id).sole_well,
		"a second well stands full and neither the order nor the panel calls the first one the only well now")
	purger = water._purge_worker(well)
	_check(purger != null,"a resident is free to scrub the well out a second time")
	purger.global_position = sim.entrance_of(well,"att_entrance")
	_check(water.request_purge(well_id) == "","the poisoned well is ordered scrubbed out again")
	for i in 8000:
		_water_step(game)
		if water._scrubbing(well_id): break
	_check(water._scrubbing(well_id),"the second scrubbing is under way")
	var scrubber: Citizen = water.carriers.values()[0].person
	target = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	target.fire = 1.0
	# Every hand in the settlement full, the scrubber's included: the fire cannot
	# be answered, and the reason is labour, not the shaft.
	var loads := {}
	for person in sim.citizens:
		loads[person.id] = person.carrying_amount
		person.carrying_amount = Config.CARRY_CAPACITY
	var scrubber_load := scrubber.carrying_amount
	scrubber.carrying_amount = Config.CARRY_CAPACITY
	_check(water._fire_crew(target).is_empty(),"no resident in the settlement has a hand free for a bucket")
	_check(not water._break_purges_for_fire(target) and water._scrubbing(well_id),
		"a fire nobody has hands to fight never cancels the scrubbing")
	# Free one pair of hands and the same call breaks it, so the control above is
	# the labour and not something else about this settlement.
	for person in sim.citizens:
		person.carrying_amount = loads[person.id]
	scrubber.carrying_amount = scrubber_load
	_check(water._break_purges_for_fire(target) and not water._scrubbing(well_id),
		"with hands free again the same fire does break the scrubbing off")
	game.free()
	await process_frame

## The same rule reached from the other side, and the half `request_firefighting`
## cannot answer: the fire is already held by a carrier, so the order refuses a
## second one outright and never gets as far as looking at the purge. Here the
## carrier is dispatched from a full well and the purge is ordered afterwards, so
## the purger walks up and bales the shaft dry under somebody already standing on
## it -- which is how a building burned to nothing with a firefighter at the head
## in the first place. `_fire_tick` has to ask the question itself.
func _purge_gives_way_under_a_standing_carrier() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var water: WaterSystem = sim.water
	var well: Building = sim.buildings.filter(func(b): return b.type_id == "well")[0]
	var well_id := well.id
	var target: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	var target_id := target.id
	target.fire = 1.0
	_check(water.request_firefighting(target.id) == "" and water._firefighters() == 1,
		"a burning building draws a carrier while the only well still holds water")
	var fid: int = water.carriers.keys()[0]
	water.wells[well_id].poison = 1.0
	water.wells[well_id].poison_days = WaterSystem.POISON_DAYS
	var purger := water._purge_worker(well)
	_check(purger != null and purger.id != fid,"a second resident, not the firefighter, can scrub the well out")
	purger.global_position = sim.entrance_of(well,"att_entrance")
	_check(water.request_purge(well_id) == "","the only well can be ordered scrubbed with a carrier already drawing from it")
	# Drunk down to nothing before the purger arrives, so the carrier cannot fill
	# and walk off with the fire before the scrubbing starts. The purge would
	# leave it here in any case; this only fixes when.
	water.wells[well_id].water = 0.0
	_check(water.request_firefighting(target_id) != "",
		"no second carrier can be sent to a fire that already has one, so the order cannot break the purge itself")
	var baled := false
	for i in 2000:
		_water_step(game)
		if water._scrubbing(well_id):
			baled = true
			break
	_check(baled and water.carriers.has(fid),
		"the purger reaches the well and bales it under a carrier who is still on the job")
	# Bounded for the same reason as above: waiting the purge out is the defect,
	# not the fix.
	var waited := 0.0
	for i in 40:
		if not water._scrubbing(well_id): break
		_water_step(game)
		waited += 0.25
	_check(not water._scrubbing(well_id) and waited <= 2.0 and water.carriers.has(fid)
		and water.wells[well_id].poison == 1.0,
		"the purge gives way within seconds to the carrier standing at the dry head, and scrubs nothing (waited %.2fs)" % waited)
	for i in 20000:
		_water_step(game)
		if sim.buildings_by_id[target_id].fire <= 0.0: break
	_check(sim.buildings_by_id[target_id].fire == 0.0,
		"the carrier puts the fire out with water drawn from the released well")
	for i in 400:
		_water_step(game)
		if not water.carriers.has(fid): break
	_check(not water.carriers.has(fid) and sim.citizens_by_id.has(fid),
		"the carrier is handed back to ordinary work once the fire is out")
	_check(SaveGame.validate(SaveGame.capture(game),game.registry) == "",
		"a purge broken off under a standing carrier leaves a valid save")
	game.free()
	await process_frame

func _run() -> void:
	await _hydration_and_claims()
	await _loaded_drinking_destination(false)
	await _loaded_drinking_destination(true)
	await _fire_buckets()
	await _poison_and_drinkers()
	await _purge_well()
	await _firefighter_source_changes()
	await _firefighter_cannot_refill_a_scrubbed_well()
	await _firefighter_returns_while_drinking()
	await _purge_ends_while_its_worker_drinks()
	await _purge_never_takes_a_loaded_carter()
	await _fire_outranks_a_purge()
	await _purge_gives_way_under_a_standing_carrier()
	print("Water regression failures: %d" % _failures)
	quit(1 if _failures else 0)
