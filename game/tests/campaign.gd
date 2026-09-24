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
	_check(campaign.enemy_buildings.size() == 6 and campaign.units.size() == 3
			and campaign._workers.size() == 3,
			"the seeded rival has a keep, homes, farm, granary, well, growers and guards")
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
	var terrain := game.world.heightmap.heights.duplicate()
	var terrain_edits := game.world.heightmap.capture()
	var saved := campaign.capture()
	_check(FrontierCampaign.validate(saved) == "", "the live rival and marching growers produce a valid save")
	_check(campaign.restore(saved) == "" and campaign.capture() == saved,
			"campaign state round-trips exact positions, cargo, orders, fields and timers")
	_check(game.world.nodes.capture() == nodes and game.world.wear.capture() == wear,
			"campaign restoration preserves saved resources and road history")
	_check(game.world.heightmap.heights == terrain and game.world.heightmap.capture() == terrain_edits,
			"restoring rival buildings does not grade their foundations a second time")
	_check(campaign.restore(saved) == "" and campaign.enemy_buildings.size() == 6
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
	# The fields expansion added. `validate` runs on untrusted data and has to
	# turn each of these away with a string rather than throwing on the way in.
	bad = saved.duplicate(true)
	bad.workers[0].farm_id = bad.buildings[0].id if bad.buildings[0].type_id != "farm" else 999999
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.workers[0].farm_id = "the north field"
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.build_in = -1.0
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.grow_in = INF
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
		_check(rival.enemy_buildings.size() == 6 and seeded_farm != null
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


func _foundation_save() -> void:
	var game := _new_game(20260911)
	var saved := SaveGame.capture(game)
	var terrain := game.world.heightmap.heights.duplicate()
	var buildings: Array = game.sim.campaign.capture().buildings
	var error := game.restore_from(saved)
	_check(error == "" and game.world.heightmap.heights == terrain
			and game.sim.campaign.capture().buildings == buildings,
			"full save/load preserves rival foundation grading and exact building positions: " + error)
	game.free()
	await process_frame


## Companies: the block between "one soldier" and "the whole army". Every check
## here was mutation-tested — the guarded behaviour was broken, the check was
## confirmed to fail, and the break reverted.
func _companies() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	campaign.set_personality("peaceful")
	var at := sim.entrance_of(sim.keep, "att_entrance")
	var squad: Array[int] = []
	for i in 6:
		var recruit := campaign._spawn_unit(0, at + Vector3(float(i) * 2.0, 0, 0))
		recruit.position.y = game.world.heightmap.height_at(recruit.position.x, recruit.position.z)
		recruit._wear_anchor = recruit.position
		squad.append(recruit.id)
	var guard_id: int = campaign.units.values().filter(func(u): return u.faction == 1)[0].id

	var muster_ground := game.world.centre() + Vector3(0, 0, 70)
	muster_ground.y = game.world.heightmap.height_at(muster_ground.x, muster_ground.z)
	campaign.command(squad, muster_ground)
	_check(campaign.units[squad[0]]._goal.is_equal_approx(muster_ground)
			and campaign.units[squad[3]]._goal.is_equal_approx(muster_ground + Vector3(6, 0, 0))
			and campaign.units[squad[4]]._goal.is_equal_approx(muster_ground + Vector3(0, 0, 2)),
			"a bare id list with no companies still forms the four-wide grid it always did")

	var first := campaign.form_company([squad[0], squad[1], squad[2], squad[3]])
	_check(first > 0 and campaign.company_members(first) == [squad[0], squad[1], squad[2], squad[3]]
			and campaign.company_of(squad[0]) == first and campaign.company_of(squad[4]) == -1,
			"forming a company enlists exactly the named soldiers and leaves the rest loose")
	_check(campaign.form_company([]) == -1 and campaign.form_company([999999, -3]) == -1
			and campaign.form_company([guard_id]) == -1 and campaign.companies.size() == 1,
			"a company cannot be formed from nothing, from unknown ids or from rival guards")
	_check(campaign.set_company_width(first, 2) and not campaign.set_company_width(first, 0)
			and not campaign.set_company_width(first, FrontierCampaign.MAX_COMPANY_WIDTH + 1)
			and campaign.companies[first].width == 2,
			"a company's frontage is the company's own, and out-of-range shapes are refused")
	# `set_company_width` refuses out-of-range shapes; `form_company` takes one
	# straight from a caller and has to clamp it instead, or the company it
	# builds is a save that `validate` will refuse to load back.
	var overwide := campaign.form_company([squad[4], squad[5]], 999)
	_check(overwide > 0 and campaign.companies[overwide].width == FrontierCampaign.MAX_COMPANY_WIDTH
			and FrontierCampaign.validate(campaign.capture()) == "",
			"a frontage past the ceiling is clamped as the company forms rather than saved and rejected on load")
	campaign.disband_company(overwide)

	# A company reaches one man by a split or by casualties, and the block
	# panel that carries the disband button needs two soldiers to appear. His
	# own panel has to name the company and offer the way out, or he is
	# enlisted for good in a company with no name on screen.
	var lone := campaign.form_company([squad[5]], 3)
	game._select_unit(squad[5], false, false)
	var disband_button: Button = null
	for child in game.hud._selection_actions.get_children():
		if child is Button and child.text.begins_with("Disband"): disband_button = child
	_check(game.selected_units == [squad[5]] and disband_button != null
			and game.hud._selection_body.text.contains(campaign.company_report(lone).name),
			"the panel for a lone soldier names the one-man company he marches with and offers to disband it")
	if disband_button != null: disband_button.pressed.emit()
	_check(not campaign.companies.has(lone) and campaign.company_of(squad[5]) == -1
			and campaign.units.has(squad[5]),
			"pressing it really disbands the one-man company and leaves the soldier himself untouched")

	game._select_unit(squad[1], false, false)
	_check(game.selected_units.size() == 4 and game.selected_units.has(squad[0])
			and game.selected_units.has(squad[3]) and not game.selected_units.has(squad[4]),
			"clicking one soldier selects the whole company he marches with")
	game._select_unit(squad[4], false, false)
	_check(game.selected_units == [squad[4]],
			"clicking a soldier who is in no company still selects just him")
	game._select_unit(squad[1], false, true)
	_check(game.selected_units == [squad[1]],
			"Alt-click takes one soldier back out of his company")
	game._select_unit(squad[4], true, false)
	_check(game.selected_units.size() == 2 and game.selected_units.has(squad[1])
			and game.selected_units.has(squad[4]),
			"Shift-click adds to the selection instead of replacing it")
	game._select_unit(squad[4], true, false)
	_check(game.selected_units == [squad[1]],
			"Shift-clicking soldiers already held takes them back out again")
	game.selected_units.assign([guard_id])
	game._select_unit(squad[4], true, false)
	_check(game.selected_units == [squad[4]],
			"Shift-click never carries a rival guard into a selection of our own soldiers")

	game._select_unit(squad[0], false, true)
	game._select_unit(squad[1], true, true)
	game._regroup_selection()
	var detached := campaign.company_of(squad[0])
	_check(detached > 0 and detached != first
			and campaign.company_members(detached) == [squad[0], squad[1]]
			and campaign.company_members(first) == [squad[2], squad[3]]
			and campaign.companies[detached].width == 2,
			"splitting peels the selected soldiers into a new company that inherits the old shape")
	_check(campaign.split_company(first, [squad[2], squad[3]]) == -1
			and campaign.split_company(first, [squad[0]]) == -1
			and campaign.company_members(first) == [squad[2], squad[3]],
			"a split refuses to take a whole company or a soldier who belongs to another")

	var inherited := campaign.form_company([squad[2], squad[4]])
	_check(inherited > 0 and campaign.companies[inherited].width == 2
			and campaign.company_members(first) == [squad[3]],
			"forming without a stated shape inherits it from a member's old company")
	var fresh := campaign.form_company([squad[5]])
	_check(fresh > 0 and campaign.companies[fresh].width == FrontierCampaign.COMPANY_WIDTH,
			"soldiers with no past company fall back to the default frontage instead")
	campaign.disband_company(fresh)
	campaign.disband_company(inherited)
	first = campaign.form_company([squad[2], squad[3]], 2)
	detached = campaign.form_company([squad[0], squad[1]], 5)

	# Named youngest first, and holding the higher-numbered company's soldiers
	# first, so neither the argument order nor the click order can be mistaken
	# for the id order both of these are supposed to impose.
	var listed: Dictionary = campaign.selection_report([squad[0], squad[1], squad[2], squad[3]])
	_check(listed.companies.size() == 2 and listed.companies[0].id == first
			and listed.companies[1].id == detached and listed.mergeable,
			"a selection report lists companies by id, not by the order the selection was assembled")

	var merged := campaign.merge_companies([detached, first])
	_check(merged > 0 and campaign.company_members(merged) == [squad[0], squad[1], squad[2], squad[3]]
			and campaign.companies[merged].width == 2
			and not campaign.companies.has(first) and not campaign.companies.has(detached)
			and campaign.merge_companies([merged]) == -1,
			"merging leaves one roster and no emptied companies, takes its frontage from the lowest-numbered company whichever was named first, and refuses a merge of one")

	var spare := campaign.form_company([squad[4], squad[5]], 1)
	game.selected_units.assign([squad[0], squad[1], squad[2], squad[3], squad[4]])
	game._regroup_selection()
	var regrouped := campaign.company_members(campaign.company_of(squad[0]))
	_check(regrouped == [squad[0], squad[1], squad[2], squad[3], squad[4]]
			and campaign.company_of(squad[5]) == spare
			and campaign.companies[spare].members == [squad[5]],
			"regrouping part of one company and all of another takes the selection, not the unselected men")
	campaign.disband_company(campaign.company_of(squad[0]))
	campaign.disband_company(spare)

	var left := campaign.form_company([squad[0], squad[1], squad[2]], 2)
	var right := campaign.form_company([squad[3], squad[4]], 1)
	var ground := game.world.centre() + Vector3(0, 0, 40)
	ground.y = game.world.heightmap.height_at(ground.x, ground.z)
	campaign.command([squad[0], squad[1], squad[2]], ground)
	_check(campaign.units[squad[0]]._goal.is_equal_approx(ground)
			and campaign.units[squad[1]]._goal.is_equal_approx(ground + Vector3(2, 0, 0))
			and campaign.units[squad[2]]._goal.is_equal_approx(ground + Vector3(0, 0, 2)),
			"a two-file company marches two files wide, from its own shape rather than the order's")
	campaign.units[squad[0]].clear_goal()
	campaign.units[squad[1]].clear_goal()
	campaign.units[squad[2]].clear_goal()
	campaign.command([squad[2], squad[0], squad[1]], ground)
	_check(campaign.units[squad[0]]._goal.is_equal_approx(ground)
			and campaign.units[squad[2]]._goal.is_equal_approx(ground + Vector3(0, 0, 2)),
			"the block follows the company's own roster however the order's ids were assembled")
	var second_ground := ground + Vector3(0, 0, 30)
	second_ground.y = game.world.heightmap.height_at(second_ground.x, second_ground.z)
	campaign.command(campaign.friendly_ids(), second_ground)
	var lanes := {}
	for id in campaign.friendly_ids():
		var key: int = campaign.company_of(id)
		var x: float = campaign.units[id]._goal.x
		if not lanes.has(key): lanes[key] = [x, x]
		lanes[key][0] = minf(lanes[key][0], x)
		lanes[key][1] = maxf(lanes[key][1], x)
	var disjoint := true
	for a in lanes:
		for b in lanes:
			if a < b and lanes[a][1] >= lanes[b][0]: disjoint = false
	_check(lanes.size() == 3 and disjoint,
			"mustering the whole army lands each company and the loose men on ground of their own")

	var corner := Vector3(game.world.size_m - 1.0, 0, game.world.size_m - 1.0)
	corner.y = game.world.heightmap.height_at(corner.x, corner.z)
	campaign.command(campaign.friendly_ids(), corner)
	var corner_lanes := {}
	for id in campaign.friendly_ids():
		corner_lanes[campaign.units[id]._goal.x] = true
	_check(corner_lanes.size() >= 3 and campaign.units[squad[0]]._goal.x < corner.x,
			"an order against the map edge forms the parade inland instead of stacking every company on one spot")

	var saved := campaign.capture()
	# Read through `get`, and bail rather than run on: a capture that dropped
	# the roster would otherwise abort this function on the fixtures below and
	# leave the suite reporting success over checks that never ran.
	var written: Array = saved.get("companies", [])
	# No claim about ordering here: the fixture formed its companies in
	# ascending id, which is the only order live play can produce, so asserting
	# it would pass with `capture` sorting nothing. The shuffled fixture below
	# is the one that tests the sort, because `restore` can seed the table in
	# any order a hand-edited save asks for.
	_check(FrontierCampaign.validate(saved) == "" and written.size() == 2,
			"a campaign holding companies produces a valid save")
	if written.size() != 2:
		game.free()
		await process_frame
		return
	_check(campaign.restore(saved) == "" and campaign.capture() == saved
			and campaign.company_of(squad[0]) == left
			and campaign.company_members(left) == [squad[0], squad[1], squad[2]]
			and campaign.companies[left].width == 2 and campaign.companies[right].width == 1
			and campaign.companies[left].name == saved.companies[0].name,
			"company rosters, names and shapes round-trip exactly and rebuild the reverse index")

	# The rosters a save carries are copies. Sharing the array would let the
	# save layer above — compression, validation, a future migration pass —
	# reach into the living army by editing what it was handed, and nothing
	# about the reloaded game would look wrong until the roster did.
	var snapshot := campaign.capture()
	var before_left: Array[int] = campaign.company_members(left)
	var before_right: Array[int] = campaign.company_members(right)
	for company in snapshot.companies:
		company.members.append(-1)
	_check(campaign.company_members(left) == before_left
			and campaign.company_members(right) == before_right
			and FrontierCampaign.validate(campaign.capture()) == "",
			"a captured save copies the rosters rather than aliasing them, so editing the save enlists nobody")

	var shuffled := saved.duplicate(true)
	shuffled.companies.reverse()
	_check(FrontierCampaign.validate(shuffled) == "" and campaign.restore(shuffled) == ""
			and campaign.capture() == saved,
			"a save whose companies were written out of order comes back in id order, so capture stays a function of state")

	var malformed: Array = []
	var bad := saved.duplicate(true)
	bad.companies[0].members.append(bad.companies[0].members[0])
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].members[0] = guard_id
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].members[0] = 987654
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].members = []
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].id = bad.units[0].id
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].width = 0
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].name = 7
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0].erase("members")
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies[0] = "a company"
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.companies = {}
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.next_company_ordinal = 0
	malformed.append(bad)
	var atomic := true
	for data in malformed:
		atomic = atomic and campaign.restore(data) != "" and campaign.capture() == saved
	_check(atomic, "malformed company data is rejected cleanly, before the living army is touched")

	var whole_save := SaveGame.capture(game)
	var error := game.restore_from(whole_save)
	campaign = game.sim.campaign
	_check(error == "" and campaign.company_of(squad[0]) == left
			and campaign.company_members(left) == [squad[0], squad[1], squad[2]]
			and campaign.company_members(right) == [squad[3], squad[4]],
			"a full SaveGame capture and staged load keeps every roster: " + error)

	var legacy := saved.duplicate(true)
	legacy.erase("companies")
	legacy.erase("next_company_ordinal")
	_check(FrontierCampaign.validate(legacy) == "" and campaign.restore(legacy) == ""
			and campaign.companies.is_empty() and campaign.company_of(squad[0]) == -1
			and campaign.units.size() == saved.units.size(),
			"a save written before companies existed still loads, with every soldier marching loose")

	_check(campaign.restore(saved) == "", "companies come back for the casualty check")
	campaign.units[squad[4]].apply_damage(100.0)
	campaign.tick(0.05)
	_check(not campaign.units.has(squad[4]) and campaign.company_of(squad[4]) == -1
			and campaign.company_members(right) == [squad[3]]
			and campaign.companies.has(right),
			"a soldier killed in the field leaves his company's roster and the reverse index")
	campaign.units[squad[3]].apply_damage(100.0)
	campaign.tick(0.05)
	_check(not campaign.companies.has(right) and campaign.company_of(squad[3]) == -1
			and campaign.companies.has(left) and FrontierCampaign.validate(campaign.capture()) == "",
			"a company whose last soldier dies stops existing, and leaves a valid save behind")
	game.free()
	await process_frame


## Order a body of men to `ground` and report where they actually landed, by
## the four measures that can go wrong: how many of them were given an order at
## all, how far the nearest is from the click, how many separate spots the
## order names, and how many men sit on the border line.
##
## `clamped` is the one to read first. "Every goal is on the map" would be a
## tautology — `command` clamps every destination into the map as its last
## resort — so what it asserts instead is that the clamp never had to fire. A
## layout that overran the edge scored zero collisions on some clicks and
## still crowded men onto the border; this sees that, and it is what caught a
## parade laid out from a frontage measured before its columns folded.
##
## `ordered` exists because this issues the order itself, after clearing every
## goal. `set_goal` ignores a target within 0.6 m of the one already held, so
## reading `_goal` after a second order can hand back the first order's answer:
## a soldier `command` silently skipped would look perfectly commanded.
##
## The front rank is found by distance rather than by its place in the id list,
## so a check does not quietly depend on which group `command` lays down first.
func _parade(campaign: FrontierCampaign, ids: Array[int], ground: Vector3) -> Dictionary:
	for id in ids: campaign.units[id].clear_goal()
	campaign.command(ids, ground)
	var seen := {}
	var ordered := 0
	var nearest := INF
	var clamped := 0
	var edge: float = campaign.world.size_m - 0.5
	for id in ids:
		var unit: Soldier = campaign.units[id]
		if not unit.has_goal(): continue
		ordered += 1
		var goal: Vector3 = unit._goal
		seen[Vector2(goal.x, goal.z)] = true
		nearest = minf(nearest, Vector2(goal.x - ground.x, goal.z - ground.z).length())
		if is_equal_approx(goal.x, 0.5) or is_equal_approx(goal.x, edge) \
				or is_equal_approx(goal.z, 0.5) or is_equal_approx(goal.z, edge):
			clamped += 1
	return {"ordered": ordered, "nearest": nearest, "distinct": seen.size(), "clamped": clamped}


## The regimes a six-soldier fixture cannot see. A parade of six fits anywhere,
## so nothing above notices a layout that only misbehaves once it is wider or
## deeper than the map; the company ceiling needs 512 companies to reach; and
## selecting one company only becomes expensive when the company is the army.
##
## Each check here was confirmed to fail against the code it guards, and the
## click positions are chosen rather than convenient: the centre and a corner
## both have room to spare in at least one direction and between them missed a
## live bug, so the two clicks that pin the layout down are the ones a few
## paces out from an edge, where there is nearly enough room.
func _companies_at_scale() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("peaceful")
	var at: Vector3 = game.sim.entrance_of(game.sim.keep, "att_entrance")
	var army: Array[int] = []
	for i in 2000:
		var recruit := campaign._spawn_unit(0, at + Vector3(float(i % 50), 0, float(i / 50)))
		recruit.position.y = game.world.heightmap.height_at(recruit.position.x, recruit.position.z)
		recruit._wear_anchor = recruit.position
		army.append(recruit.id)
	var centre := game.world.centre()
	centre.y = game.world.heightmap.height_at(centre.x, centre.z)

	# 2,000 loose men four files wide want a kilometre of depth on a 768 m map,
	# and 500 four-man companies want five kilometres of frontage. An earlier
	# layout pulled the whole parade back by that overrun and then clamped what
	# was still off the map: the front rank landed 383 m from the click, and
	# hundreds of men were given the same destination.
	var parade := _parade(campaign, army, centre)
	_check(parade.ordered == army.size() and parade.nearest < 0.001
			and parade.distinct == army.size() and parade.clamped == 0,
			"2,000 loose men march to the ground the player clicked, onto 2,000 separate spots, none of them against the border")

	# Not the centre and not a corner. A corner has no room either way, so the
	# parade turns inland and the layout is never asked to judge a tight fit; a
	# click a few paces out has just enough room to look like enough, and that
	# is where a frontage measured before the columns fold gets it wrong. This
	# exact order put 848 of these 2,000 men on top of one another.
	var verge := Vector3(game.world.size_m - 10.0, 0, game.world.centre().z)
	verge.y = game.world.heightmap.height_at(verge.x, verge.z)
	parade = _parade(campaign, army, verge)
	_check(parade.ordered == army.size() and parade.nearest < 0.001
			and parade.distinct == army.size() and parade.clamped == 0,
			"2,000 loose men ordered ten metres from the east edge form west of the click instead of crowding onto the border")

	for i in range(0, army.size(), 4):
		campaign.form_company(army.slice(i, i + 4))
	parade = _parade(campaign, army, centre)
	_check(campaign.companies.size() == 500 and parade.ordered == army.size()
			and parade.nearest < 0.001 and parade.distinct == army.size()
			and parade.clamped == 0,
			"500 companies wrap into further bands instead of piling onto one lane, and the front rank still lands on the click")

	# 715, 741 rather than the corner itself: the bands fit east-to-west but
	# only just, and counting them by dividing frontage by room said seven
	# where the wrap below takes eight. The eighth band ran off the map.
	var awkward := Vector3(game.world.size_m - 53.0, 0, game.world.size_m - 27.0)
	awkward.y = game.world.heightmap.height_at(awkward.x, awkward.z)
	parade = _parade(campaign, army, awkward)
	_check(parade.ordered == army.size() and parade.nearest < 0.001
			and parade.distinct == army.size() and parade.clamped == 0,
			"the band count is the one the layout actually takes, so the last band of 500 companies lands on the map too")

	var corner := Vector3(game.world.size_m - 1.0, 0, game.world.size_m - 1.0)
	corner.y = game.world.heightmap.height_at(corner.x, corner.z)
	parade = _parade(campaign, army, corner)
	_check(parade.ordered == army.size() and parade.nearest < 0.001
			and parade.distinct == army.size() and parade.clamped == 0,
			"the same 500 companies ordered into the far corner form inland from the click rather than being shoved off it")

	for company_id in campaign.companies.keys(): campaign.disband_company(company_id)
	var column: Array[int] = []
	column.assign(army.slice(0, 400))
	campaign.form_company(column, 1)
	parade = _parade(campaign, column, centre)
	_check(parade.ordered == column.size() and parade.nearest < 0.001
			and parade.distinct == column.size() and parade.clamped == 0,
			"a 400-man single file is 798 m deep on a 768 m map: it folds into further files rather than running off the edge or dragging the column back from the click")

	campaign.form_company(army)
	game.selected_units.clear()
	game._select_unit(army[0], false, false)
	# How long that click takes is held to a budget in tests/perf_budgets.gd,
	# which the gate runs alone: a wall-clock limit means nothing while seven
	# other stages share the CPU.
	_check(game.selected_units.size() == army.size(),
			"one click takes the whole 2,000-man company")

	# The cost here is allocation, so the guard counts allocations rather than
	# milliseconds: one mesh for 2,000 rings instead of 2,000. The material
	# hangs off the mesh, so counting it too would prove nothing the mesh count
	# has not already proved. Timing is printed, not asserted — a ceiling that
	# has to sit clear of a 39 ms regression and a 10 ms pass is a coin toss on
	# a loaded machine, and the identity below cannot be satisfied by luck.
	var started_rings := Time.get_ticks_usec()
	game._refresh_unit_rings()
	var ring_ms := float(Time.get_ticks_usec() - started_rings) / 1000.0
	var meshes := {}
	var rings := 0
	for id in game.selected_units:
		var ring: MeshInstance3D = campaign.units[id].get_node_or_null("selection_ring")
		if ring == null or not ring.visible: continue
		rings += 1
		meshes[ring.mesh.get_instance_id()] = true
	_check(rings == army.size() and meshes.size() == 1,
			"2,000 rings are raised from one shared mesh rather than a torus and a material allocated per soldier (%.2f ms to raise them all)" % ring_ms)

	for company_id in campaign.companies.keys(): campaign.disband_company(company_id)
	for i in FrontierCampaign.MAX_COMPANIES:
		campaign.form_company([army[i]])
	var spare: int = army[FrontierCampaign.MAX_COMPANIES]
	_check(campaign.companies.size() == FrontierCampaign.MAX_COMPANIES
			and campaign.form_company([spare]) == -1 and campaign.company_of(spare) == -1,
			"company number %d is refused once the ceiling is reached" % (FrontierCampaign.MAX_COMPANIES + 1))
	var oldest: int = campaign.company_of(army[0])
	var next: int = campaign.company_of(army[1])
	var joined := campaign.merge_companies([oldest, next])
	_check(joined > 0 and campaign.companies.size() == FrontierCampaign.MAX_COMPANIES - 1
			and campaign.company_members(joined) == [army[0], army[1]]
			and campaign.form_company([spare]) > 0,
			"a merge at the ceiling still runs, because it empties the two it draws from: the one order that gets the player back under the cap is not the order the cap refuses")
	game.free()
	await process_frame


## The rival town's own growth. Everything in this block runs long on purpose:
## the town holds its first review on day three, a second farm is a week's work
## and a personality only tells itself apart once it has had a hundred days to
## build. A ten-day fixture here would pass with the whole feature deleted.
## The rival's own clock, and the water everyone on the map drinks. Ticking the
## whole settlement for the hundreds of in-game days these fixtures need is
## minutes of the player's economy that nothing here reads, and the rival's
## growth does not depend on it — but the rival's people do die of thirst, so the
## water system is not optional. Checked against full `sim.tick` over sixty days
## of an aggressive neighbour: the same 13 buildings, 31 residents, 16 guards, 15
## growers and 5 farms, in half the wall time. `_settled_days` below is the full
## simulation, for the one fixture that saves and loads a real game.
func _rival_days(game: SeededGame, days: int) -> void:
	var step := Config.MAX_SIM_STEP
	var per_day := roundi(Config.DAY_LENGTH / step)
	for _d in days:
		for _i in per_day:
			if game.sim.water != null:
				game.sim.water.tick(step)
			game.sim.campaign.tick(step)
			game.sim.day += step / Config.DAY_LENGTH
			game.clock.elapsed_days += step / Config.DAY_LENGTH
		await process_frame


func _settled_days(game: SeededGame, days: int) -> void:
	var step := Config.MAX_SIM_STEP
	var per_day := roundi(Config.DAY_LENGTH / step)
	for _d in days:
		for _i in per_day:
			game.sim.tick(step)
			game.clock.elapsed_days += step / Config.DAY_LENGTH
		await process_frame


## `founding` is the set of building ids the town was seeded with, so `sited`
## counts only what the town has raised for itself.
func _town_state(campaign: FrontierCampaign, founding: Dictionary = {}) -> Dictionary:
	var guards := 0
	for u in campaign.units.values():
		if u.faction == 1 and u.health > 0.0:
			guards += 1
	var sited := 0
	for b in campaign.enemy_buildings.values():
		if not founding.has(b.id):
			sited += 1
	var keep := campaign._enemy_type("keep")
	return {"buildings": campaign.enemy_buildings.size(),
		"people": campaign.town_population, "growers": campaign._workers.size(),
		"guards": guards, "farms": campaign._farms.size(),
		"iron": keep.inventory[Config.Res.IRON] if keep != null else -1.0,
		"sited": sited}


func _expansion() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("peaceful")
	var founded := _town_state(campaign)
	# Day twelve first, and on purpose. At HEAD every rival garrison in the game
	# was dead by about day ten: guards drink at the town well 43 m out, and
	# `_refill` reaches 24 m from a store's door, so a guard who had once gone to
	# drink stood beside the well with an empty pack until he died — measured at
	# HEAD, rations gone on day six and all three dead by day ten. Checked at
	# twelve rather than at sixty because by sixty the town has five farms and a
	# granary and there is food within reach of almost anywhere it might stand.
	await _rival_days(game, 12)
	var early := _town_state(campaign)
	var packed := 0
	for u in campaign.units.values():
		if u.faction == 1 and u.health > 0.0 and u.rations > 1.0:
			packed += 1
	_check(early.guards == founded.guards and packed == founded.guards,
			"the founding garrison is alive on day twelve and still carrying rations (%d of %d alive, %d with a pack)"
			% [early.guards, founded.guards, packed])
	await _rival_days(game, 48)
	var grown := _town_state(campaign)
	print("METRIC " + JSON.stringify({"phase": "rival_growth", "day": 60, "personality": "peaceful",
		"state": grown}))
	_check(grown.buildings > founded.buildings and grown.people > founded.people
			and grown.farms > founded.farms,
			"sixty days of neighbouring leaves the rival with more buildings, more people and more fields than it was founded with")
	# Everything the town raised has to be a building the game already defines,
	# and has to stand where the player's own placement rules would allow it.
	var invented := ""
	var overlapping := false
	for b in campaign.enemy_buildings.values():
		if b.type_id not in ["keep", "house", "farm", "granary", "well"]:
			invented = b.type_id
		for other in campaign.enemy_buildings.values():
			if other != b and other.position.distance_to(b.position) < 20.0:
				overlapping = true
	_check(invented == "" and not overlapping,
			"the town it grew is made of ordinary building types on ground that does not overlap")
	_check(campaign._workers.size() <= campaign.town_population
			and campaign._workers.size() <= FrontierCampaign.MAX_GROWERS,
			"every grower in the fields is one of the town's own residents")
	_check(grown.guards > 0,
			"the garrison is still alive after sixty days rather than starved beside the well")
	_check(FrontierCampaign.validate(campaign.capture()) == "",
			"a town that has grown for sixty days still writes a save its own validator accepts")
	# Burn a staffed farm down and watch where its growers go. They have to
	# spread over the farms that are left, not all land on whichever one had the
	# fewest hands when the first of them was looked at: re-homing read
	# `farm.workers`, which the reconciliation does not write until afterwards,
	# so three growers off one farm all chose the same destination and a
	# three-slot farm came back holding six.
	if campaign._farms.size() >= 2:
		var doomed: Building = campaign._farms[0]
		var displaced: int = doomed.workers.size()
		campaign._destroy_enemy(doomed)
		var over := 0
		var placed := 0
		for farm in campaign._farms:
			placed += farm.workers.size()
			if farm.workers.size() > farm.def.worker_slots:
				over += 1
		# Whatever room the surviving farms had is filled without any of them
		# going over its slots, and whoever is left over is back to being a
		# labourer rather than disappearing from the town's economy: `_workers`
		# still holds him, no farm claims him, and the labour count says so.
		var homeless: int = campaign._workers.size() - campaign._field_hands()
		_check(displaced > 1 and over == 0 and placed == campaign._field_hands()
				and campaign._field_hands() + homeless == campaign._workers.size(),
				"the %d growers of a burned farm are taken on by the farms still standing (%d of them), none over its own slots, and the %d with nowhere to go count as labourers again"
				% [displaced, campaign._field_hands(), homeless])
		_check(campaign.capture() == campaign.capture()
				and FrontierCampaign.validate(campaign.capture()) == "",
				"and the town writes a valid, stable save straight after losing a farm")
	game.free()
	await process_frame


## Materials. The town buys its buildings out of the keep at the ordinary
## `BuildingDefs` price, so a town held at nothing cannot build however many
## people it has and however hungry it is.
func _expansion_needs_materials() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("peaceful")
	var keep := campaign._enemy_type("keep")
	var step := Config.MAX_SIM_STEP
	var per_day := roundi(Config.DAY_LENGTH / step)
	for _d in 40:
		for _i in per_day:
			game.sim.water.tick(step)
			game.sim.campaign.tick(step)
			# Robbed every tick, so nothing accumulates between reviews.
			keep.inventory[Config.Res.TIMBER] = 0.0
			keep.inventory[Config.Res.STONE] = 0.0
			game.sim.day += step / Config.DAY_LENGTH
			game.clock.elapsed_days += step / Config.DAY_LENGTH
		await process_frame
	var poor := _town_state(campaign)
	_check(poor.buildings == 6,
			"forty days with no timber or stone in the keep raise no buildings at all")
	_check(poor.people >= 8,
			"the town that could not build is a living one, not a dead one: the materials are what it lacked")
	# Watch a single building go up and check the keep is actually debited for
	# it. Without this the fixture proves only that the town needs materials in
	# hand, not that raising something spends them: delete the `keep.remove`
	# line in `_expand` and everything above still passes.
	var seen: Dictionary = {}
	for b in campaign.enemy_buildings.values():
		seen[b.id] = true
	var paid := ""
	var step2 := Config.MAX_SIM_STEP
	for _d in 30:
		for _i in per_day:
			var before_stock := {}
			for res in [Config.Res.TIMBER, Config.Res.STONE]:
				before_stock[res] = keep.inventory[res]
			game.sim.water.tick(step2)
			campaign.tick(step2)
			game.sim.day += step2 / Config.DAY_LENGTH
			game.clock.elapsed_days += step2 / Config.DAY_LENGTH
			for b in campaign.enemy_buildings.values():
				if seen.has(b.id):
					continue
				seen[b.id] = true
				if paid != "":
					continue
				var cost: Dictionary = b.def.cost
				var short := ""
				for res in cost:
					var spent: float = float(before_stock[res]) - keep.inventory[res]
					if absf(spent - float(cost[res])) > 0.2:
						short = "%s cost %s, keep fell %.2f" % [b.type_id, str(cost), spent]
				paid = short if short != "" else "yes"
		await process_frame
	var supplied := _town_state(campaign)
	print("METRIC " + JSON.stringify({"phase": "rival_materials", "robbed": poor, "supplied": supplied}))
	_check(supplied.buildings > poor.buildings,
			"the same town builds once its people are left the materials they cut")
	_check(paid == "yes",
			"and the keep is debited the building's own BuildingDefs price as it goes up (%s)" % paid)
	game.free()
	await process_frame


## People and food. A resident costs food out of the keep and needs a roof, and
## a town with nobody left in it is not a spawner that refills itself.
func _expansion_needs_people_and_food() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("peaceful")
	var keep := campaign._enemy_type("keep")
	var started := campaign.town_population
	var step := Config.MAX_SIM_STEP
	var per_day := roundi(Config.DAY_LENGTH / step)
	for _d in 30:
		for _i in per_day:
			game.sim.water.tick(step)
			game.sim.campaign.tick(step)
			keep.inventory[Config.Res.FOOD] = 0.0
			game.sim.day += step / Config.DAY_LENGTH
			game.clock.elapsed_days += step / Config.DAY_LENGTH
		await process_frame
	_check(campaign.town_population <= started,
			"thirty days of an empty granary add nobody to the rival's population")
	# Food back, and this time a town with nobody left in it. It stays empty:
	# growth is people raising children, not a counter refilling itself.
	campaign.town_population = 0
	keep.inventory[Config.Res.FOOD] = 300.0
	await _rival_days(game, 20)
	_check(campaign.town_population == 0,
			"a rival town with no residents left and a full granary stays empty")
	game.free()
	await process_frame


## Three neighbours, one seed, one hundred and twenty days. The rows printed
## here are the measurement the balance claims rest on.
func _expansion_personalities() -> void:
	var results := {}
	for personality in FrontierCampaign.PERSONALITIES:
		var game := _new_game(42)
		var campaign: FrontierCampaign = game.sim.campaign
		campaign.set_personality(personality)
		var founding := {}
		for b in campaign.enemy_buildings.values():
			founding[b.id] = true
		var elapsed := 0
		for day in [30, 60, 120]:
			await _rival_days(game, day - elapsed)
			elapsed = day
			var state := _town_state(campaign, founding)
			state.personality = personality
			state.day = day
			state.phase = "rival_personality"
			print("METRIC " + JSON.stringify(state))
			if day == 120:
				results[personality] = state
		_check(FrontierCampaign.validate(campaign.capture()) == "",
				"a %s neighbour at day 120 still writes a valid save" % personality)
		game.free()
		await process_frame
	var aggressive: Dictionary = results.aggressive
	var peaceful: Dictionary = results.peaceful
	var loner: Dictionary = results.loner
	_check(aggressive.guards > peaceful.guards and peaceful.guards >= loner.guards,
			"at day 120 the aggressive neighbour is holding more men under arms than the peaceful one, and the loner fewest (%d/%d/%d)"
			% [aggressive.guards, peaceful.guards, loner.guards])
	_check(peaceful.buildings > loner.buildings and peaceful.people > loner.people,
			"the loner has built and settled less than the peaceful town on the same ground (%d buildings/%d people against %d/%d)"
			% [loner.buildings, loner.people, peaceful.buildings, peaceful.people])
	_check(aggressive.sited >= 6 and peaceful.sited > aggressive.sited and loner.sited <= 3,
			"each temperament raised a different amount of town of its own: %d buildings for the aggressive neighbour, %d for the peaceful one, %d for the loner"
			% [aggressive.sited, peaceful.sited, loner.sited])
	_check(peaceful.iron > 32.0 and loner.iron <= 32.0 and aggressive.iron <= 32.0,
			"only the peaceful neighbour digs more iron than the thirty-two it was founded with, so only a peaceful neighbour is worth trading with twice")


## Growth is state like any other state: a save taken mid-expansion and reloaded
## must develop into the same town, building for building.
##
## The fields the save now carries are named explicitly below, because a round
## trip cannot catch a field `capture` never writes: drop it and both sides of
## the comparison lose it together. Three mutations of this fixture — dropping
## the build clock, dropping each grower's farm, dropping the reconciliation on
## load — passed a comparison that only replayed the save against itself.
##
## `seed()` before each replay because Godot's global generator is not in the
## save. That is a gap in `savegame.gd` and predates this work: measured at HEAD,
## a rival reloaded without it drifts — its growers' hydration first, and from
## there which of them is walking and which is standing in a field, ending in a
## keep holding 77 food on one run and 215 on the other.
##
## What this then establishes, exactly: a save reloaded and replayed develops
## identically to the same save reloaded and replayed again, to the digit. It is
## NOT the stronger claim that a reloaded game matches one that was never
## interrupted. It does not, and that predates this work too — `restore` rebuilds
## each grower with `Citizen.setup(..., _rng, ...)`, which redraws body
## attributes that `capture` never wrote down, so a reloaded grower can walk at a
## slightly different speed than the one he replaced. Live-versus-reloaded was
## measured and diverges at HEAD as well. The fields growth itself added are
## covered by naming them below rather than by leaning on the replay.
func _expansion_survives_loading() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("peaceful")
	await _settled_days(game, 25)
	var snapshot := SaveGame.capture(game)
	_check(SaveGame.validate(snapshot, game.registry) == "",
			"a save taken while the rival is expanding is a valid save")
	var written: Dictionary = snapshot.campaign
	_check(written.has("build_in") and written.has("grow_in")
			and is_equal_approx(written.build_in, campaign._build_in)
			and is_equal_approx(written.grow_in, campaign._grow_in),
			"the save names both of the town's review clocks and writes the values the town is actually holding")
	var named := 0
	for worker in written.workers:
		if int(worker.get("farm_id", -1)) >= 0:
			named += 1
	_check(named == written.workers.size() and written.workers.size() > 3,
			"the save names the farm each of its %d growers works — more growers than a town could hold before it expanded" % written.workers.size())
	var error := game.restore_from(snapshot)
	campaign = game.sim.campaign
	_check(error == "" and campaign.capture() == written,
			"the growth a mid-expansion save carries comes back exactly as it was written: " + error)
	var standing := 0
	for farm in campaign._farms:
		standing += farm.workers.size()
	_check(standing == campaign._workers.size() and campaign._harvest_rate() > 0.0,
			"every grower is standing in a field after loading and the fields are worked, rather than the farms coming back empty")
	seed(42)
	await _settled_days(game, 25)
	var uninterrupted: Dictionary = game.sim.campaign.capture()
	_check(uninterrupted.buildings.size() > written.buildings.size(),
			"the twenty-five days replayed either side of the save actually contained construction (%d buildings became %d)"
			% [written.buildings.size(), uninterrupted.buildings.size()])
	error = game.restore_from(snapshot)
	seed(42)
	await _settled_days(game, 25)
	var reloaded: Dictionary = game.sim.campaign.capture()
	_check(error == "" and reloaded == uninterrupted,
			"a reloaded town builds the same buildings in the same places, staffs them with the same people and holds the same stores, to the digit: " + error)
	game.free()
	await process_frame


## Nothing above may hand the player a live readout. What the rival has is what
## a scout last saw it have, dated to the day of the visit.
func _expansion_is_only_seen_by_scouting() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	var scouting: Scouting = game.sim.scouting
	campaign.set_personality("peaceful")
	await _rival_days(game, 12)
	scouting._reveal(campaign.rival_position, 120.0)
	scouting._observe_city()
	var visit: Dictionary = scouting.city_report()
	_check(not visit.is_empty() and visit.has("last_seen_day"),
			"a scout who reaches the town brings back a dated report")
	# The visibility pass has to actually run through the unobserved stretch,
	# once a day, or this proves nothing: `_rival_days` does not call it, and a
	# report that is never asked to refresh trivially does not refresh. It is
	# `refresh_visibility` -> `_observe_city` finding the town out of sight that
	# has to leave the dated report alone.
	var step := Config.MAX_SIM_STEP
	var per_day := roundi(Config.DAY_LENGTH / step)
	var refreshes := 0
	for _d in 45:
		for _i in per_day:
			game.sim.water.tick(step)
			campaign.tick(step)
			game.sim.day += step / Config.DAY_LENGTH
			game.clock.elapsed_days += step / Config.DAY_LENGTH
		scouting.refresh_visibility()
		refreshes += 1
		await process_frame
	var later: Dictionary = scouting.city_report()
	_check(later == visit and refreshes == 45 and not scouting.visibility_at(campaign.rival_position),
			"forty-five days of building, with the fog refreshed on every one of them and the town out of sight, do not edit the report the scout brought home")
	var briefing: Dictionary = campaign.info()
	var leaked := ""
	for key in briefing:
		if key not in ["units", "rations", "can_recruit", "recruit_cost", "civilians",
				"population", "rival_name", "status"]:
			leaked = key
	# Naming the allowed keys is not enough: a live rival count returned under
	# "population" would have passed. Each allowed number is pinned to the thing
	# it is supposed to be — ours — and checked to differ from the rival's.
	_check(leaked == "" and briefing.rival_name == visit.name
			and briefing.population == game.sim.population_members().size()
			and briefing.civilians == game.sim.citizens.size()
			and briefing.units == campaign.friendly_ids().size()
			and briefing.population != campaign.town_population,
			"the frontier panel counts our own people and soldiers and the name on the last report, and carries no number the rival holds now (ours %d, theirs %d)"
			% [briefing.population, campaign.town_population])
	scouting._reveal(campaign.rival_position, 120.0)
	scouting._observe_city()
	var second: Dictionary = scouting.city_report()
	_check(second != visit and second.last_seen_day > visit.last_seen_day,
			"sending someone back replaces the old report with what is there now")
	game.free()
	await process_frame


## Pressure, not a scripted loss. A garrison grown past RAID_GARRISON comes for
## the supply yard of a settlement that raised no army at all; a garrison the
## size the rival is founded with does not.
func _expansion_pressure() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	campaign.set_personality("aggressive")
	var relay := _build(game, "supply_hut", game.world.centre() + Vector3(-90, 0, 60))
	if relay == null:
		game.free()
		return
	sim.day = 10.0
	campaign._assign_guards()
	var raiding := 0
	for u in campaign.units.values():
		if u.faction == 1 and u.target_kind == "building":
			raiding += 1
	_check(campaign.friendly_ids().is_empty() and raiding == 0 and not campaign.at_war,
			"a founding garrison does not raid a settlement that has raised no army")
	while campaign.units.size() - campaign.friendly_ids().size() < FrontierCampaign.RAID_GARRISON:
		campaign._spawn_unit(1, campaign.rival_position + Vector3(0, 0, -20))
	campaign._assign_guards()
	var grown_raiding := 0
	for u in campaign.units.values():
		if u.faction == 1 and u.target_kind == "building" and u.target_id == relay.id:
			grown_raiding += 1
	_check(grown_raiding > 0 and campaign.at_war,
			"a garrison grown to %d comes for the supply yard even though we have no soldiers at all"
			% FrontierCampaign.RAID_GARRISON)
	game.free()
	await process_frame


## And the answer. A settlement that fielded an army can still end a rival that
## has been growing for six weeks, and a conquered town builds nothing further.
func _expansion_can_be_answered() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("aggressive")
	await _rival_days(game, 45)
	var before := _town_state(campaign)
	_check(before.buildings > 6,
			"the rival being answered is one that had six weeks to grow (%d buildings, %d people, %d guards)"
			% [before.buildings, before.people, before.guards])
	var keep := campaign._enemy_type("keep")
	var army: Array[int] = []
	for i in 20:
		var soldier := campaign._spawn_unit(0,
				campaign._door(keep) + Vector3(float(i % 5) * 3.0 - 6.0, 0, 8.0 + float(i / 5) * 3.0))
		soldier.rations = FrontierCampaign.PACK_DAYS
		army.append(soldier.id)
	campaign.command(army, keep.position, {"kind": "building", "id": keep.id})
	for _i in 8000:
		campaign.tick(0.25)
		if campaign.conquered:
			break
	_check(campaign.conquered,
			"twenty supplied soldiers of ours reach the keep of a grown rival and bring it down")
	var after := campaign.enemy_buildings.size()
	# Doubly guaranteed, and worth saying which guard does the work: `conquered`
	# stops `_tick_town` at its first line, and the keep that held every scrap of
	# the town's food and materials is the building that was just burned down, so
	# there is nothing left to build with either. Removing the `conquered` guard
	# on its own changes nothing — recorded as such in the mutation table rather
	# than dressed up as a check that caught it.
	await _rival_days(game, 30)
	_check(campaign.enemy_buildings.size() == after and campaign._keep == null
			and campaign.conquered,
			"a conquered town raises nothing in the month that follows: its keep is gone, and with it every store it would have built from")
	game.free()
	await process_frame


## `--campaign-only=<section>` runs one block. The expansion sections simulate
## hundreds of in-game days each, and every check in them was mutation-tested
## one section at a time; without this the table behind that would have meant a
## dozen runs of the whole suite. An unknown name is a failure and not a quiet
## pass, because a suite that reports "0 failures" over checks that never ran is
## exactly the trap this file has fallen into before.
const SECTIONS := ["core", "growth", "personalities", "saving", "knowledge", "pressure"]


func _run() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--campaign-only="):
			only = arg.trim_prefix("--campaign-only=")
	if only != "" and only not in SECTIONS:
		_check(false, "unknown campaign section '%s'" % only)
		print("Campaign regression failures: %d" % _failures)
		quit(1)
		return
	if only in ["", "core"]:
		await _generation_and_persistence()
		await _foundation_save()
		await _companies()
		await _companies_at_scale()
		await _military()
	if only in ["", "growth"]:
		await _expansion()
		await _expansion_needs_materials()
		await _expansion_needs_people_and_food()
	if only in ["", "personalities"]:
		await _expansion_personalities()
	if only in ["", "saving"]:
		await _expansion_survives_loading()
	if only in ["", "knowledge"]:
		await _expansion_is_only_seen_by_scouting()
	if only in ["", "pressure"]:
		await _expansion_pressure()
		await _expansion_can_be_answered()
	print("Campaign regression failures: %d" % _failures)
	quit(1 if _failures else 0)
