extends "res://tests/long_run.gd"

## tools/godot_env.sh --headless --path game --script res://tests/perf_budgets.gd
##
## Wall-clock budgets, kept apart from the functional suites because they only
## mean something on a quiet machine. The gate runs this stage on its own, after
## the parallel stages have finished (`tools/verify.py`, `exclusive`).


## One click on a soldier selects his whole company, and a company can be two
## thousand strong. The build this replaced asked `Array.has` and `Array.erase`
## per id, which measured 11.3 ms against 3.3 ms for the set; 8 ms sits clear
## of both, and the best of three keeps a scheduling spike from deciding it.
func _company_click() -> void:
	var game := _new_game(42)
	var campaign: FrontierCampaign = game.sim.campaign
	campaign.set_personality("peaceful")
	var at: Vector3 = game.sim.entrance_of(game.sim.keep, "att_entrance")
	var army: Array[int] = []
	for i in 2000:
		var recruit := campaign._spawn_unit(0, at + Vector3(float(i % 50), 0, float(i / 50)))
		recruit.position.y = game.world.heightmap.height_at(recruit.position.x, recruit.position.z)
		army.append(recruit.id)
	campaign.form_company(army)
	var best := INF
	for attempt in 3:
		game.selected_units.clear()
		var started := Time.get_ticks_usec()
		game._select_unit(army[0], false, false)
		best = minf(best, float(Time.get_ticks_usec() - started) / 1000.0)
	_check(game.selected_units.size() == army.size() and best < 8.0,
			"one click takes the whole 2,000-man company in %.2f ms, inside the 8 ms budget" % best)
	game.free()
	await process_frame


func _run() -> void:
	await _company_click()
	print("Performance budget failures: %d" % _failures)
	quit(1 if _failures else 0)
