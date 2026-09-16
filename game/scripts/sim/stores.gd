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


func _init() -> void:
	_totals.resize(Config.RES_COUNT)
	_carried.resize(Config.RES_COUNT)
	for i in Config.RES_COUNT:
		_by_resource.append([] as Array[Building])


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
func refresh_totals(citizens: Array[Citizen]) -> void:
	for i in Config.RES_COUNT:
		_totals[i] = 0.0
		_carried[i] = 0.0
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
	for c in citizens:
		if c.carrying_res >= 0 and c.carrying_amount > 0.0:
			_carried[c.carrying_res] += c.carrying_amount


## What the kingdom owns, counting loads being carried. Use for display.
func total(res: int) -> float:
	return _totals[res] + _carried[res]


## What can actually be spent right now — goods sitting in a building. A load
## on someone's back is real, but no clerk can requisition it, and counting it
## let road works be commissioned and then paid for with nothing.
func spendable(res: int) -> float:
	return _totals[res]


func in_transit(res: int) -> float:
	return _carried[res]


func can_afford(cost: Dictionary) -> bool:
	for res in cost:
		if _totals[res] < float(cost[res]):
			return false
	return true


## Spend, reporting whether the full cost was actually met.
func try_spend(cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	spend(cost)
	return true


## Take `cost` out of the settlement's stores, nearest-to-dearest order
## unspecified — this is for abstracted spending (road works), not hauling.
func spend(cost: Dictionary) -> void:
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
			remaining -= b.remove(res, remaining)
		_totals[res] = maxf(0.0, _totals[res] - (float(cost[res]) - remaining))


# --- Lookup -----------------------------------------------------------------

## The best building to take `res` out of, near `from`.
func find_source(res: int, from: Vector3, want: float) -> Building:
	var best: Building = null
	var best_score := -INF
	for b in _by_resource[res]:
		if b.under_construction:
			continue
		var have: float = b.available(res)
		if have < minf(want, 1.0):
			continue
		var score := -from.distance_to(b.global_position)
		if have >= want:
			score += 40.0
		if score > best_score:
			best_score = score
			best = b
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
		if b.def.is_workshop():
			continue
		if b.space_for(res) < 1.0:
			continue
		var score := -from.distance_to(b.global_position)
		match b.def.role:
			BuildingDefs.Role.STORAGE, BuildingDefs.Role.GRANARY:
				score += 60.0
			BuildingDefs.Role.SEAT:
				score += 30.0
		if score > best_score:
			best_score = score
			best = b
	return best


## True when there is nowhere left in the kingdom to put this resource.
func is_full_for(res: int) -> bool:
	for b in _by_resource[res]:
		if not b.under_construction and b.space_for(res) >= 1.0:
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
