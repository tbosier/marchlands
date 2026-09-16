class_name Simulation
extends Node

## The settlement simulation.
##
## This class owns the entities and runs the per-tick behaviour; the decisions
## about *what work exists* live in `Production`, the food and immigration
## economy lives in `Population`, who works where lives in `Workforce`, and the
## goods index lives in `Stores`. Keeping those apart matters because they run
## on completely different cadences — behaviour is per tick, posting is on a
## rota, the economy is per day — and mixing them is what made the first
## version both slow and hard to change.
##
## Tick order: post work, run citizens (walking, and therefore wearing routes
## into the world), refresh the road graph, then the daily systems.

signal alert(text: String, position: Vector3)
signal stats_changed()

const ROAD_REFRESH_INTERVAL := 2.5
## Breathing room left around every building, in metres.
const CLEARANCE := 1.0
## Marker put in a node's `reserved_by` when the player has ordered it felled,
## distinct from any real building id.
const FELLING_CLAIM := 1000000
const STATS_INTERVAL := 0.5
## Goods on show only need to keep up with the eye, not the simulation.
const STOCK_DISPLAY_INTERVAL := 1.0

var world: World
var registry: AssetRegistry

var jobs := JobBoard.new()
var stores := Stores.new()
var workforce := Workforce.new()
var production := Production.new()
var population := Population.new()

var buildings: Array[Building] = []
var citizens: Array[Citizen] = []
var buildings_by_id: Dictionary = {}
var citizens_by_id: Dictionary = {}

var day := 0.0
var keep: Building = null
var cart: Cart = null

var stat_population := 0
var stat_homeless := 0
var stat_idle := 0
var stat_jobs_open := 0
## Work-rate multiplier from having tools in store, 1.0 to 1.0 + the bonus.
var tools_bonus := 1.0

var _next_building_id := 1
var _next_citizen_id := 1
var _road_timer := 0.0
var _stats_timer := 0.0
var _stock_timer := 0.0
var _felling_timer := 0
var _last_idle_reason := ""
var _day_marker := 0.0
var _rng := RandomNumberGenerator.new()
## Entrance positions are asked for every tick by every worker; they only
## change when a building is placed, so they are worked out once.
var _entrance_cache: Dictionary = {}


func setup(world_node: World, asset_registry: AssetRegistry,
		   seed_value: int) -> void:
	world = world_node
	registry = asset_registry
	_rng.seed = seed_value + 4242
	# A mined-out outcrop leaves walkable ground behind. Loading a save has
	# always restored it that way; play did not, so saving and reloading made
	# the map measurably more walkable than it had been a moment earlier.
	world.nodes.depletion_changed.connect(_on_node_depletion_changed)
	production.setup(jobs, stores, world)
	population.setup(stores, jobs, seed_value)
	population.alert.connect(func(text, pos): alert.emit(text, pos))


func _on_node_depletion_changed(rec) -> void:
	if rec.kind == ResourceNodes.Kind.TREE:
		return
	var c := Config.world_to_cell(rec.position)
	world.nav.set_blocked(c.x, c.y, not rec.depleted)
	jobs.clear_refusals()


func set_cart(new_cart: Cart) -> void:
	cart = new_cart
	production.set_cart(new_cart)


# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

## `delta` is in-game seconds (real delta * time scale).
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	Perf.begin("sim.total")

	var prev_day := day
	day += delta / Config.DAY_LENGTH

	stores.refresh_totals(citizens)
	if workforce.update(buildings, citizens, buildings_by_id):
		for b in buildings:
			if b.sync_fields_to_workers():
				# Staffing decides how much of the farm is under crop, and
				# ground under crop is ground no track may form on.
				_protect_fields(b, true)
	production.tick(delta, buildings)

	Perf.begin("sim.citizens")
	for c in citizens:
		_tick_citizen(c, delta)
	Perf.end("sim.citizens")

	if cart != null:
		cart.follow(world.heightmap, delta)
	world.nodes.tick_falling(delta)

	_repost_felling_orders()

	_road_timer -= delta
	if _road_timer <= 0.0:
		_road_timer = ROAD_REFRESH_INTERVAL
		var changed := world.wear.refresh_levels()
		if not changed.is_empty():
			world.nav.apply_road_changes(changed)
			jobs.clear_refusals()

	if floori(day) > floori(prev_day):
		_daily(day - _day_marker)
		_day_marker = day

	_stats_timer -= delta
	if _stats_timer <= 0.0:
		_stats_timer = STATS_INTERVAL
		_update_stats()

	_stock_timer -= delta
	if _stock_timer <= 0.0:
		_stock_timer = STOCK_DISPLAY_INTERVAL
		for b in buildings:
			b.refresh_stock_display()

	Perf.end("sim.total")


## Keep a job on the board for every tree the player has ordered cleared, until
## it is gone. One trip rarely empties a trunk.
func _repost_felling_orders() -> void:
	_felling_timer -= 1
	if _felling_timer > 0:
		return
	_felling_timer = 30
	for node_id in world.nodes.marked_ids():
		var rec := world.nodes.get_node_rec(node_id)
		if rec == null or rec.reserved_by != FELLING_CLAIM or rec.depleted:
			continue
		if jobs.count_for(JobBoard.Kind.FELL, -1, Config.Res.TIMBER) > 12:
			return
		if _felling_job_exists(rec.id):
			continue
		var job := jobs.post(JobBoard.Kind.FELL, rec.position, 62.0)
		job.res = Config.Res.TIMBER
		job.node_id = rec.id
		jobs.index(job)


func _felling_job_exists(node_id: int) -> bool:
	for job in jobs.all_jobs():
		if job.kind == JobBoard.Kind.FELL and job.node_id == node_id:
			return true
	return false


func _daily(elapsed_days: float) -> void:
	Perf.begin("sim.daily")
	var keep_pos := keep.global_position if keep else Vector3.ZERO

	world.wear.decay(elapsed_days)
	# Roads that faded overnight have to stop being roads now, not whenever the
	# refresh timer next comes round. `nav_level` is a cache over the wear
	# field, and leaving it stale meant the settlement kept routing over a
	# track that had already gone back to grass — and, more visibly, that a
	# march saved inside that window came back with different roads from the
	# one that was saved, because loading rebuilds the cache from scratch.
	var faded := world.wear.refresh_levels()
	if not faded.is_empty():
		world.nav.apply_road_changes(faded)
		jobs.clear_refusals()
	world.nodes.tick_regrowth(day)
	population.consume_food(citizens, elapsed_days, keep_pos, floori(day))
	_consume_tools(elapsed_days)
	population.grow_crops(buildings, elapsed_days)
	_run_immigration()
	_warn_about_storage(keep_pos)

	Perf.end("sim.daily")


## Tools are worn out by the people using them. While the march has some in
## store every trade works faster; when they run out, work slows to bare hands
## — which is the whole reason to dig iron and keep a forge.
func _consume_tools(elapsed_days: float) -> void:
	var workers := 0
	for b in buildings:
		if not b.under_construction:
			workers += b.workers.size()
	if workers <= 0:
		return
	var wanted := workers * Config.TOOLS_PER_WORKER_DAY * elapsed_days
	var short := stores.consume(Config.Res.TOOLS, wanted)
	tools_bonus = 1.0 + Config.TOOLS_WORK_BONUS * (
			0.0 if wanted <= 0.0 else clampf(1.0 - short / wanted, 0.0, 1.0))


func _run_immigration() -> void:
	if keep == null:
		return
	var decision := population.consider_immigration(buildings, citizens)
	var count: int = decision.get("count", 0)
	if count <= 0:
		return
	var entry := population.edge_entry_point(world)
	if entry == Vector3.INF:
		return
	for i in count:
		# The entry point was checked, but the scatter that spreads the party
		# out is applied after that check — far enough to drop somebody into
		# the lake or past the edge of the map, where their surface speed is
		# zero and they stand for ever.
		var p := entry + population.scatter_offset()
		var cell := Config.world_to_cell(p)
		if world.nav.is_solid(cell.x, cell.y):
			var free := world.nav.nearest_free(p)
			p = Config.cell_to_world(free)
			p.y = world.heightmap.height_at(p.x, p.z)
		add_citizen(p, true)
	var reasons: Array = decision.get("reasons", [])
	alert.emit("%d settlers are travelling to your lands — %s."
			% [count, ", ".join(reasons)], entry)


## Say why the settlement has stopped.
##
## A yard of idle people with no explanation is the commonest way this game
## wastes someone's time: the player can see that nothing is happening but not
## why, and the reason is nearly always one of a small number of things. Work
## it out and say it plainly.
func idle_diagnosis() -> String:
	if citizens.is_empty():
		return ""
	if stat_idle < maxi(2, citizens.size() / 3):
		return ""

	# Nowhere to put what is being produced.
	var blocked: Array[String] = []
	for b in buildings:
		if b.under_construction or not b.def.is_producer():
			continue
		var res := b.def.produces
		if b.space_for(res) < 1.0 and stores.is_full_for(res):
			var name := Res.display(res)
			if not blocked.has(name):
				blocked.append(name)
	if not blocked.is_empty():
		return ("Nowhere to put %s. Build a stockpile or a granary."
				% ", ".join(blocked))

	# Nothing that employs anyone.
	var slots := 0
	for b in buildings:
		if not b.under_construction:
			slots += b.def.worker_slots
	if slots == 0:
		return ("Nobody has anywhere to work. Build a logging camp, a quarry "
				+ "or a farm.")
	if slots < citizens.size() / 3:
		return ("Only %d work places for %d people. More workplaces would put "
				% [slots, citizens.size()] + "them to use.")

	# Work exists but cannot be reached or supplied.
	if jobs.open_jobs() == 0:
		var waiting := 0
		for b in buildings:
			if b.under_construction and not b.materials_complete():
				waiting += 1
		if waiting > 0:
			return ("%d building site%s waiting on materials you do not have."
					% [waiting, "" if waiting == 1 else "s"])
		return "No work to be had. Place something to build."
	return ""


func _warn_about_storage(keep_pos: Vector3) -> void:
	var reason := idle_diagnosis()
	if reason == "" or reason == _last_idle_reason:
		if reason == "":
			_last_idle_reason = ""
		return
	_last_idle_reason = reason
	alert.emit(reason, keep_pos)


# ---------------------------------------------------------------------------
# Citizen behaviour
# ---------------------------------------------------------------------------

func _tick_citizen(c: Citizen, delta: float) -> void:
	if c.immigrant:
		_tick_immigrant(c, delta)
		return

	if c.job == null and c.carrying_amount > 0.01:
		# Someone holding goods with no job to justify them — a hauler whose
		# destination was demolished, a worker restored from a save mid-round.
		# They must put it down before they are given anything else: the haul
		# tick assumes an empty pair of hands on its first leg, and a job taken
		# while loaded would deposit the load under the new job's resource.
		_carry_stray_load(c, delta)
		return

	if c.job == null:
		_seek_job(c)
		if c.job == null:
			_idle_behaviour(c, delta)
			return

	# A job whose site cannot be walked to is not a job. Releasing it lets
	# someone better placed take it, rather than one citizen blocking it.
	if c.unreachable:
		_abandon(c)
		return

	match c.job.kind:
		JobBoard.Kind.HAUL: _tick_haul(c, delta)
		JobBoard.Kind.GATHER: _tick_gather(c, delta)
		JobBoard.Kind.HARVEST: _tick_harvest(c, delta)
		JobBoard.Kind.BUILD: _tick_build(c, delta)
		JobBoard.Kind.FELL: _tick_fell(c, delta)
		JobBoard.Kind.CRAFT: _tick_craft(c, delta)
		_: _abandon(c)


func _seek_job(c: Citizen) -> void:
	c.job = jobs.best_for(c.id, c.global_position, JobBoard.Accept.ANY,
			c.workplace_id)
	if c.job != null:
		c.state = Citizen.State.TRAVELLING
		c.set_goal(c.job.position)
		c.task_label = c.job.describe()


func _abandon(c: Citizen) -> void:
	_release_cart(c)
	if c.job != null:
		if c.job.kind == JobBoard.Kind.HAUL and c.job.loaded:
			# The goods are already on this citizen's back. Handing the job to
			# somebody else would have them draw the same load from the source
			# a second time; retire it instead, give back what it still holds,
			# and let the stray-load path walk the goods to a store.
			_release_reservations(c.job)
			jobs.cancel(c.job)
		else:
			# The job itself is still live and goes back on the board, so it
			# keeps its claims — the goods waiting at the source and the room
			# promised at the destination belong to the *job*, not to whoever
			# last held it. Releasing them here left an open haul with nothing
			# backing it, and the same goods were promised to somebody else.
			# A job dropped because this citizen could not walk to it is
			# refused for them alone.
			jobs.release(c.job, c.id if c.unreachable else -1)
	_go_idle(c)


## Drop a job because the work itself no longer exists, as opposed to
## `_abandon`, which means only that this citizen could not do it.
func _retire_job(c: Citizen) -> void:
	_release_cart(c)
	if c.job != null:
		_release_reservations(c.job)
		jobs.cancel(c.job)
	_go_idle(c)


func _go_idle(c: Citizen) -> void:
	c.job = null
	c.state = Citizen.State.IDLE
	c.task_label = "idle"
	# Drop the route with the job. Leaving it set meant `set_goal` treated the
	# next identical destination as a no-op and never cleared `unreachable`, so
	# a citizen who failed to reach a job claimed and abandoned it every tick
	# for the rest of the game.
	c.clear_goal()


## A felling order lives in the tree's `reserved_by`, and a job retired for
## some other reason (its destination store was pulled down, say) clears it.
## The order itself is the *marker*, which survives — so put the claim back
## rather than leaving a marked tree nothing will ever come and cut.
func _restore_felling_claim(job: JobBoard.Job) -> void:
	if job.kind != JobBoard.Kind.FELL or job.node_id < 0:
		return
	var rec := world.nodes.get_node_rec(job.node_id)
	if rec != null and not rec.depleted and world.nodes.is_marked(rec.id):
		rec.reserved_by = FELLING_CLAIM


func _release_reservations(job: JobBoard.Job) -> void:
	if job.kind == JobBoard.Kind.HAUL and job.res >= 0:
		# A loaded haul consumed its source reservation when it picked up.
		# Releasing it again drops the reservation covering *other* pending
		# jobs, and the same goods get promised twice.
		if not job.loaded:
			var src: Building = buildings_by_id.get(job.source_id)
			if src:
				src.reserved[job.res] = maxf(0.0,
						src.reserved[job.res] - job.amount)
		var dst: Building = buildings_by_id.get(job.dest_id)
		if dst:
			dst.incoming[job.res] = maxf(0.0, dst.incoming[job.res] - job.amount)
	elif job.kind == JobBoard.Kind.GATHER and job.node_id >= 0:
		var node := world.nodes.get_node_rec(job.node_id)
		if node:
			node.reserved_by = -1


func _tick_haul(c: Citizen, delta: float) -> void:
	var job := c.job
	var src: Building = buildings_by_id.get(job.source_id)
	var dst: Building = buildings_by_id.get(job.dest_id)
	if src == null or dst == null:
		_abandon(c)
		return

	if c.carrying_amount <= 0.0:
		# Leg 1: fetch the cart if this job needs it, then load at the source.
		if job.uses_cart and not c.has_cart():
			if cart == null or not cart.is_free():
				# Someone else got there first; carry what a person can. The
				# source reservation and the destination's promised room were
				# both sized for a cartload, so hand back the difference —
				# otherwise three quarters of the load stays reserved at one
				# end and promised at the other with nobody coming for it.
				jobs.drop_cart_claim(job)
				var trimmed: float = minf(job.amount, Config.CARRY_CAPACITY)
				var freed: float = job.amount - trimmed
				if freed > 0.0:
					src.reserved[job.res] = maxf(0.0,
							src.reserved[job.res] - freed)
					dst.incoming[job.res] = maxf(0.0,
							dst.incoming[job.res] - freed)
				job.amount = trimmed
			else:
				c.task_label = "fetching the cart"
				c.set_goal(cart.parked_at)
				c.advance(delta, world)
				if not c.has_arrived():
					return
				cart.take(c)

		c.set_goal(entrance_of(src, "att_cart_bay"), Config.WEAR_PEDESTRIAN)
		c.advance(delta, world)
		if not c.has_arrived():
			return

		var got := src.remove(job.res, job.amount)
		src.reserved[job.res] = maxf(0.0, src.reserved[job.res] - job.amount)
		job.loaded = true
		if got <= 0.01:
			dst.incoming[job.res] = maxf(0.0, dst.incoming[job.res] - job.amount)
			_release_cart(c)
			jobs.complete(job)
			_go_idle(c)
			return

		c.pick_up(job.res, got, registry)
		if c.has_cart() and cart:
			cart.load_goods(job.res)
		c.task_label = "%s %s" % [
			"carting" if c.has_cart() else "hauling", Res.display(job.res)]
		c.set_goal(entrance_of(dst, "att_cart_bay"), Config.WEAR_PEDESTRIAN)
		return

	# Leg 2: carry it home.
	c.advance(delta, world)
	if not c.has_arrived():
		return

	var amount := c.drop()
	dst.incoming[job.res] = maxf(0.0, dst.incoming[job.res] - job.amount)
	# What the destination would not take. `add` and `deliver_material` both
	# report this, and both reports used to be thrown away: if the source had
	# filled up while the hauler walked, the remainder simply ceased to exist.
	var left := 0.0
	if dst.under_construction:
		left = dst.deliver_material(job.res, amount)
	else:
		left = amount - dst.add(job.res, amount)
	if left > 0.01:
		left -= src.add(job.res, left)
	if left > 0.01:
		left = _spill_into_stores(job.res, left, c.global_position, dst)
	if left > 0.01:
		# Nowhere in the march will take it. It stays on their back rather
		# than being deleted, and the stray-load path retries every tick.
		c.pick_up(job.res, left, registry)
	_release_cart(c)
	jobs.complete(job)
	_go_idle(c)


## Hand the cart back. Called whenever a carter finishes or drops their job.
func _release_cart(c: Citizen) -> void:
	if cart != null and cart.carrier == c:
		cart.unload()
		cart.release(world.heightmap)


func _tick_gather(c: Citizen, delta: float) -> void:
	var job := c.job
	var site: Building = buildings_by_id.get(job.dest_id)
	var node := world.nodes.get_node_rec(job.node_id)
	if site == null or node == null \
			or (node.depleted and c.carrying_amount <= 0.0):
		_abandon(c)
		return

	if c.carrying_amount <= 0.0 and c.state != Citizen.State.WORKING:
		c.advance(delta, world)
		if not c.has_arrived():
			return
		var units: float = minf(Config.CARRY_CAPACITY, node.amount)
		c.begin_work(units * Config.WORK_TICKS_PER_UNIT / tools_bonus)
		c.task_label = "felling" if node.kind == ResourceNodes.Kind.TREE \
				else "cutting stone"
		c.face_towards(node.position)
		return

	if c.state == Citizen.State.WORKING:
		if not c.work_tick(delta):
			c.update_animation(delta, 0.0)
			return
		var taken := world.nodes.harvest(node, Config.CARRY_CAPACITY, day)
		node.reserved_by = -1
		if taken <= 0.01:
			_abandon(c)
			return
		c.pick_up(job.res, taken, registry)
		c.state = Citizen.State.TRAVELLING
		c.task_label = "carrying %s" % Res.display(job.res)
		c.set_goal(entrance_of(site, "att_stock_0"), Config.WEAR_PEDESTRIAN)
		return

	c.advance(delta, world)
	if not c.has_arrived():
		return
	_deposit(c, site, job.res)
	jobs.complete(job)
	_go_idle(c)


func _tick_harvest(c: Citizen, delta: float) -> void:
	var job := c.job
	var farm: Building = buildings_by_id.get(job.dest_id)
	if farm == null or farm.field_count() == 0:
		_abandon(c)
		return

	if c.carrying_amount <= 0.0 and c.state != Citizen.State.WORKING:
		# Choose a plot once and stick to it; re-rolling every tick would mean
		# the reaper walks towards a different field each frame and never
		# actually gets anywhere.
		if job.target == Vector3.INF:
			job.target = farm.fields[_rng.randi() % farm.field_count()]
		c.set_goal(job.target)
		c.advance(delta, world)
		if not c.has_arrived():
			return
		c.begin_work(Config.CARRY_CAPACITY * Config.WORK_TICKS_PER_UNIT
				* 0.8 / tools_bonus)
		c.task_label = "reaping"
		c.face_towards(farm.global_position)
		return

	if c.state == Citizen.State.WORKING:
		if not c.work_tick(delta):
			c.update_animation(delta, 0.0)
			return
		var yield_amount: float = Config.CARRY_CAPACITY * lerpf(
				0.6, 1.25, farm.crop_growth)
		c.pick_up(Config.Res.FOOD, yield_amount, registry)
		c.state = Citizen.State.TRAVELLING
		c.task_label = "carrying grain"
		c.set_goal(entrance_of(farm, "att_entrance"))
		# Each load taken cuts part of the standing crop, so a mature field is
		# worth roughly FARM_HARVEST_TRIPS loads before it has to grow again.
		farm.set_crop_growth(maxf(0.0, farm.crop_growth
				- 1.0 / float(Config.FARM_HARVEST_TRIPS)))
		return

	c.advance(delta, world)
	if not c.has_arrived():
		return
	_deposit(c, farm, Config.Res.FOOD)
	jobs.complete(job)
	_go_idle(c)


## Put a carried load into a building, overflowing to the keep if it will not
## fit, so a worker's effort is never silently thrown away.
## Put a carried load into a building, and make sure none of it evaporates.
##
## `into` is where the job meant it to go; when that is full the rest goes to
## any other store that will take it, and whatever still does not fit stays on
## the carrier's back. Deleting the remainder — which is what happens if you
## trust one fallback store to have room — silently destroys a full day's work
## for a settlement that has outgrown its storage, which is exactly the moment
## a player is watching their stocks.
func _deposit(c: Citizen, into: Building, res: int) -> void:
	var amount := c.drop()
	var left: float = amount - into.add(res, amount)
	if left > 0.01:
		left = _spill_into_stores(res, left, c.global_position, into)
	if left > 0.01:
		c.pick_up(res, left, registry)


## Spread `amount` over any store with room, skipping `exclude`. Returns what
## would not fit anywhere.
func _spill_into_stores(res: int, amount: float, from: Vector3,
						exclude: Building = null) -> float:
	var left := amount
	for b in stores.buildings_storing(res):
		if left <= 0.01:
			break
		if b == exclude or b.under_construction:
			continue
		left -= b.add(res, left)
	return maxf(0.0, left)


## Walk a stray load to the nearest store and put it down.
func _carry_stray_load(c: Citizen, delta: float) -> void:
	var res := c.carrying_res
	var dest := stores.find_store(res, c.global_position, -1)
	if dest == null:
		# Nowhere to take it. Stand still holding it rather than dropping it on
		# the grass, so it reappears the moment a store is built.
		c.task_label = "nowhere to put %s" % Res.display(res)
		c.clear_goal()
		c.update_animation(delta, 0.0)
		return
	c.task_label = "returning %s" % Res.display(res)
	c.set_goal(entrance_of(dest, "att_cart_bay"))
	c.advance(delta, world)
	if c.has_arrived():
		_deposit(c, dest, res)
		c.clear_goal()


## Standing at the bench. The smith walks to the worksite, works a spell, and
## a batch of goods appears in the building's own store for hauliers to move.
func _tick_craft(c: Citizen, delta: float) -> void:
	var job := c.job
	var shop: Building = buildings_by_id.get(job.dest_id)
	if shop == null or not shop.can_craft():
		# The *job* has lapsed, not this citizen's attempt at it. Releasing it
		# would put it straight back on the board for the nearest smith to
		# claim and drop again, every tick, while the posting gate counts it
		# and refuses to post anything better.
		_retire_job(c)
		return

	if c.state != Citizen.State.WORKING:
		c.set_goal(entrance_of(shop, "att_worksite"))
		c.advance(delta, world)
		if not c.has_arrived():
			return
		c.begin_work(Config.CRAFT_BATCH * Config.WORK_TICKS_PER_UNIT
				* 1.4 / tools_bonus)
		c.task_label = "working the forge"
		c.face_towards(shop.global_position)
		return

	if not c.work_tick(delta):
		c.update_animation(delta, 0.0)
		return
	shop.craft()
	jobs.complete(job)
	_go_idle(c)


## Clearing ground the player has marked. Unlike gathering this belongs to no
## workplace: any idle pair of hands will do it, and the timber goes to
## whatever store will take it.
func _tick_fell(c: Citizen, delta: float) -> void:
	var job := c.job
	var node := world.nodes.get_node_rec(job.node_id)
	if node == null or (node.depleted and c.carrying_amount <= 0.0):
		_abandon(c)
		return

	if c.carrying_amount <= 0.0 and c.state != Citizen.State.WORKING:
		c.set_goal(node.position)
		c.advance(delta, world)
		if not c.has_arrived():
			return
		c.begin_work(Config.CARRY_CAPACITY * Config.WORK_TICKS_PER_UNIT
				/ tools_bonus)
		c.task_label = "clearing ground"
		c.face_towards(node.position)
		return

	if c.state == Citizen.State.WORKING:
		if not c.work_tick(delta):
			c.update_animation(delta, 0.0)
			return
		var taken := world.nodes.fell(node, Config.CARRY_CAPACITY)
		if taken <= 0.01:
			node.reserved_by = -1
			_abandon(c)
			return
		# The order stands until the tree is gone; anything still in the trunk
		# is another trip, not timber that evaporates.
		if node.depleted or node.falling >= 0.0:
			node.reserved_by = -1
		c.pick_up(Config.Res.TIMBER, taken, registry)
		c.state = Citizen.State.TRAVELLING
		c.task_label = "carrying timber"
		var dest := stores.find_store(Config.Res.TIMBER, c.global_position, -1)
		jobs.set_destination(job, dest.id if dest else -1)
		if dest == null:
			# Nowhere to put it: put the timber back in the tree rather than
			# deleting it, and give up on the order for now.
			world.nodes.restore(node, c.drop())
			jobs.complete(job)
			_go_idle(c)
			return
		c.set_goal(entrance_of(dest, "att_cart_bay"))
		return

	var into: Building = buildings_by_id.get(job.dest_id)
	if into == null:
		_abandon(c)
		return
	c.advance(delta, world)
	if not c.has_arrived():
		return
	_deposit(c, into, Config.Res.TIMBER)
	jobs.complete(job)
	_go_idle(c)


## Mark a tree for felling. Returns false if it is already spoken for.
func order_felling(node) -> bool:
	if node == null or node.depleted or node.reserved_by >= 0:
		return false
	node.reserved_by = FELLING_CLAIM
	world.nodes.set_marked(node, true)
	var job := jobs.post(JobBoard.Kind.FELL, node.position, 62.0)
	job.res = Config.Res.TIMBER
	job.node_id = node.id
	jobs.index(job)
	return true


func _tick_build(c: Citizen, delta: float) -> void:
	var job := c.job
	var site: Building = buildings_by_id.get(job.dest_id)
	if site == null or not site.under_construction:
		# Nothing left to build here — retire the order rather than recycling
		# it, or it outlives the building and idle hands keep claiming it.
		_retire_job(c)
		return

	c.set_goal(entrance_of(site, "att_entrance"))
	c.advance(delta, world)
	if not c.has_arrived():
		return

	c.state = Citizen.State.WORKING
	c.task_label = "building %s" % site.display_name()
	c.update_animation(delta, 0.0)

	if site.advance_construction(delta):
		_on_building_completed(site)
		_go_idle(c)


func _on_building_completed(site: Building) -> void:
	alert.emit("%s finished" % site.display_name(), site.global_position)
	stores.register(site)
	production.forget(site.id)

	for job in jobs.cancel_for_building(site.id):
		# Same release the demolition path does: a job retired without giving
		# back what it had claimed leaves goods reserved at a source that
		# nobody is coming for.
		_release_reservations(job)
		if job.node_id >= 0:
			var node := world.nodes.get_node_rec(job.node_id)
			if node:
				node.reserved_by = -1
			_restore_felling_claim(job)
		var worker: Citizen = citizens_by_id.get(job.claimed_by)
		if worker != null:
			_release_cart(worker)
			_go_idle(worker)

	# A farm upgraded in place already has its field; laying another one out
	# would stack a second set of plots on top of the first.
	if site.def.is_farm() and site.all_plots().is_empty():
		site.create_fields(world.heightmap, world.nav, registry)
	if site.def.is_farm():
		_protect_fields(site, true)
	workforce.mark_all_dirty()


func _idle_behaviour(c: Citizen, delta: float) -> void:
	## Idle people drift home. That is not decoration: the daily walk between
	## home and work is a major contributor to the paths that form through a
	## settlement.
	c.state = Citizen.State.IDLE
	var home: Building = buildings_by_id.get(c.home_id)
	var anchor: Building = home if home != null else keep
	if anchor == null:
		return
	var target := entrance_of(anchor, "att_entrance")
	if c.global_position.distance_to(target) > 5.0:
		c.task_label = "going home"
		c.set_goal(target)
		c.advance(delta, world)
	else:
		c.task_label = "idle"
		c.clear_goal()
		c.update_animation(delta, 0.0)


## Where a citizen should stand to use a building. Falls back sensibly when an
## asset does not declare the attachment. Cached, because this is asked for on
## every tick of every hauling job.
func entrance_of(b: Building, preferred: String) -> Vector3:
	var key := "%d:%s" % [b.id, preferred]
	var hit: Variant = _entrance_cache.get(key)
	if hit != null:
		return hit

	var local := Vector3.ZERO
	if registry.has_attachment(b.asset_id, preferred):
		local = registry.attachment(b.asset_id, preferred)
	elif registry.has_attachment(b.asset_id, "att_entrance"):
		local = registry.attachment(b.asset_id, "att_entrance")
	else:
		local = Vector3(0, 0, -b.footprint.y * 0.5 - 1.5)

	var p: Vector3 = b.global_transform * local
	p.y = world.heightmap.height_at(p.x, p.z)
	_entrance_cache[key] = p
	return p


# ---------------------------------------------------------------------------
# Buildings
# ---------------------------------------------------------------------------

## `forced_id` exists for loading a save, where ids are already spoken for by
## the citizens who work and live in them. Ordinary play leaves it alone and
## takes the next id in sequence.
## `flatten_ground` is false when loading a save. The terrain there is already
## the terrain the march ended with — every pad it has ever had is replayed
## from the edit list before a single building goes down — so flattening again
## would carve a pad that the original session never carved.
## `restoring` is set when a save is being replayed. It suppresses the
## "nothing has to be delivered, so it is already built" shortcut below: an
## upgrade tier carries no `cost` of its own — it is paid for by the previous
## tier's `upgrade_cost` — so a march saved halfway through an upgrade came
## back with the upgrade finished and paid for by nobody.
func place_building(type_id: String, position: Vector3, yaw: float,
					instant: bool = false, variant: String = "",
					forced_id: int = -1,
					flatten_ground: bool = true,
					restoring: bool = false) -> Building:
	var def := BuildingDefs.get_def(type_id)
	if def == null:
		push_error("place_building: unknown type '%s'" % type_id)
		return null

	var b := Building.new()
	var chosen := variant if variant != "" else def.random_asset(_rng)
	b.setup(forced_id if forced_id > 0 else _next_building_id, def, registry,
			chosen)
	_next_building_id = maxi(_next_building_id, b.id) + 1

	b.yaw = yaw
	var plan := b.plan_footprint()
	var half_w: float = plan.x * 0.5
	var half_d: float = plan.y * 0.5
	var ground := (world.heightmap.flatten(position, half_w + 1.5, half_d + 1.5)
			if flatten_ground
			else world.heightmap.height_at(position.x, position.z))
	b.position = Vector3(position.x, ground, position.z)
	b.rotation.y = yaw
	b.ground_y = ground
	b.yaw = yaw

	world.buildings_root.add_child(b)
	buildings.append(b)
	buildings_by_id[b.id] = b

	world.terrain.rebuild_region(position, half_w + 8.0, half_d + 8.0)
	world.nav.block_footprint(b.global_position, half_w * 0.8, half_d * 0.8, true)
	_invalidate_entrances(b)
	# A new building changes what can be walked to, in both directions.
	jobs.clear_refusals()

	if instant or (def.cost.is_empty() and not restoring):
		b.finish_construction()
		stores.register(b)
		if def.is_farm():
			b.create_fields(world.heightmap, world.nav, registry)
			_protect_fields(b, true)

	if def.role == BuildingDefs.Role.SEAT:
		keep = b

	workforce.mark_all_dirty()
	return b


## Take a building off the map, returning whatever has been delivered to it.
##
## Without this, committing your timber to a blueprint you could not finish was
## unrecoverable: the materials were gone, the site could never complete, and
## nothing would give them back.
func can_demolish(b: Building) -> Dictionary:
	if b == null or not is_instance_valid(b):
		return {"ok": false, "reason": "no such building"}
	if b.def.role == BuildingDefs.Role.SEAT:
		# There is no way to build another, and immigration stops without one.
		return {"ok": false, "reason": "your seat cannot be pulled down"}
	return {"ok": true, "reason": ""}


## Whether this building can be grown into its next tier right now.
func can_upgrade(b: Building) -> Dictionary:
	if b == null or not is_instance_valid(b):
		return {"ok": false, "reason": "no such building"}
	if b.under_construction:
		return {"ok": false, "reason": "finish building it first"}
	if not b.def.can_upgrade():
		return {"ok": false, "reason": "nothing to grow into"}
	var next := BuildingDefs.get_def(b.def.upgrades_to)
	if next == null:
		return {"ok": false, "reason": "unknown upgrade"}
	if not can_afford(b.def.upgrade_cost):
		return {"ok": false, "reason": "you cannot afford it"}
	# The next tier is a larger building, and nothing used to measure it: the
	# upgrade flattened a bigger pad and blocked a bigger footprint wherever it
	# stood, so a Granary could grow straight through the stockpile beside it.
	var room := can_place(next.type_id, b.global_position, b.yaw, b.id)
	if not room["ok"]:
		return {"ok": false,
				"reason": "no room to grow — %s" % room["reason"]}
	return {"ok": true, "reason": "", "def": next}


## Start the upgrade: put the building back on the stocks and let the haulers
## supply it, exactly as a new blueprint is supplied. Nothing is deducted up
## front — `can_upgrade` only checks the settlement could afford it, the same
## gate a placement gets.
##
## The staff, the residents, the stock and the fields all stay attached to the
## same building, so this reads as the settlement improving what it has rather
## than losing a granary and gaining a different one. Work stops while it is
## up: an upgrading workshop is a building site, and the workforce pass will
## stand its people down until it reopens.
func upgrade(b: Building) -> Dictionary:
	var check := can_upgrade(b)
	if not check["ok"]:
		return check
	var next: BuildingDefs.Def = check["def"]
	var cost: Dictionary = b.def.upgrade_cost.duplicate()
	var seconds: float = b.def.upgrade_time

	# Whatever the site had going on belongs to the building it used to be.
	for job in jobs.cancel_for_building(b.id):
		_release_reservations(job)
		if job.node_id >= 0:
			var node := world.nodes.get_node_rec(job.node_id)
			if node:
				node.reserved_by = -1
			_restore_felling_claim(job)
		var worker: Citizen = citizens_by_id.get(job.claimed_by)
		if worker != null:
			_release_cart(worker)
			_go_idle(worker)
	production.forget(b.id)
	stores.unregister(b)
	_protect_fields(b, false)

	# Give back the cells the smaller building claimed before the larger one
	# claims its own. Without this the overlap between the two plans is claimed
	# twice and released once, and stays impassable after the building is
	# eventually pulled down.
	var old_plan := b.plan_footprint()
	world.nav.block_footprint(b.global_position, old_plan.x * 0.4,
			old_plan.y * 0.4, false)

	var was := b.def.display_name
	var orphaned := b.begin_upgrade(next, cost, seconds, registry)
	for res in orphaned:
		var left := _spill_into_stores(res, float(orphaned[res]),
				b.global_position, b)
		if left > 0.01:
			alert.emit("%s of %s had nowhere to go"
					% [int(left), Res.display(res)], b.global_position)
	# Back into the index under its new definition, so what it is holding still
	# counts towards the settlement's stock while the work goes on. Lookups
	# skip anything under construction, so nothing will try to draw from it.
	stores.register(b)

	# The larger building needs the larger pad, and the pad is part of the
	# terrain's permanent history exactly as the first one was.
	var plan := b.plan_footprint()
	b.ground_y = world.heightmap.flatten(b.global_position,
			plan.x * 0.5 + 1.5, plan.y * 0.5 + 1.5)
	b.position.y = b.ground_y
	world.terrain.rebuild_region(b.global_position, plan.x * 0.5 + 8.0,
			plan.y * 0.5 + 8.0)
	world.nav.block_footprint(b.global_position, plan.x * 0.4, plan.y * 0.4,
			true)
	_invalidate_entrances(b)
	workforce.mark_all_dirty()
	alert.emit("%s is being made into a %s" % [was, next.display_name],
			b.global_position)
	return {"ok": true, "reason": "", "def": next}


func demolish(b: Building) -> Dictionary:
	var refunded := {}

	# Anything already on site, plus anything the building was storing.
	for res in b.delivered:
		var amount := float(b.delivered[res])
		if amount > 0.01:
			refunded[res] = float(refunded.get(res, 0.0)) + amount
	for res in Config.RES_COUNT:
		if b.inventory[res] > 0.01:
			refunded[res] = float(refunded.get(res, 0.0)) + b.inventory[res]
			b.inventory[res] = 0.0

	# Stand down anyone working on or hauling to it, and release every claim
	# those jobs held — the goods reserved at their source, the capacity
	# promised at their destination, and any resource node they had spoken for.
	for job in jobs.cancel_for_building(b.id):
		_release_reservations(job)
		if job.node_id >= 0:
			var node := world.nodes.get_node_rec(job.node_id)
			if node:
				node.reserved_by = -1
			_restore_felling_claim(job)
		var worker: Citizen = citizens_by_id.get(job.claimed_by)
		if worker != null:
			_release_cart(worker)
			if worker.carrying_amount > 0.0:
				var carried := worker.carrying_res
				refunded[carried] = (float(refunded.get(carried, 0.0))
						+ worker.drop())
			_go_idle(worker)
	for c in citizens:
		if c.job != null and (c.job.dest_id == b.id or c.job.source_id == b.id):
			_abandon(c)

	_protect_fields(b, false)
	for rec in world.nodes.records:
		if rec.reserved_by == b.id:
			rec.reserved_by = -1

	workforce.release_workers(b, citizens_by_id)
	workforce.release_residents(b, citizens_by_id)
	stores.unregister(b)
	production.forget(b.id)

	var plan := b.plan_footprint()
	world.nav.block_footprint(b.global_position, plan.x * 0.4, plan.y * 0.4,
			false)
	_invalidate_entrances(b)

	jobs.clear_refusals()
	buildings.erase(b)
	buildings_by_id.erase(b.id)
	if keep == b:
		keep = null
	b.queue_free()

	# Put the goods somewhere real, or they have simply been deleted.
	var lost := {}
	for res in refunded:
		var remaining := float(refunded[res])
		while remaining > 0.5:
			var dest := stores.find_store(res, b.global_position, -1)
			if dest == null:
				break
			var placed := dest.add(res, remaining)
			if placed <= 0.01:
				break
			remaining -= placed
		if remaining > 0.5:
			lost[res] = remaining
		refunded[res] = float(refunded[res]) - remaining

	workforce.mark_all_dirty()
	# `refunded` is now what actually reached a store; `lost` is what had
	# nowhere to go. Telling the player everything came back when the stores
	# were full was simply untrue.
	return {"refunded": refunded, "lost": lost}


## Keep traffic off a farm's crops, and release the ground when it goes.
## Crops refuse to record a track, and cost more to cross than open grass.
##
## Protection follows the *worked* plots rather than every plot the farm could
## reach, so a half-staffed farm leaves its fallow ground walkable — and has to
## be re-applied whenever staffing changes, which is why every caller sits next
## to a field layout or a sync.
func _protect_fields(b: Building, value: bool = true,
					 clear_existing: bool = true) -> void:
	for p in b.all_plots():
		world.wear.set_protected(p, Config.CELL * 0.5, false)
		var fallow := Config.world_to_cell(p)
		world.nav.set_cultivated(fallow.x, fallow.y, false)
	if not value:
		return
	for p in b.fields:
		world.wear.set_protected(p, Config.CELL * 0.5, true, clear_existing)
		var worked := Config.world_to_cell(p)
		world.nav.set_cultivated(worked.x, worked.y, true)


func _invalidate_entrances(b: Building) -> void:
	for key in _entrance_cache.keys():
		if String(key).begins_with("%d:" % b.id):
			_entrance_cache.erase(key)


## Returns {ok, reason, slope, footprint}. The UI shows the reason, which is
## what makes placement feel informative rather than arbitrary.
## `ignore_id` skips one building in the overlap test, so a building can be
## measured against its neighbours without colliding with itself — which is
## what an upgrade needs, since it grows on ground it already stands on.
func can_place(type_id: String, position: Vector3,
			   yaw: float = 0.0, ignore_id: int = -1) -> Dictionary:
	var def := BuildingDefs.get_def(type_id)
	if def == null:
		return {"ok": false, "reason": "unknown building"}

	var raw: Vector2 = registry.footprint(def.asset)
	# Test the ground the building will actually stand on once turned.
	var c: float = absf(cos(yaw))
	var sn: float = absf(sin(yaw))
	var fp := Vector2(raw.x * c + raw.y * sn, raw.x * sn + raw.y * c)
	var half_w: float = fp.x * 0.5 + 0.5
	var half_d: float = fp.y * 0.5 + 0.5

	if position.x - half_w < 2.0 or position.z - half_d < 2.0 \
			or position.x + half_w > Config.WORLD_SIZE - 2.0 \
			or position.z + half_d > Config.WORLD_SIZE - 2.0:
		return {"ok": false, "reason": "outside the march", "footprint": fp}

	var c0 := Config.world_to_cell(position - Vector3(half_w, 0, half_d))
	var c1 := Config.world_to_cell(position + Vector3(half_w, 0, half_d))
	var worst_slope := 0.0
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if world.heightmap.cell_surface(cx, cz) == Heightmap.Surface.WATER:
				return {"ok": false, "reason": "water", "footprint": fp}
			worst_slope = maxf(worst_slope, world.heightmap.cell_slope(cx, cz))

	if worst_slope > Config.MAX_BUILD_SLOPE:
		return {"ok": false, "reason": "ground too steep",
				"slope": worst_slope, "footprint": fp}

	# Real footprint overlap, not a distance heuristic. The old rule accepted
	# two 8x8 yards whose centres were 7.5 m apart, so their footprints
	# intersected by half a metre and the buildings visibly interpenetrated.
	var here := Rect2(position.x - fp.x * 0.5 - CLEARANCE,
			position.z - fp.y * 0.5 - CLEARANCE,
			fp.x + CLEARANCE * 2.0, fp.y + CLEARANCE * 2.0)
	for other in buildings:
		if other.id == ignore_id:
			continue
		var of: Vector2 = other.plan_footprint()
		var there := Rect2(other.global_position.x - of.x * 0.5,
				other.global_position.z - of.y * 0.5, of.x, of.y)
		if here.intersects(there):
			return {"ok": false,
					"reason": "overlaps %s" % other.display_name(),
					"footprint": fp}

	# Resource buildings need something to work on.
	if def.is_gatherer():
		if world.nodes.find_nearest(def.harvest_kind, position,
				def.work_radius, false) == null:
			var what := "trees" if def.harvest_kind == ResourceNodes.Kind.TREE \
					else "stone"
			return {"ok": false, "reason": "no %s in range" % what,
					"footprint": fp}

	return {"ok": true, "reason": "", "slope": worst_slope, "footprint": fp}


# --- Economy façade ---------------------------------------------------------

func total_resource(res: int) -> float:
	return stores.total(res)


func can_afford(cost: Dictionary) -> bool:
	return stores.can_afford(cost)


func spend(cost: Dictionary) -> void:
	stores.spend(cost)


func food_days_remaining() -> float:
	return population.food_days_remaining(citizens)


func housing_capacity() -> int:
	return population.housing_capacity(buildings)


# ---------------------------------------------------------------------------
# Population
# ---------------------------------------------------------------------------

func add_citizen(position: Vector3, as_immigrant: bool = false,
				 forced_asset: String = "", forced_id: int = -1) -> Citizen:
	var c := Citizen.new()
	c.setup(forced_id if forced_id > 0 else _next_citizen_id, registry, _rng,
			forced_asset)
	_next_citizen_id = maxi(_next_citizen_id, c.id) + 1
	c.position = Vector3(position.x,
			world.heightmap.height_at(position.x, position.z), position.z)
	world.citizens_root.add_child(c)
	citizens.append(c)
	citizens_by_id[c.id] = c

	if as_immigrant:
		c.immigrant = true
		c.task_label = "travelling to your lands"
		c.immigrant_target = keep.global_position if keep else position
		c.set_goal(c.immigrant_target)
	else:
		workforce.mark_all_dirty()
	return c


# ---------------------------------------------------------------------------
# Persistence support
# ---------------------------------------------------------------------------

func next_building_id() -> int:
	return _next_building_id


func next_citizen_id() -> int:
	return _next_citizen_id


## Put the calendar where a save left it.
##
## `_day_marker` has to move with it. The daily update charges for the interval
## since the marker, so restoring day 30 while the marker sat at zero billed
## the settlement for thirty days of eating and thirty days of road decay on
## the first midnight after loading — enough to empty the stores and erase the
## roads the save existed to preserve.
func set_day(value: float) -> void:
	day = value
	_day_marker = value


## How far through the current day the settlement has already been charged
## for. Saved, because a load that forgets it forgets that accounting.
func day_marker() -> float:
	return _day_marker


func set_day_marker(value: float) -> void:
	_day_marker = value


func set_next_ids(building_id: int, citizen_id: int) -> void:
	_next_building_id = maxi(_next_building_id, building_id)
	_next_citizen_id = maxi(_next_citizen_id, citizen_id)


## Re-derive everything a load deliberately did not write: the entrance cache,
## which ground counts as cultivated, staffing, and the running totals. Called
## once, after every building and citizen from the save is in place.
func finish_restore() -> void:
	_entrance_cache.clear()

	# A tree the player ordered cleared carries the order in its reservation,
	# which a save does not write (reservations are rebuilt, not restored). The
	# marker survives, so the claim is put back from it — otherwise the world
	# shows standing orders that nothing will ever carry out.
	for id in world.nodes.marked_ids():
		var rec := world.nodes.get_node_rec(id)
		if rec != null and not rec.depleted:
			rec.reserved_by = FELLING_CLAIM

	# Staffing first: how much of a farm is under crop depends on it, and both
	# the crop and the ground it protects follow from that.
	workforce.mark_all_dirty()
	workforce.update(buildings, citizens, buildings_by_id)
	for b in buildings:
		if b.under_construction:
			continue
		if b.def.is_farm():
			b.sync_fields_to_workers()
			# Protect, but do not wipe: see set_protected. The wear under these
			# plots came out of the save and is exactly what must survive.
			_protect_fields(b, true, false)

	# Last, because every building placed above flattened the ground beneath
	# it, and a cell's travel weight is part slope.
	world.nav.rebuild_all()
	stores.refresh_totals(citizens)
	_update_stats()


func _tick_immigrant(c: Citizen, delta: float) -> void:
	c.advance(delta, world)
	if c.global_position.distance_to(c.immigrant_target) < 12.0:
		c.immigrant = false
		c.task_label = "idle"
		c.clear_goal()
		workforce.mark_all_dirty()


func _update_stats() -> void:
	stat_population = citizens.size()
	stat_homeless = 0
	stat_idle = 0
	for c in citizens:
		if c.immigrant:
			continue
		if c.home_id < 0:
			stat_homeless += 1
		if c.job == null:
			stat_idle += 1
	stat_jobs_open = jobs.open_jobs()
	stats_changed.emit()
