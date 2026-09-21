extends SceneTree

## Run with tools/godot_env.sh --headless --path game --script res://tests/save_fingerprint.gd
## Negative controls must catch losses that the old rounded/aggregate snapshot
## accepted, and a real disk round trip must preserve a nontrivial fixture.

var _failures := 0
var _harness: Node
var _game: Node


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", description])
	if not ok:
		_failures += 1


func _detects(before: Dictionary, path: String, description: String) -> void:
	var drift: Array[String] = _harness._state_drift("", before,
			_harness._fingerprint())
	var found := false
	for line in drift:
		if line.begins_with(path):
			found = true
	_check(found, description)
	if not found:
		print("  expected %s; drift: %s" % [path, drift])


func _check_fingerprint(before: Dictionary, description: String) -> void:
	var drift: Array[String] = _harness._state_drift("", before,
			_harness._fingerprint())
	_check(drift.is_empty(), description)
	for line in drift:
		print("  " + line)


func _write_snapshot(slot: String, data: Dictionary) -> bool:
	var file := FileAccess.open_compressed(SaveGame.slot_path(slot),
			FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	_check(file != null, "opens reordered save fixture")
	if file == null:
		return false
	var stored := file.store_var(data, false)
	file.close()
	_check(stored, "writes reordered save fixture")
	return stored


func _run() -> void:
	_game = load("res://main.tscn").instantiate()
	root.add_child(_game)
	_game.process_mode = Node.PROCESS_MODE_DISABLED
	_harness = load("res://scripts/core/harness.gd").new()
	_harness.game = _game
	var sim: Simulation = _game.sim
	_check(sim.research.restore({"completed": ["civic_building"],
		"active": "roadworks", "remaining_days": 1.125}) == "",
			"persistence fixture explicitly includes completed and paid research in progress")
	for res in Config.RES_COUNT:
		sim.keep.inventory[res] = 200.125
	_harness._do_build({"type": "granary", "offset": [40, 35],
			"radius": 40, "instant": true})
	var warehouse: Building = sim.buildings_by_id.get(_harness._last_building_id)
	_harness._do_build({"type": "farm", "offset": [-15, 55],
			"radius": 40, "instant": true})
	var farm: Building = sim.buildings_by_id.get(_harness._last_building_id)
	_check(warehouse != null and farm != null, "fixture has a granary and farm")
	if warehouse == null or farm == null:
		_finish()
		return
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var upgrade: Dictionary = sim.upgrade(warehouse)
	_check(upgrade["ok"], "fixture includes an unfinished warehouse upgrade")
	if not upgrade["ok"]:
		print("  " + upgrade["reason"])
		_finish()
		return
	warehouse.build_progress = 0.125
	warehouse.delivered[Config.Res.TIMBER] = 0.375
	farm.crop_growth = 0.375
	farm.health = 175.125
	farm.fire = 0.125
	# Each amount is below the Float32 cache's rounding precision next to the
	# keep's stock; summing the two first crosses that precision boundary.
	farm.inventory[Config.Res.FOOD] = 0.000004
	warehouse.inventory[Config.Res.FOOD] = 0.000004
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	farm.sync_fields_to_workers()
	var homes: Array[Building] = []
	for b in sim.buildings:
		if b.type_id == "house":
			homes.append(b)
	homes[0].larder = 0.125
	homes[1].larder = 0.375
	var citizen: Citizen = sim.citizens[0]
	citizen.hunger = 0.375
	citizen.next_meal = 1.875
	citizen.meals_taken = 3
	citizen.morale = 0.625
	citizen.pick_up(Config.Res.TIMBER, 3.125, _game.registry)
	# Even a positive load below the simulation's delivery threshold belongs
	# to its carrier and must survive persistence without being discarded.
	sim.citizens[1].pick_up(Config.Res.STONE, 0.005, _game.registry)
	var immigrant := sim.add_citizen(Vector3(10, 0, 10), true)
	immigrant.immigrant_target = sim.keep.position + Vector3(2, 0, 2)
	var tree: ResourceNodes.NodeRec = _game.world.nodes.find_nearest(
			ResourceNodes.Kind.TREE, sim.keep.position, 200.0)
	_check(tree != null, "fixture has a partly harvested resource")
	if tree == null:
		_finish()
		return
	_game.world.nodes.harvest(tree, 0.125, sim.day)
	_game.world.wear.wear[0] = 1.25
	_game.world.wear.wear[1] = 2.5
	# Later earthworks can change the terrain under existing objects without
	# moving them. Loading must keep their recorded elevation and plot layout.
	_game.world.heightmap.flatten(homes[0].position + Vector3(5, 0, 0), 10, 10)
	var plots := farm.all_plots()
	_check(not plots.is_empty(), "fixture has persisted field plots")
	if not plots.is_empty():
		_game.world.heightmap.flatten(plots[0] + Vector3(3, 0, 0), 4, 4)
	_game.clock.set_rate(4.0)
	_game.clock.toggle_pause()
	_check(_game.save_game("regression_fingerprint") == "", "fixture saves to disk")
	var before: Dictionary = _harness._fingerprint()
	_check(_harness._state_drift("", before, _harness._fingerprint()).is_empty(),
			"unchanged live state compares equal")
	sim.stores.unregister(sim.keep)
	sim.stores.register(sim.keep)
	_check_fingerprint(before, "storage registration order does not change the fingerprint totals")

	# The original fingerprint rounded both local and global inventory totals.
	var amount := sim.keep.inventory[Config.Res.FOOD]
	sim.keep.inventory[Config.Res.FOOD] -= 0.125
	_detects(before, "buildings.%d.inventory" % sim.keep.id,
			"detects fractional inventory loss below rounding precision")
	sim.keep.inventory[Config.Res.FOOD] = amount
	var carrying := citizen.carrying_amount
	citizen.carrying_amount -= 0.125
	_detects(before, "people.%d.carrying_amount" % citizen.id,
			"detects fractional loss from a carried load")
	citizen.carrying_amount = carrying
	var arrival := immigrant.immigrant_target
	immigrant.immigrant_target += Vector3(1, 0, 0)
	_detects(before, "people.%d.immigrant_target" % immigrant.id,
			"detects a changed immigrant arrival destination")
	immigrant.immigrant_target = arrival

	# Keep the total household food unchanged while putting it in the wrong home.
	homes[0].larder += 0.125
	homes[1].larder -= 0.125
	_detects(before, "buildings.%d.larder" % homes[0].id,
			"detects food moved between larders with unchanged kingdom totals")
	homes[0].larder -= 0.125
	homes[1].larder += 0.125
	for property in ["hunger", "next_meal", "meals_taken", "morale"]:
		var original: Variant = citizen.get(property)
		citizen.set(property, 0 if property == "meals_taken" else 0.0)
		_detects(before, "people.%d.%s" % [citizen.id, property],
				"detects an omitted citizen %s value" % property)
		citizen.set(property, original)

	warehouse.delivered[Config.Res.TIMBER] = 0.0
	_detects(before, "buildings.%d.delivered" % warehouse.id,
			"detects omitted construction deliveries")
	warehouse.delivered[Config.Res.TIMBER] = 0.375
	var cost: Dictionary = warehouse.build_cost.duplicate()
	warehouse.build_cost.clear()
	_detects(before, "buildings.%d.build_cost" % warehouse.id,
			"detects omitted upgrade costs")
	warehouse.build_cost = cost
	var seconds := warehouse.build_seconds
	warehouse.build_seconds += 0.125
	_detects(before, "buildings.%d.build_seconds" % warehouse.id,
			"detects changed upgrade duration")
	warehouse.build_seconds = seconds
	warehouse.build_progress += 0.000125
	_detects(before, "buildings.%d.build_progress" % warehouse.id,
			"detects construction progress below old display precision")
	warehouse.build_progress = 0.125
	farm.crop_growth = 0.0
	_detects(before, "buildings.%d.crop_growth" % farm.id,
			"detects lost crop growth")
	farm.crop_growth = 0.375
	for property in ["health", "fire", "market_stock_target"]:
		var original: Variant = farm.get(property)
		farm.set(property, 40 if property == "market_stock_target" else 0.0)
		_detects(before, "buildings.%d.%s" % [farm.id, property],
				"detects lost building %s" % property)
		farm.set(property, original)
	var remaining := sim.research.remaining_days
	sim.research.remaining_days -= 0.125
	_detects(before, "research.remaining_days", "detects changed paid research progress")
	sim.research.remaining_days = remaining
	var completed := sim.research.completed.duplicate()
	sim.research.completed.clear()
	_detects(before, "research.completed", "detects lost completed technology")
	sim.research.completed.assign(completed)
	var discovered := sim.research.ranching_known
	sim.research.ranching_known = not discovered
	_detects(before, "research.ranching_known", "detects lost domestication knowledge")
	sim.research.ranching_known = discovered
	var cow: Cattle = sim.husbandry.cows.values()[0]
	var cow_age := cow.age_days
	cow.age_days += 0.5
	_detects(before, "husbandry.cows.%d.age_days" % cow.id, "detects changed cattle age independently of the save writer")
	cow.age_days = cow_age
	var marked := cow.marked
	cow.marked = not marked
	_detects(before, "husbandry.cows.%d.marked" % cow.id, "detects lost domestication orders")
	cow.marked = marked
	var campaign: Node = sim.campaign
	if campaign != null and not campaign.units.is_empty():
		var unit: Node = campaign.units.values()[0]
		var rations: float = unit.rations
		unit.rations -= 0.125
		_detects(before, "campaign.units.%d.rations" % unit.id,
				"detects lost soldier rations")
		unit.rations = rations
		var body: Dictionary = unit._body_state.duplicate(true)
		unit._body_state.parts.arm_r.bruise += 0.5
		_detects(before, "campaign.units.%d.body.parts.arm_r.bruise" % unit.id,
				"detects changed localized injury independently of body serialization")
		unit._body_state = body
		var town: String = campaign.rival_name
		campaign.rival_name = "Changed settlement"
		_detects(before, "campaign.rival_name", "detects changed rival settlement identity")
		campaign.rival_name = town
	if not plots.is_empty():
		var original_plot := plots[0]
		plots[0] += Vector3(0.125, 0, 0)
		_detects(before, "buildings.%d.plots[0]" % farm.id,
				"detects moved field plots without changing field count")
		plots[0] = original_plot
	if not farm.workers.is_empty():
		var worker: int = farm.workers[0]
		farm.workers[0] = immigrant.id
		_detects(before, "buildings.%d.workers" % farm.id,
				"detects a changed worker roster with unchanged staffing count")
		farm.workers[0] = worker
	var cart_position: Vector3 = sim.cart.position
	sim.cart.position.y += 0.125
	_detects(before, "cart_position", "detects lost cart elevation")
	sim.cart.position = cart_position

	# A shallow snapshot aliases the live dictionaries and would miss this edit.
	var edit: Dictionary = _game.world.heightmap.edits[0]
	var original_extent: float = edit["half_w"]
	edit["half_w"] = original_extent + 0.125
	_detects(before, "terrain_edits[0].half_w",
			"detects changed terrain contents without changing edit count")
	edit["half_w"] = original_extent
	var node_amount := tree.amount
	tree.amount -= 0.125
	_detects(before, "nodes.%d.amount" % tree.id,
			"detects resource loss with unchanged standing-tree count")
	tree.amount = node_amount
	_game.world.wear.wear[0] = 2.5
	_game.world.wear.wear[1] = 1.25
	_detects(before, "wear[0]", "detects moved wear with unchanged wear sum")
	_game.world.wear.wear[0] = 1.25
	_game.world.wear.wear[1] = 2.5
	_game.clock.restore_speed(0, Config.NORMAL_SPEED)
	_detects(before, "resume_speed_index", "detects a lost paused resume speed")
	_game.clock.set_rate(4.0)
	_game.clock.toggle_pause()

	_check(_harness._state_drift("", {"a": 1, "b": {"c": 2}},
			{"b": {"c": 2}, "a": 1}).is_empty(),
			"dictionary insertion order is irrelevant")
	_check(not _harness._state_drift("", {"a": 1},
			{"a": 1, "extra": 2}).is_empty(), "extra state is detected")
	_check(_harness._state_drift("position", Vector3.ONE,
			Vector3.ONE + Vector3(0.00001, 0, 0)).is_empty(),
			"allows spatial floating-point reconstruction noise")
	_check(not _harness._state_drift("amount", 1.0, 1.00001).is_empty(),
			"spatial tolerance never rounds away resource quantities")
	_check(not _harness._state_drift("position", Vector3.ONE,
			Vector3.ONE + Vector3(0.01, 0, 0)).is_empty(),
			"spatial comparison detects a real moved position")

	# Exercise the actual binary file, capture and restoration paths. This
	# proves the independent fingerprint accepts valid persisted game state.
	var farm_id := farm.id
	_check(_game.load_game("regression_fingerprint") == "", "fixture loads from disk")
	_check_fingerprint(before, "real save/load preserves the detailed fixture")
	DirAccess.remove_absolute(SaveGame.slot_path("regression_fingerprint"))

	# Record order is not identity. Restoring a high ID first must not inflate
	# counters once for each later (lower) forced ID.
	var reordered := SaveGame.capture(_game)
	reordered["buildings"].reverse()
	reordered["citizens"].reverse()
	if _write_snapshot("regression_fingerprint_reordered", reordered):
		_check(_game.load_game("regression_fingerprint_reordered") == "",
				"loads valid reordered building and citizen records")
		_check_fingerprint(before,
				"record order preserves contents, assignments and next ID counters")
	DirAccess.remove_absolute(SaveGame.slot_path("regression_fingerprint_reordered"))

	# An explicitly empty layout is saved state. Only older records with the
	# plots field absent should generate a layout when restored.
	farm = _game.sim.buildings_by_id[farm_id]
	farm.adopt_plots([], _game.world.heightmap, _game.world.nav, _game.registry)
	_check(farm.all_plots().is_empty() and farm.field_count() == 0,
			"adopting an empty farm layout removes active fields")
	before = _harness._fingerprint()
	_check(_game.save_game("regression_fingerprint_empty_plots") == "",
			"saves a staffed farm with explicitly empty plots")
	_check(_game.load_game("regression_fingerprint_empty_plots") == "",
			"loads a staffed farm with explicitly empty plots")
	_check_fingerprint(before, "explicitly empty plots survive a real save/load")
	DirAccess.remove_absolute(SaveGame.slot_path("regression_fingerprint_empty_plots"))
	var legacy := SaveGame.capture(_game)
	for building in legacy["buildings"]:
		if building["id"] == farm_id:
			building.erase("plots")
	_check(_game.restore_from(legacy) == "", "loads a legacy farm without a plots field")
	farm = _game.sim.buildings_by_id[farm_id]
	_check(not farm.all_plots().is_empty(), "legacy farms still generate missing layouts")
	_finish()


func _finish() -> void:
	_harness.free()
	_game.free()
	print("Save fingerprint regression failures: %d" % _failures)
	quit(1 if _failures else 0)
