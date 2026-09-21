class_name FrontierCampaign
extends Node3D

## One physical rival town and its expeditionary forces. Food belongs to local
## stores or soldiers' packs; marching, resupply and attacks happen on the map.
const PERSONALITIES := ["aggressive", "peaceful", "loner"]
const RECRUIT_COST := {Config.Res.TOOLS: 5, Config.Res.FOOD: 10}
const PACK_DAYS := 4.0
const SUPPLY_REACH := 24.0
const GUARD_SIGHT := 60.0
const CONTACT_COOLDOWN := 60.0
var sim: Simulation
var world: World
var registry: AssetRegistry
var units: Dictionary = {}
var enemy_buildings: Dictionary = {}
var rival_position := Vector3.ZERO
var rival_name := "Ashcombe"
var personality := "peaceful"
var at_war := false
var defeated := false
var conquered := false
var town_population := 8
var _next_id := 100000
var _time := 0.0
var _review := 0.0
var _recruit_at := 0.0
var _workers: Array[Citizen] = []
var _worker_leg: Dictionary = {}
var _worker_wait: Dictionary = {}
var _impacts: Array = []
var _ruins: Array = []
var _civilian_ids: Dictionary = {} # military id -> the person's permanent civilian id
var _rng := RandomNumberGenerator.new()
var _contact_cooldown := 0.0
var _visible_contacts: Array[int] = []
var _contact_pending := false
var _contact_war := false
var _guard_contacts: Dictionary = {}

func setup(p_sim: Simulation, p_world: World, p_registry: AssetRegistry) -> void:
	sim = p_sim
	world = p_world
	registry = p_registry
	_rng.seed = world.world_seed + 19037
	personality = PERSONALITIES[_rng.randi_range(0, PERSONALITIES.size() - 1)]
	name = "frontier"

func _site(anchor: Vector3, type_id: String) -> Vector3:
	for ring in 20:
		for i in 16:
			var p := anchor + Vector3(cos(i * TAU / 16), 0, sin(i * TAU / 16)) * ring * 5.0
			if p.x < 35 or p.z < 35 or p.x > world.size_m - 35 or p.z > world.size_m - 35: continue
			if world.generation_version >= 2:
				var river_phase := float(posmod(world.world_seed, 997)) / 997.0 * TAU
				if p.x < world.heightmap.river_centre(p.z, river_phase) + 36.0: continue
			p.y = world.heightmap.height_at(p.x,p.z)
			# Generated towns represent previously cleared ground. Their builder
			# clears resources below; player placement must obtain that clearing.
			if not sim.can_place(type_id,p,0.0,-1,false).ok: continue
			if type_id == "farm" and not _has_farmland(p): continue
			var overlaps := false
			for other in enemy_buildings.values():
				if other.position.distance_to(p) < 25.0: overlaps = true
			if overlaps or not world.nav.can_reach(world.centre(),p): continue
			return p
	return Vector3.INF

func _has_farmland(position: Vector3) -> bool:
	# A buildable farmhouse can still stand on barren soil. Require enough
	# viable outer-ring cells to begin the same layout create_fields grows.
	var origin := world.world_to_cell(position)
	var plots := 0
	for z in range(-2, 3):
		for x in range(-2, 3):
			if maxi(absi(x), absi(z)) != 2: continue
			var cell := origin + Vector2i(x, z)
			if not world.in_bounds(cell) or world.nav.is_solid(cell.x, cell.y): continue
			if world.heightmap.cell_slope(cell.x, cell.y) > 0.22: continue
			if world.heightmap.cell_surface(cell.x, cell.y) == Heightmap.Surface.WATER: continue
			if world.heightmap.cell_fertility(cell.x, cell.y) >= 0.12:
				plots += 1
	return plots >= 3

func generate_rival() -> void:
	if not enemy_buildings.is_empty() or not units.is_empty():
		return
	var across_river := world.generation_version >= 2
	var first_offset := Vector3(280, 0, -70) if across_river else Vector3(210, 0, -180)
	var second_offset := Vector3(290, 0, 60) if across_river else Vector3(180, 0, 190)
	var at := _site(world.centre() + first_offset, "keep")
	if at == Vector3.INF: at = _site(world.centre() + second_offset, "keep")
	if at == Vector3.INF: return
	rival_position = at
	var keep := _create_building("keep", at)
	keep.inventory[Config.Res.FOOD] = 100.0
	# Initial regional surplus, seeded once; trade never replenishes it for free.
	keep.inventory[Config.Res.IRON] = 32.0
	for item in [["house",Vector3(-30,0,28)], ["house",Vector3(0,0,36)], ["farm",Vector3(35,0,30)], ["granary",Vector3(35,0,-8)], ["well",Vector3(-35,0,-12)]]:
		var p := _site(at + item[1], item[0])
		if p != Vector3.INF: _create_building(item[0], p)
	var farm := _enemy_type("farm")
	if farm != null:
		farm.inventory[Config.Res.FOOD] = 30.0
		for i in 3:
			var worker := Citizen.new()
			add_child(worker)
			worker.setup(_allocate(),registry,_rng)
			worker._body.collision_layer = 0
			worker.position = _door(keep) + Vector3(i,0,0)
			worker._wear_anchor = worker.position
			worker.profession = "Ashcombe grower"
			_workers.append(worker)
			_worker_leg[worker.id] = 0
			_worker_wait[worker.id] = 0.0
			farm.workers.append(worker.id)
		farm.create_fields(world.heightmap,world.nav,registry)
		farm.sync_fields_to_workers()
		farm.set_crop_growth(0.7)
		_protect_farm(farm, true, true)
	for i in 3: _spawn_unit(1, at + Vector3(i*3-3,0,-16))
	_recruit_at = Config.DAY_LENGTH * 4.0

func _allocate() -> int:
	var value := _next_id
	_next_id += 1
	return value

func _create_building(type_id: String, p: Vector3, id: int = -1, restoring: bool = false) -> Building:
	var b := Building.new()
	b.setup(_allocate() if id < 0 else id, BuildingDefs.get_def(type_id),registry)
	add_child(b)
	b.position = p
	if not restoring:
		# Rival foundations need the same level pad as player buildings. A
		# centre-height sample alone buries one wall and floats the opposite
		# wall on otherwise buildable slopes. Saves already replay this edit.
		var half_w := b.footprint.x * 0.5
		var half_d := b.footprint.y * 0.5
		b.position.y = world.heightmap.flatten(p, half_w + 1.5, half_d + 1.5)
		world.terrain.rebuild_region(p, half_w + 8.0, half_d + 8.0)
	b.ground_y = b.position.y
	b.under_construction = false
	b.build_progress = 1.0
	b._apply_construction_visual()
	b._body.remove_meta("building_id")
	b._body.set_meta("rival_building_id",b.id)
	b._body.collision_layer = 8
	if not restoring:
		world.nodes.clear_area(b.position,maxf(b.footprint.x,b.footprint.y)*0.6)
	world.nav.block_footprint(b.position,b.footprint.x*0.4,b.footprint.y*0.4,true)
	enemy_buildings[b.id] = b
	return b

func _spawn_unit(faction: int, p: Vector3, id: int = -1,
		body_asset: String = "citizen_male_base", civilian_id: int = -1) -> Soldier:
	var unit := Soldier.new()
	add_child(unit)
	unit.setup_unit(registry,world.heightmap,_allocate() if id < 0 else id,faction,p,body_asset)
	units[unit.id] = unit
	if faction == 0:
		_civilian_ids[unit.id] = civilian_id if civilian_id > 0 else sim.allocate_citizen_identity()
	return unit


func _protect_farm(farm: Building, enabled: bool, clear_existing: bool = false) -> void:
	for plot in farm.all_plots():
		var cell := world.world_to_cell(plot)
		world.nav.set_cultivated(cell.x, cell.y, false)
		world.wear.set_protected(plot, Config.CELL * 0.5, false)
	if not enabled: return
	for plot in farm.fields:
		var cell := world.world_to_cell(plot)
		world.nav.set_cultivated(cell.x, cell.y, enabled)
		world.wear.set_protected(plot, Config.CELL * 0.5, enabled, clear_existing)

func friendly_ids() -> Array[int]:
	var ids: Array[int] = []
	for u in units.values():
		if u.faction == 0: ids.append(u.id)
	return ids

func can_recruit() -> bool:
	if defeated: return false
	var recruit := _recruit_candidate()
	if recruit == null: return false
	for b in sim.buildings:
		if b.type_id == "barracks" and not b.under_construction:
			return sim.can_afford(_recruit_cost(recruit))
	return false

func _recruit_candidate(citizen_id: int = -1) -> Citizen:
	var best: Citizen
	for citizen in sim.citizens:
		if citizen.immigrant or citizen.service_health <= 0 or (citizen_id >= 0 and citizen.id != citizen_id): continue
		if citizen is Soldier and citizen.health <= 0.0: continue
		if best == null or (citizen.workplace_id < 0 and best.workplace_id >= 0) \
				or ((citizen.workplace_id < 0) == (best.workplace_id < 0) and citizen.id < best.id):
			best = citizen
	return best

func _recruit_cost(citizen: Citizen) -> Dictionary:
	var cost := RECRUIT_COST.duplicate()
	# A returning veteran keeps any unused personal food; training uses six
	# food and the rest fills the four-day pack, without discarding leftovers.
	if citizen is Soldier:
		cost[Config.Res.FOOD] = 10.0 - citizen.rations
	return cost

func recruit(citizen_id: int = -1) -> String:
	if defeated: return "Your keep has fallen."
	var citizen := _recruit_candidate(citizen_id)
	if citizen == null: return "No settled civilians remain to recruit."
	var barracks: Building
	for b in sim.buildings:
		if b.type_id == "barracks" and not b.under_construction:
			barracks = b
			break
	if barracks == null: return "Build a barracks before recruiting residents."
	if not sim.stores.try_spend(_recruit_cost(citizen)): return "Recruitment needs 5 available tools and supplies for training and a four-day pack."
	var identity := SaveGame._capture_citizen(citizen)
	identity.workplace_id = -1
	sim.detach_for_service(citizen)
	var unit: Soldier
	if citizen is Soldier:
		unit = citizen
		unit.id = _allocate()
		unit.reparent(self)
		unit.set_civilian_mode(false)
		units[unit.id] = unit
		_civilian_ids[unit.id] = identity.id
	else:
		unit = _spawn_unit(0, citizen.position, -1, citizen.asset_id, citizen.id)
		unit.apply_state(identity, registry)
		# An ordinary resident's travel injuries predate a detailed soldier
		# body. Carry that deficit into systemic strain exactly once; veterans
		# above already retain their authoritative body through every role.
		unit.apply_damage(100.0 - citizen.service_health)
		unit.position = citizen.position
		citizen.queue_free()
	unit.rations = PACK_DAYS
	unit.name = "soldier_%d" % unit.id
	unit.task_label = "holding position"
	unit.target_id = -1
	unit.target_kind = ""
	unit.cooldown = 0.0
	unit.fire_cooldown = 0.0
	unit._wear_anchor = unit.position
	sim.stores.refresh_totals(sim.population_members(), sim.buildings)
	return ""

func demobilize(unit_id: int) -> String:
	var unit: Soldier = units.get(unit_id)
	if unit == null or unit.faction != 0 or unit.health <= 0.0:
		return "Select a living soldier from your army."
	if defeated: return "Your keep has fallen."
	if at_war:
		for enemy in units.values():
			if enemy.faction == 1 and enemy.health > 0.0 \
					and unit.position.distance_to(enemy.position) <= SUPPLY_REACH:
				return "Move out of combat before returning to civilian life."
	var citizen_id: int = _civilian_ids[unit.id]
	if not sim.buildings_by_id.has(unit.home_id): unit.home_id = -1
	_unregister_unit(unit)
	sim.return_from_service(unit, citizen_id)
	return ""


func medic_quote(unit_id: int) -> Dictionary:
	var unit: Soldier = units.get(unit_id)
	var reason := ""
	var cost := {Config.Res.TOOLS: 4, Config.Res.FOOD: 4}
	if unit == null or unit.faction != 0 or unit.health <= 0.0:
		reason = "Select a living soldier."
	elif unit.incapacitated():
		reason = "This soldier needs care before serving as a medic."
	elif unit.medical_supplies > 18:
		reason = "The medical pack is full."
	else:
		var nearby := false
		for b in sim.buildings:
			if b.type_id == "barracks" and not b.under_construction \
					and unit.position.distance_to(_door(b)) <= SUPPLY_REACH \
					and world.nav.can_reach(unit.position, _door(b)):
				nearby = true
				break
		if not nearby: reason = "Return within 24 m of a completed barracks."
		elif not sim.stores.can_afford(cost): reason = "Two medical kits need 4 tools and 4 food."
	return {"can_fit": reason == "", "reason": reason, "cost": cost}


func equip_medic(unit_id: int) -> String:
	var offer := medic_quote(unit_id)
	if not offer.can_fit: return offer.reason
	if not sim.stores.try_spend(offer.cost): return "Those supplies are already reserved."
	var unit: Soldier = units[unit_id]
	unit.configure_medic(2)
	return ""


func _tick_medic(unit: Soldier) -> bool:
	if unit.medical_role != "medic" or unit.medical_supplies <= 0 or unit.incapacitated():
		return false
	var patient: Soldier
	var best := -INF
	var patients: Array = units.values()
	if unit.faction == 0:
		for citizen in sim.population_members():
			if citizen is Soldier and not patients.has(citizen): patients.append(citizen)
	for other in patients:
		if other.faction != unit.faction or not unit.can_treat(other): continue
		var distance := unit.position.distance_to(other.position)
		if distance > SUPPLY_REACH or not world.nav.can_reach(unit.position, other.position): continue
		# Unconscious patients take priority, then the nearest treatable wound.
		var priority: float = (100.0 if other.incapacitated() else 0.0) - distance
		if priority > best:
			best = priority
			patient = other
	if patient == null: return false
	unit.target_id = -1
	unit.target_kind = ""
	unit.task_label = "Tending " + patient.given_name
	if unit.position.distance_to(patient.position) > 3.0:
		unit.order_move(patient.position)
	else:
		unit.clear_goal()
		if unit.cooldown <= 0.0:
			unit.treat(patient)
			unit.cooldown = 3.0
	return true

func set_personality(value: String) -> bool:
	if value not in PERSONALITIES: return false
	personality = value
	return true

func info() -> Dictionary:
	var food := 0.0
	for u in units.values():
		if u.faction == 0: food += u.rations
	var candidate := _recruit_candidate()
	var report: Dictionary = sim.scouting.city_report() if sim.scouting != null else {}
	return {"units":friendly_ids().size(),"rations":food,"can_recruit":can_recruit(),
		"recruit_cost":_recruit_cost(candidate) if candidate != null else RECRUIT_COST.duplicate(),
		"civilians":sim.citizens.size(),"population":sim.population_members().size(),
		"rival_name":report.get("name", "No settlement reported"),
		"status":"At war. Protect your food relays." if at_war else "Send scouts to learn about neighboring settlements."}

func command(ids: Array[int], ground: Vector3, target: Dictionary = {}) -> void:
	if defeated or not _position(ground, world.size_m):
		return
	var target_id: int = target.get("id", -1) if target.get("id", -1) is int else -1
	var target_kind: String = target.get("kind", "") if target.get("kind", "") is String else ""
	if target_id >= 0:
		if target_kind == "unit":
			var enemy: Soldier = units.get(target_id)
			if enemy == null or enemy.faction != 1 or enemy.health <= 0.0:
				return
		elif target_kind != "building" or not enemy_buildings.has(target_id):
			return
	else:
		target_kind = ""
	var offset := 0
	var commanded := {}
	for id in ids:
		var u: Soldier = units.get(id)
		if u == null or u.faction != 0 or u.health <= 0.0 or commanded.has(id): continue
		commanded[id] = true
		u.target_id = target_id
		u.target_kind = target_kind
		if u.target_id >= 0:
			at_war = true
			u.task_label = "attacking " + rival_name
		else:
			u.task_label = "marching"
		var destination := ground + Vector3((offset % 4)*2,0,(offset / 4)*2)
		destination.x = clampf(destination.x, 0.5, world.size_m - 0.5)
		destination.z = clampf(destination.z, 0.5, world.size_m - 0.5)
		u.order_move(destination)
		offset += 1

func pick_target(origin: Vector3, direction: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(origin,origin+direction*4000.0,8)
	q.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty(): return {}
	var node: Node = hit.collider
	if node.has_meta("rival_building_id"):
		if sim.scouting != null and not sim.scouting.visibility_at(hit.position): return {}
		return {"kind":"building","id":int(node.get_meta("rival_building_id"))}
	if node.has_meta("unit_id"):
		var u: Soldier = units.get(int(node.get_meta("unit_id")))
		if u != null and sim.scouting != null and not sim.scouting.visibility_at(u.position): return {}
		if u != null and u.faction == 1: return {"kind":"unit","id":u.id}
	return {}

func _enemy_type(type_id: String) -> Building:
	for b in enemy_buildings.values():
		if b.type_id == type_id: return b
	return null

func _door(b: Building) -> Vector3:
	return sim.entrance_of(b,"att_cart_bay")

func tick(delta: float) -> void:
	if defeated or delta <= 0.0 or not is_finite(delta): return
	Soldier.advance_projectiles(world.effects_root, delta)
	_time += delta
	_tick_town(delta)
	for event in _impacts.duplicate():
		event.wait -= delta
		if event.wait <= 0:
			var b: Building = enemy_buildings.get(event.id) if event.faction == 0 else sim.buildings_by_id.get(event.id)
			if b != null: b.apply_damage(6.0,0.55)
			_impacts.erase(event)
	for b in enemy_buildings.values().duplicate():
		if b.tick_fire(delta): _destroy_enemy(b)
	for b in sim.buildings.duplicate():
		if b.tick_fire(delta):
			if b == sim.keep:
				defeated = true
				sim.alert.emit("Your keep has fallen. Load a save to try again.",b.position)
			else:
				sim.alert.emit("%s burned down" % b.display_name(),b.position)
				sim.demolish(b,false)
	_review -= delta
	if _review <= 0:
		_review = 2.0
		_assign_guards()
	for u in units.values().duplicate():
		u.advance_condition(delta)
		if u.health <= 0.0:
			_remove_unit(u)
			continue
		if u.faction == 0 and not sim.buildings_by_id.has(u.home_id):
			u.home_id = -1
		u.rations = maxf(0.0,u.rations-delta/Config.DAY_LENGTH)
		_refill(u)
		u.speed_modifier = 0.65 if u.rations <= 0 else 1.0
		if u.rations <= 0: u.apply_damage(delta * 0.15)
		u.cooldown = maxf(0,u.cooldown-delta)
		u.fire_cooldown = maxf(0,u.fire_cooldown-delta)
		if u.health <= 0:
			_remove_unit(u)
			continue
		if sim.water != null and sim.water.handles(u): continue
		if u.incapacitated():
			u.clear_goal()
			u.task_label = "Incapacitated — needs a medic"
		elif not _tick_guard_security(u) and not _tick_medic(u):
			_tick_combat(u,delta)
		u.tick(delta,world)
	_tick_security(delta)


func _tick_security(delta: float) -> void:
	# Only current friendly sight can produce a contact or its alert position.
	# Remember identities/cooldown, never track an unseen enemy's coordinates.
	_contact_cooldown = maxf(0.0, _contact_cooldown - delta)
	var seen: Array[int] = []
	var nearest: Soldier
	var distance := INF
	if sim.scouting != null:
		for other: Soldier in units.values():
			if other.faction != 1 or other.health <= 0.0 \
					or not sim.scouting.visibility_at(other.position): continue
			seen.append(other.id)
			if not _visible_contacts.has(other.id): _contact_pending = true
			var from: Vector3 = sim.keep.position if sim.keep != null else world.centre()
			var d := from.distance_squared_to(other.position)
			if d < distance:
				distance = d
				nearest = other
	var escalated := at_war and not _contact_war and not seen.is_empty()
	if escalated: _contact_pending = true
	if nearest != null and _contact_pending and (_contact_cooldown <= 0.0 or escalated):
		var message := "Enemy soldiers spotted — last observed here." if at_war \
				else "Armed neighbors sighted — currently at peace."
		sim.alert.emit(message, nearest.position)
		_contact_cooldown = CONTACT_COOLDOWN
		_contact_pending = false
	if seen.is_empty(): _contact_pending = false
	_visible_contacts = seen
	_contact_war = at_war


func _tick_guard_security(unit: Soldier) -> bool:
	if unit.faction != 1 or unit.health <= 0.0 or unit.incapacitated(): return false
	var candidates: Array = []
	if at_war and sim.scouting != null:
		for scout: Scout in sim.scouting.scouts.values(): candidates.append(scout.person)
	else:
		var water: Node = sim.get("water")
		if water != null and water.has_method("hostile_scouts"):
			candidates = water.hostile_scouts()
	var target: Citizen
	var best := GUARD_SIGHT
	for candidate: Citizen in candidates:
		if not is_instance_valid(candidate) or candidate.service_health <= 0.0 \
				or (candidate is Soldier and candidate.health <= 0.0): continue
		var d := unit.position.distance_to(candidate.position)
		if d < best and world.nav.can_reach(unit.position, candidate.position):
			best = d
			target = candidate
	# A nearby armed opponent remains the more immediate threat.
	var armed := _target(unit)
	if armed is Soldier and unit.position.distance_to(armed.position) <= best:
		target = null
	if target == null:
		if _guard_contacts.has(unit.id):
			_guard_contacts.erase(unit.id)
			if _target(unit) == null: unit.clear_goal()
		return false
	at_war = true
	_guard_contacts[unit.id] = target.id
	unit.target_id = -1
	unit.target_kind = ""
	unit.task_label = "Intercepting hostile scout"
	if best > 2.6: unit.order_move(target.position)
	else: unit.clear_goal()
	# Scouting._danger owns contact damage and uses this soldier's ordinary
	# strike cooldown, preventing an extra attack during the campaign tick.
	return true

func _refill(u: Soldier) -> void:
	if u.rations >= PACK_DAYS - 0.01: return
	if u.carrying_res == Config.Res.FOOD and u.carrying_amount > 0.0:
		var carried := minf(PACK_DAYS - u.rations, u.carrying_amount)
		u.rations += carried
		u.carrying_amount -= carried
		if u.carrying_amount <= 0.0: u.drop()
		if u.rations >= PACK_DAYS - 0.01: return
	var stores: Array = sim.buildings if u.faction == 0 else enemy_buildings.values()
	for b in stores:
		if b.under_construction or not b.stores(Config.Res.FOOD): continue
		var door := _door(b)
		if u.position.distance_to(door) > SUPPLY_REACH or not world.nav.can_reach(u.position, door): continue
		var amount: float = minf(maxf(0.0, PACK_DAYS-u.rations),b.available(Config.Res.FOOD))
		if amount > 0: u.rations += b.remove(Config.Res.FOOD,amount)

func _target(u: Soldier) -> Node3D:
	if u.target_kind == "unit":
		var other: Soldier = units.get(u.target_id)
		return other if other != null and other.faction != u.faction and other.health > 0.0 else null
	if u.target_kind == "building":
		var building: Building = enemy_buildings.get(u.target_id) if u.faction == 0 else sim.buildings_by_id.get(u.target_id)
		return building if building != null and building.health > 0.0 else null
	return null

func _tick_combat(u: Soldier, _delta: float) -> void:
	var target := _target(u)
	if target == null:
		u.target_id = -1
		u.target_kind = ""
		if not u.has_goal(): u.task_label = "holding position" if u.rations > 0 else "out of food"
		return
	var destination: Vector3 = _door(target) if target is Building else target.position
	var distance := u.position.distance_to(destination)
	if distance > 2.8:
		u.order_move(destination)
	else:
		u.clear_goal()
		if u.cooldown <= 0 and u.can_strike():
			u.strike(target.position)
			u.cooldown = 1.8
			if target is Soldier:
				var landed := _rng.randf() < u.hit_probability(target)
				u.practice("melee", 0.12)
				if landed:
					var locations: Array[String] = target.hit_locations()
					var location := locations[_rng.randi_range(0, locations.size() - 1)]
					var heavy := _rng.randf() < 0.10
					target.receive_hit(location, "slash" if heavy or _rng.randf() < 0.7 else "stab", 80.0 if heavy else 12.0, _rng.randf())
					if heavy: u.cooldown = 3.0
				else:
					target.practice("dodge", 0.12)
			else:
				target.apply_damage(7.0)
	if target is Building and distance <= 20.0 and u.fire_cooldown <= 0 and u.can_throw_firepot():
		u.throw_firepot(target.position + Vector3(0,2,0))
		u.fire_cooldown = 8.0
		var flight := clampf((u.position + Vector3(0, 1.5, 0)).distance_to(
				target.position + Vector3(0, 0.1, 0)) / 18.0, 0.45, 1.4)
		_impacts.append({"wait":flight,"id":target.id,"faction":u.faction})


func _remove_unit(unit: Soldier) -> void:
	_release_home(unit)
	_unregister_unit(unit)
	unit.queue_free()

func _release_home(unit: Soldier) -> void:
	if not _civilian_ids.has(unit.id): return
	var civilian_id: int = _civilian_ids[unit.id]
	for home in sim.buildings:
		home.residents.erase(civilian_id)
	sim.workforce.mark_homes_dirty()

func _unregister_unit(unit: Soldier) -> void:
	units.erase(unit.id)
	_civilian_ids.erase(unit.id)
	unit.target_id = -1
	unit.target_kind = ""
	for other in units.values():
		if other.target_kind == "unit" and other.target_id == unit.id:
			other.target_id = -1
			other.target_kind = ""
			other.clear_goal()

func _assign_guards() -> void:
	for u in units.values():
		if u.faction == 0:
			if _target(u) != null: continue
			for other in units.values():
				if other.faction == 1 and at_war and u.position.distance_to(other.position)<16:
					u.target_id=other.id; u.target_kind="unit"; break
			continue
		var nearest: Soldier
		var best := 90.0 if personality != "loner" else 45.0
		for other in units.values():
			if other.faction == 0 and other.health > 0.0 and (at_war
					or (personality == "aggressive" and sim.day > 5.0)):
				var distance: float = u.position.distance_to(other.position)
				if distance < best: nearest=other; best=distance
		if nearest != null:
			at_war = true
			u.target_id=nearest.id; u.target_kind="unit"; u.task_label="defending town"
		elif personality == "aggressive" and not conquered and sim.day > 5 and not friendly_ids().is_empty():
			var candidate: Building
			var closest := INF
			for b in sim.buildings:
				if b.type_id in ["supply_hut","fort","barracks"] and u.position.distance_to(b.position)<closest:
					candidate=b; closest=u.position.distance_to(b.position)
			if candidate != null:
				at_war=true; u.target_id=candidate.id; u.target_kind="building"; u.task_label="raiding supplies"
		else:
			u.target_id=-1; u.target_kind=""
			if u.position.distance_to(rival_position)>45: u.order_move(rival_position+Vector3(0,0,-18))

func _tick_town(delta: float) -> void:
	if conquered: return
	var keep := _enemy_type("keep")
	var farm := _enemy_type("farm")
	if keep == null: return
	keep.inventory[Config.Res.FOOD] = maxf(0,keep.inventory[Config.Res.FOOD]-town_population*delta/Config.DAY_LENGTH)
	if farm != null:
		var available_workers := 0
		for worker in _workers:
			if sim.water == null or not sim.water.handles(worker): available_workers += 1
		farm.add(Config.Res.FOOD,delta/Config.DAY_LENGTH*6.0*mini(available_workers, farm.field_count()))
		for worker in _workers:
			if sim.water != null and sim.water.handles(worker): continue
			var leg: int = _worker_leg.get(worker.id,0)
			var destination := _door(farm) if leg == 0 else _door(keep)
			worker.set_goal(destination)
			worker.advance(delta,world)
			if not worker.has_arrived(): continue
			if leg == 0:
				var amount := farm.remove(Config.Res.FOOD,minf(8,farm.available(Config.Res.FOOD)))
				if amount < 0.1: continue
				worker.pick_up(Config.Res.FOOD,amount,registry)
				_worker_leg[worker.id]=1
			else:
				var amount := minf(worker.carrying_amount,keep.space_for(Config.Res.FOOD))
				keep.add(Config.Res.FOOD,amount)
				worker.carrying_amount -= amount
				if worker.carrying_amount<=0.01:
					worker.drop(); _worker_leg[worker.id]=0
			worker.clear_goal()
	if _time >= _recruit_at and at_war:
		_recruit_at=_time+Config.DAY_LENGTH*(2.0 if personality=="aggressive" else 4.0)
		var guards := units.size()-friendly_ids().size()
		if guards<6 and town_population > 0 and not _workers.is_empty() and keep.available(Config.Res.FOOD)>=12:
			keep.remove(Config.Res.FOOD,12)
			var worker: Citizen = _workers.back()
			var identity := SaveGame._capture_citizen(worker)
			var recruit := _spawn_unit(1, worker.position, worker.id, worker.asset_id)
			recruit.apply_state(identity, registry)
			recruit.apply_damage(100.0-worker.service_health)
			recruit.position = worker.position
			recruit._wear_anchor = recruit.position
			_workers.erase(worker)
			_worker_leg.erase(worker.id)
			_worker_wait.erase(worker.id)
			town_population = maxi(0, town_population - 1)
			if farm != null:
				farm.workers.erase(worker.id)
				farm.sync_fields_to_workers()
				_protect_farm(farm, true, false)
			worker.queue_free()

func _destroy_enemy(b: Building) -> void:
	if not enemy_buildings.has(b.id):
		return
	if b.def.is_farm():
		_protect_farm(b, false)
	if b.type_id=="keep":
		conquered=true
		sim.alert.emit("Ashcombe's keep has fallen. The road to its town is yours.",b.position)
	world.nav.block_footprint(b.position,b.footprint.x*0.4,b.footprint.y*0.4,false)
	var ruin := {"position":b.position,"footprint":b.footprint}
	_ruins.append(ruin)
	_make_ruin(ruin)
	enemy_buildings.erase(b.id)
	for unit in units.values():
		if unit.faction == 0 and unit.target_kind == "building" and unit.target_id == b.id:
			unit.target_id = -1
			unit.target_kind = ""
			unit.clear_goal()
	for event in _impacts.duplicate():
		if event.faction == 0 and event.id == b.id:
			_impacts.erase(event)
	b.queue_free()

func _make_ruin(data: Dictionary) -> void:
	var rubble := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size=Vector3(data.footprint.x,0.6,data.footprint.y)
	var mat := StandardMaterial3D.new()
	mat.albedo_color=Color(0.16,0.14,0.12)
	mesh.material=mat; rubble.mesh=mesh
	add_child(rubble); rubble.position=data.position+Vector3(0,0.15,0)

func capture() -> Dictionary:
	var buildings: Array = []
	for b in enemy_buildings.values():
		buildings.append({"id": b.id, "type_id": b.type_id, "position": b.position,
			"health": b.health, "fire": b.fire, "inventory": b.inventory.duplicate(),
			"plots": b.all_plots().duplicate(), "crop_growth": b.crop_growth})
	var army: Array = []
	for u in units.values():
		var target := _target(u)
		var record := {"id": u.id, "faction": u.faction, "position": u.position,
			"name": u.given_name, "age": u.age, "asset_id": u.asset_id,
			"carrying_res": u.carrying_res, "carrying_amount": u.carrying_amount,
			"health": u.health, "rations": u.rations,
			"hydration":u.hydration,"water_sickness":u.water_sickness,"water_bucket":u.water_bucket,"service_health":u.service_health,
			"target_id": u.target_id if target != null else -1,
			"target_kind": u.target_kind if target != null else "", "goal": u._goal,
			"moving": u.has_goal(), "cooldown": u.cooldown, "fire_cooldown": u.fire_cooldown,
			"body": u.capture_body()}
		if u.faction == 0:
			var identity := SaveGame._capture_citizen(u)
			identity.id = _civilian_ids[u.id]
			identity.workplace_id = -1
			identity.immigrant = false
			if not sim.buildings_by_id.has(identity.home_id): identity.home_id = -1
			identity.erase("body")
			identity.erase("veteran_rations")
			record.civilian = identity
		army.append(record)
	var workers: Array = []
	for c in _workers:
		workers.append({"id": c.id, "position": c.position, "carried": c.carrying_amount,
			"name": c.given_name, "age": c.age,
			"hydration":c.hydration,"water_sickness":c.water_sickness,"water_bucket":c.water_bucket,"service_health":c.service_health,
			"leg": int(_worker_leg.get(c.id, 0)), "asset_id": c.asset_id,
			"goal": c._goal, "moving": c.has_goal()})
	var impacts: Array = []
	for event in _impacts:
		var buildings_by_id: Dictionary = enemy_buildings if event.faction == 0 else sim.buildings_by_id
		if buildings_by_id.has(event.id):
			impacts.append(event.duplicate())
	return {"personality": personality, "rival_name": rival_name, "town_population": town_population,
		"rival_position": rival_position, "at_war": at_war, "defeated": defeated,
		"conquered": conquered, "next_id": _next_id, "time": _time, "review": _review,
		"recruit_at": _recruit_at, "rng_state": _rng.state, "buildings": buildings,
		"units": army, "workers": workers, "ruins": _ruins.duplicate(true), "impacts": impacts,
		"security": {"cooldown": _contact_cooldown, "visible_ids": _visible_contacts.duplicate(),
			"pending": _contact_pending, "was_at_war": _contact_war}}


func _reset() -> void:
	for unit in units.values():
		_release_home(unit)
	for b in enemy_buildings.values():
		if b.def.is_farm():
			_protect_farm(b, false)
		world.nav.block_footprint(b.position, b.footprint.x * 0.4, b.footprint.y * 0.4, false)
	for child in get_children():
		child.free()
	enemy_buildings.clear()
	units.clear()
	_civilian_ids.clear()
	_workers.clear()
	_worker_leg.clear()
	_worker_wait.clear()
	_ruins.clear()
	_impacts.clear()
	_visible_contacts.clear()
	_guard_contacts.clear()
	_contact_cooldown = 0.0
	_contact_pending = false
	_contact_war = false
	_next_id = 100000
	_time = 0.0
	_review = 0.0
	_recruit_at = 0.0
	at_war = false
	defeated = false
	conquered = false


func restore(data: Variant) -> String:
	var error := validate(data, sim.buildings_by_id, world.size_m)
	if error != "":
		return error
	for entry in data.get("units", []):
		if entry.has("civilian") and sim.citizens_by_id.has(entry.civilian.id):
			return "serving citizen is already in the civilian workforce"
	# Validation finishes before any footprints, resources or living entities
	# change. Replacing an existing state must not leave double nav claims.
	_reset()
	if data.is_empty():
		generate_rival()
		return ""
	personality = data.personality
	rival_name = data.get("rival_name", "Ashcombe")
	town_population = data.get("town_population", 8)
	rival_position = data.rival_position
	at_war = data.at_war
	defeated = data.defeated
	conquered = data.conquered
	_time = data.time
	_review = data.get("review", 0.0)
	_recruit_at = data.recruit_at
	var security: Dictionary = data.get("security", {})
	_contact_cooldown = security.get("cooldown", 0.0)
	_visible_contacts.assign(security.get("visible_ids", []))
	_contact_pending = security.get("pending", false)
	_contact_war = security.get("was_at_war", at_war)
	for entry in data.buildings:
		var b := _create_building(entry.type_id, entry.position, entry.id, true)
		b.inventory = entry.inventory.duplicate()
		b.health = entry.health
		b.fire = entry.fire
		b.crop_growth = entry.get("crop_growth", 0.7 if b.def.is_farm() else 0.0)
		b.apply_damage(0)
	for entry in data.units:
		var identity: Dictionary = entry.get("civilian", {})
		var u := _spawn_unit(entry.faction, entry.position, entry.id,
				identity.get("asset_id", entry.get("asset_id", "citizen_male_base")), identity.get("id", -1))
		if not identity.is_empty():
			u.apply_state(identity, registry)
			var home: Building = sim.buildings_by_id.get(u.home_id)
			if home != null and not home.residents.has(identity.id):
				home.residents.append(identity.id)
		else:
			u.given_name = entry.get("name", u.given_name)
			u.age = entry.get("age", u.age)
			if entry.get("carrying_amount", 0.0) > 0.0:
				u.pick_up(entry.carrying_res, entry.carrying_amount, registry)
		for key in ["hydration","water_sickness","water_bucket","service_health"]:
			u.set(key,entry.get(key,u.get(key)))
		u.position = entry.position
		u._wear_anchor = u.position
		if entry.has("body"):
			u.restore_body(entry.body)
		else:
			u.health = entry.health
		u.rations = entry.rations
		u.target_id = entry.target_id
		u.target_kind = entry.target_kind
		u.cooldown = entry.cooldown
		u.fire_cooldown = entry.fire_cooldown
		u._goal = entry.goal
		if entry.moving:
			u.order_move(entry.goal)
	for entry in data.workers:
		var c := Citizen.new()
		add_child(c)
		c.setup(entry.id, registry, _rng, entry.get("asset_id", ""))
		c.given_name = entry.get("name", c.given_name)
		c.age = entry.get("age", c.age)
		for key in ["hydration","water_sickness","water_bucket","service_health"]:
			c.set(key,entry.get(key,c.get(key)))
		c._body.collision_layer = 0
		c.position = entry.position
		c._wear_anchor = c.position
		c.profession = "Ashcombe grower"
		c._goal = entry.get("goal", Vector3.ZERO)
		if entry.get("moving", false):
			c.set_goal(entry.goal)
		if entry.carried > 0:
			c.pick_up(Config.Res.FOOD, entry.carried, registry)
		_workers.append(c)
		_worker_leg[c.id] = entry.leg
	var farm := _enemy_type("farm")
	if farm != null:
		for c in _workers:
			farm.workers.append(c.id)
		var saved_farm: Dictionary = {}
		for entry in data.buildings:
			if entry.id == farm.id:
				saved_farm = entry
		if saved_farm.has("plots"):
			farm.adopt_plots(saved_farm.plots, world.heightmap, world.nav, registry)
		else:
			farm.create_fields(world.heightmap, world.nav, registry)
		farm.set_crop_growth(saved_farm.get("crop_growth", 0.7))
		_protect_farm(farm, true, false)
	_ruins = data.ruins.duplicate(true)
	for ruin in _ruins:
		_make_ruin(ruin)
	_impacts = data.impacts.duplicate(true)
	_next_id = data.next_id
	_rng.state = data.get("rng_state", _rng.state)
	sim.stores.refresh_totals(sim.population_members(), sim.buildings)
	return ""

static func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and value>=minimum and value<=maximum

static func _position(value: Variant, world_size: float = 768.0) -> bool:
	return value is Vector3 and value.is_finite() and value.x>=0 and value.z>=0 and value.x<=world_size and value.z<=world_size and absf(value.y)<10000

static func validate(data: Variant, friendly_buildings: Variant = null, world_size: float = 768.0) -> String:
	if not data is Dictionary:
		return "campaign must be a dictionary"
	if data.is_empty():
		return ""
	for key in ["personality", "rival_position", "at_war", "defeated", "conquered", "next_id", "time", "recruit_at", "buildings", "units", "workers", "ruins", "impacts"]:
		if not data.has(key):
			return "campaign missing " + key
	if not data.personality is String or data.personality not in PERSONALITIES or not _position(data.rival_position, world_size):
		return "invalid rival town"
	if not data.get("rival_name", "Ashcombe") is String or String(data.get("rival_name", "Ashcombe")).length() > 80:
		return "invalid rival name"
	if not data.get("town_population", 8) is int or not _number(data.get("town_population", 8), 0, 128):
		return "invalid rival population"
	if not _number(data.get("review", 0.0), 0.0, 2.0) or not data.get("rng_state", 0) is int:
		return "invalid campaign scheduling state"
	for key in ["at_war", "defeated", "conquered"]:
		if not data[key] is bool:
			return "invalid campaign flag"
	if not data.next_id is int or data.next_id < 100000 or data.next_id > 2147483647:
		return "invalid military identifier"
	if not _number(data.time, 0, 1e12) or not _number(data.recruit_at, 0, 1e12):
		return "invalid campaign time"
	if data.has("security"):
		var security: Variant = data.security
		if not security is Dictionary or security.size() != 4 \
				or not _number(security.get("cooldown"), 0.0, CONTACT_COOLDOWN) \
				or not security.get("visible_ids") is Array \
				or security.visible_ids.size() > 65536 \
				or not security.get("pending") is bool or not security.get("was_at_war") is bool:
			return "invalid contact warning state"
		var seen_contacts := {}
		for id in security.visible_ids:
			if not id is int or id < 100000 or id >= data.next_id or seen_contacts.has(id):
				return "invalid contact warning identity"
			seen_contacts[id] = true
	for key in ["buildings", "units", "workers", "ruins", "impacts"]:
		if not data[key] is Array or data[key].size() > (65536 if key == "units" else 128):
			return "invalid campaign collection"
	var ids := {}
	var buildings := {}
	var armies := {}
	var keeps := 0
	var friendly := 0
	var guards := 0
	var civilian_ids := {}
	for b in data.buildings:
		if not b is Dictionary:
			return "invalid rival building"
		for key in ["id", "type_id", "position", "health", "fire", "inventory"]:
			if not b.has(key):
				return "incomplete rival building"
		if not b.type_id is String or b.type_id not in ["keep", "house", "farm", "granary", "well"] or not _position(b.position, world_size):
			return "invalid rival building type or position"
		if not b.id is int or b.id < 100000 or b.id >= data.next_id or ids.has(b.id):
			return "invalid rival building id"
		ids[b.id] = true
		buildings[b.id] = b
		keeps += int(b.type_id == "keep")
		if not _number(b.health, 0, 800 if b.type_id == "keep" else 200) or not _number(b.fire, 0, 1):
			return "invalid rival damage"
		if not b.inventory is PackedFloat32Array or b.inventory.size() != Config.RES_COUNT:
			return "invalid rival inventory"
		var def := BuildingDefs.get_def(b.type_id)
		var total := 0.0
		for resource in Config.RES_COUNT:
			var amount: float = b.inventory[resource]
			if not _number(amount, 0, def.storage) or (amount > 0.0 and resource not in def.stores):
				return "invalid rival stock"
			total += amount
		if total > def.storage + 0.001:
			return "rival inventory exceeds capacity"
		if not b.get("plots", []) is Array or not _number(b.get("crop_growth", 0.0), 0.0, 1.0):
			return "invalid rival field state"
		if b.get("plots", []).size() > def.worker_slots * def.plots_per_worker:
			return "too many rival field plots"
		var plots := {}
		for plot in b.get("plots", []):
			if not _position(plot, world_size) or plots.has(plot) or plot.distance_to(b.position) > def.work_radius + Config.CELL:
				return "invalid rival field plot"
			plots[plot] = true
	if keeps > 1 or (data.conquered and keeps != 0) or (not data.conquered and not buildings.is_empty() and keeps != 1):
		return "rival keep disagrees with conquest state"
	for u in data.units:
		if not u is Dictionary:
			return "invalid soldier"
		for key in ["id", "faction", "position", "health", "rations", "target_id", "target_kind", "goal", "moving", "cooldown", "fire_cooldown"]:
			if not u.has(key):
				return "incomplete soldier"
		if not u.id is int or u.id < 100000 or u.id >= data.next_id or ids.has(u.id):
			return "invalid soldier id"
		ids[u.id] = true
		armies[u.id] = u
		if not u.faction is int or u.faction not in [0, 1] or not _position(u.position, world_size) or not _position(u.goal, world_size):
			return "invalid soldier allegiance or position"
		if not u.get("name", "") is String or not u.get("age", 24) is int \
				or not _number(u.get("age", 24), 0, 120) \
				or u.get("asset_id", "citizen_male_base") not in ["citizen_male_base", "citizen_female_base"]:
			return "invalid soldier identity"
		if not u.get("carrying_res", -1) is int or u.get("carrying_res", -1) < -1 \
				or u.get("carrying_res", -1) >= Config.RES_COUNT \
				or not _number(u.get("carrying_amount", 0.0), 0.0, 1e12) \
				or ((u.get("carrying_res", -1) == -1) != (u.get("carrying_amount", 0.0) == 0.0)):
			return "invalid soldier cargo"
		var water_error := WaterSystem.validate_person(u)
		if water_error != "": return water_error
		friendly += int(u.faction == 0)
		guards += int(u.faction == 1)
		if not u.moving is bool or not u.target_id is int or not u.target_kind is String or u.target_kind not in ["", "unit", "building"]:
			return "invalid soldier orders"
		if (u.target_kind == "") != (u.target_id == -1):
			return "inconsistent soldier target"
		if not _number(u.health, 0, 100) or not _number(u.rations, 0, PACK_DAYS) or not _number(u.cooldown, 0, 3.0) or not _number(u.fire_cooldown, 0, 8):
			return "invalid soldier supplies or condition"
		if u.has("body"):
			var body_error := Soldier.validate_body(u.body)
			if body_error != "": return body_error
			if not is_equal_approx(float(u.health), Soldier.body_health(u.body)):
				return "soldier health disagrees with body injuries"
		if u.has("civilian"):
			if u.faction != 0: return "rival soldier cannot own a player civilian identity"
			var identity_error: String = SaveGame.Validation._citizen(u.civilian, null, world_size)
			if identity_error != "": return identity_error
			if u.civilian.workplace_id != -1 or u.civilian.immigrant or civilian_ids.has(u.civilian.id):
				return "duplicate or employed serving citizen"
			if u.civilian.position != u.position:
				return "serving citizen position disagrees with unit"
			for key in ["name", "age", "asset_id", "carrying_res", "carrying_amount", "hydration", "water_sickness", "water_bucket", "service_health"]:
				if u.has(key) and (not u.civilian.has(key) or u[key] != u.civilian[key]):
					return "serving citizen identity disagrees with unit"
			civilian_ids[u.civilian.id] = true
	if guards > 6:
		return "army exceeds recruitment limits"
	for u in data.units:
		if u.target_kind == "unit":
			if not armies.has(u.target_id) or armies[u.target_id].faction == u.faction:
				return "soldier targets a missing or friendly unit"
		elif u.target_kind == "building":
			if u.faction == 0 and not buildings.has(u.target_id):
				return "soldier targets a missing rival building"
			if u.faction == 1 and (u.target_id <= 0 or u.target_id > 2147483647):
				return "invalid friendly building target"
			if u.faction == 1 and friendly_buildings != null and not friendly_buildings.has(u.target_id):
				return "soldier targets a missing friendly building"
	if data.workers.size() > 3:
		return "too many rival workers"
	if data.workers.size() > data.get("town_population", 8):
		return "rival workforce exceeds civilian population"
	for c in data.workers:
		if not c is Dictionary:
			return "invalid rival worker"
		for key in ["id", "position", "carried", "leg"]:
			if not c.has(key):
				return "incomplete rival worker"
		if not c.id is int or c.id < 100000 or c.id >= data.next_id or ids.has(c.id) or not _position(c.position, world_size) or not _number(c.carried, 0, 8) or not c.leg is int or c.leg not in [0, 1]:
			return "invalid rival worker state"
		if (c.leg == 1) != (c.carried > 0.0):
			return "rival worker load disagrees with its delivery leg"
		if not c.get("asset_id", "citizen_male_base") is String or c.get("asset_id", "citizen_male_base") not in ["citizen_male_base", "citizen_female_base"]:
			return "invalid rival worker appearance"
		if not c.get("name", "") is String or not c.get("age", 24) is int \
				or not _number(c.get("age", 24), 0, 120):
			return "invalid rival worker identity"
		if not _position(c.get("goal", Vector3.ZERO), world_size) or not c.get("moving", false) is bool:
			return "invalid rival worker route"
		var water_error := WaterSystem.validate_person(c)
		if water_error != "": return water_error
		ids[c.id] = true
	for ruin in data.ruins:
		if not ruin is Dictionary or not _position(ruin.get("position"), world_size) or not ruin.get("footprint") is Vector2:
			return "invalid ruins"
		if not ruin.footprint.is_finite() or ruin.footprint.x <= 0 or ruin.footprint.y <= 0 or ruin.footprint.length() > 100:
			return "invalid ruin size"
	for impact in data.impacts:
		if not impact is Dictionary or not _number(impact.get("wait"), 0, 1.4) or not impact.get("id") is int or not impact.get("faction") is int or impact.get("faction") not in [0, 1]:
			return "invalid pending projectile"
		if (impact.faction == 0 and not buildings.has(impact.id)) or (impact.faction == 1 and (impact.id <= 0 or impact.id > 2147483647)):
			return "pending projectile targets a missing building"
		if impact.faction == 1 and friendly_buildings != null and not friendly_buildings.has(impact.id):
			return "pending projectile targets a missing friendly building"
	return ""


## Trade uses the same finite inventories as the rival town and military.
func trade_store() -> Building:
	return _enemy_type("keep")


func trade_access_reason(target_id: int) -> String:
	if defeated: return "Your keep has fallen; normal trade is closed."
	if at_war: return "Destination at war; normal trade is closed."
	if conquered: return "The rival town has fallen; its old offers are canceled."
	var target: Building = enemy_buildings.get(target_id)
	if target == null or target.type_id != "keep" or target.health <= 0:
		return "Trading destination destroyed or unavailable."
	return ""


func reserve_trade(target_id: int, amount: float) -> bool:
	if not is_finite(amount) or amount <= 0 or trade_access_reason(target_id) != "": return false
	var target: Building = enemy_buildings[target_id]
	if target.available(Config.Res.IRON) + 0.0001 < amount: return false
	target.reserved[Config.Res.IRON] += amount
	return true


func release_trade(target_id: int, amount: float) -> void:
	if not is_finite(amount) or amount <= 0: return
	var target: Building = enemy_buildings.get(target_id)
	if target != null:
		target.reserved[Config.Res.IRON] = maxf(0.0, target.reserved[Config.Res.IRON] - amount)


func exchange_trade(target_id: int, timber: float, iron: float) -> String:
	if not is_finite(timber) or not is_finite(iron) or timber <= 0 or iron <= 0 or not is_equal_approx(timber, iron * 3.0):
		return "Invalid barter quantities."
	var reason := trade_access_reason(target_id)
	if reason != "": return reason
	var target: Building = enemy_buildings[target_id]
	if target.reserved[Config.Res.IRON] + 0.0001 < iron or target.inventory[Config.Res.IRON] + 0.0001 < target.reserved[Config.Res.IRON]:
		return "Promised iron is missing; returning with the timber."
	if target.space_for(Config.Res.TIMBER) + iron + 0.0001 < timber:
		return "The receiving store is full; returning with the timber."
	# All conditions are checked before this indivisible handover.
	target.reserved[Config.Res.IRON] = maxf(0.0, target.reserved[Config.Res.IRON] - iron)
	target.inventory[Config.Res.IRON] -= iron
	target.inventory[Config.Res.TIMBER] += timber
	return ""
