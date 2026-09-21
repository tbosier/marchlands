extends SceneTree

## Reproducible render-only Extra large benchmark (no simulation population).
## tools/godot_env.sh --path game --script res://tests/world_size_render.gd
## Run on a real graphics display; Xvfb commonly uses a software renderer.
## Screenshot is saved to user://world_size_render.png.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var registry := AssetRegistry.new()
	registry.load_all()
	var world := World.new()
	root.add_child(world)
	var start := Time.get_ticks_msec()
	world.generate(registry, 20260911, {"size_m": 6144.0, "generation_version": 2})
	print("RENDER_GEN_MS ", Time.get_ticks_msec() - start)
	world.set_time_of_day(0.38, 0.2)
	var camera := RTSCamera.new()
	root.add_child(camera)
	camera.bind_terrain(world.heightmap)
	camera.yaw = 0.6
	camera.look_at_position(world.centre() + Vector3(130, 0, 45), 310)
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("user://world_size_render.png")
	var times: Array[float] = []
	var previous := Time.get_ticks_usec()
	for i in 120:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append((now - previous) / 1000.0)
		previous = now
	times.sort()
	print("RENDER_FRAME_MS median=", times[60], " p95=", times[114], " max=", times[119],
			" draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			" memory_mb=", OS.get_static_memory_usage() / 1048576.0)
	world.free()
	camera.free()
	quit()
