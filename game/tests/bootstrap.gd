extends "res://tests/long_run.gd"

## tools/godot_env.sh --headless --path game --script res://tests/bootstrap.gd
## A playable bootstrap and a complete tools chain, paid from the real opening
## stock and subsequent production. No gifted production sites or materials.
## --bootstrap-seed=N and --bootstrap-days=N shorten diagnostic runs.

const BOOTSTRAP_DAYS := 120
const LATE_START := 60

var _tools_used := 0.0
var _research_tools_spent := 0.0


func _advance_bootstrap_day(game: SeededGame) -> void:
	for _i in roundi(Config.DAY_LENGTH / Config.MAX_SIM_STEP):
		var next_day := game.sim.day + Config.MAX_SIM_STEP / Config.DAY_LENGTH
		var reckoning := floori(next_day) > floori(game.sim.day)
		var elapsed := next_day - game.sim.day_marker()
		game.sim.tick(Config.MAX_SIM_STEP)
		game.clock.elapsed_days += Config.MAX_SIM_STEP / Config.DAY_LENGTH
		if reckoning:
			var workers := 0
			for b in game.sim.buildings:
				if not b.under_construction:
					workers += b.workers.size()
			# The daily bonus reports the fraction of the tool demand actually
			# supplied, allowing production to be measured despite consumption.
			var supplied := clampf((game.sim.tools_bonus - 1.0) / Config.TOOLS_WORK_BONUS, 0.0, 1.0)
			_tools_used += float(workers) * Config.TOOLS_PER_WORKER_DAY * elapsed * supplied
	await process_frame


func _production_anchors(game: SeededGame, type_id: String, offset: Vector3) -> Array[Vector3]:
	var def := BuildingDefs.get_def(type_id)
	var anchors: Array[Vector3] = []
	if def.is_gatherer():
		for node in game.world.nodes.records:
			if node.kind == def.harvest_kind and not node.depleted:
				anchors.append(node.position)
		var centre := game.world.centre()
		anchors.sort_custom(func(a: Vector3, b: Vector3) -> bool:
			return a.distance_squared_to(centre) < b.distance_squared_to(centre))
	else:
		anchors.append(game.world.centre() + offset)
	return anchors


func _global_ore(game: SeededGame) -> float:
	var amount := 0.0
	for node in game.world.nodes.records:
		if node.kind == ResourceNodes.Kind.IRON and not node.depleted:
			amount += node.amount
	return amount


func _ore_in_range(game: SeededGame, mine: Building) -> float:
	var amount := 0.0
	for node in game.world.nodes.records:
		if node.kind == ResourceNodes.Kind.IRON and not node.depleted \
				and node.position.distance_to(mine.position) <= mine.def.work_radius:
			amount += node.amount
	return amount


func _paid_site(game: SeededGame, type_id: String, offset: Vector3) -> Building:
	# Leave room for the later forge; this is planning a larger footprint, not
	# receiving the upgrade before its materials have been hauled and built.
	var footprint_type := "forge" if type_id == "blacksmith" else type_id
	# The nearest live deposit can be steep or disconnected; try every real
	# deposit before declaring that a paid replacement cannot be built.
	for anchor in _production_anchors(game, type_id, offset):
		var at := _site(game, footprint_type, anchor)
		if at != Vector3.INF:
			return game.sim.place_building(type_id, at, 0.0, false)
	return null


func _reachable_ore_remains(game: SeededGame, active_mine: Building) -> bool:
	if active_mine != null and _ore_in_range(game, active_mine) > 0.001:
		return true
	for anchor in _production_anchors(game, "mine", Vector3.ZERO):
		if _site(game, "mine", anchor) != Vector3.INF:
			return true
	return false


func _industry_metrics(game: SeededGame, day_number: int) -> Dictionary:
	var metrics := _metrics(game, day_number)
	var workers := {}
	var vacancies := 0
	var food_plots := 0
	var iron_near_mines := 0.0
	var self_hauls := 0
	var stranded_carriers := 0
	for b in game.sim.buildings:
		if b.def.worker_slots > 0:
			workers[b.type_id] = int(workers.get(b.type_id, 0)) + b.workers.size()
			if not b.under_construction:
				vacancies += b.def.worker_slots - b.workers.size()
		food_plots += b.field_count()
		if b.type_id == "mine":
			iron_near_mines += _ore_in_range(game, b)
	for job in game.sim.jobs.all_jobs():
		self_hauls += int(job.kind == JobBoard.Kind.HAUL and job.source_id == job.dest_id)
	for c in game.sim.citizens:
		stranded_carriers += int(c.carrying_amount > 0.01 and c.job == null and not c.has_goal())
	metrics["phase"] = "bootstrap"
	metrics["workers"] = workers
	metrics["vacancies"] = vacancies
	metrics["food_plots"] = food_plots
	metrics["iron"] = game.sim.total_resource(Config.Res.IRON)
	metrics["iron_near_mines"] = iron_near_mines
	metrics["global_ore"] = _global_ore(game)
	metrics["tools_bonus"] = game.sim.tools_bonus
	metrics["tools_consumed"] = _tools_used
	metrics["estimated_tools_made"] = metrics.tools + _tools_used + _research_tools_spent - game.START_TOOLS
	metrics["research"] = game.sim.research.completed.duplicate()
	metrics["active_research"] = game.sim.research.active
	metrics["self_hauls"] = self_hauls
	metrics["loaded_without_route"] = stranded_carriers
	return metrics


func _diagnose(game: SeededGame, current: Building) -> Dictionary:
	var buildings: Array = []
	for b in game.sim.buildings:
		if b.def.is_producer() or b.def.houses > 0 or b.under_construction:
			buildings.append({"id": b.id, "type": b.type_id, "position": b.position,
				"inventory": Array(b.inventory), "reserved": Array(b.reserved),
				"incoming": Array(b.incoming), "workers": b.workers,
				"progress": b.build_progress, "needed": b.materials_needed(), "larder": b.larder})
	var people: Array = []
	for c in game.sim.citizens:
		people.append({"id": c.id, "workplace": c.workplace_id, "task": c.task_label,
			"hunger": c.hunger, "carried": c.carrying_amount,
			"resource": c.carrying_res, "position": c.position,
			"state": c.state, "next_meal": c.next_meal, "work_remaining": c._work_timer,
			"job": c.job.id if c.job != null else -1,
			"job_kind": c.job.kind if c.job != null else -1,
			"job_target": c.job.position if c.job != null else Vector3.ZERO,
			"home": c.home_id, "meals": c.meals_taken, "indoors": c.indoors,
			"unreachable": c.unreachable, "goal": c._goal if c.has_goal() else Vector3.INF})
	return {"seed": game.scenario_seed, "phase": "bootstrap_diagnostic", "day": game.sim.day,
		"current_site": current.id if current != null else -1,
		"buildings": buildings, "people": people}


func _bootstrap(world_seed: int, days: int) -> void:
	var started := Time.get_ticks_msec()
	var failures_before := _failures
	var game := _new_game(world_seed)
	_tools_used = 0.0
	_research_tools_spent = 0.0
	var plan: Array = [
		["logging_camp", Vector3.ZERO],
		["farm", Vector3(-36, 0, 48)],
		["quarry", Vector3.ZERO],
		["farm", Vector3(44, 0, 48)],
		["granary", Vector3(40, 0, 4)],
		["mine", Vector3.ZERO],
		["blacksmith", Vector3(-56, 0, 12)],
		["market", Vector3(-36, 0, -32)],
		["stockpile", Vector3(-32, 0, -12)],
		["house", Vector3(-42, 0, 8)],
		["house", Vector3(8, 0, 52)],
	]
	var next_order := 0
	var current: Building
	var current_started := 0
	var current_cost := {}
	var shop: Building
	var active_mine: Building
	var replacement_mines := 0
	var initial_ore := _global_ore(game)
	var ore_exhausted_day := -1
	var late_reachable_ore := false
	var upgrade_started := false
	var upgrade_completed := false
	var chain_completed_day := -1
	var paid := {Config.Res.TIMBER: 0.0, Config.Res.STONE: 0.0, Config.Res.IRON: 0.0}
	var timeline: Array = []
	var research_timeline: Array = []
	var research_paid := {Config.Res.TIMBER: 0.0, Config.Res.STONE: 0.0, Config.Res.TOOLS: 0.0}
	var min_food := INF
	var min_tools := INF
	var hungry_days := 0
	var low_tools_days := 0
	var late_tools_min := INF
	var late_made_start := 0.0
	var stalled_reported := false
	var max_stranded := 0
	var stranded_days := 0
	for day_number in range(1, days + 1):
		game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
		if game._has_market() and game.sim.research.active == "":
			for tech_id in ["civic_building", "metallurgy"]:
				if game.sim.research.completed.has(tech_id):
					continue
				var offer := game.sim.research.quote(tech_id, true)
				if offer.can_start and game.sim.stores.can_afford(offer.cost):
					var error := game.sim.research.start(tech_id, true, game.sim.stores.try_spend)
					_check(error == "", "seed %d pays for %s research" % [world_seed, tech_id])
					if error == "":
						for res in offer.cost:
							research_paid[res] = float(research_paid.get(res, 0.0)) + float(offer.cost[res])
						_research_tools_spent += float(offer.cost.get(Config.Res.TOOLS, 0.0))
						research_timeline.append({"id": tech_id, "started": day_number,
							"cost": offer.cost, "duration_days": offer.duration_days})
						print("METRIC " + JSON.stringify({"seed": world_seed,
							"phase": "bootstrap_research", "day": day_number,
							"id": tech_id, "cost": offer.cost}))
				break
		if current == null and next_order < plan.size():
			var type_id: String = plan[next_order][0]
			var def := BuildingDefs.get_def(type_id)
			if game.sim.can_afford(def.cost):
				current = _paid_site(game, type_id, plan[next_order][1])
				_check(current != null, "seed %d can site paid %s" % [world_seed, type_id])
				if current == null:
					break
				_check(current.under_construction and current.build_progress == 0.0,
						"seed %d %s starts as an unpaid blueprint" % [world_seed, type_id])
				current_started = day_number
				current_cost = def.cost.duplicate()
				timeline.append({"type": type_id, "ordered": day_number, "cost": current_cost})
				print("METRIC " + JSON.stringify({"seed": world_seed, "phase": "bootstrap_order",
					"day": day_number, "type": type_id, "cost": current_cost}))
				if type_id == "blacksmith":
					shop = current
				elif type_id == "mine":
					active_mine = current
				next_order += 1
		elif current == null and next_order == plan.size() and not upgrade_started \
				and day_number >= 35 and shop != null:
			var verdict := game.sim.can_upgrade(shop)
			if verdict["ok"]:
				current_cost = shop.def.upgrade_cost.duplicate()
				var result := game.sim.upgrade(shop)
				_check(result["ok"], "seed %d pays for forge upgrade through construction" % world_seed)
				if result["ok"]:
					upgrade_started = true
					current = shop
					current_started = day_number
					timeline.append({"type": "forge", "ordered": day_number, "cost": current_cost})
		if current == null and active_mine != null \
				and _ore_in_range(game, active_mine) <= 0.001 and _global_ore(game) > 0.001:
			# Deposits are finite. Retire the spent mine and pay to work the next
			# real vein, exactly as a player must; never refill its old outcrops.
			# This can happen before the forge is affordable: waiting for that
			# upgrade would deadlock the very iron supply needed to build it.
			var mine_def := BuildingDefs.get_def("mine")
			if game.sim.can_afford(mine_def.cost):
				current = _paid_site(game, "mine", Vector3.ZERO)
				if current == null:
					_problem("%d:replacement_site" % world_seed,
							"seed %d can site a paid replacement mine at a remaining deposit" % world_seed)
				if current != null:
					var previous_id := active_mine.id
					var demolition := game.sim.demolish(active_mine)
					active_mine = current
					current_cost = mine_def.cost.duplicate()
					current_started = day_number
					replacement_mines += 1
					timeline.append({"type": "mine", "ordered": day_number, "cost": current_cost,
						"replaces": previous_id, "refunded": demolition.refunded, "lost": demolition.lost})
					print("METRIC " + JSON.stringify({"seed": world_seed, "phase": "bootstrap_relocate_mine",
						"day": day_number, "old_id": previous_id, "cost": current_cost,
						"ore_in_range": _ore_in_range(game, current)}))
		await _advance_bootstrap_day(game)
		for entry in research_timeline:
			if not entry.has("completed") and game.sim.research.completed.has(entry.id):
				entry["completed"] = day_number
		_invariants(game, "seed %d bootstrap" % world_seed)
		if current != null and not current.under_construction:
			for res in current_cost:
				_check(is_equal_approx(float(current.delivered.get(res, 0.0)), float(current_cost[res])),
						"seed %d completed %s paid its %s cost" % [world_seed, current.type_id, Res.display(res)])
				paid[res] = float(paid.get(res, 0.0)) + float(current_cost[res])
			timeline[-1]["completed"] = day_number
			if current.type_id == "blacksmith":
				chain_completed_day = day_number
			elif current.type_id == "forge":
				upgrade_completed = true
			print("METRIC " + JSON.stringify({"seed": world_seed, "phase": "bootstrap_complete",
				"day": day_number, "type": current.type_id, "construction_days": day_number - current_started + 1}))
			current = null
		elif current != null and day_number - current_started >= 15 and not stalled_reported:
			stalled_reported = true
			print("METRIC " + JSON.stringify(_diagnose(game, current)))
		var metrics := _industry_metrics(game, day_number)
		if metrics.global_ore <= 0.001 and ore_exhausted_day < 0:
			ore_exhausted_day = day_number
		if metrics.self_hauls > 0:
			_problem("%d:self_haul" % world_seed,
					"seed %d posts a haul from a workshop to itself" % world_seed)
		max_stranded = maxi(max_stranded, metrics.loaded_without_route)
		stranded_days += int(metrics.loaded_without_route > 0)
		min_food = minf(min_food, metrics.food)
		min_tools = minf(min_tools, metrics.tools)
		hungry_days += int(metrics.hungry > 0)
		if day_number == LATE_START:
			late_made_start = metrics.estimated_tools_made
			late_reachable_ore = _reachable_ore_remains(game, active_mine)
		if day_number > LATE_START:
			late_tools_min = minf(late_tools_min, metrics.tools)
			low_tools_days += int(metrics.tools_bonus < 1.0 + Config.TOOLS_WORK_BONUS * 0.95)
		if day_number % 10 == 0 or day_number == days:
			print("METRIC " + JSON.stringify(metrics))
	var summary := _industry_metrics(game, days)
	summary["phase"] = "bootstrap_summary"
	summary["timeline"] = timeline
	summary["paid_materials"] = paid
	summary["research_paid"] = research_paid
	summary["research_timeline"] = research_timeline
	summary["minimum_food"] = min_food
	summary["minimum_tools"] = min_tools
	summary["days_with_hungry_people"] = hungry_days
	summary["blacksmith_completed_day"] = chain_completed_day
	summary["forge_completed"] = upgrade_completed
	summary["replacement_mines"] = replacement_mines
	summary["initial_ore"] = initial_ore
	summary["ore_exhausted_day"] = ore_exhausted_day
	summary["reachable_ore_at_day_60"] = late_reachable_ore
	summary["maximum_loaded_without_route"] = max_stranded
	summary["days_with_loaded_without_route"] = stranded_days
	summary["late_tools_minimum"] = late_tools_min if late_tools_min != INF else null
	summary["late_tool_shortage_days"] = low_tools_days
	summary["late_tools_made"] = summary.estimated_tools_made - late_made_start if days > LATE_START else null
	summary["wall_seconds"] = (Time.get_ticks_msec() - started) / 1000.0
	print("METRIC " + JSON.stringify(summary))
	if days >= 60:
		_check(next_order == plan.size() and timeline.size() >= plan.size()
				and timeline[plan.size() - 1].has("completed"),
				"seed %d builds its complete economy from opening stock and production" % world_seed)
		_check(chain_completed_day > 0 and summary.estimated_tools_made >= 40.0,
				"seed %d mine and smith produce replacement tools" % world_seed)
		_check(upgrade_completed, "seed %d completes the paid forge upgrade" % world_seed)
		_check(game.sim.research.completed.has("civic_building")
				and game.sim.research.completed.has("metallurgy")
				and research_timeline.size() == 2 and research_paid[Config.Res.TOOLS] == 5.0,
				"seed %d pays for and completes both technologies before operating a forge" % world_seed)
	if days > LATE_START:
		_check(low_tools_days == 0,
				"seed %d full industry sustains the tools bonus after day %d" % [world_seed, LATE_START])
		_check(late_tools_min > 0.0,
				"seed %d retains replacement tools through day %d" % [world_seed, days])
		if late_reachable_ore:
			_check(float(summary.late_tools_made) >= Config.CRAFT_BATCH,
					"seed %d industry keeps producing tools after day %d while ore remains" % [world_seed, LATE_START])
	# A replacement ordered near the horizon may still be receiving its
	# materials. An old site must not hide behind reserves from its predecessor.
	_check(current == null or days - current_started < 15,
			"seed %d has no paid construction stalled for fifteen days at the horizon" % world_seed)
	if _failures > failures_before or next_order != plan.size() \
			or not upgrade_completed or low_tools_days > 0 or summary.famine_days >= 3.0:
		print("METRIC " + JSON.stringify(_diagnose(game, current)))
	game.free()
	await process_frame


func _run() -> void:
	var seeds: Array = SEEDS.duplicate()
	var days := BOOTSTRAP_DAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bootstrap-seed="):
			seeds = [int(arg.trim_prefix("--bootstrap-seed="))]
		elif arg.begins_with("--bootstrap-days="):
			days = maxi(1, int(arg.trim_prefix("--bootstrap-days=")))
	var started := Time.get_ticks_msec()
	for world_seed in seeds:
		await _bootstrap(world_seed, days)
	print("METRIC " + JSON.stringify({"phase": "bootstrap_run_summary", "seeds": seeds,
		"days_per_seed": days, "failures": _failures,
		"wall_seconds": (Time.get_ticks_msec() - started) / 1000.0}))
	print("Bootstrap failures: %d" % _failures)
	quit(1 if _failures else 0)
