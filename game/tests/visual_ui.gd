extends "res://tests/connections_ui.gd"

## Rendered layout and stale-interface checks for release review.
## xvfb-run -a -s "-screen 0 1600x1000x24" tools/godot_env.sh --path game --script res://tests/visual_ui.gd


func _shot(name: String) -> void:
	await _settle_ui()
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/visual_ui")
	DirAccess.make_dir_recursive_absolute(directory)
	_check(root.get_texture().get_image().save_png(directory.path_join(name + ".png")) == OK,
		"screenshot saved: " + name)


func _tray(game: SeededGame, suffix: String) -> void:
	await _click(game.hud._build_toggle)
	_check(game.hud.tray_is_open(), "Build opens the scrollable tray " + suffix)
	game.hud._build_scroll.scroll_horizontal = 0
	await _settle_ui()
	_check(game.hud._build_scroll.get_global_rect().end.x >= game.hud.size.x - 16,
		"open tray uses the full available row " + suffix)
	await _shot("tray_first_" + suffix)
	# Each building lives under one tab, reached by clicking it: one click per
	# tab, then every card it shows is checked.
	var by_tab := {}
	for type_id in game.hud._build_buttons:
		var category := BuildingDefs.tray_category(type_id)
		if not by_tab.has(category): by_tab[category] = []
		by_tab[category].append(type_id)
	for category in by_tab:
		await _click(game.hud._tray_tabs[category])
		for other in game.hud._build_buttons:
			var shown: bool = game.hud._build_buttons[other].visible
			if shown != by_tab[category].has(other):
				_check(false, "the %s tab %s %s %s" % [category,
						"hides" if shown else "shows", other, suffix])
		for type_id in by_tab[category]:
			await _check_card(game, type_id, suffix)
	game.hud._build_scroll.ensure_control_visible(game.hud._clear_button)

	await _shot("tray_last_" + suffix)
	await _click(game.hud._clear_button)
	_check(game.mode == game.Mode.CLEAR, "last scrolled tray action activates Clear Ground " + suffix)
	game._exit_clear_tool()
	await _click(game.hud._build_toggle)


func _window(game: SeededGame, dimensions: Vector2i) -> void:
	root.size = dimensions
	await _settle_ui()
	var suffix := "%dx%d" % [dimensions.x, dimensions.y]
	game._clear_selection()
	game.hud.clear_alerts()
	game.camera.look_at_position(game.sim.keep.position, 78)
	for label in ["Research", "Army", "Trade", "Bridge"]:
		await _click(_button(game.hud, label))
		_panel_fits(game, label + " " + suffix)
		await _shot(label.to_lower() + "_" + suffix)
		if label == "Bridge": game._cancel_bridge()
	await _tray(game, suffix)
	await _click(_button(game.hud, "World"))
	var dialog := game.hud._world_dialog
	_check(Rect2(Vector2.ZERO, dimensions).encloses(Rect2(dialog.position, dialog.size)),
		"world dialog fits " + suffix)
	await _shot("world_" + suffix)
	await _dialog_click(dialog, dialog.get_cancel_button())


func _lifecycle(game: SeededGame) -> void:
	root.size = Vector2i(1280, 720)
	await _settle_ui()
	var hud := game.hud
	var before_controls := hud.get_child_count()
	_check(game.save_game("visual_ui") == "", "rendered fixture saves successfully")
	await _click(_button(hud, "Bridge"))
	game._bridge_start = game.sim.keep.position
	game._bridge_hover = game.sim.keep.position + Vector3(20, 0, 0)
	game._update_bridge_preview()
	var old_world := game.world
	_check(game.load_game("visual_ui") == "", "load succeeds with a placement tool open")
	await _settle_ui()
	_check(not is_instance_valid(old_world) and game.world != old_world,
		"load frees the prior rendered world")
	_check(game.mode == game.Mode.SELECT and not hud._selection_panel.visible
		and not is_instance_valid(game._bridge_preview) and game._bridge_start == Vector3.INF,
		"load clears the old bridge preview and selection panel")
	_check(game.hud == hud and hud.get_child_count() == before_controls,
		"load keeps one HUD with no duplicate bars")
	game.world.set_time_of_day(0.38)
	await _shot("loaded_world")
	await _create_world(game)
	_check(game.hud == hud and game.hud._sim == game.sim and not hud._selection_panel.visible,
		"new world binds the existing HUD and clears prior selection")
	await _shot("replaced_world")


func _run() -> void:
	root.position = Vector2i.ZERO
	var game := _new_game(42)
	game.process_mode = Node.PROCESS_MODE_ALWAYS
	game.set_process(false)
	game.camera.set_process(false)
	game.world.set_time_of_day(0.38)
	for resource in Config.RES_COUNT: game.sim.keep.inventory[resource] = 150
	game.sim.stores.refresh_totals(game.sim.population_members(), game.sim.buildings)
	game.sim._update_stats()
	game.hud.refresh()
	for dimensions in [Vector2i(1280, 720), Vector2i(900, 600), Vector2i(640, 900), Vector2i(640, 480)]:
		await _window(game, dimensions)
	root.size = Vector2i(1280, 960)
	root.content_scale_factor = 2.0
	await _settle_ui()
	game._clear_selection()
	game.hud.set_tray_open(true)
	game.hud._build_scroll.scroll_horizontal = 0
	await _shot("tray_double_scale")
	game.hud.set_tray_open(false)
	root.content_scale_factor = 1.0
	await _lifecycle(game)
	game.free()
	await _settle_ui()
	print("Visual UI regression failures: %d" % _failures)
	quit(1 if _failures else 0)


func _check_card(game: SeededGame, type_id: String, suffix: String) -> void:
	var button: Button = game.hud._build_buttons[type_id]
	game.hud._build_scroll.ensure_control_visible(button)
	await _settle_ui()
	var viewport := game.hud._build_scroll.get_global_rect()
	_check(viewport.encloses(button.get_global_rect()), "build card is reachable: " + type_id + " " + suffix)
	var label: Label = game.hud._build_cards[type_id].name
	var text_width := label.get_theme_font("font").get_string_size(label.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
	_check(text_width <= label.size.x + 1.0, "build name is fully readable: " + type_id + " " + suffix)
	var price: Label = game.hud._build_cards[type_id].cost
	var price_width := price.get_theme_font("font").get_string_size(price.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, price.get_theme_font_size("font_size")).x
	_check(price.is_visible_in_tree() and price_width <= price.size.x + 1.0,
		"building material price is fully readable: " + type_id + " " + suffix)
