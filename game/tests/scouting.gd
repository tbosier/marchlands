extends "res://tests/long_run.gd"

func _prepare_scouts() -> SeededGame:
	var game := _new_game(42)
	game.sim.campaign.personality = "peaceful"
	for job in game.sim.jobs.all_jobs():
		game.sim._release_reservations(job)
		game.sim.jobs.cancel(job)
	for c in game.sim.citizens:
		game.sim._release_cart(c)
		game.sim._go_idle(c)
	_build(game,"scout_lodge",game.world.centre()+Vector3(-48,0,24))
	_build(game,"market",game.world.centre()+Vector3(-48,0,-24))
	game.sim.keep.inventory.fill(0)
	game.sim.keep.inventory[Config.Res.TOOLS] = 40
	game.sim.keep.inventory[Config.Res.FOOD] = 140
	game.sim.keep.inventory[Config.Res.TIMBER] = 100
	return game

func _advance(game: SeededGame, count: int = 1) -> void:
	for i in count:
		game.sim.day += 0.25 / Config.DAY_LENGTH
		game.sim.scouting.tick(0.25)

func _until_scout(game: SeededGame, state: String, limit: int = 20000) -> bool:
	for i in limit:
		if game.sim.scouting.scouts.is_empty(): return state == "finished"
		if game.sim.scouting.scouts.values()[0].state == state: return true
		_advance(game)
	return false

func _training_and_intel() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var manager: Scouting = sim.scouting
	var person: Citizen = sim.citizens[0]
	var identity := person.id
	var name_before := person.given_name
	var population := sim.population_members().size()
	var tools_before := sim.keep.inventory[Config.Res.TOOLS]
	_check(manager.city_report().is_empty() and not manager.explored_at(sim.campaign.rival_position),"a new march has no remote city report or explored remote terrain")
	var quote: Dictionary = sim.trade.quotes()[0]
	_check(not quote.ok and quote.target_id == -1 and quote.reason.contains("Discover"),"undiscovered town does not leak its target or trade offer")
	var lodge: Building = manager._lodge()
	_check(manager.train(lodge.id,identity) == "","a completed lodge assigns an existing resident")
	var scout: Scout = manager.scouts.values()[0]
	_check(scout.person == person and sim.population_members().size() == population and not sim.citizens_by_id.has(identity),"scout assignment keeps the same person and housing without creating population")
	_check(sim.keep.inventory[Config.Res.TOOLS] == tools_before and scout.tools == 0 and scout.food == 0,"assignment reserves but does not teleport training stock")
	_check(manager.command(scout.id,sim.campaign.rival_position) != "","an untrained scout cannot explore")
	for phase in ["food","tools","lodge","training","ready"]:
		_check(_until_scout(game,phase),"scout physically reaches " + phase)
		var snapshot := SaveGame.capture(game)
		var before: Dictionary = game.sim.scouting.capture()
		var old_fog := game.world.fog
		var old_manager := game.sim.scouting
		var error := game.restore_from(snapshot)
		_check(error == "" and game.sim.scouting.capture() == before,"full save preserves scout phase, exact identity, reservations and explored map during " + phase + ": " + error)
		_check(not is_instance_valid(old_fog) and not is_instance_valid(old_manager) and game.world.fog.scouting == game.sim.scouting and game.world.fog._campaign == game.sim.campaign,"adoption replaces fog and vision references during " + phase)
		if error != "": break
	manager = game.sim.scouting
	scout = manager.scouts.values()[0]
	_check(game.sim.keep.inventory[Config.Res.TOOLS] == tools_before-Scouting.TOOL_COST and scout.tools == 0 and scout.food > 0,"training consumes exactly the physically delivered tools and real food")
	_check(manager.visit_city(scout.id) != "","unknown rulers cannot be selected using hidden coordinates")
	var approach: Vector3 = game.sim.campaign.rival_position + Vector3(-75,0,0)
	approach.y = game.world.heightmap.height_at(approach.x,approach.z)
	_check(manager.command(scout.id,approach) == "","trained scout can receive a reachable exploration order")
	_check(_until_scout(game,"ready"),"scout walks into view of the town")
	manager.refresh_visibility()
	var observed := manager.city_report()
	_check(not observed.is_empty() and observed.source == "observation" and observed.population_text.contains("estimated") and observed.military_text.contains("observed"),"physical observation provides estimated residents and observed troops")
	_check(manager.visit_city(scout.id) == "" and _until_scout(game,"ready"),"scout physically visits the ruler at the keep entrance")
	var report := manager.city_report()
	_check(report.get("source","") == "ruler" and report.population_text == "%d residents confirmed" % (game.sim.campaign.town_population+3),"only the keep visit obtains a confirmed census including soldiers")
	var interview_snapshot := SaveGame.capture(game)
	var interview_error := game.restore_from(interview_snapshot)
	manager = game.sim.scouting
	scout = manager.scouts.values()[0]
	_check(interview_error == "" and manager.city_report() == report,"loading a scout at the keep preserves the confirmed interview instead of downgrading it")
	var census: String = report.population_text
	game.sim.campaign.town_population += 5
	_check(manager.city_report().population_text == census,"remote population changes do not rewrite a historical interview")
	scout.health = 63
	_check(manager.recall(scout.id) == "" and _until_scout(game,"finished"),"recall physically returns and unloads remaining supplies")
	var returned: Citizen = game.sim.citizens_by_id.get(identity)
	_check(returned != null and returned.given_name == name_before and returned.service_health == 63 and game.sim.population_members().size() == population,"return preserves citizen identity, damage and population")
	manager.refresh_visibility()
	_check(not manager.visibility_at(report.position) and manager.explored_at(report.position),"departed scouts leave explored fog rather than live vision")
	var observer: Citizen = game.sim.citizens[1]
	var old_position := observer.global_position
	observer.global_position = report.position
	manager.refresh_visibility()
	_check(manager.city_report().source == "observation" and manager.city_report().ruler_history.population_text == census,"later observers refresh estimates while preserving the dated ruler census")
	observer.global_position = old_position
	game.free()
	await process_frame

func _interruptions_and_validation() -> void:
	var game := _prepare_scouts()
	var manager: Scouting = game.sim.scouting
	var lodge: Building = manager._lodge()
	var person: Citizen = game.sim.citizens[0]
	var stock := game.sim.keep.inventory.duplicate()
	_check(manager.train(lodge.id,person.id) == "","interruption fixture assigns a scout")
	var scout: Scout = manager.scouts.values()[0]
	_check(manager.recall(scout.id) == "" and game.sim.keep.inventory == stock and game.sim.keep.reserved[Config.Res.TOOLS] == 0 and game.sim.keep.reserved[Config.Res.FOOD] == 0,"recall before pickup releases promises without refunds or stock creation")
	_check(_until_scout(game,"finished"),"cancelled training returns the original resident")
	_check(manager.train(lodge.id,person.id) == "" and _until_scout(game,"tools"),"interrupted scout collects food before tools")
	scout = manager.scouts.values()[0]
	var saved := SaveGame.capture(game)
	var invalid := saved.duplicate(true)
	invalid.citizens.append(invalid.scouting.scouts[0].citizen.duplicate(true))
	_check(SaveGame.validate(invalid,game.registry).contains("identity"),"save rejects one resident shared by scout and civilian roles")
	invalid = saved.duplicate(true)
	invalid.scouting.scouts[0].food = 99.0
	_check(SaveGame.validate(invalid,game.registry) != "","save rejects invented scout pack quantities")
	invalid = saved.duplicate(true)
	invalid.scouting.explored.resize(2)
	_check(SaveGame.validate(invalid,game.registry) != "","save rejects malformed explored maps before adoption")
	var total_tools := game.sim.keep.inventory[Config.Res.TOOLS]
	_check(manager.restore(saved.scouting) != "" and game.sim.keep.inventory[Config.Res.TOOLS] == total_tools,"direct restore cannot duplicate active identities or stock promises")
	var contact: Array = []
	game.sim.alert.connect(func(message: String, at: Vector3): contact.append([message,at]))
	var incident: Vector3 = game.sim.campaign.rival_position
	scout.person.global_position = incident
	scout.health = 1
	game.sim.campaign.at_war = true
	var patrol: Soldier = game.sim.campaign.units.values()[0]
	patrol.global_position = incident
	_advance(game)
	game.sim.campaign.at_war = false
	_check(manager.scouts.is_empty() and contact.back()[0].contains("Lost contact") and contact.back()[1].distance_to(incident) > 40,"scout loss reports missing contact without disclosing the hidden incident")
	_check(game.sim.population_members().size() == 19 and game.sim.keep.reserved[Config.Res.TOOLS] == 0,"dead scouts release promises and their body is not returned as a new citizen")
	var legacy := SaveGame.capture(game)
	legacy.erase("scouting")
	var error := game.restore_from(legacy)
	_check(error == "" and game.sim.scouting.scouts.is_empty() and game.sim.scouting.city_report().is_empty(),"old saves restore local vision without granting remote intelligence: " + error)
	game.free()
	await process_frame

func _veteran_conditions() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	_build(game,"barracks",game.world.centre()+Vector3(60,0,12))
	_check(sim.campaign.recruit() == "","condition fixture recruits a real resident")
	var unit: Soldier = sim.campaign.units[sim.campaign.friendly_ids()[0]]
	unit.receive_hit("lower_arm_r","slash",10.0)
	var before := unit.capture_body()
	var expected := before.duplicate(true)
	Soldier.Body.advance(expected,0.25)
	sim.tick(0.25)
	_check(is_equal_approx(unit.capture_body().blood,expected.blood),"active army condition advances once rather than in both simulation and campaign")
	_check(sim.campaign.demobilize(unit.id) == "","injured soldier returns to a civilian role")
	var identity := unit.id
	expected = unit.capture_body().duplicate(true)
	Soldier.Body.advance(expected,0.25)
	sim.tick(0.25)
	_check(is_equal_approx(unit.capture_body().blood,expected.blood),"civilian veteran bleeding continues exactly once per simulation tick")
	unit.rations = 0
	_check(sim.scouting.train(sim.scouting._lodge().id,identity) == "","injured working veteran can enter scout training")
	var scout: Scout = sim.scouting.scouts.values()[0]
	expected = unit.capture_body().duplicate(true)
	Soldier.Body.advance(expected,0.25)
	sim.tick(0.25)
	_check(scout.person == unit and is_equal_approx(unit.capture_body().blood,expected.blood),"scout transfer preserves the body node and bleeding does not freeze or tick twice")
	var previous_position := unit.global_position
	unit.global_position = game.sim.campaign.rival_position + Vector3(-60,0,0)
	unit.hunger = 1.0
	var strain_before: float = unit.capture_body().strain
	unit.pick_up(Config.Res.FOOD,1.0,game.registry)
	game.sim.scouting._feed(scout,0.25)
	_check(unit.carrying_amount < 1.0 and unit.capture_body().strain == strain_before,
		"scout eats existing hand-carried food before starving with provisions on their person")
	unit.drop()
	unit.hunger = 1.0
	game.sim.scouting._feed(scout,0.25)
	_check(unit.capture_body().strain > strain_before and unit.service_health == 100.0,
		"scout veteran starvation damages their persistent body rather than a second ignored health pool")
	unit.global_position = previous_position
	var saved := SaveGame.capture(game)
	var body := unit.capture_body()
	var error := game.restore_from(saved)
	scout = game.sim.scouting.scouts.values()[0]
	_check(error == "" and scout.person is Soldier and scout.person.capture_body() == body,"full save preserves a scout's veteran wounds, blood, skills and kits: " + error)
	scout.person.receive_hit("neck","slash",35.0)
	for i in 300:
		game.sim.tick(1.0)
		if game.sim.scouting.scouts.is_empty(): break
	_check(game.sim.scouting.scouts.is_empty() and not game.sim.citizens_by_id.has(identity),"a bleeding scout eventually dies without reappearing in civilian work")
	game.free()
	await process_frame

func _merchants_and_shared_stock() -> void:
	var game := _prepare_scouts()
	var manager: Scouting = game.sim.scouting
	var observer: Citizen = game.sim.citizens[0]
	var home := observer.global_position
	observer.global_position = game.sim.campaign.rival_position
	manager.refresh_visibility()
	observer.global_position = home
	manager.refresh_visibility()
	_check(manager.train(manager._lodge().id,observer.id) == "" and game.sim.trade.dispatch() == "","a scout and merchant reserve different shares of the same real store")
	var snapshot := SaveGame.capture(game)
	_check(SaveGame.validate(snapshot,game.registry) == "","shared merchant and scout promises validate with sufficient stock")
	var invalid := snapshot.duplicate(true)
	var route: Dictionary = invalid.trade.caravans[0]
	for b in invalid.buildings:
		if b.id == route.food_source_id: b.inventory[Config.Res.FOOD] = maxf(route.pack_amount,Scouting.FOOD_PACK)
	_check(SaveGame.validate(invalid,game.registry).contains("service reservations"),"combined role validation rejects spending one food stack twice")
	var scout: Scout = manager.scouts.values()[0]
	manager.recall(scout.id)
	_check(_until_scout(game,"finished"),"scout cancellation leaves the merchant's stock promises intact")
	var legacy := SaveGame.capture(game)
	legacy.erase("scouting")
	var error := game.restore_from(legacy)
	manager = game.sim.scouting
	_check(error == "" and manager.city_report().get("source","") == "merchant route","legacy saves retain the destination known to an existing merchant route")
	var caravan: Caravan = game.sim.trade.caravans.values()[0]
	_check(manager.command(caravan.id,game.sim.campaign.rival_position) != "","merchant assignment cannot be ordered to explore")
	var last_seen: float = manager.city_report().last_seen_day
	game.sim.day += 1.0
	caravan.merchant.global_position = game.sim.campaign.rival_position
	manager.refresh_visibility()
	_check(manager.city_report().source == "observation" and manager.city_report().last_seen_day > last_seen,"merchants physically at town refresh observations without a ruler interview")
	game.free()
	await process_frame

func _run() -> void:
	await _training_and_intel()
	await _interruptions_and_validation()
	await _veteran_conditions()
	await _merchants_and_shared_stock()
	print("Scouting regression failures: %d" % _failures)
	quit(1 if _failures else 0)
