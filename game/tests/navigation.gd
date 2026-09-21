extends SceneTree

## tools/godot_env.sh --headless --path game --script res://tests/navigation.gd
## Controlled flat terrain isolates access failures from seed-dependent hills.

var _failures := 0
var _world: World
var _sim: Simulation
var _registry := AssetRegistry.new()


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", description])
	if not ok:
		_failures += 1


func _flat_world() -> void:
	_world = World.new()
	root.add_child(_world)
	var hm := _world.heightmap
	hm.heights.resize(Heightmap.N * Heightmap.N)
	hm.heights.fill(9.0)
	hm.surface.resize(Config.GRID * Config.GRID)
	hm.surface.fill(Heightmap.Surface.GRASS)
	hm.fertility.resize(Config.GRID * Config.GRID)
	hm.fertility.fill(0.5)
	_world.nav.setup(hm, _world.wear)
	_world.nodes = ResourceNodes.new()
	_world.add_child(_world.nodes)
	_world.terrain = Terrain.new()
	_world.add_child(_world.terrain)
	_world.terrain.build(hm, _world.wear)
	_world.buildings_root = Node3D.new()
	_world.add_child(_world.buildings_root)
	_world.citizens_root = Node3D.new()
	_world.add_child(_world.citizens_root)
	_world.effects_root = Node3D.new()
	_world.add_child(_world.effects_root)
	_sim = Simulation.new()
	root.add_child(_sim)
	_sim.setup(_world, _registry, 71)


func _ring(centre: Vector3, radius: int, blocked: bool) -> void:
	var c := Config.world_to_cell(centre)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if absi(dx) == radius or absi(dz) == radius:
				_world.nav.set_blocked(c.x + dx, c.y + dz, blocked)


func _free_position(position: Vector3) -> bool:
	var cell := Config.world_to_cell(position)
	return not _world.nav.is_solid(cell.x, cell.y)


func _walk(c: Citizen, limit: int = 600) -> bool:
	for i in limit:
		c.advance(0.1, _world)
		if not _free_position(c.position):
			return false
		if c.has_arrived():
			return true
	return false


func _path_edges() -> void:
	var nav := _world.nav
	_check(nav._clear_line(Vector2(6, 6), Vector2(4, 8))
			and nav._clear_line(Vector2(4, 8), Vector2(6, 6)),
			"segments ending exactly on a grid boundary are clear in both directions")
	var target := Config.cell_to_world(Vector2i(30, 25))
	nav.set_blocked(30, 25, true)
	var c := _sim.add_citizen(Config.cell_to_world(Vector2i(25, 25)))
	var path := nav.find_path(c.position, target)
	_check(not path.is_empty() and _free_position(path[path.size() - 1]),
			"a blocked destination ends at a walkable access point")
	c.set_goal(target)
	_check(_walk(c), "citizen reaches the resolved goal without entering the obstacle")
	nav.set_blocked(30, 25, false)

	# No free cell exists within the navigator's endpoint search radius. Even
	# start == destination must not invent a path inside this solid region.
	var buried := Config.cell_to_world(Vector2i(60, 60))
	for z in range(47, 74):
		for x in range(47, 74):
			nav.set_blocked(x, z, true)
	_check(nav.find_path(buried, buried).is_empty(),
			"fully blocked same-cell endpoints are unreachable")
	c.position = buried
	c.clear_goal()
	c.set_goal(buried)
	c.advance(0.1, _world)
	_check(c.unreachable and not c.has_arrived(),
			"an unreachable goal cannot report arrival")
	for z in range(47, 74):
		for x in range(47, 74):
			nav.set_blocked(x, z, false)

	var island := Config.cell_to_world(Vector2i(80, 80))
	var outside := island + Vector3(24, 0, 0)
	_ring(island, 3, true)
	_check(nav.find_path(outside, island).is_empty(),
			"a free destination behind a closed barrier is unreachable")
	_check(not nav.can_reach(outside, island), "store reachability agrees with pathfinding")
	nav.set_blocked(83, 80, false)
	_check(nav.can_reach(outside, island), "opening a passage invalidates cached disconnection")
	nav.set_blocked(83, 80, true)
	_check(not nav.can_reach(outside, island), "closing a passage invalidates cached connection")
	_ring(island, 3, false)
	var before_revision := nav.revision
	nav.apply_road_changes([Vector2i(80, 80)])
	nav.set_cultivated(80, 80, true)
	_check(nav.revision == before_revision,
			"road and crop weights retain the cached connectivity graph")
	nav.set_cultivated(80, 80, false)
	# A sub-metre clip of a blocked corner used to fall between the two-metre
	# samples and become an illegal shortcut through a closed enclosure.
	nav.set_blocked(90, 90, true)
	_check(not nav._clear_line(Vector2(359.9, 360.1), Vector2(364.1, 359.9)),
			"short clips across obstacle corners cannot be smoothed away")
	nav.set_blocked(90, 90, false)


func _building_changes() -> void:
	var c := _sim.add_citizen(Vector3(402, 9, 402))
	var target := Vector3(442, 9, 402)
	c.set_goal(target)
	c.advance(0.1, _world)
	var site := _sim.place_building("house", Vector3(422, 9, 402), 0.0)
	_check(_walk(c), "construction invalidates a cached route before it crosses the new footprint")
	var centre := Config.world_to_cell(site.position)
	_check(_world.nav.is_solid(centre.x, centre.y), "construction site blocks its footprint")
	_sim.demolish(site)
	_check(not _world.nav.is_solid(centre.x, centre.y), "demolition reopens the footprint")
	c.position = Vector3(402, 9, 402)
	c.clear_goal()
	c.set_goal(target)
	_check(_walk(c), "citizens can use the reopened route after demolition")

	# Overlapping grid claims belong to both buildings, even when one is gone.
	var overlap := Vector3(502, 9, 502)
	_world.nav.block_footprint(overlap, 3, 3, true)
	_world.nav.block_footprint(overlap, 3, 3, true)
	_world.nav.block_footprint(overlap, 3, 3, false)
	_check(not _free_position(overlap), "releasing one overlapping footprint keeps its neighbour blocked")
	_world.nav.block_footprint(overlap, 3, 3, false)
	_check(_free_position(overlap), "the final footprint release makes the cell walkable")


func _food_and_stores() -> void:
	var keep := _sim.place_building("keep", Vector3(200, 9, 200), 0.0, true)
	var nearby := _sim.place_building("granary", Vector3(244, 9, 200), 0.0, true)
	var alternate := _sim.place_building("granary", Vector3(220, 9, 244), 0.0, true)
	nearby.inventory[Config.Res.FOOD] = 30.0
	alternate.inventory[Config.Res.FOOD] = 30.0
	var c := _sim.add_citizen(Vector3(270, 9, 200))
	c.home_id = -1

	var door := _sim.entrance_of(nearby, "att_cart_bay")
	var cell := Config.world_to_cell(door)
	_check(_free_position(door), "building access is outside its own solid footprint")
	_world.nav.set_blocked(cell.x, cell.y, true)
	var replacement := _sim.entrance_of(nearby, "att_cart_bay")
	_check(replacement != door and _free_position(replacement),
			"a blocked cached entrance resolves to a new walkable access point")
	_world.nav.set_blocked(cell.x, cell.y, false)
	_check(_sim.entrance_of(nearby, "att_cart_bay") == door,
			"reopening the doorway restores the original access point")

	_ring(nearby.position, 4, true)
	_check(_sim._nearest_food(c.position) == alternate,
			"food search skips an inaccessible nearer granary")
	_check(_sim.stores.find_source(Config.Res.FOOD, c.position, 4.0) == alternate,
			"haul source selection skips an inaccessible stocked store")
	_check(_sim.stores.find_store(Config.Res.FOOD, c.position, -1) == alternate,
			"stray-load selection skips an inaccessible preferred store")
	c.state = Citizen.State.EATING
	c.next_meal = 0.0
	for i in 800:
		_sim._tick_meal(c, 0.1)
		if c.meals_taken > 0:
			break
	_check(c.meals_taken == 1 and nearby.inventory[Config.Res.FOOD] == 30.0,
			"a hungry citizen walks to reachable food instead of stalling at the nearer store")
	if c.meals_taken != 1 or nearby.inventory[Config.Res.FOOD] != 30.0:
		print("  position=%s goal=%s path=%s arrived=%s meals=%d nearby=%s"
				% [c.position, c._goal, c._path, c.has_arrived(), c.meals_taken,
				nearby.inventory[Config.Res.FOOD]])

	var home := _sim.place_building("house", Vector3(300, 9, 300), 0.0, true)
	home.larder = 5.0
	c.home_id = home.id
	_ring(home.position, 4, true)
	c.next_meal = 0.0
	c.state = Citizen.State.EATING
	var meals := c.meals_taken
	for i in 800:
		_sim._tick_meal(c, 0.1)
		if c.meals_taken > meals:
			break
	_check(c.meals_taken == meals + 1 and home.larder == 5.0,
			"an unreachable home falls back to eating at an accessible store")

	# A home can become cut off after someone already collected its food.
	c.pick_up(Config.Res.FOOD, 8.0, _registry)
	c.state = Citizen.State.EATING
	var stock := alternate.inventory[Config.Res.FOOD]
	_sim._tick_meal(c, 0.1)
	for i in 800:
		if c.carrying_amount <= 0.01:
			break
		_sim._carry_stray_load(c, 0.1)
	_check(c.carrying_amount == 0.0 and alternate.inventory[Config.Res.FOOD] == stock + 8.0,
			"food collected for a blocked home returns to reachable storage intact")
	if c.carrying_amount != 0.0 or alternate.inventory[Config.Res.FOOD] != stock + 8.0:
		print("  position=%s goal=%s carry=%s stock=%s was=%s"
				% [c.position, c._goal, c.carrying_amount, alternate.inventory[Config.Res.FOOD], stock])

	nearby.inventory[Config.Res.FOOD] = 0.0
	alternate.inventory[Config.Res.FOOD] = 0.0
	keep.inventory[Config.Res.FOOD] = 0.0
	c.next_meal = 0.0
	c.meal_retry_at = 0.0
	c.state = Citizen.State.IDLE
	_sim._tick_citizen(c, 0.1)
	_check(c.state != Citizen.State.EATING and c.meal_retry_at > _sim.day,
			"inaccessible household food does not trap a citizen in an eating errand")

	_ring(keep.position, 4, true)
	_ring(alternate.position, 4, true)
	c.position = Vector3(270, 9, 200)
	c.clear_goal()
	c.pick_up(Config.Res.FOOD, 7.0, _registry)
	_sim._carry_stray_load(c, 0.1)
	_check(c.carrying_amount == 7.0 and not c.has_goal(),
			"when all storage is unreachable the load stays held without a futile route")
	_ring(alternate.position, 4, false)
	for i in 800:
		_sim._carry_stray_load(c, 0.1)
		if c.carrying_amount <= 0.01:
			break
	_check(c.carrying_amount == 0.0 and alternate.inventory[Config.Res.FOOD] == 7.0,
			"opening storage access lets a stranded load recover")
	if c.carrying_amount != 0.0 or alternate.inventory[Config.Res.FOOD] != 7.0:
		print("  position=%s goal=%s carry=%s stock=%s path=%s"
				% [c.position, c._goal, c.carrying_amount, alternate.inventory[Config.Res.FOOD], c._path])

	# Public food can all be unreachable, but a carrier must still be able to
	# eat the ration already on their own back without discarding the rest.
	c.position = Vector3(270, 9, 200)
	c.pick_up(Config.Res.FOOD, Config.MEAL_FOOD + 0.125, _registry)
	c.next_meal = 0.0
	c.meal_retry_at = 0.0
	c.hunger = 0.8
	c.state = Citizen.State.IDLE
	_ring(alternate.position, 4, true)
	meals = c.meals_taken
	_sim._tick_citizen(c, 0.1)
	_check(c.meals_taken == meals + 1 and c.carrying_amount == 0.125,
			"a blocked food carrier eats one ration and keeps every remaining unit")


func _immigration_access() -> void:
	var destination := Config.cell_to_world(Vector2i(110, 110))
	_ring(destination, 3, true)
	_check(_sim.population.edge_entry_point(_world, destination) == Vector3.INF,
			"immigration rejects walkable map edges disconnected from the settlement")
	_ring(destination, 3, false)
	var entry := _sim.population.edge_entry_point(_world, destination)
	_check(entry != Vector3.INF and _world.nav.can_reach(entry, destination),
			"opening access admits settlers from a connected map edge")


func _loaded_haul(c: Citizen, source: Building, destination: Building,
		res: int, amount: float) -> JobBoard.Job:
	var job := _sim.jobs.post(JobBoard.Kind.HAUL, source.position, 999.0)
	job.source_id = source.id
	job.dest_id = destination.id
	job.res = res
	job.amount = amount
	job.loaded = true
	destination.incoming[res] += amount
	_sim.jobs.index(job)
	c.pick_up(res, amount, _registry)
	_sim._seek_job(c)
	_check(c.job == job, "carrier owns the loaded delivery fixture")
	c.next_meal = 0.0
	c.meal_retry_at = 0.0
	c.hunger = 0.8
	return job


func _delivery_meal_breaks() -> void:
	var source := _sim.place_building("stockpile", Vector3(600, 9, 180), 0.0, true)
	var food := _sim.place_building("granary", Vector3(600, 9, 220), 0.0, true)
	food.inventory[Config.Res.FOOD] = 50.0
	var site := _sim.place_building("house", Vector3(660, 9, 220), 0.0)
	var c := _sim.add_citizen(_sim.entrance_of(food, "att_cart_bay") + Vector3(8, 0, 0))
	var job := _loaded_haul(c, source, site, Config.Res.TIMBER, 8.0)
	for i in 800:
		_sim._tick_citizen(c, 0.1)
		if c.meals_taken > 0:
			break
	_check(c.meals_taken == 1 and c.job == job and not job.cancelled,
			"an urgent meal preserves the loaded delivery's claimed job")
	_check(c.carrying_amount == 8.0 and site.incoming[Config.Res.TIMBER] == 8.0,
			"eating preserves cargo and the destination's incoming claim")
	_check(c.has_goal() and c._goal == _sim.entrance_of(site, "att_cart_bay"),
			"after eating the carrier resumes its construction destination")
	for i in 800:
		_sim._tick_citizen(c, 0.1)
		if c.job == null:
			break
	_check(site.delivered.get(Config.Res.TIMBER, 0.0) == 8.0
			and site.incoming[Config.Res.TIMBER] == 0.0 and c.carrying_amount == 0.0,
			"the resumed load arrives with no lost goods or stale incoming claim")

	var destination := _sim.place_building("granary", Vector3(660, 9, 180), 0.0, true)
	job = _loaded_haul(c, food, destination, Config.Res.FOOD, 2.0)
	var meals := c.meals_taken
	_sim._tick_citizen(c, 0.1)
	_check(c.meals_taken == meals + 1 and c.job == job
			and c.carrying_amount == 2.0 - Config.MEAL_FOOD,
			"a food carrier eats one ration and preserves the remaining delivery")
	for i in 800:
		_sim._tick_citizen(c, 0.1)
		if c.job == null:
			break
	_check(destination.inventory[Config.Res.FOOD] == 2.0 - Config.MEAL_FOOD
			and destination.incoming[Config.Res.FOOD] == 0.0,
			"a food delivery releases its full original claim after supplying a meal")

	job = _loaded_haul(c, food, destination, Config.Res.FOOD, Config.MEAL_FOOD)
	_sim._tick_citizen(c, 0.1)
	_check(c.carrying_amount == 0.0 and c.job == null and job.cancelled
			and destination.incoming[Config.Res.FOOD] == 0.0,
			"eating a delivery's final ration retires its incoming claim")

	var doomed := _sim.place_building("house", Vector3(660, 9, 280), 0.0)
	c.position = _sim.entrance_of(doomed, "att_cart_bay")
	job = _loaded_haul(c, source, doomed, Config.Res.TIMBER, 8.0)
	_sim._tick_citizen(c, 0.1)
	_check(c.state == Citizen.State.EATING and c.job == job,
			"loaded carrier can be walking to its meal when the destination changes")
	_sim.stores.refresh_totals(_sim.citizens, _sim.buildings)
	var stock := _sim.stores.total(Config.Res.TIMBER)
	_sim.demolish(doomed)
	_sim.stores.refresh_totals(_sim.citizens, _sim.buildings)
	_check(c.job == null and job.cancelled and _sim.stores.total(Config.Res.TIMBER) == stock,
			"demolition during a meal cancels the delivery while conserving its cargo")


func _meal_departure_planning() -> void:
	var route_from := Vector3(601, 9, 481)
	var route_to := route_from + Vector3(1, 0, 1)
	var walk_cost := _world.nav.travel_cost(route_from, route_to)
	_world.nav.set_cultivated(150, 120, true)
	_check(is_equal_approx(_world.nav.travel_cost(route_from, route_to), walk_cost),
			"route preferences do not inflate estimated time when walking speed is unchanged")
	_world.nav.set_cultivated(150, 120, false)
	# Isolate a long, walkable food trip with a real loaded construction job.
	# The old policy waited for urgent hunger before beginning this whole walk.
	for b in _sim.buildings:
		b.inventory[Config.Res.FOOD] = 0.0
		b.larder = 0.0
	var source := _sim.place_building("stockpile", Vector3(580, 9, 650), 0.0, true)
	var food := _sim.place_building("granary", Vector3(620, 9, 620), 0.0, true)
	food.inventory[Config.Res.FOOD] = 50.0
	var site := _sim.place_building("house", Vector3(710, 9, 660), 0.0)
	var c := _sim.add_citizen(Vector3(622, 9, 360))
	c.home_id = -1
	c.take_meal(1.779)
	_check(is_equal_approx(c.next_meal, 1.779 + (Config.MEAL_TIMES[1] - Config.MEAL_TIMES[0])),
			"a late meal provides a full meal interval before hunger begins again")
	c.take_meal(1.30)
	_check(is_equal_approx(c.next_meal, 1.78),
			"an on-time breakfast keeps the ordinary evening meal schedule")
	c.meals_taken = 0
	var job := _loaded_haul(c, source, site, Config.Res.TIMBER, 8.0)
	_sim.day = 1.36
	_sim._is_night = false
	c.hunger = 0.02
	_check(not _sim._should_start_meal(c),
			"a worker with enough time to reach food can finish the current task")
	# An outbound worker cannot keep turning around just before reaching a
	# distant resource. Finish that leg before planning an early return meal.
	c.drop()
	c.hunger = 0.18
	_check(not _sim._should_start_meal(c),
			"an outbound worker keeps making progress before actual urgent hunger")
	c.hunger = Config.HUNGER_URGENT
	_check(_sim._should_start_meal(c),
			"actual urgent hunger still interrupts an outbound worker")
	c.pick_up(Config.Res.TIMBER, 8.0, _registry)
	c.hunger = 0.02
	var paths := int(Perf._counters.get("nav.paths", 0))
	for i in 100:
		_sim._should_start_meal(c)
	_check(int(Perf._counters.get("nav.paths", 0)) == paths,
			"repeated meal checks reuse the cached route instead of running A* each tick")
	_sim.day += Config.MEAL_RETRY_DAYS
	_sim._should_start_meal(c)
	_check(int(Perf._counters.get("nav.paths", 0)) > paths,
			"meal route estimates refresh after their bounded interval")
	c.hunger = 0.18
	_sim._tick_citizen(c, 0.1)
	_check(c.state == Citizen.State.EATING and c.job == job
			and c.hunger < Config.HUNGER_URGENT,
			"a distant loaded worker leaves for food before hunger becomes urgent")
	var highest_hunger := c.hunger
	for i in 2000:
		_sim.day += 0.1 / Config.DAY_LENGTH
		_sim._is_night = Config.is_night(_sim.day)
		highest_hunger = maxf(highest_hunger, c.hunger)
		_sim._tick_citizen(c, 0.1)
		if c.meals_taken > 0:
			break
	_check(c.meals_taken == 1 and highest_hunger < Config.HUNGER_URGENT,
			"travel-aware departure gets a distant worker fed before urgent hunger")
	_check(c.job == job and c.carrying_amount == 8.0
			and site.incoming[Config.Res.TIMBER] == 8.0,
			"an earlier meal break preserves the delivery and every reserved unit")
	for i in 800:
		_sim._tick_citizen(c, 0.1)
		if c.job == null:
			break
	_check(site.delivered.get(Config.Res.TIMBER, 0.0) == 8.0
			and site.incoming[Config.Res.TIMBER] == 0.0 and c.carrying_amount == 0.0,
			"the earlier meal break still completes its claimed construction delivery")

	# A carrier with no outstanding job has no reason to postpone a due meal.
	c.position = _sim.entrance_of(food, "att_cart_bay")
	c.clear_goal()
	c.pick_up(Config.Res.STONE, 3.0, _registry)
	c.hunger = 0.01
	c.next_meal = 0.0
	var meals := c.meals_taken
	_sim._tick_citizen(c, 0.1)
	_check(c.meals_taken == meals + 1 and c.carrying_amount == 3.0,
			"a jobless carrier eats a due meal immediately without losing the load")
	c.drop()
	c.clear_goal()

	var home := _sim.place_building("house", Vector3(710, 9, 710), 0.0, true)
	c.home_id = home.id
	home.larder = 4.0
	c.position = _sim.entrance_of(home, "att_entrance")
	c.next_meal = 0.0
	c.hunger = 0.01
	_sim.day = 2.9
	_sim._is_night = true
	meals = c.meals_taken
	_sim._tick_citizen(c, 0.1)
	_check(c.meals_taken == meals + 1 and home.larder == 3.5,
			"an overdue dinner at home is eaten before turning in for the night")
	_sim._tick_citizen(c, 0.1)
	_check(c.indoors and c.state == Citizen.State.SLEEPING,
			"after dinner the citizen still sleeps normally")

	food.inventory[Config.Res.FOOD] = 0.0
	c.set_indoors(false)
	c.state = Citizen.State.IDLE
	c.position = Vector3(622, 9, 580)
	c.clear_goal()
	c.next_meal = 0.0
	c.meal_retry_at = 0.0
	_sim._is_night = false
	_check(_sim._meal_home(c) == home,
			"a distant stocked home remains a food source when public stores are empty")
	meals = c.meals_taken
	for i in 1000:
		_sim._tick_citizen(c, 0.1)
		if c.meals_taken > meals:
			break
	_check(c.meals_taken == meals + 1 and home.larder == 3.0,
			"the citizen reaches the distant stocked home and actually eats")


func _run() -> void:
	_registry.load_all()
	_flat_world()
	_path_edges()
	_building_changes()
	_food_and_stores()
	_immigration_access()
	_delivery_meal_breaks()
	_meal_departure_planning()
	_outbound_delivery_meals()
	_sim.free()
	_world.free()
	print("Navigation regression failures: %d" % _failures)
	quit(1 if _failures else 0)


func _outbound_delivery_meals() -> void:
	for b in _sim.buildings:
		b.inventory[Config.Res.FOOD] = 0.0
		b.larder = 0.0
	var food := _sim.place_building("granary", Vector3(700, 9, 540), 0.0, true)
	food.inventory[Config.Res.FOOD] = 100.0
	var source := _sim.place_building("stockpile", Vector3(700, 9, 500), 0.0, true)
	var site := _sim.place_building("house", Vector3(220, 9, 540), 0.0)
	var c := _sim.add_citizen(_sim.entrance_of(food, "att_cart_bay"))
	c.home_id = -1
	c.speed_scale = 1.0
	c.speed_modifier = 1.0
	var job := _loaded_haul(c, source, site, Config.Res.TIMBER, 12.0)
	_sim.day = 10.30
	c.take_meal(_sim.day)
	c.set_goal(_sim.entrance_of(site, "att_cart_bay"))
	var delivered := false
	var claims_intact := true
	var highest_hunger := 0.0
	# The destination is reachable before urgency after a full meal, but a
	# policy that demands time to return for dinner turns back halfway forever.
	for i in roundi(Config.DAY_LENGTH * 2.0 / 0.1):
		_sim.day += 0.1 / Config.DAY_LENGTH
		_sim._is_night = Config.is_night(_sim.day)
		_sim._tick_citizen(c, 0.1)
		highest_hunger = maxf(highest_hunger, c.hunger)
		if c.job == null:
			delivered = site.delivered.get(Config.Res.TIMBER, 0.0) == 12.0
			break
		claims_intact = claims_intact and c.job == job and c.carrying_amount == 12.0 \
				and site.incoming[Config.Res.TIMBER] == 12.0
	_check(delivered and highest_hunger < Config.HUNGER_URGENT,
			"a distant outbound delivery arrives before urgency instead of repeating meal detours")
	_check(claims_intact and site.incoming[Config.Res.TIMBER] == 0.0
			and c.carrying_amount == 0.0,
			"the distant delivery preserves its cargo and clears its incoming claim on arrival")
