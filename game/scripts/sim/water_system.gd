class_name WaterSystem
extends Node3D

## Local wells, real drinking journeys and bucket carriers. Water never appears
## in the global construction wallet or moves to a fire without a person.
const CAPACITY := 80.0
const REFILL_PER_DAY := 40.0
const THIRST_PER_DAY := 0.35
const SEEK_AT := 0.45
const BUCKET := 4.0
const POISON_SECONDS := 12.0
const POISON_DAYS := 4.0
var sim: Simulation
var world: World
var registry: AssetRegistry
var wells: Dictionary = {}
var drinkers: Dictionary = {}
var carriers: Dictionary = {}
var poison_jobs: Dictionary = {}
var _review := 0.0
var _moved := {}

func setup(p_sim: Simulation, p_world: World, p_registry: AssetRegistry) -> void:
	sim = p_sim
	world = p_world
	registry = p_registry
	sim.stores.water = self
	name = "water_system"
	_sync_wells()

func _buildings() -> Dictionary:
	var out := sim.buildings_by_id.duplicate()
	if sim.campaign != null: out.merge(sim.campaign.enemy_buildings)
	return out

func _sync_wells() -> void:
	var buildings := _buildings()
	for id in wells.keys():
		if not buildings.has(id) or buildings[id].type_id != "well": wells.erase(id)
	for b in buildings.values():
		if b.type_id == "well" and not b.under_construction and not wells.has(b.id):
			wells[b.id] = {"id":b.id,"water":CAPACITY,"poison":0.0,"poison_days":0.0}

func _faction(c: Citizen) -> int:
	if c is Soldier: return c.faction
	if sim.campaign != null and sim.campaign._workers.has(c): return 1
	return 0

func _identity(c: Citizen) -> int:
	if sim.campaign != null and c is Soldier and c.faction == 0:
		return sim.campaign._civilian_ids.get(c.id,c.id)
	return c.id

func _key(c: Citizen) -> String:
	return "%d:%d" % [_faction(c),_identity(c)]

func _people() -> Dictionary:
	var out := {}
	for c in sim.population_members(): out[_key(c)] = c
	if sim.campaign != null:
		for c in sim.campaign._workers: out[_key(c)] = c
		for u in sim.campaign.units.values():
			if u.faction == 1: out[_key(u)] = u
	return out

func handles(c: Citizen) -> bool:
	if _moved.has(_key(c)) or drinkers.has(_key(c)) or carriers.has(c.id): return true
	for job in poison_jobs.values():
		var scout: Scout = sim.scouting.scouts.get(job.scout_id) if sim.scouting != null else null
		if scout != null and scout.person == c: return true
	return false

func poisoning(scout_id: int) -> bool:
	return poison_jobs.has(scout_id)

func hostile_scouts() -> Array[Citizen]:
	var out: Array[Citizen] = []
	if sim.scouting == null: return out
	for job in poison_jobs.values():
		var scout: Scout = sim.scouting.scouts.get(job.scout_id)
		if scout != null and job.state in ["approach","poisoning"]: out.append(scout.person)
	return out

func sabotage_target(person_id: int) -> Vector3:
	if sim.scouting == null: return Vector3.INF
	for job in poison_jobs.values():
		var scout: Scout = sim.scouting.scouts.get(job.scout_id)
		if scout != null and scout.person.id == person_id:
			var b: Building = _buildings().get(job.target_id)
			if b != null: return b.global_position
	return Vector3.INF

func _well_for(c: Citizen) -> Building:
	var best: Building
	var distance := INF
	var faction := _faction(c)
	for b in _buildings().values():
		if not wells.has(b.id) or b.under_construction or wells[b.id].water < 0.01: continue
		var enemy: bool = sim.campaign != null and sim.campaign.enemy_buildings.has(b.id)
		if int(enemy) != faction: continue
		var door := sim.entrance_of(b,"att_entrance")
		var d := c.global_position.distance_squared_to(door)
		if d < distance and world.nav.can_reach(c.global_position,door):
			best = b
			distance = d
	return best

func _move(c: Citizen, p: Vector3, delta: float) -> bool:
	if c.service_health <= 0 or (c is Soldier and c.health <= 0): return false
	_moved[_key(c)] = true
	if c is Soldier and c.incapacitated(): return false
	c.set_indoors(false)
	c.set_goal(p)
	c.advance(delta,world)
	return c.has_arrived() and not c.unreachable

func _damage(c: Citizen, amount: float) -> void:
	if c is Soldier: c.apply_damage(amount)
	else: c.service_health = maxf(0,c.service_health-amount)

func tick(delta: float) -> void:
	if delta <= 0 or not is_finite(delta): return
	_moved.clear()
	_sync_wells()
	for well in wells.values():
		well.water = minf(CAPACITY,well.water+REFILL_PER_DAY*delta/Config.DAY_LENGTH)
		well.poison_days = maxf(0,well.poison_days-delta/Config.DAY_LENGTH)
		if well.poison_days <= 0: well.poison = 0.0
	var people := _people()
	for key in drinkers.keys():
		if not people.has(key): drinkers.erase(key)
	for key in people:
		var c: Citizen = people[key]
		if (c is Soldier and c.health <= 0) or c.service_health <= 0: continue
		c.hydration = maxf(0,c.hydration-THIRST_PER_DAY*delta/Config.DAY_LENGTH)
		if c.water_sickness > 0:
			_damage(c,delta*0.035*c.water_sickness)
			c.water_sickness = maxf(0,c.water_sickness-delta/(Config.DAY_LENGTH*4.0))
		if c.hydration <= 0: _damage(c,delta*0.03)
		if c.hydration <= SEEK_AT and not drinkers.has(key):
			var well := _well_for(c)
			if well != null:
				if sim.citizens_by_id.get(c.id) == c:
					var previous_job := c.job
					sim._retire_job(c)
					if previous_job != null: sim._restore_felling_claim(previous_job)
				c.clear_goal()
				drinkers[key] = {"faction":_faction(c),"person_id":_identity(c),"well_id":well.id}
		if drinkers.has(key): _drink(c,key,delta)
	for id in carriers.keys(): _fire_tick(id,delta)
	for id in poison_jobs.keys(): _poison_tick(id,delta)
	_review -= delta
	if _review <= 0:
		_review = 2.0
		for b in sim.buildings:
			if b.fire > 0.05 and carriers.size() < 2: request_firefighting(b.id)
	# Enemy workers are actual people too; drinking poison never kills a
	# remote population counter that did not visit the well.
	if sim.campaign != null:
		for c in sim.campaign._workers.duplicate():
			if c.service_health > 0: continue
			var farm: Building = sim.campaign._enemy_type("farm")
			if farm != null:
				sim.campaign._protect_farm(farm,false)
				farm.workers.erase(c.id)
				farm.sync_fields_to_workers()
				sim.campaign._protect_farm(farm,true,false)
			sim.campaign._workers.erase(c)
			sim.campaign._worker_leg.erase(c.id)
			sim.campaign._worker_wait.erase(c.id)
			sim.campaign.town_population = maxi(0,sim.campaign.town_population-1)
			c.queue_free()

func _drink(c: Citizen, key: String, delta: float) -> void:
	var job: Dictionary = drinkers[key]
	var b: Building = _buildings().get(job.well_id)
	if b == null or not wells.has(b.id) or b.under_construction:
		drinkers.erase(key)
		c.clear_goal()
		return
	c.task_label = "Fetching drinking water"
	if not _move(c,sim.entrance_of(b,"att_entrance"),delta): return
	var well: Dictionary = wells[b.id]
	var amount := minf(float(well.water),(1.0-c.hydration)*2.0)
	if amount <= 0.00001: return
	well.water -= amount
	c.hydration = minf(1,c.hydration+amount*0.5)
	if well.poison > 0: c.water_sickness = minf(1,c.water_sickness+well.poison*amount)
	if c.hydration >= 0.95:
		drinkers.erase(key)
		c.clear_goal()
		c.task_label = "Finished drinking"
		# The water movement already consumed this tick. Give a loaded civilian
		# their real delivery destination now, without walking them twice or
		# leaving an observable idle tick with an unaccounted-for handload.
		if sim.citizens_by_id.get(c.id) == c and c.job == null and c.carrying_amount > 0.01 and c.workability() > 0:
			var store := sim.stores.find_store(c.carrying_res,c.global_position,-1)
			if store != null:
				c.set_goal(sim.entrance_of(store,"att_cart_bay"))
				c.state = Citizen.State.TRAVELLING
				c.task_label = "returning %s" % Res.display(c.carrying_res)

func request_firefighting(building_id: int) -> String:
	var target: Building = sim.buildings_by_id.get(building_id)
	if target == null or target.fire <= 0: return "Choose a burning building in your settlement."
	for job in carriers.values():
		if job.target_id == building_id: return "A bucket carrier is already responding."
	var c: Citizen
	var well: Building
	for person in sim.citizens:
		if person.immigrant or handles(person) or person.service_health <= 0 or person.carrying_amount + (person.rations if person is Soldier else 0.0) > Config.CARRY_CAPACITY-BUCKET: continue
		if person is Soldier and (person.health <= 0 or person.incapacitated() or person.workability() <= 0): continue
		var source := _well_for(person)
		if source != null and world.nav.can_reach(sim.entrance_of(source,"att_entrance"),sim.entrance_of(target,"att_entrance")):
			c = person
			well = source
			break
	if c == null: return "No available resident can carry water from a reachable well."
	sim.detach_for_service(c)
	c.reparent(self)
	c.profession = "bucket carrier"
	c.clear_goal()
	carriers[c.id] = {"person":c,"target_id":target.id,"well_id":well.id,"state":"fill"}
	return ""

func _bucket(c: Citizen) -> void:
	var visual: Node3D = c.get_node_or_null("water_bucket")
	if c.water_bucket <= 0.00001:
		if visual != null:
			c.remove_child(visual)
			visual.queue_free()
		return
	if visual != null: return
	var mesh := MeshInstance3D.new()
	mesh.name = "water_bucket"
	var bucket := CylinderMesh.new()
	bucket.top_radius = 0.22
	bucket.bottom_radius = 0.16
	bucket.height = 0.34
	bucket.radial_segments = 10
	mesh.mesh = bucket
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.26,0.16,0.075)
	mesh.material_override = material
	mesh.position = Vector3(0.43,0.55,0.05)
	c.add_child(mesh)

func _finish_carrier(id: int, died: bool = false) -> void:
	var c: Citizen = carriers[id].person
	carriers.erase(id)
	if died:
		var home: Building = sim.buildings_by_id.get(c.home_id)
		if home != null: home.residents.erase(c.id)
		c.queue_free()
		return
	c.water_bucket = 0
	_bucket(c)
	sim.return_from_service(c,c.id)

func _fire_tick(id: int, delta: float) -> void:
	var job: Dictionary = carriers[id]
	var c: Citizen = job.person
	if not sim.buildings_by_id.has(c.home_id): c.home_id = -1
	if c.service_health <= 0 or (c is Soldier and c.health <= 0):
		_finish_carrier(id,true)
		return
	c.update_hunger(sim.day,delta/Config.DAY_LENGTH)
	if _moved.has(_key(c)) or drinkers.has(_key(c)): return
	var target: Building = sim.buildings_by_id.get(job.target_id)
	var well: Building = sim.buildings_by_id.get(job.well_id)
	if target == null or target.fire <= 0 or well == null or not wells.has(well.id) or c.hunger >= Config.HUNGER_URGENT:
		# Return unused bucket water to its source when possible.
		if c.water_bucket > 0 and well != null and wells.has(well.id):
			c.task_label = "Returning unused bucket water"
			if not _move(c,sim.entrance_of(well,"att_entrance"),delta): return
			wells[well.id].water = minf(CAPACITY,wells[well.id].water+c.water_bucket)
		_finish_carrier(id)
		return
	if job.state == "fill":
		c.task_label = "Filling a firefighting bucket"
		if not _move(c,sim.entrance_of(well,"att_entrance"),delta): return
		var amount := minf(BUCKET,float(wells[well.id].water))
		if amount < 0.01: return
		wells[well.id].water -= amount
		c.water_bucket += amount
		job.state = "carry"
		_bucket(c)
		c.clear_goal()
	else:
		c.task_label = "Carrying water to the fire"
		if not _move(c,sim.entrance_of(target,"att_entrance"),delta): return
		target.fire = maxf(0,target.fire-c.water_bucket*0.25)
		c.water_bucket = 0
		_bucket(c)
		job.state = "fill"
		c.clear_goal()

func poison_quote(scout_id: int) -> Dictionary:
	var q := {"can_poison":false,"reason":"Select a trained scout.","cost":{Config.Res.TOOLS:1},"target_id":-1,"source_id":-1}
	if sim.scouting == null or sim.campaign == null or sim.campaign.defeated: return q
	var scout: Scout = sim.scouting.scouts.get(scout_id)
	if scout == null or scout.state not in ["ready","exploring","visiting"]: return q
	if scout.person.service_health <= 0 or (scout.person is Soldier and (scout.person.health <= 0 or scout.person.incapacitated())): return q
	q.reason = "This scout is already on a water mission."
	if handles(scout.person): return q
	q.reason = "Bring the enemy well into sight before targeting it."
	var target: Building
	for b in sim.campaign.enemy_buildings.values():
		if b.type_id == "well" and not b.under_construction and sim.scouting.visibility_at(b.global_position): target = b; break
	if target == null: return q
	q.target_id = target.id
	q.reason = "The scout needs food for the journey."
	if scout.food < 1: return q
	q.reason = "No traversable approach to the enemy well."
	if not world.nav.can_reach(scout.person.global_position,sim.entrance_of(target,"att_entrance")): return q
	var source: Building = sim.scouting._source(Config.Res.TOOLS,1.0,scout.person.global_position)
	q.reason = "The scout must collect one tool from a reachable friendly store."
	if source == null: return q
	q.source_id = source.id
	q.reason = ""
	q.can_poison = true
	return q

func poison(scout_id: int) -> String:
	var q := poison_quote(scout_id)
	if not q.can_poison: return q.reason
	var scout: Scout = sim.scouting.scouts[scout_id]
	var source: Building = sim.buildings_by_id[q.source_id]
	source.reserved[Config.Res.TOOLS] += 1
	poison_jobs[scout_id] = {"scout_id":scout_id,"target_id":q.target_id,"source_id":q.source_id,
		"state":"collect","reserved":true,"kit":0.0,"progress":0.0}
	scout.person.clear_goal()
	scout.status = "Collecting a well sabotage kit"
	return ""

func cancel_poison(scout_id: int) -> void:
	if not poison_jobs.has(scout_id): return
	var job: Dictionary = poison_jobs[scout_id]
	var b: Building = sim.buildings_by_id.get(job.source_id)
	if job.reserved and b != null: b.reserved[Config.Res.TOOLS] = maxf(0,b.reserved[Config.Res.TOOLS]-1.0)
	var scout: Scout = sim.scouting.scouts.get(scout_id) if sim.scouting != null else null
	if scout != null:
		scout.tools += job.kit
		scout.person.clear_goal()
	poison_jobs.erase(scout_id)

func _poison_tick(id: int, delta: float) -> void:
	var job: Dictionary = poison_jobs[id]
	var scout: Scout = sim.scouting.scouts.get(id) if sim.scouting != null else null
	if scout == null or scout.person.service_health <= 0 or (scout.person is Soldier and scout.person.health <= 0):
		cancel_poison(id)
		return
	if _moved.has(_key(scout.person)) or drinkers.has(_key(scout.person)): return
	var target: Building = sim.campaign.enemy_buildings.get(job.target_id)
	if target == null or not wells.has(target.id) or sim.campaign.conquered:
		sim.scouting.recall(id)
		return
	if job.state == "collect":
		var source: Building = sim.buildings_by_id.get(job.source_id)
		if source == null or source.inventory[Config.Res.TOOLS] < 1:
			sim.scouting.recall(id)
			return
		scout.status = "Collecting a well sabotage kit"
		if not _move(scout.person,sim.entrance_of(source,"att_entrance"),delta): return
		source.reserved[Config.Res.TOOLS] = maxf(0,source.reserved[Config.Res.TOOLS]-1.0)
		job.kit = source.remove(Config.Res.TOOLS,1.0)
		job.reserved = false
		job.state = "approach"
		scout.person.clear_goal()
		return
	var distance := scout.person.global_position.distance_to(target.global_position)
	if distance <= 60.0: sim.campaign.at_war = true
	for u in sim.campaign.units.values():
		if u.faction == 1 and u.health > 0 and not u.incapacitated() and u.global_position.distance_to(scout.person.global_position) < 6.0:
			sim.scouting.recall(id)
			scout.status = "Sabotage interrupted; retreating with the kit"
			return
	scout.status = "Approaching the enemy well" if job.state == "approach" else "Tampering with the enemy well"
	if not _move(scout.person,sim.entrance_of(target,"att_entrance"),delta):
		job.progress = 0.0
		return
	job.state = "poisoning"
	job.progress += delta
	if job.progress < POISON_SECONDS: return
	wells[target.id].poison = 1.0
	wells[target.id].poison_days = POISON_DAYS
	job.kit = 0.0
	poison_jobs.erase(id)
	scout.state = "ready"
	scout.status = "Enemy well poisoned; awaiting orders"
	scout.person.clear_goal()

func well_info(id: int) -> Dictionary:
	_sync_wells()
	var b: Building = _buildings().get(id)
	if b == null or not wells.has(id): return {}
	var data: Dictionary = wells[id].duplicate(true)
	data.capacity = CAPACITY
	data.position = b.global_position
	data.poisoned = data.poison > 0
	data.refill_per_day = REFILL_PER_DAY
	return data

func info() -> Dictionary:
	var rows: Array = []
	for b in sim.buildings:
		if wells.has(b.id): rows.append(well_info(b.id))
	var thirsty := 0
	for c in sim.population_members():
		if c.hydration <= SEEK_AT: thirsty += 1
	return {"wells":rows,"thirsty":thirsty,"missions":carriers.size()+poison_jobs.size(),"firefighters":carriers.size()}

func transit(res: int) -> float:
	var total := 0.0
	if res == Config.Res.TOOLS:
		for job in poison_jobs.values(): total += job.kit
	return total

func capture() -> Dictionary:
	_sync_wells()
	var active_people := _people()
	var drinks: Array = []
	for key in drinkers:
		if active_people.has(key): drinks.append(drinkers[key].duplicate())
	var workers: Array = []
	for job in carriers.values():
		var c: Citizen = job.person
		var identity := SaveGame._capture_citizen(c)
		if not sim.buildings_by_id.has(c.home_id): identity.home_id = -1
		workers.append({"citizen":identity,"target_id":job.target_id,"well_id":job.well_id,"state":job.state})
	return {"wells":wells.values().duplicate(true),"drinkers":drinks,"carriers":workers,"poison_jobs":poison_jobs.values().duplicate(true)}

func restore(data: Variant) -> String:
	var error := validate(data,world.size_m)
	if error != "": return error
	if not carriers.is_empty() or not poison_jobs.is_empty(): return "restore water into an empty manager"
	var people := _people()
	for entry in data.get("carriers",[]):
		if people.has("0:%d" % entry.citizen.id): return "water carrier identity is already assigned"
	for entry in data.get("poison_jobs",[]):
		if sim.scouting == null or not sim.scouting.scouts.has(entry.scout_id): return "sabotage mission has no scout"
	for entry in data.get("wells",[]): wells[entry.id] = entry.duplicate()
	for entry in data.get("carriers",[]):
		var identity: Dictionary = entry.citizen
		var c := sim.add_citizen(identity.position,false,identity.asset_id,identity.id,identity.get("body",{}))
		c.apply_state(identity,registry)
		c.position = identity.position
		if c is Soldier: c.rations = identity.get("veteran_rations",0.0)
		sim.detach_for_service(c)
		c.reparent(self)
		carriers[c.id] = {"person":c,"target_id":entry.target_id,"well_id":entry.well_id,"state":entry.state}
		_bucket(c)
	for entry in data.get("drinkers",[]): drinkers["%d:%d" % [entry.faction,entry.person_id]] = entry.duplicate()
	for entry in data.get("poison_jobs",[]):
		if sim.scouting == null or not sim.scouting.scouts.has(entry.scout_id): return "sabotage mission has no scout"
		poison_jobs[entry.scout_id] = entry.duplicate()
		var b: Building = sim.buildings_by_id.get(entry.source_id)
		if entry.reserved and b != null: b.reserved[Config.Res.TOOLS] += 1
	_sync_wells()
	return ""

static func validate(data: Variant, size_m: float) -> String:
	if not data is Dictionary: return "water must be a dictionary"
	if data.is_empty(): return ""
	var error := SaveGame.Validation._fields(data,{"wells":TYPE_ARRAY,"drinkers":TYPE_ARRAY,"carriers":TYPE_ARRAY,"poison_jobs":TYPE_ARRAY},"water")
	if error != "": return error
	if data.wells.size() > 4096 or data.drinkers.size() > 1024 or data.carriers.size() > 128 or data.poison_jobs.size() > 32: return "too many water records"
	var ids := {}
	for well in data.wells:
		error = SaveGame.Validation._fields(well,{"id":TYPE_INT,"water":TYPE_FLOAT,"poison":TYPE_FLOAT,"poison_days":TYPE_FLOAT},"well")
		if error != "": return error
		if well.id < 1 or ids.has(well.id): return "invalid or duplicate well"
		ids[well.id] = true
		if not TradeRoutes._number(well.water,0,CAPACITY) or not TradeRoutes._number(well.poison,0,1) or not TradeRoutes._number(well.poison_days,0,POISON_DAYS): return "invalid well contents"
	ids.clear()
	for entry in data.drinkers:
		error = SaveGame.Validation._fields(entry,{"faction":TYPE_INT,"person_id":TYPE_INT,"well_id":TYPE_INT},"drinker")
		if error != "": return error
		var key := "%d:%d" % [entry.faction,entry.person_id]
		if entry.faction not in [0,1] or entry.person_id < 1 or entry.well_id < 1 or ids.has(key): return "invalid drinker"
		ids[key] = true
	ids.clear()
	for entry in data.carriers:
		error = SaveGame.Validation._fields(entry,{"citizen":TYPE_DICTIONARY,"target_id":TYPE_INT,"well_id":TYPE_INT,"state":TYPE_STRING},"water carrier")
		if error != "": return error
		error = SaveGame.Validation._citizen(entry.citizen,null,size_m)
		if error != "": return error
		if entry.citizen.workplace_id != -1 or entry.citizen.immigrant or ids.has(entry.citizen.id): return "invalid water carrier identity"
		ids[entry.citizen.id] = true
		if entry.target_id < 1 or entry.well_id < 1 or entry.state not in ["fill","carry"]: return "invalid firefighting mission"
		if entry.state == "fill" and entry.citizen.get("water_bucket",0.0) > 0: return "empty carrier has uncollected water"
		if entry.citizen.carrying_amount + entry.citizen.get("water_bucket",0.0) + entry.citizen.get("veteran_rations",0.0) > Config.CARRY_CAPACITY + 0.001: return "overloaded water carrier"
	ids.clear()
	for entry in data.poison_jobs:
		error = SaveGame.Validation._fields(entry,{"scout_id":TYPE_INT,"target_id":TYPE_INT,"source_id":TYPE_INT,"state":TYPE_STRING,"reserved":TYPE_BOOL,"kit":TYPE_FLOAT,"progress":TYPE_FLOAT},"sabotage")
		if error != "": return error
		if entry.scout_id < 1 or entry.target_id < 1 or entry.source_id < 1 or ids.has(entry.scout_id): return "invalid sabotage reference"
		ids[entry.scout_id] = true
		if entry.state not in ["collect","approach","poisoning"] or entry.reserved != (entry.state == "collect"): return "invalid sabotage phase"
		if entry.kit != (0.0 if entry.state == "collect" else 1.0) or not TradeRoutes._number(entry.progress,0,POISON_SECONDS): return "unpaid sabotage kit or invalid progress"
	return ""

static func validate_person(data: Dictionary) -> String:
	var error := SaveGame.Validation._fields(data,{"hydration":TYPE_FLOAT,"water_bucket":TYPE_FLOAT,"water_sickness":TYPE_FLOAT,"service_health":TYPE_FLOAT},"water condition",true)
	if error != "": return error
	if not TradeRoutes._number(data.get("hydration",1.0),0,1) or not TradeRoutes._number(data.get("water_sickness",0.0),0,1) or not TradeRoutes._number(data.get("water_bucket",0.0),0,BUCKET) or not TradeRoutes._number(data.get("service_health",100.0),0,100): return "invalid water condition"
	return ""
