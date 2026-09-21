class_name Scouting
extends Node3D

## Exploration and reports belong to observers, never to the omniscient town model.
signal changed()
const FOG_CELL := 32.0
const TRAIN_SECONDS := Config.DAY_LENGTH * 0.5
const FOOD_PACK := 8.0
const TOOL_COST := 2.0
const STATES := ["food", "tools", "lodge", "training", "ready", "exploring", "visiting", "return", "unloading"]
var sim: Simulation
var world: World
var registry: AssetRegistry
var scouts: Dictionary = {}
var grid_size := 1
var world_size := 1.0
var revision := 0
var _explored := PackedByteArray()
var _visible := PackedByteArray()
var _texture: ImageTexture
var _timer := 0.0
var _next_id := 1
var _report: Dictionary = {}
var _trained: Array[int] = []
var _city_in_sight := false

func setup(p_sim: Simulation, p_world: World, p_registry: AssetRegistry) -> void:
	sim = p_sim
	world = p_world
	registry = p_registry
	sim.stores.scouting = self
	name = "scouting"
	world_size = world.size_m
	grid_size = ceili(world_size / FOG_CELL)
	_explored.resize(grid_size * grid_size)
	_visible.resize(grid_size * grid_size)
	refresh_visibility()

func texture() -> Texture2D:
	return _texture

func _cell(p: Vector3) -> int:
	if not p.is_finite() or p.x < 0 or p.z < 0 or p.x >= world_size or p.z >= world_size: return -1
	return mini(grid_size - 1, int(p.z / FOG_CELL)) * grid_size + mini(grid_size - 1, int(p.x / FOG_CELL))

func visibility_at(p: Vector3) -> bool:
	var i := _cell(p)
	return i >= 0 and _visible[i] > 0

func explored_at(p: Vector3) -> bool:
	var i := _cell(p)
	return i >= 0 and _explored[i] > 0

func _reveal(p: Vector3, radius: float) -> void:
	for z in range(maxi(0, floori((p.z-radius)/FOG_CELL)), mini(grid_size, ceili((p.z+radius)/FOG_CELL))):
		for x in range(maxi(0, floori((p.x-radius)/FOG_CELL)), mini(grid_size, ceili((p.x+radius)/FOG_CELL))):
			var centre := Vector2((x + 0.5) * FOG_CELL, (z + 0.5) * FOG_CELL)
			if centre.distance_to(Vector2(p.x,p.z)) <= radius:
				_visible[z*grid_size+x] = 255
				_explored[z*grid_size+x] = 255

func refresh_visibility() -> void:
	_visible.fill(0)
	for b in sim.buildings:
		if not b.under_construction: _reveal(b.global_position, 96.0)
	for c in sim.citizens: _reveal(c.global_position, 64.0)
	if sim.campaign != null:
		for u in sim.campaign.units.values():
			if u.faction == 0 and u.health > 0: _reveal(u.global_position, 80.0)
	if sim.trade != null:
		for route in sim.trade.caravans.values(): _reveal(route.merchant.global_position, 72.0)
	if sim.water != null:
		for job in sim.water.carriers.values(): _reveal(job.person.global_position,64.0)
	for scout in scouts.values(): _reveal(scout.person.global_position, 128.0 if scout.state not in ["food", "tools", "lodge", "training"] else 64.0)
	_observe_city()
	var pixels := PackedByteArray()
	pixels.resize(_visible.size()*2)
	for i in _visible.size():
		pixels[i*2] = _explored[i]
		pixels[i*2+1] = _visible[i]
	var img := Image.create_from_data(grid_size, grid_size, false, Image.FORMAT_RG8, pixels)
	if _texture == null: _texture = ImageTexture.create_from_image(img)
	else: _texture.update(img)
	revision += 1
	changed.emit()

func city_report() -> Dictionary:
	return _report.duplicate(true)

func _observe_city() -> void:
	if sim.campaign == null: return
	if not visibility_at(sim.campaign.rival_position):
		_city_in_sight = false
		return
	var ruler_history: Dictionary = _report.get("ruler_history",{}).duplicate(true)
	if _report.get("source", "") == "ruler":
		if _city_in_sight: return
		ruler_history = _report.duplicate(true)
		ruler_history.erase("ruler_history")
	_city_in_sight = true
	var seen_people := 0
	for c in sim.campaign._workers:
		if visibility_at(c.global_position): seen_people += 1
	var seen_troops := 0
	for u in sim.campaign.units.values():
		if u.faction == 1 and u.health > 0 and visibility_at(u.global_position): seen_troops += 1
	_report = {"name": sim.campaign.rival_name, "position": sim.campaign.rival_position,
		"last_seen_day": sim.day, "population_text": "%d–%d residents estimated" % [maxi(1,seen_people),maxi(6,seen_people*3)],
		"military_text": "%d soldiers observed" % seen_troops, "source": "observation"}
	if not ruler_history.is_empty(): _report.ruler_history = ruler_history

func _lodge(id: int = -1) -> Building:
	for b in sim.buildings:
		if b.type_id == "scout_lodge" and not b.under_construction and (id < 0 or id == b.id): return b
	return null

func _candidate(id: int = -1) -> Citizen:
	for c in sim.citizens:
		if c.immigrant or c.service_health <= 0 or (id >= 0 and c.id != id): continue
		if c is Soldier and (c.health <= 0 or c.incapacitated() or c.mobility_scale() <= 0): continue
		if c.carrying_amount + (c.rations if c is Soldier else 0.0) > Config.CARRY_CAPACITY - FOOD_PACK - TOOL_COST: continue
		return c
	return null

func _source(res: int, amount: float, from: Vector3) -> Building:
	var best: Building
	var distance := INF
	for b in sim.stores.buildings_storing(res):
		var door := sim.entrance_of(b,"att_entrance")
		if b.under_construction or b.available(res) < amount or not world.nav.can_reach(from,door): continue
		var d := from.distance_squared_to(door)
		if d < distance:
			best = b
			distance = d
	return best

func _training_reason(lodge: Building, c: Citizen) -> String:
	if sim.campaign != null and sim.campaign.defeated: return "The settlement has fallen."
	if lodge == null: return "Build and complete a scout lodge."
	if scouts.size() >= 32: return "All scout assignments are occupied."
	if c == null: return "Choose an available resident with room for a scout pack."
	if not world.nav.can_reach(c.global_position,sim.entrance_of(lodge,"att_entrance")): return "The resident cannot reach the lodge."
	if _source(Config.Res.FOOD,FOOD_PACK,c.global_position) == null: return "Scouting requires eight food at a reachable store."
	if _source(Config.Res.TOOLS,TOOL_COST,c.global_position) == null: return "Training requires two tools at a reachable store."
	return ""

func info() -> Dictionary:
	var lodge := _lodge()
	var reason := _training_reason(lodge,_candidate())
	var rows: Array = []
	for scout in scouts.values():
		rows.append({"id": scout.id, "name": scout.person.given_name, "status": scout.status,
			"position": scout.person.global_position, "training": scout.state in ["food","tools","lodge","training"],
			"can_explore": scout.state in ["ready","exploring","visiting"] and scout.food >= 1,
			"trained": _trained.has(scout.person.id)})
	return {"scouts": rows, "can_train": reason == "", "lodge_id": lodge.id if lodge != null else -1, "reason": reason}

func train(lodge_id: int, citizen_id: int = -1) -> String:
	var lodge := _lodge(lodge_id)
	var c := _candidate(citizen_id)
	var reason := _training_reason(lodge,c)
	if reason != "": return reason
	var food := _source(Config.Res.FOOD,FOOD_PACK,c.global_position)
	var tools := _source(Config.Res.TOOLS,TOOL_COST,c.global_position)
	sim.detach_for_service(c)
	var scout := Scout.new()
	add_child(scout)
	scout.setup(_next_id,c)
	_next_id += 1
	scouts[scout.id] = scout
	scout.lodge_id = lodge.id
	scout.food_source = food.id
	scout.tool_source = tools.id
	scout.training_left = TRAIN_SECONDS * (0.25 if _trained.has(c.id) else 1.0)
	scout.destination = c.global_position
	food.reserved[Config.Res.FOOD] += FOOD_PACK
	tools.reserved[Config.Res.TOOLS] += TOOL_COST
	changed.emit()
	return ""

func command(id: int, destination: Vector3) -> String:
	if sim.water != null and sim.water.poisoning(id): return "Recall the sabotage mission before issuing exploration orders."
	if sim.campaign != null and sim.campaign.defeated: return "The settlement has fallen."
	var scout: Scout = scouts.get(id)
	if scout == null: return "Select a scout."
	if scout.state not in ["ready","exploring","visiting"]: return "Complete training before exploring."
	if scout.food < 1: return "The scout needs to return for supplies."
	if not TradeRoutes._position(destination,world_size) or not world.nav.can_reach(scout.person.global_position,destination): return "No traversable route to that location."
	scout.destination = destination
	scout.state = "exploring"
	scout.status = "Exploring"
	scout.person.clear_goal()
	return ""

func visit_city(id: int) -> String:
	if _report.is_empty(): return "Discover a town before requesting an audience."
	if sim.campaign == null or sim.campaign.at_war or sim.campaign.conquered: return "The ruler is not receiving visitors."
	var keep := _rival_keep()
	if keep == null: return "The town has no standing keep."
	var error := command(id,sim.campaign._door(keep))
	if error != "": return error
	scouts[id].state = "visiting"
	scouts[id].status = "Visiting the ruler"
	return ""

func _rival_keep() -> Building:
	if sim.campaign == null: return null
	for b in sim.campaign.enemy_buildings.values():
		if b.def.role == BuildingDefs.Role.SEAT: return b
	return null

func _release(scout: Scout) -> void:
	for item in [[scout.food_reserved,scout.food_source,Config.Res.FOOD,FOOD_PACK],[scout.tools_reserved,scout.tool_source,Config.Res.TOOLS,TOOL_COST]]:
		var b: Building = sim.buildings_by_id.get(item[1])
		if item[0] and b != null: b.reserved[item[2]] = maxf(0,b.reserved[item[2]]-item[3])
	scout.food_reserved = false
	scout.tools_reserved = false

func recall(id: int) -> String:
	if sim.water != null: sim.water.cancel_poison(id)
	var scout: Scout = scouts.get(id)
	if scout == null: return "Select an active scout."
	_release(scout)
	scout.state = "return"
	scout.status = "Returning home"
	scout.person.clear_goal()
	return ""

func _move(scout: Scout, p: Vector3, delta: float) -> bool:
	if scout.person is Soldier and scout.person.incapacitated():
		scout.status = "Incapacitated; needs medical aid"
		return false
	scout.person.set_goal(p)
	scout.person.advance(delta,world)
	if scout.person.unreachable: scout.status = "Waiting for a traversable route"
	return scout.person.has_arrived()

func tick(delta: float) -> void:
	if delta <= 0 or not is_finite(delta): return
	for scout: Scout in scouts.values().duplicate():
		var c := scout.person
		if not sim.buildings_by_id.has(c.home_id): c.home_id = -1
		if (c is Soldier and c.health <= 0) or scout.health <= 0:
			_lose(scout)
			continue
		_feed(scout,delta)
		_danger(scout,delta)
		if scout.health <= 0 or (c is Soldier and c.health <= 0):
			_lose(scout)
			continue
		if sim.water != null and sim.water.handles(c):
			c.task_label = scout.status
			continue
		if scout.state in ["food","tools","lodge","training"] and _lodge(scout.lodge_id) == null: recall(scout.id)
		match scout.state:
			"food", "tools": _collect(scout,delta)
			"lodge":
				if _move(scout,sim.entrance_of(_lodge(scout.lodge_id),"att_entrance"),delta):
					scout.tools -= TOOL_COST
					scout.state = "training"
					scout.status = "Learning fieldcraft at the lodge"
			"training":
				if c is Soldier and c.incapacitated(): continue
				scout.training_left = maxf(0,scout.training_left-delta)
				if scout.training_left <= 0:
					if not _trained.has(c.id): _trained.append(c.id)
					if c is Soldier: c.practice("scouting",10.0)
					scout.state = "ready"
					scout.status = "Ready for orders"
			"exploring", "visiting":
				if _move(scout,scout.destination,delta):
					if scout.state == "visiting": _interview(scout)
					scout.state = "ready"
					scout.status = "Awaiting orders in the field"
			"return":
				var home := _lodge(scout.lodge_id)
				if home == null: home = sim.keep
				if home == null or _move(scout,sim.entrance_of(home,"att_entrance"),delta): scout.state = "unloading"
			"unloading": _unload(scout,delta)
		if scouts.has(scout.id): c.task_label = scout.status
	_timer -= delta
	if _timer <= 0:
		_timer = 0.5
		refresh_visibility()

func _feed(scout: Scout, delta: float) -> void:
	var c := scout.person
	var need := delta / Config.DAY_LENGTH * Config.HUNGER_PER_DAY
	var eaten := minf(scout.food,need)
	scout.food -= eaten
	need -= eaten
	if need > 0 and c is Soldier:
		eaten = minf(c.rations,need)
		c.rations -= eaten
		need -= eaten
	if need > 0 and c.carrying_res == Config.Res.FOOD:
		eaten = minf(c.carrying_amount,need)
		c.carrying_amount -= eaten
		need -= eaten
		if c.carrying_amount <= 0.00001: c.drop()
	if need > 0:
		for b in sim.stores.buildings_storing(Config.Res.FOOD):
			if b.under_construction or c.global_position.distance_to(sim.entrance_of(b,"att_entrance")) > Config.ARRIVE_RADIUS + 0.25: continue
			need -= b.remove(Config.Res.FOOD,minf(need,b.available(Config.Res.FOOD)))
			if need <= 0: break
	c.hunger = clampf(c.hunger + need - (delta / Config.DAY_LENGTH - need),0,1)
	c.next_meal = Config.next_meal_after(sim.day)
	if c.hunger >= 1:
		if c is Soldier: c.apply_damage(delta*0.15)
		else: scout.health = maxf(0,scout.health-delta*0.15)
	if scout.food < 1 and scout.state in ["ready","exploring","visiting"]: recall(scout.id)

func _danger(scout: Scout, _delta: float) -> void:
	if sim.campaign == null or not sim.campaign.at_war: return
	for u in sim.campaign.units.values():
		if u.faction != 1 or u.health <= 0 or u.incapacitated(): continue
		if u.global_position.distance_to(scout.person.global_position) > 3.0: continue
		# Share the patrol's ordinary attack cooldown; it cannot hit a soldier
		# and several scouts simultaneously during the same combat tick.
		if u.cooldown > 0 or not u.strike(scout.person.global_position): continue
		u.cooldown = 1.0
		if scout.person is Soldier: scout.person.receive_hit("torso","slash",7.0)
		else: scout.health = maxf(0,scout.health-7.0)

func _collect(scout: Scout, delta: float) -> void:
	var is_food := scout.state == "food"
	var b: Building = sim.buildings_by_id.get(scout.food_source if is_food else scout.tool_source)
	var res := Config.Res.FOOD if is_food else Config.Res.TOOLS
	var amount := FOOD_PACK if is_food else TOOL_COST
	if b == null or b.under_construction or b.inventory[res] < amount:
		recall(scout.id)
		return
	if not _move(scout,sim.entrance_of(b,"att_entrance"),delta): return
	b.reserved[res] = maxf(0,b.reserved[res]-amount)
	var got := b.remove(res,amount)
	if is_food:
		scout.food_reserved = false
		scout.food = got
		scout.state = "tools"
	else:
		scout.tools_reserved = false
		scout.tools = got
		scout.state = "lodge"
	scout.person.clear_goal()

func _interview(scout: Scout) -> void:
	var keep := _rival_keep()
	if keep == null or sim.campaign.at_war or sim.campaign.conquered or scout.person.global_position.distance_to(sim.campaign._door(keep)) > Config.ARRIVE_RADIUS + 0.5: return
	var troops := 0
	for u in sim.campaign.units.values():
		if u.faction == 1 and u.health > 0: troops += 1
	_report = {"name": sim.campaign.rival_name, "position": keep.global_position,
		"last_seen_day": sim.day, "population_text": "%d residents confirmed" % (sim.campaign.town_population + troops),
		"military_text": "%d soldiers confirmed" % troops, "source": "ruler"}
	_city_in_sight = true

func _unload(scout: Scout, delta: float) -> void:
	var c := scout.person
	var res := Config.Res.TOOLS if scout.tools > 0.00001 else Config.Res.FOOD
	var amount := scout.tools if res == Config.Res.TOOLS else scout.food
	var personal := amount <= 0.00001 and c.carrying_amount > 0.00001
	if personal:
		res = c.carrying_res
		amount = c.carrying_amount
	if amount <= 0.00001:
		_release(scout)
		scouts.erase(scout.id)
		c._body.remove_meta("scout_id")
		sim.return_from_service(c,c.id)
		scout.queue_free()
		changed.emit()
		return
	var b := sim.stores.find_store(res,c.global_position,-1)
	if b == null:
		scout.status = "Waiting for storage space; carrying the supplies"
		return
	if not _move(scout,sim.entrance_of(b,"att_entrance"),delta): return
	var put := b.add(res,amount)
	if personal:
		c.carrying_amount = maxf(0,c.carrying_amount-put)
		if c.carrying_amount <= 0.00001: c.drop()
	elif res == Config.Res.TOOLS: scout.tools = maxf(0,scout.tools-put)
	else: scout.food = maxf(0,scout.food-put)
	c.clear_goal()

func _lose(scout: Scout) -> void:
	if sim.water != null: sim.water.cancel_poison(scout.id)
	_release(scout)
	var c := scout.person
	var home: Building = sim.buildings_by_id.get(c.home_id)
	if home != null: home.residents.erase(c.id)
	_trained.erase(c.id)
	scouts.erase(scout.id)
	var last_contact := home.global_position if home != null else (sim.keep.global_position if sim.keep != null else world.centre())
	sim.alert.emit("Lost contact with %s. The scout has not returned." % c.given_name,last_contact)
	scout.queue_free()
	sim.workforce.mark_all_dirty()
	changed.emit()

func transit(res: int) -> float:
	var total := 0.0
	for scout in scouts.values():
		if res == Config.Res.FOOD: total += scout.food
		elif res == Config.Res.TOOLS: total += scout.tools
	return total

func capture() -> Dictionary:
	refresh_visibility()
	var entries: Array = []
	for scout in scouts.values():
		var entry: Dictionary = scout.record()
		if not sim.buildings_by_id.has(entry.citizen.home_id): entry.citizen.home_id = -1
		entries.append(entry)
	return {"next_id": _next_id, "scouts": entries, "explored": _explored.duplicate(), "report": _report.duplicate(true), "city_in_sight": _city_in_sight, "trained": _trained.duplicate()}

func restore(data: Variant) -> String:
	var error := validate(data,world_size,sim.buildings_by_id)
	if error != "": return error
	if not scouts.is_empty(): return "restore scouting into an empty manager"
	var identities := {}
	for c in sim.population_members(): identities[c.id] = true
	for entry in data.get("scouts",[]):
		if identities.has(entry.citizen.id): return "scout identity is already assigned to another role"
		identities[entry.citizen.id] = true
	_next_id = data.get("next_id",1)
	_report = data.get("report",{}).duplicate(true)
	_city_in_sight = data.get("city_in_sight",false)
	_trained.assign(data.get("trained",[]))
	if data.has("explored"): _explored = data.explored.duplicate()
	for entry in data.get("scouts",[]):
		var identity: Dictionary = entry.citizen
		var c := sim.add_citizen(identity.position,false,identity.asset_id,identity.id,identity.get("body",{}))
		c.apply_state(identity,registry)
		c.position = identity.position
		if c is Soldier: c.rations = identity.get("veteran_rations",0.0)
		sim.detach_for_service(c)
		var scout := Scout.new()
		add_child(scout)
		scout.setup(entry.id,c)
		for key in scout.record():
			if key not in ["id","citizen"]: scout.set(key,entry[key])
		scouts[scout.id] = scout
		for item in [[scout.food_reserved,scout.food_source,Config.Res.FOOD,FOOD_PACK],[scout.tools_reserved,scout.tool_source,Config.Res.TOOLS,TOOL_COST]]:
			var b: Building = sim.buildings_by_id.get(item[1])
			if item[0] and b != null: b.reserved[item[2]] += item[3]
	# Old saves with dispatched merchants already contain knowledge of that route.
	if data.is_empty() and sim.trade != null and not sim.trade.caravans.is_empty() and sim.campaign != null:
		_report = {"name":sim.campaign.rival_name,"position":sim.campaign.rival_position,"last_seen_day":sim.day,
			"population_text":"Population unknown","military_text":"Military unknown","source":"merchant route"}
	refresh_visibility()
	return ""

static func validate(data: Variant, size_m: float, buildings: Variant = null) -> String:
	if not data is Dictionary: return "scouting must be a dictionary"
	if data.is_empty(): return ""
	var error := SaveGame.Validation._fields(data,{"next_id":TYPE_INT,"scouts":TYPE_ARRAY,"explored":TYPE_PACKED_BYTE_ARRAY,"report":TYPE_DICTIONARY,"trained":TYPE_ARRAY},"scouting")
	if error != "": return error
	if not data.get("city_in_sight",false) is bool: return "invalid city contact state"
	if data.next_id < 1 or data.next_id > 2147483647 or data.scouts.size() > 32: return "invalid scout identifiers"
	var cells := ceili(size_m/FOG_CELL)
	if data.explored.size() != cells*cells: return "invalid exploration grid"
	for value in data.explored:
		if value not in [0,255]: return "invalid explored cell"
	error = SaveGame.Validation._ids(data.trained,"trained scouts",1,2147483647)
	if error != "": return error
	if not data.report.is_empty():
		error = SaveGame.Validation._fields(data.report,{"name":TYPE_STRING,"position":TYPE_VECTOR3,"last_seen_day":TYPE_FLOAT,"population_text":TYPE_STRING,"military_text":TYPE_STRING,"source":TYPE_STRING},"city report")
		if error != "": return error
		if not TradeRoutes._position(data.report.position,size_m) or data.report.last_seen_day < 0 or data.report.source not in ["observation","ruler","merchant route"]: return "invalid city observation"
		for report in [data.report,data.report.get("ruler_history",{})]:
			if not report is Dictionary: return "invalid ruler history"
			if report.is_empty(): continue
			error = SaveGame.Validation._fields(report,{"name":TYPE_STRING,"position":TYPE_VECTOR3,"last_seen_day":TYPE_FLOAT,"population_text":TYPE_STRING,"military_text":TYPE_STRING,"source":TYPE_STRING},"city history")
			if error != "": return error
			if not TradeRoutes._position(report.position,size_m) or report.last_seen_day < 0 or report.last_seen_day > data.report.last_seen_day: return "invalid city history date or position"
			for key in ["name","population_text","military_text"]:
				if report[key].length() > 160: return "invalid city report text"
	var ids := {}
	var reservations := {}
	for entry in data.scouts:
		error = SaveGame.Validation._fields(entry,{"id":TYPE_INT,"citizen":TYPE_DICTIONARY,"lodge_id":TYPE_INT,"state":TYPE_STRING,"status":TYPE_STRING,
			"food_source":TYPE_INT,"tool_source":TYPE_INT,"food_reserved":TYPE_BOOL,"tools_reserved":TYPE_BOOL,
			"food":TYPE_FLOAT,"tools":TYPE_FLOAT,"training_left":TYPE_FLOAT,"destination":TYPE_VECTOR3,"health":TYPE_FLOAT},"scout")
		if error != "": return error
		if entry.id < 1 or entry.id >= data.next_id or ids.has(entry.id): return "duplicate or invalid scout id"
		ids[entry.id] = true
		error = SaveGame.Validation._citizen(entry.citizen,null,size_m)
		if error != "": return error
		if entry.citizen.workplace_id != -1 or entry.citizen.immigrant: return "scout cannot also hold a civilian job"
		if entry.state not in STATES or entry.status.length() > 240 or not TradeRoutes._position(entry.destination,size_m): return "invalid scout orders"
		for key in ["lodge_id","food_source","tool_source"]:
			if entry[key] < 1 or entry[key] >= 2147483647: return "invalid scout building reference"
		if not TradeRoutes._number(entry.food,0,FOOD_PACK) or not TradeRoutes._number(entry.tools,0,TOOL_COST) or not TradeRoutes._number(entry.training_left,0,TRAIN_SECONDS) or not TradeRoutes._number(entry.health,0,100): return "invalid scout supplies or training"
		if not is_equal_approx(entry.health,entry.citizen.get("service_health",100.0)): return "scout health differs from resident health"
		if entry.food + entry.tools + entry.citizen.carrying_amount + entry.citizen.get("veteran_rations",0.0) > Config.CARRY_CAPACITY + 0.001: return "overloaded scout"
		if entry.food_reserved != (entry.state == "food") or entry.tools_reserved != (entry.state in ["food","tools"]): return "scout reservation does not match phase"
		if entry.state == "food" and entry.food > 0: return "scout has uncollected provisions"
		if entry.state in ["food","tools"] and entry.tools > 0: return "scout has uncollected tools"
		if entry.state == "lodge" and entry.tools != TOOL_COST: return "scout lacks training tools"
		if entry.state in ["training","ready","exploring","visiting"] and entry.tools != 0: return "trained scout retains consumed tools"
		if entry.state in ["ready","exploring","visiting"] and (entry.training_left != 0 or not data.trained.has(entry.citizen.id)): return "scout is active without completed training"
		if buildings != null:
			for item in [[entry.food_reserved,entry.food_source,Config.Res.FOOD,FOOD_PACK],[entry.tools_reserved,entry.tool_source,Config.Res.TOOLS,TOOL_COST]]:
				var b: Variant = buildings.get(item[1])
				if not item[0] or b == null: continue
				var key := "%d:%d" % [item[1],item[2]]
				reservations[key] = float(reservations.get(key,0))+item[3]
				var inventory: PackedFloat32Array = b.inventory
				if reservations[key] > inventory[item[2]] + 0.001: return "scout reservations exceed real stock"
	return ""
