extends "res://tests/long_run.gd"

## Real viewport coverage for the market, paid road/research and army controls.
## xvfb-run -a tools/godot_env.sh --path game --script res://tests/expansion_ui.gd


func _settle_ui() -> void:
	for i in 4:
		await process_frame


func _button(node: Node, prefix: String) -> Button:
	for child in node.get_children():
		if child is Button and child.is_visible_in_tree() and child.text.contains(prefix):
			return child
		var found := _button(child, prefix)
		if found != null:
			return found
	return null


func _click_at(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame
	await _settle_ui()


func _click(button: Button) -> void:
	_check(button != null and not button.disabled, "requested UI action exists and is enabled")
	if button == null or button.disabled:
		return
	var ancestor := button.get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer:
			ancestor.ensure_control_visible(button)
		ancestor = ancestor.get_parent()
	await _settle_ui()
	await _click_at(button.get_global_rect().get_center())


func _panel_fits(game: SeededGame, label: String) -> void:
	var panel: Rect2 = game.hud._selection_panel.get_global_rect()
	var bar_top: float = game.hud._build_bar.get_global_rect().position.y
	_check(panel.position.x >= 0 and panel.end.x <= root.size.x + 1
			and panel.end.y <= bar_top - 5,
			label + " panel fits above the build bar")
	_check(panel.size.x >= 208.0, label + " retains readable panel width")
	_check(not game.hud.blocks_mouse(Vector2(panel.get_center().x, bar_top - 3)),
			label + " clipped actions do not block ground below the panel")


func _shot(name: String) -> void:
	await _settle_ui()
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/expansion_ui")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _run() -> void:
	var game := _new_game(42)
	game.process_mode = Node.PROCESS_MODE_ALWAYS
	game.set_process(false)
	game.camera.set_process(false)
	game.world.set_time_of_day(0.38)
	for res in Config.RES_COUNT:
		game.sim.keep.inventory[res] = 150.0
	var centre := game.world.centre()
	var market := _build(game, "market", centre + Vector3(40, 0, 38))
	var barracks := _build(game, "barracks", centre + Vector3(-45, 0, -10))
	var fort := _build(game, "fort", centre + Vector3(-32, 0, 45))
	if market == null or barracks == null or fort == null:
		game.free()
		quit(1)
		return
	market.inventory[Config.Res.FOOD] = 80.0
	market.refresh_stock_display()
	game.sim.stores.refresh_totals(game.sim.citizens, game.sim.buildings)
	game.sim._update_stats()
	game.hud.refresh()
	for dimensions in [Vector2i(1280, 720), Vector2i(900, 600), Vector2i(640, 900)]:
		root.size = dimensions
		await _settle_ui()
		await _click(_button(game.hud, "Research"))
		_check(game.research_open and game.hud._selection_actions.get_child_count() == RoadResearch.TECH_IDS.size(),
			"Research button opens every technology at %s" % dimensions)
		_panel_fits(game, "Research %s" % dimensions)
		await _shot("research_%d" % dimensions.x)
		await _click(_button(game.hud, "Army"))
		_check(game.army_open, "Army button opens the actual army panel")
		_panel_fits(game, "Army %s" % dimensions)
	root.size = Vector2i(1280, 720)
	await _settle_ui()
	await _click(_button(game.hud, "Research"))
	await _click(_button(game.hud._selection_actions, "Roadworks"))
	_check(game.sim.research.active == "roadworks", "technology action starts paid Roadworks research")
	game.sim.research.advance(2.0)
	game.hud.refresh()
	game._clear_selection()
	game.selected_building = market
	game._refresh_selection()
	game.camera.look_at_position(market.position, 46.0)
	await _settle_ui()
	await _click(_button(game.hud._selection_actions, "120"))
	_check(market.market_stock_target == 120, "market stock policy action changes its actual target")
	await _shot("market")
	var road_at := centre + Vector3(-12, 0, 6)
	for i in 24:
		game.world.wear.stamp_segment(road_at, road_at + Vector3(22, 0, 0), 1.0, 1.6)
	game.world.wear.refresh_levels()
	game.world.wear.flush_texture()
	game._clear_selection()
	game.selected_road = road_at
	game.has_road_selection = true
	game.camera.look_at_position(road_at, 55.0)
	game._refresh_selection()
	await _settle_ui()
	for label in ["Busiest route", "Main routes", "Entire connected"]:
		await _click(_button(game.hud._selection_actions, label))
		_check(is_instance_valid(game._road_preview) and game._road_preview.multimesh.instance_count
				== game._road_quotes[game.road_scope].count,
				"road choice highlights its exact quoted texels")
		_check(_button(game.hud._selection_actions, label).text.contains("\n"),
				"each road scope shows its own material cost")
	_panel_fits(game, "Road improvement")
	await _shot("road_preview")
	var quote := game._road_info(road_at)
	_check(quote.can_upgrade, "funded researched road improvement is available")
	await _click(_button(game.hud._selection_actions, "Commission improvement"))
	_check(game.world.wear.road_level_at(road_at.x, road_at.z) >= Config.RoadLevel.DIRT,
			"commission button applies the selected paid road improvement")
	await _click(_button(game.hud, "Army"))
	await _click(_button(game.hud._selection_actions, "Recruit"))
	_check(game.sim.campaign.friendly_ids().size() == 1, "Army recruitment creates a real soldier")
	await _click(_button(game.hud._selection_actions, "Muster"))
	_check(game.selected_units.size() == 1, "Muster selects the recruited force")
	var unit: Soldier = game.sim.campaign.units[game.selected_units[0]]
	var goal := unit.position + Vector3(10, 0, 8)
	goal.y = game.world.heightmap.height_at(goal.x, goal.z)
	game.camera.look_at_position(goal, 42.0)
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(goal), MOUSE_BUTTON_RIGHT)
	_check(unit.has_goal(), "right-click through the viewport issues a military movement order")
	var old_position := unit.position
	for i in 20:
		game.sim.campaign.tick(0.1)
	_check(unit.position.distance_to(old_position) > 0.5, "the mustered soldier physically marches")
	await _shot("army_fort")
	game._clear_selection()
	game.selected_building = fort
	game._refresh_selection()
	game.camera.look_at_position(fort.position, 40.0)
	await _shot("fort")
	await _click(_button(game.hud, "Army"))
	await _click(_button(game.hud._selection_actions, "Recruit"))
	await _click(_button(game.hud._selection_actions, "Recruit"))
	await _click(_button(game.hud._selection_actions, "Muster"))
	var enemy_house: Building = game.sim.campaign._enemy_type("house")
	for i in game.selected_units.size():
		var guard: Soldier = game.sim.campaign.units[game.selected_units[i]]
		guard.position = game.sim.campaign._door(enemy_house) + Vector3((i - 1) * 3, 0, 7)
		guard.position.y = game.world.heightmap.height_at(guard.position.x, guard.position.z)
	game.sim.scouting.refresh_visibility()
	game.camera.look_at_position(enemy_house.position, 38.0)
	await physics_frame
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(enemy_house.position + Vector3(0, 2, 0)),
			MOUSE_BUTTON_RIGHT)
	_check(unit.target_kind == "building" and unit.target_id == enemy_house.id,
			"right-click on a rival building issues an actual attack order")
	for i in 45:
		game.sim.campaign.tick(0.1)
	_check(enemy_house.fire > 0.0 and enemy_house.health < enemy_house.max_health(),
			"the commanded attack ignites and damages the rival building")
	await _shot("rival_attack")
	game.dev_mode = true
	game.dev.visible = true
	game.dev._refresh()
	await _settle_ui()
	var selector: OptionButton = game.dev._personality
	var old_selection := game.selected_units.duplicate()
	await _click(selector)
	_check(selector.get_popup().visible and game.selected_units == old_selection,
			"developer personality control opens without issuing a world order")
	# Exercise the actual embedded popup through its parent viewport, including
	# its input grab. Direct PopupMenu.push_input bypasses that window routing.
	var popup := selector.get_popup()
	await _click_at(Vector2(popup.position) + Vector2(popup.size.x * 0.5, popup.size.y * 5.0 / 6.0))
	await _settle_ui()
	_check(game.sim.campaign.personality == "loner", "developer dropdown edits the live rival personality")
	var saved := SaveGame.capture(game)
	game.sim.campaign.set_personality("aggressive")
	var problem := game.restore_from(saved)
	await _settle_ui()
	_check(problem == "" and game.sim.campaign.personality == "loner"
			and game.dev._personality.selected == 2,
			"save/load restores personality and rebinds the developer dropdown")
	await _shot("personality_restored")
	game.dev.visible = false
	game.free()
	await _settle_ui()
	print("Expansion UI regression failures: %d" % _failures)
	quit(1 if _failures else 0)
