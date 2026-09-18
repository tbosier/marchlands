extends Node3D

## Marchlands — root controller.
##
## Owns the world, the simulation, the camera and the interface, and handles
## the player's two verbs: placing a building, and improving a route.
##
## The opening scenario is the one in design doc 26: a keep, a few houses, a
## stockpile and twenty citizens, with forest to the east, stone to the north
## and good farmland to the south.

const START_FOOD := 200.0
const START_TOOLS := 50.0
const START_TIMBER := 40.0
const START_STONE := 20.0

enum Mode { SELECT, PLACE, CLEAR }

var registry := AssetRegistry.new()
var clock := Clock.new()
var world: World
var sim: Simulation
var camera: RTSCamera
var hud: HUD

var mode := Mode.SELECT
var place_type := ""
var place_yaw := 0.0
var place_valid := false
var place_position := Vector3.ZERO
var _ghost: Node3D
var _ghost_ok_material: StandardMaterial3D
var _ghost_bad_material: StandardMaterial3D

var selected_building: Building = null
var selected_citizen: Citizen = null
var selected_road := Vector3.ZERO
var has_road_selection := false
## `route_extent` is a flood fill over thousands of texels. The road panel is
## refreshed four times a second for as long as a route stays selected, so the
## answer is worked out once per selection rather than per refresh.
var _road_extent_at := Vector3.INF
var _road_extent := 0

var dev: DevOverlay
var dev_mode := false
var show_nav_overlay := false

## How far from the cursor the clear-ground tool reaches, in metres.
const CLEAR_BRUSH := 9.0

var _ui_timer := 0.0
var _screenshot_script := ""


func _ready() -> void:
	randomize()
	var world_seed := _seed_from_args()

	registry.load_all()
	if not registry.missing.is_empty():
		push_warning("Missing assets: %s" % str(registry.missing))
	for problem in BuildingDefs.validate(registry):
		push_error("BuildingDefs: %s" % problem)

	_build_world_and_sim(world_seed)

	camera = RTSCamera.new()
	camera.name = "camera_rig"
	add_child(camera)
	camera.bind_terrain(world.heightmap)

	var layer := CanvasLayer.new()
	layer.name = "ui"
	add_child(layer)
	hud = HUD.new()
	hud.name = "hud"
	layer.add_child(hud)
	hud.setup(sim, clock)
	hud.build_requested.connect(_on_build_requested)
	hud.build_cancelled.connect(_cancel_placement)
	hud.speed_requested.connect(func(i): clock.set_speed(i))
	hud.upgrade_route_requested.connect(request_route_upgrade)
	hud.demolish_requested.connect(_on_demolish_requested)
	hud.upgrade_requested.connect(_on_upgrade_requested)
	hud.clear_ground_requested.connect(_toggle_clear_tool)
	hud.focus_requested.connect(func(p): camera.focus_on(p, 70.0))

	dev = DevOverlay.new()
	dev.name = "dev_overlay"
	layer.add_child(dev)
	dev.setup(sim, clock, world, camera)

	_make_ghost_materials()
	_setup_scenario()

	for arg in OS.get_cmdline_user_args():
		if arg == "--dev":
			dev_mode = true
			dev.visible = true

	camera.look_at_position(sim.keep.global_position, 78.0)
	world.set_time_of_day(clock.day_fraction(), clock.season_fraction())

	_run_harness()


## Everything that is specific to one march, as opposed to one session. Held
## apart from _ready so that loading a save can replace the world and the
## simulation without disturbing the camera, the interface or the dev overlay.
func _build_world_and_sim(world_seed: int) -> void:
	world = World.new()
	world.name = "world"
	add_child(world)
	world.generate(registry, world_seed)

	sim = Simulation.new()
	sim.name = "simulation"
	add_child(sim)
	sim.setup(world, registry, world_seed)
	sim.alert.connect(_on_alert)


func _seed_from_args() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			return int(arg.substr(7))
	return 20260911


# ---------------------------------------------------------------------------
# Saving and loading
# ---------------------------------------------------------------------------

## Returns "" on success, or the reason it failed.
func save_game(slot: String = SaveGame.QUICK_SLOT) -> String:
	# Settle the world before writing it down. Road levels are a cache over the
	# wear field refreshed on a timer, so a save taken inside that window
	# records a march whose road graph lags its own history by a couple of
	# seconds — and since loading rebuilds the cache from scratch, the march
	# came back with a road the saved one did not have.
	var settled := world.wear.refresh_levels()
	if not settled.is_empty():
		world.nav.apply_road_changes(settled)
		sim.jobs.clear_refusals()
	var problem := SaveGame.write(self, slot)
	if problem == "":
		_on_alert("Saved as '%s'" % slot, camera.focus)
	else:
		_on_alert("Could not save: %s" % problem, camera.focus)
	return problem


## Returns "" on success, or the reason it failed.
func load_game(slot: String = SaveGame.QUICK_SLOT) -> String:
	var problems: Array[String] = []
	var data := SaveGame.read(slot, problems)
	if data.is_empty():
		var why: String = problems[0] if not problems.is_empty() else "unknown"
		_on_alert("Could not load: %s" % why, camera.focus)
		return why
	restore_from(data)
	_on_alert("Loaded '%s' — day %d" % [slot, int(data.get("day", 0)) + 1],
			camera.focus)
	return ""


## Replace the current march with a saved one, in place.
##
## The world and the simulation are thrown away and rebuilt from the save's
## seed, which is both simpler and safer than unpicking a running settlement:
## every system has a correct construction path and has been exercised by every
## session ever played, whereas a repopulate-in-place path would be new code on
## the one operation you cannot afford to get subtly wrong.
##
## The camera, the interface and the dev overlay survive: the view stays where
## the player left it, and whatever they had open stays open.
func restore_from(data: Dictionary) -> void:
	_cancel_placement()
	_exit_clear_tool()
	_clear_selection()

	# Freed outright rather than queued: the replacements take the same node
	# names, and a queued node still holds its name until the end of the frame.
	remove_child(sim)
	sim.free()
	remove_child(world)
	world.free()

	_build_world_and_sim(int(data.get("seed", world_seed_fallback())))
	# The camera and interface outlived the world they were pointed at.
	camera.bind_terrain(world.heightmap)
	hud.setup(sim, clock)
	dev.setup(sim, clock, world, camera)

	SaveGame.restore(self, data)

	# The camera is only moved when where it was looking makes no sense any
	# more — a save loaded over a session the player had panned somewhere else
	# entirely. Snapping to the keep on every load would throw away the view
	# they had set up.
	if sim.keep and camera.focus.distance_to(sim.keep.global_position) > 400.0:
		camera.look_at_position(sim.keep.global_position, camera.distance)
	world.set_time_of_day(clock.day_fraction(), clock.season_fraction())
	hud.refresh()


## The seed to fall back on when a save does not name one. Only reachable via a
## hand-edited file; a real save always carries its seed.
func world_seed_fallback() -> int:
	return _seed_from_args()


# ---------------------------------------------------------------------------
# Opening scenario (design doc 26)
# ---------------------------------------------------------------------------

## Radius of ground cleared for the opening settlement, in metres.
const START_CLEARING := 46.0


func _setup_scenario() -> void:
	var centre := world.centre()

	# The march has been held long enough to have cleared its own ground.
	var felled := world.nodes.clear_area(centre, START_CLEARING)
	for rec in world.nodes.records:
		if rec.depleted and rec.kind != ResourceNodes.Kind.TREE:
			var c := Config.world_to_cell(rec.position)
			world.nav.set_blocked(c.x, c.y, false)
	var keep := sim.place_building("keep", centre, PI, true)
	keep.inventory[Config.Res.FOOD] = START_FOOD
	keep.inventory[Config.Res.TOOLS] = START_TOOLS
	keep.inventory[Config.Res.TIMBER] = START_TIMBER
	keep.inventory[Config.Res.STONE] = START_STONE

	# Four houses and a stockpile, loosely grouped south of the keep so the
	# settlement has somewhere to be before the player touches anything.
	var rng := RandomNumberGenerator.new()
	rng.seed = world.world_seed + 7
	var house_spots := [
		Vector3(-19, 0, 21), Vector3(-6, 0, 26),
		Vector3(9, 0, 24), Vector3(21, 0, 16),
	]
	for offset in house_spots:
		var p: Vector3 = centre + (offset as Vector3)
		p = _settle(p)
		sim.place_building("house", p, PI + rng.randf_range(-0.35, 0.35), true)

	var stock := _settle(centre + Vector3(16, 0, -6))
	sim.place_building("stockpile", stock, PI * 0.5, true)

	# The settlement's one cart, parked at the stockpile's loading bay.
	var cart := Cart.new()
	world.effects_root.add_child(cart)
	var bay := stock + Vector3(4.5, 0, 4.5)
	bay.y = world.heightmap.height_at(bay.x, bay.z)
	cart.setup(registry, bay)
	sim.set_cart(cart)

	for i in Config.START_CITIZENS:
		var a := TAU * i / float(Config.START_CITIZENS)
		var r := rng.randf_range(10.0, 22.0)
		sim.add_citizen(centre + Vector3(cos(a) * r, 0, sin(a) * r + 14.0))

	sim.workforce.mark_all_dirty()
	hud.refresh()


## Nudge a proposed position to somewhere actually buildable nearby.
func _settle(p: Vector3) -> Vector3:
	p.y = world.heightmap.height_at(p.x, p.z)
	var c := Config.world_to_cell(p)
	if world.heightmap.cell_slope(c.x, c.y) < Config.MAX_BUILD_SLOPE \
			and world.heightmap.cell_surface(c.x, c.y) != Heightmap.Surface.WATER:
		return p
	for r in range(1, 10):
		for a in 12:
			var ang := TAU * a / 12.0
			var q := p + Vector3(cos(ang) * r * 4.0, 0, sin(ang) * r * 4.0)
			var qc := Config.world_to_cell(q)
			if world.heightmap.cell_slope(qc.x, qc.y) < Config.MAX_BUILD_SLOPE \
					and world.heightmap.cell_surface(qc.x, qc.y) \
						!= Heightmap.Surface.WATER:
				q.y = world.heightmap.height_at(q.x, q.z)
				return q
	return p


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var sim_delta := clock.advance(delta)
	if sim_delta > 0.0:
		# At high speeds a single frame can represent several seconds of world
		# time. Stepping it in slices keeps movement and wear accumulation
		# accurate instead of letting citizens teleport past their waypoints.
		var remaining := sim_delta
		while remaining > 0.0:
			var step: float = minf(remaining, Config.MAX_SIM_STEP)
			sim.tick(step)
			remaining -= step
		world.set_time_of_day(clock.day_fraction(), clock.season_fraction())

	# Once per rendered frame, whatever the simulation did in between.
	world.wear.flush_texture()

	if mode == Mode.PLACE:
		_update_ghost()

	_ui_timer -= delta
	if _ui_timer <= 0.0:
		_ui_timer = 0.25
		hud.refresh()
		_refresh_selection()

	Perf.flush_frame()


func _refresh_selection() -> void:
	if selected_building != null and is_instance_valid(selected_building):
		hud.show_building(selected_building)
	elif selected_citizen != null and is_instance_valid(selected_citizen):
		hud.show_citizen(selected_citizen)
	elif has_road_selection:
		hud.show_road(_road_info(selected_road))


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				clock.toggle_pause()
				hud.refresh()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				clock.set_speed(event.keycode - KEY_1 + 1)
				hud.refresh()
			KEY_BRACKETLEFT:
				clock.set_speed(clock.speed_index - 1)
				hud.refresh()
			KEY_BRACKETRIGHT:
				clock.set_speed(clock.speed_index + 1)
				hud.refresh()
			KEY_ESCAPE:
				if mode == Mode.CLEAR:
					_exit_clear_tool()
				elif mode == Mode.PLACE:
					_cancel_placement()
				elif selected_building or selected_citizen or has_road_selection:
					_clear_selection()
				else:
					hud.clear_alerts()
			KEY_R:
				if mode == Mode.PLACE:
					place_yaw += PI * 0.25
			KEY_F:
				_focus_selection()
			KEY_B:
				hud.set_tray_open(not hud.tray_is_open())
			KEY_C:
				_toggle_clear_tool()
			KEY_DELETE:
				if selected_building:
					_on_demolish_requested(selected_building)
			KEY_S:
				if event.ctrl_pressed:
					save_game()
			KEY_L:
				if event.ctrl_pressed:
					load_game()
			KEY_F12:
				_save_screenshot("manual")
			KEY_F3:
				dev_mode = not dev_mode
				dev.toggle()
			KEY_F4: _dev_spawn_settlers(10)
			KEY_F5: _dev_finish_buildings()
			KEY_F6: _dev_grant_resources(300.0)
			KEY_F7: _dev_wear_route()
			KEY_F8: _dev_toggle_nav_overlay()
			KEY_F9:
				Perf.reset()

	elif event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event
		if hud.blocks_mouse(mb.position):
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			match mode:
				Mode.PLACE: _try_place()
				Mode.CLEAR: _order_clear_at(mb.position)
				_: _pick_at(mb.position)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mode == Mode.PLACE:
				_cancel_placement()
			elif mode == Mode.CLEAR:
				_exit_clear_tool()
			else:
				_clear_selection()


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

## The two states of the placement ghost.
##
## The ghost used to be a lit, half-transparent solid, which put it in exactly
## the wrong register: the sun modelled it like a real building, so its value
## moved with wherever the cursor happened to be. In
## design/screenshots/construction.png the result is a pale blue box you have
## to look for. A proposal is not a building yet and should not pretend to be
## one. These are unshaded, so the ghost holds one constant value wherever the
## cursor takes it — a drawing laid over the world rather than an object
## standing in it.
func _make_ghost_materials() -> void:
	_ghost_ok_material = _ghost_material(Color(0.52, 0.88, 0.62))
	_ghost_bad_material = _ghost_material(Color(0.94, 0.38, 0.34))


func _ghost_material(tint: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.46)
	# Both faces, so the far wall shows through the near one and the ghost
	# reads as a volume being proposed rather than a flat silhouette.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Sorted after the other transparent surfaces in the scene — the water
	# chiefly — so a ghost placed at the lake's edge draws over it rather than
	# under it. It does not defeat the depth buffer: a ghost behind a hill is
	# still hidden by the hill, which is correct.
	mat.render_priority = 1
	return mat


func _on_build_requested(type_id: String) -> void:
	_clear_selection()
	_exit_clear_tool()
	mode = Mode.PLACE
	place_type = type_id
	place_yaw = PI
	_spawn_ghost()


func _spawn_ghost() -> void:
	if _ghost:
		_ghost.queue_free()
	var def := BuildingDefs.get_def(place_type)
	_ghost = registry.instantiate(def.asset, 0)
	_ghost.name = "placement_ghost"
	world.effects_root.add_child(_ghost)


## The clear-ground tool: click trees to have them felled.
func _toggle_clear_tool() -> void:
	if mode == Mode.CLEAR:
		_exit_clear_tool()
		return
	_cancel_placement()
	_clear_selection()
	mode = Mode.CLEAR
	hud.set_clear_tool_active(true)
	hud.set_hint("Click trees to have them felled · right click / Esc to stop")


func _exit_clear_tool() -> void:
	if mode == Mode.CLEAR:
		mode = Mode.SELECT
	hud.set_clear_tool_active(false)
	hud.set_hint("WASD pan · wheel zoom · middle-drag rotate · click to select")


func _order_clear_at(screen_pos: Vector2) -> void:
	var ray := camera.screen_ray(screen_pos)
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"]:
		return
	var p: Vector3 = hit["position"]
	# A generous radius: clicking a single trunk at play zoom is unreasonable,
	# and clearing is an area instruction anyway.
	var marked := 0
	for rec in world.nodes.records:
		if rec.kind != ResourceNodes.Kind.TREE or rec.depleted:
			continue
		if rec.position.distance_to(p) > CLEAR_BRUSH:
			continue
		if sim.order_felling(rec):
			marked += 1
	if marked > 0:
		hud.set_hint("%d tree%s marked for felling"
				% [marked, "" if marked == 1 else "s"])


func _on_demolish_requested(b: Building) -> void:
	if b == null or not is_instance_valid(b):
		return
	var allowed := sim.can_demolish(b)
	if not allowed["ok"]:
		hud.set_hint(String(allowed["reason"]))
		return
	var was_blueprint := b.under_construction
	var name := b.display_name()
	var result := sim.demolish(b)
	_clear_selection()

	var verb := "cancelled" if was_blueprint else "pulled down"
	var parts: Array[String] = []
	for res in result["refunded"]:
		if float(result["refunded"][res]) > 0.5:
			parts.append("%d %s" % [int(result["refunded"][res]),
					Res.display(res)])
	var lost: Array[String] = []
	for res in result["lost"]:
		lost.append("%d %s" % [int(result["lost"][res]), Res.display(res)])

	var text := "%s %s" % [name, verb]
	if not parts.is_empty():
		text += " — %s returned" % ", ".join(parts)
	if not lost.is_empty():
		# Say so. Claiming a full refund the stores could not absorb is a lie
		# the player would only discover by counting.
		text += " · %s lost, nowhere to store it" % ", ".join(lost)
	_on_alert(text, camera.focus)
	hud.refresh()


func _cancel_placement() -> void:
	mode = Mode.SELECT
	place_type = ""
	if _ghost:
		_ghost.queue_free()
		_ghost = null
	hud.set_active_build("")
	hud.hide_cursor_tooltip()


func _update_ghost() -> void:
	if _ghost == null:
		return
	var mouse := get_viewport().get_mouse_position()
	if hud.blocks_mouse(mouse):
		_ghost.visible = false
		hud.hide_cursor_tooltip()
		return
	_ghost.visible = true

	var ray := camera.screen_ray(mouse)
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"]:
		_ghost.visible = false
		return

	place_position = hit["position"]
	_ghost.global_position = place_position
	_ghost.rotation.y = place_yaw

	var check := sim.can_place(place_type, place_position, place_yaw)
	var def := BuildingDefs.get_def(place_type)
	var cost := def.cost
	var affordable := sim.can_afford(cost)
	place_valid = bool(check["ok"]) and affordable

	for child in _ghost.get_children():
		if child is MeshInstance3D:
			child.material_override = _ghost_ok_material if place_valid \
					else _ghost_bad_material

	_show_placement_tooltip(check, affordable, cost, mouse)


## Everything the design doc asks placement to tell the player: footprint,
## slope, cost, access, and how far workers would have to walk.
func _show_placement_tooltip(check: Dictionary, affordable: bool,
							 cost: Dictionary, mouse: Vector2) -> void:
	var def := BuildingDefs.get_def(place_type)
	var fp: Vector2 = check.get("footprint", Vector2(4, 4))
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % def.display_name)
	lines.append("Footprint  %.1f x %.1f m" % [fp.x, fp.y])

	var slope := float(check.get("slope", 0.0))
	var slope_colour := "#9ec983" if slope < 0.22 else (
			"#e0a85c" if slope <= Config.MAX_BUILD_SLOPE else "#d97368")
	lines.append("Slope  [color=%s]%d%%[/color]"
			% [slope_colour, int(slope * 100.0)])

	if not cost.is_empty():
		var cost_colour := "#9ec983" if affordable else "#d97368"
		lines.append("Cost  [color=%s]%s[/color]"
				% [cost_colour, BuildingDefs.cost_text(place_type)])

	# Travel time for the nearest worker — distance is the enemy (design 2.3).
	var nearest := _nearest_citizen(place_position)
	if nearest != null:
		var d := nearest.global_position.distance_to(place_position)
		lines.append("Nearest worker  %d m (~%ds walk)"
				% [int(d), int(d / Config.WALK_SPEED)])

	var store: Building = sim.stores.find_store(
			Config.Res.TIMBER, place_position, -1)
	if store != null:
		var d2: float = store.global_position.distance_to(place_position)
		lines.append("Storage  %s, %d m" % [store.display_name(), int(d2)])

	var road := world.wear.road_level_at(place_position.x, place_position.z)
	lines.append("Ground  %s" % Config.ROAD_NAMES[road])

	if not check["ok"]:
		lines.append("[color=#d97368]Cannot build: %s[/color]"
				% check["reason"])
	elif not affordable:
		lines.append("[color=#d97368]Cannot afford[/color]")

	hud.show_cursor_tooltip(lines, mouse)


func _nearest_citizen(p: Vector3) -> Citizen:
	var best: Citizen = null
	var best_d := INF
	for c in sim.citizens:
		if c.immigrant:
			continue
		var d := c.global_position.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = c
	return best


func _try_place() -> void:
	if not place_valid:
		return
	var def := BuildingDefs.get_def(place_type)
	var cost := def.cost
	# Nothing is deducted here. A blueprint's cost is the materials haulers
	# physically carry to the site (design doc 6.3), so the stock is spent when
	# it is loaded, not when the player clicks. Affordability is still checked,
	# so you cannot queue a building the kingdom has no hope of supplying.
	if not sim.can_afford(cost):
		return
	var b := sim.place_building(place_type, place_position, place_yaw)
	_on_alert("%s sited" % b.display_name(), b.global_position)

	# The tool stays armed: placing four houses should be four clicks, not four
	# trips to the build bar. Right click or Escape puts it away.
	if sim.can_afford(cost):
		_spawn_ghost()
	else:
		_cancel_placement()
		hud.set_hint("Not enough materials for another %s" % def.display_name)
	hud.refresh()


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _clear_selection() -> void:
	selected_building = null
	selected_citizen = null
	has_road_selection = false
	hud.clear_selection()


func _pick_at(screen_pos: Vector2) -> void:
	var ray := camera.screen_ray(screen_pos)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			ray["origin"], ray["origin"] + ray["direction"] * 3000.0)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 2 | 4
	var result := space.intersect_ray(query)

	if not result.is_empty():
		var collider: Node = result["collider"]
		if collider.has_meta("building_id"):
			_clear_selection()
			selected_building = sim.buildings_by_id.get(
					collider.get_meta("building_id"))
			if selected_building:
				hud.show_building(selected_building)
				return
		elif collider.has_meta("citizen_id"):
			_clear_selection()
			selected_citizen = sim.citizens_by_id.get(
					collider.get_meta("citizen_id"))
			if selected_citizen:
				hud.show_citizen(selected_citizen)
				return

	# Nothing solid: the player clicked the ground, which selects the route
	# there — this is how worn paths become something you can act on.
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"]:
		_clear_selection()
		return
	_clear_selection()
	selected_road = hit["position"]
	has_road_selection = true
	hud.show_road(_road_info(selected_road))


func _road_info(p: Vector3) -> Dictionary:
	var wear := world.wear.wear_at(p.x, p.z)
	var level := Config.road_level_for_wear(wear)
	var cost := {
		Config.Res.TIMBER: Config.UPGRADE_COST_TIMBER,
		Config.Res.STONE: Config.UPGRADE_COST_STONE,
	}
	if p.distance_squared_to(_road_extent_at) > 0.01:
		_road_extent_at = p
		_road_extent = world.wear.route_extent(p, 6000)
	return {
		"wear": wear,
		"level": level,
		"position": p,
		"extent": _road_extent,
		"affordable": sim.can_afford(cost),
		"locked": world.wear.locked[
			clampi(int(p.z / Config.WEAR_CELL), 0, Config.WEAR_RES - 1)
			* Config.WEAR_RES
			+ clampi(int(p.x / Config.WEAR_CELL), 0, Config.WEAR_RES - 1)],
	}


func request_route_upgrade() -> void:
	if not has_road_selection:
		return
	var info := _road_info(selected_road)
	var level: int = info["level"]
	if level < Config.RoadLevel.WORN or level >= Config.RoadLevel.PAVED:
		return
	var cost := {
		Config.Res.TIMBER: Config.UPGRADE_COST_TIMBER,
		Config.Res.STONE: Config.UPGRADE_COST_STONE,
	}
	if not sim.stores.try_spend(cost):
		return
	var next: int = level + 1
	# The paved stretch is a different shape from the worn one that was there.
	_road_extent_at = Vector3.INF
	var changed := world.wear.upgrade_route(selected_road, next)
	world.nav.apply_road_changes(world.wear.refresh_levels())
	world.wear.flush_texture()
	_on_alert("Route improved to %s" % Config.ROAD_NAMES[next], selected_road)
	hud.show_road(_road_info(selected_road))
	hud.refresh()


func _focus_selection() -> void:
	if selected_building:
		camera.focus_on(selected_building.global_position, 55.0)
	elif selected_citizen:
		camera.focus_on(selected_citizen.global_position, 28.0)
	elif has_road_selection:
		camera.focus_on(selected_road, 45.0)


## Grow a building into its next tier (design doc 6.4).
func _on_upgrade_requested(b: Building) -> void:
	if b == null or not is_instance_valid(b):
		return
	var result := sim.upgrade(b)
	if not result["ok"]:
		_on_alert("Cannot upgrade %s: %s"
				% [b.display_name(), result["reason"]], b.global_position)
		return
	# The panel is showing the building it used to be.
	hud.show_building(b)
	hud.refresh()


func _on_alert(text: String, position: Vector3) -> void:
	hud.push_alert(text, position)


# ---------------------------------------------------------------------------
# Developer commands
#
# Gated behind dev mode so a stray function key during normal play cannot
# quietly rewrite the settlement.
# ---------------------------------------------------------------------------

func _dev_guard() -> bool:
	if dev_mode:
		return true
	hud.set_hint("Developer tools are off — press F3 to enable them")
	return false


func _dev_spawn_settlers(count: int) -> void:
	if not _dev_guard():
		return
	var origin := sim.keep.global_position if sim.keep else world.centre()
	for i in count:
		var a := TAU * i / float(count)
		sim.add_citizen(origin + Vector3(cos(a) * 14.0, 0, sin(a) * 14.0))
	_on_alert("%d settlers conjured" % count, origin)


func _dev_finish_buildings() -> void:
	if not _dev_guard():
		return
	var n := 0
	for b in sim.buildings.duplicate():
		if b.under_construction:
			for res in b.build_cost:
				b.deliver_material(res, float(b.build_cost[res]))
			b.finish_construction()
			# Go through the simulation's own completion path rather than
			# repeating two of its five steps. Skipping it left the site's
			# build order — the highest priority job in the game — on the board
			# for ever, and every idle pair of hands near it kept claiming a
			# job for a building that was already finished.
			sim._on_building_completed(b)
			n += 1
	sim.workforce.mark_all_dirty()
	_on_alert("%d buildings completed" % n, camera.focus)


func _dev_grant_resources(amount: float) -> void:
	if not _dev_guard():
		return
	if sim.keep == null:
		return
	for res in Config.RES_COUNT:
		sim.keep.inventory[res] += amount
	_on_alert("granted %d of every resource" % int(amount),
			sim.keep.global_position)


## Stamp enough traffic under the cursor to force a route into existence,
## for testing the road system without waiting for citizens to wear one.
func _dev_wear_route() -> void:
	if not _dev_guard():
		return
	var ray := camera.screen_ray(get_viewport().get_mouse_position())
	var hit := world.terrain.raycast(ray["origin"], ray["direction"])
	if not hit["hit"]:
		return
	var p: Vector3 = hit["position"]
	world.wear.stamp_point(p.x, p.z, Config.ROAD_THRESHOLD[
			Config.RoadLevel.DIRT] * 1.2, 3.0)
	world.nav.apply_road_changes(world.wear.refresh_levels())
	world.wear.flush_texture()
	_on_alert("route worn in", p)


func _dev_toggle_nav_overlay() -> void:
	if not _dev_guard():
		return
	show_nav_overlay = not show_nav_overlay
	world.set_nav_overlay(show_nav_overlay)


# ---------------------------------------------------------------------------
# Screenshot / automation harness
# ---------------------------------------------------------------------------

## Lets the build pipeline drive the game headlessly and capture frames, which
## is how the project verifies that changes actually look right.
func _run_harness() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--harness="):
			_screenshot_script = arg.substr(10)
	if _screenshot_script == "":
		return
	var harness: Node = load("res://scripts/core/harness.gd").new()
	harness.name = "harness"
	add_child(harness)
	harness.run(self, _screenshot_script)


func _save_screenshot(tag: String) -> String:
	var image := get_viewport().get_texture().get_image()
	var dir := "user://screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s_%d.png" % [dir, tag, Time.get_ticks_msec()]
	image.save_png(path)
	print("screenshot: ", ProjectSettings.globalize_path(path))
	return ProjectSettings.globalize_path(path)
