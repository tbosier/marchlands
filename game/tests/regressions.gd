extends SceneTree

## Run with tools/godot_env.sh --headless --path game --script res://tests/regressions.gd
## Exercise transitions which broad, end-of-day scenario assertions miss.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", description])
	if not ok:
		_failures += 1


func _claim_gather(sim: Simulation, c: Citizen,
		node: ResourceNodes.NodeRec, kind: int = JobBoard.Kind.GATHER) -> JobBoard.Job:
	var job := sim.jobs.post(kind, node.position, 100.0)
	job.res = Config.Res.TIMBER
	job.dest_id = sim.keep.id
	job.node_id = node.id
	sim.jobs.index(job)
	node.reserved_by = sim.keep.id
	c.workplace_id = sim.keep.id
	sim._seek_job(c)
	_check(c.job == job, "worker claims the test order")
	return job


const FIRE_STEP := 0.25
## What one carrier tips over a fire: WaterSystem.BUCKET * 0.25.
const BUCKET_EFFECT := 1.0
## What a soldier's firepot leaves behind, from FrontierCampaign's impact.
const FIREPOT := 0.55
## Centre spacing for houses packed as tightly as can_place will allow: a
## hovel's 6.2 m depth plus the 1 m of clear ground CLEARANCE leaves.
const TIGHT_ROW := 7.2


## Advance only what fire does — the spread scan on its real cadence, then the
## burn — and report what it destroyed.
##
## FrontierCampaign.tick also marches soldiers and works the rival town, which
## would bury a fire measurement under unrelated motion. This is that tick's
## fire half, in its order, including the demolition of what burns down.
func _burn(sim: Simulation, seconds: float, lost: Array = []) -> Array:
	var campaign: FrontierCampaign = sim.campaign
	for step in int(round(seconds / FIRE_STEP)):
		var was: float = campaign._time
		campaign._time += FIRE_STEP
		campaign._spread_fire(was)
		for b: Building in campaign.enemy_buildings.values().duplicate():
			if b.tick_fire(FIRE_STEP):
				lost.append(b.id)
				campaign._destroy_enemy(b)
		for b in sim.buildings.duplicate():
			if b.tick_fire(FIRE_STEP):
				lost.append(b.id)
				sim.demolish(b, false)
	return lost


func _raise(sim: Simulation, at: Vector3, type_id := "house",
		variant := "house_hovel", instant := true) -> Building:
	return sim.place_building(type_id, at, 0.0, instant, variant)


func _clear(sim: Simulation, raised: Array) -> void:
	for b in raised:
		if is_instance_valid(b) and sim.buildings.has(b):
			sim.demolish(b, false)


## How many buildings are alight anywhere in the settlement.
func _lit(sim: Simulation) -> int:
	var count := 0
	for b in sim.buildings:
		if b.fire > 0.0:
			count += 1
	return count


## Total fire burning anywhere in the settlement.
func _alight(sim: Simulation) -> float:
	var total := 0.0
	for b in sim.buildings:
		total += b.fire
	return total


## Every building's exact state on both sides of the frontier, for comparing two
## runs digit for digit.
func _fire_state(sim: Simulation) -> String:
	var rows: Array[String] = []
	for b in sim.buildings:
		rows.append("%d=%.17f/%.17f" % [b.id, b.fire, b.health])
	for b: Building in sim.campaign.enemy_buildings.values():
		rows.append("%d=%.17f/%.17f" % [b.id, b.fire, b.health])
	rows.sort()
	return "|".join(rows)


## Tip a full bucket over each of the `carriers` worst fires, which is what
## WaterSystem._fire_tick does on arrival. The settlement dispatches two of its
## own accord; request_firefighting refuses a second carrier per burning
## building and nothing else, so a player answering by hand can field one per
## fire — up to the number of fires, not the number of residents.
##
## THIS IS AN OPTIMISTIC UPPER BOUND, NOT THE WATER SYSTEM. Read every claim
## measured through it as "no worse than this", never as "this is what happens".
## A real carrier is strictly weaker in three ways, and every one of them is a
## way the real settlement loses buildings this model saves:
##
##  - It re-targets for free. A real carrier holds one `job.target_id` for the
##    life of the job and cannot be moved to the fire that has since become the
##    worst one; this picks the two worst afresh on every trip.
##  - It never runs short. A real bucket is `minf(BUCKET, well water)`: a full
##    80-unit shaft is twenty of them, and past that one more every fifty-one
##    seconds, which is all REFILL_PER_DAY puts back. This tips BUCKET_EFFECT
##    whatever the wells hold, including nothing.
##  - It is never interrupted. A real carrier is handed back at HUNGER_URGENT,
##    loses its leg to a drinking errand, and draws on a well a purge has only
##    just released — a trickle, not a bucket.
##
## Nor is the forty-second round trip measured: it is a stated assumption about
## how far apart the well and the fire are. Making the model faithful means
## running the real WaterSystem against the real navigation, which would move
## every number the exposure cap was tuned against — a retune, not a comment.
## Stated instead, in both places, which is the honest form of the claim.
func _buckets(sim: Simulation, carriers: int) -> void:
	var worst := sim.buildings.duplicate()
	worst.sort_custom(func(a: Building, b: Building): return a.fire > b.fire)
	for i in mini(carriers, worst.size()):
		if worst[i].fire > 0.0:
			worst[i].fire = maxf(0.0, worst[i].fire - BUCKET_EFFECT)


## Spread alone, with no burn and a source held at a fixed intensity, stepped in
## `step`-second slices. Returns what the target took on.
func _spread_only(campaign: FrontierCampaign, source: Building, target: Building,
		step: float, steps: int) -> float:
	campaign._time = 0.0
	target.fire = 0.0
	for i in steps:
		source.fire = 0.5
		var was: float = campaign._time
		campaign._time += step
		campaign._spread_fire(was)
	source.fire = 0.0
	return target.fire


## A row of houses packed as tightly as Simulation.can_place will allow, the
## first of them hit by a firepot. Returns the row.
## Ignited with the firepot's incendiary but none of its impact damage, so what
## follows measures the fire rather than the throw.
func _packed_row(sim: Simulation, base: Vector3, houses: int) -> Array[Building]:
	var row: Array[Building] = []
	for i in houses:
		row.append(_raise(sim, base + Vector3(0, 0, TIGHT_ROW * float(i))))
	row[0].apply_damage(0.0, FIREPOT)
	return row


## Fire spreads between buildings that stand close together.
##
## A hovel is 5.6 x 6.2 m. can_place pads only the building being placed, by
## Simulation.CLEARANCE, so houses may stand 1 m apart along Z — centres 7.2 m
## apart — and that is the worst case every claim below is made against.
func _fire_spread(game: Node) -> void:
	var sim: Simulation = game.sim
	var campaign: FrontierCampaign = sim.campaign
	var base: Vector3 = game.world.centre() + Vector3(0, 0, 170)
	var alerts: Array = []
	sim.alert.connect(func(text: String, _at: Vector3): alerts.append(text))

	# The house next door catches and takes real damage for it. One 11 m clear
	# of the blaze — past the reach entirely — is never touched.
	var source := _raise(sim, base)
	var close := _raise(sim, base + Vector3(0, 0, TIGHT_ROW))
	# 11 m clear of the neighbour that is about to catch, and 18.2 m clear of
	# the fire itself. Spelled out in metres rather than derived from
	# FIRE_SPREAD_REACH, so widening the reach fails this instead of moving it.
	var apart := _raise(sim, base + Vector3(0, 0, 24.4))
	source.apply_damage(0.0, FIREPOT)
	_burn(sim, 40.0)
	_check(close.fire > 0.25 and close.health < close.max_health(),
			"a house built a metre from a burning one catches and burns with it")
	_check(apart.fire == 0.0 and apart.health == apart.max_health(),
			"a house beyond the blaze's reach is untouched")
	_check(alerts.count("Hovel has caught fire") == 1,
			"the house that caught is reported to the player exactly once")
	_clear(sim, [source, close, apart])

	# Where the reach ends, to the half metre. One scan and no burn, so this
	# measures the reach itself rather than what a fire can go on to sustain.
	source = _raise(sim, base)
	var inside := _raise(sim, base + Vector3(0, 0, 15.7))     # 9.5 m of clear ground
	var outside := _raise(sim, base - Vector3(0, 0, 16.7))    # 10.5 m of clear ground
	source.apply_damage(0.0, 1.0)
	campaign._spread_fire_scan(10.0)
	_check(inside.fire > 0.0 and outside.fire == 0.0,
			"the reach cuts off between nine and a half and ten and a half metres")
	_clear(sim, [source, inside, outside])

	# The scan cadence comes off the campaign clock, and that clock cannot be
	# recovered by subtracting a frame's delta back off it: at a thirtieth of a
	# second the subtraction lands on the far side of a half-second boundary and
	# the scan it stood for never runs. Thirty seconds is thirty seconds.
	source = _raise(sim, base)
	close = _raise(sim, base + Vector3(0, 0, TIGHT_ROW))
	var coarse := _spread_only(campaign, source, close, 0.5, 60)
	var fine := _spread_only(campaign, source, close, 1.0 / 30.0, 900)
	_check(coarse > 0.0 and is_equal_approx(coarse, fine),
			"half a minute of spread is the same stepped at 0.5 s or at a thirtieth")
	_clear(sim, [source, close])

	# Proximity is footprint to footprint. A grain warehouse is 16 m deep and a
	# hovel 6.2 m, so at the same 16.4 m centre distance the warehouse stands
	# 5.3 m clear of the fire and the hovel 10.2 m: near enough to take hold in
	# the first case, not in the second.
	source = _raise(sim, base)
	var deep := _raise(sim, base + Vector3(0, 0, 16.4), "grain_warehouse", "granary_large")
	var slight := _raise(sim, base - Vector3(0, 0, 16.4))
	source.apply_damage(0.0, 1.0)
	_burn(sim, 60.0)
	_check(deep.fire > 0.1 and slight.fire == 0.0,
			"the gap is measured between footprints: a deep warehouse takes hold"
			+ " where a cottage at the same centre distance never lights")
	_clear(sim, [source, deep, slight])

	# Nothing standing is exempt. A blueprint nobody has delivered to is a
	# timber frame waiting to happen, and an upgrading building reports itself
	# as an undelivered site while being a finished, stocked, occupied one.
	source = _raise(sim, base)
	var site := _raise(sim, base + Vector3(0, 0, TIGHT_ROW), "house", "house_hovel", false)
	var upgrading := _raise(sim, base - Vector3(0, 0, 13.9), "granary", "granary")
	upgrading.begin_upgrade(BuildingDefs.get_def("grain_warehouse"),
			{Config.Res.TIMBER: 20}, 10.0, game.registry)
	source.apply_damage(0.0, FIREPOT)
	_burn(sim, 40.0)
	_check(site.fire > 0.0, "an undelivered building site catches like anything else")
	_check(upgrading.fire > 0.0, "beginning an upgrade does not make a building fireproof")
	_clear(sim, [source, site, upgrading])

	# Ignored, a packed row is lost outright — and it is the row that is lost.
	var row := _packed_row(sim, base, 4)
	var ids: Array = []
	for b in row:
		ids.append(b.id)
	var lost: Array = []
	_burn(sim, 400.0, lost)
	lost.sort()
	ids.sort()
	_check(lost == ids, "a packed row of four houses left burning is lost entirely")

	# Answered by two idealised carriers -- `_buckets`, an upper bound on the two
	# the settlement dispatches by itself, not a model of them -- on the
	# forty-second round trip a well fifty metres off implies at WALK_SPEED, the
	# same row is hurt but not lost. The real water system is weaker than this on
	# every axis, so read the result as the best the row can hope for.
	row = _packed_row(sim, base, 4)
	lost = []
	var spreading := 0
	for trip in 10:
		_burn(sim, 40.0, lost)
		spreading = maxi(spreading, _lit(sim))
		_buckets(sim, 2)
	_check(spreading > 1, "the answered row was alight in more than one place at once")
	_check(not lost.is_empty() and lost.size() < row.size() and is_zero_approx(_alight(sim)),
			"two idealised carriers hold a packed row to partial loss at best")
	_clear(sim, row)

	# Answered properly — an idealised carrier on each fire, which
	# request_firefighting allows the player to field for real — and nothing is
	# lost at all. Again an upper bound: see `_buckets`.
	row = _packed_row(sim, base, 4)
	lost = []
	for trip in 10:
		_burn(sim, 40.0, lost)
		_buckets(sim, row.size())
	_check(lost.is_empty() and is_zero_approx(_alight(sim)),
			"a carrier sent to every fire can save the whole packed row")
	_clear(sim, row)

	# The rival's town burns on the same terms; a blaze does not ask whose roof
	# it is under. Ashcombe's own fires are its business, not an alert of ours.
	var anchor: Vector3 = campaign.enemy_buildings.values()[0].position
	var rival_a := campaign._create_building("house", anchor + Vector3(70, 0, 0))
	var rival_b := campaign._create_building("house", anchor + Vector3(70, 0, TIGHT_ROW))
	rival_a.apply_damage(0.0, FIREPOT)
	var before := alerts.size()
	_burn(sim, 20.0)
	_check(rival_b.fire > 0.0, "fire spreads between the rival's buildings too")
	_check(alerts.size() == before, "the rival's own fires are not reported to the player")
	rival_a.fire = 0.0
	rival_b.fire = 0.0

	# A fire saved mid-spread carries on exactly as it would have. Saved part
	# way through a scan interval on purpose: a cadence kept in an accumulator
	# the save does not carry would resume on different boundaries.
	row = _packed_row(sim, base, 3)
	_burn(sim, 20.25)
	_check(_lit(sim) > 1, "the saved fire had already spread")
	_check(game.save_game("regression_fire") == "", "a spreading fire saves")
	_burn(sim, 45.0)
	var uninterrupted := _fire_state(sim)
	_check(game.load_game("regression_fire") == "", "a spreading fire loads")
	sim = game.sim
	_burn(sim, 45.0)
	_check(_fire_state(sim) == uninterrupted,
			"a reloaded fire develops exactly as the uninterrupted one did")
	DirAccess.remove_absolute(SaveGame.slot_path("regression_fire"))


func _run() -> void:
	var game: Node = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var sim: Simulation = game.sim
	var c := sim.citizens[0]
	var original_home := c.home_id
	var original_workplace := c.workplace_id
	c.next_meal = 100.0
	# A hovel, because only houses are homes: the keep sleeps nobody.
	var home: Building = sim.buildings.filter(func(b): return b.type_id == "house")[0]
	c.home_id = home.id
	var door := sim.entrance_of(home, "att_entrance")
	var tree: ResourceNodes.NodeRec = game.world.nodes.find_nearest(
			ResourceNodes.Kind.TREE, door, 200.0)
	_check(tree != null, "a tree exists away from the worker's home")
	if tree == null:
		game.free()
		quit(1)
		return

	# Sleep keeps the job but replaces and eventually clears its outbound route.
	c.global_position = door
	var job := _claim_gather(sim, c, tree)
	sim._tick_sleep(c, 0.1)
	_check(c.indoors and c.job == job, "sleep retains the gathering order")
	sim._tick_citizen(c, 0.1)
	_check(c.has_goal() and c.state != Citizen.State.WORKING,
			"waking gatherer travels back to the tree before working")
	var amount := tree.amount
	for i in 150:
		sim._tick_citizen(c, 0.1)
	_check(is_equal_approx(tree.amount, amount) and c.carrying_amount == 0.0,
			"no timber is gathered remotely from the doorstep")
	sim._retire_job(c)
	c.drop()

	# A resource can disappear after an order is posted (e.g. ground cleared
	# for a building). That order must stop occupying the site's job quota.
	for kind in [JobBoard.Kind.GATHER, JobBoard.Kind.FELL]:
		tree = game.world.nodes.find_nearest(ResourceNodes.Kind.TREE, door, 200.0)
		job = _claim_gather(sim, c, tree, kind)
		game.world.nodes.harvest(tree, tree.amount, sim.day)
		sim._tick_citizen(c, 0.1)
		_check(job.cancelled and sim.jobs.total_jobs() == 0,
				"depleted resource retires %s order" % JobBoard.Kind.keys()[kind])
		_check(tree.reserved_by == -1, "expired order releases its resource claim")
		# Isolate the next case even when this one fails.
		sim.jobs.clear()
		tree.reserved_by = -1

	# Loading a paused march must restore that march's resume speed, even when
	# the player has changed speed in the session being replaced.
	c.home_id = original_home
	c.workplace_id = original_workplace
	game.clock.set_rate(4.0)
	game.clock.toggle_pause()
	_check(game.save_game("regression_paused") == "", "paused march saves")
	game.clock.set_rate(0.5)
	game.clock.toggle_pause()
	_check(game.load_game("regression_paused") == "", "paused march loads")
	_check(game.clock.paused(), "loaded march remains paused")
	game.clock.toggle_pause()
	_check(is_equal_approx(game.clock.scale(), 4.0), "unpause restores the saved 4x speed")
	DirAccess.remove_absolute(SaveGame.slot_path("regression_paused"))
	game.clock.set_rate(2.0)
	game.clock.set_speed(0)
	game.clock.toggle_pause()
	_check(is_equal_approx(game.clock.scale(), 2.0), "direct pause remembers the current speed")
	game.clock.restore_speed(0)
	game.clock.toggle_pause()
	_check(game.clock.speed_index == Config.NORMAL_SPEED,
			"older paused saves use normal speed instead of the replaced session's speed")

	_fire_spread(game)

	game.free()
	print("Regression failures: %d" % _failures)
	quit(1 if _failures else 0)
