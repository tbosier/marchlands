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


# ---------------------------------------------------------------------------
# Developer tools
#
# The tools exist to reach situations ordinary play cannot, so nothing else in
# the suite can reach them either. Three things are checked of each one: that it
# does what its panel row says, that a save taken immediately afterwards
# validates and loads back, and — collectively — that not one of them touches the
# world while dev mode is off.
# ---------------------------------------------------------------------------

## Everything a developer command can reach, in one comparable value.
##
## The guard check compares this before and after firing every command. It is
## wide on purpose: a fingerprint that counted only citizens would have been
## satisfied while the frost, the fire, the war and the wound all fired.
func _dev_fingerprint(game: SeededGame) -> Dictionary:
	var sim := game.sim
	var poison := 0.0
	for well in sim.water.wells.values():
		poison += float(well.poison)
	var fire := 0.0
	var sites := 0
	for b in sim.buildings:
		fire += b.fire
		if b.under_construction:
			sites += 1
	var condition := 0.0
	for u in sim.campaign.units.values():
		condition += u.health + u.workability()
	return {
		"citizens": sim.citizens.size(),
		"buildings": sim.buildings.size(),
		"sites": sites,
		"inventory": sim.keep.inventory.duplicate(),
		"units": sim.campaign.units.size(),
		"condition": condition,
		"scouts": sim.scouting.scouts.size(),
		"sabotage": sim.water.poison_jobs.size(),
		"purges": sim.water.carriers.size(),
		"at_war": sim.campaign.at_war,
		"day": sim.day,
		"elapsed": game.clock.elapsed_days,
		"poison": poison,
		"fire": fire,
		"nav_overlay": game.show_nav_overlay,
	}


## A save taken right now must validate and load back into a playable march.
##
## Run after every tool, because two of them were wrong the first time in exactly
## this way: `save_validation.gd` pins a ready scout's resident into Scouting's
## trained list, and pins a sabotage kit to the mission's phase, and neither
## produces a symptom until the file is written.
func _dev_reload(game: SeededGame, label: String) -> void:
	var saved := SaveGame.capture(game)
	var invalid := SaveGame.validate(saved, game.registry)
	_check(invalid == "", "the save after '%s' is valid: %s" % [label, invalid])
	if invalid != "":
		return
	var error := game.restore_from(saved)
	_check(error == "" and game.sim.keep != null,
			"the save after '%s' loads back: %s" % [label, error])


func _dev_rival_well(game: SeededGame) -> Building:
	for b in game.sim.campaign.enemy_buildings.values():
		if b.type_id == "well" and not b.under_construction:
			return b
	return null


func _dev_own_well(game: SeededGame) -> Building:
	for b in game.sim.buildings:
		if b.type_id == "well" and not b.under_construction:
			return b
	return null


## Set by each developer phase as its last act. A phase that dies half way
## through reports nothing at all for the checks it never reached, and a suite
## that only counts failures calls that a pass — this project has shipped
## exactly that. `_run` asserts both phases got to the end.
var _dev_phases_finished := 0


func _developer_tools() -> void:
	var game := _new_game(42)
	game.dev_mode = true

	_check(game._dev_command("nonexistent_tool") == "unknown",
			"a command name nothing dispatches is reported rather than swallowed")
	_check(game._dev_keys.size() == DevOverlay.TOOLS.size(),
			"every listed developer tool is bound to a parseable key")
	for row in DevOverlay.TOOLS:
		var bound := false
		for code in game._dev_keys:
			if game._dev_keys[code][0] == row[0]:
				bound = true
		if not bound:
			_check(false, "developer tool '%s' has no key" % row[0])

	# --- a trained scout ---------------------------------------------------
	var scouts: int = game.sim.scouting.scouts.size()
	_check(game._dev_command("scout") == "", "the scout tool runs")
	var rows: Array = game.sim.scouting.info().scouts
	var fresh: Dictionary = rows[rows.size() - 1] if not rows.is_empty() else {}
	_check(game.sim.scouting.scouts.size() == scouts + 1
			and not fresh.get("training", true) and fresh.get("can_explore", false)
			and fresh.get("trained", false) and game.selected_scout == fresh.get("id", -1),
			"the scout tool leaves a trained, provisioned scout selected and ready")
	# Unreachability, stated rather than assumed: this scout is standing at home
	# and cannot be given the sabotage order, which is the whole reason the
	# saboteur tool has to put one at the rival's well itself.
	_check(not game.sim.water.poison_quote(int(fresh.get("id", -1))).can_poison,
			"a scout at the lodge cannot be ordered to poison anything")
	_dev_reload(game, "scout")

	# --- a scout at the rival well with a kit ------------------------------
	var rival_well := _dev_rival_well(game)
	_check(rival_well != null, "the rival town has a well to sabotage")
	_check(game._dev_command("saboteur") == "", "the saboteur tool runs")
	var jobs: Array = game.sim.water.poison_jobs.keys()
	_check(jobs.size() == 1, "the saboteur tool places exactly one sabotage mission")
	if jobs.size() == 1 and rival_well != null:
		var job: Dictionary = game.sim.water.poison_jobs[jobs[0]]
		var saboteur: Scout = game.sim.scouting.scouts[job.scout_id]
		var reach := saboteur.person.global_position.distance_to(rival_well.global_position)
		_check(job.state == "approach" and job.kit == 1.0 and not job.reserved
				and job.target_id == rival_well.id and reach < 60.0,
				"the saboteur stands at the rival well with a kit already paid for")
	_dev_reload(game, "saboteur")

	# --- a friendly soldier, then a wound, then a kill ---------------------
	var friendlies: int = game.sim.campaign.friendly_ids().size()
	_check(game._dev_command("soldier") == "", "the soldier tool runs")
	_check(game.sim.campaign.friendly_ids().size() == friendlies + 1
			and game.selected_units.size() == 1,
			"the soldier tool recruits one soldier and selects him")
	_dev_reload(game, "soldier")
	# restore_from clears the selection, so the soldier is picked up again.
	var soldier_id: int = game.sim.campaign.friendly_ids().max()
	game.selected_units.assign([soldier_id])
	var soldier: Soldier = game.sim.campaign.units[soldier_id]
	_check(soldier.can_strike() and is_equal_approx(soldier.workability(), 1.0),
			"the recruited soldier starts whole")
	_check(game._dev_command("wound") == "", "the wound tool runs")
	# The panel opens on arm_r / maim, and `soldier_body.gd` severs a limb at 75
	# of accumulated cut. One arm gone is workability 0.45 exactly, which is the
	# rule the tool exists to make visible.
	_check(not soldier.can_strike() and is_equal_approx(soldier.workability(), 0.45),
			"the wound tool takes the sword arm off at the panel's default severity")
	_dev_reload(game, "wound")
	soldier_id = game.sim.campaign.friendly_ids().max()
	soldier = game.sim.campaign.units[soldier_id]
	_check(is_equal_approx(soldier.workability(), 0.45),
			"a severed arm survives the save it was given in")
	game.selected_units.assign([soldier_id])
	# The dropdown is read at the moment the command fires, not when it moved.
	game.dev._wound_location.select(DevOverlay.WOUND_LOCATIONS.find("leg_r"))
	var mobility := soldier.mobility_scale()
	_check(game._dev_command("wound") == ""
			and soldier.mobility_scale() < mobility,
			"the panel's location dropdown decides where the next wound lands")
	game.dev._wound_location.select(DevOverlay.WOUND_LOCATIONS.find("arm_r"))
	_dev_reload(game, "a second wound")

	# The kill gets a soldier of its own. Wounding the same man twice can bleed
	# him out, and a corpse the wound made would have satisfied the kill check
	# without the kill tool doing anything at all.
	_check(game._dev_command("soldier") == "", "the soldier tool runs a second time")
	var doomed: int = game.selected_units[0] if not game.selected_units.is_empty() else -1
	var victim: Soldier = game.sim.campaign.units.get(doomed)
	_check(victim != null and victim.health > 0.0,
			"the second recruit is alive before the kill")
	_check(game._dev_command("kill") == "", "the kill tool runs")
	_check(victim != null and victim.health <= 0.0 and game.selected_units.is_empty(),
			"the kill tool kills the selection and drops it from the inspector")
	game.sim.campaign.tick(0.1)
	_check(not game.sim.campaign.units.has(doomed),
			"the killed soldier leaves the roster through the campaign's own tick")
	_dev_reload(game, "kill")

	# --- a rival soldier, and war -----------------------------------------
	game.sim.campaign.at_war = false
	var enemies := 0
	for u in game.sim.campaign.units.values():
		if u.faction == 1:
			enemies += 1
	_check(game._dev_command("rival") == "", "the rival tool runs")
	var arrived := 0
	var at_gate := false
	for u in game.sim.campaign.units.values():
		if u.faction != 1:
			continue
		arrived += 1
		if u.global_position.distance_to(game.sim.keep.global_position) < 60.0:
			at_gate = true
	_check(arrived == enemies + 1 and at_gate and game.sim.campaign.at_war,
			"the rival tool puts one hostile soldier at the keep and starts the war")
	_dev_reload(game, "rival")
	game.sim.campaign.at_war = false
	_check(game._dev_command("war") == "" and game.sim.campaign.at_war,
			"the war tool declares war on its own")
	_dev_reload(game, "war")

	# --- poisoning one of our own wells -----------------------------------
	var own_well := _dev_own_well(game)
	_check(own_well != null, "the opening settlement has a well of its own")
	if own_well != null:
		# The purge is unreachable before the tool fires, which is the claim.
		_check(game.sim.water.request_purge(own_well.id) != "",
				"a clean well cannot be ordered purged")
		game.selected_building = own_well
		_check(game._dev_command("poison") == "", "the poison tool runs")
		var info: Dictionary = game.sim.water.well_info(own_well.id)
		_check(info.get("poisoned", false)
				and is_equal_approx(info.poison_days, WaterSystem.POISON_DAYS),
				"the poison tool contaminates our own well for the full four days")
		_check(game.sim.water.request_purge(own_well.id) == "",
				"a poisoned well can now be ordered purged, which nothing in play could reach")
	_dev_reload(game, "poison")

	# --- fire --------------------------------------------------------------
	var houses: Array = game.sim.buildings.filter(func(b): return b.type_id == "house")
	_check(not houses.is_empty(), "the opening settlement has a house to burn")
	if not houses.is_empty():
		var house: Building = houses[0]
		game._clear_selection()
		game.selected_building = house
		_check(game._dev_command("ignite") == "", "the ignite tool runs")
		# Strong enough to spread rather than gutter out: a blaze loses
		# FIRE_DECAY per second to nothing in particular, and the spread rules
		# are written against a firepot's 0.55.
		_check(house.fire > Building.FIRE_DECAY * 10.0 and house.fire <= 1.0,
				"the ignite tool leaves a blaze at firepot strength")
	_dev_reload(game, "ignite")

	# --- the calendar ------------------------------------------------------
	var season := Clock.season_index_at(game.sim.day)
	_check(game._dev_command("season") == "", "the season tool runs")
	_check(Clock.season_index_at(game.sim.day) == (season + 1) % Clock.SEASONS.size()
			and is_equal_approx(game.clock.elapsed_days, game.sim.day)
			and is_equal_approx(game.sim.day_marker(), game.sim.day),
			"the season jump moves the calendar, the clock and the billing marker together")
	_dev_reload(game, "season")
	_check(game._dev_command("frost") == "", "the frost tool runs")
	var to_frost := Clock.days_to_frost(game.sim.day)
	_check(to_frost > 0.0 and to_frost < 1.0
			and Clock.frost_is_hard_at(game.sim.day + to_frost)
			and Clock.season_index_at(game.sim.day) == Clock.AUTUMN,
			"the frost jump lands in late autumn, hours before a frost that bites")
	var stood_at := game.sim.day
	_check(game._dev_command("frost") == "" and game.sim.day == stood_at,
			"a second frost jump inside the window leaves the calendar alone")
	_dev_reload(game, "frost")
	# And the frost it jumped to actually falls on the crop.
	var farm := _build(game, "farm", game.world.centre() + Vector3(0, 0, 60))
	if farm != null:
		farm.set_crop_growth(1.0)
		# Clamped. The window is meant to be a fraction of a day; a jump that
		# landed somewhere else entirely should make the check below fail in a
		# second rather than quietly simulate the rest of the year.
		var steps := mini(2700, int((Clock.days_to_frost(game.sim.day) + 0.05)
				* Config.DAY_LENGTH / Config.MAX_SIM_STEP))
		for _i in steps:
			game.sim.tick(Config.MAX_SIM_STEP)
			game.clock.elapsed_days += Config.MAX_SIM_STEP / Config.DAY_LENGTH
		_check(Clock.season_index_at(game.sim.day) == Clock.WINTER
				and farm.dormant and farm.crop_growth == 0.0,
				"the frost the tool jumped to arrives and takes the standing crop")
	_dev_reload(game, "frost aftermath")

	# The new tools leave no stranded job, reservation or haul behind them. Run
	# here rather than at the end of the phase: the two oldest tools break these
	# invariants by design — 300 of everything overflows the keep's storage and
	# ten settlers outrun the settlement's roofs — and always have.
	_invariants(game, "dev tools")

	# --- the pre-existing four, still working ------------------------------
	var population := game.sim.citizens.size()
	_check(game._dev_command("settlers") == "" and game.sim.citizens.size() == population + 10,
			"the settler tool still conjures ten residents")
	var stored := game.sim.keep.inventory.duplicate()
	_check(game._dev_command("grant") == "", "the grant tool runs")
	var granted := true
	for res in Config.RES_COUNT:
		if not is_equal_approx(game.sim.keep.inventory[res], stored[res] + 300.0):
			granted = false
	_check(granted, "the grant tool still adds 300 of every resource")
	var site := _build(game, "house", game.world.centre() + Vector3(-60, 0, 40), false)
	_check(site != null and site.under_construction, "an unfinished site is waiting")
	_check(game._dev_command("finish") == "" and site != null and not site.under_construction,
			"the finish tool still completes construction")
	var overlay := game.show_nav_overlay
	_check(game._dev_command("nav") == "" and game.show_nav_overlay != overlay,
			"the navigation overlay still toggles")
	_check(game._dev_command("wear") == "" and game._dev_command("perf") == "",
			"the route and counter tools still dispatch")

	# --- the keys themselves ----------------------------------------------
	#
	# Nothing else in the suite drives `_unhandled_input`, so without this the
	# whole binding path — parsing the overlay's table, requiring the modifier,
	# swallowing the rest of Alt — is untested and the commands are only ever
	# reached by name.
	var scouts_before: int = game.sim.scouting.scouts.size()
	var key := InputEventKey.new()
	key.keycode = KEY_T
	key.pressed = true
	game._unhandled_input(key)
	_check(game.sim.scouting.scouts.size() == scouts_before,
			"a bare letter never reaches a developer tool")
	key.alt_pressed = true
	game._unhandled_input(key)
	_check(game.sim.scouting.scouts.size() == scouts_before + 1,
			"the same letter with Alt held runs the tool the panel lists against it")
	# Alt is the developer modifier, so Alt+C is not the clear-ground tool.
	var clear_key := InputEventKey.new()
	clear_key.keycode = KEY_C
	clear_key.pressed = true
	clear_key.alt_pressed = true
	var mode_before: int = game.mode
	game._unhandled_input(clear_key)
	_check(game.mode == mode_before,
			"Alt swallows the keys it does not bind rather than falling through to play")
	clear_key.alt_pressed = false
	game._unhandled_input(clear_key)
	_check(game.mode == game.Mode.CLEAR,
			"an unmodified gameplay key still reaches the game")
	game._exit_clear_tool()
	# And the buttons, which are the half of the panel a key press does not
	# cover — and the half somebody reading the list is most likely to use.
	var units_before: int = game.sim.campaign.units.size()
	game.dev._tool_buttons["rival"].pressed.emit()
	_check(game.sim.campaign.units.size() == units_before + 1,
			"pressing a row in the panel runs the command that row names")
	_dev_reload(game, "every tool")
	game.free()
	_dev_phases_finished += 1
	await process_frame


## The guard, on its own fixture, with a live target for every command.
##
## The order matters. Targets are set up with dev mode ON, then dev mode is
## turned off and every command is fired at them: that is what makes "nothing
## moved" a claim about the guard rather than a description of commands that had
## nothing to do. Then the identical sequence is fired again with dev mode on and
## the fingerprint must move — without that second half this check would pass
## just as happily against a `_dev_command` that did nothing at all.
func _developer_guard() -> void:
	var game := _new_game(1776)
	game.dev_mode = true
	_check(game._dev_command("soldier") == "", "the guard fixture has a soldier to aim at")
	var target: int = game.selected_units[0] if not game.selected_units.is_empty() else -1
	var houses: Array = game.sim.buildings.filter(func(b): return b.type_id == "house")
	var house: Building = houses[0] if not houses.is_empty() else null
	game.selected_building = house
	game.dev_mode = false

	var before := _dev_fingerprint(game)
	var refused := 0
	for row in DevOverlay.TOOLS:
		if game._dev_command(row[0]) == "off":
			refused += 1
	_check(refused == DevOverlay.TOOLS.size(),
			"every developer command refuses to run with dev mode off")
	_check(_dev_fingerprint(game) == before,
			"no developer command changes anything with dev mode off")
	_check(game.hud._base_hint.contains("Developer tools are off"),
			"a refused command says why rather than failing silently")

	game.dev_mode = true
	game.selected_units.assign([target])
	game.selected_building = house
	var dispatched := 0
	for row in DevOverlay.TOOLS:
		var outcome: String = game._dev_command(row[0])
		if outcome == "unknown":
			_check(false, "developer tool '%s' is listed but nothing dispatches it" % row[0])
		else:
			dispatched += 1
	_check(dispatched == DevOverlay.TOOLS.size() and _dev_fingerprint(game) != before,
			"the same commands with dev mode on do move the world, so the guard check has teeth")
	_dev_reload(game, "the whole table with dev mode on")
	game.free()
	_dev_phases_finished += 1
	await process_frame


## The first playtest's list: homes are houses, old saves are re-homed, rates
## are recorded, the lodge and keep panels lead where the player wanted, and a
## mustered force gets its unit grid.
func _playtest_fixes() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var houses := sim.buildings.filter(func(b): return b.type_id == "house")
	_check(houses.size() == 5 and sim.keep.def.houses == 0 and sim.keep.residents.is_empty(),
			"the opening has five hovels and nobody lives in the keep")
	sim.workforce.mark_all_dirty()
	sim.tick(0.1)
	_check(sim.stat_homeless == 0 and sim.citizens.all(func(c): return c.home_id >= 0),
			"every opening settler has a hovel")
	var free_beds := 0
	for b in houses:
		free_beds += b.def.houses - b.residents.size()
	_check(free_beds >= Config.IMMIGRATION_GROUP_MIN,
			"the opening leaves room for the first newcomers (%d beds)" % free_beds)

	# A save from before: the keep slept people, houses wore the old model.
	var old := SaveGame.capture(game)
	old.erase("housing_layout")
	var keep_record: Dictionary = {}
	for record in old.buildings:
		if record.type_id == "keep": keep_record = record
	var moved: Array = []
	for record in old.buildings:
		if record.type_id == "house":
			record.asset_id = "house_small_02"
			if moved.is_empty() and not record.residents.is_empty():
				moved.append(record.residents.pop_back())
	keep_record.residents = moved.duplicate()
	for person in old.citizens:
		if moved.has(person.id): person.home_id = keep_record.id
	var error := game.restore_from(old)
	sim = game.sim
	_check(error == "" and sim.keep.residents.is_empty()
			and sim.buildings.filter(func(b): return b.type_id == "house").all(
					func(b): return b.asset_id == "house_hovel"),
			"an old save loads with its keep emptied and its houses made hovels: " + error)
	sim.workforce.mark_all_dirty()
	sim.tick(0.1)
	_check(not moved.is_empty() and sim.citizens_by_id[moved[0]].home_id >= 0,
			"the settler who lived in the keep is found a hovel")

	sim._eat_meal(sim.citizens[0])
	_check(sim.ledger.used_per_day(Config.Res.FOOD) >= Config.MEAL_FOOD * 0.99,
			"a meal is recorded as food used")
	game.hud.refresh()
	_check(game.hud._res_labels[Config.Res.FOOD].tooltip_text.contains("used"),
			"hovering food shows what is produced and used")

	var lodge := sim.place_building("scout_lodge",
			sim.keep.global_position + Vector3(-40, 0, -30), 0.0, true)
	game.selected_building = lodge
	game._refresh_selection()
	var manage: Button = null
	for button in game.hud._selection_actions.get_children():
		if button is Button and button.text == "Manage scouts": manage = button
	_check(manage != null, "a scout lodge offers its scouts screen without training anyone")
	if manage != null:
		manage.pressed.emit()
		_check(game.scouting_open, "Manage scouts opens the scouts screen")
	game._clear_selection()
	game.selected_building = sim.keep
	game._refresh_selection()
	_check(game.hud._selection_body.text.contains("Research"),
			"the keep's panel says what is being researched")
	game._clear_selection()

	game.dev_mode = true
	game._dev_command("soldier")
	game._dev_command("soldier")
	game.dev_mode = false
	game.selected_scout = 7
	game.army_open = true
	game.hud.muster_requested.emit()
	_check(game.selected_units.size() >= 2 and game.selected_scout < 0 and not game.army_open,
			"muster makes a fresh selection of the force")
	_check(game.hud._unit_grid_panel.visible
			and game.hud._unit_grid.get_child_count() == game.selected_units.size(),
			"the selected force appears in the unit grid")
	game.hud.unit_pick_requested.emit(game.selected_units[0], false)
	_check(game.selected_units.size() == 1, "clicking a tile picks out one soldier")
	game._clear_selection()
	game._refresh_selection()
	_check(not game.hud._unit_grid_panel.visible, "the grid goes when nobody is selected")
	game.free()
	await process_frame


## A selected scout goes where the player right-clicks: the real input path,
## from a synthesised mouse event through `_unhandled_input` to the order.
func _scout_right_click() -> void:
	# A window's worth of screen: headless starts at 64 x 64, where the
	# interface covers everything a click could land on.
	var previous_size := root.size
	root.size = Vector2i(1280, 720)
	var game := _new_game(42)
	game.dev_mode = true
	_check(game._dev_command("scout") == "", "the scout tool trains a scout")
	game.dev_mode = false
	var scouts: Array = game.sim.scouting.scouts.values()
	_check(not scouts.is_empty(), "a scout is in service")
	if scouts.is_empty():
		game.free()
		root.size = previous_size
		return
	var scout: Scout = scouts[0]
	_check(scout.state == "ready", "the scout is ready for orders (%s)" % scout.state)
	# Picking him out on the map needs real physics; `tests/scouting_ui.gd`
	# covers that click. Here the panel's selection stands in for it.
	game.hud.scout_select_requested.emit(scout.id)
	game.camera.focus_on(scout.person.global_position, 60.0)
	for i in 30:
		game.camera._process(0.1)
	var target: Vector3 = scout.person.global_position + Vector3(24, 0, 18)
	target.y = game.world.heightmap.height_at(target.x, target.z)
	var at: Vector2 = game.camera._camera.unproject_position(target)
	_check(not game._ui_blocks(at), "the target ground is not under the interface")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	click.position = at
	game._unhandled_input(click)
	_check(scout.state == "exploring" and scout.destination.distance_to(target) < 6.0,
			"right-clicking the ground sends the selected scout there (%s, %.1f m off)"
			% [scout.state, scout.destination.distance_to(target)])
	_check(game.selected_scout == scout.id, "and the scout stays selected for the next order")
	# An order given during training is kept, not refused, and carried out
	# the moment training ends.
	scout.state = "training"
	scout.training_left = 1.0
	scout.orders_waiting = false
	var later: Vector3 = scout.person.global_position + Vector3(-20, 0, 14)
	later.y = game.world.heightmap.height_at(later.x, later.z)
	_check(game.sim.scouting.command(scout.id, later) == "" and scout.orders_waiting,
			"a scout still in training takes an order and holds it")
	for i in 8:
		game.sim.scouting.tick(0.25)
	_check(scout.state == "exploring" and not scout.orders_waiting
			and scout.destination.distance_to(later) < 0.01,
			"and sets out on it as soon as training ends (%s)" % scout.state)
	game.free()
	root.size = previous_size
	await process_frame


## A tip appears when its situation arises, once, and "Don't show tips" turns
## them off and remembers it.
func _tips() -> void:
	var game := _new_game(42)
	var tips: Tips = game.tips
	_check(tips != null and not tips.enabled, "tests start with tips off")
	tips.enabled = true
	tips._seen.clear()
	tips._next_at = 0
	for b in game.sim.buildings:
		b.inventory[Config.Res.FOOD] = 0.0
	game.sim.stores.refresh_totals(game.sim.population_members(), game.sim.buildings)
	tips.poll()
	_check(tips.visible and tips.showing() == "food",
			"running short of food brings up the food tip (%s)" % tips.showing())
	tips.dismiss()
	tips._next_at = 0
	tips.poll()
	_check(tips.showing() != "food", "a tip is not shown twice")
	tips.visible = false
	var off: Button = tips.find_child("no_tips", true, false)
	tips.visible = true
	off.pressed.emit()
	_check(not tips.enabled and not tips.visible, "Don't show tips turns them off")
	var settings := ConfigFile.new()
	_check(settings.load(Tips.SETTINGS) == OK
			and settings.get_value("tips", "enabled", true) == false,
			"and the choice is remembered in the settings file")
	tips._next_at = 0
	tips.poll()
	_check(not tips.visible, "no tip appears once they are off")
	_check(not game.hud._tips_button.button_pressed, "the Tips button shows them off")
	game.hud._tips_button.pressed.emit()
	_check(tips.enabled and game.hud._tips_button.button_pressed, "the Tips button turns them back on")
	game.free()
	await process_frame


func _run() -> void:
	await _tips()
	await _scout_right_click()
	await _playtest_fixes()
	await _selection_and_placement()
	await _roads_and_research()
	await _clock_and_load()
	await _developer_tools()
	await _developer_guard()
	_check(_dev_phases_finished == 2,
			"both developer phases ran to the end rather than dying half way")
	print("Game integration regression failures: %d" % _failures)
	quit(1 if _failures else 0)
