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
const FIRE_SPREAD_INTERVAL := 0.5
const FIRE_CELL := 24.0
## Every company the game creates is four files wide: `form_company` is only
## ever called with the default, and `set_company_width` has no caller outside
## the tests, so frontage is modelled and saved but not yet something the
## player can set. The ceilings are there so a hand-edited save cannot ask for
## a kilometre-wide line or a million rosters to walk.
const COMPANY_WIDTH := 4
const MAX_COMPANY_WIDTH := 12
const MAX_COMPANIES := 512
## Parade geometry: two metres between files and between ranks, four between
## the blocks of neighbouring companies so they read as separate bodies.
const FILE_SPACING := 2.0
const COMPANY_GAP := 4.0
## Expansion. The rival town is a settlement, not a spawner: it eats the food
## its growers carry home, houses the people it feeds, and pays a building's
## real `BuildingDefs` cost out of its own keep before anything is raised. Every
## number below is a placeholder in the sense GAME_DESIGN.md means — measured,
## not derived — and the measurements are in the campaign test.
##
## Labour is abstracted the same way the rival's farming already is: a resident
## who is not a grower is a labourer, and labourers turn into timber and stone
## in the keep at a fixed daily rate. Modelling rival woodcutters would mean
## rival jobs, rival hauling and rival pathing for a town the player mostly
## never sees, at a per-frame cost this project has just spent a lot of effort
## removing.
##
## What that abstraction does not do, stated plainly: no tree or outcrop is
## depleted for the timber and stone it makes, so unlike the player the rival
## cannot log a hillside bare, and a hungry town keeps cutting — `_tick_labour`
## reads the head count, not whether `_eat` actually found the meal. The town is
## still held to its own stores for everything it spends; it is the supply of
## raw material that is a rate rather than a place on the map.
## Doubled with the building prices (BuildingDefs), so the rival still grows at
## the pace it was tuned to rather than at half of it.
const LABOUR_TIMBER := 2.6   ## per labourer per day
const LABOUR_STONE := 1.4
const LABOUR_IRON := 0.35    ## peaceful towns only; what makes their trade renewable
## Kept deliberately low. The keep holds 400 of everything together, so every
## unit of material on the shelf is a unit of food the town cannot bank, and a
## town that cannot bank food starves its garrison the first bad week. These
## are a little over the price of the dearest thing the town builds: a granary
## at 52 timber, a well at 40 stone.
const TIMBER_CEILING := 70.0
const STONE_CEILING := 50.0
const IRON_CEILING := 60.0
## A resident costs food to raise, and the town keeps a buffer beyond that so a
## settlement that is only just feeding itself does not add another mouth.
const SETTLE_FOOD := 12.0
const FOOD_RESERVE := 20.0
## Daily harvest the worked fields must yield per mouth before the town takes on
## another one, and the test `_wanted` makes to decide it needs another field.
## Above one because a grower spends part of every day walking and part of it at
## the well, and because a guard's four-day pack comes out of the same stores.
##
## It is a rate rather than the stock in the keep so that the two questions —
## can we feed another mouth, do we need another field — are the same question
## asked once. Honest about its weight: mutation-tested, and removing it from
## `_settle` changes none of the three towns at day 120, because `_can_spare`
## and `_population_cap` both bite first. It is the farm decision that this
## number is actually load-bearing for, and it becomes load-bearing for
## settlement too the moment MAX_TOWN_POPULATION is raised.
const HARVEST_MARGIN := 1.8
## A grower's load, and the smallest harvest he will break off a trip for.
const LOAD := 8.0
const LOAD_MIN := 4.0
const GROW_INTERVAL := Config.DAY_LENGTH
const BUILD_INTERVAL := Config.DAY_LENGTH * 0.5
## The town reviews nothing for its first three days: the player gets a few
## mornings before the neighbour is a moving target.
const FIRST_REVIEW := Config.DAY_LENGTH * 3.0
## A failed siting scan is the expensive branch — up to 320 `can_place` probes —
## so a town with nowhere left to build backs off instead of repeating it every
## half day for the rest of the game.
const BUILD_BACKOFF := Config.DAY_LENGTH * 3.0
## Labourers the town will not strip to staff another farm. Without it a second
## farm takes every spare resident and the town stops producing materials.
const LABOUR_RESERVE := 3
const MAX_FARMS := 5
const MAX_GROWERS := 15
const MAX_RIVAL_BUILDINGS := 24
const MAX_TOWN_POPULATION := 48
## Was a flat six. The cap now scales with the town that feeds it, and the
## constant is only the ceiling a hand-edited save is held to.
const MAX_GUARDS := 16
## An aggressive garrison this size raids supply and military buildings even
## from a settlement that has raised no army. Below it the old rule holds: a
## rival does not pick on the defenceless. Reaching it takes a town that has
## really grown — see the day-30/60/120 table in the campaign test.
const RAID_GARRISON := 8
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
var _worker_farm: Dictionary = {} # grower id -> the farm building he works
## The town's two review clocks, counted down by the delta actually simulated
## rather than read off an absolute `_time`, exactly as `_review` is. A review
## is a thing the town does over an interval of lived time, so a tick of zero
## seconds must not bring one on — and `_tick_town` is called with a zero delta
## by the conscription fixtures, which have every right to expect that a tick
## in which no time passes changes nothing.
var _grow_in := 0.0
var _build_in := 0.0
## `_tick_town` runs every frame, so the keep and the farms it needs are held
## rather than found: `_enemy_type` walks the whole town, and with the town now
## able to reach two dozen buildings that walk is exactly the per-frame scan
## this file is not allowed to reintroduce. `_index_town` refreshes both, and
## the only three things that change the town are `_create_building`,
## `_destroy_enemy` and `_reset`.
var _keep: Building
var _farms: Array[Building] = []
var _granaries: Array[Building] = []
var _impacts: Array = []
var _ruins: Array = []
var _civilian_ids: Dictionary = {} # military id -> the person's permanent civilian id
var _rng := RandomNumberGenerator.new()
var _contact_cooldown := 0.0
var _visible_contacts: Array[int] = []
var _contact_pending := false
var _contact_war := false
var _guard_contacts: Dictionary = {}
var _patients: Dictionary = {} # faction -> candidates every medic of it shares this tick
## A company is a persistent block of soldiers — the thing the player selects,
## marches, splits and merges. It owns nothing: `units` still holds every
## soldier, a company only references them, and a soldier is in at most one.
##
## companies: company id -> {"id", "name", "width", "members": Array of unit id}
## _unit_company: unit id -> company id, the reverse index.
##
## Both are plain dictionaries, so "which company is this soldier in" is one
## hash lookup — the reverse index exists precisely so nothing has to walk the
## roster to answer it. Storage is one entry per company plus one int per
## enlisted soldier: O(companies + soldiers).
##
## No tick() work scans either table: the one that reads them per frame is
## `_leave_company`, on the death path in `_unregister_unit`, and it costs one
## hash lookup plus an erase from that one company's roster. What walks
## linearly is `command` and `selection_report`, and both
## walk only the id list they are handed — one order, one selection — doing an
## O(1) index lookup per id; plus one company's own roster when its block is
## laid out. Nothing scans the army to answer a question about one soldier.
var companies: Dictionary = {}
var _unit_company: Dictionary = {}
var _next_company_ordinal := 1

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
			var worker := _add_grower(farm)
			worker.position = _door(keep) + Vector3(i,0,0)
			worker._wear_anchor = worker.position
		farm.create_fields(world.heightmap,world.nav,registry)
		farm.sync_fields_to_workers()
		farm.set_crop_growth(0.7)
		_protect_farm(farm, true, true)
	for i in 3: _spawn_unit(1, at + Vector3(i*3-3,0,-16))
	_recruit_at = Config.DAY_LENGTH * 4.0
	_build_in = FIRST_REVIEW
	_grow_in = FIRST_REVIEW


## One more resident put to work on `farm`. The caller syncs the field and its
## protection afterwards, because staffing several farms at once should redraw
## each of them once rather than once per hand.
## Take a grower out of the town for good — conscripted, or dead — and off the
## farm he actually worked, which is not necessarily the town's first one.
func remove_grower(worker: Citizen) -> void:
	var farm: Building = enemy_buildings.get(_worker_farm.get(worker.id, -1))
	_workers.erase(worker)
	_worker_leg.erase(worker.id)
	_worker_farm.erase(worker.id)
	town_population = maxi(0, town_population - 1)
	if farm != null:
		farm.workers.erase(worker.id)
		farm.sync_fields_to_workers()
		_protect_farm(farm, true, false)
	worker.queue_free()


func _add_grower(farm: Building) -> Citizen:
	var worker := Citizen.new()
	add_child(worker)
	worker.setup(_allocate(),registry,_rng)
	worker._body.collision_layer = 0
	worker.position = _door(farm)
	worker._wear_anchor = worker.position
	worker.profession = "Ashcombe grower"
	_workers.append(worker)
	_worker_leg[worker.id] = 0
	_worker_farm[worker.id] = farm.id
	farm.workers.append(worker.id)
	return worker

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
	if not restoring:
		# A rival pad is flattened wider than the footprint it blocks, exactly
		# as a player one is, so the ring around it needs the same reprice —
		# otherwise Ashcombe's approaches keep the weights of the hillside that
		# stood there, and our own people path through it.
		sim.resync_nav_after_flatten(b.position, b.footprint.x*0.5 + 1.5,
			b.footprint.y*0.5 + 1.5)
	enemy_buildings[b.id] = b
	_index_town()
	return b


## The cached view of the town `_tick_town` reads every frame. Farms are held in
## id order rather than dictionary order so nothing about the town's behaviour
## depends on the sequence buildings happened to be created or loaded in.
func _index_town() -> void:
	_keep = null
	_farms.clear()
	_granaries.clear()
	for b: Building in enemy_buildings.values():
		if b.type_id == "keep": _keep = b
		elif b.def.is_farm(): _farms.append(b)
		elif b.type_id == "granary": _granaries.append(b)
	var by_id := func(a: Building, b: Building) -> bool: return a.id < b.id
	_farms.sort_custom(by_id)
	_granaries.sort_custom(by_id)

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
	var cost := _recruit_cost(citizen)
	if not sim.stores.try_spend(cost): return "Recruitment needs 5 available tools and supplies for training and a four-day pack."
	# Training eats six; the rest is the pack, recorded as it is eaten below.
	sim.ledger.unused(Config.Res.FOOD, float(cost.get(Config.Res.FOOD, 0.0)) - 6.0)
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


## Every medic of a faction scans the same people, so that side is built once
## per tick instead of once per medic: population_members() allocates the whole
## player population and the old `patients.has()` de-duplication was a linear
## scan of that array for every person in it. Only faction 0 pays for the
## population walk, so a rival medic never drags the player's civilians in.
## A soldier removed later in this tick keeps a stale entry, which is harmless:
## _remove_unit only ever fires on a body already at zero health, and can_treat
## rejects those. Nothing adds units between here and the end of the tick.
func _patient_pool(faction: int) -> Array:
	if _patients.has(faction): return _patients[faction]
	var pool: Array = []
	for u in units.values():
		if u.faction == faction: pool.append(u)
	if faction == 0:
		# Veterans serving as scouts, carriers or merchants stay treatable; a
		# person already marching under this campaign is the same object, so
		# the units gathered above are the whole of what must not repeat.
		var enlisted := {}
		for u in pool: enlisted[u] = true
		for citizen in sim.population_members():
			if citizen is Soldier and citizen.faction == 0 and not enlisted.has(citizen):
				pool.append(citizen)
	_patients[faction] = pool
	return pool

func _tick_medic(unit: Soldier) -> bool:
	if unit.medical_role != "medic" or unit.medical_supplies <= 0 or unit.incapacitated():
		return false
	var patient: Soldier
	var best := -INF
	# Distance rejects nearly every candidate for the price of a subtraction and
	# a square root. can_treat costs more even now that Soldier memoises its
	# derived body state, because treatment_need still walks the target's whole
	# wound list uncached. It once cost ten full body evaluations; the cache
	# took most of that away, and the ordering still pays for itself.
	for other in _patient_pool(unit.faction):
		var distance := unit.position.distance_to(other.position)
		if distance > SUPPLY_REACH or not unit.can_treat(other) \
				or not world.nav.can_reach(unit.position, other.position): continue
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

# ---------------------------------------------------------------------------
# Companies
# ---------------------------------------------------------------------------

func company_of(unit_id: int) -> int:
	return _unit_company.get(unit_id, -1)


func company_members(company_id: int) -> Array[int]:
	var members: Array[int] = []
	if companies.has(company_id): members.assign(companies[company_id].members)
	return members


## One company described for the interface, empty when there is no such
## company. `company_report(company_of(id))` is how the panel asks about a
## soldier, and it answers empty for a soldier who marches loose — which is a
## legal thing to be, select and order.
func company_report(company_id: int) -> Dictionary:
	if not companies.has(company_id): return {}
	var company: Dictionary = companies[company_id]
	return {"id": company.id, "name": company.name, "width": company.width,
		"size": company.members.size()}


func _company_name() -> String:
	var ordinal := _next_company_ordinal
	_next_company_ordinal += 1
	var suffix := "th"
	if ordinal % 100 < 11 or ordinal % 100 > 13:
		match ordinal % 10:
			1: suffix = "st"
			2: suffix = "nd"
			3: suffix = "rd"
	return "%d%s Company" % [ordinal, suffix]


## Drop one soldier from whatever company holds him. A company is its soldiers:
## the last one to leave — killed, discharged, or taken into another company —
## takes the company with him, rather than leaving an empty name behind for the
## interface to offer and for `capture` to write out.
func _leave_company(unit_id: int) -> void:
	var company_id: int = _unit_company.get(unit_id, -1)
	if company_id < 0: return
	_unit_company.erase(unit_id)
	if not companies.has(company_id): return
	var company: Dictionary = companies[company_id]
	company.members.erase(unit_id)
	if company.members.is_empty(): companies.erase(company_id)


## The one mutator: these soldiers, and only these, become one company.
##
## Forming, splitting and merging are the same act seen from three angles — a
## loose selection becomes a company, part of a company becomes a new one, and
## two companies become one — so the player learns a single verb and
## `split_company`/`merge_companies` below are thin, checked wrappers over it.
## Returns the new company id, or -1 when the selection holds no living
## soldier of ours, or when forming would leave more than MAX_COMPANIES.
func form_company(ids: Array, width: int = 0, company_name: String = "") -> int:
	var members: Array = []
	var seen := {}
	for id in ids:
		if not id is int or seen.has(id): continue
		var u: Soldier = units.get(id)
		if u == null or u.faction != 0 or u.health <= 0.0: continue
		seen[id] = true
		members.append(id)
	if members.is_empty(): return -1
	# The ceiling counts the companies that will still exist afterwards. A merge
	# at the cap empties the companies it draws from, so testing the raw size
	# here would refuse the one operation that gets the player back under it.
	var drawn := {}
	for id in members:
		var previous: int = _unit_company.get(id, -1)
		if previous >= 0: drawn[previous] = int(drawn.get(previous, 0)) + 1
	var vacated := 0
	for previous in drawn:
		if drawn[previous] >= companies[previous].members.size(): vacated += 1
	if companies.size() - vacated >= MAX_COMPANIES: return -1
	if width <= 0:
		# Shape is inherited, not re-derived, so a detachment split off a
		# six-wide line marches six wide. Nothing in the game makes a six-wide
		# line yet — see COMPANY_WIDTH — so today this only carries the default
		# through a split; it is why width lives on the company rather than
		# being invented afresh by each order.
		width = COMPANY_WIDTH
		for id in members:
			var previous: int = _unit_company.get(id, -1)
			if companies.has(previous):
				width = companies[previous].width
				break
	# Ascending id rather than the order the selection happened to be
	# assembled in, so a soldier holds the same file in the block from one
	# order to the next and the roster a save writes does not depend on clicks.
	members.sort()
	for id in members: _leave_company(id)
	var company_id := _allocate()
	companies[company_id] = {"id": company_id, "width": clampi(width, 1, MAX_COMPANY_WIDTH),
		"name": company_name.substr(0, 60) if company_name != "" else _company_name(),
		"members": members}
	for id in members: _unit_company[id] = company_id
	return company_id


## Peel part of a company off into a new one. Which part is the player's
## current selection, not a count: soldiers are not interchangeable here — they
## carry their own armor and their own injuries — so "these four" is a
## meaningful order in a way that "the first half of the roster" is not.
## Taking the whole company is refused; that is a rename, not a split.
func split_company(company_id: int, ids: Array) -> int:
	if not companies.has(company_id): return -1
	var leaving: Array = []
	var seen := {}
	for id in ids:
		if not id is int or seen.has(id) or _unit_company.get(id, -1) != company_id: continue
		seen[id] = true
		leaving.append(id)
	if leaving.is_empty() or leaving.size() >= companies[company_id].members.size(): return -1
	return form_company(leaving, companies[company_id].width)


## Merge came free: the union of the rosters forms one company and the emptied
## originals disband themselves in `_leave_company`.
func merge_companies(ids: Array) -> int:
	var members: Array = []
	var seen := {}
	var width := 0
	var order: Array = []
	for company_id in ids:
		if company_id is int: order.append(company_id)
	# Frontage comes from the lowest-numbered company, not from whichever one
	# the caller happened to name first.
	order.sort()
	for company_id in order:
		if seen.has(company_id) or not companies.has(company_id): continue
		seen[company_id] = true
		if width <= 0: width = companies[company_id].width
		members.append_array(companies[company_id].members)
	if seen.size() < 2: return -1
	return form_company(members, width)


func disband_company(company_id: int) -> bool:
	if not companies.has(company_id): return false
	for id in companies[company_id].members: _unit_company.erase(id)
	companies.erase(company_id)
	return true


func set_company_width(company_id: int, width: int) -> bool:
	if not companies.has(company_id) or width < 1 or width > MAX_COMPANY_WIDTH: return false
	companies[company_id].width = width
	return true


## What a selection of soldiers amounts to, so the interface can name one
## button honestly instead of guessing. `split_from` is the company the
## selection is a strict part of; `whole` is the company it covers exactly.
func selection_report(ids: Array) -> Dictionary:
	var counts := {}
	var loose := 0
	var total := 0
	var seen := {}
	for id in ids:
		if not id is int or seen.has(id): continue
		var u: Soldier = units.get(id)
		if u == null or u.faction != 0 or u.health <= 0.0: continue
		seen[id] = true
		total += 1
		var company_id: int = _unit_company.get(id, -1)
		if company_id < 0: loose += 1
		else: counts[company_id] = int(counts.get(company_id, 0)) + 1
	var rows: Array = []
	var keys: Array = counts.keys()
	keys.sort()
	for company_id in keys:
		var row := company_report(company_id)
		row.selected = counts[company_id]
		rows.append(row)
	var whole := -1
	var split_from := -1
	if rows.size() == 1 and loose == 0:
		if rows[0].selected >= rows[0].size: whole = rows[0].id
		else: split_from = rows[0].id
	# A merge takes whole rosters. Offering it for a selection that holds only
	# part of a company would sweep men the player never selected into the new
	# one — so it is only a merge when every company named is wholly selected;
	# otherwise the selection itself forms the company, as the button says.
	var mergeable := loose == 0 and rows.size() >= 2
	for row in rows:
		if row.selected < row.size: mergeable = false
	return {"total": total, "loose": loose, "companies": rows,
		"whole": whole, "split_from": split_from, "mergeable": mergeable}


## How many files of ground `size` men take when they march `width` files wide
## and fold after `ranks` ranks. A fold keeps each panel `width` files wide and
## sets the panels flush beside one another, so a company too deep for the map
## still reads as one solid block rather than as several companies.
##
## The measurement that chooses which way the parade grows and the layout that
## places it must agree about this, so they ask the same function: when they
## disagreed, the parade committed to ground it then overran.
static func _files(size: int, width: int, ranks: int) -> int:
	var per_panel := width * ranks
	var panels := (size - 1) / per_panel + 1
	return (panels - 1) * width + mini(width, size - (panels - 1) * per_panel)


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
	# Sorted into the companies the commanded soldiers belong to, so each one
	# arrives in its own shape, side by side, instead of every order inventing
	# one anonymous four-wide grid. `command` has one production caller — the
	# right-click order in game.gd — and a selection may hold loose men too;
	# those land in the -1 group, which sorts first and so takes the head of
	# the parade, in the four-wide grid a bare id list has always formed.
	var groups := {}
	var commanded := {}
	for id in ids:
		var u: Soldier = units.get(id)
		if u == null or u.faction != 0 or u.health <= 0.0 or commanded.has(id): continue
		commanded[id] = true
		var key: int = _unit_company.get(id, -1)
		if not groups.has(key): groups[key] = []
		groups[key].append(id)
	var keys: Array = groups.keys()
	keys.sort()
	# The front rank lands on `ground` exactly, at every scale — to within the
	# half-metre border the clamp below keeps everyone inside, which only bites
	# for a click in the outermost half metre of the map. An earlier draft
	# pulled the origin back by the whole parade's span so the tail would stay
	# on the map, which marched 2,000 loose men to the northern edge whatever
	# the player clicked: an order that arrives somewhere else is a worse fault
	# than one that arrives crowded, so the origin is fixed and the shape gives.
	#
	# It gives three ways. The parade grows away from the nearer map edge, so a
	# click in a corner forms inland. A company's column folds into further
	# files once it is deeper than the ground behind the click — 2,000 men four
	# wide want a kilometre of depth on a 768 m map. And the row of companies
	# wraps into a second band once it is wider — 512 four-wide companies want
	# five kilometres of frontage. Without those, everything past the map's edge
	# collapsed onto the clamped half-metre below, stacked on one spot.
	var east := maxf(0.0, world.size_m - 0.5 - ground.x)
	var west := maxf(0.0, ground.x - 0.5)
	var south := maxf(0.0, world.size_m - 0.5 - ground.z)
	var north := maxf(0.0, ground.z - 0.5)
	# Frontage is measured after the fold, through the same `_files` the layout
	# uses. Measuring it before was worse than useless: a 2,000-man column four
	# wide folds to twelve files, and reading the unfolded four let an order
	# ten metres from the east edge decide nine metres of room was enough. 848
	# of those 2,000 were then clamped onto the border, on top of each other.
	#
	# The depth it folds at here is the roomier side, which is the shallowest
	# the layout can settle on: `sz` falls back to that side whenever the near
	# one is too shallow, and when it does not fall back, the block is shallow
	# enough that it never folds at all, so the two agree.
	var deep := maxi(1, int(maxf(south, north) / FILE_SPACING) + 1)
	var want_x := 0.0
	var want_z := 0.0
	for key in keys:
		var size: int = groups[key].size()
		var w: int = companies[key].width if companies.has(key) else COMPANY_WIDTH
		want_x += float(_files(size, w, deep) - 1) * FILE_SPACING + COMPANY_GAP
		want_z = maxf(want_z, float(mini(deep, (size - 1) / w + 1) - 1) * FILE_SPACING)
	want_x = maxf(0.0, want_x - COMPANY_GAP)
	# East and south unless the parade will not fit that way and the far side
	# is roomier, so an ordinary order keeps the layout it has always had and
	# only one that genuinely runs off the map turns around.
	var sx := 1.0 if want_x <= east or east >= west else -1.0
	var room_x: float = east if sx > 0.0 else west
	# Wrapping buys frontage with depth, so the depth that decides which way
	# the parade grows is the deepest block times the bands it will take, not
	# one block's. Reading one block's sent 500 four-man companies south from a
	# corner: seven bands' worth of them, laid on top of one another.
	#
	# The bands are counted by replaying the wrap below rather than by dividing
	# frontage by room, because a band cannot split a company: dividing said
	# seven where the layout then took eight, and the eighth ran off the map.
	var bands := 1
	var run := 0.0
	for key in keys:
		var cols := _files(groups[key].size(),
				companies[key].width if companies.has(key) else COMPANY_WIDTH, deep)
		if run > 0.0 and run + float(cols - 1) * FILE_SPACING > room_x:
			run = 0.0
			bands += 1
		run += float(cols - 1) * FILE_SPACING + COMPANY_GAP
	var sz := 1.0 if float(bands) * want_z + float(bands - 1) * COMPANY_GAP <= south \
			or south >= north else -1.0
	var room_z: float = south if sz > 0.0 else north
	# Shallow enough that every band fits in the room there is.
	var ranks := maxi(1, int((room_z - float(bands - 1) * COMPANY_GAP)
			/ float(bands) / FILE_SPACING) + 1)
	var lane := 0.0
	var band := 0.0
	var band_depth := 0.0
	for key in keys:
		var block: Array = groups[key]
		var width := COMPANY_WIDTH
		if companies.has(key):
			width = companies[key].width
			# Walk the company's own roster, not the order the ids arrived in,
			# so the same men laid out twice take the same files however the
			# selection was assembled. Order a company in part and the men who
			# came close up, as they would.
			block = []
			for id in companies[key].members:
				if commanded.has(id): block.append(id)
		var per_panel := width * ranks
		var cols := _files(block.size(), width, ranks)
		if lane > 0.0 and lane + float(cols - 1) * FILE_SPACING > room_x:
			lane = 0.0
			band += band_depth + COMPANY_GAP
			band_depth = 0.0
		var offset := 0
		for id in block:
			var u: Soldier = units[id]
			u.target_id = target_id
			u.target_kind = target_kind
			if u.target_id >= 0:
				at_war = true
				u.task_label = "attacking " + rival_name
			else:
				u.task_label = "marching"
			var seat := offset % per_panel
			var destination := ground + Vector3(
					sx * (lane + float((offset / per_panel) * width + seat % width) * FILE_SPACING), 0,
					sz * (band + float(seat / width) * FILE_SPACING))
			# The last net, for a parade bigger than the map itself: a man told
			# to march off the edge would never arrive.
			destination.x = clampf(destination.x, 0.5, world.size_m - 0.5)
			destination.z = clampf(destination.z, 0.5, world.size_m - 0.5)
			u.order_move(destination)
			u.ordered_to = destination
			offset += 1
		band_depth = maxf(band_depth,
				float(mini(ranks, (block.size() - 1) / width + 1) - 1) * FILE_SPACING)
		lane += float(cols - 1) * FILE_SPACING + COMPANY_GAP

func pick_target(origin: Vector3, direction: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(origin,origin+direction*4000.0,8)
	q.collide_with_areas = true
	# Look past the player's own men. The ray used to stop on whichever friendly
	# soldier stood between the camera and the enemy, and the order became a
	# plain march onto the ground behind him.
	var hit := {}
	var skipped: Array[RID] = []
	for attempt in 64:
		q.exclude = skipped
		hit = get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty(): return {}
		var candidate: Node = hit.collider
		if candidate.has_meta("unit_id"):
			var mine: Soldier = units.get(int(candidate.get_meta("unit_id")))
			if mine != null and mine.faction == 0:
				skipped.append(hit.rid)
				continue
		break
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
	_patients.clear()
	# The fire scan below needs the tick's *starting* clock, not `_time - delta`
	# back-calculated from it: floating point does not give that subtraction
	# back exactly, and at a thirtieth of a second the reconstruction landed on
	# the wrong side of a half-second boundary and skipped a scan outright.
	var was := _time
	_time += delta
	_tick_town(delta)
	for event in _impacts.duplicate():
		event.wait -= delta
		if event.wait <= 0:
			var b: Building = enemy_buildings.get(event.id) if event.faction == 0 else sim.buildings_by_id.get(event.id)
			if b != null: b.apply_damage(6.0,0.55)
			_impacts.erase(event)
	_spread_fire(was)
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
	# values() already hands back a detached array, so _remove_unit below cannot
	# disturb this walk; the extra duplicate() only copied it a second time.
	for u in units.values():
		u.advance_condition(delta)
		if u.health <= 0.0:
			_remove_unit(u)
			continue
		if u.faction == 0 and not sim.buildings_by_id.has(u.home_id):
			u.home_id = -1
		if u.faction == 0: sim.ledger.used(Config.Res.FOOD, minf(u.rations, delta/Config.DAY_LENGTH))
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


## Fire crosses from a burning building to whatever stands close to it, on both
## sides of the frontier — a blaze does not ask whose roof it is under, and
## making Ashcombe fireproof would make our own firepots pointless.
##
## Scanned on a cadence taken from `_time` rather than every tick. Nothing the
## spread depends on is unsaved and nothing is random: a building's gain is a
## function of the fires around it, the ground between, and `_time`, which is
## captured and restored. So a loaded fire lands its scans on the same absolute
## boundaries an uninterrupted one would and, stepped the same way, develops
## digit for digit identically. It is not step-size independent — neither is
## `tick_fire`, which charges damage over whatever slice it is handed — so a
## session resumed at a different frame rate diverges in the last decimals like
## every other accumulator in the simulation.
func _spread_fire(previous: float) -> void:
	var scans := floori(_time / FIRE_SPREAD_INTERVAL) - floori(previous / FIRE_SPREAD_INTERVAL)
	if scans > 0: _spread_fire_scan(float(scans) * FIRE_SPREAD_INTERVAL)

## Driven from the burning set, never from all pairs. A settlement with nothing
## alight costs one walk of each building list and stops; only once something
## burns is the coarse grid of possible targets built, and each blaze then reads
## the handful of cells its reach covers instead of every building.
##
## Per scan that costs O(buildings) to collect the burning set, O(buildings) to
## file the grid, and for each burning building the candidates standing in the
## cells its reach covers — a small constant while placement keeps buildings
## from stacking. Against that, an all-pairs proximity test is O(buildings^2),
## every frame. The grid also carries each footprint as it lies in world axes,
## because computing it per candidate put two `cos`/`sin` pairs inside the
## innermost loop of the one code path that runs when the town is on fire.
func _spread_fire_scan(elapsed: float) -> void:
	var rival: Array = enemy_buildings.values()
	var sources: Array[Building] = []
	for b: Building in rival:
		if b.fire > 0.0: sources.append(b)
	for b in sim.buildings:
		if b.fire > 0.0: sources.append(b)
	if sources.is_empty(): return
	var grid := {}
	var plans := {}
	var widest := 0.0
	for b: Building in rival: widest = maxf(widest,_index_fire(grid,plans,b))
	for b in sim.buildings: widest = maxf(widest,_index_fire(grid,plans,b))
	# Exposure is summed per target before any of it is applied. Applying each
	# source separately would let the cap in `take_fire_exposure` be paid once
	# per neighbour, which is the whole thing the cap exists to stop.
	var exposure := {}
	for s in sources:
		var plan: Vector2 = plans[s]
		# Reach is edge to edge, so the cell sweep has to allow for the widest
		# half-extent on the map at both ends of the measurement.
		var span := ceili((Building.FIRE_SPREAD_REACH + maxf(plan.x,plan.y) * 0.5 + widest) / FIRE_CELL)
		var home := _fire_cell(s)
		for dz in range(-span,span + 1):
			for dx in range(-span,span + 1):
				var key := home + Vector2i(dx,dz)
				if not grid.has(key): continue
				for n: Building in grid[key]:
					if n == s: continue
					var heat := s.fire_exposure_at(Building.footprint_gap_between(
						s.position,plan,n.position,plans[n]))
					if heat > 0.0: exposure[n] = float(exposure.get(n,0.0)) + heat
	for n: Building in exposure:
		if n.take_fire_exposure(float(exposure[n]),elapsed) and sim.buildings_by_id.get(n.id) == n:
			sim.alert.emit("%s has caught fire" % n.display_name(),n.position)

func _fire_cell(b: Building) -> Vector2i:
	return Vector2i(floori(b.position.x / FIRE_CELL),floori(b.position.z / FIRE_CELL))

## File a building as a possible target and remember the footprint it presents
## in world axes, so the sweep below neither recomputes it per candidate nor has
## to guess how far a footprint can reach out of its own cell. Returns that
## building's half-extent.
func _index_fire(grid: Dictionary, plans: Dictionary, b: Building) -> float:
	var key := _fire_cell(b)
	if not grid.has(key): grid[key] = []
	grid[key].append(b)
	var plan := b.plan_footprint()
	plans[b] = plan
	return maxf(plan.x,plan.y) * 0.5

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
	# The one choke point every death, discharge and conquest already passes
	# through, so a company can never hold an id that `units` no longer does.
	_leave_company(unit.id)
	_guard_contacts.erase(unit.id)
	unit.target_id = -1
	unit.target_kind = ""
	for other in units.values():
		if other.target_kind == "unit" and other.target_id == unit.id:
			other.target_id = -1
			other.target_kind = ""
			other.clear_goal()

func _assign_guards() -> void:
	# Both scans only ever match the opposing faction, and rival guards are
	# capped at six. Splitting the roster once turns an n^2 walk that also
	# re-allocated units.values() inside the loop into two thin cross products.
	# The single pass below keeps the original interleaved order: a rival guard
	# declares war as a side effect, and the soldiers reviewed before it in this
	# same pass must still see peace.
	var roster: Array = units.values()
	var friendly: Array = []
	var rival: Array = []
	for u in roster:
		if u.faction == 0: friendly.append(u)
		elif u.faction == 1: rival.append(u)
	# The raid list was rebuilt from sim.buildings inside the per-guard loop. It
	# is the same list for every guard, and the garrison is no longer capped at
	# six, so it is gathered once — sixteen guards against a settlement's worth
	# of buildings is the shape of walk this file has already had to delete.
	var plunder: Array = []
	if personality == "aggressive" and not conquered and sim.day > 5:
		# A rival still does not pick on a settlement with no army — unless its
		# own garrison has grown past RAID_GARRISON, which takes a town that has
		# fed, housed and armed that many men. That is the clock: ignore the
		# neighbour long enough and the neighbour comes for the supply yard.
		if not friendly.is_empty() or rival.size() >= RAID_GARRISON:
			for b in sim.buildings:
				if b.type_id in ["supply_hut","fort","barracks"]: plunder.append(b)
	for u in roster:
		if u.faction == 0:
			if _target(u) != null or not at_war: continue
			for other in rival:
				if u.position.distance_to(other.position)<16:
					u.target_id=other.id; u.target_kind="unit"; break
			continue
		var nearest: Soldier
		var best := 90.0 if personality != "loner" else 45.0
		for other in friendly:
			if other.health > 0.0 and (at_war
					or (personality == "aggressive" and sim.day > 5.0)):
				var distance: float = u.position.distance_to(other.position)
				if distance < best: nearest=other; best=distance
		if nearest != null:
			at_war = true
			u.target_id=nearest.id; u.target_kind="unit"; u.task_label="defending town"
		elif not plunder.is_empty():
			var candidate: Building
			var closest := INF
			for b: Building in plunder:
				var reach: float = u.position.distance_to(b.position)
				if reach < closest:
					candidate=b; closest=reach
			if candidate != null:
				at_war=true; u.target_id=candidate.id; u.target_kind="building"; u.task_label="raiding supplies"
		else:
			u.target_id=-1; u.target_kind=""
			# Unchanged from before the town expanded. Every rival garrison in
			# the game used to be dead of hunger by about day ten — measured at
			# HEAD: rations gone on day six, all three down by day ten, with 136
			# food sitting in the keep they stood 43 m away from. The cause was
			# not this line. It was the harvest loss in `_tick_growers`: a grower
			# waiting at the farm destroyed every tick of its output, so the farm
			# stood at 0.0 permanently and was never a store a guard could draw
			# on, while the keep was outside `_refill`'s 24 m. With that fixed the
			# farms hold a load again and the garrison lives. Sending a hungry
			# guard to the keep's door as well was tried and is deliberately not
			# here: removing it moved neither the day-twelve nor the day-sixty
			# garrison, so it was a behaviour nothing could show.
			if u.position.distance_to(rival_position)>45: u.order_move(rival_position+Vector3(0,0,-18))

func _tick_town(delta: float) -> void:
	if conquered: return
	var keep := _keep
	if keep == null: return
	_eat(town_population*delta/Config.DAY_LENGTH)
	_tick_growers(keep, delta)
	_tick_labour(keep, delta)
	# Both reviews are cheap unless they fire, and neither fires more than twice
	# a day. Nothing in the tick above walks the town.
	_grow_in -= delta
	if _grow_in <= 0.0:
		_grow_in = GROW_INTERVAL * 2.0 if personality == "loner" else GROW_INTERVAL
		_settle()
	_build_in -= delta
	if _build_in <= 0.0:
		_build_in = BUILD_INTERVAL
		_expand(keep)
	if _time >= _recruit_at and (at_war
			or (personality == "aggressive" and sim.day > 5.0)):
		_recruit_at=_time+Config.DAY_LENGTH*(2.0 if personality=="aggressive" else 4.0)
		var guards := units.size()-friendly_ids().size()
		# At war a town does what it must, and the conscription fixtures hold it
		# to that: it will strip its own fields bare. At peace an aggressive
		# neighbour arms only where the fields have slack for another mouth —
		# because a guard is still a mouth, and a guard is a grower who has left
		# the field. Without this it conscripted itself to death: eight
		# residents became four soldiers, the harvest halved twice, and the town
		# that had been arming was three people and no garrison by day thirty.
		if (at_war or _fields_feed_another()) \
				and guards<_guard_cap() and town_population > 0 and not _workers.is_empty() and _can_spare(12.0):
			_eat(12.0)
			var worker: Citizen = _workers.back()
			var identity := SaveGame._capture_citizen(worker)
			var recruit := _spawn_unit(1, worker.position, worker.id, worker.asset_id)
			recruit.apply_state(identity, registry)
			recruit.apply_damage(100.0-worker.service_health)
			recruit.position = worker.position
			recruit._wear_anchor = recruit.position
			remove_grower(worker)


## The town eats out of the keep and then out of its granaries. The granary the
## rival is founded with used to be scenery — nothing put food in it and nothing
## took food out — and that mattered once the town grew: the keep holds 400 of
## everything together, so a town banking a season's food filled it and could
## no longer stack the timber for the next house. An aggressive neighbour froze
## at ten buildings on 308 food it had nowhere to put.
func _eat(amount: float) -> void:
	var left := amount
	if _keep != null: left -= _keep.remove(Config.Res.FOOD, left)
	for b in _granaries:
		if left <= 0.0: return
		left -= b.remove(Config.Res.FOOD, left)


## Food the town can actually reach, keep and granaries together.
func _town_food() -> float:
	var total := 0.0
	if _keep != null: total += _keep.available(Config.Res.FOOD)
	for b in _granaries: total += b.available(Config.Res.FOOD)
	return total


## Where a loaded grower takes his basket: the keep while it has room for a
## load, otherwise the first granary that has.
func _deposit() -> Building:
	if _keep == null: return null
	if _keep.space_for(Config.Res.FOOD) >= LOAD: return _keep
	for b in _granaries:
		if b.space_for(Config.Res.FOOD) >= LOAD: return b
	return _keep


## Growers carry food from the farm they are employed at, not from whichever
## farm happens to be first in the town. Walking `_workers` once to count hands
## per farm costs one pass over at most MAX_GROWERS people; the farms themselves
## come from the cached index.
func _tick_growers(keep: Building, delta: float) -> void:
	if _farms.is_empty(): return
	var deposit: Building = _deposit()
	if deposit == null: deposit = keep
	var hands := {}
	for worker in _workers:
		if sim.water != null and sim.water.handles(worker): continue
		var at: int = _worker_farm.get(worker.id,-1)
		hands[at] = int(hands.get(at,0)) + 1
	for farm in _farms:
		var staffed: int = int(hands.get(farm.id,0))
		if staffed > 0:
			farm.add(Config.Res.FOOD,delta/Config.DAY_LENGTH*6.0*mini(staffed, farm.field_count()))
	for worker in _workers:
		if sim.water != null and sim.water.handles(worker): continue
		var farm: Building = enemy_buildings.get(_worker_farm.get(worker.id,-1))
		if farm == null: continue
		var leg: int = _worker_leg.get(worker.id,0)
		var destination := _door(farm) if leg == 0 else _door(deposit)
		worker.set_goal(destination)
		worker.advance(delta,world)
		if not worker.has_arrived(): continue
		if leg == 0:
			# Wait for a load worth carrying, and only then take it. The old
			# order was `remove` first and abandon the result if it came to less
			# than a tenth — which threw that tenth away, because `remove` has
			# already taken it off the farm. At the half-second step the game
			# actually runs at, a farm makes 0.05 a tick, so every tick a grower
			# stood waiting destroyed the whole of that tick's harvest. It only
			# looked sound because the one fixture that measured it drove
			# `_tick_town` a second at a time, where the tick's output is
			# exactly the tenth the test was written against.
			if farm.available(Config.Res.FOOD) < LOAD_MIN: continue
			var amount := farm.remove(Config.Res.FOOD,minf(LOAD,farm.available(Config.Res.FOOD)))
			worker.pick_up(Config.Res.FOOD,amount,registry)
			_worker_leg[worker.id]=1
		else:
			var amount := minf(worker.carrying_amount,deposit.space_for(Config.Res.FOOD))
			deposit.add(Config.Res.FOOD,amount)
			worker.carrying_amount -= amount
			if worker.carrying_amount<=0.01:
				worker.drop(); _worker_leg[worker.id]=0
		worker.clear_goal()


## Residents who are not growers cut timber and stone into the keep. Ceilings
## exist because the keep holds 400 of everything together: a town that stacked
## materials without limit would crowd out the food it lives on, and materials
## past the price of the next building buy nothing anyway.
func _tick_labour(keep: Building, delta: float) -> void:
	var labourers := town_population - _field_hands()
	if labourers <= 0: return
	var day := delta / Config.DAY_LENGTH * float(labourers)
	_gather(keep, Config.Res.TIMBER, LABOUR_TIMBER * day, TIMBER_CEILING)
	_gather(keep, Config.Res.STONE, LABOUR_STONE * day, STONE_CEILING)
	# Only a town that trades has any reason to dig iron. Any neighbour that is
	# not at war will sell — `trade_access_reason` turns on war, defeat and
	# conquest, not on temperament, and `trade_routes.gd` only narrows a loner to
	# one caravan at a time. What a peaceful town alone does is dig MORE: the 32
	# iron seeded at founding is otherwise the last iron the others ever have, so
	# a peaceful neighbour is the only one worth going back to.
	if personality == "peaceful":
		_gather(keep, Config.Res.IRON, LABOUR_IRON * day, IRON_CEILING)


## Growers who actually have a farm to walk to. A grower whose farm burned down
## when every other farm was already full keeps his place in `_workers` but has
## nowhere to work, and counting him as a grower made him vanish from the town's
## economy entirely — no field to harvest and not counted as a labourer either.
## He is a resident with no job, which is a labourer.
func _field_hands() -> int:
	var hands := 0
	for worker in _workers:
		if enemy_buildings.has(int(_worker_farm.get(worker.id, -1))): hands += 1
	return hands


func _gather(keep: Building, res: int, amount: float, ceiling: float) -> void:
	var room := minf(amount, ceiling - keep.inventory[res])
	if room > 0.0: keep.add(res, room)


## Food the town can commit without eating into what the people already there
## will want. Everything that costs the town food asks this first, so a hungry
## settlement neither breeds nor arms — which is what stopped an aggressive
## rival from conscripting its own growers until its guards starved.
func _can_spare(cost: float) -> bool:
	return _town_food() >= FOOD_RESERVE + float(town_population) + cost


## How many soldiers the town will keep under arms. Every one of them was a
## grower, so a garrison is paid for in food production, not conjured.
##
## Six is the floor because six is the garrison the rival has always been able
## to raise; a town the size it is founded at behaves exactly as it used to.
## What growth buys is the headroom above that, and how much of it a town buys
## is the clearest thing that separates the three temperaments at day 120.
func _guard_cap() -> int:
	match personality:
		"aggressive": return clampi(6 + town_population / 2, 6, MAX_GUARDS)
		"loner": return clampi(6 + town_population / 8, 6, 8)
		_: return clampi(6 + town_population / 6, 6, 11)


## What the worked fields yield in a day. A farm's `fields` are already clamped
## to the hands standing in them, so the plots are the whole answer.
func _harvest_rate() -> float:
	var rate := 0.0
	for farm in _farms: rate += 6.0 * float(farm.field_count())
	return rate


## Everyone the town feeds: residents, plus the garrison whose packs are filled
## from the same stores.
func _mouths() -> int:
	var fed := town_population
	for u in units.values():
		if u.faction == 1 and u.health > 0.0: fed += 1
	return fed


## Whether the fields as they stand could feed one more person.
func _fields_feed_another() -> bool:
	return _harvest_rate() >= float(_mouths() + 1) * HARVEST_MARGIN


func _housing() -> int:
	var rooms := 0
	for b: Building in enemy_buildings.values(): rooms += b.def.houses
	return rooms


func _population_cap() -> int:
	match personality:
		"aggressive": return mini(MAX_TOWN_POPULATION, 36)
		"loner": return mini(MAX_TOWN_POPULATION, 16)
		_: return MAX_TOWN_POPULATION


func _building_cap() -> int:
	match personality:
		"aggressive": return mini(MAX_RIVAL_BUILDINGS, 20)
		"loner": return mini(MAX_RIVAL_BUILDINGS, 11)
		_: return MAX_RIVAL_BUILDINGS


## One more resident, if the town has a roof for him and food to spare beyond
## what the people already there will eat. A town with nobody left in it stays
## empty: growth is people having children, not a settlement respawning.
## `_fields_feed_another` here is the complement of the farm want below, so the
## two cannot disagree about whether the town is short. Measured, it is currently
## slack: remove it and nothing about any of the three towns at day 120 changes,
## because `_can_spare` and `_population_cap` both bite first. It is kept because
## it is the same rule stated once, and it becomes the binding one the moment
## MAX_TOWN_POPULATION is raised — the mutation table records it as unguarded
## rather than pretending a check covers it.
func _settle() -> void:
	if town_population <= 0 or town_population >= _population_cap(): return
	if town_population >= _housing() or not _fields_feed_another(): return
	if not _can_spare(SETTLE_FOOD): return
	_eat(SETTLE_FOOD)
	town_population += 1
	_staff_farms()


## Free plots on existing farms, filled from the town's own spare residents.
## LABOUR_RESERVE hands are never taken, so a town always keeps someone cutting
## timber; without that a second farm ate the workforce and the town, now fed,
## could never build a third.
func _staff_farms() -> void:
	var changed := {}
	while _workers.size() < MAX_GROWERS \
			and _workers.size() + LABOUR_RESERVE < town_population:
		var farm := _least_staffed()
		if farm == null: break
		_add_grower(farm)
		changed[farm] = true
	for farm: Building in changed:
		farm.sync_fields_to_workers()
		_protect_farm(farm, true, false)


func _least_staffed() -> Building:
	return _least_staffed_of({})


## The farm with the fewest hands that still has a slot and a plot for one more.
##
## `pending` lets `_reconcile_farms` ask about rosters it is still assembling
## rather than about `farm.workers`, which it does not write until afterwards.
## Without that, re-homing the three growers off a burned farm sent all three to
## the same surviving one — each of them read the same stale count — leaving a
## three-slot farm holding six and another farm empty. `_staff_farms` needs no
## such thing: `_add_grower` appends to `farm.workers` as it goes.
func _least_staffed_of(pending: Dictionary) -> Building:
	var best: Building
	var fewest := 0
	for farm in _farms:
		var held: int = pending[farm.id].size() if pending.has(farm.id) else farm.workers.size()
		if held >= farm.def.worker_slots or held >= farm.all_plots().size(): continue
		if best == null or held < fewest:
			best = farm
			fewest = held
	return best


## Put every grower on a farm that still stands and give each farm the roster it
## actually has. This is also the repair pass: `WaterSystem` drowns a rival
## grower and strikes him off `_enemy_type("farm")`, which is the first farm in
## the town and not necessarily his, so the town reconciles rather than trusting
## that bookkeeping. Runs on the build review, over at most MAX_GROWERS people.
func _reconcile_farms() -> void:
	var rosters := {}
	for farm in _farms: rosters[farm.id] = PackedInt32Array()
	# Two passes. Everyone who still has a farm keeps it first, and only then are
	# the ones who have lost theirs offered what is genuinely left. Placing them
	# as the list was walked handed a displaced grower a slot that a grower
	# further down the list already held, and a three-slot farm came back with
	# four — the room looked free only because its own people had not been
	# counted yet.
	var orphans: Array = []
	for worker in _workers:
		var id: int = _worker_farm.get(worker.id, -1)
		if rosters.has(id): rosters[id].append(worker.id)
		else: orphans.append(worker)
	for worker in orphans:
		var farm := _least_staffed_of(rosters)
		if farm == null:
			_worker_farm.erase(worker.id)
			continue
		_worker_farm[worker.id] = farm.id
		rosters[farm.id].append(worker.id)
	for farm in _farms:
		var roster: PackedInt32Array = rosters[farm.id]
		roster.sort()
		if farm.workers.size() == roster.size():
			var same := true
			for i in roster.size():
				if farm.workers[i] != roster[i]: same = false
			if same: continue
		farm.workers.assign(roster)
		farm.sync_fields_to_workers()
		_protect_farm(farm, true, false)


## What the town wants next, best first — food, then roofs, then somewhere dry
## for the surplus, then water, which is the order a settlement needs things in.
## A list rather than one answer because
## the first want is often the one there is no ground for — a farm needs soil,
## and an aggressive town's ground lies toward a river it cannot build past. A
## single answer meant one unsiteable want froze the whole settlement: it asked
## for a farm every review for a hundred days and never raised a house.
func _wanted() -> Array[String]:
	var houses := 0
	var granaries := 0
	var wells := 0
	for b: Building in enemy_buildings.values():
		match b.type_id:
			"house": houses += 1
			"granary": granaries += 1
			"well": wells += 1
	var wants: Array[String] = []
	# A farm exactly when the fields the town already works cannot feed one more
	# mouth, and every plot it owns already has someone standing in it. This is
	# the complement of the test `_settle` makes, which is what breaks the
	# deadlock: population was gated on food, food on farms and farms on
	# population, so a town that could not feed itself could never farm its way
	# out of it.
	# A farm that came up with no plots at all is not a farm, and the town must
	# not answer being hungry by raising another one beside it. On ground where
	# `create_fields` finds nothing viable, `_least_staffed` skips the farm (no
	# plots, so no room) and the harvest never rises, so without this the town
	# asks for a farm every review until it hits MAX_FARMS.
	#
	# That ground is real and it is not this file's doing: measured at HEAD, on
	# a 1536 m and a 3072 m world the founding farm `generate_rival` itself
	# places comes up with zero plots, the same before this work as after. The
	# rival has never grown anything on those maps. Expansion cannot fix that —
	# it lives in `create_fields`/`_has_farmland` — but it can decline to raise
	# five more barren farms on top of it, which is what it did before this
	# guard: five farms, no fields, a starved garrison and a town still eight
	# people strong on day thirty.
	var barren := 0
	for farm in _farms:
		if farm.all_plots().is_empty(): barren += 1
	if _farms.size() < MAX_FARMS and barren == 0 and _least_staffed() == null \
			and not _fields_feed_another():
		wants.append("farm")
	if town_population + 2 > _housing(): wants.append("house")
	# Somewhere dry for the surplus once the keep cannot hold it, and then a
	# well. An aggressive town wants neither until it has run out of roofs to
	# raise: its stone goes on housing more people to arm.
	if granaries * 4 < houses: wants.append("granary")
	if personality != "aggressive" and wells * 10 < town_population:
		wants.append("well")
	return wants


## Where the next building is sited from: outward from the keep, further out as
## the town fills, in a direction the campaign's own generator picks.
##
## It used to lean — an aggressive town siting toward us, a loner away. That is
## gone, because it could not be shown. `_site` searches rings around this
## anchor and takes the first ground the player's own placement rules accept, and
## with a 25 m spacing rule and a river it cannot build past, where there is room
## beats where the town would rather be. Measured over the eight buildings an
## aggressive town raises by day 120, as the mean bearing of a new building from
## its own keep toward our settlement (1.0 being straight at us): 0.70 on seed
## 42, 0.56 on seed 20260911 and 0.17 on seed 1776 — where the peaceful town on
## that same seed managed 0.28. A temperament that shows up on two seeds out of
## three is not a temperament, so the personalities tell themselves apart by what
## they build and how hard they arm, which they do on every seed.
func _growth_anchor() -> Vector3:
	var angle := _rng.randf() * TAU
	return rival_position + Vector3(cos(angle), 0, sin(angle)) \
			* (26.0 + float(enemy_buildings.size()) * 5.0)


## One building, paid for out of the keep and stood on ground `_site` accepts.
## That is `sim.can_place` with its last argument false — the rival is held to
## the player's slope, water, footprint and spacing rules, but not to the
## resource-obstruction rule, so it will raise a house on ground the player
## would first have to clear the trees from, and `_create_building` then clears
## them. That is `_site`'s long-standing behaviour and the comment there says
## why; it is recorded here because "the rules the player is held to" would be
## too strong a claim for what is actually checked. Nothing here is on a timer:
## without the cost in store, or without a site, the review does nothing and
## comes back later.
func _expand(keep: Building) -> void:
	_reconcile_farms()
	# Replacing a grower the town lost — drowned, or conscripted — belongs here
	# and not only on the back of a successful `_settle`. Hung off settling, a
	# town that had gone short of food could never put anyone back in the
	# fields, because settling is the first thing hunger stops: one drowning
	# took a third of the harvest away permanently.
	_staff_farms()
	_advance_crops()
	if enemy_buildings.size() >= _building_cap(): return
	for type_id in _wanted():
		var def := BuildingDefs.get_def(type_id)
		var affordable := true
		for res in def.cost:
			if keep.inventory[res] + 0.0001 < float(def.cost[res]): affordable = false
		if not affordable: continue
		var at := _site(_growth_anchor(), type_id)
		if at == Vector3.INF: continue
		for res in def.cost: keep.remove(res, float(def.cost[res]))
		var b := _create_building(type_id, at)
		if b.def.is_farm():
			b.create_fields(world.heightmap, world.nav, registry)
			b.set_crop_growth(0.0)
			_protect_farm(b, true, true)
			_staff_farms()
		return
	# Nothing wanted was both paid for and siteable. A siting scan is the
	# expensive branch in this file, so a town with nowhere to put what it wants
	# waits rather than repeating it twice a day for the rest of the game.
	_build_in = BUILD_BACKOFF


## New fields come up bare and fill in, so a farm raised last week reads as one
## on a scout's report rather than as a mature field that appeared overnight.
## 0.7 is where `generate_rival` puts the founding farm, so nothing outgrows it.
func _advance_crops() -> void:
	for farm in _farms:
		if farm.crop_growth < 0.7:
			farm.set_crop_growth(minf(0.7, farm.crop_growth + 0.06))

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
	_index_town()
	# Growers of a burned farm are re-homed here rather than on the next build
	# review, so `_worker_farm` never names a building that is gone. `capture`
	# writes that table out, and a save whose growers point at rubble would come
	# back reconciled and no longer equal to what was written.
	if b.def.is_farm(): _reconcile_farms()
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
			"farm_id": int(_worker_farm.get(c.id, -1)),
			"goal": c._goal, "moving": c.has_goal()})
	var impacts: Array = []
	for event in _impacts:
		var buildings_by_id: Dictionary = enemy_buildings if event.faction == 0 else sim.buildings_by_id
		if buildings_by_id.has(event.id):
			impacts.append(event.duplicate())
	# Sorted by id rather than by dictionary order: forming and disbanding
	# reorder the table, and a save must not depend on that history.
	var roster: Array = []
	var company_ids: Array = companies.keys()
	company_ids.sort()
	for company_id in company_ids:
		var company: Dictionary = companies[company_id]
		roster.append({"id": company.id, "name": company.name,
			"width": company.width, "members": company.members.duplicate()})
	return {"personality": personality, "rival_name": rival_name, "town_population": town_population,
		"rival_position": rival_position, "at_war": at_war, "defeated": defeated,
		"conquered": conquered, "next_id": _next_id, "time": _time, "review": _review,
		"recruit_at": _recruit_at, "build_in": _build_in, "grow_in": _grow_in,
		"rng_state": _rng.state, "buildings": buildings,
		"units": army, "workers": workers, "ruins": _ruins.duplicate(true), "impacts": impacts,
		"companies": roster, "next_company_ordinal": _next_company_ordinal,
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
	_worker_farm.clear()
	_farms.clear()
	_granaries.clear()
	_keep = null
	_ruins.clear()
	_impacts.clear()
	_visible_contacts.clear()
	_guard_contacts.clear()
	companies.clear()
	_unit_company.clear()
	_next_company_ordinal = 1
	# _reset frees its children outright, so no cached candidate may outlive it.
	_patients.clear()
	_contact_cooldown = 0.0
	_contact_pending = false
	_contact_war = false
	_next_id = 100000
	_time = 0.0
	_review = 0.0
	_recruit_at = 0.0
	_build_in = 0.0
	_grow_in = 0.0
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
	# Optional, like every field added after save version 1. A save written
	# before the rival expanded has no review clocks; zero means the first tick
	# after loading holds the town's first review, which is what an old save
	# joining a game with an expanding neighbour should do.
	_build_in = data.get("build_in", 0.0)
	_grow_in = data.get("grow_in", 0.0)
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
	# Optional, like every field added after save version 1: a save written
	# before companies existed simply has none, and the numbering restarts.
	_next_company_ordinal = data.get("next_company_ordinal", 1)
	for entry in data.get("companies", []):
		var members: Array = []
		for id in entry.members:
			if units.has(id): members.append(id)
		if members.is_empty(): continue
		companies[entry.id] = {"id": entry.id, "name": entry.name,
			"width": entry.width, "members": members}
		for id in members: _unit_company[id] = entry.id
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
		# A save written before the town had a second farm names no farm for its
		# growers; `_reconcile_farms` below puts those on the one farm such a
		# save could have had, which is where they already were.
		var farm_id: int = entry.get("farm_id", -1)
		if enemy_buildings.has(farm_id): _worker_farm[c.id] = farm_id
	var saved_fields := {}
	for entry in data.buildings:
		saved_fields[entry.id] = entry
	for farm in _farms:
		var saved_farm: Dictionary = saved_fields.get(farm.id, {})
		if saved_farm.has("plots"):
			farm.adopt_plots(saved_farm.plots, world.heightmap, world.nav, registry)
		else:
			farm.create_fields(world.heightmap, world.nav, registry)
		farm.set_crop_growth(saved_farm.get("crop_growth", 0.7))
	# Rosters, field extents and plot protection all follow from who works
	# where, so one reconciliation settles every farm instead of the founding
	# one. It is also what makes a `restore` of a save with unassigned growers
	# capture back the same way twice.
	_reconcile_farms()
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
	# Optional: a save from before the rival expanded carries neither clock.
	# Both are intervals still to run, so neither can exceed the longest one the
	# town ever sets — a hand-edited save cannot postpone expansion for a year.
	if not _number(data.get("build_in", 0.0), 0.0, FIRST_REVIEW) \
			or not _number(data.get("grow_in", 0.0), 0.0, FIRST_REVIEW):
		return "invalid town review schedule"
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
	# Was a flat six. A town that grew earns a bigger garrison, and the ceiling
	# an edited save is held to is the largest any personality will ever keep.
	if guards > MAX_GUARDS:
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
	# Companies are optional and checked here, after `armies` is complete, so a
	# roster can be held to real living soldiers of ours. Every read goes
	# through `get`, so a save written before companies existed passes
	# untouched. Nothing below may throw: this is untrusted data.
	if not data.get("next_company_ordinal", 1) is int \
			or not _number(data.get("next_company_ordinal", 1), 1, 1e9):
		return "invalid company numbering"
	var roster: Variant = data.get("companies", [])
	if not roster is Array or roster.size() > MAX_COMPANIES:
		return "invalid company roster"
	var enlisted := {}
	for company in roster:
		if not company is Dictionary:
			return "invalid company"
		for key in ["id", "name", "width", "members"]:
			if not company.has(key):
				return "incomplete company"
		if not company.id is int or company.id < 100000 or company.id >= data.next_id or ids.has(company.id):
			return "invalid company id"
		ids[company.id] = true
		if not company.name is String or company.name.is_empty() or company.name.length() > 60:
			return "invalid company name"
		if not company.width is int or company.width < 1 or company.width > MAX_COMPANY_WIDTH:
			return "invalid company formation"
		if not company.members is Array or company.members.is_empty() or company.members.size() > 65536:
			return "invalid company strength"
		for id in company.members:
			if not id is int or not armies.has(id) or armies[id].faction != 0 or enlisted.has(id):
				return "company roster holds a missing, hostile or twice-enlisted soldier"
			enlisted[id] = true
	if data.workers.size() > MAX_GROWERS:
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
		# Optional, and -1 means "not placed yet": a grower whose farm burned
		# down between reviews has no farm, and restoring re-homes him.
		var farm_id: Variant = c.get("farm_id", -1)
		if not farm_id is int or (farm_id != -1 and (not buildings.has(farm_id)
				or buildings[farm_id].type_id != "farm")):
			return "rival worker employed at no such farm"
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
