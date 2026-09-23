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
## Scrubbing a poisoned well out by hand: half a day of one resident's labour on
## site, on top of the walk there and back. POISON_DAYS is four, so purging is
## plainly the faster road -- but it is not free and it is not instant. The well
## is also baled dry to do it, which is what keeps waiting a real option: the
## price of acting is a worker's half-day plus a well that has to refill at
## REFILL_PER_DAY, against the price of doing nothing, which is everyone who
## drinks there falling ill for four days. It costs no stored resource; the
## project already prices labour, and a tool or a plank would only add a second
## way for the order to be refused.
const PURGE_SECONDS := 90.0
## A purge is a carrier job, not a second kind of mission. Both live in
## `carriers`, share `_finish_carrier`, and are told apart by these two states.
## Folding them together is deliberate: `Simulation.population_members` walks
## `water.carriers` to find the people detached into water service, so a purger
## kept in a dictionary of its own would stop eating, stop drinking and stop
## counting as a resident for as long as the job lasted.
const PURGE_STATES := ["approach","purging"]
var sim: Simulation
var world: World
var registry: AssetRegistry
var wells: Dictionary = {}
var drinkers: Dictionary = {}
var carriers: Dictionary = {}
var poison_jobs: Dictionary = {}
var _review := 0.0
var _moved := {}
## Tick-scoped copy of the settlement's and the rival's buildings, held only for
## the duration of `tick()` (see `_tick` for why it is safe, and `_buildings`
## for what it deliberately does not cache).
var _building_cache: Dictionary = {}
var _building_cache_live := false

func setup(p_sim: Simulation, p_world: World, p_registry: AssetRegistry) -> void:
	sim = p_sim
	world = p_world
	registry = p_registry
	sim.stores.water = self
	name = "water_system"
	_sync_wells()

## Every building either side of the frontier, by id. This duplicates a
## dictionary and merges a second one, and `_well_for` and `_drink` each wanted
## it once per person: with the army marching and thirsty that was one full
## duplication of the settlement per soldier per tick, and it dominated the
## water span. During `tick` the copy is made once and handed out unchanged.
##
## What is cached is the *membership* — which ids exist and which Building each
## names. The Buildings themselves are the same references the simulation holds,
## so `under_construction`, `fire`, inventory and position are all still read
## live, and `wells` (the poison and water levels) is not cached at all: a well
## poisoned by `_poison_tick` contaminates the next drinker immediately.
func _buildings() -> Dictionary:
	if _building_cache_live: return _building_cache
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

## Faction and identity in one integer. This used to be a "%d:%d" String:
## formatting and hashing one per person per tick, and twice more inside every
## handles() call, was a measurable slice of the frame once the army was the
## population. Nothing persisted changes shape — capture() writes the faction
## and identity as separate fields and restore() packs them again, so old saves
## load unaltered.
##
## The packing claims no more than the String did. Identities are positive and
## the faction is one bit, so `_pack` is injective: it separates exactly the
## pairs "%d:%d" separated, and merges exactly the ones it merged. It does NOT
## make a person unique, because `_identity` above does not: a discharged
## veteran carries an ordinary citizen id, and if that number also happened to
## be some still-serving unit's military id the lookup would hand back that
## unit's civilian identity instead. Military ids start at 100000 and citizen
## ids at 1, so reaching the overlap means issuing a hundred thousand citizen
## ids -- cumulative over a long game of immigration and burial, not a hundred
## thousand people alive at once -- and a hand-built save may place a citizen
## id anywhere up to MAX_ENTITY_ID without issuing any. It is a property of the
## id registries, not of the key, and it is unchanged here: the String form
## collided on exactly the same pairs.
func _key(c: Citizen) -> int:
	return _pack(_faction(c),_identity(c))

static func _pack(faction: int, identity: int) -> int:
	return (identity << 1) | faction

## `_pack` is a shift and an or, so the two halves come straight back out. Any
## caller already holding a key gets the faction and the identity for the price
## of a mask, instead of re-running `_faction` (which scans the rival's worker
## list for every civilian) and `_identity` (a dictionary lookup for every
## soldier of ours). Four of those per person per tick were being recomputed
## from a key that was already in hand.
static func _faction_of(key: int) -> int:
	return key & 1

static func _identity_of(key: int) -> int:
	return key >> 1

func _people() -> Dictionary:
	var out := {}
	for c in sim.population_members(): out[_key(c)] = c
	if sim.campaign != null:
		for c in sim.campaign._workers: out[_key(c)] = c
		for u in sim.campaign.units.values():
			if u.faction == 1: out[_key(u)] = u
	return out

func handles(c: Citizen) -> bool:
	# One key per call. Every campaign unit and every citizen asks this once a
	# tick, so building the key twice here doubled a per-actor-per-frame cost.
	# The carrier check wants only the citizen id, and neither of the keyed
	# lookups can hit when both dictionaries are empty, so the key is not built
	# at all in a settlement where nobody is drinking or being moved.
	if carriers.has(c.id): return true
	if not _moved.is_empty() or not drinkers.is_empty():
		var key := _key(c)
		if _moved.has(key) or drinkers.has(key): return true
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

## `faction` is the drinker's side. Callers inside the tick loop already hold
## the packed key and pass `_faction_of(key)` rather than paying for `_faction`
## a second time for the same person.
##
## The search walks `wells` rather than every building. The old loop scanned the
## whole settlement and discarded all but the wells on the first line of the
## body, which cost a dictionary lookup per building per thirsty person; the
## wells are the only candidates either way, and a well id with no building
## behind it was never a candidate in the old form either.
##
## Identical candidates do not by themselves mean an identical winner, and this
## is where walking a different dictionary could be seen. The old `d < distance`
## left an exact tie to whichever entry came first, which was the building
## order — an order a save restores, because the buildings are placed again in
## the order they were recorded. `wells` is NOT restored in its own order:
## `setup()` runs before `restore()` and reseeds it in building order, and
## `restore()` then overwrites those entries in place. A settlement that
## finished its wells out of the order it sited them would therefore have broken
## a tie one way while playing and the other way after loading. So ties are
## broken on the building id, which is stable in both, and the result no longer
## depends on any insertion order at all: the nearest reachable well, and the
## lowest id among equals.
func _well_for(c: Citizen, faction: int) -> Building:
	var best: Building
	var distance := INF
	var buildings := _buildings()
	var enemy_buildings: Dictionary = sim.campaign.enemy_buildings if sim.campaign != null else {}
	for id in wells:
		if wells[id].water < 0.01: continue
		var b: Building = buildings.get(id)
		if b == null or b.under_construction: continue
		if int(enemy_buildings.has(id)) != faction: continue
		var door := sim.entrance_of(b,"att_entrance")
		var d := c.global_position.distance_squared_to(door)
		if d > distance or (d == distance and (best == null or b.id > best.id)): continue
		if not world.nav.can_reach(c.global_position,door): continue
		best = b
		distance = d
	return best

## `key` must be the caller's own `_key(c)`; every call site already has one.
func _move(c: Citizen, p: Vector3, delta: float, key: int) -> bool:
	if c.service_health <= 0 or (c is Soldier and c.health <= 0): return false
	_moved[key] = true
	if c is Soldier and c.incapacitated(): return false
	c.set_indoors(false)
	c.set_goal(p)
	c.advance(delta,world)
	return c.has_arrived() and not c.unreachable

func _damage(c: Citizen, amount: float) -> void:
	if c is Soldier: c.apply_damage(amount)
	else: c.service_health = maxf(0,c.service_health-amount)

## Holds the building set still for the length of one tick. Nothing reached from
## `_tick` adds or removes a building. The only writers of `sim.buildings_by_id`
## are `Simulation.place_building` and `Simulation.demolish`, and of
## `campaign.enemy_buildings` are `FrontierCampaign._create_building`,
## `_destroy_enemy` and `_reset`. Every caller of those five is a player order,
## world generation, a save restore, the test harness, or `FrontierCampaign.tick`
## — which burns down and demolishes rival buildings, but which `Simulation.tick`
## runs long after water, water being the very first thing it ticks.
##
## `_tick` does reach a fair way out of this file and twice comes back into it:
## `request_firefighting` calls `sim.detach_for_service` and `_finish_carrier`
## calls `sim.return_from_service`, and both end in `_update_stats` and its
## `stats_changed` signal, which nothing in the project connects; the second also
## runs `stores.refresh_totals`, which calls back into `transit` here. None of
## those, nor `scouting.recall` — which returns straight into `cancel_poison` —
## touches the building membership, and the ones that re-enter only read.
##
## The wrapper exists so that holding it still cannot outlive the tick. Leaving
## the flag set past the end — through a future early `return` in `_tick`, say —
## would serve a stale set to `well_info` afterwards, and
## then to a well that a player demolished between ticks. Keep the body in
## `_tick` and let this clear it.
func tick(delta: float) -> void:
	if delta <= 0 or not is_finite(delta): return
	_building_cache = _buildings()
	_building_cache_live = true
	_tick(delta)
	_building_cache_live = false
	_building_cache = {}

func _tick(delta: float) -> void:
	_moved.clear()
	_sync_wells()
	# A well under the brush holds nothing drinkable. This is the whole of the
	# "steer people away" behaviour: `_well_for` already refuses a well with no
	# water, so nobody needs telling about the purge and no second rule can drift
	# out of step with the first.
	var scrubbed := {}
	for job in carriers.values():
		if job.state == "purging": scrubbed[job.well_id] = true
	for well in wells.values():
		if scrubbed.has(well.id): well.water = 0.0
		else: well.water = minf(CAPACITY,well.water+REFILL_PER_DAY*delta/Config.DAY_LENGTH)
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
			var well := _well_for(c,_faction_of(key))
			if well != null:
				# A loaded delivery owns its destination's reserved room. Keep
				# that job through the drinking trip, just as through a meal;
				# cancelling it sends scarce workshop inputs back to their mine.
				if sim.citizens_by_id.get(c.id) == c and c.carrying_amount <= 0.01:
					var previous_job := c.job
					sim._retire_job(c)
					if previous_job != null: sim._restore_felling_claim(previous_job)
				c.clear_goal()
				# Unpacked from the key rather than recomputed: `key` is
				# `_pack(_faction(c),_identity(c))` for this very person, so the
				# two fields capture() persists are the same integers either way.
				drinkers[key] = {"faction":_faction_of(key),"person_id":_identity_of(key),"well_id":well.id}
		if drinkers.has(key): _drink(c,key,delta)
	# `carriers.has(id)` and not the bare key: one carrier's tick can now end
	# another's. `_fire_tick` breaks off a purge that is holding the only well dry
	# (see `_break_purges_for_fire`), and `_finish_carrier` erases that entry --
	# which, without this guard, would index a key this loop had already copied
	# and take the tick down with it.
	for id in carriers.keys():
		if carriers.has(id): _carrier_tick(id,delta)
	for id in poison_jobs.keys(): _poison_tick(id,delta)
	_review -= delta
	if _review <= 0:
		_review = 2.0
		for b in sim.buildings:
			# Purges share `carriers`, and a settlement that ordered one must not
			# thereby stop answering its own fires. Only bucket carriers count
			# against the automatic response limit.
			if b.fire > 0.05 and _firefighters() < 2: request_firefighting(b.id)
	# Enemy workers are actual people too; drinking poison never kills a
	# remote population counter that did not visit the well.
	if sim.campaign != null:
		for c in sim.campaign._workers.duplicate():
			if c.service_health > 0: continue
			sim.campaign.remove_grower(c)

func _drink(c: Citizen, key: int, delta: float) -> void:
	var job: Dictionary = drinkers[key]
	var b: Building = _buildings().get(job.well_id)
	if b == null or not wells.has(b.id) or b.under_construction:
		drinkers.erase(key)
		c.clear_goal()
		_resume_civilian(c)
		return
	# A well pinned dry for scrubbing is not going to refill for the rest of the
	# purge, and `amount <= 0.00001` below would otherwise leave this person
	# standing at the head waiting on water that is not coming -- for the whole
	# ninety seconds, not the moment an ordinary well takes to catch up. Release
	# them so the next tick picks somewhere else. `_well_for` will not offer this
	# well back, and if it was the only one they simply go thirsty, which is the
	# price of the order rather than a bug in it.
	if _scrubbing(b.id):
		drinkers.erase(key)
		c.clear_goal()
		_resume_civilian(c)
		return
	c.task_label = "Fetching drinking water"
	if not _move(c,sim.entrance_of(b,"att_entrance"),delta,key): return
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
		_resume_civilian(c)

func _resume_civilian(c: Citizen) -> void:
	# The water movement already consumed this tick. Restore the destination
	# without walking again or depositing the load at the well's doorstep.
	if sim.citizens_by_id.get(c.id) != c or c.carrying_amount <= 0.01 or c.workability() <= 0: return
	if c.job != null:
		var target := sim._loaded_delivery_target(c.job)
		if c.job.kind == JobBoard.Kind.BRIDGE_HAUL and sim.bridges != null:
			var bridge: Dictionary = sim.bridges.bridges.get(c.job.bridge_id,{})
			target = bridge.get("a",Vector3.INF) if not bridge.get("complete",true) else Vector3.INF
		if not c.job.cancelled and target != Vector3.INF:
			c.set_goal(target)
			c.state = Citizen.State.TRAVELLING
			c.task_label = c.job.describe()
			return
		sim._retire_job(c)
	var store := sim.stores.find_store(c.carrying_res,c.global_position,-1)
	if store != null:
		c.set_goal(sim.entrance_of(store,"att_cart_bay"))
		c.state = Citizen.State.TRAVELLING
		c.task_label = "returning %s" % Res.display(c.carrying_res)

func request_firefighting(building_id: int) -> String:
	var target: Building = sim.buildings_by_id.get(building_id)
	if target == null or target.fire <= 0: return "Choose a burning building in your settlement."
	for job in carriers.values():
		if job.target_id == building_id and job.state not in PURGE_STATES: return "A bucket carrier is already responding."
	var crew := _fire_crew(target)
	if crew.is_empty():
		# Nobody could be sent. If the reason is a purge holding water at zero, the
		# purge gives way -- see `_break_purges_for_fire` for when it is judged to
		# be the reason, and why it is broken off rather than suspended.
		#
		# No second search afterwards, because none could succeed. `_tick` refills
		# at the top and the pin overwrote this well to zero on the way past, so
		# the shaft holds nothing until the next tick, and `_well_for` wants 0.01.
		# Nor can the freed purger be used: `_moved` still carries the key their
		# own `_purge_tick` set this tick, so `handles` refuses them until it is
		# cleared. The dispatcher's next pass is what actually sends somebody, and
		# `_break_purges_for_fire` is honest about how long that takes.
		if not _break_purges_for_fire(target): return "No available resident can carry water from a reachable well."
		return "The well was being scrubbed out. The work is broken off, and a carrier goes as soon as the shaft has refilled enough to fill a bucket."
	var c: Citizen = crew[0]
	var well: Building = crew[1]
	# Nobody detached here is overloaded: `_fire_crew` refuses a person whose
	# hands are already full. See `_purge_worker` for why that matters.
	sim.detach_for_service(c)
	c.reparent(self)
	c.profession = "bucket carrier"
	c.clear_goal()
	carriers[c.id] = {"person":c,"target_id":target.id,"well_id":well.id,"state":"fill","progress":0.0}
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

## Everything both kinds of water service owe regardless of the job. Neither a
## bucket carrier nor a well purger is in `sim.citizens` any more, so hunger,
## death and the one-movement-per-person rule are settled here for both before
## the job's own leg runs -- and death routes through `_finish_carrier`, which is
## the single place a detached person is ever handed back or buried.
func _carrier_tick(id: int, delta: float) -> void:
	var job: Dictionary = carriers[id]
	var c: Citizen = job.person
	if not sim.buildings_by_id.has(c.home_id): c.home_id = -1
	if c.service_health <= 0 or (c is Soldier and c.health <= 0):
		_finish_carrier(id,true)
		return
	c.update_hunger(sim.day,delta/Config.DAY_LENGTH)
	var key := _key(c)
	# A movement already spent this tick, or a drinking trip under way, stops the
	# job's own leg. It must not stop the job from ENDING. This used to return
	# outright, which left a purger who had walked off to another well deaf to
	# everything that finishes a purge: the well they were scrubbing was pinned
	# dry for the rest of the game after its poison expired, and a well demolished
	# while they drank left them in `carriers` and out of `citizens_by_id` for
	# good -- a resident permanently lost. The termination checks run either way
	# now; only the walking and the work wait on `busy`.
	var busy := _moved.has(key) or drinkers.has(key)
	if job.state in PURGE_STATES: _purge_tick(id,job,c,key,delta,busy)
	else: _fire_tick(id,job,c,key,delta,busy)

## True while a worker is actually standing at this well with the brush, which
## is the window in which `_tick` pins its water to zero. It is NOT true while
## they are still walking there: an untouched poisoned well is still a well
## people can drink from, and saying otherwise on the panel would be a lie.
func _scrubbing(well_id: int) -> bool:
	for job in carriers.values():
		if job.well_id == well_id and job.state == "purging": return true
	return false

func _firefighters() -> int:
	var count := 0
	for job in carriers.values():
		if job.state not in PURGE_STATES: count += 1
	return count

## The well a bucket carrier could fill at and still reach `target` from.
## `request_firefighting` asks it when it hands out the job and `_fire_tick` asks
## it again when the chosen well runs dry, so a source nobody could have been
## given is not a source anybody is left standing at either.
func _fire_source(c: Citizen, target: Building) -> Building:
	var source := _well_for(c,_faction(c))
	if source == null: return null
	if not world.nav.can_reach(sim.entrance_of(source,"att_entrance"),sim.entrance_of(target,"att_entrance")): return null
	return source

## Whether this person has the hands and the health to carry a bucket. Pulled
## out because `_break_purges_for_fire` has to ask the same question `_fire_crew`
## asks, about a person who is not in `sim.citizens` yet; two copies of a filter
## this specific would drift the first time either was touched.
func _could_carry(person: Citizen) -> bool:
	if person.immigrant or person.service_health <= 0: return false
	if person.carrying_amount + (person.rations if person is Soldier else 0.0) > Config.CARRY_CAPACITY-BUCKET: return false
	if person is Soldier and (person.health <= 0 or person.incapacitated() or person.workability() <= 0): return false
	return true

## The first resident who could fetch water to `target`, and the well they would
## draw from, or an empty array.
func _fire_crew(target: Building) -> Array:
	for person in sim.citizens:
		if handles(person) or not _could_carry(person): continue
		var source := _fire_source(person,target)
		if source != null: return [person,source]
	return []

## Could anybody actually draw from this wellhead, if it held anything? This is
## the person-side half of what `_fire_source` asks, put to one particular well.
##
## `also` is the purger standing on that well. They are not in `sim.citizens`
## while detached and `handles` would refuse them in any case, but breaking the
## purge hands them straight back, so they are a real candidate -- provided their
## hands are as free as a bucket carrier's have to be, which `_purge_worker`
## does not require and so does not guarantee.
func _anyone_could_fetch(head: Vector3, also: Citizen = null) -> bool:
	for person in sim.citizens:
		if handles(person) or not _could_carry(person): continue
		if world.nav.can_reach(person.global_position,head): return true
	return also != null and _could_carry(also) and world.nav.can_reach(also.global_position,head)

## Fire outranks scrubbing. Returns true if any purge was broken off.
##
## A purge pins its well to zero for as long as the scrubbing lasts -- the
## PURGE_SECONDS of onsite work at least, and longer whenever the worker is
## pushed off the well or walks away to drink, since `_purge_tick` banks onsite
## time only while the pin in `_tick` keys on the job state alone. A march begins
## with one well. With that well held dry `_well_for` skips it, `_fire_source` returns
## null and `request_firefighting` refuses every candidate -- so one purge
## disarmed the settlement's whole firefighting response, and the automatic
## dispatcher in `_tick` went on failing at it every two seconds with nobody
## told. Measured with fire spread live: the keep ended a purged fire on 39 of
## 800 HP against 746 unpurged, which is a lost game rather than a slow one.
## Nothing in the shipped game poisons a friendly well yet, so the order cannot
## be given -- this is closed before rival sabotage makes it reachable.
##
## Broken off, not suspended. `_finish_carrier` is the single door a detached
## person comes home through, and `_purge_tick` already discards onsite progress
## the moment a worker steps off the well, so a suspended purge would either park
## a resident at the wellhead banking nothing for the length of the fire or send
## them home anyway -- the second with an extra state to save, validate and
## resume. This cancels exactly as `cancel_purge` does: the worker goes back to
## ordinary work and the well stays poisoned, because the buckets are wanted now
## and the poison keeps.
##
## Releasing a well does not fill it. The shaft was physically baled out, so it
## comes back at REFILL_PER_DAY -- 40 a day against a DAY_LENGTH of 180 s, about
## 0.22 a second. It is a candidate for `_well_for` again within a tick, since
## that asks only for 0.01, and the automatic dispatcher then sends somebody on
## its own two-second cadence: measured in `water.gd`, four seconds from the
## building catching to a carrier being detached. What is slow is the water, not
## the dispatch. Each trip draws whatever has trickled in rather than a full
## BUCKET -- about one bucket's worth every 18 s, against the twenty buckets a
## full 80-unit shaft hands out on demand -- so the response is thin for the
## first minute and ordinary after six, when the well is full again. That is the
## honest price of the order, and it is what the player is warned about when
## they give it.
##
## Broken only where the purge is genuinely the reason this fire has no water.
## `_fire_crew` also comes back empty when every resident is busy or loaded, and
## cancelling the player's order over that would be its own defect. So each
## purged well is asked the two questions `_fire_source` would have asked of it
## had it held anything: can a carrier reach the fire from its head, and could
## anybody draw from that head. Both, or it is left alone.
##
## Asked about the purged well itself and NOT about what else the settlement has.
## An earlier form here bailed out when any other watered well could reach the
## fire, which is a different question and one that answers "yes" in cases where
## no resident can use that well at all: `_well_for` offers only the NEAREST
## watered well it can reach and `_fire_source` then tests that one against the
## fire, so a second well standing full is no proof anybody can fight with it.
## That form would have vetoed the break and left a carrier at a dry head for
## the length of the purge -- the very lost game this function exists to stop.
##
## Only a state of "purging", too. A purge still walking to its well has baled
## nothing, so an empty shaft is not its doing; and if it bales one under a
## carrier already standing there, `_fire_tick` asks this question again and
## catches it then.
func _break_purges_for_fire(target: Building) -> bool:
	var door := sim.entrance_of(target,"att_entrance")
	var broken := false
	for id in carriers.keys():
		var job: Dictionary = carriers[id]
		if job.state != "purging": continue
		var well: Building = sim.buildings_by_id.get(job.well_id)
		if well == null: continue
		var head := sim.entrance_of(well,"att_entrance")
		if not world.nav.can_reach(head,door): continue
		if not _anyone_could_fetch(head,job.person): continue
		_finish_carrier(id)
		broken = true
		sim.alert.emit("Well scrubbing broken off to fight the fire — the shaft is refilling, and the water is still poisoned.",well.global_position)
	return broken

func _fire_tick(id: int, job: Dictionary, c: Citizen, key: int, delta: float, busy: bool) -> void:
	var target: Building = sim.buildings_by_id.get(job.target_id)
	var well: Building = sim.buildings_by_id.get(job.well_id)
	if target == null or target.fire <= 0 or well == null or not wells.has(well.id) or c.hunger >= Config.HUNGER_URGENT:
		# Return unused bucket water to its source when possible -- but never into
		# a well being held dry for a purge. An empty shaft is the whole premise of
		# the order, and four units tipped back in are four that `_well_for` can
		# offer a drinker before the next tick pins it to zero again. Poured out
		# instead, which is the same loss a carrier with no well left takes.
		# Nor at the price of holding the job open. A carrier part way through a
		# drinking trip cannot walk anywhere, and a drink that never finishes --
		# a well that stopped being reachable after it was chosen -- would keep
		# them detached from the settlement for good. Tip the bucket out and hand
		# them back, exactly as when the well was demolished under them: four
		# units of a well that refills against a resident lost for good.
		if c.water_bucket > 0 and well != null and wells.has(well.id) and not _scrubbing(well.id) and not busy:
			c.task_label = "Returning unused bucket water"
			if not _move(c,sim.entrance_of(well,"att_entrance"),delta,key): return
			wells[well.id].water = minf(CAPACITY,wells[well.id].water+c.water_bucket)
		_finish_carrier(id)
		return
	if busy: return
	if job.state == "fill":
		# A source can run dry under a standing firefighter: a purge pins its well
		# to zero for ninety seconds, and an ordinary well can simply be drunk
		# down. Waiting at the head for water that is not coming burned a building
		# to nothing -- the keep included -- while another well stood full, and no
		# second carrier could be sent because this one already held the fire. Ask
		# the assignment's own question again rather than wait.
		if float(wells[well.id].water) < 0.01:
			var replacement := _fire_source(c,target)
			# No other well to go to, which in a one-well settlement is every
			# time. Break the purge off and stand where they are. Not this tick's
			# water: `_tick` refills at the top and the pin already zeroed this
			# shaft on the way past, so `_fire_source` still comes back null here
			# and the fill leg below still takes nothing. From the next tick the
			# well refills instead of being pinned, and the fill leg takes
			# whatever has arrived. `request_firefighting` cannot reach this case
			# at all -- it refuses the moment a fire already has a carrier.
			if replacement == null and _break_purges_for_fire(target): replacement = _fire_source(c,target)
			if replacement != null:
				job.well_id = replacement.id
				well = replacement
				c.clear_goal()
		c.task_label = "Filling a firefighting bucket"
		if not _move(c,sim.entrance_of(well,"att_entrance"),delta,key): return
		var amount := minf(BUCKET,float(wells[well.id].water))
		if amount < 0.01: return
		wells[well.id].water -= amount
		c.water_bucket += amount
		job.state = "carry"
		_bucket(c)
		c.clear_goal()
	else:
		c.task_label = "Carrying water to the fire"
		if not _move(c,sim.entrance_of(target,"att_entrance"),delta,key): return
		target.fire = maxf(0,target.fire-c.water_bucket*0.25)
		c.water_bucket = 0
		_bucket(c)
		job.state = "fill"
		c.clear_goal()

## The one worker a purge would take, or null. `purge_quote` and `request_purge`
## both ask, so the button the player sees is disabled by exactly the search that
## would have run had they pressed it.
func _purge_worker(target: Building) -> Citizen:
	var door := sim.entrance_of(target,"att_entrance")
	for person in sim.citizens:
		if person.immigrant or handles(person) or person.service_health <= 0: continue
		# Hands already full. `sim.detach_for_service` hands the cart back but
		# leaves the cargo on the person's back, so a carter part way through a
		# cartload -- Cart.CAPACITY, four times what a pair of hands may hold --
		# became a water carrier that `validate` rejects outright as an
		# "overloaded water carrier", and the game could not be saved at all until
		# the order was cancelled.
		#
		# Refused rather than made to put the load down: goods in this game move
		# because somebody carries them, so tipping a cartload out at the wellhead
		# would either destroy it or teleport it into a store nobody walked to,
		# and neither is a thing an order to scrub a well should do. The
		# settlement sends somebody whose hands are free instead, which is what
		# `request_firefighting` above has always done -- it asks for the same
		# room and a bucket's worth besides. A carter is not refused for good,
		# only until they have walked their load to where it was going.
		if person.carrying_amount + (person.rations if person is Soldier else 0.0) > Config.CARRY_CAPACITY: continue
		if person is Soldier and (person.health <= 0 or person.incapacitated() or person.workability() <= 0): continue
		if not world.nav.can_reach(person.global_position,door): continue
		return person
	return null

## True when scrubbing this well out leaves the settlement with nothing else to
## draw from. `_break_purges_for_fire` makes that survivable rather than fatal,
## but it costs the first minute of a fire, so the order says so before it is
## given (game.gd) and the panel says so while it runs (hud.gd). Wells still
## being dug hold nothing and do not count; a rival's well is not in
## `sim.buildings_by_id` at all, which is the same reason `purge_quote` reads
## that dictionary rather than `_buildings()`.
func _sole_well(well_id: int) -> bool:
	for id in wells:
		if id == well_id: continue
		var other: Building = sim.buildings_by_id.get(id)
		if other != null and not other.under_construction: return false
	return true

## Why this reads `sim.buildings_by_id` and not `_buildings()`: only the
## settlement's own wells are there. A rival well is in `campaign.enemy_buildings`
## and so cannot be named here at all, which is deliberate -- the player may
## poison the enemy's water but may not send a resident across the frontier to
## clean it, and refusing by lookup means there is no second rule to forget.
func purge_quote(well_id: int) -> Dictionary:
	var q := {"can_purge":false,"reason":"Select one of your own completed wells.","well_id":well_id,"purging":false,"poisoned":false,"sole_well":false}
	var target: Building = sim.buildings_by_id.get(well_id)
	if target == null or target.type_id != "well" or target.under_construction or not wells.has(well_id): return q
	q.sole_well = _sole_well(well_id)
	q.poisoned = wells[well_id].poison > 0
	for job in carriers.values():
		if job.well_id == well_id and job.state in PURGE_STATES:
			q.purging = true
			q.reason = "A worker is already scrubbing this well out."
			return q
	q.reason = "This well is clean. There is nothing to scrub out."
	if not q.poisoned: return q
	q.reason = "No available resident with free hands can reach this well on foot."
	if _purge_worker(target) == null: return q
	q.reason = ""
	q.can_purge = true
	return q

func request_purge(well_id: int) -> String:
	var q := purge_quote(well_id)
	if not q.can_purge: return q.reason
	var target: Building = sim.buildings_by_id[well_id]
	var c := _purge_worker(target)
	if c == null: return "No available resident with free hands can reach this well on foot."
	sim.detach_for_service(c)
	c.reparent(self)
	c.profession = "well purger"
	c.clear_goal()
	carriers[c.id] = {"person":c,"target_id":well_id,"well_id":well_id,"state":"approach","progress":0.0}
	return ""

## The player's way back out, and the reason the order is not a trap: a worker
## sent to a well can always be called home. Nothing is refunded, because nothing
## was spent but time and the water already baled out of the shaft. Recalling
## half way through leaves the well poisoned and empty, which is the honest price
## of changing your mind.
func cancel_purge(well_id: int) -> String:
	for id in carriers.keys():
		var job: Dictionary = carriers[id]
		if job.well_id == well_id and job.state in PURGE_STATES:
			_finish_carrier(id)
			return ""
	return "No worker is scrubbing this well out."

## Every way out of a purge ends in `_finish_carrier`, which is the only thing
## that hands a detached person back: the well finished, the well demolished, the
## poison having decayed on its own while the worker walked, the worker getting
## too hungry to stay, and -- one level up in `_carrier_tick` -- the worker dying.
## Nothing here erases the entry itself.
func _purge_tick(id: int, job: Dictionary, c: Citizen, key: int, delta: float, busy: bool) -> void:
	var well: Building = sim.buildings_by_id.get(job.well_id)
	if well == null or not wells.has(well.id) or well.under_construction or wells[well.id].poison <= 0 or c.hunger >= Config.HUNGER_URGENT:
		_finish_carrier(id)
		return
	# Nothing above needs the worker to be here, so it is checked before `busy`;
	# everything below is the work itself, which waits.
	if busy: return
	if job.state == "approach":
		c.task_label = "Walking to the poisoned well"
		if not _move(c,sim.entrance_of(well,"att_entrance"),delta,key): return
		# Baling the shaft dry is the first hour of the work, and it is also what
		# makes the work legible: an empty well is one `_well_for` already skips,
		# and `_drink` lets go of anyone already walking here, so the settlement
		# visibly turns round and drinks somewhere else.
		wells[well.id].water = 0.0
		job.state = "purging"
		c.clear_goal()
		return
	c.task_label = "Scrubbing out the poisoned well"
	# Progress is onsite time only. A worker shoved off the well -- or one whose
	# path to it broke -- starts the scrubbing again, exactly as sabotage does.
	if not _move(c,sim.entrance_of(well,"att_entrance"),delta,key):
		job.progress = 0.0
		return
	job.progress += delta
	if job.progress < PURGE_SECONDS: return
	wells[well.id].poison = 0.0
	wells[well.id].poison_days = 0.0
	_finish_carrier(id)

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
	var key := _key(scout.person)
	if _moved.has(key) or drinkers.has(key): return
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
		if not _move(scout.person,sim.entrance_of(source,"att_entrance"),delta,key): return
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
	if not _move(scout.person,sim.entrance_of(target,"att_entrance"),delta,key):
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
	# Two different facts, because the panel says two different things: a purge is
	# under way, and the shaft is currently empty because of it.
	data.purging = _scrubbing(id)
	data.purge_ordered = false
	for job in carriers.values():
		if job.well_id == id and job.state in PURGE_STATES: data.purge_ordered = true
	data.sole_well = sim.buildings_by_id.has(id) and _sole_well(id)
	data.refill_per_day = REFILL_PER_DAY
	return data

func info() -> Dictionary:
	var rows: Array = []
	for b in sim.buildings:
		if wells.has(b.id): rows.append(well_info(b.id))
	var thirsty := 0
	for c in sim.population_members():
		if c.hydration <= SEEK_AT: thirsty += 1
	var firefighters := _firefighters()
	return {"wells":rows,"thirsty":thirsty,"missions":carriers.size()+poison_jobs.size(),
		"firefighters":firefighters,"purges":carriers.size()-firefighters}

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
		workers.append({"citizen":identity,"target_id":job.target_id,"well_id":job.well_id,"state":job.state,"progress":job.progress})
	return {"wells":wells.values().duplicate(true),"drinkers":drinks,"carriers":workers,"poison_jobs":poison_jobs.values().duplicate(true)}

func restore(data: Variant) -> String:
	var error := validate(data,world.size_m)
	if error != "": return error
	if not carriers.is_empty() or not poison_jobs.is_empty(): return "restore water into an empty manager"
	var people := _people()
	for entry in data.get("carriers",[]):
		if people.has(_pack(0,entry.citizen.id)): return "water carrier identity is already assigned"
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
		# `progress` is additive and optional: a save written before wells could be
		# purged has only bucket carriers in this array, and a bucket carrier's
		# progress is zero, so an old save restores to exactly what it meant.
		# There is no migration step to lean on -- save_validation rejects a
		# version mismatch outright -- so nothing may become required here.
		carriers[c.id] = {"person":c,"target_id":entry.target_id,"well_id":entry.well_id,
			"state":entry.state,"progress":float(entry.get("progress",0.0))}
		_bucket(c)
	for entry in data.get("drinkers",[]): drinkers[_pack(entry.faction,entry.person_id)] = entry.duplicate()
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
		# A citizen record embedded in a subsystem is read back with property
		# syntax below, but `_citizen` treats these fields as optional — it
		# serves the top-level roster too, where `savegame.gd` tolerates their
		# absence. Reading one that is missing throws inside the validator, and
		# a validator that throws returns null into a String rather than
		# rejecting, so a crafted save is neither loaded nor refused. Require
		# them here, exactly as `trade_routes.gd` does for a merchant.
		for field in ["asset_id", "workplace_id", "immigrant", "carrying_amount"]:
			if not entry.citizen.has(field): return "water carrier identity missing " + field
		if entry.citizen.workplace_id != -1 or entry.citizen.immigrant or ids.has(entry.citizen.id): return "invalid water carrier identity"
		ids[entry.citizen.id] = true
		if entry.target_id < 1 or entry.well_id < 1 or entry.state not in ["fill","carry"]+PURGE_STATES: return "invalid water mission"
		if entry.state != "carry" and entry.citizen.get("water_bucket",0.0) > 0: return "empty carrier has uncollected water"
		# Optional, so a save from before purges existed is silent here rather
		# than rejected; present, it must still be a real number in range, and a
		# purger who has not reached the well yet cannot have banked any of it.
		var progress: Variant = entry.get("progress",0.0)
		if not TradeRoutes._number(progress,0,PURGE_SECONDS): return "invalid purge progress"
		if float(progress) != 0.0 and entry.state != "purging": return "purge progress without onsite work"
		if entry.state in PURGE_STATES and entry.target_id != entry.well_id: return "a purge works on its own well"
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
