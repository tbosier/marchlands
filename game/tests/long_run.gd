extends SceneTree

## tools/godot_env.sh --headless --path game --script res://tests/long_run.gd
## Defaults to 90 days on three fixed seeds. --long-seed=N, --long-days=N and
## --long-phase=economy|supply|storage select a smaller diagnostic run.
## METRIC records report balance observations;
## only state integrity and explicitly supplied recovery scenarios are gates.

class SeededGame extends "res://scripts/core/game.gd":
	var scenario_seed := 20260911

	func _seed_from_args() -> int:
		return scenario_seed


const SEEDS := [20260911, 1776, 42]
const DEFAULT_DAYS := 90

var _failures := 0
var _seen_failures := {}
var _summaries: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", description])
	if not ok:
		_failures += 1


func _problem(key: String, detail: String) -> void:
	if _seen_failures.has(key):
		return
	_seen_failures[key] = true
	_check(false, detail)


func _new_game(world_seed: int) -> SeededGame:
	var game := SeededGame.new()
	game.scenario_seed = world_seed
	root.add_child(game)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	# _ready randomizes presentation; production's review jitter also uses the
	# global generator, so seed it after startup for repeatable simulation.
	seed(world_seed)
	return game


func _site(game: SeededGame, type_id: String, anchor: Vector3) -> Vector3:
	var from := game.sim.entrance_of(game.sim.keep, "att_entrance")
	for ring in 22:
		var radius := float(ring) * 6.0
		for i in 20:
			var angle := TAU * float(i) / 20.0 + float(ring) * 0.31
			var p := anchor + Vector3(cos(angle), 0, sin(angle)) * radius
			if p.x < 12 or p.z < 12 or p.x > Config.WORLD_SIZE - 12 \
					or p.z > Config.WORLD_SIZE - 12:
				continue
			p.y = game.world.heightmap.height_at(p.x, p.z)
			if not game.sim.can_place(type_id, p)["ok"]:
				continue
			if game.world.nav.find_path(from, p).is_empty():
				continue
			return p
	return Vector3.INF


func _build(game: SeededGame, type_id: String, anchor: Vector3,
		instant: bool = true) -> Building:
	var p := _site(game, type_id, anchor)
	_check(p != Vector3.INF, "seed %d can site %s" % [game.scenario_seed, type_id])
	if p == Vector3.INF:
		return null
	return game.sim.place_building(type_id, p, 0.0, instant)


func _advance_day(game: SeededGame) -> void:
	var ticks := roundi(Config.DAY_LENGTH / Config.MAX_SIM_STEP)
	for _i in ticks:
		game.sim.tick(Config.MAX_SIM_STEP)
		game.clock.elapsed_days += Config.MAX_SIM_STEP / Config.DAY_LENGTH
	# Long runs must let queued visuals go, just as ordinary rendered play
	# does; otherwise replaced carried props accumulate for ninety days.
	await process_frame


func _invariants(game: SeededGame, label: String) -> void:
	var sim := game.sim
	var outgoing := {}
	var incoming := {}
	var production := {}
	for job in sim.jobs.all_jobs():
		if job.cancelled:
			_problem(label + ":cancelled", label + " retains a cancelled job")
		if job.claimed_by >= 0:
			var worker: Citizen = sim.citizens_by_id.get(job.claimed_by)
			if worker == null or worker.job != job:
				_problem(label + ":claim", label + " has a job without its claimed worker")
		if job.kind in [JobBoard.Kind.GATHER, JobBoard.Kind.HARVEST, JobBoard.Kind.BUTCHER]:
			production[job.dest_id] = float(production.get(job.dest_id, 0.0)) + job.output_reserved
		if job.kind != JobBoard.Kind.HAUL:
			continue
		if not sim.buildings_by_id.has(job.source_id) \
				or not sim.buildings_by_id.has(job.dest_id):
			_problem(label + ":endpoint", label + " has a haul whose endpoint is gone")
		var source_key := "%d:%d" % [job.source_id, job.res]
		var dest_key := "%d:%d" % [job.dest_id, job.res]
		if not job.loaded:
			outgoing[source_key] = float(outgoing.get(source_key, 0.0)) + job.amount
		incoming[dest_key] = float(incoming.get(dest_key, 0.0)) + job.amount
	for b in sim.buildings:
		var stored := 0.0
		var incoming_total := 0.0
		for res in Config.RES_COUNT:
			stored += b.inventory[res]
			incoming_total += b.incoming[res]
			for value in [b.inventory[res], b.reserved[res], b.incoming[res]]:
				if not is_finite(value) or value < -0.01:
					_problem(label + ":inventory", "%s has invalid inventory at building %d" % [label, b.id])
			var key := "%d:%d" % [b.id, res]
			if absf(b.reserved[res] - float(outgoing.get(key, 0.0))) > 0.02:
				_problem(label + ":reserved", "%s source reservation disagrees with live jobs at %s" % [label, key])
			if absf(b.incoming[res] - float(incoming.get(key, 0.0))) > 0.02:
				_problem(label + ":incoming", "%s incoming reservation disagrees with live jobs at %s" % [label, key])
		if stored > b.capacity() + 0.05:
			_problem(label + ":capacity", "%s exceeds storage capacity at building %d" % [label, b.id])
		if not is_finite(b.production_reserved) or b.production_reserved < -0.01 \
				or absf(b.production_reserved - float(production.get(b.id, 0.0))) > 0.02:
			_problem(label + ":production_reserved",
					"%s production capacity claim disagrees with live jobs at building %d" % [label, b.id])
		if b.def.is_producer() and not b.under_construction \
				and stored + incoming_total + b.production_reserved > b.capacity() + 0.05:
			_problem(label + ":production_capacity",
					"%s stock and pending production exceed capacity at building %d" % [label, b.id])
		if not is_finite(b.larder) or b.larder < 0 or b.larder > b.larder_capacity() + 0.01:
			_problem(label + ":larder", label + " has an invalid household larder")
		if b.crop_growth < 0 or b.crop_growth > 1 or not is_finite(b.crop_growth):
			_problem(label + ":crop", label + " has invalid crop growth")
	for c in sim.citizens:
		if not c.position.is_finite() or not is_finite(c.carrying_amount) \
				or c.carrying_amount < 0 or not is_finite(c.hunger) \
				or c.hunger < 0 or c.hunger > 1:
			_problem(label + ":citizen", label + " has an invalid citizen state")
		if c.home_id >= 0 and (not sim.buildings_by_id.has(c.home_id) \
				or not sim.buildings_by_id[c.home_id].residents.has(c.id)):
			_problem(label + ":home", label + " has an inconsistent household assignment")
		if c.workplace_id >= 0 and (not sim.buildings_by_id.has(c.workplace_id) \
				or not sim.buildings_by_id[c.workplace_id].workers.has(c.id)):
			_problem(label + ":work", label + " has an inconsistent workplace assignment")
		if c.job != null and (c.job.cancelled or c.job.claimed_by != c.id):
			_problem(label + ":workerjob", label + " has a worker keeping a retired job")
	if sim.citizens.size() > sim.population.housing_capacity(sim.buildings):
		_problem(label + ":population", label + " immigration exceeded available housing")


func _metrics(game: SeededGame, day_number: int) -> Dictionary:
	var sim := game.sim
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var hungry := 0
	var hungry_with_load := 0
	var immigrants := 0
	var meals := 0
	var larders := 0.0
	var saturated := 0
	var construction := 0
	for c in sim.citizens:
		hungry += int(c.hunger > Config.HUNGER_URGENT)
		hungry_with_load += int(c.hunger > Config.HUNGER_URGENT and c.carrying_amount > 0.01)
		immigrants += int(c.immigrant)
		meals += c.meals_taken
	for b in sim.buildings:
		larders += b.larder
		construction += int(b.under_construction)
		var held := 0.0
		for amount in b.inventory:
			held += amount
		if b.capacity() > 0 and held >= b.capacity() * 0.95:
			saturated += 1
	return {"seed": game.scenario_seed, "day": day_number,
		"population": sim.citizens.size(), "immigrants": immigrants,
		"hungry": hungry, "hungry_with_load": hungry_with_load,
		"meals": meals, "food": sim.total_resource(Config.Res.FOOD),
		"larder_food": larders, "timber": sim.total_resource(Config.Res.TIMBER),
		"stone": sim.total_resource(Config.Res.STONE), "tools": sim.total_resource(Config.Res.TOOLS),
		"saturated_stores": saturated, "jobs": sim.jobs.total_jobs(),
		"construction": construction, "famine_days": sim.population.famine_days()}


func _economy(world_seed: int, days: int) -> void:
	var started := Time.get_ticks_msec()
	var game := _new_game(world_seed)
	var centre := game.world.centre()
	# Start with a small established economy, then let its ordinary stores,
	# workforce, meals, harvests, immigration, and shortages run unaided.
	_build(game, "farm", centre + Vector3(-36, 0, 48))
	_build(game, "farm", centre + Vector3(44, 0, 48))
	_build(game, "granary", centre + Vector3(40, 0, 4))
	_build(game, "house", centre + Vector3(-42, 0, 8))
	_build(game, "house", centre + Vector3(8, 0, 52))
	for pair in [["logging_camp", ResourceNodes.Kind.TREE], ["quarry", ResourceNodes.Kind.STONE]]:
		var node := game.world.nodes.find_nearest(pair[1], centre, 350.0, false)
		_check(node != null, "seed %d has resource for %s" % [world_seed, pair[0]])
		if node != null:
			_build(game, pair[0], node.position)
	var construction_orders: Array[Dictionary] = []
	var min_food := INF
	var hungry_days := 0
	var last_meals := 0
	var max_immigrants := 0
	var saturated_days := 0
	var arriving_since := {}
	var longest_arrival := 0
	for day_number in range(1, days + 1):
		if day_number in [20, 50]:
			var cost := BuildingDefs.get_def("house").cost
			if game.sim.can_afford(cost):
				var b := _build(game, "house", centre + Vector3(-20, 0, 64), false)
				if b != null:
					construction_orders.append({"building": b, "ordered_day": day_number})
			else:
				print("METRIC " + JSON.stringify({"seed": world_seed, "day": day_number,
					"event": "expansion_waits_for_materials"}))
		await _advance_day(game)
		_invariants(game, "seed %d economy" % world_seed)
		var metrics := _metrics(game, day_number)
		for c in game.sim.citizens:
			if c.immigrant:
				if not arriving_since.has(c.id):
					arriving_since[c.id] = day_number
				var waiting: int = day_number - int(arriving_since[c.id])
				longest_arrival = maxi(longest_arrival, waiting)
				if waiting > 12:
					_problem("%d:immigrant" % world_seed,
							"seed %d immigrant %d remains stranded after twelve days" % [world_seed, c.id])
			else:
				arriving_since.erase(c.id)
		min_food = minf(min_food, metrics.food)
		hungry_days += int(metrics.hungry > 0)
		max_immigrants = maxi(max_immigrants, metrics.immigrants)
		saturated_days += int(metrics.saturated_stores > 0)
		if metrics.meals < last_meals:
			_problem("%d:meals" % world_seed, "seed %d lost recorded meals" % world_seed)
		last_meals = metrics.meals
		for order in construction_orders:
			var b: Building = order.building
			if day_number == int(order.ordered_day) + 15:
				_check(not b.under_construction,
						"seed %d funded house ordered day %d completes within fifteen days" % [world_seed, order.ordered_day])
		if day_number % 10 == 0 or day_number == days:
			print("METRIC " + JSON.stringify(metrics))
	var summary := _metrics(game, days)
	summary["phase"] = "economy_summary"
	summary["minimum_food"] = min_food
	summary["days_with_hungry_people"] = hungry_days
	summary["days_with_saturated_storage"] = saturated_days
	summary["maximum_arriving_immigrants"] = max_immigrants
	summary["longest_arrival_days"] = longest_arrival
	summary["estimated_food_produced"] = summary.food + float(last_meals) * Config.MEAL_FOOD - game.START_FOOD
	summary["wall_seconds"] = (Time.get_ticks_msec() - started) / 1000.0
	_summaries.append(summary)
	print("METRIC " + JSON.stringify(summary))
	_check(last_meals >= Config.START_CITIZENS,
			"seed %d citizens actually eat during the long run" % world_seed)
	if days >= 7:
		_check(summary.estimated_food_produced >= Config.CARRY_CAPACITY,
				"seed %d farms produce food beyond the starting reserves" % world_seed)
	if days >= 10:
		_check(int(summary.population) - int(summary.immigrants) > Config.START_CITIZENS,
				"seed %d spare housing and initial food attract settlers who arrive" % world_seed)
	game.free()
	await process_frame


func _construction_recovery(world_seed: int) -> void:
	var game := _new_game(world_seed)
	var sim := game.sim
	sim.keep.inventory[Config.Res.TIMBER] = 0.0
	sim.keep.inventory[Config.Res.STONE] = 0.0
	var site := _build(game, "house", game.world.centre() + Vector3(-34, 0, 42), false)
	if site == null:
		game.free()
		return
	for _day in 2:
		await _advance_day(game)
	_check(site.under_construction and site.build_progress == 0.0
			and site.delivered.get(Config.Res.TIMBER, 0.0) == 0.0
			and site.delivered.get(Config.Res.STONE, 0.0) == 0.0,
			"seed %d unfunded site waits without inventing materials" % world_seed)
	for res in site.build_cost:
		sim.keep.add(res, float(site.build_cost[res]))
	for _day in 8:
		await _advance_day(game)
		if not site.under_construction:
			break
	_check(not site.under_construction, "seed %d construction resumes after supplies arrive" % world_seed)
	_invariants(game, "seed %d supply recovery" % world_seed)
	print("METRIC " + JSON.stringify({"seed": world_seed, "phase": "supply_recovery",
		"complete": not site.under_construction, "progress": site.build_progress,
		"day": sim.day, "delivered": site.delivered}))
	game.free()
	await process_frame


func _storage_recovery(world_seed: int) -> void:
	var game := _new_game(world_seed)
	var sim := game.sim
	# Freeze meal demand for this short, isolated logistics fixture so eating
	# cannot accidentally open the space whose absence is being exercised.
	for c in sim.citizens:
		c.next_meal = sim.day + 100.0
	for b in sim.buildings:
		for res in Config.RES_COUNT:
			b.inventory[res] = 0.0
		if b.stores(Config.Res.TIMBER):
			b.inventory[Config.Res.TIMBER] = b.capacity()
	var carrier := sim.citizens[0]
	var granary := _build(game, "granary", game.world.centre() + Vector3(40, 0, 4))
	if granary == null:
		game.free()
		return
	granary.add(Config.Res.FOOD, 100.0)
	carrier.pick_up(Config.Res.TIMBER, 12.0, game.registry)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var before := sim.total_resource(Config.Res.TIMBER)
	await _advance_day(game)
	_check(carrier.carrying_res == Config.Res.TIMBER and carrier.carrying_amount == 12.0,
			"seed %d full storage retains the undeliverable load" % world_seed)
	carrier.next_meal = sim.day - 1.0
	carrier.hunger = 0.8
	var meals_before := carrier.meals_taken
	for _day in 2:
		await _advance_day(game)
	_check(carrier.meals_taken > meals_before,
			"seed %d hungry carrier can eat while material stores are full" % world_seed)
	_check(carrier.carrying_res == Config.Res.TIMBER and carrier.carrying_amount == 12.0,
			"seed %d eating preserves the stranded material load" % world_seed)
	carrier.next_meal = sim.day + 100.0
	var site := _build(game, "stockpile", game.world.centre() + Vector3(-32, 0, -12), false)
	if site == null:
		game.free()
		return
	for _day in 8:
		await _advance_day(game)
		if not site.under_construction and carrier.carrying_amount == 0.0:
			break
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var accounted := sim.total_resource(Config.Res.TIMBER) + float(site.delivered.get(Config.Res.TIMBER, 0.0))
	_check(not site.under_construction and carrier.carrying_amount == 0.0,
			"seed %d full-storage construction opens capacity and releases the carrier" % world_seed)
	_check(absf(accounted - before) < 0.02,
			"seed %d storage recovery conserves timber including construction materials" % world_seed)
	_invariants(game, "seed %d storage recovery" % world_seed)
	print("METRIC " + JSON.stringify({"seed": world_seed, "phase": "storage_recovery",
		"complete": not site.under_construction, "before_timber": before,
		"accounted_timber": accounted, "carried": carrier.carrying_amount,
		"carrier_meals": carrier.meals_taken - meals_before, "day": sim.day}))
	game.free()
	await process_frame


func _run() -> void:
	var seeds: Array = SEEDS.duplicate()
	var days := DEFAULT_DAYS
	var phase := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--long-seed="):
			seeds = [int(arg.trim_prefix("--long-seed="))]
		elif arg.begins_with("--long-days="):
			days = maxi(1, int(arg.trim_prefix("--long-days=")))
		elif arg.begins_with("--long-phase="):
			phase = arg.trim_prefix("--long-phase=")
	if phase not in ["", "economy", "supply", "storage"]:
		_check(false, "unknown long-run phase '%s'" % phase)
		print("Long-run failures: %d" % _failures)
		quit(1)
		return
	var started := Time.get_ticks_msec()
	for world_seed in seeds:
		if phase in ["", "economy"]:
			await _economy(world_seed, days)
		if phase in ["", "supply"]:
			await _construction_recovery(world_seed)
		if phase in ["", "storage"]:
			await _storage_recovery(world_seed)
	print("METRIC " + JSON.stringify({"phase": "long_run_summary", "seeds": seeds,
		"days_per_seed": days, "failures": _failures,
		"wall_seconds": (Time.get_ticks_msec() - started) / 1000.0}))
	print("Long-run failures: %d" % _failures)
	quit(1 if _failures else 0)
