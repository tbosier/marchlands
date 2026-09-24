extends "res://tests/expansion_ui.gd"

## Rendered coverage for cattle selection, resident armies and equipment.
## xvfb-run -a tools/godot_env.sh --path game --script res://tests/society_ui.gd


func _shot(name: String) -> void:
	await _settle_ui()
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/society_ui")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join(name + ".png")
	_check(root.get_texture().get_image().save_png(path) == OK, "saves rendered evidence " + name)
	print("SHOT ", path)


func _topbar(game: SeededGame, dimensions: Vector2i) -> void:
	var hud := game.hud
	var controls := hud._controls_row.get_global_rect()
	var population := hud._pop_label.get_global_rect()
	_check(hud._res_labels.size() == 7 and Config.RES_COUNT == 7,
			"all seven resource readouts exist at %s" % dimensions)
	var previous_end := 0.0
	for i in Config.RES_COUNT:
		var label: Label = hud._res_labels[i]
		var bounds := label.get_global_rect()
		_check(label.is_visible_in_tree() and bounds.position.x >= previous_end
				and bounds.end.x <= population.position.x and bounds.position.y >= 0.0
				and bounds.end.y <= HUD.TOP_BAR_H
				and label.text == str(int(game.sim.total_resource(i))),
				"%s stock is legible without overlapping another readout at %s" % [Res.display(i), dimensions])
		previous_end = bounds.end.x
	_check(population.end.x + 5.0 <= controls.position.x,
			"population and speed controls do not overlap at %s" % dimensions)
	for button in hud._speed_buttons:
		var bounds := button.get_global_rect()
		_check(bounds.position.x >= 0 and bounds.end.x <= dimensions.x
				and bounds.position.y >= 0 and bounds.end.y <= HUD.TOP_BAR_H,
				"speed %s remains fully visible at %s" % [button.text, dimensions])
	_check(hud._pop_label.get_tooltip(Vector2.ZERO).contains("%d civilians and %d soldiers" % [
			game.sim.citizens.size(), game.sim.campaign.friendly_ids().size()]),
			"population tooltip identifies civilians and soldiers at %s" % dimensions)


func _research_scroll(game: SeededGame, dimensions: Vector2i) -> void:
	await _click(_button(game.hud, "Research"))
	_check(game.research_open and game.hud._selection_actions.get_child_count() == 9,
			"Research opens all nine technologies at %s" % dimensions)
	_panel_fits(game, "Research %s" % dimensions)
	for i in RoadResearch.TECH_IDS.size():
		var action: Button = game.hud._selection_actions.get_child(i)
		game.hud._selection_scroll.ensure_control_visible(action)
		await _settle_ui()
		var viewport := game.hud._selection_scroll.get_global_rect()
		var bounds := action.get_global_rect()
		_check(viewport.encloses(bounds) and action.text.begins_with(
				RoadResearch.TECHS[RoadResearch.TECH_IDS[i]].name),
				"technology %s can be fully scrolled into view at %s" % [RoadResearch.TECH_IDS[i], dimensions])
	_check(game.hud._selection_scroll.scroll_vertical > 0,
			"nine-technology panel actually scrolls at %s" % dimensions)
	await _shot("research_%d" % dimensions.x)


func _run() -> void:
	var game := _new_game(42)
	game.process_mode = Node.PROCESS_MODE_ALWAYS
	game.set_process(false)
	game.camera.set_process(false)
	game.world.set_time_of_day(0.38)
	var sim := game.sim
	for resource in Config.RES_COUNT:
		sim.keep.inventory[resource] = 150.0
	var centre := game.world.centre()
	var market := _build(game, "market", centre + Vector3(40, 0, 38))
	var ranch := _build(game, "ranch", centre + Vector3(52, 0, -34))
	var barracks := _build(game, "barracks", centre + Vector3(-45, 0, -10))
	if market == null or ranch == null or barracks == null:
		game.free()
		quit(1)
		return
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	sim.stores.refresh_totals(sim.population_members(), sim.buildings)
	sim._update_stats()
	game.hud.refresh()
	var opening_people := sim.citizens.size()
	var cow: Cattle
	for candidate: Cattle in sim.husbandry.cows.values():
		if sim.husbandry.get_info(candidate.id).can_domesticate:
			cow = candidate
			break
	_check(cow != null and not ranch.workers.is_empty(), "a staffed ranch can receive a real wild cow")
	if cow != null:
		# A resident physically observes the herd before it can be inspected.
		sim.citizens[0].position = cow.position + Vector3(4, 0, 0)
		sim.scouting.refresh_visibility()
		game.camera.look_at_position(cow.position, 22.0)
		await physics_frame
		await _settle_ui()
		await _click_at(game.camera.camera().unproject_position(cow.position + Vector3(0, 1, 0)))
		_check(game.selected_cow == cow.id and game.hud._selection_title.text == "Wild cattle",
				"viewport cow pick opens its domestication panel")
		_panel_fits(game, "Wild cattle")
		await _shot("wild_cattle")
		await _click(_button(game.hud._selection_actions, "Send rancher"))
		var posted := false
		for job in sim.jobs.all_jobs():
			posted = posted or (job.kind == JobBoard.Kind.TAME and job.cow_id == cow.id)
		_check(cow.marked and posted and cow.ranch_id == -1 and not sim.research.ranching_known,
				"domestication click posts real rancher work before granting cattle or knowledge")
		var tame := _button(game.hud._selection_actions, "Send rancher")
		_check(tame != null and tame.disabled, "a pending domestication cannot be ordered twice")
	await _click(_button(game.hud, "Army"))
	await _click(_button(game.hud._selection_actions, "Recruit"))
	_check(sim.campaign.friendly_ids().size() == 1 and sim.citizens.size() == opening_people - 1,
			"Army recruit converts a resident into one soldier")
	if sim.campaign.friendly_ids().is_empty():
		game.free()
		quit(1)
		return
	var unit: Soldier = sim.campaign.units[sim.campaign.friendly_ids()[0]]
	sim._update_stats()
	game.hud.refresh()
	_check(game.hud._selection_body.text.contains("Civilians: %d · Soldiers: 1" % [opening_people - 1]),
			"Army panel reports the actual civilian and soldier split")
	for dimensions in [Vector2i(1280, 720), Vector2i(900, 600), Vector2i(640, 900)]:
		root.size = dimensions
		await _settle_ui()
		_topbar(game, dimensions)
		await _research_scroll(game, dimensions)
	root.size = Vector2i(900, 600)
	await _settle_ui()
	# The paid supply-chain suite earns these prerequisites. This viewport
	# fixture isolates clicking the final technology after scrolling.
	sim.research.discover_ranching()
	sim.research.completed.assign(["ranching", "leatherworking", "mail"])
	game._refresh_selection()
	var before := sim.keep.inventory.duplicate()
	await _click(_button(game.hud._selection_actions, "Plate armor"))
	_check(sim.research.active == "plate"
			and sim.keep.inventory[Config.Res.IRON] == before[Config.Res.IRON] - 35.0,
			"last scrolled technology starts paid Plate armor research through a real click")
	sim.research.advance(4.0)
	root.size = Vector2i(1280, 720)
	game._clear_selection()
	unit.position = sim.entrance_of(barracks, "att_cart_bay")
	unit.tick(0.0, game.world)
	game.camera.look_at_position(unit.position, 14.0)
	await physics_frame
	await _settle_ui()
	await _click_at(game.camera.camera().unproject_position(unit.position + Vector3(0, 0.9, 0)))
	_check(game.selected_units == [unit.id] and game.hud._selection_title.text == unit.given_name,
			"viewport soldier pick opens that resident's equipment panel")
	_check(game.hud._selection_actions.get_child_count() == 6,
			"friendly soldier panel offers all four armor choices and discharge")
	for tier in ["leather", "mail", "plate"]:
		before = sim.keep.inventory.duplicate()
		await _click(_button(game.hud._selection_actions, String(tier).capitalize()))
		var paid := true
		for resource in MilitaryEquipment.COSTS[tier]:
			paid = paid and sim.keep.inventory[resource] == before[resource] - MilitaryEquipment.COSTS[tier][resource]
		var visible_armor := unit._armor_visuals.size() == 6
		for visual in unit._armor_visuals:
			visible_armor = visible_armor and visual.is_visible_in_tree() and visual.get_child_count() > 0
		_check(unit.armor_tier == tier and paid and visible_armor
				and unit._sword.is_visible_in_tree() and unit._shield.is_visible_in_tree(),
				"%s click spends actual materials and renders armor with sword and shield" % tier)
		_check(_button(game.hud._selection_actions, String(tier).capitalize()).disabled,
				"equipped %s cannot be charged twice" % tier)
		await _shot("soldier_" + tier)
	for dimensions in [Vector2i(900, 600), Vector2i(640, 900)]:
		root.size = dimensions
		await _settle_ui()
		_panel_fits(game, "Soldier %s" % dimensions)
		await _shot("soldier_%d" % dimensions.x)
	await _click(_button(game.hud._selection_actions, "Remove armor"))
	_check(unit.armor_tier == "none" and unit._armor_visuals.is_empty(),
			"Remove armor click removes the visible suit")
	unit.receive_hit("arm_r", "slash", 80.0)
	game._refresh_selection()
	_check(game.hud._selection_body.text.contains("Sword arm: missing")
			and not unit._parts.arm_r.visible and not unit._sword.visible
			and unit._shield.is_visible_in_tree(),
			"soldier body and panel agree on missing limb and usable remaining equipment")
	await _shot("wounded_soldier")
	var body := unit.capture_body()
	await _click(_button(game.hud._selection_actions, "Return to civilian life"))
	_check(sim.campaign.friendly_ids().is_empty() and sim.citizens.size() == opening_people
			and sim.citizens_by_id.get(unit.id) == unit and unit.capture_body() == body
			and not unit._sword.visible and not unit._shield.visible,
			"discharge click returns the wounded person to civilian life with injuries intact")
	sim._update_stats()
	game.hud.refresh()
	await _click(_button(game.hud, "Army"))
	_check(game.hud._selection_body.text.contains("Civilians: %d · Soldiers: 0" % opening_people)
			and game.hud._pop_label.get_tooltip(Vector2.ZERO).contains("%d civilians and 0 soldiers" % opening_people),
			"Army and population readouts update after discharge")
	await _shot("discharged")
	game.free()
	await _settle_ui()
	print("Society UI regression failures: %d" % _failures)
	quit(1 if _failures else 0)
