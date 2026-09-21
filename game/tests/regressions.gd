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


func _run() -> void:
	var game: Node = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var sim: Simulation = game.sim
	var c := sim.citizens[0]
	var original_home := c.home_id
	var original_workplace := c.workplace_id
	c.next_meal = 100.0
	c.home_id = sim.keep.id
	var door := sim.entrance_of(sim.keep, "att_entrance")
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

	game.free()
	print("Regression failures: %d" % _failures)
	quit(1 if _failures else 0)
