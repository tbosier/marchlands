extends "res://tests/expansion_ui.gd"


func _shot(name: String) -> void:
	await _settle_ui()
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/scouting_ui")
	DirAccess.make_dir_recursive_absolute(directory)
	_check(root.get_texture().get_image().save_png(directory.path_join(name + ".png")) == OK,
		"scouting screenshot saved: " + name)


func _run() -> void:
	var game := _new_game(42)
	game.process_mode = Node.PROCESS_MODE_ALWAYS
	game.set_process(false)
	game.camera.set_process(false)
	game.world.set_time_of_day(0.38)
	await _settle_ui()
	_check(game.sim.scouting.city_report().is_empty(), "new game does not disclose the rival town")
	await _click(_button(game.hud, "Scouts"))
	_check(game.scouting_open, "Scouts toolbar opens its panel")
	await _click(_button(game.hud._selection_actions, "Known settlement reports"))
	_check(game.city_report_open and game.hud._selection_body.text.contains("No settlements"),
		"unknown cities cannot be inspected through a report button")
	var lodge := _build(game, "scout_lodge", game.world.centre() + Vector3(55, 0, -20))
	if lodge == null:
		game.free()
		quit(1)
		return
	game._clear_selection()
	game.selected_building = lodge
	game._refresh_selection()
	var population := game.sim.population_members().size()
	await _click(_button(game.hud._selection_actions, "Train a citizen scout"))
	_check(game.sim.scouting.scouts.size() == 1 and game.sim.citizens.size() == population - 1
		and game.sim.population_members().size() == population, "training click reassigns one real resident")
	game.hud.refresh()
	_check(game.hud._pop_label.tooltip_text.contains("%d people" % population)
		and game.hud._pop_label.tooltip_text.contains("1 scouts"), "population readout includes the scout away from local work")
	if game.sim.scouting.scouts.is_empty():
		game.free()
		quit(1)
		return
	var scout: Scout = game.sim.scouting.scouts.values()[0]
	for i in 1600:
		game.sim.scouting.tick(0.25)
		if scout.state == "ready": break
		if i % 100 == 0: await process_frame
	_check(scout.state == "ready", "scout collects supplies, walks to lodge and completes timed training")
	# Found on the map and clicked, the way a player picks him out.
	game._clear_selection()
	game.camera.look_at_position(scout.person.global_position, 30)
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(
			scout.person.global_position + Vector3(0, 0.9, 0)), MOUSE_BUTTON_LEFT)
	_check(game.selected_scout == scout.id,
			"clicking the scout on the map selects him (selected %d)" % game.selected_scout)
	game._clear_selection()
	game.scouting_open = true
	game._refresh_selection()
	await _click(_button(game.hud._selection_actions, "Select ·"))
	_check(game.selected_scout == scout.id, "select action chooses the trained person")
	var goal := scout.person.position + Vector3(15, 0, 10)
	goal.y = game.world.heightmap.height_at(goal.x, goal.z)
	game.camera.look_at_position(goal, 45)
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(goal), MOUSE_BUTTON_RIGHT)
	_check(scout.state == "exploring", "right-click issues an exploration order to the selected scout")
	var old_position := scout.person.position
	for i in 20: game.sim.scouting.tick(0.1)
	_check(scout.person.position.distance_to(old_position) > 0.1, "exploration moves the actual scout")
	# Place the observer at the town for a visibility/report fixture; the journey
	# and audience state machines have separate simulation regression coverage.
	scout.person.position = game.sim.campaign.rival_position + Vector3(20, 0, 0)
	game.sim.scouting.refresh_visibility()
	var report: Dictionary = game.sim.scouting.city_report()
	_check(not report.is_empty() and report.source == "observation", "nearby scout produces an observation, not a ruler census")
	scout.person.position = game.sim.keep.position
	game.sim.scouting.refresh_visibility()
	game.sim.day += 12
	game.clock.elapsed_days += 12
	game.sim.campaign.town_population += 7
	game.camera.look_at_position(report.position, 75)
	game._refresh_selection()
	await _settle_ui()
	_check(game.hud._city_marker.visible and game.hud._city_marker.text.contains("12 days"),
		"remembered town marker displays the age of its last visit")
	await _click(game.hud._city_marker)
	_check(game.city_report_open and game.hud._selection_body.text.contains(report.population_text)
		and game.sim.scouting.city_report() == report, "city popup shows the saved observation, without reading new enemy population")
	for dimensions in [Vector2i(1280,720), Vector2i(640,480)]:
		root.size = dimensions
		await _settle_ui()
		_panel_fits(game, "City report %s" % dimensions)
		await _shot("city_report_%d" % dimensions.x)
		await _click(_button(game.hud, "Scouts"))
		game._refresh_city_marker()
		_check(not game.hud._city_marker.visible or not game.hud._city_marker.get_global_rect().intersects(game.hud._selection_panel.get_global_rect()),
			"city marker never overlaps the selection panel")
		_panel_fits(game, "Scouts %s" % dimensions)
		await _shot("scouts_%d" % dimensions.x)
		await _click(_button(game.hud._selection_actions, "Known settlement reports"))
	game.free()
	await process_frame
	print("Scouting UI regression failures: %d" % _failures)
	quit(1 if _failures else 0)
