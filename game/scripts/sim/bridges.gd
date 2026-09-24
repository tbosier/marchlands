class_name Bridges
extends Node3D

## A bridge owns materials and work, not people. The ordinary job board sends
## real carriers and builders to the first bank; only completed work changes
## navigation. Incoming reservations are transient and rebuilt after loading.
const MIN_SPAN := 8.0
const MAX_SPAN := 64.0
const MAX_SLOPE := 0.18
const WIDTH := 4.0
const DECK_LIFT := 0.35
const MAX_BRIDGES := 128

var sim: Simulation
var world: World
var registry: AssetRegistry
var bridges: Dictionary = {}
var _visuals: Dictionary = {}
var _next_id := 1
var _review := 0.0


func setup(simulation: Simulation, terrain: World, assets: AssetRegistry) -> void:
	sim = simulation
	world = terrain
	registry = assets


static func _length(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func _cost(length: float) -> Dictionary:
	return {Config.Res.TIMBER: float(ceili(12.0 + length * 1.5)),
		Config.Res.TOOLS: float(ceili(1.0 + length / 16.0))}


static func _labor(length: float) -> float:
	return 12.0 + length * 3.0


func _bank(at: Vector3) -> Vector3:
	var cell := world.world_to_cell(at)
	var bank := Vector3((cell.x + 0.5) * Config.CELL, 0, (cell.y + 0.5) * Config.CELL)
	bank.y = world.heightmap.height_at(bank.x, bank.z) + DECK_LIFT
	return bank


func _inside(at: Vector3) -> bool:
	return at.is_finite() and at.x >= Config.CELL and at.z >= Config.CELL \
		and at.x < world.size_m - Config.CELL and at.z < world.size_m - Config.CELL


func _dry(at: Vector3) -> bool:
	if not _inside(at):
		return false
	var cell := world.world_to_cell(at)
	return world.heightmap.is_passable(cell.x, cell.y) and not world.nav.is_solid(cell.x, cell.y)


## Validate geography without requiring the two banks already be connected.
## Each bank needs dry ground continuing away from the span; at least one must
## be reachable from the settlement before anyone can deliver its materials.
func _shape_error(a: Vector3, b: Vector3, check_workers: bool = true) -> String:
	if not _inside(a) or not _inside(b):
		return "Choose two banks inside the map"
	var length := _length(a, b)
	if length < MIN_SPAN or length > MAX_SPAN:
		return "Timber bridge span must be between 8 and 64 metres"
	if absf(a.y - b.y) / length > MAX_SLOPE:
		return "Banks are too uneven (maximum deck slope 18%)"
	if not _dry(a) or not _dry(b):
		return "Both entrances need clear, dry banks"
	var direction := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
	var approach_a := a - direction * Config.CELL
	var approach_b := b + direction * Config.CELL
	if not _dry(approach_a) or not _dry(approach_b) \
			or not world.nav.can_reach(a, approach_a) or not world.nav.can_reach(b, approach_b):
		return "Leave a clear approach behind each bank"
	var crossed_water := false
	var left_water := false
	var steps := ceili(length / (Config.CELL * 0.25))
	for i in range(1, steps):
		var t := float(i) / steps
		var at := a.lerp(b, t)
		var cell := world.world_to_cell(at)
		var is_water := world.heightmap.surface[cell.y * world.grid_size + cell.x] == Heightmap.Surface.WATER
		if is_water:
			if left_water:
				return "Cross a single stretch of water between opposite banks"
			crossed_water = true
		else:
			if crossed_water:
				left_water = true
			if world.nav.is_solid(cell.x, cell.y):
				return "Bridge span crosses blocked ground"
			if world.heightmap.height_at(at.x, at.z) > at.y + 0.3:
				return "The deck would pass through raised ground"
	if not crossed_water:
		return "A timber bridge must cross water"
	if check_workers and sim.keep != null:
		var origin := sim.entrance_of(sim.keep, "att_entrance")
		if not world.nav.can_reach(origin, a) and not world.nav.can_reach(origin, b):
			return "Builders cannot reach either bank from the settlement"
	return ""


static func _overlap(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> bool:
	# Lift differences do not permit crossing bridges on the same navigation cell.
	var a2 := Vector3(a.x, 0, a.z)
	var b2 := Vector3(b.x, 0, b.z)
	var c2 := Vector3(c.x, 0, c.z)
	var d2 := Vector3(d.x, 0, d.z)
	var pair := Geometry3D.get_closest_points_between_segments(a2, b2, c2, d2)
	return pair[0].distance_to(pair[1]) < WIDTH + Config.CELL


func quote(first: Vector3, second: Vector3) -> Dictionary:
	if not _inside(first) or not _inside(second):
		return {"ok": false, "reason": "Choose two banks inside the map"}
	var a := _bank(first)
	var b := _bank(second)
	var length := _length(a, b)
	var error := _shape_error(a, b)
	if error == "" and bridges.size() >= MAX_BRIDGES:
		error = "The map already has 128 timber bridges"
	if error == "":
		for record in bridges.values():
			if _overlap(a, b, record.a, record.b):
				error = "Bridge overlaps an existing crossing or construction site"
				break
	if sim.keep != null and error == "":
		var origin := sim.entrance_of(sim.keep, "att_entrance")
		if not world.nav.can_reach(origin, a):
			var swap := a
			a = b
			b = swap
	var saved := -1.0
	if error == "":
		var path := world.nav.find_path(a, b)
		if not path.is_empty():
			var distance := 0.0
			for i in range(1, path.size()):
				distance += path[i - 1].distance_to(path[i])
			saved = maxf(0.0, distance - length)
	return {"ok": error == "", "reason": error, "a": a, "b": b,
		"length": length, "cost": _cost(length), "labor": _labor(length),
		"detour_saved": saved, "width": WIDTH}


func place(a: Vector3, b: Vector3) -> Dictionary:
	var result := quote(a, b)
	if not result.ok:
		return result
	if not sim.stores.can_afford(result.cost):
		return {"ok": false, "reason": "Not enough unreserved timber and tools for this bridge"}
	var id := _next_id
	_next_id += 1
	var record := {"id": id, "a": result.a, "b": result.b,
		"cost": result.cost.duplicate(), "delivered": {}, "incoming": {},
		"work": 0.0, "complete": false}
	bridges[id] = record
	_visual(record)
	_post(record)
	sim.alert.emit("Timber bridge ordered — builders will bring timber and tools to the bank", record.a)
	return {"ok": true, "reason": "", "id": id}


func _visual(record: Dictionary) -> void:
	var visual := BridgeVisual.new()
	add_child(visual)
	visual.setup(record.id, record.a, record.b, WIDTH,
		1.0 if record.complete else float(record.work) / _labor(_length(record.a, record.b)))
	_visuals[record.id] = visual


func tick(delta: float) -> void:
	_review -= delta
	if _review > 0.0:
		return
	_review = 0.4
	for record in bridges.values():
		if not record.complete:
			_post(record)


func _materials_complete(record: Dictionary) -> bool:
	for res in record.cost:
		if float(record.delivered.get(res, 0.0)) + 0.01 < float(record.cost[res]):
			return false
	return true


func _post(record: Dictionary) -> void:
	if not _materials_complete(record):
		for res in record.cost:
			var needed := float(record.cost[res]) - float(record.delivered.get(res, 0.0)) \
				- float(record.incoming.get(res, 0.0))
			while needed > 0.01:
				var source := sim.stores.find_source(res, record.a, minf(needed, Config.CARRY_CAPACITY))
				if source == null:
					break
				var amount := minf(needed, minf(source.available(res), Config.CARRY_CAPACITY))
				if amount <= 0.01:
					break
				var job := sim.jobs.post(JobBoard.Kind.BRIDGE_HAUL, source.global_position, 72.0)
				job.bridge_id = record.id
				job.res = res
				job.amount = amount
				job.source_id = source.id
				sim.jobs.index(job)
				source.reserved[res] += amount
				record.incoming[res] = float(record.incoming.get(res, 0.0)) + amount
				needed -= amount
		return
	var workers := 0
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.BRIDGE_BUILD and job.bridge_id == record.id:
			workers += 1
	while workers < 2:
		var job := sim.jobs.post(JobBoard.Kind.BRIDGE_BUILD, record.a, 68.0)
		job.bridge_id = record.id
		sim.jobs.index(job)
		workers += 1


func release_reservations(job: JobBoard.Job) -> void:
	if job.kind != JobBoard.Kind.BRIDGE_HAUL:
		return
	if not job.loaded:
		var source: Building = sim.buildings_by_id.get(job.source_id)
		if source != null:
			source.reserved[job.res] = maxf(0, source.reserved[job.res] - job.amount)
	var record: Dictionary = bridges.get(job.bridge_id, {})
	if not record.is_empty():
		record.incoming[job.res] = maxf(0, float(record.incoming.get(job.res, 0.0)) - job.amount)


func tick_job(c: Citizen, delta: float) -> void:
	var job := c.job
	var record: Dictionary = bridges.get(job.bridge_id, {})
	if record.is_empty() or record.complete:
		sim._retire_job(c)
		return
	if job.kind == JobBoard.Kind.BRIDGE_BUILD:
		c.set_goal(record.a)
		c.advance(delta, world)
		if not c.has_arrived():
			return
		if not _materials_complete(record):
			sim._retire_job(c)
			return
		c.state = Citizen.State.WORKING
		c.task_label = "building timber bridge"
		c.face_towards(record.b)
		c.update_animation(delta, 0)
		var labor := _labor(_length(record.a, record.b))
		record.work = minf(labor, float(record.work) + delta * c.workability() * sim.tools_bonus)
		_visuals[record.id].set_progress(float(record.work) / labor)
		if float(record.work) >= labor:
			_finish(record)
		return
	if not job.loaded:
		var source: Building = sim.buildings_by_id.get(job.source_id)
		if source == null:
			sim._retire_job(c)
			return
		c.set_goal(sim.entrance_of(source, "att_cart_bay"))
		c.advance(delta, world)
		if not c.has_arrived():
			return
		var amount := source.remove(job.res, job.amount)
		source.reserved[job.res] = maxf(0, source.reserved[job.res] - job.amount)
		job.loaded = true
		if amount <= 0.01:
			sim._retire_job(c)
			return
		c.pick_up(job.res, amount, registry)
		c.state = Citizen.State.TRAVELLING
		c.task_label = "carrying %s to bridge bank" % Res.display(job.res)
		c.set_goal(record.a)
		return
	# Reassert the bank after a saved meal detour or a night's sleep.
	c.set_goal(record.a)
	c.advance(delta, world)
	if not c.has_arrived():
		return
	var amount := c.drop()
	var room := maxf(0, float(record.cost[job.res]) - float(record.delivered.get(job.res, 0.0)))
	var accepted := minf(amount, room)
	record.delivered[job.res] = float(record.delivered.get(job.res, 0.0)) + accepted
	sim.ledger.used(job.res, accepted, "Bridges")
	if amount - accepted > 0.01:
		c.pick_up(job.res, amount - accepted, registry)
	release_reservations(job)
	sim.jobs.complete(job)
	sim._go_idle(c)


func _cancel_jobs(id: int) -> void:
	for job in sim.jobs.all_jobs():
		if job.bridge_id != id:
			continue
		release_reservations(job)
		sim.jobs.cancel(job)
		var worker: Citizen = sim.citizens_by_id.get(job.claimed_by)
		if worker != null and worker.job == job:
			# Loaded goods remain with their carrier and use normal stray delivery.
			sim._go_idle(worker)


func _finish(record: Dictionary) -> void:
	record.complete = true
	_cancel_jobs(record.id)
	world.install_bridge(record.id, record.a, record.b, WIDTH)
	sim.jobs.clear_refusals()
	sim.alert.emit("Timber bridge finished — the crossing is open", record.a)


func info(id: int) -> Dictionary:
	var record: Dictionary = bridges.get(id, {})
	if record.is_empty():
		return {}
	var data := record.duplicate(true)
	data.length = _length(record.a, record.b)
	data.labor = _labor(data.length)
	data.progress = 1.0 if record.complete else float(record.work) / data.labor
	data.position = record.a.lerp(record.b, 0.5)
	data.status = "Open to traffic" if record.complete else (
		"Building at the bank" if _materials_complete(record) else "Waiting for timber and tools")
	data.can_remove = _occupants(record).is_empty()
	return data


## Keep later building pads and upgrades from flattening a bank out from
## under the bridge or sealing its approaches. The margin includes terrain
## flattening beyond the visible building footprint.
func overlaps_footprint(centre: Vector3, half_w: float, half_d: float) -> bool:
	var margin := 6.0 + WIDTH * 0.5
	var rect := Rect2(Vector2(centre.x - half_w - margin, centre.z - half_d - margin),
		Vector2((half_w + margin) * 2.0, (half_d + margin) * 2.0))
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)]
	for record in bridges.values():
		var a := Vector2(record.a.x, record.a.z)
		var b := Vector2(record.b.x, record.b.z)
		if rect.has_point(a) or rect.has_point(b):
			return true
		for i in 4:
			if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null:
				return true
	return false


func _actor_roots() -> Array:
	var roots: Array = [world.citizens_root, sim.campaign, sim.husbandry, sim.cart]
	# Trade is optional in isolated simulation tests and older staged games.
	# Scouts and bucket carriers are reparented under their own systems while
	# out, so they are only found by walking those too.
	for optional in ["trade", "scouting", "water"]:
		var root: Variant = sim.get(optional)
		if root is Node:
			roots.append(root)
	return roots


func _gather_actors(node: Node, actors: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node is Citizen or node is Cart or node is Cattle:
		if not actors.has(node):
			actors.append(node)
		return
	for child in node.get_children():
		_gather_actors(child, actors)


func _occupants(record: Dictionary) -> Array:
	var actors: Array = []
	for actor_root in _actor_roots():
		_gather_actors(actor_root, actors)
	var result: Array = []
	for actor: Node3D in actors:
		if _on_deck(actor.global_position, record):
			result.append(actor)
	return result


func _on_deck(at: Vector3, record: Dictionary) -> bool:
	var a: Vector3 = record.a
	var b: Vector3 = record.b
	var point := Vector3(at.x, 0, at.z)
	var closest := Geometry3D.get_closest_point_to_segment(point,
		Vector3(a.x, 0, a.z), Vector3(b.x, 0, b.z))
	return point.distance_to(closest) <= WIDTH * 0.5 + Config.CELL * 0.75


## Demolition refuses occupied decks and insufficient storage. Delivered
## materials are refundable; reserved and carried loads never count twice.
func remove(id: int) -> Dictionary:
	var record: Dictionary = bridges.get(id, {})
	if record.is_empty():
		return {"ok": false, "reason": "No such bridge"}
	if not _occupants(record).is_empty():
		return {"ok": false, "reason": "Wait until people, livestock and carts have left the bridge"}
	var plan: Array = []
	var capacity := {}
	for res in record.delivered:
		var left := float(record.delivered[res])
		for store: Building in sim.stores.buildings_storing(res):
			if store.under_construction or not world.nav.can_reach(record.a, sim.entrance_of(store, "att_cart_bay")):
				continue
			var room := maxf(0, store.space_for(res) - float(capacity.get(store.id, 0.0)))
			var amount := minf(left, room)
			if amount <= 0.01:
				continue
			plan.append([store, res, amount])
			capacity[store.id] = float(capacity.get(store.id, 0.0)) + amount
			left -= amount
		if left > 0.01:
			return {"ok": false, "reason": "Make room in reachable stores for delivered bridge materials"}
	_cancel_jobs(id)
	for entry in plan:
		entry[0].add(entry[1], entry[2])
	var refunded: Dictionary = record.delivered.duplicate()
	_erase(id)
	return {"ok": true, "reason": "", "refunded": refunded}


## Destruction has an explicit bank evacuation rule. People, carts and their
## cargo survive at the nearer clear bank; the destroyed timber is lost.
func destroy_bridge(id: int) -> Dictionary:
	var record: Dictionary = bridges.get(id, {})
	if record.is_empty():
		return {"ok": false, "reason": "No such bridge"}
	var occupants := _occupants(record)
	_cancel_jobs(id)
	world.remove_bridge(id)
	for actor: Node3D in occupants:
		var bank: Vector3 = record.a if actor.global_position.distance_squared_to(record.a) \
			< actor.global_position.distance_squared_to(record.b) else record.b
		var cell := world.nav.nearest_free(bank)
		bank = Vector3((cell.x + 0.5) * Config.CELL, 0, (cell.y + 0.5) * Config.CELL)
		bank.y = world.surface_height_at(bank.x, bank.z)
		actor.global_position = bank
		if actor is Citizen:
			actor.clear_goal()
		elif actor is Cart:
			actor.parked_at = bank
			if sim.trade != null and actor.has_meta("wreck_id"):
				sim.trade.relocate_wreck(int(actor.get_meta("wreck_id")), bank)
	_erase(id)
	sim.alert.emit("Bridge destroyed — travelers evacuated to the banks", record.a)
	return {"ok": true, "reason": "", "evacuated": occupants.size(), "lost": record.delivered.duplicate()}


func _erase(id: int) -> void:
	world.remove_bridge(id)
	if _visuals.has(id):
		_visuals[id].queue_free()
		_visuals.erase(id)
	bridges.erase(id)
	sim.jobs.clear_refusals()


func capture() -> Dictionary:
	var records: Array = []
	for record in bridges.values():
		var entry: Dictionary = record.duplicate(true)
		entry.erase("incoming")
		records.append(entry)
	return {"next_id": _next_id, "bridges": records}


func restore(data: Variant) -> String:
	var error := validate(data, world.size_m)
	if error != "":
		return error
	# Validate against the restored terrain before changing any live record.
	for record in data.get("bridges", []):
		error = _shape_error(record.a, record.b, false)
		if error != "":
			return "Invalid bridge geography: " + error
		if _bank(record.a).distance_to(record.a) > 0.05 or _bank(record.b).distance_to(record.b) > 0.05:
			return "Bridge entrances do not match the saved banks"
	for id in bridges.keys():
		_cancel_jobs(id)
		_erase(id)
	_next_id = int(data.get("next_id", 1))
	for entry in data.get("bridges", []):
		var record: Dictionary = entry.duplicate(true)
		record.incoming = {}
		bridges[record.id] = record
		_visual(record)
		if record.complete:
			world.install_bridge(record.id, record.a, record.b, WIDTH)
	sim.jobs.clear_refusals()
	return ""


static func validate(data: Variant, size_m: float = Config.WORLD_SIZE) -> String:
	if not data is Dictionary:
		return "bridges must be a dictionary"
	if data.is_empty():
		return ""
	if typeof(data.get("next_id")) != TYPE_INT or data.next_id < 1 or data.next_id > 2147483647 \
			or not data.get("bridges") is Array or data.bridges.size() > MAX_BRIDGES:
		return "bridges require a bounded next_id and bridge array"
	var ids := {}
	var records: Array = []
	for record in data.bridges:
		if not record is Dictionary or typeof(record.get("id")) != TYPE_INT \
				or record.id < 1 or record.id >= data.next_id or ids.has(record.id):
			return "bridge ID is invalid or duplicated"
		ids[record.id] = true
		for bank in ["a", "b"]:
			if not record.get(bank) is Vector3 or not record[bank].is_finite():
				return "bridge banks must be finite world positions"
			var at: Vector3 = record[bank]
			if at.x < Config.CELL or at.z < Config.CELL or at.x >= size_m - Config.CELL \
					or at.z >= size_m - Config.CELL or absf(at.y) > size_m:
				return "bridge bank is outside the world"
		var length := _length(record.a, record.b)
		if length < MIN_SPAN or length > MAX_SPAN or absf(record.a.y - record.b.y) / length > MAX_SLOPE:
			return "bridge span or slope exceeds timber limits"
		if not record.get("cost") is Dictionary or record.cost != _cost(length) \
				or not record.get("delivered") is Dictionary:
			return "bridge cost does not match its span"
		for res in record.delivered:
			if not record.cost.has(res) or typeof(record.delivered[res]) not in [TYPE_FLOAT, TYPE_INT] \
					or not is_finite(float(record.delivered[res])) or record.delivered[res] < 0 \
					or record.delivered[res] > record.cost[res]:
				return "bridge delivered materials exceed their cost"
		if typeof(record.get("complete")) != TYPE_BOOL \
				or typeof(record.get("work")) not in [TYPE_FLOAT, TYPE_INT] \
				or not is_finite(float(record.work)) or record.work < 0 or record.work > _labor(length):
			return "bridge work progress is invalid"
		if record.complete != (record.work >= _labor(length)):
			return "bridge completion disagrees with its work progress"
		if record.work > 0:
			for res in record.cost:
				if absf(float(record.delivered.get(res, 0.0)) - float(record.cost[res])) > 0.01:
					return "bridge labor has no delivered materials"
		for other in records:
			if _overlap(record.a, record.b, other.a, other.b):
				return "saved bridge spans overlap"
		records.append(record)
	return ""
