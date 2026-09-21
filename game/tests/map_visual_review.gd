extends SceneTree

## Render actual terrain at edges, water, mountains and chunk transitions.
## xvfb-run -a -s "-screen 0 1600x1000x24" tools/godot_env.sh --path game \
## --display-server x11 --rendering-driver opengl3 --audio-driver Dummy \
## --resolution 1280x720 --script res://tests/map_visual_review.gd

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _shot(world: World, camera: RTSCamera, label: String, at: Vector3, yaw: float, distance: float) -> void:
	camera.yaw = yaw
	camera.look_at_position(at, distance)
	world.terrain.update_detail(camera.focus, true)
	for i in 5: await process_frame
	var eye := camera.camera().global_position
	var floor_height := maxf(Config.SEA_LEVEL, Terrain.presentation_height(world.heightmap, eye.x, eye.z))
	if eye.y < floor_height + RTSCamera.GROUND_CLEARANCE - 0.001:
		failures += 1
		print("FAIL camera clearance at ", label)
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/map_visual_review")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join(label + ".png")
	if root.get_texture().get_image().save_png(path) != OK: failures += 1
	print("SHOT ", path)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("FAIL map visual review requires a renderer")
		quit(1)
		return
	var registry := AssetRegistry.new()
	registry.load_all()
	for size_m in [768, 1536, 3072, 6144]:
		var requested := 0
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--map-size="): requested = int(arg.trim_prefix("--map-size="))
		if requested > 0 and requested != size_m: continue
		var world := World.new()
		root.add_child(world)
		world.generate(registry, 42, {"size_m": size_m, "generation_version": 2})
		world.set_time_of_day(0.38)
		var camera := RTSCamera.new()
		root.add_child(camera)
		camera.set_process(false)
		camera.bind_terrain(world.heightmap)
		camera.camera().current = true
		var c := world.centre()
		await _shot(world, camera, "%d_river" % size_m, c + Vector3(190, 0, -65), 0.5, 220)
		await _shot(world, camera, "%d_north" % size_m, Vector3(size_m * 0.55, 0, 1), PI, 160)
		await _shot(world, camera, "%d_corner" % size_m, Vector3(size_m - 1, 0, size_m - 1), -PI * 0.75, 220)
		var summit := c
		for z in range(8, world.grid_size - 8, 8):
			for x in range(8, world.grid_size - 8, 8):
				var height := world.heightmap.height_at(x * Config.CELL, z * Config.CELL)
				if height > summit.y: summit = Vector3(x * Config.CELL, height, z * Config.CELL)
		await _shot(world, camera, "%d_mountain" % size_m, summit, 0.6, 210)
		await _shot(world, camera, "%d_close_slope" % size_m, summit, 2.6, RTSCamera.MIN_DIST)
		# Moving across a detail-tile boundary must replace meshes without gaps.
		await _shot(world, camera, "%d_chunk_before" % size_m, c + Vector3(190, 0, 120), 1.2, RTSCamera.MAX_DIST)
		await _shot(world, camera, "%d_chunk_after" % size_m, c + Vector3(194, 0, 120), 1.2, RTSCamera.MAX_DIST)
		world.queue_free()
		camera.queue_free()
		for i in 5: await process_frame
	print("Map visual review failures: %d" % failures)
	quit(1 if failures else 0)
