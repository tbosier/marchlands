extends "res://tests/long_run.gd"

## tools/godot_env.sh --headless --path game --script res://tests/game_integration.gd


func _selection_and_placement() -> void:
	var game := _new_game(42)
	var house: Building = game.sim.buildings.filter(func(b): return b.type_id == "house")[0]
	game.selected_building = house
	game._refresh_selection()
	game.sim.demolish(house, false)
	game._refresh_selection()
	_check(game.selected_building == null and not game.hud._selection_panel.visible,
			"a destroyed selected building immediately leaves the inspector")
	game._clear_selection()
	await process_frame
	game._focus_selection()
	var first: Soldier = game.sim.campaign._spawn_unit(0, game.sim.entrance_of(game.sim.keep, "att_entrance"))
	var second: Soldier = game.sim.campaign._spawn_unit(0, first.position + Vector3(3, 0, 0))
	game.selected_units.assign([first.id, second.id])
	game._refresh_selection()
	game.sim.campaign._remove_unit(first)
	game._refresh_selection()
	_check(game.selected_units == [second.id] and game.hud._selection_title.text == second.given_name,
			"a force selection keeps its surviving units when the first unit dies")
	game.sim.campaign._remove_unit(second)
	game._refresh_selection()
	_check(game.selected_units.is_empty() and not game.hud._selection_panel.visible,
			"the last selected unit dying clears its stale inspector")
	game._clear_selection()
	var market := _build(game, "market", game.world.centre() + Vector3(-45, 0, -10))
	if market != null:
		game.selected_building = market
		game._refresh_selection()
		var stale_policy: Button = game.hud._selection_actions.get_child(0)
		game.sim.demolish(market, false)
		await process_frame
		# The panel refreshes four times a second; clicks in the intervening
		# frame must not dereference a building the fire has already removed.
		stale_policy.pressed.emit()
		game._focus_selection()
		_check(game.selected_building == null and not game.hud._selection_panel.visible,
				"a stale market button and focus shortcut safely handle a freed building")
	var at := _site(game, "house", game.world.centre() + Vector3(45, 0, 35))
	_check(at != Vector3.INF, "placement regression has a valid house site")
	game._on_build_requested("house")
	game.place_position = at
	game.place_valid = true
	var count := game.sim.buildings.size()
	game._try_place()
	_check(game.sim.buildings.size() == count + 1, "a valid placement creates one construction site")
	game._try_place()
	_check(game.sim.buildings.size() == count + 1,
			"two clicks before the next ghost update cannot overlap construction sites")
	game.free()
	await process_frame


func _roads_and_research() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var keep := sim.keep
	keep.inventory[Config.Res.TIMBER] = 100.0
	keep.inventory[Config.Res.STONE] = 100.0
	var before := keep.inventory.duplicate()
	game.request_research("roadworks")
	_check(sim.research.active == "" and keep.inventory == before,
			"the game rejects research without a market before taking payment")
	var market := _build(game, "market", game.world.centre() + Vector3(45, 0, 35))
	if market == null:
		game.free()
		return
	keep.reserved[Config.Res.STONE] = keep.inventory[Config.Res.STONE]
	game.request_research("roadworks")
	_check(sim.research.active == "" and keep.inventory == before,
			"research cannot spend stone already promised to construction")
	keep.reserved[Config.Res.STONE] = 0.0
	game.request_research("roadworks")
	_check(sim.research.active == "roadworks"
			and keep.inventory[Config.Res.TIMBER] == before[Config.Res.TIMBER] - 10.0
			and keep.inventory[Config.Res.STONE] == before[Config.Res.STONE] - 5.0,
			"the game starts research with its exact one-time price")
	sim.research.advance(2.0)
	var wear := game.world.wear
	for x in range(20, 30):
		wear.wear[20 * WearField.RES + x] = Config.ROAD_THRESHOLD[Config.RoadLevel.PATH] + 1.0
	wear.apply_state(wear.capture())
	game.selected_road = Vector3(20.5 * Config.WEAR_CELL, 0.0, 20.5 * Config.WEAR_CELL)
	game.has_road_selection = true
	game.road_scope = "all"
	var quoted := game._road_info(game.selected_road)
	_check(quoted.target == Config.RoadLevel.DIRT and quoted.can_upgrade,
			"the selected path displays its researched Dirt quote")
	before = keep.inventory.duplicate()
	for x in range(20, 30):
		wear.wear[20 * WearField.RES + x] = Config.ROAD_THRESHOLD[Config.RoadLevel.DIRT] + 1.0
	wear.apply_state(wear.capture())
	game.request_route_upgrade()
	_check(keep.inventory == before and wear.locked[20 * WearField.RES + 20] == 0,
			"traffic changing the target surface cannot silently buy a higher-priced upgrade")
	quoted = game._road_info(game.selected_road)
	_check(quoted.target == Config.RoadLevel.IMPROVED and quoted.can_upgrade,
			"a changed target presents the new Improved quote for review")
	# An unrelated path changes the global revision but not this purchase.
	wear.wear[90 * WearField.RES + 90] = Config.ROAD_THRESHOLD[Config.RoadLevel.PATH]
	wear.apply_state(wear.capture())
	game.request_route_upgrade()
	var expected := before.duplicate()
	for res in quoted.proposal.cost:
		expected[res] -= quoted.proposal.cost[res]
	_check(keep.inventory == expected and wear.locked[20 * WearField.RES + 20] == Config.RoadLevel.IMPROVED,
			"unrelated new traffic accepts the unchanged reviewed cells and exact price")
	before = keep.inventory.duplicate()
	game.request_route_upgrade()
	_check(keep.inventory == before, "the next road tier stays locked until Paving is researched")
	game.request_research("paving")
	sim.research.advance(4.0)
	quoted = game._road_info(game.selected_road)
	before = keep.inventory.duplicate()
	for x in range(30, 50):
		wear.wear[20 * WearField.RES + x] = Config.ROAD_THRESHOLD[Config.RoadLevel.DIRT] + 1.0
	wear.apply_state(wear.capture())
	game.request_route_upgrade()
	_check(keep.inventory == before and game._road_quotes.all.count > quoted.proposal.count,
			"a growing connected network refreshes its area and price before payment")
	quoted = game._road_info(game.selected_road)
	keep.reserved[Config.Res.STONE] = keep.inventory[Config.Res.STONE]
	game.request_route_upgrade()
	_check(keep.inventory == before and wear.locked[20 * WearField.RES + 20] == Config.RoadLevel.IMPROVED,
			"a reviewed road quote cannot consume reserved materials or partially upgrade")
	keep.reserved[Config.Res.STONE] = 0.0
	game.request_route_upgrade()
	expected = before.duplicate()
	for res in quoted.proposal.cost:
		expected[res] -= quoted.proposal.cost[res]
	_check(keep.inventory == expected and wear.locked[20 * WearField.RES + 49] == Config.RoadLevel.PAVED,
			"confirming the refreshed quote pays exactly for the full displayed route")
	game.free()
	await process_frame


func _clock_and_load() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var market := _build(game, "market", game.world.centre() + Vector3(45, 0, 35))
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -10))
	if market == null or barracks == null:
		game.free()
		return
	game.request_research("roadworks")
	_check(sim.campaign.recruit() == "", "clock integration recruits a paid soldier")
	var soldier: Soldier = sim.campaign.units[sim.campaign.friendly_ids()[0]]
	soldier.order_move(soldier.position + Vector3(24, 0, 0))
	for rate in [32.0, 64.0]:
		game.clock.set_rate(rate)
		var day := sim.day
		var elapsed := game.clock.elapsed_days
		var left := sim.research.remaining_days
		var time: float = sim.campaign._time
		game._process(0.1)
		var advanced: float = rate * 0.1 / Config.DAY_LENGTH
		_check(is_equal_approx(sim.day - day, advanced)
				and is_equal_approx(game.clock.elapsed_days - elapsed, advanced)
				and is_equal_approx(left - sim.research.remaining_days, advanced)
				and is_equal_approx(sim.campaign._time - time, rate * 0.1),
				"Game._process at %.0fx advances calendar, simulation, research and combat together" % rate)
	game.clock.set_speed(0)
	var paused: Dictionary = sim.campaign.capture()
	var day := sim.day
	var elapsed := game.clock.elapsed_days
	var left := sim.research.remaining_days
	game._process(0.1)
	_check(sim.campaign.capture() == paused and sim.day == day
			and game.clock.elapsed_days == elapsed and sim.research.remaining_days == left,
			"pausing the actual game frame stops movement, rations, combat and research")
	var saved := SaveGame.capture(game)
	game.selected_units.assign([soldier.id])
	game._refresh_selection()
	var error := game.restore_from(saved)
	_check(error == "" and game.selected_units.is_empty() and not game.hud._selection_panel.visible
			and game.hud._sim == game.sim and game.sim.campaign.capture() == saved.campaign
			and game.sim.research.capture() == saved.research,
			"full staged load restores campaign and research while rebinding HUD and clearing old selections: " + error)
	game.clock.toggle_pause()
	day = game.sim.day
	game._process(0.1)
	_check(game.clock.scale() == 64.0 and is_equal_approx(game.sim.day - day, 6.4 / Config.DAY_LENGTH),
			"a paused load resumes its saved 64x rate in the real frame loop")
	game.sim.keep.health = 0.1
	game.sim.keep.apply_damage(0.0, 1.0)
	game.sim.campaign.tick(0.2)
	day = game.sim.day
	game._process(0.1)
	_check(game.sim.campaign.defeated and game.clock.paused() and game.sim.day == day,
			"defeat pauses the actual game frame without freeing its keep")
	error = game.restore_from(saved)
	game.clock.toggle_pause()
	day = game.sim.day
	game._process(0.1)
	_check(error == "" and not game.sim.campaign.defeated and game.sim.day > day,
			"loading a living march after defeat restores playable simulation")
	game.free()
	await process_frame


func _run() -> void:
	await _selection_and_placement()
	await _roads_and_research()
	await _clock_and_load()
	print("Game integration regression failures: %d" % _failures)
	quit(1 if _failures else 0)
