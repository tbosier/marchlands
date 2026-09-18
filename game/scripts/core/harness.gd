extends Node

## Scriptable automation for the running game.
##
## The pipeline drives real play sessions — place a logging camp, run the
## simulation for a few in-game days, photograph the result — so that changes
## can be verified against what actually happens rather than against what the
## code was supposed to do. Every screenshot in the project's documentation is
## produced this way.
##
## Usage:
##     godot --path game -- --harness=tools/scenes/first_road.json
##
## A script is a JSON array of steps:
##     {"op": "camera",     "at": [x, z], "distance": 80, "yaw": 0.7}
##     {"op": "focus_keep", "distance": 90}
##     {"op": "build",      "type": "logging_camp", "near": "trees",
##                          "radius": 120, "instant": true}
##     {"op": "speed",      "rate": 4}
##     {"op": "run",        "days": 2.5}
##     {"op": "shot",       "name": "after_two_days"}
##     {"op": "assert",     "check": "wear_above", "value": 500}
##     {"op": "upgrade_building", "type": "granary"}
##     {"op": "strand_load", "res": 1, "amount": 8}
##     {"op": "watch",      "check": "loads_are_accounted_for"}
##     {"op": "save",       "slot": "harness"}
##     {"op": "load",       "slot": "harness"}
##     {"op": "upgrade_route", "at": "busiest"}
##     {"op": "report"}
##     {"op": "quit"}

var game
var _steps: Array = []
var _index := 0
var _run_remaining := 0.0
var _out_dir := "res://../artifacts"
var _failures: Array[String] = []
var _log: Array[String] = []
var _settled := 0
## Set while an async step (a screenshot) is mid-flight. Without it the step
## loop charges on through the next ops while the capture is still awaiting a
## frame, and photographs a world that has already moved on — which cost real
## time chasing a selection panel that was being cleared a step early.
var _busy := false
## A snapshot of the settlement taken by the "save" op, compared against the
## live one by the save_round_trip assertion after a "load".
var _save_fingerprint: Dictionary = {}
## Invariants checked on every simulation step rather than sampled after one.
var _watches: Array[String] = []
var _watch_steps := 0
var _felling_target := Vector3.ZERO
var _felling_marked := 0
var _felling_timber_before := 0.0
var _felling_expected := 0.0


func run(game_node, script_path: String) -> void:
	game = game_node
	var text := ""
	var abs_path := script_path
	if not abs_path.begins_with("res://") and not abs_path.begins_with("/"):
		abs_path = "res://../" + abs_path
	if FileAccess.file_exists(abs_path):
		text = FileAccess.get_file_as_string(abs_path)
	else:
		push_error("harness: cannot read %s" % abs_path)
		get_tree().quit(2)
		return

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		push_error("harness: %s is not a JSON array" % abs_path)
		get_tree().quit(2)
		return
	_steps = parsed
	DirAccess.make_dir_recursive_absolute(_out_dir)

	_note("harness: %d steps from %s" % [_steps.size(), script_path])


func _process(delta: float) -> void:
	if game == null:
		return
	# Let the world settle for a few frames before touching anything.
	if _settled < 4:
		_settled += 1
		return

	# A screenshot is mid-flight; let it finish before touching the world.
	if _busy:
		return

	if _run_remaining > 0.0:
		# The clock is already advancing in the game's own _process; we just
		# wait for the requested span of in-game time to elapse.
		_run_remaining -= delta * game.clock.scale()
		if _run_remaining > 0.0:
			return

	while _index < _steps.size():
		var step: Dictionary = _steps[_index]
		_index += 1
		var done := _execute(step)
		if not done:
			return
	_finish()


## Returns false when the step needs time to pass before continuing.
func _execute(step: Dictionary) -> bool:
	match String(step.get("op", "")):
		"camera":
			var at: Array = step.get("at", [0, 0])
			var p := Vector3(at[0], 0, at[1])
			p.y = game.world.heightmap.height_at(p.x, p.z)
			if step.has("yaw"):
				game.camera.yaw = float(step["yaw"])
			game.camera.look_at_position(p, float(step.get("distance", 90.0)))
		"focus_keep":
			var k = game.sim.keep
			if k:
				if step.has("yaw"):
					game.camera.yaw = float(step["yaw"])
				game.camera.look_at_position(k.global_position,
						float(step.get("distance", 90.0)))
		"build":
			_do_build(step)
		"speed":
			if step.has("rate"):
				game.clock.set_rate(float(step["rate"]))
			else:
				game.clock.set_speed(int(step.get("index", 1)))
		"populate":
			_do_populate(int(step.get("count", 50)))
		"open_build_tray":
			game.hud.set_tray_open(true)
		"cancel_site":
			_do_cancel_site(String(step.get("type", "house")))
		"upgrade_building":
			_do_upgrade_building(String(step.get("type", "granary")))
		"strand_load":
			_do_strand_load(step)
		"watch":
			var check := String(step.get("check", ""))
			if not _watches.has(check):
				_watches.append(check)
			_watch_steps = 0
			_note("watching %s on every simulation step" % check)
		"unwatch":
			_watches.clear()
		"clear_trees":
			_do_clear_trees(step)
		"stamp_wear":
			_do_stamp_wear(step)
		"select_building":
			_do_select_building(String(step.get("type", "keep")))
		"pick_test":
			_do_pick_test()
		"raycast_test":
			_do_raycast_test()
		"dev":
			game.dev_mode = bool(step.get("on", true))
			game.dev.visible = game.dev_mode
		"run":
			_run_remaining = float(step.get("days", 1.0)) * Config.DAY_LENGTH
			return false
		"advance_to":
			_do_advance_to(float(step.get("time", 0.45)))
		"simulate":
			_do_simulate(float(step.get("days", 1.0)))
		"shot":
			_busy = true
			_shot(String(step.get("name", "frame")))
			return false
		"upgrade_route":
			_do_upgrade(step)
		"assert":
			_do_assert(step)
		"note":
			_note(String(step.get("text", "")))
		"inspect":
			_do_inspect(String(step.get("type", "blacksmith")))
		"save":
			_do_save(String(step.get("slot", SaveGame.QUICK_SLOT)))
		"load":
			_do_load(String(step.get("slot", SaveGame.QUICK_SLOT)))
		"report":
			_report()
		"perf":
			_perf_report()
		"quit":
			_finish()
			return false
		_:
			# A typo in an op name used to be silently ignored, so a scenario
			# could lose its assertion and still report ALL CHECKS PASSED. A
			# check that cannot fail is worse than no check at all.
			_fail("unknown harness op '%s'" % String(step.get("op", "")))
	return true


func _do_build(step: Dictionary) -> void:
	var type_id := String(step.get("type", "house"))
	var position := _resolve_position(step)
	if position == Vector3.INF:
		_fail("build %s: no valid position found" % type_id)
		return
	var check: Dictionary = game.sim.can_place(type_id, position,
			float(step.get("yaw", PI)))
	if not check["ok"]:
		_fail("build %s at %v rejected: %s"
				% [type_id, position, check["reason"]])
		return
	# "pay" applies the same affordability gate the player's click does, so the
	# scripted scenarios test the real flow rather than a shortcut.
	if bool(step.get("pay", false)):
		var cost: Dictionary = BuildingDefs.get_def(type_id).cost
		if not game.sim.can_afford(cost):
			_fail("build %s: cannot afford %s"
					% [type_id, BuildingDefs.cost_text(type_id)])
			return

	var instant := bool(step.get("instant", false))
	var b = game.sim.place_building(type_id, position,
			float(step.get("yaw", PI)), instant)
	_note("%s %s at (%.0f, %.0f)"
			% ["built" if instant else "sited", type_id, position.x, position.z])


## Raise the population to `count` so the per-tick systems can be measured
## under a load the opening scenario never reaches.
func _do_populate(count: int) -> void:
	var origin: Vector3 = game.sim.keep.global_position
	var added := 0
	while game.sim.citizens.size() < count:
		var a := randf() * TAU
		var r := randf_range(8.0, 60.0)
		game.sim.add_citizen(origin + Vector3(cos(a) * r, 0, sin(a) * r))
		added += 1
		if added > 4000:
			break
	_note("populated to %d citizens" % game.sim.citizens.size())


## Find somewhere sensible to build, the way a player would: near a resource,
## at an offset from the keep, or at explicit coordinates.
func _resolve_position(step: Dictionary) -> Vector3:
	var type_id := String(step.get("type", "house"))
	if step.has("at"):
		var at: Array = step["at"]
		var p := Vector3(at[0], 0, at[1])
		p.y = game.world.heightmap.height_at(p.x, p.z)
		return p

	var origin: Vector3 = game.sim.keep.global_position
	if step.has("offset"):
		var off: Array = step["offset"]
		origin += Vector3(off[0], 0, off[1])

	var radius := float(step.get("radius", 140.0))
	var near := String(step.get("near", ""))
	var anchor := origin

	if near == "trees" or near == "stone" or near == "iron":
		var kind := ResourceNodes.Kind.TREE
		if near == "stone":
			kind = ResourceNodes.Kind.STONE
		elif near == "iron":
			kind = ResourceNodes.Kind.IRON
		var node = game.world.nodes.find_nearest(kind, origin, radius, false)
		if node == null:
			return Vector3.INF
		anchor = node.position

	# Spiral outward from the anchor until placement validates. Prefer sites
	# that are close to the anchor but not on top of it.
	for ring in range(1, 16):
		var r := 6.0 + ring * 5.0
		for a in 16:
			var ang := TAU * a / 16.0 + ring * 0.31
			var p := anchor + Vector3(cos(ang) * r, 0, sin(ang) * r)
			if p.x < 10 or p.z < 10 or p.x > Config.WORLD_SIZE - 10 \
					or p.z > Config.WORLD_SIZE - 10:
				continue
			p.y = game.world.heightmap.height_at(p.x, p.z)
			var check: Dictionary = game.sim.can_place(type_id, p)
			if check["ok"]:
				return p
	return Vector3.INF


## Advance the simulation synchronously, as fast as the processor allows.
##
## `run` waits for real time to pass, which ties a sixty-day test to ten
## minutes of wall clock. This steps the same code path in a tight loop
## instead, so long-horizon behaviour — routes growing back over, crops
## cycling, a settlement filling up — can actually be asserted on in CI.
## It skips rendering, so any screenshot wants `run` instead.
func _do_simulate(days: float) -> void:
	var target: float = days * Config.DAY_LENGTH
	var elapsed := 0.0
	var step: float = Config.MAX_SIM_STEP
	var started := Time.get_ticks_msec()
	while elapsed < target:
		game.sim.tick(step)
		game.clock.elapsed_days += step / Config.DAY_LENGTH
		elapsed += step
		if not _watches.is_empty():
			_watch_steps += 1
			_run_watches()
	_note("simulated %.1f days in %.1f s of wall clock"
			% [days, (Time.get_ticks_msec() - started) / 1000.0])


## Run on until the march reaches a given time of day, given as a fraction.
##
## The settlement sleeps now, so whether anybody is working depends on the hour
## as well as on the state of the world. An assertion about work placed after a
## fixed number of days lands wherever the arithmetic happens to put it — which
## is how `work_in_progress` came to be sampled at two in the morning and fail
## with the entirely correct answer that everyone was in bed.
func _do_advance_to(target: float) -> void:
	var want: float = fposmod(target, 1.0)
	var step: float = Config.MAX_SIM_STEP
	var guard := 0
	# A whole day of steps plus a margin: enough to reach any hour from any
	# other, and a hard stop rather than a possible infinite loop.
	var limit: int = int(ceil(Config.DAY_LENGTH / step)) + 8
	while guard < limit:
		var now: float = fposmod(game.sim.day, 1.0)
		if absf(now - want) < step / Config.DAY_LENGTH:
			break
		game.sim.tick(step)
		game.clock.elapsed_days += step / Config.DAY_LENGTH
		guard += 1
		if not _watches.is_empty():
			_watch_steps += 1
			_run_watches()
	_note("advanced to %02d:%02d" % [int(fposmod(game.sim.day, 1.0) * 24.0),
			int(fposmod(fposmod(game.sim.day, 1.0) * 24.0, 1.0) * 60.0)])


## Place a blueprint, let some materials arrive, then call it off and check the
## goods came back. This is the stuck-state a player hits by committing all
## their timber to a site they cannot finish.
func _do_cancel_site(type_id: String) -> void:
	var before: float = game.sim.total_resource(Config.Res.TIMBER)
	var target: Building = null
	for b in game.sim.buildings:
		if b.type_id == type_id and b.under_construction:
			target = b
			break
	if target == null:
		_fail("cancel_site: no %s under construction" % type_id)
		return
	var on_site: float = float(target.delivered.get(Config.Res.TIMBER, 0.0))
	game._on_demolish_requested(target)
	# Totals are cached and refreshed once per tick, so ask for a recount
	# rather than reading the figure from before the goods came back.
	game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
	var after: float = game.sim.total_resource(Config.Res.TIMBER)
	if after >= before + on_site - 0.5:
		_note("PASS cancel_site: %.0f timber returned (%.0f -> %.0f)"
				% [on_site, before, after])
	else:
		_fail("cancel_site: %.0f timber on site, total went %.0f -> %.0f"
				% [on_site, before, after])
	for b in game.sim.buildings:
		if b == target:
			_fail("cancel_site: building still on the map")


## Order trees felled near a point and confirm they actually come down.
func _do_clear_trees(step: Dictionary) -> void:
	var origin: Vector3 = game.sim.keep.global_position
	var node = game.world.nodes.find_nearest(
			ResourceNodes.Kind.TREE, origin, 220.0, false)
	if node == null:
		_fail("clear_trees: no trees on the map")
		return
	var standing := 0
	for rec in game.world.nodes.records:
		if rec.kind == ResourceNodes.Kind.TREE and not rec.depleted \
				and rec.position.distance_to(node.position) <= game.CLEAR_BRUSH:
			standing += 1
	game._toggle_clear_tool()
	var marked := 0
	for rec in game.world.nodes.records:
		if rec.kind != ResourceNodes.Kind.TREE or rec.depleted:
			continue
		if rec.position.distance_to(node.position) > game.CLEAR_BRUSH:
			continue
		if game.sim.order_felling(rec):
			marked += 1
	game._exit_clear_tool()
	if marked <= 0:
		_fail("clear_trees: nothing was marked (%d standing)" % standing)
		return
	_note("marked %d of %d trees around (%.0f, %.0f)"
			% [marked, standing, node.position.x, node.position.z])
	_felling_target = node.position
	_felling_marked = marked
	_felling_timber_before = game.sim.total_resource(Config.Res.TIMBER)
	_felling_expected = 0.0
	for rec in game.world.nodes.records:
		if rec.reserved_by == game.sim.FELLING_CLAIM and not rec.depleted:
			_felling_expected += rec.amount


## Force a route into existence at a spot, so route decay can be tested without
## waiting for citizens to wear one in first.
func _do_stamp_wear(step: Dictionary) -> void:
	var p := Vector3.ZERO
	if step.has("on_field"):
		# Aim at ground the game is supposed to be shielding, rather than at a
		# fixed coordinate that a change to the farm layout would quietly move
		# the test off.
		p = _first_worked_plot()
		if p == Vector3.INF:
			_fail("stamp_wear on_field: no farm is working any plots")
			return
	else:
		var at: Array = step.get("at", [0, 0])
		p = Vector3(at[0], 0, at[1])
	var level := int(step.get("level", Config.RoadLevel.DIRT))
	game.world.wear.stamp_point(p.x, p.z,
			Config.ROAD_THRESHOLD[level] * 1.15, float(step.get("radius", 4.0)))
	game.world.nav.apply_road_changes(game.world.wear.refresh_levels())
	game.world.wear.flush_texture(true)
	_note("stamped %s at (%.0f, %.0f) -> %s"
			% [Config.ROAD_NAMES[level], p.x, p.z,
			   Config.ROAD_NAMES[game.world.wear.road_level_at(p.x, p.z)]])


## The centre of the first plot any farm currently has under crop.
func _first_worked_plot() -> Vector3:
	for b in game.sim.buildings:
		if b.under_construction or not b.def.is_farm():
			continue
		if not b.fields.is_empty():
			return b.fields[0]
	return Vector3.INF


func _do_upgrade(step: Dictionary) -> void:
	var target := Vector3.ZERO
	if String(step.get("at", "busiest")) == "busiest":
		target = _busiest_route()
	else:
		var at: Array = step["at"]
		target = Vector3(at[0], 0, at[1])
	if target == Vector3.INF:
		_fail("upgrade_route: no worn route found")
		return

	game.selected_road = target
	game.has_road_selection = true
	var before: int = game.world.wear.road_level_at(target.x, target.z)
	game.request_route_upgrade()
	var after: int = game.world.wear.road_level_at(target.x, target.z)
	if after <= before:
		_fail("upgrade_route: level did not rise (was %d, now %d)"
				% [before, after])
	else:
		_note("upgraded route at (%.0f, %.0f): %s -> %s"
				% [target.x, target.z, Config.ROAD_NAMES[before],
				   Config.ROAD_NAMES[after]])


func _busiest_route() -> Vector3:
	var best := -1.0
	var best_p := Vector3.INF
	var w = game.world.wear
	for y in Config.WEAR_RES:
		for x in Config.WEAR_RES:
			var v: float = w.wear[y * Config.WEAR_RES + x]
			if v > best:
				best = v
				best_p = Vector3((x + 0.5) * Config.WEAR_CELL, 0.0,
						(y + 0.5) * Config.WEAR_CELL)
	if best <= 0.0:
		return Vector3.INF
	best_p.y = game.world.heightmap.height_at(best_p.x, best_p.z)
	return best_p


## Per-entry comparison of two fingerprint sub-dictionaries, so the report
## names the building or the person that came back wrong rather than saying
## that something, somewhere, differs.
func _dict_drift(label: String, was: Dictionary, is_now: Variant
				 ) -> Array[String]:
	var out: Array[String] = []
	if typeof(is_now) != TYPE_DICTIONARY:
		out.append("%s: missing entirely after loading" % label)
		return out
	var now: Dictionary = is_now
	for key in was:
		if not now.has(key):
			out.append("%s %s: gone after loading (was %s)"
					% [label, key, was[key]])
		elif str(now[key]) != str(was[key]):
			out.append("%s %s: saved '%s', loaded '%s'"
					% [label, key, was[key], now[key]])
	for key in now:
		if not was.has(key):
			out.append("%s %s: appeared from nowhere (%s)"
					% [label, key, now[key]])
	return out


## Put goods into an idle citizen's hands with no job to explain them.
##
## This is the state a hauler is left in when their destination disappears
## under them, and the state every carrier is restored in from a save, since
## saves deliberately keep the load and drop the schedule. Reproducing it
## deliberately is the only way to test the recovery: waiting for it to happen
## by chance gives an assertion that passes because the situation never arose.
func _do_strand_load(step: Dictionary) -> void:
	var res := int(step.get("res", Config.Res.TIMBER))
	var amount := float(step.get("amount", 8.0))
	for c in game.sim.citizens:
		if c.job != null or c.carrying_amount > 0.01 or c.immigrant:
			continue
		c.pick_up(res, amount, game.registry)
		_note("put %.0f %s into %s's hands with no job to explain it"
				% [amount, Res.display(res), c.given_name])
		return
	_fail("strand_load: nobody is free to hold it")


## Grow the first completed building of `type_id` into its next tier.
func _do_upgrade_building(type_id: String) -> void:
	for b in game.sim.buildings:
		if b.type_id != type_id or b.under_construction:
			continue
		var was: String = b.display_name()
		var result: Dictionary = game.sim.upgrade(b)
		if result["ok"]:
			_note("upgrading %s into a %s (%s)"
					% [was, b.display_name(), Res.cost_text(b.build_cost)])
		else:
			_fail("upgrade %s: %s" % [type_id, result["reason"]])
		return
	_fail("upgrade %s: no completed one to upgrade" % type_id)


func _do_save(slot: String) -> void:
	var problem: String = game.save_game(slot)
	# Fingerprinted *after* the write, so it describes the world that was
	# actually written down rather than the world a moment before it — saving
	# settles the road-level cache, and taking the print first compared the
	# reloaded march against a state that was never saved.
	_save_fingerprint = _fingerprint()
	if problem == "":
		_note("saved '%s' (%s)" % [slot, _describe_save(slot)])
	else:
		_fail("save '%s' failed: %s" % [slot, problem])


func _do_load(slot: String) -> void:
	var problem: String = game.load_game(slot)
	if problem == "":
		_note("loaded '%s'" % slot)
	else:
		_fail("load '%s' failed: %s" % [slot, problem])


func _describe_save(slot: String) -> String:
	var path := SaveGame.slot_path(slot)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "unreadable"
	var size := file.get_length()
	file.close()
	return "%.1f KB on disk" % (size / 1024.0)


## The facts a save is supposed to preserve, reduced to comparable numbers.
##
## Deliberately not a checksum of the save file: that would only prove the file
## round-trips through itself, not that the settlement came back. Deliberately
## per-thing rather than per-kingdom, too — totalling the stores cannot tell a
## granary full of grain from a keep full of grain, so an early version of this
## would have accepted a load that put everything in the wrong place.
func _fingerprint() -> Dictionary:
	# The kingdom's totals are a per-tick cache. Reading them straight after an
	# op that moved goods gives the figure from before the op, which showed up
	# as a round trip that had apparently gained eight timber.
	game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
	var totals := {}
	for res in Config.RES_COUNT:
		totals[res] = roundf(game.sim.stores.total(res))

	# Each building's identity, contents, staffing and construction state,
	# keyed by id so a reordered list is not mistaken for a changed one.
	var buildings := {}
	for b in game.sim.buildings:
		var held := ""
		for res in Config.RES_COUNT:
			held += "%.0f," % b.inventory[res]
		buildings[b.id] = "%s@%.1f,%.1f %s %s w%d r%d f%d %s" % [
			b.type_id, b.position.x, b.position.z, b.asset_id, held,
			b.workers.size(), b.residents.size(), b.field_count(),
			"site%.2f" % b.build_progress if b.under_construction else "done"]

	# And each person's identity and attachments.
	var people := {}
	for c in game.sim.citizens:
		people[c.id] = "%s %s home%d work%d %s%.0f %s" % [
			c.given_name, c.asset_id, c.home_id, c.workplace_id,
			Res.display(c.carrying_res) if c.carrying_res >= 0 else "-",
			c.carrying_amount, "settling" if c.immigrant else "settled"]

	# Roads by level, not just "some road exists".
	var levels := {}
	var wear_sum := 0.0
	for cz in Config.GRID:
		for cx in Config.GRID:
			var level: int = game.world.wear.road_level_of_cell(cx, cz)
			if level > 0:
				levels[level] = int(levels.get(level, 0)) + 1
	for i in game.world.wear.wear.size():
		wear_sum += game.world.wear.wear[i]

	var standing := 0
	var marked: int = game.world.nodes.marked_ids().size()
	for rec in game.world.nodes.records:
		if not rec.depleted:
			standing += 1

	return {
		"population": game.sim.citizens.size(),
		"buildings_count": game.sim.buildings.size(),
		"buildings": buildings,
		"people": people,
		"road_cells": str(levels),
		"wear_sum": roundf(wear_sum),
		"standing_nodes": standing,
		"marked_trees": marked,
		"terrain_edits": game.world.heightmap.edits.size(),
		"day": roundf(game.sim.day * 100.0),
		"totals": totals,
	}


## Two ways a carried load goes wrong, and both are invisible from the resource
## readout.
##
## It can be *stranded*: a hauler whose destination was demolished, or one
## restored from a save, stands about holding goods that a store has room for
## and never puts them down.
##
## Or it can be *laundered*: the same person takes a fresh haul job while still
## loaded, skips the leg that would have filled their hands, and delivers what
## they are holding as whatever the new job was for. A load of timber arrives
## as stone, at the wrong door.
func _check_loads() -> Array[String]:
	var wrong: Array[String] = []
	for c in game.sim.citizens:
		if c.carrying_amount <= 0.01:
			continue
		if c.job != null:
			if c.job.res >= 0 and c.job.res != c.carrying_res:
				wrong.append("%s is carrying %s on a %s job"
						% [c.given_name, Res.display(c.carrying_res),
						   Res.display(c.job.res)])
			continue
		# Being loaded and jobless is fine for as long as they are walking the
		# load somewhere. It is standing still with it that is the defect.
		if c.has_goal():
			continue
		var room := 0.0
		for b in game.sim.stores.buildings_storing(c.carrying_res):
			if not b.under_construction:
				room += b.space_for(c.carrying_res)
		if room > c.carrying_amount:
			wrong.append("%s is standing still holding %.0f %s, with %.0f of "
					% [c.given_name, c.carrying_amount,
					   Res.display(c.carrying_res), room]
					+ "room free to put it")
	return wrong


## Run every armed invariant against the settlement as it stands.
##
## Some defects are transient: a load delivered as the wrong resource is wrong
## for a tick or two and then gone, and an assertion placed after a simulate
## step samples a moment that has almost certainly already passed. A watch runs
## on every simulation step instead, which is the difference between a test
## that could catch the bug and one that could not.
func _run_watches() -> void:
	for i in range(_watches.size() - 1, -1, -1):
		var check: String = _watches[i]
		var problems: Array[String] = []
		match check:
			"loads_are_accounted_for":
				problems = _check_loads()
			_:
				_fail("watch: '%s' is not a watchable check" % check)
				_watches.remove_at(i)
				continue
		if problems.is_empty():
			continue
		# Disarmed after the first catch, so one broken invariant does not
		# bury the report under a line per simulation step.
		_watches.remove_at(i)
		_fail("watch %s (step %d): %s" % [check, _watch_steps, problems[0]])


func _do_assert(step: Dictionary) -> void:
	var check := String(step.get("check", ""))
	var value := float(step.get("value", 0.0))
	match check:
		"wear_above":
			var peak := _peak_wear()
			if peak >= value:
				_note("PASS wear_above %.0f (peak %.0f)" % [value, peak])
			else:
				_fail("wear_above %.0f — peak was only %.0f" % [value, peak])
		"work_in_progress":
			var busy := 0
			for c in game.sim.citizens:
				if c.job != null:
					busy += 1
			if busy >= int(maxf(value, 1.0)):
				_note("PASS %d of %d people are on a job"
						% [busy, game.sim.citizens.size()])
			else:
				var labels := {}
				for c in game.sim.citizens:
					var key := String(c.task_label)
					labels[key] = int(labels.get(key, 0)) + 1
				_fail("work_in_progress: only %d of %d people have a job; "
						% [busy, game.sim.citizens.size()]
						+ "%d jobs open; doing %s (%s)"
						% [game.sim.jobs.open_jobs(), str(labels),
						   game.sim.idle_diagnosis()])
		"loads_are_accounted_for":
			var wrong := _check_loads()
			if wrong.is_empty():
				_note("PASS every carried load matches the job carrying it")
			else:
				for line in wrong.slice(0, 5):
					_fail(line)
		"fields_refuse_wear":
			var trodden: Array[String] = []
			var plots := 0
			for b in game.sim.buildings:
				if b.under_construction or not b.def.is_farm():
					continue
				for p in b.fields:
					plots += 1
					var w: float = game.world.wear.wear_at(p.x, p.z)
					if w > 0.0:
						trodden.append("%s: plot at %v carries %.0f wear"
								% [b.display_name(), p, w])
			if plots == 0:
				_fail("fields_refuse_wear: no farm is working any plots")
			elif trodden.is_empty():
				_note("PASS %d worked plots refused to record a track" % plots)
			else:
				for line in trodden:
					_fail(line)
		"farm_plots_match_workers":
			var bad: Array[String] = []
			for b in game.sim.buildings:
				if b.def.plots_per_worker <= 0 or b.under_construction:
					continue
				var want: int = b.workers.size() * b.def.plots_per_worker
				want = mini(want, b.plot_capacity())
				if b.field_count() != want:
					bad.append("%s: %d plots for %d workers (wanted %d)"
							% [b.display_name(), b.field_count(),
							   b.workers.size(), want])
			if bad.is_empty():
				_note("PASS farm plots match worker counts")
			else:
				for line in bad:
					_fail(line)
		"building_is":
			# Names a type that must exist, completed. Used to prove an upgrade
			# finished as the upgraded building rather than reverting.
			var want := String(step.get("type", ""))
			var found: Building = null
			for b in game.sim.buildings:
				if b.type_id == want and not b.under_construction:
					found = b
					break
			if found == null:
				var have: Array[String] = []
				for b in game.sim.buildings:
					have.append(b.type_id + ("*" if b.under_construction
							else ""))
				_fail("no completed '%s' — the settlement has %s"
						% [want, ", ".join(have)])
			else:
				_note("PASS a completed %s stands (%d storage, %d workers)"
						% [found.display_name(), int(found.capacity()),
						   found.def.worker_slots])
		"save_state_changed":
			# The control for save_round_trip. A load that quietly did nothing
			# would pass a round-trip check performed on an untouched world, so
			# the scenario changes the settlement in between and proves here
			# that the change really took.
			if _save_fingerprint.is_empty():
				_fail("save_state_changed: nothing has been saved yet")
			else:
				var after := _fingerprint()
				var moved: Array[String] = []
				for key in _save_fingerprint:
					if str(after.get(key)) != str(_save_fingerprint[key]):
						moved.append(key)
				if moved.is_empty():
					_fail("save_state_changed: the world is identical to the "
							+ "save, so reloading it would prove nothing")
				else:
					_note("PASS the world moved on since the save (%s)"
							% ", ".join(moved))
		"save_round_trip":
			if _save_fingerprint.is_empty():
				_fail("save_round_trip: nothing was saved to compare against")
			else:
				var now := _fingerprint()
				var drift: Array[String] = []
				for key in _save_fingerprint:
					var was: Variant = _save_fingerprint[key]
					var is_now: Variant = now.get(key)
					if typeof(was) == TYPE_DICTIONARY:
						drift.append_array(_dict_drift(key, was, is_now))
					elif str(is_now) != str(was):
						drift.append("%s: saved %s, loaded %s"
								% [key, was, is_now])
				if drift.is_empty():
					_note("PASS save round trip preserved the settlement "
							+ "(%d people, %d buildings, roads %s, wear %.0f, "
							% [now["population"], now["buildings_count"],
							   now["road_cells"], now["wear_sum"]]
							+ "%d terrain edits)" % now["terrain_edits"])
				else:
					for line in drift.slice(0, 8):
						_fail("save_round_trip — " + line)
					if drift.size() > 8:
						_note("    ...and %d more" % (drift.size() - 8))
		"nav_matches_roads":
			var wrong: Array[String] = []
			var checked := 0
			for cz in Config.GRID:
				for cx in Config.GRID:
					# The level is recomputed from the raw wear field rather
					# than read from the cache the pathfinder itself uses.
					# Comparing the cache with the cache proved only that the
					# two agreed with each other, which they do even when both
					# are stale.
					var truth: int = game.world.wear.level_from_wear(cx, cz)
					if truth <= 0:
						continue
					if game.world.nav.is_solid(cx, cz):
						continue
					checked += 1
					var cached: int = game.world.wear.road_level_of_cell(cx, cz)
					if cached != truth:
						wrong.append("(%d,%d) cached level %d, wear says %d"
								% [cx, cz, cached, truth])
						continue
					var live: float = game.world.nav.weight_at(cx, cz)
					var want: float = game.world.nav.expected_weight(cx, cz)
					if absf(live - want) > 0.001:
						wrong.append("(%d,%d) weight %.4f, expected %.4f"
								% [cx, cz, live, want])
			if checked == 0:
				_fail("nav_matches_roads: no road cells exist to check, so "
						+ "this proves nothing")
			elif wrong.is_empty():
				_note("PASS navigation weights match road levels (%d cells)"
						% checked)
			else:
				_fail("%d of %d road cells have stale navigation weights"
						% [wrong.size(), checked])
				for line in wrong.slice(0, 3):
					_note("    " + line)
		"timber_not_lost":
			# Felling a tree must not destroy the part a worker cannot carry.
			var expected: float = _felling_timber_before + _felling_expected
			var now: float = game.sim.total_resource(Config.Res.TIMBER)
			var standing := 0.0
			for rec in game.world.nodes.records:
				if rec.reserved_by == game.sim.FELLING_CLAIM and not rec.depleted:
					standing += rec.amount
			if now + standing >= expected - 1.0:
				_note("PASS felled timber accounted for (%.0f of %.0f expected)"
						% [now + standing, expected])
			else:
				_fail("felling lost timber: expected %.0f, have %.0f in store "
						% [expected, now] + "and %.0f still standing" % standing)
		"no_stale_reservations":
			var bad: Array[String] = []
			for b in game.sim.buildings:
				for res in Config.RES_COUNT:
					# Against the raw numbers, not against available(), which
					# clamps at zero and so could never report a shortfall
					# however far the reservations ran past the stock.
					if b.reserved[res] - b.inventory[res] > 0.01:
						bad.append("%s has %.1f %s reserved against %.1f held"
								% [b.display_name(), b.reserved[res],
								   Res.display(res), b.inventory[res]])
					if b.incoming[res] > 0.01 \
							and game.sim.jobs.count_for(
								JobBoard.Kind.HAUL, b.id, res) == 0:
						bad.append("%s expects %s nobody is bringing"
								% [b.display_name(), Res.display(res)])
			var ghosts := 0
			for rec in game.world.nodes.records:
				if rec.reserved_by < 0 or rec.reserved_by == game.sim.FELLING_CLAIM:
					continue
				if not game.sim.buildings_by_id.has(rec.reserved_by):
					ghosts += 1
			if ghosts > 0:
				bad.append("%d resource nodes claimed by buildings that are gone"
						% ghosts)
			if bad.is_empty():
				_note("PASS no stale reservations after demolition")
			else:
				for line in bad:
					_fail(line)
		"seat_is_protected":
			var seat = game.sim.keep
			var verdict: Dictionary = game.sim.can_demolish(seat)
			game._on_demolish_requested(seat)
			if game.sim.keep == seat and not verdict["ok"]:
				_note("PASS the seat cannot be pulled down (%s)"
						% verdict["reason"])
			else:
				_fail("the seat was destroyed, which cannot be undone")
		"tools_being_made":
			# Tools must actually be produced, not merely spent from the
			# starting stock, and they must be doing something once made.
			var made := 0.0
			for b in game.sim.buildings:
				if b.def.is_workshop():
					made += b.inventory[b.def.produces]
			var total: float = game.sim.total_resource(Config.Res.TOOLS)
			var bonus: float = game.sim.tools_bonus
			if total > 50.0 and bonus > 1.01:
				_note("PASS tools produced (%.0f in store, work rate %d%%)"
						% [total, int(bonus * 100.0)])
			else:
				_fail("tools: %.0f in store (started at 50), work rate %d%%"
						% [total, int(bonus * 100.0)])
		"trees_were_felled":
			var left := 0
			for rec in game.world.nodes.records:
				if rec.kind != ResourceNodes.Kind.TREE or rec.depleted:
					continue
				if rec.position.distance_to(_felling_target) <= game.CLEAR_BRUSH:
					left += 1
			if left == 0:
				_note("PASS all %d marked trees were felled" % _felling_marked)
			else:
				_fail("%d of %d marked trees still standing"
						% [left, _felling_marked])
		"stock_is_visible":
			# Bring every yard up to date first. Goods on show are refreshed on
			# a timer (they only have to keep up with the eye), so sampling
			# without this asserts that the timer happened to have fired since
			# the last delivery, not that a building holding goods can show
			# them — which is the property meant here.
			for b in game.sim.buildings:
				b.refresh_stock_display()
			var shown := 0
			var holding := 0
			var slotless: Array[String] = []
			## Naming the building that failed is the whole value of the check;
			## "3 of 4" sends the reader back to guess which one.
			var dark: Array[String] = []
			for b in game.sim.buildings:
				if b.under_construction or b.total_stored() < 1.0:
					continue
				if b._stock_positions().is_empty():
					# A store that cannot show anything is the defect, not a
					# case to skip over.
					if b.def.role != BuildingDefs.Role.SEAT:
						slotless.append(b.display_name())
					continue
				holding += 1
				var visible := false
				for node in b._stock_slots:
					if node != null:
						visible = true
						break
				if visible:
					shown += 1
				else:
					dark.append("%s (%s, %.0f held)" % [
							b.display_name(), b.type_id, b.total_stored()])
			for name in slotless:
				_fail("%s holds goods but has no display slots" % name)
			if holding == 0 and slotless.is_empty():
				_fail("stock_is_visible: nothing was holding goods")
			elif shown >= holding:
				_note("PASS %d stocked buildings show their goods" % shown)
			else:
				_fail("only %d of %d stocked buildings show goods — %s"
						% [shown, holding, ", ".join(dark)])
		"road_level_at_most_here":
			var at: Array = step.get("at", [0, 0])
			var here: int = game.world.wear.road_level_at(
					float(at[0]), float(at[1]))
			if here <= int(value):
				_note("PASS route regrew to %s (wanted at most %s)"
						% [Config.ROAD_NAMES[here],
						   Config.ROAD_NAMES[int(value)]])
			else:
				_fail("route still %s, wanted at most %s"
						% [Config.ROAD_NAMES[here],
						   Config.ROAD_NAMES[int(value)]])
		"road_level_at_least":
			var level := _peak_road_level()
			if level >= int(value):
				_note("PASS road_level_at_least %s (reached %s)"
						% [Config.ROAD_NAMES[int(value)],
						   Config.ROAD_NAMES[level]])
			else:
				_fail("road_level_at_least %s — only reached %s"
						% [Config.ROAD_NAMES[int(value)],
						   Config.ROAD_NAMES[level]])
		"resource_above":
			var res := int(step.get("res", Config.Res.TIMBER))
			var have: float = game.sim.total_resource(res)
			if have >= value:
				_note("PASS %s >= %.0f (have %.0f)"
						% [Res.display(res), value, have])
			else:
				_fail("%s below %.0f (have %.0f)"
						% [Res.display(res), value, have])
		"population_at_least":
			# Measured against the settlement's starting size, not against a
			# bare number: nothing removes a citizen, so any target at or below
			# Config.START_CITIZENS is satisfied before the scenario begins and
			# would stay green with immigration entirely broken.
			var pop: int = game.sim.citizens.size()
			var want: int = int(value)
			if want <= Config.START_CITIZENS:
				_fail("population_at_least %d proves nothing: the march opens "
						% want + "with %d and nobody ever leaves"
						% Config.START_CITIZENS)
			elif pop >= want:
				_note("PASS population %d >= %d (%d settled since day one)"
						% [pop, want, pop - Config.START_CITIZENS])
			else:
				_fail("population %d < %d" % [pop, want])
		"buildings_complete":
			var n := 0
			for b in game.sim.buildings:
				if not b.under_construction:
					n += 1
			if n >= int(value):
				_note("PASS %d buildings complete" % n)
			else:
				_fail("only %d buildings complete, wanted %d" % [n, int(value)])
		"households_eat":
			# Meals actually sat down to, per settled citizen. Food being
			# present proves nothing; somebody has to have eaten it.
			var total := 0
			var counted := 0
			var starving: Array[String] = []
			for c in game.sim.citizens:
				if c.immigrant:
					continue
				counted += 1
				total += c.meals_taken
				if c.hunger > 0.75:
					starving.append(c.given_name)
			# The average rather than the worst-fed: settlers arrive throughout
			# a run, and somebody who walked in yesterday cannot have eaten a
			# week of dinners. Starvation is the per-person half of this and is
			# checked separately, so it cannot hide inside an average.
			var per_head: float = float(total) / float(maxi(1, counted))
			if counted == 0:
				_fail("households_eat: nobody to feed")
			elif not starving.is_empty():
				_fail("households_eat: %d starving (%s)"
						% [starving.size(), ", ".join(starving.slice(0, 4))])
			elif per_head < value:
				_fail("households_eat: %.1f meals a head across %d people, "
						% [per_head, counted] + "wanted %.0f (%d eaten)"
						% [value, total])
			else:
				_note("PASS %.1f meals a head across %d people (%d eaten, "
						% [per_head, counted, total] + "nobody starving)")
		"larders_are_stocked":
			# The food has to be in the houses, not in the granary. This is the
			# whole point of the change: it is carried home and kept there.
			var stocked := 0
			var households := 0
			var bare: Array[String] = []
			for b in game.sim.buildings:
				if b.under_construction or b.def.houses <= 0 \
						or b.residents.is_empty():
					continue
				households += 1
				if b.larder >= Config.MEAL_FOOD:
					stocked += 1
				else:
					bare.append("%s (%d housed)"
							% [b.display_name(), b.residents.size()])
			if households == 0:
				_fail("larders_are_stocked: no occupied households")
			elif stocked < int(maxf(value, 1.0)):
				_fail("only %d of %d households have food in — bare: %s"
						% [stocked, households, ", ".join(bare.slice(0, 4))])
			else:
				_note("PASS %d of %d households have food in the larder"
						% [stocked, households])
		"asleep_at_night":
			# Asserts it really is night as well as that they are indoors: a
			# check that silently passes in broad daylight is worthless.
			if not Config.is_night(game.sim.day):
				_fail("asleep_at_night sampled at %.2f of a day, which is not "
						% fposmod(game.sim.day, 1.0) + "night")
			else:
				var inside := 0
				var housed := 0
				for c in game.sim.citizens:
					if c.immigrant or c.home_id < 0:
						continue
					housed += 1
					if c.indoors:
						inside += 1
				if housed == 0:
					_fail("asleep_at_night: nobody has a home to go to")
				elif inside < int(maxf(value, 1.0)):
					_fail("only %d of %d housed citizens are indoors at night"
							% [inside, housed])
				else:
					_note("PASS %d of %d housed citizens are indoors for the "
							% [inside, housed] + "night")
		_:
			_fail("unknown assert '%s'" % check)


func _peak_wear() -> float:
	var best := 0.0
	for v in game.world.wear.wear:
		best = maxf(best, v)
	return best


func _peak_road_level() -> int:
	return Config.road_level_for_wear(_peak_wear())


func _shot(tag: String) -> void:
	# Logic-only runs use --headless, where there is no framebuffer to grab.
	# Skipping lets a long simulation test run at full speed instead of being
	# bottlenecked on a software rasteriser it does not need.
	if DisplayServer.get_name() == "headless":
		_note("shot %s skipped (headless)" % tag)
		_busy = false
		return
	# Bring the view up to date before photographing it. A `simulate` step runs
	# the whole span inside one frame, so nothing that refreshes on a timer has
	# caught up: the interface still shows the readouts it had before the burst
	# and the wear texture still shows the ground before anybody walked on it.
	# A screenshot captioned "day 16" that reads "Day 1" in the corner is worse
	# than no screenshot, because it is documentation.
	game.world.set_time_of_day(game.clock.day_fraction(),
			game.clock.season_fraction())
	game.world.wear.flush_texture(true)
	game.hud.refresh()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image: Image = game.get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_out_dir, tag]
	var err := image.save_png(path)
	_busy = false
	if err != OK:
		_fail("could not save screenshot %s (error %d)" % [path, err])
		return
	_note("shot %s -> %s" % [tag, ProjectSettings.globalize_path(path)])


func _do_inspect(type_id: String) -> void:
	for b in game.sim.buildings:
		if b.type_id != type_id:
			continue
		_note("--- %s #%d ---" % [b.display_name(), b.id])
		_note("  under_construction=%s workers=%d/%d"
				% [b.under_construction, b.workers.size(), b.def.worker_slots])
		for res in Config.RES_COUNT:
			if b.inventory[res] > 0.01 or b.incoming[res] > 0.01:
				_note("  %-7s have %.1f incoming %.1f reserved %.1f"
						% [Res.display(res), b.inventory[res],
						   b.incoming[res], b.reserved[res]])
		_note("  stored %.1f / %.1f   can_craft=%s"
				% [b.total_stored(), b.capacity(), b.can_craft()])
		_note("  craft jobs=%d  haul-in jobs=%d"
				% [game.sim.jobs.count_for(JobBoard.Kind.CRAFT, b.id,
						b.def.produces),
				   game.sim.jobs.count_for(JobBoard.Kind.HAUL, b.id,
						Config.Res.IRON)])
		return
	_note("inspect: no %s found" % type_id)


func _report() -> void:
	var sim = game.sim
	_note("--- state ---")
	# Both clocks, because they are supposed to be the same clock: the sun is
	# graded off the Clock and the settlement's routine off the simulation, so
	# if these ever drift apart the march goes to bed at noon.
	_note("day %.2f (clock %.2f, %02d:%02d)  population %d  buildings %d"
			% [sim.day, game.clock.elapsed_days,
			   int(game.clock.day_fraction() * 24.0),
			   int(fposmod(game.clock.day_fraction() * 24.0, 1.0) * 60.0),
			   sim.citizens.size(), sim.buildings.size()])
	for res in Config.RES_COUNT:
		_note("  %-7s %.0f" % [Res.display(res), sim.total_resource(res)])
	_note("  peak wear %.0f (%s)"
			% [_peak_wear(), Config.ROAD_NAMES[_peak_road_level()]])
	var levels := {}
	for cz in Config.GRID:
		for cx in Config.GRID:
			var l: int = game.world.wear.road_level_of_cell(cx, cz)
			if l > 0:
				levels[l] = int(levels.get(l, 0)) + 1
	for l in levels.keys():
		_note("  %-14s %d cells" % [Config.ROAD_NAMES[l], levels[l]])


## Print what the run actually cost. Paired with the correctness assertions,
## this is how an optimisation is shown to have worked rather than asserted to.
func _perf_report() -> void:
	_note("--- performance ---")
	_note("  %-26s %9.1f" % ["fps", Engine.get_frames_per_second()])
	for line in Perf.report():
		_note(line)


## Screen-space tests need a screen. Headless opens a 64-pixel window, where the
## top bar alone covers the whole of it, every click aimed at the world lands on
## the interface, and any conclusion drawn is about nothing. Say so and fail
## rather than report a result: this used to "pass" headless only because the
## test called the picking function behind the interface's back.
func _needs_real_viewport(what: String) -> bool:
	var size: Vector2 = game.get_viewport().get_visible_rect().size
	if size.x >= 640.0 and size.y >= 400.0:
		return false
	_fail("%s needs a real viewport; this one is %dx%d. Run it with a display "
			% [what, int(size.x), int(size.y)]
			+ "(tools/build.sh harness <scene>, or under xvfb-run) rather "
			+ "than --headless.")
	return true


## Left-click at a screen position the way the player does.
##
## This builds a real InputEventMouseButton and hands it to the game's input
## handler, rather than calling `_pick_at` behind its back. Calling the picking
## function directly skipped `hud.blocks_mouse` and the placement/clear mode
## dispatch entirely, so the test could not have caught a click being eaten by
## the interface or going to the wrong verb — while its comment claimed it
## exercised "the real input path". The only part left out is the engine's own
## event routing, which is not ours to break.
func _click_at(screen: Vector2) -> void:
	if game.hud.blocks_mouse(screen):
		_fail("a click at %v never reaches the world: %s is over it"
				% [screen, _blocker_at(game.hud, screen)])
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = screen
	game._unhandled_input(ev)


## Name the interface element sitting over a point, so "the click was eaten"
## comes with the culprit rather than sending the reader hunting for it.
func _blocker_at(node: Node, at: Vector2) -> String:
	for child in node.get_children():
		if not (child is Control):
			continue
		var control: Control = child
		if not control.visible:
			continue
		if control.mouse_filter != Control.MOUSE_FILTER_IGNORE \
				and control.get_global_rect().has_point(at):
			return "%s %s" % [control.name, str(control.get_global_rect())]
		var deeper := _blocker_at(control, at)
		if deeper != "":
			return deeper
	return ""


## Click the first building of a type, through the game's input handler, so the
## screenshot shows what a player actually sees after clicking it.
func _do_select_building(type_id: String) -> void:
	if _needs_real_viewport("select_building"):
		return
	var cam: Camera3D = game.camera.camera()
	for b in game.sim.buildings:
		if b.type_id != type_id:
			continue
		var aim: Vector3 = b.global_position + Vector3(0, 1.5, 0)
		if cam.is_position_behind(aim):
			continue
		_click_at(cam.unproject_position(aim))
		if game.selected_building == b:
			_note("selected %s by clicking it" % b.display_name())
		else:
			_fail("clicking %s selected %s" % [b.display_name(),
					"nothing" if game.selected_building == null
					else game.selected_building.display_name()])
		return
	_fail("select_building: no %s on the map" % type_id)


## Click on the centre of every building, through the game's input handler, and
## report what got selected. Verifies the whole chain: world position -> screen
## projection -> input handling -> ray -> physics query -> selection.
func _do_pick_test() -> void:
	if _needs_real_viewport("pick_test"):
		return
	var cam: Camera3D = game.camera.camera()
	var hits := 0
	var misses: Array[String] = []
	for b in game.sim.buildings:
		var aim: Vector3 = b.global_position + Vector3(0, 1.5, 0)
		if cam.is_position_behind(aim):
			continue
		var screen: Vector2 = cam.unproject_position(aim)
		_click_at(screen)
		if game.selected_building == b:
			hits += 1
		elif game.selected_building != null:
			# Something else was in front. That is a legitimate result, but
			# only if it really is in front: counting any selection as a hit
			# meant the test passed even when clicks landed on the wrong
			# building entirely.
			var other: Building = game.selected_building
			var to_b: float = cam.global_position.distance_to(b.global_position)
			var to_other: float = cam.global_position.distance_to(
					other.global_position)
			if to_other < to_b:
				hits += 1
			else:
				misses.append("%s at %v -> %s, which is further away"
						% [b.display_name(), screen, other.display_name()])
		else:
			var got := "terrain" if game.has_road_selection else "nothing"
			misses.append("%s at %v -> %s" % [b.display_name(), screen, got])
	if misses.is_empty():
		_note("PASS pick_test: %d/%d buildings selected by clicking them"
				% [hits, hits])
	else:
		_fail("pick_test: %d hit, %d missed" % [hits, misses.size()])
		for m in misses:
			_note("    " + m)
	game._clear_selection()


## Cast a ray at a known ground point and check the hit lands there. This is
## what the placement ghost follows, so drift here is the ghost jumping.
func _do_raycast_test() -> void:
	var cam: Camera3D = game.camera.camera()
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var samples := 0
	var centre: Vector3 = game.sim.keep.global_position
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			var target := centre + Vector3(dx * 7.0, 0, dz * 7.0)
			target.y = game.world.heightmap.height_at(target.x, target.z)
			if cam.is_position_behind(target):
				continue
			var screen: Vector2 = cam.unproject_position(target)
			var ray: Dictionary = game.camera.screen_ray(screen)
			var hit: Dictionary = game.world.terrain.raycast(
					ray["origin"], ray["direction"])
			if not hit["hit"]:
				_fail("raycast_test: no hit for %v" % target)
				continue
			var p: Vector3 = hit["position"]
			var err: float = Vector2(p.x - target.x, p.z - target.z).length()
			samples += 1
			if err > worst:
				worst = err
				worst_at = target
	if worst <= 1.5:
		_note("PASS raycast_test: worst error %.2f m over %d samples"
				% [worst, samples])
	else:
		_fail("raycast_test: worst error %.2f m at %v over %d samples"
				% [worst, worst_at, samples])


func _note(text: String) -> void:
	_log.append(text)
	print("[harness] ", text)


func _fail(text: String) -> void:
	_failures.append(text)
	_log.append("FAIL: " + text)
	printerr("[harness] FAIL: ", text)


func _finish() -> void:
	var summary := "\n".join(_log)
	var file := FileAccess.open("%s/harness_log.txt" % _out_dir, FileAccess.WRITE)
	if file:
		file.store_string(summary + "\n")
		file.close()
	if _failures.is_empty():
		print("[harness] ALL CHECKS PASSED")
		get_tree().quit(0)
	else:
		printerr("[harness] %d FAILURE(S)" % _failures.size())
		get_tree().quit(1)
