extends "res://tests/scouting.gd"


func _contact_alerts() -> void:
	var game := _prepare_scouts()
	var campaign: FrontierCampaign = game.sim.campaign
	var manager: Scouting = game.sim.scouting
	var guard: Soldier = campaign.units.values()[0]
	var alerts: Array = []
	game.sim.alert.connect(func(message: String, position: Vector3):
		alerts.append({"message": message, "position": position}))
	manager._visible.fill(0)
	campaign._tick_security(1.0)
	_check(alerts.is_empty(), "hidden enemy units produce no contact alert")
	manager._reveal(guard.position, 32.0)
	campaign._tick_security(1.0)
	_check(alerts.size() == 1 and alerts[0].message.contains("Armed neighbors")
		and not campaign.at_war, "visible neutral guards are reported without declaring war")
	var observed: Vector3 = alerts[0].position
	for i in 120: campaign._tick_security(1.0)
	_check(alerts.size() == 1, "continuous sight does not repeat contact notifications")
	campaign.at_war = true
	campaign._tick_security(0.1)
	_check(alerts.size() == 2 and alerts[1].message.contains("Enemy soldiers"),
		"visible armed neighbors trigger a fresh warning when they become hostile")
	var recorded := campaign.capture()
	_check(FrontierCampaign.validate(recorded) == "" and campaign.restore(recorded) == ""
		and campaign.capture().security == recorded.security,
		"contact identities and cooldown survive campaign restoration")
	campaign._tick_security(0.1)
	_check(alerts.size() == 2, "loading does not replay an already reported hostile contact")
	manager._visible.fill(0)
	guard = campaign.units.values()[0]
	guard.position += Vector3(0, 0, 80)
	campaign._tick_security(1.0)
	_check(alerts.size() == 2 and alerts[0].position == observed,
		"an unseen moving guard cannot update the earlier alert position")
	manager._reveal(guard.position, 24.0)
	campaign._tick_security(1.0)
	_check(alerts.size() == 2, "brief sight flicker respects the notification cooldown")
	campaign._tick_security(FrontierCampaign.CONTACT_COOLDOWN)
	_check(alerts.size() == 3 and alerts[2].position == guard.position,
		"a newly observed contact eventually reports its current observed position")
	var invalid := recorded.duplicate(true)
	invalid.security.cooldown = INF
	var before := campaign.capture()
	_check(campaign.restore(invalid) != "" and campaign.capture() == before,
		"invalid contact scheduling state is rejected without changing the campaign")
	game.free()
	await process_frame


func _scout_interception() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	_check(sim.scouting.train(sim.scouting._lodge().id) == ""
		and _until_scout(game, "ready"), "security fixture trains a real citizen scout")
	var scout: Scout = sim.scouting.scouts.values()[0]
	var guard: Soldier = campaign.units.values()[0]
	var destination := guard.position + Vector3(0, 0, -22)
	destination.y = game.world.heightmap.height_at(destination.x, destination.z)
	_check(game.world.nav.can_reach(guard.position, destination), "guard and scout have a physical interception route")
	scout.person.position = destination
	_check(not campaign._tick_guard_security(guard) and not campaign.at_war,
		"a peaceful scout visit does not provoke guards without hostile intent")
	campaign.at_war = true
	var start := guard.position
	_check(campaign._tick_guard_security(guard) and guard.has_goal(),
		"a guard detects a hostile scout inside sixty metres and orders pursuit")
	for i in 160:
		campaign._tick_guard_security(guard)
		guard.tick(0.25, game.world)
		if guard.position.distance_to(scout.person.position) <= 3.0: break
	_check(guard.position.distance_to(start) > 5.0
		and guard.position.distance_to(scout.person.position) <= 3.0,
		"guard walks the route and reaches the scout rather than applying remote damage")
	guard.cooldown = 0.0
	var health := scout.health
	sim.scouting._danger(scout, 0.25)
	var wounded := scout.health
	sim.scouting._danger(scout, 0.25)
	_check(wounded < health and scout.health == wounded and guard.cooldown > 0.0,
		"contact wounds the scout and shares the guard's ordinary attack cooldown")
	scout.person.position = game.world.centre()
	_check(not campaign._tick_guard_security(guard) and not guard.has_goal(),
		"a scout beyond guard sight is no longer tracked or chased to a hidden position")
	game.free()
	await process_frame


func _run() -> void:
	await _contact_alerts()
	await _scout_interception()
	await _sabotage_interruption()
	print("Frontier security regression failures: %d" % _failures)
	quit(1 if _failures else 0)


func _sabotage_interruption() -> void:
	var game := _prepare_scouts()
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	_check(sim.scouting.train(sim.scouting._lodge().id) == ""
		and _until_scout(game, "ready"), "sabotage fixture trains an existing resident")
	var scout: Scout = sim.scouting.scouts.values()[0]
	var well := campaign._enemy_type("well")
	_check(well != null and sim.water != null, "rival settlement has a physical well and water manager")
	if well == null or sim.water == null:
		game.free()
		await process_frame
		return
	# Establish an actual observation before requesting a mission. Kit loading
	# then follows the ordinary path back to the friendly tool store.
	scout.person.position = sim.entrance_of(well, "att_entrance")
	sim.scouting.refresh_visibility()
	var quote: Dictionary = sim.water.poison_quote(scout.id)
	var source: Building = sim.buildings_by_id.get(quote.source_id)
	var tools_before: float = source.inventory[Config.Res.TOOLS] if source != null else -1.0
	_check(sim.water.poison(scout.id) == "" and not campaign.at_war,
		"requesting sabotage reserves a kit without remotely alerting the whole enemy town")
	for i in 6000:
		if not sim.water.poison_jobs.has(scout.id): break
		if sim.water.poison_jobs[scout.id].state == "approach": break
		sim.water.tick(0.25)
	_check(sim.water.poison_jobs.has(scout.id)
		and sim.water.poison_jobs[scout.id].state == "approach"
		and source.inventory[Config.Res.TOOLS] == tools_before - 1.0,
		"scout physically retrieves one finite sabotage kit before the hostile approach")
	var guard: Soldier = campaign.units.values()[0]
	_check(not campaign._tick_guard_security(guard) and not campaign.at_war,
		"guards cannot detect the distant scout collecting supplies at home")
	var approach := guard.position + Vector3(0, 0, -22)
	approach.y = game.world.heightmap.height_at(approach.x, approach.z)
	scout.person.position = approach
	_check(campaign._tick_guard_security(guard) and campaign.at_war,
		"a peaceful guard detects the nearby hostile approach and moves to intercept")
	var start := guard.position
	var tools_carried := scout.tools
	for i in 400:
		if not sim.water.poison_jobs.has(scout.id): break
		campaign._tick_guard_security(guard)
		guard.tick(0.25, game.world)
		sim.water.tick(0.25)
	_check(not sim.water.poison_jobs.has(scout.id) and scout.state == "return"
		and sim.water.wells[well.id].poison == 0.0,
		"physical guard interception interrupts sabotage before the well is contaminated")
	_check(guard.position.distance_to(start) > 1.0 and scout.tools == tools_carried + 1.0,
		"guard actually approaches and the interrupted scout retains the unused paid kit")
	game.free()
	await process_frame
