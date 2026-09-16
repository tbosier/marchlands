class_name Workforce
extends RefCounted

## Who works where, and who lives where.
##
## The previous version cleared every workplace and every household and rebuilt
## the lot from scratch — on every building placement, every immigrant arrival
## and every completed construction. That was O(buildings x citizens log
## citizens) each time, and worse than the cost: a citizen's job was never
## stable, because a reshuffle could hand their post to someone who happened to
## be standing closer that second.
##
## Assignment is now incremental. Only citizens who actually lack a post are
## placed, only vacancies are filled, and an existing assignment is disturbed
## only when the building it refers to goes away.

var _dirty_work := true
var _dirty_homes := true


func mark_work_dirty() -> void:
	_dirty_work = true


func mark_homes_dirty() -> void:
	_dirty_homes = true


func mark_all_dirty() -> void:
	_dirty_work = true
	_dirty_homes = true


## Run pending assignment passes. Cheap when nothing has changed. Returns true
## when employment actually moved, so callers can react to the new staffing.
func update(buildings: Array[Building], citizens: Array[Citizen],
			by_id: Dictionary) -> bool:
	var work_ran := false
	if _dirty_work:
		_dirty_work = false
		_assign_work(buildings, citizens, by_id)
		work_ran = true
	if _dirty_homes:
		_dirty_homes = false
		_assign_homes(buildings, citizens, by_id)
	return work_ran


# ---------------------------------------------------------------------------
# Employment
# ---------------------------------------------------------------------------

func _assign_work(buildings: Array[Building], citizens: Array[Citizen],
				  by_id: Dictionary) -> void:
	Perf.begin("workforce.work")

	# Drop assignments whose building has gone, finished differently, or is no
	# longer a workplace. Everything else is left exactly as it was.
	var unemployed: Array[Citizen] = []
	for c in citizens:
		if c.immigrant:
			continue
		var place: Building = by_id.get(c.workplace_id)
		if place == null or place.under_construction \
				or place.def.worker_slots <= 0 or not place.workers.has(c.id):
			# Take them off the building's roll as well as out of their own
			# post. Standing someone down while leaving their id in `workers`
			# left the slot occupied by nobody: an upgrading workshop reopened
			# with its old staff still listed, re-hired the same people into
			# the vacancies below, and ended up with each of them on the roll
			# twice — full to the eye, half-staffed in fact, and charging tool
			# wear for the phantoms.
			if place != null:
				place.workers.erase(c.id)
			c.workplace_id = -1
			c.profession = "labourer"
			unemployed.append(c)

	if unemployed.is_empty():
		Perf.end("workforce.work")
		return

	# Fill vacancies, nearest willing worker first. Sorting the (usually tiny)
	# vacancy list rather than the whole population is what makes this cheap.
	for b in buildings:
		if b.under_construction or b.def.worker_slots <= 0:
			continue
		while b.workers.size() < b.def.worker_slots and not unemployed.is_empty():
			var best_index := -1
			var best_d := INF
			for i in unemployed.size():
				var d: float = unemployed[i].global_position \
						.distance_squared_to(b.global_position)
				if d < best_d:
					best_d = d
					best_index = i
			if best_index < 0:
				break
			var hired: Citizen = unemployed[best_index]
			unemployed.remove_at(best_index)
			# Belt and braces against a roll that already names them: take the
			# post, but do not appear on the roll twice.
			if not b.workers.has(hired.id):
				b.workers.append(hired.id)
			hired.workplace_id = b.id
			hired.profession = b.def.profession

	Perf.end("workforce.work")


## Called when a building stops being a workplace, so its staff are freed.
func release_workers(b: Building, by_id: Dictionary) -> void:
	for cid in b.workers:
		var c: Citizen = by_id.get(cid)
		if c:
			c.workplace_id = -1
			c.profession = "labourer"
	b.workers.clear()
	_dirty_work = true


# ---------------------------------------------------------------------------
# Housing
# ---------------------------------------------------------------------------

func _assign_homes(buildings: Array[Building], citizens: Array[Citizen],
				   by_id: Dictionary) -> void:
	Perf.begin("workforce.homes")

	var homeless: Array[Citizen] = []
	for c in citizens:
		if c.immigrant:
			continue
		var home: Building = by_id.get(c.home_id)
		if home == null or home.under_construction \
				or not home.residents.has(c.id):
			# Same reasoning as the workplace roll above: leave the id behind
			# and the house is permanently full of a resident who lives
			# somewhere else.
			if home != null:
				home.residents.erase(c.id)
			c.home_id = -1
			homeless.append(c)

	if homeless.is_empty():
		Perf.end("workforce.homes")
		return

	var vacancies: Array[Building] = []
	for b in buildings:
		if not b.under_construction and b.has_house_space():
			vacancies.append(b)

	for c in homeless:
		var best: Building = null
		var best_d := INF
		for b in vacancies:
			if not b.has_house_space():
				continue
			# People settle near where they already are, which is why a new
			# quarter of town fills from the side nearest the old one.
			var d := c.global_position.distance_squared_to(b.global_position)
			if d < best_d:
				best_d = d
				best = b
		if best == null:
			break
		if not best.residents.has(c.id):
			best.residents.append(c.id)
		c.home_id = best.id

	Perf.end("workforce.homes")


func release_residents(b: Building, by_id: Dictionary) -> void:
	for cid in b.residents:
		var c: Citizen = by_id.get(cid)
		if c:
			c.home_id = -1
	b.residents.clear()
	_dirty_homes = true
