extends "res://tests/long_run.gd"

## tools/godot_env.sh --headless --path game --script res://tests/campaign.gd


func _town_food(campaign: FrontierCampaign) -> float:
	var amount := 0.0
	for building in campaign.enemy_buildings.values():
		amount += building.inventory[Config.Res.FOOD]
	for worker in campaign._workers:
		amount += worker.carrying_amount
	return amount


func _generation_and_persistence() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	_check(campaign.enemy_buildings.size() == 5 and campaign.units.size() == 3
			and campaign._workers.size() == 3,
			"the seeded rival has a keep, homes, farm, granary, growers and guards")
	var keep := campaign._enemy_type("keep")
	var farm := campaign._enemy_type("farm")
	_check(keep != null and farm != null and farm.field_count() > 0
			and not game.sim.can_place("house", keep.position).ok,
			"rival farms work actual plots and enemy footprints reject friendly placement")
	var before := _town_food(campaign)
	var delivered := false
	for i in 360:
		campaign._tick_town(1.0)
		for worker in campaign._workers:
			delivered = delivered or worker.carrying_amount > 0.0
	_check(delivered and keep.inventory[Config.Res.FOOD] > 100.0
			and absf(_town_food(campaign) - before - 20.0) < 0.05,
			"growers physically supply their town while production and household consumption balance")
	var seeded_personality := campaign.personality
	var seeded_position := campaign.rival_position
	_check(campaign.set_personality("loner") and not campaign.set_personality("unknown")
			and campaign.personality == "loner", "rival personality is editable with invalid values rejected")
	keep.position.y += 0.03125
	campaign.units.values()[0].position.y += 0.0625
	campaign._workers[0].position.y += 0.125
	# A node regrown or edited after founding must not be cleared on loading.
	var node: ResourceNodes.NodeRec = game.world.nodes.records[0]
	node.position = keep.position
	node.amount = 17.25
	node.depleted = false
	var nodes := game.world.nodes.capture()
	var wear := game.world.wear.capture()
	var saved := campaign.capture()
	_check(FrontierCampaign.validate(saved) == "", "the live rival and marching growers produce a valid save")
	_check(campaign.restore(saved) == "" and campaign.capture() == saved,
			"campaign state round-trips exact positions, cargo, orders, fields and timers")
	_check(game.world.nodes.capture() == nodes and game.world.wear.capture() == wear,
			"campaign restoration preserves saved resources and road history")
	_check(campaign.restore(saved) == "" and campaign.enemy_buildings.size() == 5
			and campaign.units.size() == 3 and campaign._workers.size() == 3,
			"repeated restore replaces entities instead of duplicating the rival town")
	var malformed: Array = [false, {"personality": "peaceful"}]
	var bad := saved.duplicate(true)
	bad.units[0].rations = INF
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.units[0].target_kind = "unit"
	bad.units[0].target_id = bad.units[0].id
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.units[0].id = bad.buildings[0].id
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.buildings[0].inventory[Config.Res.FOOD] = 10000.0
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.workers[0].leg = true
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.workers[0].asset_id = "missing_asset"
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.conquered = true
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.impacts.append({"wait": 0.5, "id": 999999, "faction": 0})
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.review = NAN
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.units[0].target_kind = "building"
	bad.units[0].target_id = 99999
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.impacts.append({"wait": 0.5, "id": 99999, "faction": 1})
	malformed.append(bad)
	var atomic := true
	for data in malformed:
		atomic = atomic and campaign.restore(data) != "" and campaign.capture() == saved
	_check(atomic, "malformed campaign saves reject atomically before touching the living world")
	var house := campaign._enemy_type("house")
	var cell := Config.world_to_cell(house.position)
	campaign._destroy_enemy(house)
	_check(not game.world.nav.is_solid(cell.x, cell.y),
			"destroying a restored building releases exactly one footprint claim")
	game.free()
	await process_frame
	var other := _new_game(42)
	_check(other.sim.campaign.personality == seeded_personality
			and other.sim.campaign.rival_position == seeded_position,
			"rival location and initial personality are reproducible from the world seed")
	other.free()
	await process_frame
	for world_seed in [20260911, 1776]:
		var seeded := _new_game(world_seed)
		var rival: FrontierCampaign = seeded.sim.campaign
		var seeded_farm := rival._enemy_type("farm")
		_check(rival.enemy_buildings.size() == 5 and seeded_farm != null
				and seeded_farm.field_count() == 3,
				"seed %d also generates a complete rival on workable farmland" % world_seed)
		seeded.free()
		await process_frame


func _military() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	campaign.set_personality("peaceful")
	var original_food := sim.keep.inventory[Config.Res.FOOD]
	_check(campaign.recruit() != "" and campaign.friendly_ids().is_empty()
			and sim.keep.inventory[Config.Res.FOOD] == original_food,
			"recruitment requires a completed barracks and charges nothing without one")
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(65, 0, 15))
	if barracks == null:
		game.free()
		return
	var original_tools := sim.keep.inventory[Config.Res.TOOLS]
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	sim.keep.reserved[Config.Res.FOOD] = original_food
	_check(campaign.recruit() != "" and campaign.friendly_ids().is_empty()
			and sim.keep.inventory[Config.Res.TOOLS] == original_tools,
			"food reserved for hauling cannot be spent recruiting a soldier")
	sim.keep.reserved[Config.Res.FOOD] = 0.0
	_check(campaign.recruit() == "" and campaign.friendly_ids().size() == 1
			and sim.keep.inventory[Config.Res.TOOLS] == original_tools - 5.0
			and sim.keep.inventory[Config.Res.FOOD] == original_food - 10.0,
			"recruitment pays five tools and ten food for one supplied soldier")
	if campaign.friendly_ids().is_empty():
		game.free()
		return
	var soldier: Soldier = campaign.units[campaign.friendly_ids()[0]]
	var start := soldier.position
	var destination := start + Vector3(12, 0, -8)
	campaign.command([soldier.id], destination)
	for i in 200:
		campaign.tick(0.1)
		if not soldier.has_goal():
			break
	_check(soldier.position.distance_to(start) > 10.0 and not soldier.has_goal()
			and not campaign.at_war, "a movement order walks the unit across the map without declaring war")
	campaign.command([soldier.id], start, {"kind": "unit", "id": soldier.id})
	_check(soldier.target_id == -1 and not campaign.at_war,
			"orders cannot attack a friendly unit or declare war on an invalid target")
	var guard: Soldier = campaign.units.values().filter(func(u): return u.faction == 1)[0]
	for other in campaign.units.values():
		if other.faction == 1:
			other.position = campaign.rival_position + Vector3(0, 0, -18)
	soldier.position = guard.position + Vector3(60, 0, 0)
	campaign.set_personality("aggressive")
	sim.day = 4.0
	campaign._assign_guards()
	_check(guard.target_id == -1 and not campaign.at_war,
			"even aggressive rivals do not begin unprovoked attacks before day five")
	sim.day = 6.0
	campaign._assign_guards()
	_check(guard.target_id == soldier.id and campaign.at_war,
			"an aggressive rival responds to a nearby army after the grace period")
	campaign.set_personality("peaceful")
	campaign.at_war = false
	campaign._assign_guards()
	_check(guard.target_id == -1, "peaceful guards leave an unprovoked army alone")
	campaign.at_war = true
	campaign._assign_guards()
	_check(guard.target_id == soldier.id, "peaceful guards retaliate after their town is attacked")
	campaign.set_personality("loner")
	campaign._assign_guards()
	_check(guard.target_id == -1, "loner guards keep a smaller defensive perimeter")
	campaign.at_war = false
	campaign.set_personality("peaceful")
	sim.day = 0.36
	for unit in campaign.units.values():
		unit.target_id = -1
		unit.target_kind = ""
		unit.clear_goal()

	var relay := _build(game, "supply_hut", game.world.centre() + Vector3(-100, 0, 70))
	if relay == null:
		game.free()
		return
	for b in sim.buildings:
		b.inventory[Config.Res.FOOD] = 0.0
	relay.inventory[Config.Res.FOOD] = 7.0
	relay.reserved[Config.Res.FOOD] = 2.0
	soldier.position = campaign._door(relay)
	soldier.rations = 0.5
	campaign._refill(soldier)
	_check(soldier.rations == 4.0 and relay.inventory[Config.Res.FOOD] == 3.5,
			"a nearby relay transfers actual unreserved food into the soldier's pack")
	relay.inventory[Config.Res.FOOD] = 2.0
	soldier.rations = 1.0
	campaign._refill(soldier)
	_check(soldier.rations == 1.0 and relay.inventory[Config.Res.FOOD] == 2.0,
			"military resupply respects civilian haul reservations")
	soldier.position = Vector3(30, game.world.heightmap.height_at(30, 30), 30)
	var health := soldier.health
	campaign.tick(Config.DAY_LENGTH * 0.5)
	_check(is_equal_approx(soldier.rations, 0.5) and soldier.health == health,
			"marching consumes carried rations at one food per soldier-day")
	soldier.rations = 0.0
	campaign.tick(2.0)
	_check(soldier.health < health and soldier.speed_modifier == 0.65,
			"an isolated soldier without food weakens and slows down")
	relay.reserved[Config.Res.FOOD] = 0.0
	soldier.position = campaign._door(relay)
	health = soldier.health
	campaign.tick(0.1)
	_check(soldier.rations > 0.0 and soldier.health == health and soldier.speed_modifier == 1.0,
			"returning to a stocked relay ends starvation without creating food")
	var paused := campaign.capture()
	campaign.tick(0.0)
	campaign.tick(NAN)
	_check(campaign.capture() == paused, "paused and invalid campaign ticks leave supplies and combat unchanged")

	soldier.position = guard.position + Vector3(1, 0, 0)
	campaign.command([soldier.id], guard.position, {"kind": "unit", "id": guard.id})
	health = guard.health
	var body_before := guard.capture_body()
	campaign._tick_combat(soldier, 0.1)
	_check(campaign.at_war and guard.health < health and guard.capture_body() != body_before,
			"a close sword attack causes a located injury and starts war")
	health = guard.health
	campaign._tick_combat(soldier, 0.1)
	_check(guard.health == health, "sword cooldown prevents damage on every simulation tick")
	var house := campaign._enemy_type("house")
	var house_id := house.id
	var cell := Config.world_to_cell(house.position)
	house.health = 35.0
	soldier.position = campaign._door(house) + Vector3(10, 0, 0)
	soldier.fire_cooldown = 0.0
	campaign.command([soldier.id], house.position, {"kind": "building", "id": house.id})
	campaign._tick_combat(soldier, 0.1)
	_check(not campaign._impacts.is_empty() and house.fire == 0.0,
			"a firepot travels before its impact damages and ignites a building")
	var active := campaign.capture()
	var soldier_id := soldier.id
	var guard_id := guard.id
	_check(campaign.restore(active) == "" and campaign.capture() == active,
			"active combat saves preserve targets, rations, cooldowns and projectiles in flight")
	soldier = campaign.units[soldier_id]
	guard = campaign.units[guard_id]
	house = campaign.enemy_buildings[house_id]
	soldier.apply_damage(100.0)
	campaign.tick(1.4)
	_check(house.fire > 0.0 and house.health < 35.0 and not campaign.units.has(soldier.id),
			"a thrown firepot still lands after its attacker dies")
	for i in 100:
		campaign.tick(0.25)
		if not campaign.enemy_buildings.has(house_id):
			break
	_check(not campaign.enemy_buildings.has(house_id) and not game.world.nav.is_solid(cell.x, cell.y)
			and not campaign._ruins.is_empty(),
			"fire burns a rival building down, leaves ruins and opens its footprint")
	campaign.set_personality("aggressive")
	campaign.at_war = false
	sim.day = 10.0
	campaign._assign_guards()
	_check(campaign.friendly_ids().is_empty() and not campaign.at_war,
			"a rival does not launch unprovoked raids when the player has no army")
	var rival_keep := campaign._enemy_type("keep")
	rival_keep.health = 1.0
	rival_keep.apply_damage(0.0, 1.0)
	campaign.tick(0.2)
	_check(campaign.conquered and campaign._enemy_type("keep") == null,
			"destroying the rival keep records conquest")
	relay.health = 1.0
	relay.apply_damage(0.0, 1.0)
	var relay_id := relay.id
	campaign.tick(0.3)
	_check(not sim.buildings_by_id.has(relay_id),
			"burning a friendly supply building uses normal demolition cleanup")
	sim.keep.health = 1.0
	sim.keep.apply_damage(0.0, 1.0)
	campaign.tick(0.2)
	_check(campaign.defeated and not campaign.can_recruit(),
			"the player's keep falling ends recruitment and records defeat")
	var ended := SaveGame.capture(game)
	var error := SaveGame.validate(ended, game.registry)
	_check(sim.keep != null and sim.keep.health == 0.0 and error == "",
			"defeat preserves the fallen keep and a valid complete-game save: " + error)
	game.free()
	await process_frame


func _run() -> void:
	await _generation_and_persistence()
	await _military()
	print("Campaign regression failures: %d" % _failures)
	quit(1 if _failures else 0)
