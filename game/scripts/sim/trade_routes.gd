class_name TradeRoutes
extends Node3D

## Reservations promise stock; only a merchant at a counter transfers goods.
const EXPORT := Config.Res.TIMBER
const IMPORT := Config.Res.IRON
const HOME_FOOD_DAYS := 2.0
const MAX_ROUTES := 128
const STATES := ["loading", "outward", "exchange", "return", "unloading", "waiting"]
var sim: Simulation
var world: World
var registry: AssetRegistry
var caravans: Dictionary = {}
var wrecks: Array = []
var _next_id := 1


func setup(p_sim: Simulation, p_world: World, p_registry: AssetRegistry) -> void:
	sim = p_sim
	world = p_world
	registry = p_registry
	sim.stores.trade = self
	name = "trade_routes"


func _market(origin_id: int = -1) -> Building:
	for b in sim.buildings:
		if b.def.is_market() and not b.under_construction and (origin_id < 0 or b.id == origin_id):
			return b
	return null


func _candidate(citizen_id: int = -1) -> Citizen:
	for c in sim.citizens:
		if c.immigrant or c.service_health <= 0 or (citizen_id >= 0 and c.id != citizen_id): continue
		if c is Soldier and (c.health <= 0 or c.workability() <= 0 or c.mobility_scale() <= 0): continue
		return c
	return null


func _source(res: int, amount: float, from: Vector3) -> Building:
	var best: Building
	var distance := INF
	for b in sim.stores.buildings_storing(res):
		if b.under_construction or b.available(res) + 0.0001 < amount: continue
		var door := sim.entrance_of(b, "att_cart_bay")
		var d := door.distance_squared_to(from)
		if d < distance and world.nav.can_reach(from, door):
			best = b
			distance = d
	return best


func quotes(origin_id: int = -1, merchant: Citizen = null) -> Array[Dictionary]:
	if merchant == null: merchant = _candidate()
	var q := {"origin_id": -1, "target_id": -1, "export_res": EXPORT,
		"export_amount": 24.0, "import_res": IMPORT, "import_amount": 8.0,
		"provisions": 0.0, "travel_seconds": 0.0, "capacity": Cart.CAPACITY,
		"food_floor": float(sim.population_members().size()) * HOME_FOOD_DAYS,
		"ok": false, "reason": "Build a market to dispatch a caravan.",
		"source_id": -1, "food_source_id": -1}
	var origin := _market(origin_id)
	if origin == null: return [q]
	q.origin_id = origin.id
	q.reason = "No neighboring trading town."
	if sim.campaign == null: return [q]
	if sim.scouting != null and sim.scouting.city_report().is_empty():
		q.reason = "Discover a neighboring town with a scout before trading."
		return [q]
	var target: Building = sim.campaign.trade_store()
	if target == null: return [q]
	q.target_id = target.id
	q.reason = sim.campaign.trade_access_reason(target.id)
	if q.reason != "": return [q]
	if sim.campaign.personality == "loner":
		q.export_amount = 12.0
		q.import_amount = 4.0
		for caravan in caravans.values():
			if caravan.promised:
				q.reason = "This private town accepts one trade at a time."
				return [q]
	q.reason = "The neighbor has insufficient unreserved iron."
	if target.available(IMPORT) < q.import_amount: return [q]
	q.reason = "The neighbor has no room for the offered timber."
	if target.space_for(EXPORT) + q.import_amount < q.export_amount: return [q]
	var start := sim.entrance_of(origin, "att_cart_bay")
	var path := world.nav.find_path(start, sim.campaign._door(target))
	q.reason = "No traversable route to the neighboring town."
	if path.is_empty(): return [q]
	var speed := Config.CART_SPEED
	if merchant != null:
		speed *= merchant.speed_scale
		if merchant is Soldier: speed *= merchant.mobility_scale()
		speed *= 1.0 - 0.14 * clampf(merchant.carrying_amount / float(Config.CARRY_CAPACITY), 0.0, 1.0)
	q.travel_seconds = world.nav.travel_cost(start, sim.campaign._door(target)) * 2.0 / maxf(0.01, speed)
	q.provisions = maxf(2.0, ceilf(q.travel_seconds / Config.DAY_LENGTH + 1.0))
	q.reason = "This journey needs more provisions than the cart can carry."
	var personal_load := 0.0 if merchant == null else merchant.carrying_amount
	if merchant is Soldier: personal_load += merchant.rations
	if q.provisions + q.export_amount + personal_load > Cart.CAPACITY: return [q]
	var source := _source(EXPORT, q.export_amount, start)
	q.reason = "No reachable store has enough available timber."
	if source == null: return [q]
	q.source_id = source.id
	q.reason = "Keep two days of food at home before packing provisions."
	if sim.stores.spendable(Config.Res.FOOD) - q.provisions < q.food_floor: return [q]
	var food := _source(Config.Res.FOOD, q.provisions, start)
	q.reason = "No reachable counter can supply the travel provisions."
	if food == null: return [q]
	q.food_source_id = food.id
	q.reason = "No settled civilian remains to serve as merchant."
	if merchant == null: return [q]
	q.reason = ""
	q.ok = true
	return [q]


func dispatch(origin_id: int = -1, target_id: int = -1,
		citizen_id: int = -1, repeating: bool = false) -> String:
	if caravans.size() >= MAX_ROUTES: return "Too many active caravans."
	var c := _candidate(citizen_id)
	if c == null: return "Choose an available settled citizen."
	var q: Dictionary = quotes(origin_id, c)[0]
	if not q.ok: return q.reason
	if target_id >= 0 and target_id != q.target_id: return "That trading destination is unavailable."
	if c.carrying_amount + q.provisions + q.export_amount + (c.rations if c is Soldier else 0.0) > Cart.CAPACITY:
		return "The citizen's existing load leaves insufficient cart capacity."
	var origin: Building = sim.buildings_by_id[q.origin_id]
	if not world.nav.can_reach(c.global_position, sim.entrance_of(origin, "att_cart_bay")):
		return "The merchant cannot reach the market."
	if not sim.campaign.reserve_trade(q.target_id, q.import_amount):
		return "The neighbor's promised stock changed; request a new offer."
	sim.detach_for_service(c)
	var route := Caravan.new()
	add_child(route)
	route.setup(_next_id, c, registry)
	_next_id += 1
	caravans[route.id] = route
	route.repeat = repeating
	_accept_quote(route, q)
	_refresh()
	return ""


func _accept_quote(route: Caravan, q: Dictionary) -> void:
	route.origin_id = q.origin_id
	route.target_id = q.target_id
	route.source_id = q.source_id
	route.food_source_id = q.food_source_id
	route.export_amount = q.export_amount
	route.import_amount = q.import_amount
	route.pack_amount = q.provisions
	route.promised = true
	route.source_reserved = true
	route.food_reserved = true
	sim.buildings_by_id[route.source_id].reserved[EXPORT] += route.export_amount
	sim.buildings_by_id[route.food_source_id].reserved[Config.Res.FOOD] += route.pack_amount
	route.expires_in = maxf(Config.DAY_LENGTH * 4.0, q.travel_seconds * 4.0 + Config.DAY_LENGTH)
	route.state = "loading"
	route.loading_stage = "food"
	route.status = "Collecting provisions"
	route.merchant.clear_goal()


func recall(caravan_id: int) -> String:
	var route: Caravan = caravans.get(caravan_id)
	if route == null: return "Select an active caravan."
	route.repeat = false
	_return(route, "Recalled; bringing the cart and its goods home")
	return ""


func set_repeat(caravan_id: int, enabled: bool) -> String:
	var route: Caravan = caravans.get(caravan_id)
	if route == null: return "Select an active caravan."
	route.repeat = enabled
	return ""


func _release(route: Caravan) -> void:
	if route.promised and sim.campaign != null:
		sim.campaign.release_trade(route.target_id, route.import_amount)
	route.promised = false
	if route.source_reserved:
		var b: Building = sim.buildings_by_id.get(route.source_id)
		if b != null: b.reserved[EXPORT] = maxf(0.0, b.reserved[EXPORT] - route.export_amount)
	route.source_reserved = false
	if route.food_reserved:
		var b: Building = sim.buildings_by_id.get(route.food_source_id)
		if b != null: b.reserved[Config.Res.FOOD] = maxf(0.0, b.reserved[Config.Res.FOOD] - route.pack_amount)
	route.food_reserved = false


func _return(route: Caravan, reason: String) -> void:
	_release(route)
	route.state = "return"
	route.status = reason
	route.merchant.clear_goal()


func _move(route: Caravan, destination: Vector3, delta: float) -> bool:
	route.merchant.set_goal(destination)
	route.merchant.advance(delta, world)
	if route.merchant.unreachable:
		route.status = "Waiting: no traversable route; cargo remains on the cart"
		return false
	if route.status.begins_with("Waiting: no traversable route"):
		route.status = "Route reopened; continuing " + route.state
	return route.merchant.has_arrived()


func tick(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta): return
	_post_recovery_jobs()
	for route: Caravan in caravans.values().duplicate():
		var c := route.merchant
		if not sim.buildings_by_id.has(c.home_id): c.home_id = -1
		_feed(route, delta)
		if route.health <= 0.0 or (c is Soldier and c.health <= 0.0):
			_lose(route)
			continue
		if route.promised:
			route.expires_in = maxf(0.0, route.expires_in - delta)
			var reason: String = sim.campaign.trade_access_reason(route.target_id)
			if reason != "" or route.expires_in <= 0.0:
				route.repeat = false
				_return(route, reason if reason != "" else "Offer expired; returning with the goods")
		if sim.water != null and sim.water.handles(c):
			route.cart.follow(world.heightmap,delta,world)
			continue
		match route.state:
			"loading": _load(route, delta)
			"outward":
				var target: Building = sim.campaign.enemy_buildings.get(route.target_id)
				if target == null:
					_return(route, "Destination destroyed; returning with the goods")
				elif _move(route, sim.campaign._door(target), delta):
					route.state = "exchange"
					route.status = "Exchanging timber for iron"
			"exchange": _exchange(route)
			"return":
				var home: Building = sim.buildings_by_id.get(route.origin_id)
				if home == null or home.under_construction: home = sim.keep
				if home == null:
					route.state = "unloading"
				elif _move(route, sim.entrance_of(home, "att_cart_bay"), delta):
					route.state = "unloading"
					route.status = "Unloading at home"
			"unloading": _unload(route, delta)
			"waiting":
				if not route.repeat:
					_finish(route)
				else:
					_try_repeat(route)
					if route.state == "waiting":
						var counter := _source(Config.Res.FOOD, Config.MEAL_FOOD, c.global_position)
						if counter != null: _move(route, sim.entrance_of(counter, "att_cart_bay"), delta)
		if is_instance_valid(route) and caravans.has(route.id):
			route.cart.follow(world.heightmap, delta, world)
			route.merchant.task_label = route.status


func _feed(route: Caravan, delta: float) -> void:
	var need := delta / Config.DAY_LENGTH * Config.HUNGER_PER_DAY
	var eaten := minf(route.provisions, need)
	route.provisions -= eaten
	need -= eaten
	var c := route.merchant
	if need > 0 and c is Soldier:
		eaten = minf(c.rations, need)
		c.rations -= eaten
		need -= eaten
	if need > 0 and route.state in ["loading", "unloading", "waiting"]:
		for b in sim.stores.buildings_storing(Config.Res.FOOD):
			if b.under_construction or b.available(Config.Res.FOOD) <= 0: continue
			if c.global_position.distance_to(sim.entrance_of(b, "att_cart_bay")) > Config.ARRIVE_RADIUS + 0.25: continue
			eaten = b.remove(Config.Res.FOOD, minf(need, b.available(Config.Res.FOOD)))
			need -= eaten
			if need <= 0: break
	if need > 0 and c.carrying_res == Config.Res.FOOD:
		eaten = minf(c.carrying_amount, need)
		c.carrying_amount -= eaten
		need -= eaten
		if c.carrying_amount <= 0.00001: c.drop()
	c.hunger = clampf(c.hunger + need - (delta / Config.DAY_LENGTH - need), 0.0, 1.0)
	if c.hunger >= 1.0:
		if c is Soldier: c.apply_damage(delta * 0.15)
		else: route.health = maxf(0.0, route.health - delta * 0.15)
	c.next_meal = Config.next_meal_after(sim.day)


func _load(route: Caravan, delta: float) -> void:
	var food_stage := route.loading_stage == "food"
	if route.loading_stage == "market":
		var market := _market(route.origin_id)
		if market == null:
			_return(route, "Origin market lost; returning with the goods")
		elif _move(route, sim.entrance_of(market, "att_cart_bay"), delta):
			route.state = "outward"
			route.status = "Carrying timber to " + sim.campaign.rival_name
		return
	var b: Building = sim.buildings_by_id.get(route.food_source_id if food_stage else route.source_id)
	if b == null or b.under_construction:
		_return(route, "Loading store unavailable; returning with the goods")
		return
	if not _move(route, sim.entrance_of(b, "att_cart_bay"), delta): return
	var amount := route.pack_amount if food_stage else route.export_amount
	var res := Config.Res.FOOD if food_stage else EXPORT
	if b.inventory[res] + 0.0001 < amount or b.reserved[res] + 0.0001 < amount:
		_return(route, "Promised loading stock is missing; returning")
		return
	if food_stage and sim.stores.spendable(Config.Res.FOOD) < sim.population_members().size() * HOME_FOOD_DAYS:
		_return(route, "Food at home fell below the two-day floor; returning")
		return
	b.reserved[res] = maxf(0.0, b.reserved[res] - amount)
	var taken := b.remove(res, amount)
	if food_stage:
		route.food_reserved = false
		route.provisions += taken
		route.loading_stage = "timber"
		route.status = "Collecting the timber load"
	else:
		route.source_reserved = false
		route.cargo_res = EXPORT
		route.cargo_amount = taken
		route.cart.load_goods(EXPORT)
		route.loading_stage = "market"
		route.status = "Departing through the market"
	route.merchant.clear_goal()


func _exchange(route: Caravan) -> void:
	if not route.promised or route.cargo_res != EXPORT or not is_equal_approx(route.cargo_amount, route.export_amount):
		_return(route, "Offer no longer matches the load; returning with the goods")
		return
	var reason: String = sim.campaign.exchange_trade(route.target_id, route.export_amount, route.import_amount)
	if reason != "":
		_return(route, reason)
		return
	route.promised = false
	route.cargo_res = IMPORT
	route.cargo_amount = route.import_amount
	route.cart.load_goods(IMPORT)
	route.completed_trips += 1
	_return(route, "Bringing iron home")


func _unload(route: Caravan, delta: float) -> void:
	var c := route.merchant
	var personal := route.cargo_amount <= 0.00001 and c.carrying_amount > 0.00001
	var res := route.cargo_res if route.cargo_amount > 0.00001 else c.carrying_res if personal else Config.Res.FOOD
	var amount := route.cargo_amount if route.cargo_amount > 0.00001 else c.carrying_amount if personal else route.provisions
	if amount <= 0.00001:
		if route.repeat:
			route.state = "waiting"
			_try_repeat(route)
		else: _finish(route)
		return
	var b := sim.stores.find_store(res, c.global_position, -1)
	if b == null:
		route.status = "Waiting: no reachable storage space; goods remain on the cart"
		return
	if not _move(route, sim.entrance_of(b, "att_cart_bay"), delta): return
	var put := b.add(res, amount)
	if route.cargo_amount > 0.00001:
		route.cargo_amount = maxf(0.0, route.cargo_amount - put)
		if route.cargo_amount <= 0.00001:
			route.cargo_res = -1
			route.cart.unload()
	elif personal:
		c.carrying_amount = maxf(0.0, c.carrying_amount - put)
		if c.carrying_amount <= 0.00001: c.drop()
	else: route.provisions = maxf(0.0, route.provisions - put)
	c.clear_goal()
	_refresh()


func _try_repeat(route: Caravan) -> void:
	var q: Dictionary = quotes(route.origin_id, route.merchant)[0]
	if not q.ok:
		route.status = "Repeat paused: " + String(q.reason)
		return
	if not sim.campaign.reserve_trade(q.target_id, q.import_amount):
		route.status = "Repeat paused: promised stock changed"
		return
	_accept_quote(route, q)


func _finish(route: Caravan) -> void:
	_release(route)
	caravans.erase(route.id)
	var c := route.merchant
	route.cart.release(world.heightmap, world)
	c._body.remove_meta("caravan_id")
	sim.return_from_service(c, c.id)
	sim.alert.emit("%s returned from trading (%d completed exchanges)." % [c.given_name, route.completed_trips], c.global_position)
	route.queue_free()
	_refresh()


func _lose(route: Caravan) -> void:
	_release(route)
	var c := route.merchant
	var cargo := PackedFloat32Array()
	cargo.resize(Config.RES_COUNT)
	if route.cargo_res >= 0: cargo[route.cargo_res] += route.cargo_amount
	cargo[Config.Res.FOOD] += route.provisions
	if c.carrying_res >= 0: cargo[c.carrying_res] += c.carrying_amount
	if c is Soldier: cargo[Config.Res.FOOD] += c.rations
	var wreck := {"id": route.id, "position": c.global_position, "cargo": cargo, "name": c.given_name, "recovery_requested": false}
	wrecks.append(wreck)
	_draw_wreck(wreck)
	var home: Building = sim.buildings_by_id.get(c.home_id)
	if home != null: home.residents.erase(c.id)
	caravans.erase(route.id)
	sim.alert.emit("%s died on the trading route. The loaded cart remains at the incident site." % c.given_name, c.global_position)
	route.queue_free()
	sim.workforce.mark_all_dirty()
	_refresh()


func _draw_wreck(wreck: Dictionary) -> void:
	var abandoned := Cart.new()
	add_child(abandoned)
	abandoned.setup(registry, wreck.position)
	abandoned.name = "lost_cart_%d" % wreck.id
	abandoned.set_meta("wreck_id", wreck.id)
	for res in Config.RES_COUNT:
		if wreck.cargo[res] > 0:
			abandoned.load_goods(res)
			break


## Bridge evacuation moves the physical wreck, its saved cargo and every
## outstanding recovery errand together. Cargo stays on the same cart.
func relocate_wreck(wreck_id: int, position: Vector3) -> void:
	var wreck := _wreck(wreck_id)
	if wreck.is_empty(): return
	wreck.position = position
	var cart: Cart = get_node_or_null("lost_cart_%d" % wreck_id)
	if cart != null:
		cart.global_position = position
		cart.parked_at = position
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.SALVAGE and job.wreck_id == wreck_id:
			job.position = position
			job.refused_by.clear()
			var worker: Citizen = sim.citizens_by_id.get(job.claimed_by)
			if worker != null and worker.job == job:
				worker.clear_goal()


func transit(res: int) -> float:
	var amount := 0.0
	for route in caravans.values():
		if route.cargo_res == res: amount += route.cargo_amount
		if res == Config.Res.FOOD: amount += route.provisions
	return amount


func _refresh() -> void:
	sim.stores.refresh_totals(sim.population_members(), sim.buildings)
	sim._update_stats()


func info() -> Dictionary:
	var rows: Array = []
	for route in caravans.values():
		rows.append({"id": route.id, "name": route.merchant.given_name, "state": route.state,
			"status": route.status, "repeat": route.repeat, "position": route.merchant.global_position,
			"cargo_res": route.cargo_res, "cargo_amount": route.cargo_amount,
			"provisions": route.provisions, "capacity": Cart.CAPACITY, "completed_trips": route.completed_trips})
	return {"merchants": caravans.size(), "count": caravans.size(), "caravans": rows,
		"quote": quotes()[0], "wrecks": wrecks.size(), "lost_carts": wrecks.duplicate(true)}


func capture() -> Dictionary:
	var entries: Array = []
	for route in caravans.values():
		var entry: Dictionary = route.record()
		if not sim.buildings_by_id.has(entry.citizen.home_id): entry.citizen.home_id = -1
		entries.append(entry)
	return {"next_id": _next_id, "caravans": entries, "wrecks": wrecks.duplicate(true)}


func restore(data: Variant) -> String:
	var problem := validate(data, world.size_m, sim.buildings_by_id)
	if problem != "": return problem
	var imports := {}
	for entry in data.get("caravans", []):
		var person_id: int = entry.citizen.id
		if sim.citizens_by_id.has(person_id): return "merchant is already in the civilian workforce"
		if sim.campaign != null and sim.campaign._civilian_ids.values().has(person_id): return "merchant is already serving as a soldier"
		if entry.promised:
			if sim.campaign == null: return "promised trade requires a neighboring campaign"
			var target: Building = sim.campaign.enemy_buildings.get(entry.target_id)
			if target != null:
				imports[entry.target_id] = float(imports.get(entry.target_id, 0)) + entry.import_amount
				if imports[entry.target_id] > target.inventory[IMPORT] + 0.001: return "trade reservations exceed destination stock"
	for job in sim.jobs.all_jobs():
		if job.kind != JobBoard.Kind.SALVAGE: continue
		var worker: Citizen = sim.citizens_by_id.get(job.claimed_by)
		if worker != null and worker.job == job: sim._retire_job(worker)
		else: sim.jobs.cancel(job)
	for route in caravans.values():
		_release(route)
		var home: Building = sim.buildings_by_id.get(route.merchant.home_id)
		if home != null: home.residents.erase(route.merchant.id)
	for child in get_children(): child.free()
	caravans.clear()
	wrecks.clear()
	_next_id = int(data.get("next_id", 1))
	for entry in data.get("caravans", []):
		var identity: Dictionary = entry.citizen
		var c := sim.add_citizen(identity.position, false, identity.asset_id, identity.id, identity.get("body", {}))
		c.apply_state(identity, registry)
		c.position = identity.position
		var home: Building = sim.buildings_by_id.get(c.home_id)
		if home != null and not home.residents.has(c.id): home.residents.append(c.id)
		if c is Soldier: c.rations = identity.get("veteran_rations", 0.0)
		sim.detach_for_service(c)
		var route := Caravan.new()
		add_child(route)
		route.setup(entry.id, c, registry)
		for key in route.record():
			if key not in ["id", "citizen", "cart_position"]: route.set(key, entry[key])
		route.cart.global_position = entry.cart_position
		if route.cargo_res >= 0: route.cart.load_goods(route.cargo_res)
		caravans[route.id] = route
		if route.promised:
			var target: Building = sim.campaign.enemy_buildings.get(route.target_id)
			if target != null: target.reserved[IMPORT] += route.import_amount
		if route.source_reserved:
			var source: Building = sim.buildings_by_id.get(route.source_id)
			if source != null: source.reserved[EXPORT] += route.export_amount
		if route.food_reserved:
			var source: Building = sim.buildings_by_id.get(route.food_source_id)
			if source != null: source.reserved[Config.Res.FOOD] += route.pack_amount
	wrecks = data.get("wrecks", []).duplicate(true)
	for wreck in wrecks:
		wreck.recovery_requested = wreck.get("recovery_requested", false)
		_draw_wreck(wreck)
	_refresh()
	return ""


static func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and value >= minimum and value <= maximum


static func _position(value: Variant, size_m: float) -> bool:
	return value is Vector3 and value.is_finite() and value.x >= 0 and value.z >= 0 and value.x <= size_m and value.z <= size_m and absf(value.y) < 10000


static func validate(data: Variant, world_size: float = 768.0, friendly_buildings: Variant = null) -> String:
	if not data is Dictionary: return "trade must be a dictionary"
	if data.is_empty(): return ""
	if not data.get("next_id") is int or not _number(data.next_id, 1, 2147483647): return "invalid trade next identifier"
	if not data.get("caravans") is Array or data.caravans.size() > MAX_ROUTES: return "invalid caravan list"
	if not data.get("wrecks", []) is Array or data.get("wrecks", []).size() > 65536: return "invalid lost-cart list"
	var ids := {}
	var people := {}
	var reservations := {}
	for route in data.caravans:
		if not route is Dictionary: return "invalid caravan record"
		for key in ["id", "citizen", "origin_id", "target_id", "source_id", "food_source_id", "state", "loading_stage", "status", "repeat", "export_amount", "import_amount", "provisions", "pack_amount", "cargo_res", "cargo_amount", "promised", "source_reserved", "food_reserved", "expires_in", "health", "completed_trips", "cart_position"]:
			if not route.has(key): return "caravan missing " + key
		if not route.id is int or route.id < 1 or route.id >= data.next_id or ids.has(route.id): return "invalid caravan identifier"
		ids[route.id] = true
		if not route.citizen is Dictionary or not route.citizen.get("id") is int or people.has(route.citizen.id): return "invalid merchant identity"
		people[route.citizen.id] = true
		for field in ["name", "asset_id", "age", "profession", "home_id", "workplace_id", "hunger", "next_meal", "meals_taken", "morale", "carrying_res", "carrying_amount", "immigrant", "immigrant_target"]:
			if not route.citizen.has(field): return "merchant identity missing " + field
		var identity_error := SaveGame.Validation._citizen(route.citizen, null, world_size)
		if identity_error != "": return "merchant: " + identity_error
		if not _position(route.citizen.get("position"), world_size) or not _position(route.cart_position, world_size): return "invalid caravan position"
		if route.citizen.get("workplace_id", -1) != -1 or route.citizen.get("immigrant", false): return "merchant cannot also work or immigrate"
		for key in ["origin_id", "target_id", "source_id", "food_source_id"]:
			if not route[key] is int or route[key] < 1: return "invalid caravan building reference"
		if not route.state is String or route.state not in STATES or route.loading_stage not in ["food", "timber", "market"]: return "invalid caravan phase"
		if not route.status is String or route.status.length() > 240: return "invalid caravan status"
		for key in ["repeat", "promised", "source_reserved", "food_reserved"]:
			if not route[key] is bool: return "invalid caravan flag"
		for key in ["export_amount", "import_amount", "pack_amount", "provisions", "cargo_amount"]:
			if not _number(route[key], 0, Cart.CAPACITY): return "invalid caravan load"
		if route.export_amount not in [12.0, 24.0] or not is_equal_approx(route.import_amount * 3.0, route.export_amount) or route.pack_amount < 2: return "invalid caravan offer"
		if not route.cargo_res is int or route.cargo_res not in [-1, EXPORT, IMPORT] or ((route.cargo_res == -1) != (route.cargo_amount == 0)): return "invalid caravan cargo"
		if not _number(route.citizen.get("carrying_amount", 0), 0, Cart.CAPACITY) or route.cargo_amount + route.provisions + route.citizen.get("carrying_amount", 0) + route.citizen.get("veteran_rations", 0) > Cart.CAPACITY + 0.001: return "overloaded caravan"
		if route.provisions > route.pack_amount or (route.cargo_res == EXPORT and route.cargo_amount > route.export_amount) or (route.cargo_res == IMPORT and route.cargo_amount > route.import_amount): return "caravan load exceeds paid quantities"
		if not _number(route.expires_in, 0, 1e9) or not _number(route.health, 0, 100) or not route.completed_trips is int or not _number(route.completed_trips, 0, 1000000): return "invalid caravan accounting"
		if route.promised != (route.state in ["loading", "outward", "exchange"]): return "caravan reservation does not match phase"
		if route.source_reserved != (route.state == "loading" and route.loading_stage in ["food", "timber"]): return "caravan loading reservation does not match phase"
		if route.food_reserved != (route.state == "loading" and route.loading_stage == "food"): return "caravan provision reservation does not match phase"
		if route.state in ["outward", "exchange"] and (route.cargo_res != EXPORT or route.cargo_amount != route.export_amount): return "outward caravan lacks its paid load"
		if route.state == "loading" and route.loading_stage != "market" and route.cargo_amount != 0: return "uncollected caravan already has cargo"
		if route.state == "loading" and route.loading_stage == "market" and (route.cargo_res != EXPORT or route.cargo_amount != route.export_amount): return "loaded caravan lacks its paid timber"
		if route.food_reserved and route.provisions > 0: return "uncollected caravan already has provisions"
		if route.state == "waiting" and (route.cargo_amount > 0 or route.provisions > 0 or route.citizen.get("carrying_amount", 0) > 0): return "idle repeat caravan still has undelivered cargo"
		if route.cargo_res == IMPORT and route.completed_trips < 1: return "import cargo has no completed exchange"
		if friendly_buildings != null:
			for item in [[route.source_reserved, route.source_id, EXPORT, route.export_amount], [route.food_reserved, route.food_source_id, Config.Res.FOOD, route.pack_amount]]:
				if not item[0]: continue
				var b: Variant = friendly_buildings.get(item[1])
				# A destroyed source is a valid interruption, but existing stores cannot promise the same stock twice.
				if b == null: continue
				var key := "%d:%d" % [item[1], item[2]]
				reservations[key] = float(reservations.get(key, 0)) + float(item[3])
				if reservations[key] > b.inventory[item[2]] + 0.001: return "trade reservations exceed origin stock"
	for wreck in data.get("wrecks", []):
		if not wreck is Dictionary or not wreck.get("id") is int or wreck.id < 1 or wreck.id >= data.next_id or ids.has(wreck.id): return "invalid lost-cart identifier"
		ids[wreck.id] = true
		if not wreck.get("recovery_requested", false) is bool: return "invalid lost-cart recovery order"
		if not _position(wreck.get("position"), world_size) or not wreck.get("name") is String or wreck.name.length() > 160: return "invalid lost-cart identity"
		if not wreck.get("cargo") is PackedFloat32Array or wreck.cargo.size() != Config.RES_COUNT: return "invalid lost-cart cargo"
		var total := 0.0
		for amount in wreck.cargo:
			if not _number(amount, 0, Cart.CAPACITY + 4): return "invalid lost-cart stock"
			total += amount
		if total > Cart.CAPACITY + 4.001: return "overloaded lost cart"
	return ""


func _wreck(wreck_id: int) -> Dictionary:
	for wreck in wrecks:
		if wreck.id == wreck_id: return wreck
	return {}


func request_recovery(wreck_id: int) -> String:
	var wreck := _wreck(wreck_id)
	if wreck.is_empty(): return "That lost cart has already been emptied."
	wreck.recovery_requested = true
	_post_recovery_jobs()
	sim.stats_changed.emit()
	return ""


func cancel_recovery(wreck_id: int) -> String:
	var wreck := _wreck(wreck_id)
	if wreck.is_empty(): return "That lost cart has already been emptied."
	wreck.recovery_requested = false
	for job in sim.jobs.all_jobs():
		if job.kind != JobBoard.Kind.SALVAGE or job.wreck_id != wreck_id: continue
		var c: Citizen = sim.citizens_by_id.get(job.claimed_by)
		if c != null and c.job == job: sim._retire_job(c)
		else: sim.jobs.cancel(job)
	sim.stats_changed.emit()
	return ""


func _post_recovery_jobs() -> void:
	if wrecks.is_empty(): return
	var pending := {}
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.SALVAGE:
			pending[Vector2i(job.wreck_id, job.res)] = true
	for wreck in wrecks:
		if not wreck.get("recovery_requested", false): continue
		for res in Config.RES_COUNT:
			if wreck.cargo[res] <= 0.00001 or pending.has(Vector2i(wreck.id, res)): continue
			if sim.stores.find_store(res, wreck.position, -1) == null: continue
			var job := sim.jobs.post(JobBoard.Kind.SALVAGE, wreck.position, 72.0)
			job.wreck_id = wreck.id
			job.res = res
			job.amount = minf(Config.CARRY_CAPACITY, wreck.cargo[res])
			sim.jobs.index(job)


func tick_recovery(c: Citizen, delta: float) -> void:
	var job := c.job
	if job == null: return
	var wreck := _wreck(job.wreck_id)
	if wreck.is_empty() or not wreck.get("recovery_requested", false) or c.carrying_amount > 0:
		sim._retire_job(c)
		return
	c.set_goal(wreck.position)
	c.advance(delta, world)
	if not c.has_arrived(): return
	# A disappeared crossing can resolve a goal onto its bank. Collection
	# still requires reaching the physical cart, not merely that fallback.
	if Vector2(c.global_position.x - wreck.position.x, c.global_position.z - wreck.position.z).length() > Config.ARRIVE_RADIUS + 0.25:
		c.unreachable = true
		sim._abandon(c)
		return
	var amount := minf(job.amount, wreck.cargo[job.res])
	wreck.cargo[job.res] = maxf(0.0, wreck.cargo[job.res] - amount)
	job.loaded = true
	if amount > 0: c.pick_up(job.res, amount, registry)
	sim.jobs.complete(job)
	sim._go_idle(c)
	var remaining := 0.0
	for value in wreck.cargo: remaining += value
	if remaining <= 0.00001:
		wrecks.erase(wreck)
		var visual := get_node_or_null("lost_cart_%d" % wreck.id)
		if visual != null: visual.queue_free()
	# Carrying survives retirement and saves. The normal stray-load behavior
	# walks it into storage, even if recovery is canceled after collection.
	_refresh()
