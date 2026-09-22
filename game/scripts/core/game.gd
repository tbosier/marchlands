extends Node3D

## Marchlands — root controller.
##
## Owns the world, the simulation, the camera and the interface, and handles
## the player's two verbs: placing a building, and improving a route.
##
## The opening scenario is the one in design doc 26: a keep, a few houses, a
## stockpile and twenty citizens, with forest to the east, stone to the north
## and good farmland to the south.

const START_FOOD := 200.0
const START_TOOLS := 50.0
const START_TIMBER := 40.0
const START_STONE := 20.0

enum Mode { SELECT, PLACE, CLEAR, BRIDGE }

var registry := AssetRegistry.new()
var clock := Clock.new()
var world: World
var sim: Simulation
var camera: RTSCamera
var hud: HUD

var mode := Mode.SELECT
var place_type := ""
var place_yaw := 0.0
var place_valid := false
var place_position := Vector3.ZERO
var _ghost: Node3D
var _ghost_ok_material: StandardMaterial3D
var _ghost_bad_material: StandardMaterial3D

var selected_building: Building = null
var selected_citizen: Citizen = null
var selected_road := Vector3.ZERO
var has_road_selection := false
var research_open := false
var army_open := false
var scouting_open := false
var city_report_open := false
var selected_scout := -1
var selected_resource := -1
var selected_cow := -1
var trade_open := false
var selected_caravan := -1
var selected_bridge := -1
var _bridge_start := Vector3.INF
var _bridge_hover := Vector3.INF
var _bridge_preview: Node3D
var _world_generation_pending := false
var selected_units: Array[int] = []
var _ring_mesh: Mesh
var road_scope := "busiest"
var _road_quotes: Dictionary = {}
var _road_preview: MultiMeshInstance3D
var _road_quote_level := -1
## `route_extent` is a flood fill over thousands of texels. The road panel is
## refreshed four times a second for as long as a route stays selected, so the
## answer is worked out once per selection rather than per refresh.
var _road_extent_at := Vector3.INF
var _road_extent := 0

var dev: DevOverlay
var dev_mode := false
var show_nav_overlay := false

## How far from the cursor the clear-ground tool reaches, in metres.
const CLEAR_BRUSH := 9.0

var _ui_timer := 0.0
var _screenshot_script := ""


func _ready() -> void:
	randomize()
	var world_seed := _seed_from_args()

	registry.load_all()
	if not registry.missing.is_empty():
		push_warning("Missing assets: %s" % str(registry.missing))
	for problem in BuildingDefs.validate(registry):
		push_error("BuildingDefs: %s" % problem)

	_build_world_and_sim(world_seed)

	camera = RTSCamera.new()
	camera.name = "camera_rig"
	add_child(camera)
	camera.bind_terrain(world.heightmap)

	var layer := CanvasLayer.new()
	layer.name = "ui"
	add_child(layer)
	hud = HUD.new()
	hud.name = "hud"
	layer.add_child(hud)
	hud.setup(sim, clock)
	hud.build_requested.connect(_on_build_requested)
	hud.build_cancelled.connect(_cancel_placement)
	hud.speed_requested.connect(func(i): clock.set_speed(i))
	hud.upgrade_route_requested.connect(request_route_upgrade)
	hud.road_scope_requested.connect(func(scope):
		road_scope = scope
		_draw_road_preview()
		_refresh_selection())
	hud.research_open_requested.connect(func():
		_clear_selection()
		research_open = true
		_refresh_selection())
	hud.research_requested.connect(request_research)
	hud.market_target_requested.connect(func(b, target):
		if not is_instance_valid(b) or sim.buildings_by_id.get(b.id) != b:
			return
		b.set_market_stock_target(target)
		_refresh_selection())
	hud.army_open_requested.connect(func():
		_clear_selection()
		army_open = true
		_refresh_selection())
	hud.scouting_open_requested.connect(func():
		_clear_selection()
		scouting_open = true
		_refresh_selection())
	hud.city_report_requested.connect(func():
		_clear_selection()
		city_report_open = true
		_refresh_selection())
	hud.scout_train_requested.connect(func(id):
		var error: String = sim.scouting.train(id)
		_on_alert(error if error != "" else "A resident has begun scout training.", sim.keep.position)
		_clear_selection()
		scouting_open = true
		_refresh_selection())
	hud.scout_select_requested.connect(func(id):
		_clear_selection()
		selected_scout = id
		scouting_open = true
		for row in sim.scouting.info().scouts:
			if row.id == id: camera.focus_on(row.position, 60.0)
		_refresh_selection())
	hud.scout_recall_requested.connect(func(id):
		var error: String = sim.scouting.recall(id)
		if error != "": _on_alert(error, sim.keep.position)
		_refresh_selection())
	hud.scout_visit_requested.connect(func(id):
		var error: String = sim.scouting.visit_city(id)
		if error != "": _on_alert(error, sim.keep.position)
		_refresh_selection())
	hud.medic_requested.connect(func(id):
		var error: String = sim.campaign.equip_medic(id)
		_on_alert(error if error != "" else "Medic equipped. Nearby wounded will receive field care.", sim.keep.position)
		_refresh_selection())
	hud.firefighting_requested.connect(func(id):
		var error: String = sim.water.request_firefighting(id)
		_on_alert(error if error != "" else "A worker will collect well water and carry it to the fire.", sim.keep.position)
		_refresh_selection())
	hud.poison_well_requested.connect(func(id):
		var error: String = sim.water.poison(id)
		_on_alert(error if error != "" else "Scout assigned to sabotage. Guards can detect and interrupt the attempt.", sim.keep.position)
		_refresh_selection())
	hud.purge_well_requested.connect(func(id):
		# Scrubbing the settlement's only well out costs firefighting water as
		# well as drinking water: WaterSystem breaks the work off when something
		# catches, but the buckets then wait on the shaft refilling at
		# REFILL_PER_DAY. The player is owed that when they give the order, not
		# when the keep is alight — so the same quote the order itself runs is
		# read first and its warning appended to the confirmation.
		var sole: bool = sim.water.purge_quote(id).get("sole_well", false)
		var error: String = sim.water.request_purge(id)
		var told := "A worker is walking to the well. It stays poisoned until they arrive AND finish the work, and from the moment they start it holds no water at all — unless a fire breaks the job off, which refills the shaft and scrubs nothing."
		if sole:
			told += " This is your only well, so while it is dry there is nowhere to drink and no firefighting water either: a fire will break the scrubbing off, and the buckets then wait on the shaft refilling."
		_on_alert(error if error != "" else told, sim.keep.position)
		_refresh_selection())
	hud.purge_cancel_requested.connect(func(id):
		var error: String = sim.water.cancel_purge(id)
		_on_alert(error if error != "" else "The worker is going back to ordinary work. The well is still poisoned.", sim.keep.position)
		_refresh_selection())
	hud.recruit_requested.connect(func():
		var error: String = sim.campaign.recruit()
		if error != "": _on_alert(error, sim.keep.position)
		_refresh_selection())
	hud.company_form_requested.connect(_regroup_selection)
	hud.company_disband_requested.connect(func(company_id: int):
		var name_of: Dictionary = sim.campaign.company_report(company_id)
		if sim.campaign.disband_company(company_id):
			_on_alert("%s disbanded; its soldiers march loose." % name_of.get("name", "The company"), camera.focus)
		_refresh_selection())
	hud.muster_requested.connect(func():
		selected_units.assign(sim.campaign.friendly_ids())
		_on_alert("Force selected — right-click to march or attack", sim.keep.position))
	hud.rival_focus_requested.connect(func():
		var report: Dictionary = sim.scouting.city_report()
		if not report.is_empty(): camera.focus_on(report.position, 100.0))
	hud.armor_requested.connect(func(id, tier):
		var error := MilitaryEquipment.fit(sim, id, tier)
		_on_alert(error if error != "" else "Armor fitted at the barracks.", sim.keep.position)
		_refresh_selection())
	hud.demobilize_requested.connect(func(id):
		var error: String = sim.campaign.demobilize(id)
		_on_alert(error if error != "" else "Soldier returned to civilian life.", sim.keep.position)
		_refresh_selection())
	hud.domesticate_requested.connect(func(id):
		var error: String = sim.husbandry.request_domestication(id)
		_on_alert(error if error != "" else "A rancher will approach and lead this animal home.", sim.keep.position)
		_refresh_selection())
	hud.cattle_focus_requested.connect(_focus_wild_cattle)
	hud.new_world_requested.connect(func(seed_value: int, size_m: int):
		if _world_generation_pending: return
		_world_generation_pending = true
		_on_alert("Generating a new landscape…", world.centre())
		await get_tree().process_frame
		var error := new_world(seed_value, size_m)
		_world_generation_pending = false
		_on_alert(error if error != "" else "A new march begins.", world.centre()))
	hud.trade_open_requested.connect(func():
		_cancel_placement()
		_clear_selection()
		trade_open = true
		_refresh_selection())
	hud.trade_dispatch_requested.connect(func(origin: int, target: int):
		var error: String = sim.trade.dispatch(origin, target)
		_on_alert(error if error != "" else "A citizen is loading the trade cart.", sim.keep.position)
		_refresh_selection()
		hud.refresh())
	hud.caravan_recall_requested.connect(func(id: int):
		var error: String = sim.trade.recall(id)
		if error != "": _on_alert(error, camera.focus)
		_refresh_selection())
	hud.caravan_repeat_requested.connect(func(id: int, enabled: bool):
		sim.trade.set_repeat(id, enabled)
		_refresh_selection())
	hud.bridge_tool_requested.connect(_begin_bridge)
	hud.wreck_recovery_requested.connect(func(id: int, enabled: bool):
		var error: String = sim.trade.request_recovery(id) if enabled else sim.trade.cancel_recovery(id)
		if error != "": _on_alert(error, camera.focus)
		_refresh_selection())
	hud.bridge_remove_requested.connect(func(id: int):
		var result: Dictionary = sim.bridges.remove(id)
		if not result.ok: _on_alert(result.reason, camera.focus)
		_refresh_selection())
	hud.demolish_requested.connect(_on_demolish_requested)
	hud.upgrade_requested.connect(_on_upgrade_requested)
	hud.clear_ground_requested.connect(_toggle_clear_tool)
	hud.focus_requested.connect(func(p): camera.focus_on(p, 70.0))

	dev = DevOverlay.new()
	dev.name = "dev_overlay"
	layer.add_child(dev)
	dev.setup(sim, clock, world, camera)
	if sim.campaign != null: dev.bind_campaign(sim.campaign)

	_make_ghost_materials()
	_setup_scenario()
	_setup_campaign()
	_setup_husbandry()
	_setup_connections()

	for arg in OS.get_cmdline_user_args():
		if arg == "--dev":
			dev_mode = true
			dev.visible = true

	camera.look_at_position(sim.keep.global_position, 78.0)
	world.set_time_of_day(clock.day_fraction(), clock.season_fraction())

	_run_harness()


## Everything that is specific to one march, as opposed to one session. Held
## apart from _ready so that loading a save can replace the world and the
## simulation without disturbing the camera, the interface or the dev overlay.
func _build_world_and_sim(world_seed: int) -> void:
	world = World.new()
	world.name = "world"
	add_child(world)
	world.generate(registry, world_seed, _world_settings_from_args())

	sim = Simulation.new()
	sim.name = "simulation"
	add_child(sim)
	sim.setup(world, registry, world_seed)
	sim.alert.connect(_on_alert)


func _seed_from_args() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			return int(arg.substr(7))
	return 20260911


func _world_settings_from_args() -> Dictionary:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--world-size="):
			var preset := arg.substr(13).to_lower()
			var sizes := {"small": 768, "medium": 1536, "large": 3072, "xlarge": 6144,
				"extra_large": 6144, "extra-large": 6144, "xl": 6144}
			return {"size_m": sizes.get(preset, 768), "generation_version": 2}
	return {}


## Build in isolation so a rejected setting or invalid opening cannot erase
## the settlement the player was looking at.
func new_world(seed_value: int, size_m: int) -> String:
	var settings := {"size_m": size_m, "generation_version": 2}
	var error := SaveGame.Validation._world_settings(settings)
	if error != "" or seed_value < -SaveGame.Validation.MAX_SEED or seed_value > SaveGame.Validation.MAX_SEED:
		return error if error != "" else "Seed is outside the supported range"
	var staged := SaveGame.RestoreState.new()
	staged.own_world_3d = true
	staged.render_target_update_mode = SubViewport.UPDATE_DISABLED
	staged.process_mode = Node.PROCESS_MODE_DISABLED
	staged.registry = registry
	add_child(staged)
	staged.world = World.new()
	staged.world.name = "world"
	staged.add_child(staged.world)
	staged.world.generate(registry, seed_value, settings)
	staged.sim = Simulation.new()
	staged.sim.name = "simulation"
	staged.add_child(staged.sim)
	staged.sim.setup(staged.world, registry, seed_value)
	var previous_world := world
	var previous_sim := sim
	world = staged.world
	sim = staged.sim
	_setup_scenario()
	_setup_campaign()
	_setup_husbandry()
	_setup_connections()
	world = previous_world
	sim = previous_sim
	# Generated state has no historical records to validate. Avoid copying and
	# rescanning the entire large wear field just to start an untouched world.
	error = "The opening settlement is incomplete" if staged.sim.keep == null \
			or staged.sim.citizens.size() != Config.START_CITIZENS else ""
	if error != "":
		dev.bind_campaign(sim.campaign)
		staged.free()
		return "Could not start this march: " + error
	error = _adopt_world(staged)
	camera.look_at_position(sim.keep.global_position, 78.0)
	return error


# ---------------------------------------------------------------------------
# Saving and loading
# ---------------------------------------------------------------------------

## Returns "" on success, or the reason it failed.
func save_game(slot: String = SaveGame.QUICK_SLOT) -> String:
	# Settle the world before writing it down. Road levels are a cache over the
	# wear field refreshed on a timer, so a save taken inside that window
	# records a march whose road graph lags its own history by a couple of
	# seconds — and since loading rebuilds the cache from scratch, the march
	# came back with a road the saved one did not have.
	var settled := world.wear.refresh_levels()
	if not settled.is_empty():
		world.nav.apply_road_changes(settled)
		sim.jobs.clear_refusals()
	var problem := SaveGame.write(self, slot)
	if problem == "":
		_on_alert("Saved as '%s'" % slot, camera.focus)
	else:
		_on_alert("Could not save: %s" % problem, camera.focus)
	return problem


## Returns "" on success, or the reason it failed.
func load_game(slot: String = SaveGame.QUICK_SLOT) -> String:
	var problems: Array[String] = []
	var data := SaveGame.read(slot, problems)
	if data.is_empty():
		var why: String = problems[0] if not problems.is_empty() else "unknown"
		_on_alert("Could not load: %s" % why, camera.focus)
		return why
	var invalid := restore_from(data)
	if invalid != "":
		_on_alert("Could not load: %s" % invalid, camera.focus)
		return invalid
	_on_alert("Loaded '%s' — day %d" % [slot, int(data.get("day", 0)) + 1],
			camera.focus)
	return ""


## Replace the current march with a saved one, in place.
##
## Validate, then build the replacement in an isolated viewport. The live
## march stays intact until the new world has accepted all its saved records.
##
## The camera, the interface and the dev overlay survive: the view stays where
## the player left it, and whatever they had open stays open.
func restore_from(data: Dictionary) -> String:
	data = SaveGame.migrate(data)
	var invalid := SaveGame.validate(data, registry)
	if invalid != "":
		return invalid
	var staged := SaveGame.RestoreState.new()
	staged.own_world_3d = true
	staged.render_target_update_mode = SubViewport.UPDATE_DISABLED
	staged.process_mode = Node.PROCESS_MODE_DISABLED
	staged.registry = registry
	add_child(staged)
	staged.world = World.new()
	staged.world.name = "world"
	staged.add_child(staged.world)
	staged.world.generate(registry, data.seed, data.get("world_settings", {}))
	invalid = SaveGame.Validation.validate_world(data, staged.world)
	if invalid != "":
		staged.free()
		return invalid
	staged.sim = Simulation.new()
	staged.sim.name = "simulation"
	staged.add_child(staged.sim)
	staged.sim.setup(staged.world, registry, data.seed)
	invalid = SaveGame.restore(staged, data)
	if invalid != "":
		staged.free()
		return invalid

	return _adopt_world(staged)


func _adopt_world(staged: SaveGame.RestoreState) -> String:
	_cancel_placement()
	_exit_clear_tool()
	_clear_selection()
	_road_extent_at = Vector3.INF
	_road_extent = 0

	# Freed outright rather than queued: the replacements take the same node
	# names, and a queued node still holds its name until the end of the frame.
	remove_child(sim)
	sim.free()
	remove_child(world)
	world.free()

	world = staged.world
	sim = staged.sim
	staged.remove_child(world)
	staged.remove_child(sim)
	add_child(world)
	add_child(sim)
	sim.alert.connect(_on_alert)
	clock.elapsed_days = staged.clock.elapsed_days
	clock.set_day_marker(floori(clock.elapsed_days))
	clock.restore_speed(staged.clock.speed_index, staged.clock.resume_speed_index())
	staged.free()
	# The camera and interface outlived the world they were pointed at.
	camera.bind_terrain(world.heightmap)
	hud.setup(sim, clock)
	dev.setup(sim, clock, world, camera)
	if sim.campaign != null: dev.bind_campaign(sim.campaign)

	# The camera is only moved when where it was looking makes no sense any
	# more — a save loaded over a session the player had panned somewhere else
	# entirely. Snapping to the keep on every load would throw away the view
	# they had set up.
	if sim.keep and camera.focus.distance_to(sim.keep.global_position) > 400.0:
		camera.look_at_position(sim.keep.global_position, camera.distance)
	world.set_time_of_day(clock.day_fraction(), clock.season_fraction())
	hud.refresh()
	return ""


# ---------------------------------------------------------------------------
# Opening scenario (design doc 26)
# ---------------------------------------------------------------------------

## Radius of ground cleared for the opening settlement, in metres.
const START_CLEARING := 46.0


func _setup_scenario() -> void:
	var centre := world.centre()

	# The march has been held long enough to have cleared its own ground.
	var felled := world.nodes.clear_area(centre, START_CLEARING)
	for rec in world.nodes.records:
		if rec.depleted and rec.kind != ResourceNodes.Kind.TREE:
			var c := world.world_to_cell(rec.position)
			world.nav.set_blocked(c.x, c.y, false)
	var keep := sim.place_building("keep", centre, PI, true)
	keep.inventory[Config.Res.FOOD] = START_FOOD
	keep.inventory[Config.Res.TOOLS] = START_TOOLS
	keep.inventory[Config.Res.TIMBER] = START_TIMBER
	keep.inventory[Config.Res.STONE] = START_STONE

	# Four houses and a stockpile, loosely grouped south of the keep so the
	# settlement has somewhere to be before the player touches anything.
	var rng := RandomNumberGenerator.new()
	rng.seed = world.world_seed + 7
	var house_spots := [
		Vector3(-19, 0, 21), Vector3(-6, 0, 26),
		Vector3(9, 0, 24), Vector3(21, 0, 16),
	]
	for offset in house_spots:
		var p: Vector3 = centre + (offset as Vector3)
		p = _settle(p)
		sim.place_building("house", p, PI + rng.randf_range(-0.35, 0.35), true)

	var stock := _settle(centre + Vector3(16, 0, -6))
	sim.place_building("stockpile", stock, PI * 0.5, true)
	# Established households start with one physical water source. Subsequent
	# districts and expeditions need the player to build their own wells.
	var well_position := Vector3.INF
	for ring in 12:
		for index in 12:
			var angle := TAU * index / 12.0
			var candidate := centre + Vector3(-20, 0, -14) + Vector3(cos(angle), 0, sin(angle)) * ring * 3.0
			candidate.y = world.heightmap.height_at(candidate.x, candidate.z)
			if sim.can_place("well", candidate).ok:
				well_position = candidate
				break
		if well_position.is_finite(): break
	if well_position.is_finite(): sim.place_building("well", well_position, 0.0, true)

	# The settlement's one cart, parked at the stockpile's loading bay.
	var cart := Cart.new()
	world.effects_root.add_child(cart)
	var bay := stock + Vector3(4.5, 0, 4.5)
	bay.y = world.heightmap.height_at(bay.x, bay.z)
	cart.setup(registry, bay)
	sim.set_cart(cart)

	for i in Config.START_CITIZENS:
		var a := TAU * i / float(Config.START_CITIZENS)
		var r := rng.randf_range(10.0, 22.0)
		sim.add_citizen(centre + Vector3(cos(a) * r, 0, sin(a) * r + 14.0))

	sim.workforce.mark_all_dirty()
	hud.refresh()


## Nudge a proposed position to somewhere actually buildable nearby.
func _settle(p: Vector3) -> Vector3:
	p.y = world.heightmap.height_at(p.x, p.z)
	var c := world.world_to_cell(p)
	if world.heightmap.cell_slope(c.x, c.y) < Config.MAX_BUILD_SLOPE \
			and world.heightmap.cell_surface(c.x, c.y) != Heightmap.Surface.WATER:
		return p
	for r in range(1, 10):
		for a in 12:
			var ang := TAU * a / 12.0
			var q := p + Vector3(cos(ang) * r * 4.0, 0, sin(ang) * r * 4.0)
			var qc := world.world_to_cell(q)
			if world.heightmap.cell_slope(qc.x, qc.y) < Config.MAX_BUILD_SLOPE \
					and world.heightmap.cell_surface(qc.x, qc.y) \
						!= Heightmap.Surface.WATER:
				q.y = world.heightmap.height_at(q.x, q.z)
				return q
	return p


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if mode == Mode.BRIDGE:
		_update_bridge_preview()
	if sim.campaign != null and sim.campaign.defeated:
		clock.set_speed(0)
	var sim_delta := clock.advance(minf(delta, 0.25))
	if sim_delta > 0.0:
		# At high speeds a single frame can represent several seconds of world
		# time. Stepping it in slices keeps movement and wear accumulation
		# accurate instead of letting citizens teleport past their waypoints.
		var remaining := sim_delta
		while remaining > 0.0:
			var step: float = minf(remaining, Config.MAX_SIM_STEP)
			sim.tick(step)
			remaining -= step
		world.set_time_of_day(clock.day_fraction(), clock.season_fraction())

	# Once per rendered frame, whatever the simulation did in between.
	world.wear.flush_texture()

	if mode == Mode.PLACE:
		_update_ghost()

	_ui_timer -= delta
	if _ui_timer <= 0.0:
		_ui_timer = 0.25
		hud.refresh()
		_refresh_selection()
		_refresh_unit_rings()
		if mode == Mode.SELECT:
			_refresh_resource_hover()

	Perf.flush_frame()


func _refresh_city_marker() -> void:
	if sim.scouting == null: return
	var report: Dictionary = sim.scouting.city_report()
	var screen := Vector2.ZERO
	var on_screen := false
	if not report.is_empty():
		var at: Vector3 = report.position + Vector3(0, 12, 0)
		var view := camera.camera()
		screen = view.unproject_position(at)
		on_screen = not view.is_position_behind(at) and Rect2(Vector2(120, 85), get_viewport().get_visible_rect().size - Vector2(240, 180)).has_point(screen)
	hud.update_city_marker(report, sim.day, screen, on_screen)


func _refresh_selection() -> void:
	_refresh_city_marker.call_deferred()
	if mode == Mode.BRIDGE:
		return
	if city_report_open:
		hud.show_city_report(sim.scouting.city_report(), sim.day)
		return
	if scouting_open:
		hud.show_scouts(sim.scouting.info(), selected_scout)
		return
	if trade_open or selected_caravan >= 0:
		if selected_caravan >= 0 and not sim.trade.caravans.has(selected_caravan): selected_caravan = -1
		hud.show_trade(sim.trade.info(), selected_caravan)
		return
	if selected_bridge >= 0:
		var bridge_info: Dictionary = sim.bridges.info(selected_bridge)
		if not bridge_info.is_empty():
			hud.show_bridge(bridge_info)
			return
		selected_bridge = -1
	_prune_selection()
	if research_open:
		var quotes: Array = []
		var state: Dictionary = sim.research.capture()
		for id in RoadResearch.TECH_IDS:
			var q: Dictionary = sim.research.quote(id, _has_market())
			q.completed = state.completed.has(id)
			q.active = state.active == id
			q.remaining_days = state.remaining_days if q.active else 0.0
			quotes.append(q)
		hud.show_research(quotes)
		return
	if army_open and sim.campaign != null:
		hud.show_army(sim.campaign.info())
		return
	if selected_cow >= 0 and sim.husbandry != null:
		var info: Dictionary = sim.husbandry.get_info(selected_cow)
		if not info.is_empty() and sim.scouting.visibility_at(info.position):
			hud.show_cow(info)
			return
		selected_cow = -1
		hud.clear_selection()
	if not selected_units.is_empty() and sim.campaign != null:
		var unit: Node = sim.campaign.units.get(selected_units[0])
		if is_instance_valid(unit) and (unit.faction == 0 or sim.scouting.visibility_at(unit.position)):
			# One soldier keeps his own panel — armor, wounds, discharge. Two
			# or more is a block, and the block's panel is about the block.
			if selected_units.size() > 1:
				hud.show_company(sim.campaign.selection_report(selected_units))
			else:
				hud.show_soldier(unit,
						sim.campaign.company_report(sim.campaign.company_of(unit.id)))
			return
		selected_units.clear()
		hud.clear_selection()
	if selected_resource >= 0:
		var rec := world.nodes.get_node_rec(selected_resource)
		if rec != null and sim.scouting.visibility_at(rec.position):
			hud.show_resource(_resource_info(rec))
			return
		selected_resource = -1
		hud.clear_selection()
	if selected_building != null and is_instance_valid(selected_building):
		hud.show_building(selected_building)
	elif selected_citizen != null and is_instance_valid(selected_citizen):
		hud.show_citizen(selected_citizen)
	elif has_road_selection:
		hud.show_road(_road_info(selected_road))


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	_prune_selection()
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				clock.toggle_pause()
				hud.refresh()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				clock.set_speed(event.keycode - KEY_1 + 1)
				hud.refresh()
			KEY_BRACKETLEFT:
				clock.set_speed(clock.speed_index - 1)
				hud.refresh()
			KEY_BRACKETRIGHT:
				clock.set_speed(clock.speed_index + 1)
				hud.refresh()
			KEY_ESCAPE:
				if mode == Mode.BRIDGE:
					_cancel_bridge()
				elif mode == Mode.CLEAR:
					_exit_clear_tool()
				elif mode == Mode.PLACE:
					_cancel_placement()
				elif selected_building or selected_citizen or has_road_selection or research_open or army_open or scouting_open or city_report_open or trade_open or selected_caravan >= 0 or selected_bridge >= 0 or selected_resource >= 0 or selected_cow >= 0 or not selected_units.is_empty():
					_clear_selection()
				else:
					hud.clear_alerts()
			KEY_R:
				if mode == Mode.PLACE:
					place_yaw += PI * 0.25
			KEY_F:
				_focus_selection()
			KEY_G:
				_regroup_selection()
			KEY_B:
				hud.set_tray_open(not hud.tray_is_open())
			KEY_C:
				_toggle_clear_tool()
			KEY_DELETE:
				if selected_building:
					_on_demolish_requested(selected_building)
			KEY_S:
				if event.ctrl_pressed:
					save_game()
			KEY_L:
				if event.ctrl_pressed:
					load_game()
			KEY_F12:
				_save_screenshot("manual")
			KEY_F3:
				dev_mode = not dev_mode
				dev.toggle()
			KEY_F4: _dev_spawn_settlers(10)
			KEY_F5: _dev_finish_buildings()
			KEY_F6: _dev_grant_resources(300.0)
			KEY_F7: _dev_wear_route()
			KEY_F8: _dev_toggle_nav_overlay()
			KEY_F9:
				Perf.reset()

	elif event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event
		if hud.blocks_mouse(mb.position):
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			match mode:
				Mode.BRIDGE: _bridge_click(mb.position)
				Mode.PLACE: _try_place()
				Mode.CLEAR: _order_clear_at(mb.position)
				_: _pick_at(mb.position, mb.shift_pressed, mb.alt_pressed)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mode == Mode.BRIDGE:
				_cancel_bridge()
			elif mode == Mode.PLACE:
				_cancel_placement()
			elif mode == Mode.CLEAR:
				_exit_clear_tool()
			elif selected_scout >= 0:
				var ray := camera.screen_ray(mb.position)
				var hit := world.terrain.raycast(ray.origin, ray.direction)
				if hit.hit:
					var error: String = sim.scouting.command(selected_scout, hit.position)
					if error != "": _on_alert(error, hit.position)
					_refresh_selection()
			elif not selected_units.is_empty():
				_order_units(mb.position)
			else:
				_clear_selection()


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

## The two states of the placement ghost.
##
## The ghost used to be a lit, half-transparent solid, which put it in exactly
## the wrong register: the sun modelled it like a real building, so its value
## moved with wherever the cursor happened to be. In
## design/screenshots/construction.png the result is a pale blue box you have
## to look for. A proposal is not a building yet and should not pretend to be
## one. These are unshaded, so the ghost holds one constant value wherever the
## cursor takes it — a drawing laid over the world rather than an object
## standing in it.
func _make_ghost_materials() -> void:
	_ghost_ok_material = _ghost_material(Color(0.52, 0.88, 0.62))
	_ghost_bad_material = _ghost_material(Color(0.94, 0.38, 0.34))


func _ghost_material(tint: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.46)
	# Both faces, so the far wall shows through the near one and the ghost
	# reads as a volume being proposed rather than a flat silhouette.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Sorted after the other transparent surfaces in the scene — the water
	# chiefly — so a ghost placed at the lake's edge draws over it rather than
	# under it. It does not defeat the depth buffer: a ghost behind a hill is
	# still hidden by the hill, which is correct.
	mat.render_priority = 1
	return mat


func _on_build_requested(type_id: String) -> void:
	_cancel_bridge()
	_clear_selection()
	_exit_clear_tool()
	mode = Mode.PLACE
	place_type = type_id
	place_yaw = PI
	_spawn_ghost()


func _spawn_ghost() -> void:
	if _ghost:
		_ghost.queue_free()
	var def := BuildingDefs.get_def(place_type)
	_ghost = registry.instantiate(def.asset, 0)
	var dressing := Building.new()
	if def.is_food_depot(): dressing._add_market_stalls(_ghost)
	if place_type == "fort": dressing._add_palisade(_ghost)
	if place_type == "barracks": dressing._add_military_banner(_ghost)
	dressing.free()
	_ghost.name = "placement_ghost"
	world.effects_root.add_child(_ghost)


## The clear-ground tool: click trees to have them felled.
func _toggle_clear_tool() -> void:
	if mode == Mode.CLEAR:
		_exit_clear_tool()
		return
	_cancel_placement()
	_clear_selection()
	mode = Mode.CLEAR
	hud.set_clear_tool_active(true)
	hud.set_hint("Click trees to have them felled · right click / Esc to stop")


func _exit_clear_tool() -> void:
	if mode == Mode.CLEAR:
		mode = Mode.SELECT
	hud.set_clear_tool_active(false)
	hud.set_hint("WASD pan · wheel zoom · middle-drag rotate · click to select")


func _order_clear_at(screen_pos: Vector2) -> void:
	var ray := camera.screen_ray(screen_pos)
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"] or not sim.scouting.visibility_at(hit.position):
		return
	var p: Vector3 = hit["position"]
	# A generous radius: clicking a single trunk at play zoom is unreasonable,
	# and clearing is an area instruction anyway.
	var marked := 0
	for rec in world.nodes.records:
		if rec.kind != ResourceNodes.Kind.TREE or rec.depleted:
			continue
		if rec.position.distance_to(p) > CLEAR_BRUSH:
			continue
		if sim.order_felling(rec):
			marked += 1
	if marked > 0:
		hud.set_hint("%d tree%s marked for felling"
				% [marked, "" if marked == 1 else "s"])


func _on_demolish_requested(b: Building) -> void:
	if not is_instance_valid(b) or sim.buildings_by_id.get(b.id) != b:
		return
	var allowed := sim.can_demolish(b)
	if not allowed["ok"]:
		hud.set_hint(String(allowed["reason"]))
		return
	var was_blueprint := b.under_construction
	var name := b.display_name()
	var result := sim.demolish(b)
	_clear_selection()

	var verb := "cancelled" if was_blueprint else "pulled down"
	var parts: Array[String] = []
	for res in result["refunded"]:
		if float(result["refunded"][res]) > 0.5:
			parts.append("%d %s" % [int(result["refunded"][res]),
					Res.display(res)])
	var lost: Array[String] = []
	for res in result["lost"]:
		lost.append("%d %s" % [int(result["lost"][res]), Res.display(res)])

	var text := "%s %s" % [name, verb]
	if not parts.is_empty():
		text += " — %s returned" % ", ".join(parts)
	if not lost.is_empty():
		# Say so. Claiming a full refund the stores could not absorb is a lie
		# the player would only discover by counting.
		text += " · %s lost, nowhere to store it" % ", ".join(lost)
	_on_alert(text, camera.focus)
	hud.refresh()


func _cancel_placement() -> void:
	_cancel_bridge()
	mode = Mode.SELECT
	place_type = ""
	if _ghost:
		_ghost.queue_free()
		_ghost = null
	hud.set_active_build("")
	hud.hide_cursor_tooltip()


func _update_ghost() -> void:
	if _ghost == null:
		return
	var mouse := get_viewport().get_mouse_position()
	if hud.blocks_mouse(mouse):
		_ghost.visible = false
		hud.hide_cursor_tooltip()
		return
	_ghost.visible = true

	var ray := camera.screen_ray(mouse)
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"]:
		_ghost.visible = false
		return

	place_position = hit["position"]
	_ghost.global_position = place_position
	_ghost.rotation.y = place_yaw

	var check := sim.can_place(place_type, place_position, place_yaw)
	if not sim.scouting.explored_at(place_position):
		check = {"ok": false, "reason": "Explore this ground before building."}
	var def := BuildingDefs.get_def(place_type)
	var cost := def.cost
	var affordable := sim.can_afford(cost)
	place_valid = bool(check["ok"]) and affordable

	for child in _ghost.get_children():
		if child is MeshInstance3D:
			child.material_override = _ghost_ok_material if place_valid \
					else _ghost_bad_material

	_show_placement_tooltip(check, affordable, cost, mouse)


## Everything the design doc asks placement to tell the player: footprint,
## slope, cost, access, and how far workers would have to walk.
func _show_placement_tooltip(check: Dictionary, affordable: bool,
							 cost: Dictionary, mouse: Vector2) -> void:
	if not sim.scouting.explored_at(place_position):
		hud.show_cursor_tooltip(["Explore this ground before building."], mouse)
		return
	var def := BuildingDefs.get_def(place_type)
	var fp: Vector2 = check.get("footprint", Vector2(4, 4))
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % def.display_name)
	lines.append("Footprint  %.1f x %.1f m" % [fp.x, fp.y])

	var slope := float(check.get("slope", 0.0))
	var slope_colour := "#9ec983" if slope < 0.22 else (
			"#e0a85c" if slope <= Config.MAX_BUILD_SLOPE else "#d97368")
	lines.append("Slope  [color=%s]%d%%[/color]"
			% [slope_colour, int(slope * 100.0)])

	if not cost.is_empty():
		var cost_colour := "#9ec983" if affordable else "#d97368"
		lines.append("Cost  [color=%s]%s[/color]"
				% [cost_colour, BuildingDefs.cost_text(place_type)])

	# Travel time for the nearest worker — distance is the enemy (design 2.3).
	var nearest := _nearest_citizen(place_position)
	if nearest != null:
		var d := nearest.global_position.distance_to(place_position)
		lines.append("Nearest worker  %d m (~%ds walk)"
				% [int(d), int(d / Config.WALK_SPEED)])

	var store: Building = sim.stores.find_store(
			Config.Res.TIMBER, place_position, -1)
	if store != null:
		var d2: float = store.global_position.distance_to(place_position)
		lines.append("Storage  %s, %d m" % [store.display_name(), int(d2)])

	var road := world.wear.road_level_at(place_position.x, place_position.z)
	lines.append("Ground  %s" % Config.ROAD_NAMES[road])
	if place_type in ["supply_hut", "fort"]:
		var closest := INF
		for source in sim.buildings:
			if source.under_construction or not source.stores(Config.Res.FOOD): continue
			if source.def.is_food_depot() and sim.keep != null and source.position.distance_to(sim.keep.position) >= place_position.distance_to(sim.keep.position): continue
			closest = minf(closest, source.position.distance_to(place_position))
		lines.append("Supply link  %d m / 160 m" % closest if closest != INF else "No upstream food store")
		if closest > Building.SUPPLY_RELAY_RANGE:
			lines.append("[color=#e0a85c]Place another food relay closer first[/color]")

	if not check["ok"]:
		lines.append("[color=#d97368]Cannot build: %s[/color]"
				% check["reason"])
	elif not affordable:
		lines.append("[color=#d97368]Cannot afford[/color]")

	hud.show_cursor_tooltip(lines, mouse)


func _nearest_citizen(p: Vector3) -> Citizen:
	var best: Citizen = null
	var best_d := INF
	for c in sim.citizens:
		if c.immigrant:
			continue
		var d := c.global_position.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = c
	return best


func _try_place() -> void:
	if not place_valid or not sim.scouting.explored_at(place_position):
		return
	# Input can deliver two clicks before the ghost gets another frame.
	# Recheck the live map after the first click has claimed its footprint.
	if not sim.can_place(place_type, place_position, place_yaw).ok:
		place_valid = false
		return
	var def := BuildingDefs.get_def(place_type)
	var cost := def.cost
	# Nothing is deducted here. A blueprint's cost is the materials haulers
	# physically carry to the site (design doc 6.3), so the stock is spent when
	# it is loaded, not when the player clicks. Affordability is still checked,
	# so you cannot queue a building the kingdom has no hope of supplying.
	if not sim.can_afford(cost):
		return
	var b := sim.place_building(place_type, place_position, place_yaw)
	_on_alert("%s sited" % b.display_name(), b.global_position)

	# The tool stays armed: placing four houses should be four clicks, not four
	# trips to the build bar. Right click or Escape puts it away.
	if sim.can_afford(cost):
		_spawn_ghost()
	else:
		_cancel_placement()
		hud.set_hint("Not enough materials for another %s" % def.display_name)
	hud.refresh()


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _prune_selection() -> void:
	for id in selected_units.duplicate():
		var unit: Node = sim.campaign.units.get(id) if sim.campaign != null else null
		if not is_instance_valid(unit) or unit.health <= 0.0:
			selected_units.erase(id)
	if not is_instance_valid(selected_building) \
			or sim.buildings_by_id.get(selected_building.id) != selected_building:
		selected_building = null
	if not is_instance_valid(selected_citizen) \
			or sim.citizens_by_id.get(selected_citizen.id) != selected_citizen:
		selected_citizen = null
	if selected_units.is_empty() and selected_building == null \
			and selected_citizen == null and not has_road_selection \
			and not research_open and not army_open and not scouting_open and not city_report_open and not trade_open and selected_caravan < 0 and selected_bridge < 0 and mode != Mode.BRIDGE and selected_resource < 0 and selected_cow < 0:
		hud.clear_selection()


func _clear_selection() -> void:
	scouting_open = false
	city_report_open = false
	selected_scout = -1
	trade_open = false
	selected_caravan = -1
	selected_bridge = -1
	research_open = false
	army_open = false
	selected_resource = -1
	selected_cow = -1
	selected_units.clear()
	_road_quotes.clear()
	_road_extent_at = Vector3.INF
	if is_instance_valid(_road_preview):
		_road_preview.queue_free()
		_road_preview = null
	selected_building = null
	selected_citizen = null
	has_road_selection = false
	hud.clear_selection()


func _pick_at(screen_pos: Vector2, additive: bool = false, single: bool = false) -> void:
	var ray := camera.screen_ray(screen_pos)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			ray["origin"], ray["origin"] + ray["direction"] * 3000.0)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 2 | 4 | 8 | 16 | 32 | 64
	var result := space.intersect_ray(query)

	if not result.is_empty():
		var collider: Node = result["collider"]
		if collider.has_meta("scout_id"):
			_clear_selection()
			selected_scout = int(collider.get_meta("scout_id"))
			scouting_open = true
			_refresh_selection()
			return
		if not sim.scouting.visibility_at(result.position):
			_clear_selection()
			return
		if collider.has_meta("caravan_id"):
			_clear_selection()
			selected_caravan = int(collider.get_meta("caravan_id"))
			trade_open = true
			_refresh_selection()
			return
		if collider.has_meta("bridge_id"):
			_clear_selection()
			selected_bridge = int(collider.get_meta("bridge_id"))
			_refresh_selection()
			return
		if collider.has_meta("cow_id"):
			_clear_selection()
			selected_cow = int(collider.get_meta("cow_id"))
			_refresh_selection()
			return
		if collider.has_meta("unit_id"):
			_select_unit(int(collider.get_meta("unit_id")), additive, single)
			return
		if collider.has_meta("rival_building_id"):
			_clear_selection()
			city_report_open = true
			_refresh_selection()
			return
		if collider.has_meta("building_id"):
			_clear_selection()
			selected_building = sim.buildings_by_id.get(
					collider.get_meta("building_id"))
			if selected_building:
				hud.show_building(selected_building)
				return
		elif collider.has_meta("citizen_id"):
			_clear_selection()
			selected_citizen = sim.citizens_by_id.get(
					collider.get_meta("citizen_id"))
			if selected_citizen:
				hud.show_citizen(selected_citizen)
				return

	# Nothing solid: the player clicked the ground, which selects the route
	# there — this is how worn paths become something you can act on.
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"] or not sim.scouting.explored_at(hit.position):
		_clear_selection()
		return
	_clear_selection()
	var resource := world.nodes.pick_ray(ray.origin, ray.direction, ray.origin.distance_to(hit.position) + 1.0)
	if resource != null and sim.scouting.visibility_at(resource.position):
		selected_resource = resource.id
		hud.show_resource(_resource_info(resource))
		return
	selected_road = hit["position"]
	has_road_selection = true
	hud.show_road(_road_info(selected_road))


func _road_info(p: Vector3) -> Dictionary:
	var level := world.wear.road_level_at(p.x, p.z)
	var target := mini(Config.RoadLevel.PAVED, maxi(Config.RoadLevel.DIRT, level + 1))
	if _road_quotes.is_empty() or p.distance_squared_to(_road_extent_at) > 0.01 or target != _road_quote_level:
		_road_extent_at = p
		_road_quote_level = target
		for scope in ["busiest", "local", "all"]:
			_road_quotes[scope] = world.wear.preview_upgrade(p, target, scope)
		_draw_road_preview()
	var proposal: Dictionary = _road_quotes[road_scope]
	var reason: String = proposal.get("error", "")
	if not sim.research.allows_road_upgrade(target):
		reason = "Research %s at the keep first." % ("Paving" if target == Config.RoadLevel.PAVED else "Roadworks")
	elif proposal.count == 0:
		reason = "No used ground needs this improvement. Let traffic form a route first."
	elif not sim.can_afford(proposal.cost):
		reason = "More building materials are needed."
	return {"level": level, "target": target, "scope": road_scope,
		"proposal": proposal, "options": _road_quotes, "reason": reason,
		"can_upgrade": reason == ""}


func _draw_road_preview() -> void:
	if _road_quotes.is_empty(): return
	if is_instance_valid(_road_preview):
		_road_preview.queue_free()
	_road_preview = MultiMeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(Config.WEAR_CELL * 0.92, 0.08, Config.WEAR_CELL * 0.92)
	var material := _ghost_material(Color(0.94, 0.77, 0.32))
	mesh.material = material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	var cells: PackedInt32Array = _road_quotes[road_scope].cells
	multi.instance_count = cells.size()
	for i in cells.size():
		var idx := cells[i]
		var x := (idx % world.wear.res + 0.5) * Config.WEAR_CELL
		var z := (idx / world.wear.res + 0.5) * Config.WEAR_CELL
		multi.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x, world.heightmap.height_at(x,z) + 0.12, z)))
	_road_preview.multimesh = multi
	_road_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_road_preview)


func request_route_upgrade() -> void:
	if not has_road_selection: return
	var shown: Dictionary = _road_quotes.get(road_scope, {})
	var info := _road_info(selected_road)
	# Refreshing the panel may choose a new target when natural traffic has
	# just reached Dirt. Never replace the price the player clicked silently.
	if not shown.is_empty() and (shown.level != info.proposal.level
			or shown.cells != info.proposal.cells or shown.cost != info.proposal.cost):
		_on_alert("The route changed; review the refreshed quote.", selected_road)
		_refresh_selection()
		return
	if not info.can_upgrade:
		_on_alert(info.reason, selected_road)
		return
	var proposal: Dictionary = info.proposal
	var problem := world.wear.validate_upgrade(proposal)
	if problem != "":
		var refreshed := world.wear.preview_upgrade(selected_road, info.target, road_scope)
		if refreshed.get("error", "") == "" and refreshed.cells == proposal.cells and refreshed.cost == proposal.cost:
			proposal = refreshed
		else:
			_road_quotes.clear()
			_on_alert("The route changed; review the refreshed quote.", selected_road)
			_refresh_selection()
			return
	if not sim.stores.try_spend(proposal.cost): return
	world.wear.apply_upgrade(proposal)
	world.nav.apply_road_changes(world.wear.refresh_levels())
	world.wear.flush_texture()
	_road_quotes.clear()
	_on_alert("Improved %d m² to %s" % [proposal.area_m2, Config.ROAD_NAMES[info.target]], selected_road)
	_refresh_selection()


func _has_market() -> bool:
	for b in sim.buildings:
		if b.type_id == "market" and not b.under_construction:
			return true
	return false


func request_research(id: String) -> void:
	var error: String = sim.research.start(id, _has_market(), sim.stores.try_spend)
	_on_alert(error if error != "" else "Research funded — progress is shown at the keep.", sim.keep.position)
	_refresh_selection()


func _resource_info(rec: ResourceNodes.NodeRec) -> Dictionary:
	var title := "Woodland"
	var description := "A logging camp gathers timber here. Cleared trees can regrow."
	if rec.kind == ResourceNodes.Kind.STONE:
		title = "Stone outcrop"
		description = "Build a quarry nearby. This deposit is finite."
	elif rec.kind == ResourceNodes.Kind.IRON:
		title = "Iron ore"
		description = "Build a mine nearby to supply a smith. Dark rock with rusty veins marks iron."
	return {"id": rec.id, "title": title, "description": description, "amount": rec.amount}


func _refresh_resource_hover() -> void:
	var mouse := get_viewport().get_mouse_position()
	if hud.blocks_mouse(mouse):
		hud.hide_cursor_tooltip()
		return
	var ray := camera.screen_ray(mouse)
	var hit := world.terrain.raycast(ray.origin, ray.direction)
	var distance: float = ray.origin.distance_to(hit.position) + 1.0 if hit.hit else 4000.0
	var rec := world.nodes.pick_ray(ray.origin, ray.direction, distance)
	if rec == null or not sim.scouting.visibility_at(rec.position):
		hud.hide_cursor_tooltip()
		return
	var info := _resource_info(rec)
	hud.show_cursor_tooltip(["[b]%s[/b]" % info.title, "%d remaining · click for details" % info.amount], mouse)


func _setup_campaign() -> void:
	sim.campaign = FrontierCampaign.new()
	sim.add_child(sim.campaign)
	sim.campaign.setup(sim, world, registry)
	sim.campaign.generate_rival()
	dev.bind_campaign(sim.campaign)


func _setup_husbandry() -> void:
	sim.husbandry = Husbandry.new()
	sim.add_child(sim.husbandry)
	sim.husbandry.setup(sim, world, registry)
	sim.husbandry.generate_herds()


func _setup_connections() -> void:
	sim.bridges = Bridges.new()
	sim.add_child(sim.bridges)
	sim.bridges.setup(sim, world, registry)
	sim.trade = TradeRoutes.new()
	sim.add_child(sim.trade)
	sim.trade.setup(sim, world, registry)
	sim.scouting = Scouting.new()
	sim.add_child(sim.scouting)
	sim.scouting.setup(sim, world, registry)
	sim.water = WaterSystem.new()
	sim.add_child(sim.water)
	sim.water.setup(sim, world, registry)
	var fog := preload("res://scripts/world/fog_of_war.gd").new()
	world.add_child(fog)
	fog.setup(sim.scouting, world, sim.campaign)


func _focus_wild_cattle() -> void:
	if sim.husbandry == null: return
	for id in sim.husbandry.cows:
		var info: Dictionary = sim.husbandry.get_info(id)
		if info.get("wild", false) and sim.scouting.visibility_at(info.position):
			_clear_selection()
			selected_cow = id
			camera.focus_on(info.position, 45.0)
			_refresh_selection()
			return
	_on_alert("No wild cattle are in sight. Send a scout to look for herds.", sim.keep.position)


## Clicking a soldier selects the company he marches with.
##
## That is the whole point of a company: the block is the thing the player
## gives orders to, so the block is what a click picks up. The two ways out are
## the ordinary real-time-strategy ones — Alt for "just this man", Shift to add
## to what is already held — and together they are also how a split is
## expressed: Alt-click one, Shift+Alt-click the rest, then G.
##
## A drag box was the other candidate and is deliberately not here. It selects
## by where soldiers happen to be standing, which is the opposite of what a
## persistent company is for; it would also need its own screen-space pass over
## every unit, and this project is trying to hold 2,000 of them a side.
func _select_unit(unit_id: int, additive: bool, single: bool) -> void:
	var campaign := sim.campaign
	var unit: Soldier = campaign.units.get(unit_id) if campaign != null else null
	if unit == null:
		_clear_selection()
		return
	if unit.faction != 0:
		# A rival guard is inspected, not commanded; he is not ours to group.
		_clear_selection()
		selected_units.append(unit_id)
		_refresh_selection()
		return
	var ids: Array[int] = [unit_id]
	if not single:
		var members: Array[int] = campaign.company_members(campaign.company_of(unit_id))
		if not members.is_empty(): ids = members
	# The set is carried beside the array rather than asking the array. One
	# click now picks up a company of 2,000, and `Array.has` and `Array.erase`
	# per id made the loops below quadratic in the selection: 11.3 ms to take
	# a company that size, against 3.3 ms once the set answers instead.
	var previous: Array[int] = []
	var already := {}
	if additive:
		# A rival guard never rides along into a selection of ours. He cannot
		# be commanded, so half the selection would silently be ignored by the
		# next order, and the panel would count him as one of our soldiers.
		for id in selected_units:
			var other: Soldier = campaign.units.get(id)
			if other != null and other.faction == 0 and not already.has(id):
				already[id] = true
				previous.append(id)
	_clear_selection()
	# Shift over soldiers already wholly held takes them back out, which is how
	# every other game of this kind behaves and is the only way to undo an
	# over-eager addition without rebuilding the selection from nothing.
	var held := true
	for id in ids:
		if not already.has(id): held = false
	var kept: Array[int] = []
	if held:
		var leaving := {}
		for id in ids: leaving[id] = true
		for id in previous:
			if not leaving.has(id): kept.append(id)
	else:
		kept = previous
		for id in ids:
			if already.has(id): continue
			already[id] = true
			kept.append(id)
	selected_units.assign(kept)
	_refresh_selection()


## The player's one company verb, on G and on the block panel's first button:
## the current selection becomes a company.
##
## Forming, splitting and merging are the same order seen from three starting
## points, so there is one key to learn and the button renames itself after
## whichever of the three the selection actually expresses. The named campaign
## calls are still used where they apply, so their refusals really run — a
## split may not take a whole company, a merge needs two of them.
func _regroup_selection() -> void:
	if sim.campaign == null: return
	_prune_selection()
	var report: Dictionary = sim.campaign.selection_report(selected_units)
	if report.total == 0:
		_on_alert("Select soldiers of your own before forming a company.", camera.focus)
		return
	if report.whole >= 0:
		_on_alert("%s already holds exactly these soldiers — disband it to march them loose."
				% report.companies[0].name, camera.focus)
		return
	var company_id := -1
	var told := "formed"
	if report.split_from >= 0:
		company_id = sim.campaign.split_company(report.split_from, selected_units)
		told = "split off from %s" % report.companies[0].name
	elif report.mergeable:
		# Only when every company in the selection is wholly selected. A merge
		# takes whole rosters, so offering it for a partial selection would
		# conscript men the player never clicked; that case forms from the
		# selection instead, which is what the button and this comment promise.
		var company_ids: Array = []
		for row in report.companies: company_ids.append(row.id)
		company_id = sim.campaign.merge_companies(company_ids)
		told = "merged out of %d companies" % report.companies.size()
	else:
		company_id = sim.campaign.form_company(selected_units)
	if company_id < 0:
		_on_alert("Those soldiers cannot form a company.", camera.focus)
		_refresh_selection()
		return
	var formed: Dictionary = sim.campaign.company_report(company_id)
	_on_alert("%s %s — %d soldiers. Click any of them to select the whole company."
			% [formed.name, told, formed.size], camera.focus)
	_refresh_selection()


func _order_units(screen_pos: Vector2) -> void:
	var ray := camera.screen_ray(screen_pos)
	var hit := world.terrain.raycast(ray.origin, ray.direction)
	if not hit.hit: return
	var target: Dictionary = sim.campaign.pick_target(ray.origin, ray.direction)
	sim.campaign.command(selected_units, hit.position, target)
	_refresh_selection()


func _focus_selection() -> void:
	_prune_selection()
	if selected_caravan >= 0 and sim.trade != null and sim.trade.caravans.has(selected_caravan):
		camera.focus_on(sim.trade.caravans[selected_caravan].merchant.global_position, 28.0)
	elif selected_bridge >= 0 and sim.bridges != null:
		var bridge_info: Dictionary = sim.bridges.info(selected_bridge)
		if not bridge_info.is_empty(): camera.focus_on((bridge_info.a + bridge_info.b) * 0.5, 55.0)
	elif not selected_units.is_empty() and sim.campaign != null:
		var unit: Node = sim.campaign.units.get(selected_units[0])
		if is_instance_valid(unit) and (unit.faction == 0 or sim.scouting.visibility_at(unit.position)):
			camera.focus_on(unit.global_position, 28.0)
	elif selected_cow >= 0 and sim.husbandry != null:
		var cow_info: Dictionary = sim.husbandry.get_info(selected_cow)
		if not cow_info.is_empty() and sim.scouting.visibility_at(cow_info.position):
			camera.focus_on(cow_info.position, 35.0)
	elif selected_resource >= 0:
		var resource := world.nodes.get_node_rec(selected_resource)
		if resource != null and sim.scouting.visibility_at(resource.position):
			camera.focus_on(resource.position, 35.0)
	elif selected_building:
		camera.focus_on(selected_building.global_position, 55.0)
	elif selected_citizen:
		camera.focus_on(selected_citizen.global_position, 28.0)
	elif has_road_selection:
		camera.focus_on(selected_road, 45.0)


## Grow a building into its next tier (design doc 6.4).
func _on_upgrade_requested(b: Building) -> void:
	if not is_instance_valid(b) or sim.buildings_by_id.get(b.id) != b:
		return
	var result := sim.upgrade(b)
	if not result["ok"]:
		_on_alert("Cannot upgrade %s: %s"
				% [b.display_name(), result["reason"]], b.global_position)
		return
	# The panel is showing the building it used to be.
	hud.show_building(b)
	hud.refresh()


func _on_alert(text: String, position: Vector3) -> void:
	hud.push_alert(text, position)


# ---------------------------------------------------------------------------
# Developer commands
#
# Gated behind dev mode so a stray function key during normal play cannot
# quietly rewrite the settlement.
# ---------------------------------------------------------------------------

func _dev_guard() -> bool:
	if dev_mode:
		return true
	hud.set_hint("Developer tools are off — press F3 to enable them")
	return false


func _dev_spawn_settlers(count: int) -> void:
	if not _dev_guard():
		return
	var origin := sim.keep.global_position if sim.keep else world.centre()
	for i in count:
		var a := TAU * i / float(count)
		sim.add_citizen(origin + Vector3(cos(a) * 14.0, 0, sin(a) * 14.0))
	_on_alert("%d settlers conjured" % count, origin)


func _dev_finish_buildings() -> void:
	if not _dev_guard():
		return
	var n := 0
	for b in sim.buildings.duplicate():
		if b.under_construction:
			for res in b.build_cost:
				b.deliver_material(res, float(b.build_cost[res]))
			b.finish_construction()
			# Go through the simulation's own completion path rather than
			# repeating two of its five steps. Skipping it left the site's
			# build order — the highest priority job in the game — on the board
			# for ever, and every idle pair of hands near it kept claiming a
			# job for a building that was already finished.
			sim._on_building_completed(b)
			n += 1
	sim.workforce.mark_all_dirty()
	_on_alert("%d buildings completed" % n, camera.focus)


func _dev_grant_resources(amount: float) -> void:
	if not _dev_guard():
		return
	if sim.keep == null:
		return
	for res in Config.RES_COUNT:
		sim.keep.inventory[res] += amount
	_on_alert("granted %d of every resource" % int(amount),
			sim.keep.global_position)


## Stamp enough traffic under the cursor to force a route into existence,
## for testing the road system without waiting for citizens to wear one.
func _dev_wear_route() -> void:
	if not _dev_guard():
		return
	var ray := camera.screen_ray(get_viewport().get_mouse_position())
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"]:
		return
	var p: Vector3 = hit["position"]
	world.wear.stamp_point(p.x, p.z, Config.ROAD_THRESHOLD[
			Config.RoadLevel.DIRT] * 1.2, 3.0)
	world.nav.apply_road_changes(world.wear.refresh_levels())
	world.wear.flush_texture()
	_on_alert("route worn in", p)


func _dev_toggle_nav_overlay() -> void:
	if not _dev_guard():
		return
	show_nav_overlay = not show_nav_overlay
	world.set_nav_overlay(show_nav_overlay)


# ---------------------------------------------------------------------------
# Screenshot / automation harness
# ---------------------------------------------------------------------------

## Lets the build pipeline drive the game headlessly and capture frames, which
## is how the project verifies that changes actually look right.
func _run_harness() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--harness="):
			_screenshot_script = arg.substr(10)
	if _screenshot_script == "":
		return
	var harness: Node = load("res://scripts/core/harness.gd").new()
	harness.name = "harness"
	add_child(harness)
	harness.run(self, _screenshot_script)


func _save_screenshot(tag: String) -> String:
	var image := get_viewport().get_texture().get_image()
	var dir := "user://screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s_%d.png" % [dir, tag, Time.get_ticks_msec()]
	image.save_png(path)
	print("screenshot: ", ProjectSettings.globalize_path(path))
	return ProjectSettings.globalize_path(path)


## Every ring is the same gold torus, so one mesh and one material are built
## once and shared by all of them. A ring used to allocate its own TorusMesh
## and StandardMaterial3D inside the loop below: 39 ms to raise the rings of a
## 2,000-man company against 10 ms sharing one, and 2,000 unique resources left
## alive for as long as the army was.
func _ring_prototype() -> Mesh:
	if _ring_mesh != null: return _ring_mesh
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.7
	mesh.outer_radius = 1.0
	mesh.rings = 16
	mesh.ring_segments = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.94, 0.77, 0.32)
	mesh.material = mat
	_ring_mesh = mesh
	return _ring_mesh


func _refresh_unit_rings() -> void:
	if sim.campaign == null: return
	# One click now selects a whole company, so this can be handed two thousand
	# ids rather than the handful a single pick used to give it. `Array.has` per
	# unit made that units x selected; the set is built once instead.
	var held := {}
	for id in selected_units: held[id] = true
	for unit in sim.campaign.units.values():
		var ring := unit.get_node_or_null("selection_ring") as MeshInstance3D
		var selected: bool = held.has(unit.id)
		if selected and ring == null:
			ring = MeshInstance3D.new()
			ring.name = "selection_ring"
			# A deselected ring is hidden, not freed: selections change every
			# click and rebuilding the node would give back the per-unit
			# allocation this shared mesh exists to remove.
			ring.mesh = _ring_prototype()
			ring.scale.y = 0.15
			ring.position.y = 0.06
			ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			unit.add_child(ring)
		if ring != null: ring.visible = selected


func _begin_bridge() -> void:
	_cancel_placement()
	_exit_clear_tool()
	_clear_selection()
	hud.set_tray_open(false)
	mode = Mode.BRIDGE
	_bridge_start = Vector3.INF
	_bridge_hover = Vector3.INF
	hud.set_hint("Click opposite banks to build a timber bridge · right-click cancels")
	hud.show_bridge_preview({}, false)


func _cancel_bridge() -> void:
	if is_instance_valid(_bridge_preview): _bridge_preview.queue_free()
	_bridge_preview = null
	_bridge_start = Vector3.INF
	_bridge_hover = Vector3.INF
	if mode == Mode.BRIDGE:
		mode = Mode.SELECT
		hud.clear_selection()
		hud.set_hint("WASD pan · wheel zoom · middle-drag rotate · click to select")


func _bridge_hit(screen_position: Vector2) -> Dictionary:
	var ray := camera.screen_ray(screen_position)
	return world.terrain.raycast(ray.origin, ray.direction)


func _bridge_click(screen_position: Vector2) -> void:
	var hit := _bridge_hit(screen_position)
	if not hit.hit or not sim.scouting.explored_at(hit.position): return
	if not _bridge_start.is_finite():
		var cell := world.world_to_cell(hit.position)
		if world.nav.is_solid(cell.x, cell.y):
			_on_alert("Choose a clear, dry river bank first.", hit.position)
			return
		_bridge_start = hit.position
		_bridge_hover = Vector3.INF
		_update_bridge_preview()
		return
	var result: Dictionary = sim.bridges.place(_bridge_start, hit.position)
	if not result.ok:
		_on_alert(result.reason, hit.position)
		return
	var id := int(result.id)
	_cancel_bridge()
	_clear_selection()
	selected_bridge = id
	_on_alert("Timber bridge ordered. Builders will deliver its materials.", hit.position)
	_refresh_selection()


func _update_bridge_preview() -> void:
	if not _bridge_start.is_finite(): return
	var mouse := get_viewport().get_mouse_position()
	if hud.blocks_mouse(mouse): return
	var hit := _bridge_hit(mouse)
	if not hit.hit or not sim.scouting.explored_at(hit.position):
		if is_instance_valid(_bridge_preview): _bridge_preview.queue_free()
		_bridge_preview = null
		_bridge_hover = Vector3.INF
		hud.show_bridge_preview({"ok": false, "reason": "Explore both banks before building a bridge."}, true)
		return
	var at: Vector3 = hit.position
	# Geometry and path comparison only need refreshing after the pointer
	# crosses a navigation cell; do not run a route search every render frame.
	if _bridge_hover.is_finite() and world.world_to_cell(at) == world.world_to_cell(_bridge_hover): return
	_bridge_hover = at
	var quote: Dictionary = sim.bridges.quote(_bridge_start, at)
	if is_instance_valid(_bridge_preview): _bridge_preview.queue_free()
	_bridge_preview = null
	if quote.has("a") and quote.has("b") and quote.a.distance_to(quote.b) >= 1.0:
		var preview := BridgeVisual.new()
		world.effects_root.add_child(preview)
		preview.setup(-1, quote.a, quote.b, Bridges.WIDTH, 1.0, true, quote.ok)
		_bridge_preview = preview
	hud.show_bridge_preview(quote, true)
