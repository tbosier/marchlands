class_name Stores
extends RefCounted

## An index over everything in the settlement that holds goods.
##
## Two jobs, both about not repeatedly walking the whole building list:
##
##   * per-resource buckets, so "where can this timber go?" scans the handful
##     of buildings that store timber rather than every structure on the map;
##   * running totals, recomputed once per tick, so the interface can ask what
##     the kingdom owns as often as it likes.
##
## Before this existed the resource readout alone triggered seventeen full
## scans of the building and citizen lists every quarter second.

var _by_resource: Array = []           # res -> Array[Building]
var _all: Array[Building] = []
var _totals := PackedFloat32Array()
var _carried := PackedFloat32Array()
var _larder := PackedFloat32Array()
var trade: Node
var scouting: Node
var water: Node
var _nav: NavGrid
var _access_point: Callable


func _init() -> void:
	_totals.resize(Config.RES_COUNT)
	_carried.resize(Config.RES_COUNT)
	_larder.resize(Config.RES_COUNT)
	for i in Config.RES_COUNT:
		_by_resource.append([] as Array[Building])


func setup_navigation(nav: NavGrid, access_point: Callable) -> void:
	_nav = nav
	_access_point = access_point


func _reachable(from: Vector3, building: Building) -> bool:
	if _nav == null:
		return true
	var door: Vector3 = _access_point.call(building, "att_cart_bay")
	return _nav.can_reach(from, door)


# --- Membership -------------------------------------------------------------

func register(b: Building) -> void:
	if _all.has(b):
		return
	if not b.def.is_storage():
		return
	_all.append(b)
	for res in b.def.stores:
		_by_resource[res].append(b)


func unregister(b: Building) -> void:
	_all.erase(b)
	for res in b.def.stores:
		_by_resource[res].erase(b)


func buildings_storing(res: int) -> Array:
	return _by_resource[res]


# --- Totals -----------------------------------------------------------------

## Recompute the kingdom's stock. One pass per tick, not one per query.
func refresh_totals(citizens: Array[Citizen],
					buildings: Array[Building]) -> void:
	for i in Config.RES_COUNT:
		_totals[i] = 0.0
		_carried[i] = 0.0
		_larder[i] = 0.0
	for b in _all:
		# Counted even while the building is on the stocks. A granary being
		# grown into a warehouse still physically holds its grain; leaving it
		# out made the settlement appear to lose everything in it the moment
		# the upgrade started, which was enough to raise a famine warning and
		# throttle immigration over a building the player had just improved.
		# Lookups are what must skip it, and `find_source`, `find_store` and
		# `spend` all do.
		for res in b.def.stores:
			_totals[res] += b.inventory[res]
	# Household larders are real food the march owns, but they are not stock.
	# They cannot be spent, hauled, or requisitioned for a building site —
	# only eaten by the people who live there — so they are counted for the
	# readout and deliberately kept out of `spendable`.
	for b in buildings:
		if b.larder > 0.0:
			_larder[Config.Res.FOOD] += b.larder
	if is_instance_valid(trade):
		for res in Config.RES_COUNT:
			_carried[res] += trade.transit(res)
	if is_instance_valid(scouting):
		for res in Config.RES_COUNT: _carried[res] += scouting.transit(res)
	if is_instance_valid(water):
		for res in Config.RES_COUNT: _carried[res] += water.transit(res)
	for c in citizens:
		if c.carrying_res >= 0 and c.carrying_amount > 0.0:
			_carried[c.carrying_res] += c.carrying_amount
		if c is Soldier:
			_carried[Config.Res.FOOD] += c.rations


## What the kingdom owns, counting loads being carried and food already in
## people's larders. Use for display.
func total(res: int) -> float:
	return _totals[res] + _carried[res] + _larder[res]

## What can actually be spent right now — goods sitting in a building. A load
## on someone's back is real, but no clerk can requisition it, and counting it
## let road works be commissioned and then paid for with nothing.
func spendable(res: int) -> float:
	var stock := 0.0
	for b in _by_resource[res]:
		stock += b.available(res)
	return stock

func can_afford(cost: Dictionary) -> bool:
	for res in cost:
		if spendable(res) < float(cost[res]):
			return false
	return true


## Spend, reporting whether the full cost was actually met.
func try_spend(cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	spend(cost)
	return true


## Written by `spend`, when the simulation hands one over. See ResourceLedger.
var ledger: ResourceLedger


## Take `cost` out of the settlement's stores, nearest-to-dearest order
## unspecified — this is for abstracted spending (road works), not hauling.
func spend(cost: Dictionary) -> void:
	# Payment is synchronous: validate every resource before removing any,
	# using live, unpromised stock rather than the interface's tick snapshot.
	if not can_afford(cost):
		return
	for res in cost:
		var remaining := float(cost[res])
		for b in _by_resource[res]:
			if remaining <= 0.0:
				break
			# Deliberately *not* skipping a building under construction. The
			# only ones in this index are mid-upgrade — a newly placed store
			# is not registered until it is finished — and their stock is
			# counted by `refresh_totals`. Counting goods the settlement then
			# refused to hand over meant `can_afford` could say yes and `spend`
			# quietly take less, which bought road works for nothing.
			remaining -= b.remove(res, minf(remaining, b.available(res)))
		_totals[res] = maxf(0.0, _totals[res] - (float(cost[res]) - remaining))
		if ledger != null:
			ledger.used(int(res), float(cost[res]) - remaining)


# --- Lookup -----------------------------------------------------------------

## The best building to take `res` out of, near `from`.
func find_source(res: int, from: Vector3, want: float, exclude_id: int = -1) -> Building:
	var best: Building = null
	var best_score := -INF
	for b in _by_resource[res]:
		if b.under_construction or b.id == exclude_id:
			continue
		var have: float = b.available(res)
		if have < minf(want, 1.0):
			continue
		var score := -from.distance_to(b.global_position)
		if have >= want:
			score += 40.0
		if score > best_score and _reachable(from, b):
			best_score = score
			best = b
	return best


## Vendors and quartermasters replenish from genuine surplus. Keep enough at
## each source for its local households and meals.
func market_surplus(source: Building) -> float:
	var local_reserve := maxf(float(Config.CARRY_CAPACITY),
			float(source.def.houses) * Config.HUNGER_PER_DAY * Config.LARDER_DAYS)
	if source.def.is_farm():
		local_reserve = maxf(local_reserve, source.capacity() * 0.2)
	return maxf(0.0, source.available(Config.Res.FOOD) - local_reserve)


func find_market_source(market: Building) -> Building:
	if not market.def.is_food_depot():
		return null
	var best: Building = null
	var best_distance := INF
	var seat: Building = null
	for building in _all:
		if building.def.role == BuildingDefs.Role.SEAT:
			seat = building
			break
	for source in _by_resource[Config.Res.FOOD]:
		if source.under_construction \
				or source.id == market.id or market_surplus(source) < 1.0:
			continue
		var distance := market.global_position.distance_squared_to(source.global_position)
		if market.def.is_market() and source.def.is_food_depot():
			continue
		if market.def.role == BuildingDefs.Role.SUPPLY:
			if distance > Building.SUPPLY_RELAY_RANGE * Building.SUPPLY_RELAY_RANGE:
				continue
			if source.def.is_food_depot() and (seat == null or
					source.position.distance_squared_to(seat.position)
					>= market.position.distance_squared_to(seat.position)):
				continue
		if distance < best_distance and _reachable(market.global_position, source):
			best_distance = distance
			best = source
	return best


## The best building to put `res` into, near `from`. Dedicated storage is
## preferred over the incidental capacity a workshop happens to have.
func find_store(res: int, from: Vector3, exclude_id: int) -> Building:
	var best: Building = null
	var best_score := -INF
	for b in _by_resource[res]:
		if b.under_construction or b.id == exclude_id:
			continue
		# A workshop's store is its bench, not a warehouse. Letting general
		# deliveries fill it packed the forge with ninety timber and no iron,
		# and it stopped working. Workshops pull exactly what they need
		# themselves, in Production._post_crafting.
		if b.def.is_workshop() or b.def.is_food_depot() or b.def.is_ranch():
			continue
		if b.space_for(res) < 1.0:
			continue
		var score := -from.distance_to(b.global_position)
		match b.def.role:
			BuildingDefs.Role.STORAGE, BuildingDefs.Role.GRANARY:
				score += 60.0
			BuildingDefs.Role.SEAT:
				score += 30.0
		if score > best_score and _reachable(from, b):
			best_score = score
			best = b
	return best


## True when there is nowhere left in the kingdom to put this resource.
func is_full_for(res: int) -> bool:
	for b in _by_resource[res]:
		if not b.under_construction and not b.def.is_food_depot() and b.space_for(res) >= 1.0:
			return false
	return true


## Consume food from wherever it is held. Returns the amount that could not be
## found, which is how famine is detected.
func consume(res: int, amount: float) -> float:
	var remaining := amount
	for b in _by_resource[res]:
		if remaining <= 0.0:
			break
		# Same reasoning as `spend`: grain in a granary that is being extended
		# is still grain, and `food_days_remaining` has already counted it. If
		# this skipped it, the march would starve staring at a full larder.
		remaining -= b.remove(res, remaining)
	return maxf(0.0, remaining)
