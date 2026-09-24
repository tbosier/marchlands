extends "res://tests/navigation.gd"

## Native model contract plus real paid hauling and construction. Rendered
## runs additionally record the blueprint and both sides of the completed well.
var _well: Building
var _camera: Camera3D


func _capture(label: String) -> void:
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var directory := ProjectSettings.globalize_path("res://../artifacts/wells")
	DirAccess.make_dir_recursive_absolute(directory)
	_check(image.save_png(directory.path_join(label + ".png")) == OK,
			"saved well screenshot " + label)


func _view() -> void:
	root.size = Vector2i(640, 480)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 8.0
	_world.add_child(_camera)
	_camera.position = _well.position + Vector3(7, 6, 9)
	_camera.look_at(_well.position + Vector3(0, 1.7, 0))
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.13, 0.18, 0.23)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.85, 0.88, 1)
	environment.ambient_light_energy = 0.65
	_camera.environment = environment
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	_world.add_child(sun)


func _run() -> void:
	_registry.load_all()
	_flat_world()
	var definition := BuildingDefs.get_def("well")
	_check(definition != null and BuildingDefs.buildable().has("well")
			and definition.icon() != null and BuildingDefs.validate(_registry).is_empty(),
			"well is offered with its own tracked icon and valid native asset")
	var mesh := _registry.mesh("well")
	var bounds := mesh.get_aabb()
	_check(bounds.position.x >= -2.5 and bounds.end.x <= 2.5
			and bounds.position.z >= -2.5 and bounds.end.z <= 2.5
			and bounds.position.y >= -0.001 and bounds.end.y <= _registry.height("well")
			and mesh.get_surface_count() == 7,
			"stone ring, roof, winch and bucket fit the declared well footprint and height")
	var keep := _sim.place_building("keep", Vector3(200, 9, 200), 0, true)
	# Exactly the price, read from the definition, so the check below can ask
	# for every unit to have been carried to the site.
	var well_cost: Dictionary = BuildingDefs.get_def("well").cost
	keep.inventory[Config.Res.TIMBER] = float(well_cost[Config.Res.TIMBER])
	keep.inventory[Config.Res.STONE] = float(well_cost[Config.Res.STONE])
	var site := Vector3(236, 9, 200)
	_check(_sim.research.completed.is_empty() and _sim.can_place("well", site).ok,
			"basic water access needs no research")
	_well = _sim.place_building("well", site, 0)
	var door := _sim.entrance_of(_well, "att_entrance")
	var cell := _world.world_to_cell(door)
	_check(not _world.nav.is_solid(cell.x, cell.y)
			and door.distance_to(_well.position) > 2.5
			and _world.nav.can_reach(_sim.entrance_of(keep, "att_entrance"), door),
			"drinkers and builders can reach a doorway beyond the blocked stone ring")
	_check(_well.under_construction and _well._blueprint.visible
			and _well._body.get_meta("building_id") == _well.id,
			"ordered well is a selectable construction ghost")
	var rendered := DisplayServer.get_name() != "headless"
	if rendered:
		_view()
		await _capture("blueprint")
	for i in 2:
		var citizen := _sim.add_citizen(Vector3(222 + i, 9, 210))
		citizen.next_meal = 1000.0
		citizen.speed_scale = 1.0
	_sim._is_night = false
	var carried := false
	var labour := false
	for i in 4500:
		_sim.production.tick(0.1, _sim.buildings)
		for citizen in _sim.citizens:
			_sim._tick_citizen(citizen, 0.1)
			carried = carried or citizen.carrying_amount > 0.0
		labour = labour or (_well.build_progress > 0.0 and _well.build_progress < 1.0)
		if not _well.under_construction: break
	if _well.under_construction:
		print("WELL_PENDING delivered=%s incoming=%s stock=%s jobs=%d carried=%s labour=%s" %
				[_well.delivered, _well.incoming, keep.inventory, _sim.jobs.all_jobs().size(), carried, labour])
		for citizen in _sim.citizens:
			print("WELL_WORKER state=%s task=%s position=%s unreachable=%s" %
					[citizen.state, citizen.task_label, citizen.position, citizen.unreachable])
	_check(carried and labour and not _well.under_construction,
			"real citizens haul both materials and perform labour to complete the well")
	_check(keep.inventory[Config.Res.TIMBER] == 0.0 and keep.inventory[Config.Res.STONE] == 0.0
			and _well.delivered[Config.Res.TIMBER] == float(well_cost[Config.Res.TIMBER])
			and _well.delivered[Config.Res.STONE] == float(well_cost[Config.Res.STONE]),
			"completed well accounts for every supplied timber and stone")
	_check(_well._visual.visible and (_well._blueprint == null or not _well._blueprint.visible),
			"completion replaces the translucent blueprint with the finished model")
	if rendered:
		await _capture("completed_front")
		_camera.position = _well.position + Vector3(-7, 5, -9)
		_camera.look_at(_well.position + Vector3(0, 1.7, 0))
		await _capture("completed_rear")
	_sim.free()
	_world.free()
	await process_frame
	print("Well visual regression failures: %d" % _failures)
	quit(1 if _failures else 0)
