extends SceneTree

## Run with tools/godot_env.sh --headless --path game --script res://tests/save_validation.gd
## Exercise the public load path with corrupt files, including rejection after
## seed regeneration, and prove that neither the march nor its controls change.

var _failures := 0
var _rejections := 0
var _slot := ""


func _initialize() -> void:
	_slot = "save_validation_%d" % OS.get_process_id()
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", description])
	if not ok:
		_failures += 1


func _write_fixture(data: Variant, full_objects: bool = false) -> bool:
	DirAccess.make_dir_recursive_absolute(SaveGame.DIR)
	var file := FileAccess.open_compressed(SaveGame.slot_path(_slot),
			FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		_check(false, "open corrupt-save fixture")
		return false
	var written := file.store_var(data, full_objects)
	file.close()
	_check(written, "write fixture")
	return written


func _contents(game: Node) -> PackedByteArray:
	var state := SaveGame.capture(game)
	state.erase("saved_at")
	return var_to_bytes(state)


func _reject(game: Node, data: Variant, description: String,
		direct: bool = false, prepared: bool = false) -> bool:
	var world_id: int = game.world.get_instance_id()
	var sim_id: int = game.sim.get_instance_id()
	var clock_id: int = game.clock.get_instance_id()
	var camera_id: int = game.camera.get_instance_id()
	var hud_id: int = game.hud.get_instance_id()
	var dev_id: int = game.dev.get_instance_id()
	var selected: Variant = game.selected_building
	var citizen: Variant = game.selected_citizen
	var road_selected: bool = game.has_road_selection
	var road: Vector3 = game.selected_road
	var road_extent_at: Vector3 = game._road_extent_at
	var road_extent: int = game._road_extent
	var mode: int = game.mode
	var place_type: String = game.place_type
	var ghost: Variant = game._ghost
	var camera_focus: Vector3 = game.camera.focus
	var before := _contents(game)
	var problem: String
	if direct:
		problem = game.restore_from(data)
	else:
		if not prepared and not _write_fixture(data):
			return false
		problem = game.load_game(_slot)
	_check(not problem.is_empty(), "%s is rejected: %s" % [description, problem])
	var intact: bool = (is_instance_valid(game.world)
			and game.world.get_instance_id() == world_id
			and is_instance_valid(game.sim)
			and game.sim.get_instance_id() == sim_id
			and game.clock.get_instance_id() == clock_id
			and game.camera.get_instance_id() == camera_id
			and game.hud.get_instance_id() == hud_id
			and game.dev.get_instance_id() == dev_id)
	_check(intact, "%s preserves live object identities" % description)
	if not intact:
		return false
	var controls_intact: bool = (game.selected_building == selected
			and game.selected_citizen == citizen
			and game.has_road_selection == road_selected
			and game.selected_road == road and game.mode == mode
			and game._road_extent_at == road_extent_at
			and game._road_extent == road_extent
			and game.place_type == place_type and game._ghost == ghost
			and game.camera.focus == camera_focus)
	_check(controls_intact, "%s preserves selection and controls" % description)
	var contents_intact := _contents(game) == before
	_check(contents_intact, "%s preserves every persisted value" % description)
	game.hud.clear_alerts()
	_rejections += 1
	return not problem.is_empty() and controls_intact and contents_intact


func _replace(data: Dictionary, path: Array, value: Variant) -> Dictionary:
	return _replace_at(data.duplicate(true), path, 0, value)


func _replace_at(parent: Variant, path: Array, depth: int, value: Variant) -> Variant:
	var key: Variant = path[depth]
	if depth == path.size() - 1:
		parent[key] = value
	else:
		# Packed arrays copy on write. Assign the modified child back through
		# every parent so corrupting a texel really reaches the saved fixture.
		parent[key] = _replace_at(parent[key], path, depth + 1, value)
	return parent


func _run() -> void:
	_clock_menu_migration()
	var game: Node = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.sim.workforce.update(game.sim.buildings, game.sim.citizens,
			game.sim.buildings_by_id)
	game.clock.set_rate(4.0)
	game.clock.toggle_pause()
	game.selected_building = game.sim.keep
	game.hud.show_building(game.selected_building)
	game._road_extent_at = game.sim.keep.global_position
	game._road_extent = 1234
	var base := SaveGame.capture(game)
	_check(SaveGame.validate(base, game.registry) == "", "current capture validates")
	var node_count: int = base.nodes.count
	var citizen_id: int = base.citizens[0].id
	var building_id: int = base.buildings[0].id
	var cases: Array = [
		["non-integer version", ["version"], "1"],
		["unsupported version", ["version"], 999],
		["non-integer seed", ["seed"], "broken"],
		["seed overflows generation offsets", ["seed"], 9223372036854775807],
		["negative simulation day", ["day"], -1.0],
		["nonfinite simulation day", ["day"], NAN],
		["extreme finite simulation day", ["day"], 1e300],
		["nonfinite clock time", ["elapsed_days"], INF],
		["extreme finite clock time", ["elapsed_days"], 1e300],
		["day marker beyond current day", ["day_marker"], 1000.0],
		["invalid speed", ["speed_index"], Config.SPEEDS.size()],
		["paused resume speed", ["resume_speed_index"], 0],
		["invalid speed layout", ["speed_layout"], 99],
		["invalid resource layout", ["resource_layout"], 99],
		["noninteger resource layout", ["resource_layout"], 2.0],
		["world settings wrong type", ["world_settings"], []],
		["unsupported map size", ["world_settings", "size_m"], 900],
		["nonfinite map size", ["world_settings", "size_m"], NAN],
		["fractional map size", ["world_settings", "size_m"], 768.5],
		["unsupported generation version", ["world_settings", "generation_version"], 99],
		["noninteger generation version", ["world_settings", "generation_version"], 2.0],
		["resized legacy world", ["world_settings", "size_m"], 1536.0],
		["invalid bridge collection", ["bridges"], []],
		["invalid bridge next ID", ["bridges", "next_id"], 0],
		["invalid trade collection", ["trade"], []],
		["invalid trade next ID", ["trade", "next_id"], 0],
		["invalid ranching discovery", ["research", "ranching_known"], "yes"],
		["invalid cattle state", ["husbandry"], []],
		["nonfinite cow position", ["husbandry", "cows", 0, "position"], Vector3(NAN, 0, 0)],
		["negative cow age", ["husbandry", "cows", 0, "age_days"], -1.0],
		["cow assigned to a keep", ["husbandry", "cows", 0, "ranch_id"], building_id],
		["invalid cattle next ID", ["husbandry", "next_id"], 0],
		["research is not a record", ["research"], []],
		["unknown research", ["research", "completed"], ["alchemy"]],
		["duplicate research", ["research", "completed"], ["roadworks", "roadworks"]],
		["research missing prerequisite", ["research", "completed"], ["metallurgy"]],
		["idle research retains time", ["research", "remaining_days"], 1.0],
		["nonfinite research time", ["research", "remaining_days"], NAN],
		["invalid market target", ["buildings", 0, "market_stock_target"], 60],
		["noninteger market target", ["buildings", 0, "market_stock_target"], 40.0],
		["negative building health", ["buildings", 0, "health"], -1.0],
		["excess building health", ["buildings", 0, "health"], 801.0],
		["nonfinite building health", ["buildings", 0, "health"], INF],
		["negative building fire", ["buildings", 0, "fire"], -0.1],
		["excess building fire", ["buildings", 0, "fire"], 1.1],
		["nonfinite building fire", ["buildings", 0, "fire"], NAN],
		["next building ID overflows", ["next_building_id"], 9223372036854775807],
		["next citizen ID overflows", ["next_citizen_id"], 9223372036854775807],
		["invalid building container", ["buildings"], {}],
		["invalid building record", ["buildings", 0], "building"],
		["unknown building type", ["buildings", 0, "type_id"], "missing_type"],
		["unknown building asset", ["buildings", 0, "asset_id"], "missing_asset"],
		["duplicate building ID", ["buildings", 1, "id"], building_id],
		["invalid building ID", ["buildings", 0, "id"], 0],
		["invalid building position", ["buildings", 0, "position"], [1, 2, 3]],
		["nonfinite building position", ["buildings", 0, "position"], Vector3(INF, 0, 0)],
		["extreme finite building height", ["buildings", 0, "position"], Vector3(384, 1e20, 384)],
		["nonfinite building rotation", ["buildings", 0, "yaw"], NAN],
		["extreme finite building rotation", ["buildings", 0, "yaw"], 1e300],
		["invalid construction flag", ["buildings", 0, "under_construction"], "false"],
		["negative construction progress", ["buildings", 0, "build_progress"], -0.1],
		["nonfinite build duration", ["buildings", 0, "build_seconds"], INF],
		["negative larder", ["buildings", 0, "larder"], -1.0],
		["invalid crop growth", ["buildings", 0, "crop_growth"], 2.0],
		["wrong inventory type", ["buildings", 0, "inventory"], [1, 2, 3, 4, 5]],
		["short inventory", ["buildings", 0, "inventory"], PackedFloat32Array([1.0])],
		["negative inventory", ["buildings", 0, "inventory", 0], -1.0],
		["nonfinite inventory", ["buildings", 0, "inventory", 0], NAN],
		["extreme finite inventory", ["buildings", 0, "inventory", 0], 1e20],
		["unknown resource", ["buildings", 0, "build_cost"], {99: 1.0}],
		["invalid resource key", ["buildings", 0, "delivered"], {"0": 1.0}],
		["negative delivery", ["buildings", 0, "delivered"], {0: -1.0}],
		["extreme finite resource amount", ["buildings", 0, "delivered"], {0: 1e300}],
		["invalid workers", ["buildings", 0, "workers"], {}],
		["unknown resident", ["buildings", 0, "residents"], [999999]],
		["duplicate resident", ["buildings", 0, "residents"], [citizen_id, citizen_id]],
		["invalid field plot", ["buildings", 0, "plots"], ["plot"]],
		["invalid citizen container", ["citizens"], {}],
		["invalid citizen record", ["citizens", 0], null],
		["duplicate citizen ID", ["citizens", 1, "id"], citizen_id],
		["invalid citizen position", ["citizens", 0, "position"], Vector3(0, NAN, 0)],
		["extreme finite citizen height", ["citizens", 0, "position"], Vector3(384, 1e20, 384)],
		["invalid citizen name", ["citizens", 0, "name"], {}],
		["invalid citizen age", ["citizens", 0, "age"], -1],
		["unknown citizen asset", ["citizens", 0, "asset_id"], "missing_asset"],
		["unknown home", ["citizens", 0, "home_id"], 999999],
		["unknown workplace", ["citizens", 0, "workplace_id"], 999999],
		["inconsistent household roll", ["citizens", 0, "home_id"], -1],
		["unknown carried resource", ["citizens", 0, "carrying_res"], Config.RES_COUNT],
		["negative carried quantity", ["citizens", 0, "carrying_amount"], -1.0],
		["invalid immigrant flag", ["citizens", 0, "immigrant"], 1],
		["invalid immigrant destination", ["citizens", 0, "immigrant_target"], "home"],
		["invalid hunger", ["citizens", 0, "hunger"], 1.1],
		["nonfinite meal schedule", ["citizens", 0, "next_meal"], NAN],
		["negative meal counter", ["citizens", 0, "meals_taken"], -1],
		["invalid morale", ["citizens", 0, "morale"], -0.1],
		["invalid cart flag", ["cart"], 1],
		["invalid cart position", ["cart_position"], Vector3.INF],
		["invalid terrain container", ["terrain_edits"], {}],
		["missing terrain extent", ["terrain_edits"], [{"x": 20.0, "z": 20.0}]],
		["negative terrain extent", ["terrain_edits", 0, "half_w"], -1.0],
		["nonfinite terrain coordinate", ["terrain_edits", 0, "x"], INF],
		["invalid wear container", ["wear"], []],
		["wrong wear type", ["wear", "wear"], []],
		["short wear field", ["wear", "wear"], PackedFloat32Array([0.0])],
		["negative wear", ["wear", "wear", 0], -1.0],
		["nonfinite wear", ["wear", "wear", 0], INF],
		["extreme finite wear", ["wear", "wear", 0], 1e20],
		["short road lock field", ["wear", "locked"], PackedByteArray([0])],
		["invalid road lock", ["wear", "locked", 0], 255],
		["invalid resource node container", ["nodes"], []],
		["invalid resource node changes", ["nodes", "changed"], {}],
		["negative resource node index", ["nodes", "changed"], [{"index": -1, "amount": 1.0, "depleted": false}]],
		["resource node index out of bounds", ["nodes", "changed"], [{"index": node_count, "amount": 1.0, "depleted": false}]],
		["duplicate resource node change", ["nodes", "changed"], [{"index": 0, "amount": 1.0, "depleted": false}, {"index": 0, "amount": 1.0, "depleted": false}]],
		["negative node quantity", ["nodes", "changed"], [{"index": 0, "amount": -1.0, "depleted": false}]],
		["nonfinite node quantity", ["nodes", "changed"], [{"index": 0, "amount": INF, "depleted": false}]],
		["invalid clearing order", ["nodes", "marked"], [node_count + 1]],
		["regenerated node count mismatch", ["nodes", "count"], node_count + 1],
		["resource quantity exceeds generated capacity", ["nodes", "changed"], [{"index": 0, "amount": game.world.nodes.records[0].max_amount + 1.0, "depleted": false}]],
	]
	for node in game.world.nodes.records:
		if node.kind != ResourceNodes.Kind.TREE:
			cases.append(["clearing order targets a mineral", ["nodes", "marked"], [node.id]])
			break
	var safe := _reject(game, [1, 2, 3], "non-dictionary save")
	if safe:
		safe = _reject(game, {"version": SaveGame.VERSION}, "incomplete save")
	if safe:
		# A normal schema with an extra field distinguishes refusing object
		# decoding from merely rejecting an object as the root of the save.
		var object_save := base.duplicate(true)
		var payload := Resource.new()
		payload.set_meta("save_validation_probe", true)
		object_save["unexpected_object"] = payload
		if _write_fixture(object_save, true):
			print("BEGIN expected decoder diagnostic: full objects are forbidden")
			safe = _reject(game, null, "object-bearing file", false, true)
			print("END expected decoder diagnostic")
		else:
			safe = false
	if safe:
		var broken := FileAccess.open(SaveGame.slot_path(_slot), FileAccess.WRITE)
		if broken == null:
			_check(false, "open invalid compressed-file fixture")
			safe = false
		else:
			broken.store_buffer(PackedByteArray([0, 1, 2, 3, 4, 5, 6, 7]))
			broken.close()
			print("BEGIN expected decoder diagnostic: invalid compressed bytes")
			safe = _reject(game, null, "corrupt compressed bytes", false, true)
			print("END expected decoder diagnostic")
	if safe:
		DirAccess.remove_absolute(SaveGame.slot_path(_slot))
		safe = _reject(game, null, "missing save file", false, true)
	for entry in cases:
		if not safe:
			break
		safe = _reject(game, _replace(base, entry[1], entry[2]), entry[0])
	if safe:
		var missing := base.duplicate(true)
		missing.buildings[0].erase("position")
		safe = _reject(game, missing, "missing required building position", true)
	if safe:
		game._on_build_requested("house")
		safe = _reject(game, {"version": SaveGame.VERSION}, "rejection during placement", true)
	if safe:
		game._toggle_clear_tool()
		safe = _reject(game, {"version": SaveGame.VERSION}, "rejection during ground clearing")
	if safe:
		game._exit_clear_tool()
		_valid_round_trips(game, base)
		_military_round_trips(game)
	DirAccess.remove_absolute(SaveGame.slot_path(_slot))
	game.free()
	print("Save validation: %d rejected fixtures; %d failures" % [_rejections, _failures])
	quit(1 if _failures else 0)


func _valid_round_trips(game: Node, base: Dictionary) -> void:
	game._road_extent_at = game.sim.keep.global_position
	game._road_extent = 1234
	_check(_write_fixture(base) and game.load_game(_slot) == "", "valid captured save loads")
	_check(game._road_extent_at == Vector3.INF and game._road_extent == 0,
			"successful load discards the previous world's cached road extent")
	_check(game.clock.paused(), "valid paused save stays paused")
	game.clock.toggle_pause()
	_check(is_equal_approx(game.clock.scale(), 4.0), "valid save restores resume speed")
	game.clock.toggle_pause()
	var legacy_rate := base.duplicate(true)
	legacy_rate.erase("speed_layout")
	legacy_rate["speed_index"] = 6
	legacy_rate["resume_speed_index"] = 6
	_check(_write_fixture(legacy_rate) and game.load_game(_slot) == ""
			and game.clock.scale() == 16.0, "real legacy save keeps 16x instead of becoming 64x")
	legacy_rate["speed_index"] = 0
	legacy_rate["resume_speed_index"] = 5
	_check(_write_fixture(legacy_rate) and game.load_game(_slot) == "" and game.clock.paused(),
			"real legacy paused save remains paused")
	game.clock.toggle_pause()
	_check(game.clock.scale() == 4.0, "real legacy paused save resumes at its old 4x rate")
	var legacy := base.duplicate(true)
	for key in ["resume_speed_index", "speed_layout", "day_marker", "research", "campaign", "scouting", "water"]:
		legacy.erase(key)
	legacy.nodes.erase("marked")
	for b in legacy.buildings:
		for key in ["larder", "crop_growth", "plots", "build_cost", "build_seconds",
				"market_stock_target", "health", "fire"]:
			b.erase(key)
	for c in legacy.citizens:
		for key in ["immigrant", "immigrant_target", "hunger", "next_meal", "meals_taken", "morale",
				"hydration", "water_bucket", "water_sickness", "service_health"]:
			c.erase(key)
	_check(SaveGame.validate(legacy, game.registry) == "", "legacy optional fields validate")
	_check(_write_fixture(legacy) and game.load_game(_slot) == "", "legacy optional fields load")
	game.clock.toggle_pause()
	_check(game.clock.speed_index == Config.NORMAL_SPEED, "legacy resume speed defaults to normal")
	_check(game.sim.research.completed.is_empty() and game.sim.research.active == "",
			"legacy saves begin with no completed or active research")
	_check(game.sim.keep.health == game.sim.keep.max_health() and game.sim.keep.fire == 0.0,
			"legacy buildings default to undamaged and unlit")
	game.clock.toggle_pause()
	var sim: Simulation = game.sim
	var entrant := sim.add_citizen(Vector3(6, 0, Config.WORLD_SIZE * 0.5), true)
	entrant.immigrant_target = sim.keep.global_position + Vector3(8, 0, 3)
	var entrant_id := entrant.id
	var target := entrant.immigrant_target
	var travelling := SaveGame.capture(game)
	_check(SaveGame.validate(travelling, game.registry) == "", "travelling immigrant validates")
	_check(_write_fixture(travelling) and game.load_game(_slot) == "", "travelling immigrant loads")
	entrant = game.sim.citizens_by_id.get(entrant_id)
	_check(entrant != null and entrant.immigrant and entrant.home_id == -1
			and entrant.workplace_id == -1 and entrant.has_goal()
			and entrant.immigrant_target == target,
			"loaded immigrant keeps destination without premature housing or work")
	# Older spawning scattered settlers across the map corners. These saves
	# need to remain readable even when the entrant is a few metres outside.
	travelling.citizens[-1].position = Vector3(-3, 0, Config.WORLD_SIZE + 4)
	_check(SaveGame.validate(travelling, game.registry) == "",
			"legacy immigrant slightly outside a map corner validates")
	_check(_write_fixture(travelling) and game.load_game(_slot) == "",
			"legacy immigrant slightly outside a map corner loads")
	entrant = game.sim.citizens_by_id.get(entrant_id)
	_check(entrant != null and entrant.immigrant and entrant.home_id == -1
			and entrant.workplace_id == -1 and entrant.position.x == -3.0
			and entrant.position.z == Config.WORLD_SIZE + 4.0,
			"legacy off-map arrival keeps its saved position and immigration state")
	_upgrade_round_trip(game)


func _clock_menu_migration() -> void:
	var clock := Clock.new()
	var old_rates := [0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 16.0]
	for index in range(1, old_rates.size()):
		clock.restore_saved_speed({"speed_index": index})
		_check(clock.scale() == maxf(1.0, old_rates[index]),
				"legacy speed index %d migrates to its intended rate" % index)
		clock.restore_saved_speed({"speed_index": 0, "resume_speed_index": index})
		_check(clock.paused(), "legacy resume index %d does not unpause a save" % index)
		clock.toggle_pause()
		_check(clock.scale() == maxf(1.0, old_rates[index]),
				"legacy paused index %d resumes at its intended rate" % index)
	for index in range(1, Config.SPEEDS.size()):
		clock.restore_saved_speed({"speed_layout": 2, "speed_index": index,
			"resume_speed_index": index})
		_check(clock.scale() == Config.SPEEDS[index], "current speed menu preserves index %d" % index)
		clock.toggle_pause()
		clock.toggle_pause()
		_check(clock.scale() == Config.SPEEDS[index], "current speed %s survives pause" % Config.SPEEDS[index])


func _upgrade_round_trip(game: Node) -> void:
	var sim: Simulation = game.sim
	_check(sim.research.restore({"completed": ["civic_building", "metallurgy"],
		"active": "", "remaining_days": 0.0}) == "",
			"upgrade persistence fixture explicitly knows its required research")
	for res in Config.RES_COUNT:
		sim.keep.inventory[res] = 500.0
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var location := Vector3.INF
	for radius in [80.0, 120.0, 160.0]:
		for i in 24:
			var angle := TAU * float(i) / 24.0
			var at: Vector3 = sim.keep.global_position + Vector3(cos(angle), 0, sin(angle)) * radius
			if sim.can_place("forge", at, 0.0)["ok"]:
				location = at
				break
		if location != Vector3.INF:
			break
	_check(location != Vector3.INF, "upgrade fixture has room for its larger footprint")
	if location == Vector3.INF:
		return
	var smith := sim.place_building("blacksmith", location, 0.0, true)
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	var smith_id := smith.id
	var cost := smith.def.upgrade_cost.duplicate()
	var seconds := smith.def.upgrade_time
	var result := sim.upgrade(smith)
	_check(result["ok"], "staffed workshop starts upgrade: %s" % result["reason"])
	if not result["ok"]:
		return
	_check(not smith.workers.is_empty(), "upgrade capture includes retained workers before reassignment")
	for res in cost:
		smith.deliver_material(res, float(cost[res]) * 0.5)
	var deliveries := smith.delivered.duplicate()
	var upgrading := SaveGame.capture(game)
	_check(SaveGame.validate(upgrading, game.registry) == "", "staffed upgrade in progress validates")
	_check(_write_fixture(upgrading) and game.load_game(_slot) == "", "upgrade in progress loads")
	smith = game.sim.buildings_by_id.get(smith_id)
	_check(smith != null and smith.type_id == "forge" and smith.under_construction
			and smith.build_progress == 0.0 and smith.build_cost == cost
			and smith.build_seconds == seconds and smith.delivered == deliveries,
			"loaded upgrade retains its unpaid cost, duration, and delivered materials")


## Cross-record campaign checks need the real player building table and the
## saved world's bounds. Exercise disk writes and staged replacement, not only
## the campaign's standalone schema validator.
func _military_round_trips(game: Node) -> void:
	var campaign: FrontierCampaign = game.sim.campaign
	var attacker: Soldier
	for unit in campaign.units.values():
		if unit.faction == 1:
			attacker = unit
			break
	_check(attacker != null, "enemy attack save fixture has a rival soldier")
	if attacker == null:
		return
	campaign.at_war = true
	attacker.target_kind = "building"
	attacker.target_id = game.sim.keep.id
	campaign._impacts.append({"wait": 0.5, "id": game.sim.keep.id, "faction": 1})
	var attacker_id := attacker.id
	var keep_id: int = game.sim.keep.id
	var snapshot := SaveGame.capture(game)
	var error: String = game.save_game(_slot)
	_check(error == "", "save accepts an enemy targeting the keep with a projectile in flight: " + error)
	if error == "":
		error = game.load_game(_slot)
		_check(error == "", "enemy attack and in-flight projectile survive staged loading: " + error)
		if error == "":
			campaign = game.sim.campaign
			attacker = campaign.units.get(attacker_id)
			_check(attacker != null and attacker.target_kind == "building"
					and attacker.target_id == keep_id and campaign._impacts == snapshot.campaign.impacts,
					"restored enemy retains its actual player-building target and pending shot")
	var broken := snapshot.duplicate(true)
	for unit in broken.campaign.units:
		if unit.id == attacker_id:
			unit.target_id = snapshot.next_building_id + 100
	_check(SaveGame.validate(broken, game.registry) != "",
			"enemy targets still reject missing player buildings after the schema precheck")
	broken = snapshot.duplicate(true)
	broken.campaign.impacts[0].id = snapshot.next_building_id + 100
	_check(SaveGame.validate(broken, game.registry) != "",
			"pending enemy projectiles still reject missing player buildings")

	error = game.new_world(20260911, 1536)
	_check(error == "", "military save fixture starts a Medium world: " + error)
	if error != "":
		return
	var sim: Simulation = game.sim
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	var barracks := sim.place_building("barracks", game.world.centre() + Vector3(-45, 0, -15), 0, true)
	_check(barracks != null, "Medium fixture has a completed barracks")
	if barracks == null:
		return
	sim.keep.inventory[Config.Res.FOOD] = 150.0
	sim.keep.inventory[Config.Res.TOOLS] = 50.0
	var citizen_id: int = sim.citizens[0].id
	error = sim.campaign.recruit(citizen_id)
	_check(error == "", "an existing Medium-world resident enters military service: " + error)
	if error != "":
		return
	var unit_id: int = sim.campaign.friendly_ids()[0]
	var serving: Soldier = sim.campaign.units[unit_id]
	serving.position = Vector3(900, game.world.surface_height_at(900, 760), 760)
	var position := serving.position
	error = game.save_game(_slot)
	_check(error == "", "a serving citizen beyond legacy768m bounds can be saved: " + error)
	if error != "":
		return
	error = game.load_game(_slot)
	_check(error == "", "a Medium-world serving citizen beyond768m loads: " + error)
	if error == "":
		serving = game.sim.campaign.units.get(unit_id)
		_check(game.world.size_m == 1536 and serving != null and serving.position == position
				and game.sim.campaign._civilian_ids[unit_id] == citizen_id
				and game.sim.citizens.size() == Config.START_CITIZENS - 1,
				"large-bound military load preserves the world, position and single civilian identity")
