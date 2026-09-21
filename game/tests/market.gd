extends "res://tests/long_run.gd"

## Real markets and forward supply: staffed physical hauling, capped stock,
## household meals, paid construction, saved policies and destructive damage.


func _clear_jobs(sim: Simulation) -> void:
	for job in sim.jobs.all_jobs():
		sim._release_reservations(job)
		sim.jobs.cancel(job)
	for c in sim.citizens:
		sim._release_cart(c)
		sim._go_idle(c)
		if c.carrying_amount > 0.0:
			var res := c.carrying_res
			var left := sim._spill_into_stores(res, c.drop(), c.position)
			if left > 0.0:
				c.pick_up(res, left, sim.registry)


func _meals(sim: Simulation) -> int:
	var count := 0
	for c in sim.citizens:
		count += c.meals_taken
	return count


func _wear_total(game: SeededGame) -> float:
	var amount := 0.0
	for value in game.world.wear.wear:
		amount += value
	return amount


func _paid_market() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var market := _build(game, "market", game.world.centre() + Vector3(-55, 0, 12), false)
	if market == null:
		game.free()
		return
	_check(market.under_construction and market.total_stored() == 0.0,
			"market starts as an empty paid blueprint")
	_check(market.set_market_stock_target(40) and not market.set_market_stock_target(500),
			"market accepts a bounded stock policy and rejects invalid targets")
	for i in 4:
		await _advance_day(game)
		if not market.under_construction and market.inventory[Config.Res.FOOD] >= 8.0:
			break
	_check(not market.under_construction
			and market.delivered.get(Config.Res.TIMBER) == 24.0
			and market.delivered.get(Config.Res.STONE) == 8.0,
			"haulers and builders complete the market with actual timber and stone")
	_check(market.workers.size() == 2 and market.inventory[Config.Res.FOOD] > 0.0,
			"two employed vendors physically stock the completed market")
	_check(market.inventory[Config.Res.FOOD] + market.incoming[Config.Res.FOOD] <= 40.01,
			"stock and promised deliveries respect the chosen target")
	var service := sim.market_service(market)
	_check(service.homes > 0 and service.residents > 0 and service.daily_demand > 0.0,
			"market reports reachable local households and their real food demand")
	_check(market._visual.has_node("market_stalls") and market._stock_slots.size() == 1,
			"completed market has visible counters, awnings and a physical food pile")
	_invariants(game, "paid market")

	# Isolate one real vendor journey, retaining ordinary navigation and wear.
	_clear_jobs(sim)
	market.inventory[Config.Res.FOOD] = 0.0
	sim.keep.inventory[Config.Res.FOOD] = 100.0
	sim.production._post_market(market)
	var vendor: Citizen = sim.citizens_by_id[market.workers[0]]
	vendor.position = sim.entrance_of(market, "att_cart_bay")
	sim._seek_job(vendor)
	_check(vendor.job != null and vendor.job.required_workplace == market.id,
			"a vendor prioritizes its own procurement order")
	var wear_before := _wear_total(game)
	var food_before := sim.keep.inventory[Config.Res.FOOD]
	for tick in 1600:
		if vendor.job == null:
			break
		sim._tick_haul(vendor, Config.MAX_SIM_STEP)
	_check(vendor.job == null and market.inventory[Config.Res.FOOD] == Config.CARRY_CAPACITY
			and sim.keep.inventory[Config.Res.FOOD] == food_before - Config.CARRY_CAPACITY,
			"vendor collection and deposit conserve the food transported")
	_check(_wear_total(game) > wear_before,
			"vendor footsteps wear the real route between source and market")

	# A nearby household fetches from these counters and then eats at home.
	var home := _build(game, "house", market.position + Vector3(-20, 0, 0))
	if home != null:
		var customer: Citizen = sim.citizens[-1]
		var old_home: Building = sim.buildings_by_id.get(customer.home_id)
		if old_home != null:
			old_home.residents.erase(customer.id)
		customer.home_id = home.id
		home.residents.append(customer.id)
		home.larder = 0.0
		customer.position = sim.entrance_of(home, "att_entrance")
		customer.hunger = Config.HUNGER_URGENT
		customer.next_meal = sim.day - 1.0
		customer.state = Citizen.State.EATING
		var meal_before := customer.meals_taken
		var stock_before := market.inventory[Config.Res.FOOD]
		_check(sim._nearest_food(customer.position) == market,
				"nearby household chooses the market's actual available food")
		for tick in 1600:
			if customer.meals_taken > meal_before:
				break
			sim._tick_meal(customer, Config.MAX_SIM_STEP)
		_check(customer.meals_taken == meal_before + 1
				and market.inventory[Config.Res.FOOD] < stock_before and home.larder > 0.0,
				"household carries market food home, fills its larder and eats")
	game.free()
	await process_frame


func _procurement_rules() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var market := _build(game, "market", game.world.centre() + Vector3(-55, 0, 12))
	var other := _build(game, "market", game.world.centre() + Vector3(-75, 0, 12))
	var farm := _build(game, "farm", game.world.centre() + Vector3(-90, 0, 65))
	if market == null or other == null or farm == null:
		game.free()
		return
	_clear_jobs(sim)
	sim.production._post_market(market)
	_check(sim.jobs.total_jobs() == 0, "an unstaffed market cannot procure food")
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	for b in sim.stores.buildings_storing(Config.Res.FOOD):
		b.inventory[Config.Res.FOOD] = 0.0
	other.inventory[Config.Res.FOOD] = 100.0
	farm.inventory[Config.Res.FOOD] = 24.0
	sim.production._post_market(market)
	_check(sim.jobs.total_jobs() == 0,
			"market neither drains another market nor takes the farm's local food reserve")
	farm.inventory[Config.Res.FOOD] = 36.0
	sim.production._post_market(market)
	sim.production._post_market(market)
	_check(sim.jobs.total_jobs() == 1 and farm.reserved[Config.Res.FOOD] == 12.0,
			"vendor promises only genuine farm surplus")
	var outsider: Citizen
	for c in sim.citizens:
		if c.workplace_id != market.id:
			outsider = c
			break
	_check(sim.jobs.best_for(outsider.id, farm.position, JobBoard.Accept.ANY,
			outsider.workplace_id) == null,
			"other labourers cannot substitute for the market's employed vendors")
	_clear_jobs(sim)
	market.set_market_stock_target(40)
	market.inventory[Config.Res.FOOD] = 39.0
	sim.production._post_market(market)
	sim.production._post_market(market)
	_check(sim.jobs.total_jobs() == 1 and market.incoming[Config.Res.FOOD] == 1.0,
			"a nearly full market orders only the missing unit")
	_check(sim.stores.find_store(Config.Res.FOOD, market.position, -1) != market,
			"ordinary producer deliveries cannot bypass the market's target or staffing")
	market.inventory[Config.Res.FOOD] = 60.0
	_check(market.set_market_stock_target(40) and market.inventory[Config.Res.FOOD] == 60.0,
			"lowering the target keeps food already on the counters")
	_clear_jobs(sim)
	sim.production._post_market(market)
	_check(sim.jobs.total_jobs() == 0, "stock above a reduced target stops further procurement")
	game.free()
	await process_frame


func _supply_relays() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var centre := game.world.centre()
	var market := _build(game, "market", centre + Vector3(45, 0, 10))
	var inner := _build(game, "supply_hut", centre + Vector3(145, 0, 10))
	var outer := _build(game, "supply_hut", centre + Vector3(270, 0, 10))
	if market == null or inner == null or outer == null:
		game.free()
		return
	_clear_jobs(sim)
	for b in sim.stores.buildings_storing(Config.Res.FOOD):
		b.inventory[Config.Res.FOOD] = 0.0
	market.inventory[Config.Res.FOOD] = 80.0
	inner.inventory[Config.Res.FOOD] = 60.0
	outer.inventory[Config.Res.FOOD] = 60.0
	_check(sim.stores.find_market_source(inner) == market,
			"forward supply hut draws from an upstream market within relay range")
	_check(sim.stores.find_market_source(outer) == inner,
			"a second supply hut relays food outward through the first")
	market.inventory[Config.Res.FOOD] = 0.0
	_check(sim.stores.find_market_source(inner) == null,
			"forward depots cannot send food backward or form resupply loops")
	inner.inventory[Config.Res.FOOD] = 0.0
	sim.keep.inventory[Config.Res.FOOD] = 100.0
	_check(sim.stores.find_market_source(outer) == null,
			"a distant depot cannot skip a missing link in the supply chain")
	_check(inner.food_stock_target() == 60
			and BuildingDefs.get_def("supply_hut").upgrades_to == "fort",
			"supply huts have a bounded ration target and a fort upgrade")
	game.free()
	await process_frame


func _save_and_damage() -> void:
	var game := _new_game(42)
	var market := _build(game, "market", game.world.centre() + Vector3(-55, 0, 12))
	if market == null:
		game.free()
		return
	market.set_market_stock_target(120)
	market.inventory[Config.Res.FOOD] = 35.0
	market.apply_damage(30.0, 0.4)
	var saved := SaveGame.capture(game)
	var market_id := market.id
	var result := game.restore_from(saved)
	_check(result == "", "market policy, physical food and damage pass actual save restoration")
	if result == "":
		market = game.sim.buildings_by_id[market_id]
		_check(market.market_stock_target == 120 and market.inventory[Config.Res.FOOD] == 35.0
				and market.health == 150.0 and is_equal_approx(market.fire, 0.4),
				"restored market preserves its target, supplies, health and fire")
	var health_before := market.health
	market.tick_fire(2.0)
	_check(market.health < health_before and market.fire < 0.4
			and market._fire_visual != null and market._fire_visual.visible,
			"fire visibly burns and damages a building while its fuel decays")
	_check(market.apply_damage(10000.0) and market.health == 0.0,
			"lethal damage reports destruction without negative health")
	game.sim.workforce.update(game.sim.buildings, game.sim.citizens, game.sim.buildings_by_id)
	game.sim.keep.inventory[Config.Res.FOOD] = 100.0
	game.sim.production._post_market(market)
	var vendor: Citizen = game.sim.citizens_by_id[market.workers[0]]
	vendor.position = game.sim.entrance_of(game.sim.keep, "att_cart_bay")
	game.sim._seek_job(vendor)
	game.sim._tick_haul(vendor, Config.MAX_SIM_STEP)
	_check(vendor.carrying_amount == Config.CARRY_CAPACITY,
			"destruction fixture has a real delivery already on the road")
	game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
	var before := game.sim.total_resource(Config.Res.FOOD)
	var destroyed := game.sim.demolish(market, false)
	game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
	_check(destroyed.refunded.is_empty() and destroyed.lost.get(Config.Res.FOOD) == 35.0
			and is_equal_approx(game.sim.total_resource(Config.Res.FOOD), before - 35.0),
			"hostile destruction loses onsite food without material refunds or duplication")
	_check(not game.sim.buildings_by_id.has(market_id),
			"destroyed structure leaves the live building index")
	_check(vendor.job == null and vendor.carrying_amount == Config.CARRY_CAPACITY,
			"destruction retires the delivery but preserves goods still carried elsewhere")
	game.free()
	await process_frame


func _fort_upgrade() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var hut := _build(game, "supply_hut", game.world.centre() + Vector3(-55, 0, 12))
	if hut == null:
		game.free()
		return
	_check(not sim.can_upgrade(hut).ok, "fort upgrade requires researched fortification")
	sim.research.restore({"completed": ["civic_building", "fortification"],
		"active": "", "remaining_days": 0.0})
	sim.keep.inventory[Config.Res.TIMBER] = 80.0
	sim.keep.inventory[Config.Res.STONE] = 80.0
	sim.keep.inventory[Config.Res.TOOLS] = 20.0
	hut.inventory[Config.Res.FOOD] = 30.0
	hut.apply_damage(36.0)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var result := sim.upgrade(hut)
	_check(result.ok and hut.type_id == "fort" and hut.under_construction
			and is_equal_approx(hut.health / hut.max_health(), 0.8)
			and hut.inventory[Config.Res.FOOD] == 30.0,
			"fort upgrade preserves physical supplies and structural condition")
	for day_number in 4:
		await _advance_day(game)
		if not hut.under_construction:
			break
	_check(not hut.under_construction and hut.delivered.get(Config.Res.TIMBER) == 45.0
			and hut.delivered.get(Config.Res.STONE) == 35.0
			and hut.delivered.get(Config.Res.TOOLS) == 8.0,
			"fort is completed through actual delivery of timber, stone and tools")
	_check(hut.max_health() == 600.0 and hut.capacity() == 180.0
			and hut.food_stock_target() == 120,
			"completed fort provides tougher walls and larger forward supplies")
	_invariants(game, "paid fort upgrade")
	game.free()
	await process_frame


func _partial_food_deposit() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var granary := _build(game, "granary", game.world.centre() + Vector3(75, 0, 0))
	if granary == null:
		game.free()
		return
	_clear_jobs(sim)
	for store in sim.stores.buildings_storing(Config.Res.FOOD):
		store.inventory.fill(0.0)
		store.inventory[Config.Res.FOOD] = store.capacity()
	sim.keep.inventory.fill(0.0)
	sim.keep.inventory[Config.Res.FOOD] = sim.keep.capacity() - 2.0
	granary.inventory.fill(0.0)
	var carrier: Citizen = sim.citizens[0]
	carrier.position = sim.entrance_of(sim.keep, "att_cart_bay")
	carrier.pick_up(Config.Res.FOOD, 10.0, sim.registry)
	var total_before := sim.keep.inventory[Config.Res.FOOD] + carrier.carrying_amount
	_check(sim.stores.find_store(Config.Res.FOOD, carrier.position, -1) == sim.keep,
			"partial deposit fixture first selects the nearly full nearby keep")
	sim._carry_stray_load(carrier, Config.MAX_SIM_STEP)
	_check(carrier.carrying_amount == 8.0 and carrier.has_goal()
			and carrier._goal.is_equal_approx(sim.entrance_of(granary, "att_cart_bay")),
			"partial stray-food deposit routes its remainder to another store in the same tick")
	for tick in 1600:
		if carrier.carrying_amount <= 0.01:
			break
		sim._carry_stray_load(carrier, Config.MAX_SIM_STEP)
	_check(carrier.carrying_amount == 0.0 and granary.inventory[Config.Res.FOOD] == 8.0
			and sim.keep.inventory[Config.Res.FOOD] + granary.inventory[Config.Res.FOOD] == total_before,
			"the remainder reaches the second store without loss or teleporting")
	game.free()
	await process_frame


func _run() -> void:
	await _paid_market()
	await _procurement_rules()
	await _supply_relays()
	await _save_and_damage()
	await _fort_upgrade()
	await _partial_food_deposit()
	print("Market regression failures: %d" % _failures)
	quit(1 if _failures else 0)
