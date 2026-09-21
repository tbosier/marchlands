extends SceneTree

## Headless: boundary continuity, camera clearance, ore materials and picking.
## Add -- --world-presentation-shots on a real renderer for review screenshots.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1


func _flat_heightmap() -> Heightmap:
	var hm := Heightmap.new()
	hm.heights.resize(Heightmap.N * Heightmap.N)
	hm.heights.fill(9.0)
	hm.surface.resize(Config.GRID * Config.GRID)
	hm.surface.fill(Heightmap.Surface.GRASS)
	hm.fertility.resize(Config.GRID * Config.GRID)
	hm.fertility.fill(0.5)
	return hm


func _boundary() -> void:
	var hm := _flat_heightmap()
	for i in Heightmap.N:
		hm.heights[i] = 9.0 + sin(float(i) * 0.4) * 8.0
	var before := hm.heights.duplicate()
	var terrain := Terrain.new()
	root.add_child(terrain)
	terrain.build(hm, WearField.new())
	var arrays := terrain._backdrop.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var triangles: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var north := {}
	var outside_only := true
	var winding := true
	for p in vertices:
		if p.z == 0.0 and p.x >= 0.0 and p.x <= Config.WORLD_SIZE:
			north[roundi(p.x / Config.CELL)] = p.y
	for i in range(0, triangles.size(), 3):
		var a := vertices[triangles[i]]
		var b := vertices[triangles[i + 1]]
		var c := vertices[triangles[i + 2]]
		var centre := (a + b + c) / 3.0
		outside_only = outside_only and (centre.x < 0.0 or centre.x > Config.WORLD_SIZE \
				or centre.z < 0.0 or centre.z > Config.WORLD_SIZE)
		winding = winding and (b - a).cross(c - a).y < 0.0
	var joined := north.size() == Heightmap.N
	for i in Heightmap.N:
		joined = joined and north.has(i) and is_equal_approx(north.get(i, INF), hm.corner(i, 0))
	_check(joined, "backdrop meets every uneven north-edge sample without cracks")
	_check(outside_only and winding, "backdrop faces upward and adds no geometry inside playable map")
	_check(hm.heights == before, "boundary scenery leaves playable heightfield unchanged")
	_check(Terrain.presentation_height(hm, -Terrain.BACKDROP_WIDTH, 200) < Config.SEA_LEVEL,
			"outer backdrop finishes beneath the water")
	var water_extent: Vector2 = terrain._water.mesh.size
	_check(water_extent.x * 0.5 - Config.WORLD_SIZE * 0.5 > 2200.0 + RTSCamera.MAX_DIST,
			"water rim stays beyond the camera far plane at any orbit position")
	_check(terrain._seabed.mesh.size == water_extent and terrain._seabed.position.y < Terrain.BACKDROP_FLOOR,
			"transparent off-map water has a continuous opaque seabed")
	_check(not terrain.raycast(Vector3(-8, 80, 100), Vector3.DOWN).hit,
			"decorative off-map terrain cannot become a placement target")
	var hit := terrain.raycast(Vector3(300, 80, 300), Vector3.DOWN)
	_check(hit.hit and absf(hit.position.y - 9.0) < 0.001,
			"playable ground remains pickable")
	var old_mesh := terrain._backdrop.mesh
	hm.heights[10] = 35.0
	terrain.rebuild_region(Vector3(40, 0, 0), 4, 4)
	_check(terrain._backdrop.mesh != old_mesh,
			"grading a boundary chunk also rebuilds its visible continuation")
	terrain.free()


func _camera_clearance() -> void:
	var hm := _flat_heightmap()
	for z in range(102, 106):
		for x in range(98, 103):
			hm.heights[z * Heightmap.N + x] = 40.0
	var camera := RTSCamera.new()
	root.add_child(camera)
	camera.set_process(false)
	camera.bind_terrain(hm)
	camera.look_at_position(Vector3(400, 9, 400), RTSCamera.MIN_DIST)
	var eye := camera.camera().global_position
	_check(eye.y >= Terrain.presentation_height(hm, eye.x, eye.z) + RTSCamera.GROUND_CLEARANCE - 0.001,
			"close orbit rises above an uphill camera position")
	var toward := (camera.focus - eye).normalized()
	_check((-camera.camera().global_basis.z).dot(toward) > 0.999,
			"terrain clearance keeps the camera aimed at its requested focus")
	camera.look_at_position(Vector3(-500, -200, Config.WORLD_SIZE + 500), RTSCamera.MIN_DIST)
	_check(camera.focus.x == 0.0 and camera.focus.z == Config.WORLD_SIZE,
			"direct focus requests are constrained to the entire playable square")
	hm.heights.fill(-10.0)
	camera.look_at_position(Vector3(300, -10, 300), RTSCamera.MIN_DIST)
	_check(camera.camera().global_position.y >= Config.SEA_LEVEL + RTSCamera.GROUND_CLEARANCE,
			"zooming into a lake never places the eye under water")
	camera.free()


func _ore_and_picking(registry: AssetRegistry) -> void:
	var nodes := ResourceNodes.new()
	root.add_child(nodes)
	var original := registry.mesh("iron_node_01")
	var original_material := original.surface_get_material(0)
	nodes._build_multimesh("iron_node_01", [
		{"position": Vector3(80, 9, 80), "scale": 1.2, "yaw": 0.7,
			"kind": ResourceNodes.Kind.IRON, "amount": 120.0},
		{"position": Vector3(80, 9, 100), "scale": 1.0, "yaw": 0.0,
			"kind": ResourceNodes.Kind.IRON, "amount": 120.0}], registry)
	var materials_ok := true
	for layers in nodes._multimeshes.values():
		for layer in layers:
			var metal := false
			var rust := false
			for surface in layer.multimesh.mesh.get_surface_count():
				var mat: StandardMaterial3D = layer.multimesh.mesh.surface_get_material(surface)
				metal = metal or (mat.resource_name == "ore_metal" and mat.metallic > 0.5)
				rust = rust or (mat.resource_name == "ore_oxide" and mat.albedo_color.r > mat.albedo_color.b * 3.0)
			materials_ok = materials_ok and metal and rust
	_check(materials_ok, "both iron LODs keep readable rust veins and dark metallic host rock")
	_check(original.surface_get_material(0) == original_material,
			"ore styling preserves shared imported materials")
	var ray_origin := Vector3(80, 10, 60)
	_check(nodes.pick_ray(ray_origin, Vector3.BACK) == nodes.records[0],
			"ray picking chooses the nearest rotated and scaled resource")
	_check(nodes.pick_ray(ray_origin, Vector3.BACK, 5.0) == null,
			"terrain occlusion distance hides resources behind a hill")
	nodes._set_scale(nodes.records[0], 0.1)
	_check(nodes.pick_ray(ray_origin, Vector3.BACK) == nodes.records[1],
			"picking follows the visible shrinking outcrop rather than its original bounds")
	nodes._set_depleted(nodes.records[0], true)
	_check(nodes.pick_ray(ray_origin, Vector3.BACK) == nodes.records[1],
			"depleted outcrops stop intercepting resource hover")
	nodes.records[1].falling = 0.5
	_check(nodes.pick_ray(ray_origin, Vector3.BACK) == null,
			"falling resources stop intercepting hover")
	nodes.free()


func _shots(registry: AssetRegistry) -> void:
	var world := World.new()
	root.add_child(world)
	world.generate(registry, 20260911)
	world.set_time_of_day(0.38)
	var camera := RTSCamera.new()
	root.add_child(camera)
	camera.set_process(false)
	camera.bind_terrain(world.heightmap)
	camera.camera().current = true
	var views := [
		{"name": "north", "at": Vector3(160, 0, 3), "yaw": PI, "distance": 160.0},
		{"name": "water", "at": Vector3(750, 0, 750), "yaw": -PI * 0.75, "distance": 160.0},
	]
	for rec in world.nodes.records:
		if rec.kind == ResourceNodes.Kind.IRON:
			views.append({"name": "iron", "at": rec.position, "yaw": 0.4, "distance": 24.0})
			break
	var directory := ProjectSettings.globalize_path("res://../artifacts/world_presentation")
	DirAccess.make_dir_recursive_absolute(directory)
	for view in views:
		camera.yaw = view.yaw
		camera.look_at_position(view.at, view.distance)
		for i in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := directory.path_join(view.name + ".png")
		root.get_texture().get_image().save_png(path)
		print("SHOT ", path)
	camera.free()
	world.free()


func _run() -> void:
	_boundary()
	_camera_clearance()
	var registry := AssetRegistry.new()
	registry.load_all()
	_ore_and_picking(registry)
	if "--world-presentation-shots" in OS.get_cmdline_user_args():
		await _shots(registry)
	await process_frame
	print("World presentation regression failures: %d" % _failures)
	quit(1 if _failures else 0)
