class_name Husbandry
extends Node3D

## Every domestication, breeding and slaughter action belongs to a real
## rancher on the job board. No invisible workforce produces food or hides.
signal domesticated(cow_id: int, ranch_id: int)

const RANCH_CAPACITY := 8
const ADULT_DAYS := 6.0
const BREED_WORK_DAYS := 1.5
const FOOD_YIELD := 20.0
const HIDE_YIELD := 4.0
const TAME_SECONDS := 8.0
const BUTCHER_SECONDS := 12.0
const MAX_CATTLE := 256

var sim: Simulation
var world: World
var registry: AssetRegistry
var cows: Dictionary = {}
var breeding: Dictionary = {}
var _next_id := 1


func setup(simulation: Simulation, terrain: World, assets: AssetRegistry) -> void:
	sim = simulation
	world = terrain
	registry = assets


func _spawn(at: Vector3, ranch_id: int = -1, age_days: float = 12.0, cow_id: int = -1) -> Cattle:
	var cow := Cattle.new()
	add_child(cow)
	var actual_id := _next_id if cow_id < 0 else cow_id
	_next_id = maxi(_next_id, actual_id + 1)
	cow.age_days = age_days
	cow.ranch_id = ranch_id
	cow.setup_cow(actual_id, at)
	cows[actual_id] = cow
	return cow


func _free_ground(around: Vector3, salt: int) -> Vector3:
	for ring in 12:
		for index in 12:
			var angle := float(index) * TAU / 12.0 + float(salt) * 0.71
			var at := around + Vector3(cos(angle), 0, sin(angle)) * float(ring * 2)
			if at.x < 4.0 or at.z < 4.0 or at.x > world.size_m - 4.0 \
					or at.z > world.size_m - 4.0:
				continue
			var cell := world.world_to_cell(at)
			if world.nav.is_solid(cell.x, cell.y):
				continue
			at.y = world.heightmap.height_at(at.x, at.z)
			return at
	return Vector3.INF


func generate_herds() -> void:
	if not cows.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = world.world_seed + 81371
	var origin := world.centre()
	for herd in 3:
		var angle := float(herd) * TAU / 3.0 + rng.randf_range(-0.15, 0.15)
		var centre := origin + Vector3(cos(angle), 0, sin(angle)) * (100.0 + herd * 26.0)
		for member in 4:
			var at := _free_ground(centre + Vector3(member % 2, 0, member / 2) * 4.0, member)
			if at != Vector3.INF and world.nav.can_reach(origin, at):
				_spawn(at)


func _ranch(id: int) -> Building:
	var b: Building = sim.buildings_by_id.get(id)
	return b if b != null and b.def.is_ranch() and not b.under_construction else null


func herd_at(ranch_id: int, adults_only: bool = false) -> Array[Cattle]:
	var herd: Array[Cattle] = []
	for cow: Cattle in cows.values():
		if cow.ranch_id == ranch_id and (not adults_only or cow.age_days >= ADULT_DAYS):
			herd.append(cow)
	return herd


func ranch_info(ranch_id: int) -> Dictionary:
	return {"cattle": herd_at(ranch_id).size(), "adults": herd_at(ranch_id, true).size(),
		"capacity": RANCH_CAPACITY,
		"breeding_progress": float(breeding.get(ranch_id, 0.0)) / BREED_WORK_DAYS}


func _cow_has_job(cow_id: int) -> bool:
	for job in sim.jobs.all_jobs():
		if job.kind in [JobBoard.Kind.TAME, JobBoard.Kind.BUTCHER] and job.cow_id == cow_id:
			return true
	return false


func _receiving_ranch(cow: Cattle) -> Building:
	var best: Building
	var distance := INF
	for b in sim.buildings:
		if not b.def.is_ranch() or b.under_construction or b.workers.is_empty():
			continue
		var expected := herd_at(b.id).size() + sim.jobs.count_for(JobBoard.Kind.TAME, b.id, -1)
		if expected >= RANCH_CAPACITY:
			continue
		var d := cow.position.distance_squared_to(b.position)
		if d >= distance or d > b.def.work_radius * b.def.work_radius:
			continue
		if world.nav.can_reach(cow.position, sim.entrance_of(b, "att_entrance")):
			best = b
			distance = d
	return best


func get_info(cow_id: int) -> Dictionary:
	var cow: Cattle = cows.get(cow_id)
	if cow == null:
		return {}
	var reason := ""
	if cow.ranch_id >= 0:
		reason = "Already part of a ranch herd"
	elif cow.marked:
		reason = "A rancher has been requested"
	elif _receiving_ranch(cow) == null:
		reason = "Build and staff a ranch within 240 metres with room for cattle"
	return {"id": cow.id, "position": cow.position, "wild": cow.ranch_id < 0,
		"marked": cow.marked, "ranch_id": cow.ranch_id, "age_days": cow.age_days,
		"status": "Calf" if cow.age_days < ADULT_DAYS else ("Wild" if cow.ranch_id < 0 else "Domesticated"),
		"can_domesticate": reason == "", "reason": reason}


func request_domestication(cow_id: int) -> String:
	var info := get_info(cow_id)
	if info.is_empty():
		return "No such animal"
	if not info.can_domesticate:
		return info.reason
	var cow: Cattle = cows[cow_id]
	cow.marked = true
	var ranch := _receiving_ranch(cow)
	if ranch != null:
		post_ranch_jobs(ranch)
	return ""


func _post(kind: int, ranch: Building, cow: Cattle = null) -> JobBoard.Job:
	var at := sim.entrance_of(ranch, "att_entrance") if cow == null else cow.position
	var job := sim.jobs.post(kind, at, 70.0 if kind == JobBoard.Kind.TAME else 60.0)
	job.dest_id = ranch.id
	job.required_workplace = ranch.id
	job.cow_id = cow.id if cow != null else -1
	job.res = -1
	sim.jobs.index(job)
	return job


func post_ranch_jobs(ranch: Building) -> void:
	if ranch.under_construction or ranch.workers.is_empty():
		return
	var taming := sim.jobs.count_for(JobBoard.Kind.TAME, ranch.id, -1)
	for cow: Cattle in cows.values():
		if taming >= ranch.workers.size() or herd_at(ranch.id).size() + taming >= RANCH_CAPACITY:
			break
		if cow.ranch_id >= 0 or not cow.marked or _cow_has_job(cow.id):
			continue
		if _receiving_ranch(cow) != ranch:
			continue
		_post(JobBoard.Kind.TAME, ranch, cow)
		taming += 1
	if not sim.research.completed.has("ranching"):
		return
	var adults := herd_at(ranch.id, true)
	if adults.size() >= 2 and herd_at(ranch.id).size() + taming < RANCH_CAPACITY \
			and cows.size() < MAX_CATTLE and sim.jobs.count_for(JobBoard.Kind.TEND, ranch.id, -1) == 0:
		_post(JobBoard.Kind.TEND, ranch)
	var slaughtering := sim.jobs.count_for(JobBoard.Kind.BUTCHER, ranch.id, -1)
	# Keep three adult breeders so one lost animal does not end the herd.
	if adults.size() - slaughtering <= 3 or slaughtering >= ranch.workers.size() \
			or ranch.space_for(Config.Res.HIDES) < FOOD_YIELD + HIDE_YIELD:
		return
	for cow in adults:
		if not _cow_has_job(cow.id):
			var job := _post(JobBoard.Kind.BUTCHER, ranch, cow)
			job.output_reserved = FOOD_YIELD + HIDE_YIELD
			ranch.production_reserved += job.output_reserved
			break


func tick(delta: float) -> void:
	var busy := {}
	for job in sim.jobs.all_jobs():
		if job.kind not in [JobBoard.Kind.TAME, JobBoard.Kind.TEND, JobBoard.Kind.BUTCHER]:
			continue
		var ranch := _ranch(job.dest_id)
		var worker: Citizen = sim.citizens_by_id.get(job.claimed_by)
		var unstaffed := ranch == null or ranch.workers.is_empty()
		var worker_gone := false
		if not unstaffed and job.claimed_by >= 0:
			worker_gone = worker == null or worker.workplace_id != job.dest_id \
					or not ranch.workers.has(worker.id)
		if unstaffed or worker_gone:
			if worker != null and worker.job == job:
				sim._retire_job(worker)
			else:
				sim._release_reservations(job)
				sim.jobs.cancel(job)
			var abandoned: Cattle = cows.get(job.cow_id)
			if unstaffed and abandoned != null and job.kind == JobBoard.Kind.TAME:
				abandoned.marked = false
				abandoned.clear_goal()
				abandoned.grazing_anchor = abandoned.position
			continue
		if job.kind != JobBoard.Kind.TEND:
			busy[job.cow_id] = true
	for cow: Cattle in cows.values():
		cow.age_days += delta / Config.DAY_LENGTH
		cow.refresh_age()
		if cow.ranch_id >= 0 and _ranch(cow.ranch_id) == null:
			cow.ranch_id = -1
			cow.marked = false
			cow.grazing_anchor = cow.position
		if cow.marked and not busy.has(cow.id) and _receiving_ranch(cow) == null:
			cow.marked = false
			cow.clear_goal()
			cow.grazing_anchor = cow.position
		if busy.has(cow.id) or cow.marked:
			continue
		if sim.day >= cow.wander_at:
			cow.wander_at = sim.day + 0.15
			var anchor := cow.grazing_anchor
			if cow.ranch_id >= 0:
				anchor = sim.entrance_of(_ranch(cow.ranch_id), "att_entrance")
			var angle := float(cow.id) * 2.4 + floorf(sim.day * 5.0)
			var target := _free_ground(anchor + Vector3(cos(angle), 0, sin(angle)) * 5.0, cow.id)
			if target != Vector3.INF and world.nav.can_reach(cow.position, target):
				cow.set_goal(target)
		cow.advance(delta, world)
	for ranch_id in breeding.keys():
		if _ranch(ranch_id) == null:
			breeding.erase(ranch_id)


func tick_job(worker: Citizen, delta: float) -> void:
	var job := worker.job
	var ranch := _ranch(job.dest_id)
	if ranch == null or worker.workplace_id != ranch.id or not ranch.workers.has(worker.id) \
			or not sim.citizens_by_id.has(worker.id) or worker.workability() <= 0.0:
		sim._retire_job(worker)
		return
	if job.kind == JobBoard.Kind.TAME:
		_tick_tame(worker, ranch, delta)
	elif not sim.research.completed.has("ranching"):
		sim._retire_job(worker)
	elif job.kind == JobBoard.Kind.TEND:
		_tick_tend(worker, ranch, delta)
	else:
		_tick_butcher(worker, ranch, delta)


func _tick_tame(worker: Citizen, ranch: Building, delta: float) -> void:
	var job := worker.job
	var cow: Cattle = cows.get(job.cow_id)
	if cow == null or cow.ranch_id >= 0:
		sim._retire_job(worker)
		return
	if not job.loaded:
		worker.set_goal(cow.position)
		worker.advance(delta, world)
		if not worker.has_arrived():
			return
		worker.state = Citizen.State.WORKING
		worker.task_label = "gaining a cow's trust"
		worker.update_animation(delta, 0.0)
		job.amount += delta * worker.workability()
		if job.amount < TAME_SECONDS:
			return
		job.loaded = true
	worker.state = Citizen.State.TRAVELLING
	worker.task_label = "leading cattle home"
	var home := sim.entrance_of(ranch, "att_entrance")
	cow.set_goal(worker.position)
	cow.advance(delta, world)
	if cow.position.distance_to(worker.position) < 4.0:
		worker.set_goal(home)
		worker.advance(delta, world)
	if worker.position.distance_to(home) > 2.5 or cow.position.distance_to(home) > 4.0:
		return
	if herd_at(ranch.id).size() >= RANCH_CAPACITY:
		sim._retire_job(worker)
		return
	cow.ranch_id = ranch.id
	cow.marked = false
	cow.grazing_anchor = home
	cow.clear_goal()
	sim.jobs.complete(job)
	sim._go_idle(worker)
	var discovered := not sim.research.ranching_known
	sim.research.discover_ranching()
	domesticated.emit(cow.id, ranch.id)
	if discovered:
		sim.alert.emit("Cattle brought home. Ranching knowledge is available.", ranch.position)


func _tick_tend(worker: Citizen, ranch: Building, delta: float) -> void:
	if herd_at(ranch.id, true).size() < 2 or herd_at(ranch.id).size() \
			+ sim.jobs.count_for(JobBoard.Kind.TAME, ranch.id, -1) >= RANCH_CAPACITY \
			or cows.size() >= MAX_CATTLE:
		sim._retire_job(worker)
		return
	worker.set_goal(sim.entrance_of(ranch, "att_entrance"))
	worker.advance(delta, world)
	if not worker.has_arrived():
		return
	worker.state = Citizen.State.WORKING
	worker.task_label = "tending the breeding herd"
	worker.update_animation(delta, 0.0)
	breeding[ranch.id] = float(breeding.get(ranch.id, 0.0)) + delta * worker.workability() / Config.DAY_LENGTH
	if float(breeding[ranch.id]) < BREED_WORK_DAYS:
		return
	var at := _free_ground(worker.position + Vector3(3, 0, 0), _next_id)
	if at == Vector3.INF:
		breeding[ranch.id] = BREED_WORK_DAYS
		return
	_spawn(at, ranch.id, 0.0)
	breeding[ranch.id] = maxf(0.0, float(breeding[ranch.id]) - BREED_WORK_DAYS)
	sim.jobs.complete(worker.job)
	sim._go_idle(worker)


func _tick_butcher(worker: Citizen, ranch: Building, delta: float) -> void:
	var job := worker.job
	var cow: Cattle = cows.get(job.cow_id)
	if cow == null or cow.ranch_id != ranch.id or cow.age_days < ADULT_DAYS \
			or herd_at(ranch.id, true).size() <= 3:
		sim._retire_job(worker)
		return
	worker.set_goal(cow.position)
	worker.advance(delta, world)
	if not worker.has_arrived():
		return
	worker.state = Citizen.State.WORKING
	worker.task_label = "preparing food and hides"
	worker.update_animation(delta, 0.0)
	job.amount += delta * worker.workability()
	if job.amount < BUTCHER_SECONDS:
		return
	sim._release_output(job)
	if ranch.space_for(Config.Res.HIDES) < FOOD_YIELD + HIDE_YIELD:
		sim._retire_job(worker)
		return
	ranch.add(Config.Res.FOOD, FOOD_YIELD)
	ranch.add(Config.Res.HIDES, HIDE_YIELD)
	cows.erase(cow.id)
	cow.queue_free()
	sim.jobs.complete(job)
	sim._go_idle(worker)


func remove_ranch(ranch_id: int) -> void:
	breeding.erase(ranch_id)
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.TAME and job.dest_id == ranch_id:
			var cow: Cattle = cows.get(job.cow_id)
			if cow != null:
				cow.marked = false
				cow.clear_goal()
				cow.grazing_anchor = cow.position
	for cow: Cattle in herd_at(ranch_id):
		cow.ranch_id = -1
		cow.marked = false
		cow.grazing_anchor = cow.position
		cow.clear_goal()


func capture() -> Dictionary:
	var records: Array = []
	for cow: Cattle in cows.values():
		records.append(cow.capture_cow())
	var progress: Array = []
	for ranch_id in breeding:
		progress.append({"ranch_id": ranch_id, "progress_days": float(breeding[ranch_id])})
	return {"next_id": _next_id, "cows": records, "breeding": progress}


func restore(data: Variant) -> String:
	var error := validate(data, world.size_m)
	if error != "":
		return error
	for cow: Cattle in cows.values():
		cow.free()
	cows.clear()
	breeding.clear()
	_next_id = 1
	if data.is_empty():
		generate_herds()
		return ""
	for record in data.cows:
		var cow := _spawn(record.position, record.ranch_id, float(record.age_days), record.id)
		cow.rotation.y = float(record.yaw)
		cow.marked = record.marked
	_next_id = data.next_id
	for entry in data.breeding:
		breeding[entry.ranch_id] = float(entry.progress_days)
	return ""


static func validate(data: Variant, world_size: float = Config.WORLD_SIZE) -> String:
	if not data is Dictionary:
		return "husbandry must be a dictionary"
	if data.is_empty():
		return ""
	if not data.get("cows") is Array or not data.get("breeding") is Array \
			or typeof(data.get("next_id")) != TYPE_INT or data.next_id < 1 or data.next_id > 2147483647:
		return "husbandry requires cows, breeding and a bounded next_id"
	if data.cows.size() > MAX_CATTLE or data.breeding.size() > MAX_CATTLE:
		return "husbandry exceeds supported herd count"
	var ids := {}
	var herd_sizes := {}
	for cow in data.cows:
		if not cow is Dictionary or typeof(cow.get("id")) != TYPE_INT \
				or cow.id < 1 or cow.id >= data.next_id or ids.has(cow.id):
			return "husbandry has an invalid or duplicate cow ID"
		ids[cow.id] = true
		if not cow.get("position") is Vector3 or not cow.position.is_finite() \
				or cow.position.x < 0 or cow.position.z < 0 \
				or cow.position.x > world_size or cow.position.z > world_size \
				or absf(cow.position.y) > world_size:
			return "cow position is outside the world"
		for field in ["yaw", "age_days"]:
			if typeof(cow.get(field)) not in [TYPE_FLOAT, TYPE_INT] \
					or not is_finite(float(cow[field])) or absf(float(cow[field])) > 1000000.0:
				return "cow %s must be finite and bounded" % field
		if cow.age_days < 0 or typeof(cow.get("ranch_id")) != TYPE_INT \
				or cow.ranch_id < -1 or cow.ranch_id > 2147483647 \
				or typeof(cow.get("marked")) != TYPE_BOOL:
			return "cow age, ranch or order is invalid"
		if cow.ranch_id >= 0:
			if cow.marked:
				return "a domesticated cow cannot have a taming order"
			herd_sizes[cow.ranch_id] = int(herd_sizes.get(cow.ranch_id, 0)) + 1
			if herd_sizes[cow.ranch_id] > RANCH_CAPACITY:
				return "a ranch exceeds its cattle capacity"
	var ranches := {}
	for entry in data.breeding:
		if not entry is Dictionary or typeof(entry.get("ranch_id")) != TYPE_INT \
				or entry.ranch_id < 1 or entry.ranch_id > 2147483647 or ranches.has(entry.ranch_id):
			return "breeding has an invalid or duplicate ranch ID"
		ranches[entry.ranch_id] = true
		if typeof(entry.get("progress_days")) not in [TYPE_FLOAT, TYPE_INT] \
				or not is_finite(float(entry.progress_days)) \
				or entry.progress_days < 0 or entry.progress_days > BREED_WORK_DAYS:
			return "breeding progress is outside its work duration"
	return ""
