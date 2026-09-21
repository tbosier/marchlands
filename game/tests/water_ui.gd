extends "res://tests/expansion_ui.gd"


func _shot(name: String) -> void:
	await _settle_ui()
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/water_ui")
	DirAccess.make_dir_recursive_absolute(directory)
	_check(root.get_texture().get_image().save_png(directory.path_join(name + ".png")) == OK,
		"water screenshot saved: " + name)


func _run() -> void:
	var game := _new_game(42)
	game.process_mode = Node.PROCESS_MODE_ALWAYS
	game.set_process(false)
	game.camera.set_process(false)
	game.world.set_time_of_day(0.38)
	var well: Building
	var house: Building
	for b in game.sim.buildings:
		if b.type_id == "well": well = b
		if b.type_id == "house": house = b
	_check(well != null, "opening settlement has a physical well")
	if well == null:
		game.free()
		quit(1)
		return
	game.camera.look_at_position(well.position, 30)
	await physics_frame
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(well.position + Vector3(0, 1, 0)))
	_check(game.selected_building == well and game.hud._selection_body.text.contains("Water"),
		"clicking the well opens its local water reserve")
	await _shot("well")
	var resident: Citizen = game.sim.citizens[0]
	resident.hydration = 0.3
	game._clear_selection()
	game.selected_citizen = resident
	game._refresh_selection()
	_check(game.hud._selection_body.text.contains("Hydration") and game.hud._selection_body.text.contains("30%"),
		"individual inspection shows hydration")
	house.apply_damage(0, 0.3)
	game._clear_selection()
	game.selected_building = house
	game._refresh_selection()
	var population := game.sim.population_members().size()
	await _click(_button(game.hud._selection_actions, "Send a worker with water"))
	_check(game.sim.water.carriers.size() == 1 and game.sim.population_members().size() == population,
		"fire response button assigns an existing resident without losing population")
	game.hud.refresh()
	_check(game.hud._pop_label.tooltip_text.contains("1 bucket carriers"), "population distinguishes the worker carrying water")
	await _shot("fire_response")
	var carrier: Citizen = game.sim.water.carriers.values()[0].person
	_check(carrier.water_bucket == 0, "responding worker has no water until reaching the well")
	for i in 800:
		game.sim.water.tick(0.1)
		if carrier.water_bucket > 0: break
		if i % 100 == 0: await process_frame
	_check(carrier.water_bucket > 0 and carrier.get_node_or_null("water_bucket") != null,
		"a filled carried bucket is visible on the actual worker")
	game.camera.look_at_position(carrier.position, 18)
	await _shot("bucket_carrier")
	for dimensions in [Vector2i(1280,720), Vector2i(640,480)]:
		root.size = dimensions
		game._clear_selection()
		game.selected_building = well
		game._refresh_selection()
		await _settle_ui()
		_panel_fits(game, "Well %s" % dimensions)
		await _shot("well_%d" % dimensions.x)
	game.free()
	await process_frame
	print("Water UI regression failures: %d" % _failures)
	quit(1 if _failures else 0)
