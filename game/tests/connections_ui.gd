extends "res://tests/expansion_ui.gd"

## Real input through the rendered viewport, including embedded dialog menus.
## xvfb-run -a -s "-screen 0 1600x1000x24" tools/godot_env.sh --path game --script res://tests/connections_ui.gd


func _shot(name: String) -> void:
	await _settle_ui()
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/connections_ui")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join(name + ".png")
	_check(root.get_texture().get_image().save_png(path) == OK, "screenshot saved: " + name)
	print("SHOT ", path)


func _dialog_click(dialog: Window, control: Control) -> void:
	await _click_at(Vector2(dialog.position) + control.get_global_rect().get_center())


func _toolbar(game: SeededGame) -> void:
	for dimensions in [Vector2i(1280, 720), Vector2i(900, 600), Vector2i(640, 900)]:
		root.size = dimensions
		await _settle_ui()
		for label in ["Trade", "Bridge", "World"]:
			var button := _button(game.hud, label)
			_check(button != null and button.get_global_rect().position.x >= 0
				and button.get_global_rect().end.x <= root.size.x,
				"%s toolbar action fits at %s" % [label, dimensions])
			await _click(button)
			match label:
				"Trade":
					_check(game.trade_open and game.hud._selection_title.text.contains("Trade"),
						"Trade click opens its actual panel at %s" % dimensions)
					_panel_fits(game, "Trade %s" % dimensions)
				"Bridge":
					_check(game.mode == game.Mode.BRIDGE and game.hud._selection_title.text.contains("bridge"),
						"Bridge click opens bank placement at %s" % dimensions)
					_panel_fits(game, "Bridge %s" % dimensions)
					game._cancel_bridge()
				"World":
					_check(game.hud._world_dialog.visible, "World click opens the real dialog at %s" % dimensions)
					await _shot("world_dialog_%d" % dimensions.x)
					await _dialog_click(game.hud._world_dialog, game.hud._world_dialog.get_cancel_button())
					_check(not game.hud._world_dialog.visible, "Cancel closes the world dialog")
	root.size = Vector2i(1280, 720)
	await _settle_ui()


func _create_world(game: SeededGame) -> void:
	var previous := game.world
	await _click(_button(game.hud, "World"))
	var dialog: ConfirmationDialog = game.hud._world_dialog
	var choice: OptionButton = game.hud._world_size_choice
	await _dialog_click(dialog, choice)
	var popup := choice.get_popup()
	_check(popup.visible and choice.item_count == 4, "world size opens four actual selectable presets")
	await _click_at(Vector2(popup.position) + Vector2(popup.size.x * 0.5, popup.size.y * 3.0 / 8.0))
	_check(choice.get_selected_id() == 1536, "clicking the preset menu selects Medium")
	# Return to Small for the generated crossing fixture and a fast UI gate.
	await _dialog_click(dialog, choice)
	popup = choice.get_popup()
	await _click_at(Vector2(popup.position) + Vector2(popup.size.x * 0.5, popup.size.y / 8.0))
	_check(choice.get_selected_id() == 768, "clicking the preset menu selects Small")
	game.hud._world_seed_input.text = "42"
	await _shot("new_world_choice")
	await _dialog_click(dialog, dialog.get_ok_button())
	await _settle_ui()
	_check(game.world != previous and game.world.generation_version == 2 and game.world.world_seed == 42
		and game.world.size_m == 768, "Create world replaces the old march with the selected seed and size")
	_check(game.camera.focus.distance_to(game.sim.keep.position) < 1.0,
		"new-world lifecycle binds and focuses the camera on the new settlement")
	game.camera.set_process(false)
	game.world.set_time_of_day(0.38)


func _trade_controls(game: SeededGame) -> void:
	game.sim.campaign.personality = "peaceful"
	var market := _build(game, "market", game.world.centre() + Vector3(-45, 0, -20))
	_check(market != null, "trade UI fixture has a real market")
	if market == null: return
	game.sim.keep.inventory[Config.Res.TIMBER] = 140
	game.sim.keep.inventory[Config.Res.TOOLS] = 30
	game.sim.keep.inventory[Config.Res.FOOD] = 300
	game.sim.stores.refresh_totals(game.sim.population_members(), game.sim.buildings)
	game.sim._update_stats()
	game.hud.refresh()
	await _click(_button(game.hud, "Trade"))
	_panel_fits(game, "Finite-stock trade")
	await _shot("trade_offer")
	var population := game.sim.population_members().size()
	await _click(_button(game.hud._selection_actions, "Dispatch citizen caravan"))
	_check(game.sim.trade.caravans.size() == 1 and game.sim.citizens.size() == population - 1,
		"dispatch click assigns an existing civilian to a caravan")
	if game.sim.trade.caravans.is_empty(): return
	var route: Caravan = game.sim.trade.caravans.values()[0]
	var readout: String = game.hud._pop_label.text
	var legend: String = game.hud._pop_label.tooltip_text
	_check((readout.contains("C%d" % (population - 1)) and readout.contains("M1")
		or readout.contains("1 merchants")) and legend.contains("%d civilians" % (population - 1))
		and legend.contains("1 merchants"),
		"population readout visibly separates civilians and merchants")
	await _click(_button(game.hud._selection_actions, "Repeat trips: off"))
	_check(route.repeat, "repeat click changes the live caravan policy")
	game._clear_selection()
	# Isolate the merchant from the opening crowd so this tests its actual pick
	# area, without relying on overlapping people resolving in a given order.
	route.merchant.position = game.sim.entrance_of(market, "att_cart_bay") + Vector3(-5, 0, 7)
	route.merchant.position.y = game.world.surface_height_at(route.merchant.position.x, route.merchant.position.z)
	route.cart.follow(game.world.heightmap, 1.0, game.world)
	game.camera.look_at_position(route.merchant.position, 24)
	await physics_frame
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(route.merchant.position + Vector3(0, 1.0, 0)))
	_check(game.selected_caravan == route.id and game.trade_open,
		"clicking the visible merchant selects its caravan and cargo panel")
	_panel_fits(game, "Selected caravan")
	await _shot("selected_caravan")
	await _click(_button(game.hud._selection_actions, "Return home"))
	_check(route.state == "return" and not route.repeat and game.sim.trade.caravans.has(route.id),
		"recall click orders a real return and disables repetition without deleting the merchant")


func _bank_quote(game: SeededGame) -> Dictionary:
	for z in range(60, 110, 3):
		var first := -1
		var last := -1
		for x in range(110, 170):
			if game.world.heightmap.cell_surface(x, z) == Heightmap.Surface.WATER:
				if first < 0: first = x
				last = x
		if first < 0: continue
		for setback in range(1, 5):
			var q: Dictionary = game.sim.bridges.quote(Config.cell_to_world(Vector2i(first - setback, z)),
				Config.cell_to_world(Vector2i(last + setback, z)))
			if q.ok: return q
	return {}


func _bridge_controls(game: SeededGame) -> void:
	var q := _bank_quote(game)
	_check(not q.is_empty(), "generated river exposes a valid two-bank placement")
	if q.is_empty(): return
	game.camera.yaw = 0
	game.camera.look_at_position((q.a + q.b) * 0.5, 75)
	await _settle_ui()
	await _click(_button(game.hud, "Bridge"))
	await _click_at(game.camera.camera().unproject_position(q.a - Vector3(0, Bridges.DECK_LIFT, 0)))
	_check(game._bridge_start.is_finite(), "first terrain click selects the initial bank")
	var endpoint := game.camera.camera().unproject_position(q.b - Vector3(0, Bridges.DECK_LIFT, 0))
	# Preview reads the viewport pointer each frame. Input injection alone does
	# not move the OS pointer that get_mouse_position returns under X11.
	root.warp_mouse(endpoint)
	await _settle_ui()
	var motion := InputEventMouseMotion.new()
	motion.position = endpoint
	motion.global_position = endpoint
	root.push_input(motion, true)
	game._update_bridge_preview()
	await _settle_ui()
	var preview_quote: Dictionary = game.sim.bridges.quote(game._bridge_start, game._bridge_hover)
	if not preview_quote.ok:
		print("POINTER expected=", endpoint, " actual=", root.get_mouse_position(), " window=", root.position)
	_check(is_instance_valid(game._bridge_preview) and game.hud._selection_body.text.contains("Span")
		and game.hud._selection_body.text.contains("Timber") and game.hud._selection_body.text.contains("Tools")
		and game.hud._selection_body.text.contains("No research") and preview_quote.ok,
		"second-bank hover previews real geometry, span, timber, tools and research-free access")
	await _shot("bridge_preview")
	await _click_at(endpoint)
	_check(game.sim.bridges.bridges.size() == 1 and game.selected_bridge >= 0,
		"second terrain click commissions and selects an unfinished bridge")
	if game.selected_bridge < 0: return
	var id: int = game.selected_bridge
	_check(not game.sim.bridges.info(id).complete, "bank clicks do not grant an instant completed crossing")
	game._clear_selection()
	await physics_frame
	await _click_at(game.camera.camera().unproject_position((q.a + q.b) * 0.5 + Vector3(0, 0.4, 0)))
	_check(game.selected_bridge == id, "clicking the scaffold selects its bridge")
	await _shot("bridge_site")
	await _click(_button(game.hud._selection_actions, "Remove bridge"))
	_check(game.sim.bridges.bridges.is_empty(), "remove click cancels the empty construction site")


func _salvage_jobs(game: SeededGame, wreck_id: int) -> int:
	var count := 0
	for job in game.sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.SALVAGE and job.wreck_id == wreck_id:
			count += 1
	return count


func _lost_cart_controls(game: SeededGame) -> void:
	await _click(_button(game.hud, "Trade"))
	await _click(_button(game.hud._selection_actions, "Dispatch citizen caravan"))
	var route_id := int(game.sim.trade._next_id) - 1
	if not game.sim.trade.caravans.has(route_id):
		_check(false, "lost-cart fixture can dispatch its paid cargo")
		return
	var route: Caravan = game.sim.trade.caravans[route_id]
	for i in 2000:
		game.sim.trade.tick(0.25)
		if route.state == "outward": break
	_check(route.state == "outward" and route.cargo_amount > 0,
		"recovery UI fixture loads real timber and provisions before the incident")
	if route.state != "outward": return
	var paid_cargo: float = route.cargo_amount
	# Exercise the normal death transition; the incident retains the paid load.
	route.health = 0
	game.sim.trade.tick(0.1)
	_check(game.sim.trade.wrecks.size() == 1, "a lost merchant leaves one real loaded cart")
	if game.sim.trade.wrecks.is_empty(): return
	var wreck: Dictionary = game.sim.trade.wrecks[0]
	var cargo: PackedFloat32Array = wreck.cargo.duplicate()
	_check(is_equal_approx(cargo[Config.Res.TIMBER], paid_cargo), "lost cart retains the actual paid export")
	await _click(_button(game.hud, "Trade"))
	await _click(_button(game.hud._selection_actions, "Find lost cart"))
	_check(game.camera._target_focus.distance_to(wreck.position) < 1.0,
		"Find lost cart click points the camera at the incident")
	game.camera._process(1.0)
	await _click(_button(game.hud._selection_actions, "Recover goods"))
	_check(wreck.recovery_requested and _salvage_jobs(game, wreck.id) > 0 and wreck.cargo == cargo,
		"Recover goods click posts physical recovery work without moving the cargo")
	_panel_fits(game, "Lost-cart recovery")
	await _shot("lost_cart_recovery")
	await _click(_button(game.hud._selection_actions, "Cancel recovery"))
	_check(not wreck.recovery_requested and _salvage_jobs(game, wreck.id) == 0 and wreck.cargo == cargo,
		"Cancel recovery click cancels uncollected work and preserves every lost good")
	_check(_button(game.hud._selection_actions, "Recover goods") != null,
		"canceled recovery restores the recovery action")


func _alert_cleanup(game: SeededGame) -> void:
	var previous := get_processed_tweens()
	game.hud.push_alert("Alert lifecycle probe", game.world.centre())
	var panel: Control = game.hud._alert_box.get_child(game.hud._alert_box.get_child_count() - 1)
	var created: Array[Tween] = []
	for tween in get_processed_tweens():
		if not previous.has(tween): created.append(tween)
	_check(created.size() == 2, "an alert creates its fade-in and delayed fade-out callbacks")
	game.hud.clear_alerts()
	await _settle_ui()
	var stopped := true
	for tween in created:
		stopped = stopped and not tween.is_valid()
	_check(not is_instance_valid(panel) and stopped,
		"clearing alerts kills their delayed callbacks before a freed panel can be captured")


func _run() -> void:
	# Keep every requested pointer location on the Xvfb display after resizing.
	root.position = Vector2i.ZERO
	var game := _new_game(42)
	game.process_mode = Node.PROCESS_MODE_ALWAYS
	game.set_process(false)
	game.camera.set_process(false)
	game.sim.stores.refresh_totals(game.sim.population_members(), game.sim.buildings)
	game.sim._update_stats()
	game.hud.refresh()
	await _toolbar(game)
	await _create_world(game)
	await _trade_controls(game)
	await _bridge_controls(game)
	await _lost_cart_controls(game)
	await _alert_cleanup(game)
	game.free()
	await _settle_ui()
	print("Connections UI regression failures: %d" % _failures)
	quit(1 if _failures else 0)
