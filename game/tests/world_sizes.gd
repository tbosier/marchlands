extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		failures += 1

func _run() -> void:
	var legacy := Heightmap.new()
	legacy.generate(20260911)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(legacy.heights.to_byte_array())
	hash.update(legacy.surface)
	hash.update(legacy.fertility.to_byte_array())
	check(hash.finish().hex_encode() == "f1dbe08003d84a859194805c75c8f841612afc0eddb2876bd0067cef529dfbd3",
			"legacy heights, surfaces and fertility match pre-change golden SHA256")
	var explicit_legacy := Heightmap.new()
	explicit_legacy.generate(20260911, 768.0, 1)
	check(legacy.heights == explicit_legacy.heights and legacy.surface == explicit_legacy.surface,
			"default generation remains byte-identical to explicit legacy settings")
	var registry := AssetRegistry.new()
	registry.load_all()
	for size_m in [768.0, 1536.0, 3072.0, 6144.0]:
		var before := Time.get_ticks_msec()
		var world := World.new()
		root.add_child(world)
		world.generate(registry, 20260911, {"size_m": size_m, "generation_version": 2})
		var generated := Time.get_ticks_msec() - before
		check(world.size_m == size_m and world.grid_size == roundi(size_m / 4.0), "instance dimensions %dm" % size_m)
		check(world.heightmap.n == world.grid_size + 1 and world.wear.res == world.grid_size * 2,
				"height and wear dimensions %dm" % size_m)
		var fertility_texture := world.wear.fertility_texture()
		var fertility_bytes := world.wear._fertility_image.get_data()
		check(fertility_texture.get_width() == world.grid_size
				and fertility_texture.get_height() == world.grid_size
				and fertility_bytes.size() == world.grid_size * world.grid_size,
				"static fertility uses one byte per navigation cell %dm" % size_m)
		var fertility_matches := true
		for z in range(0, world.grid_size, maxi(1, world.grid_size / 13)):
			for x in range(0, world.grid_size, maxi(1, world.grid_size / 13)):
				fertility_matches = fertility_matches and fertility_bytes[z * world.grid_size + x] == int(
						world.heightmap.cell_fertility(x, z) * 255.0)
		check(fertility_matches, "static fertility preserves authored terrain values %dm" % size_m)
		var shared_fertility: bool = world.terrain._material.get_shader_parameter("fertility_map") == fertility_texture
		for material: ShaderMaterial in world.terrain._detail_materials.values():
			shared_fertility = shared_fertility and material.get_shader_parameter("fertility_map") == fertility_texture
		check(shared_fertility, "coarse and detailed ground share one fertility texture %dm" % size_m)
		check(legacy.world_size == 768.0 and legacy.height_at(600, 600) == explicit_legacy.height_at(600, 600),
				"staged world cannot contaminate legacy world %dm" % size_m)
		var other := World.new()
		other.heightmap.generate(71)
		check(other.world_to_cell(Vector3(size_m - 1, 0, size_m - 1)) == Vector2i(191, 191)
				and world.world_to_cell(Vector3(size_m - 1, 0, size_m - 1)) == Vector2i(world.grid_size - 1, world.grid_size - 1),
				"simultaneous differently sized world coordinate bounds %dm" % size_m)
		other.free()
		var start := world.centre()
		check(world.heightmap.cell_fertility(world.grid_size / 2, world.grid_size / 2) > 0.7,
				"fertile safe start %dm" % size_m)
		before = Time.get_ticks_msec()
		var destination := Vector3(size_m * 0.08, 0, size_m * 0.08)
		var route := world.nav.find_path(start, destination)
		var route_ms := Time.get_ticks_msec() - before
		check(not route.is_empty(), "route reaches distant region %dm" % size_m)
		var clear := true
		for i in range(1, route.size()):
			clear = clear and world.nav._clear_line(Vector2(route[i - 1].x, route[i - 1].z), Vector2(route[i].x, route[i].z))
		check(clear, "far route remains on traversable ground %dm" % size_m)
		var bridge_sim := Simulation.new()
		var bridges := Bridges.new()
		bridges.setup(bridge_sim, world, registry)
		var crossing: Dictionary = {}
		for z in range(world.grid_size / 2 - 30, mini(world.grid_size, world.grid_size / 2 + 60), 3):
			var first := -1
			var last := -1
			for x in range(world.grid_size / 2 + 20, mini(world.grid_size, world.grid_size / 2 + 80)):
				if world.heightmap.cell_surface(x, z) == Heightmap.Surface.WATER:
					if first < 0:
						first = x
					last = x
			if first < 0:
				continue
			for setback in [0.0, 1.0, 2.0, 3.0]:
				var a := Vector3((first - 0.5 - setback) * Config.CELL, 0, (z + 0.5) * Config.CELL)
				var b := Vector3((last + 1.5 + setback) * Config.CELL, 0, (z + 0.5) * Config.CELL)
				var proposal := bridges.quote(a, b)
				if proposal.ok and proposal.detour_saved > 0:
					crossing = proposal
					break
			if not crossing.is_empty():
				break
		check(not crossing.is_empty(), "generated river has a usable timber crossing %dm" % size_m)
		if not crossing.is_empty():
			var a: Vector3 = crossing.a
			var b: Vector3 = crossing.b
			var mid := (a + b) * 0.5
			var ground := world.heightmap.height_at(mid.x, mid.z)
			var old_revision := world.nav.revision
			world.install_bridge(999, a, b)
			check(world.bridge_id_at(mid.x, mid.z) == 999 and world.surface_speed_at(mid.x, mid.z) > 0
					and is_equal_approx(world.surface_height_at(mid.x, mid.z), mid.y),
					"bridge overlays water with a traversable deck %dm" % size_m)
			check(world.heightmap.height_at(mid.x, mid.z) == ground and crossing.detour_saved > 0,
					"bridge preserves riverbed and saves a real detour %dm" % size_m)
			world.remove_bridge(999)
			check(world.bridge_id_at(mid.x, mid.z) < 0 and world.nav.revision > old_revision
					and world.surface_speed_at(mid.x, mid.z) == 0,
					"bridge removal restores water and invalidates routes %dm" % size_m)
		bridges.free()
		bridge_sim.free()
		var far: float = size_m - 48.0
		world.wear.stamp_segment(Vector3(far, 0, far), Vector3(far + 20, 0, far), 10, 3)
		world.wear.refresh_levels()
		world.wear.flush_texture(true)
		if size_m > 768.0:
			var tile := Vector2i(floori(far / 192.0), floori(far / 192.0))
			var texture := world.wear.tile_texture(tile)
			check(texture.get_width() == 98 and texture.get_height() == 98,
					"large road upload is a bordered local 98x98 texture %dm" % size_m)
			world.wear.stamp_segment(Vector3(far, 0, far), Vector3(far + 20, 0, far), 10, 3)
			before = Time.get_ticks_msec()
			world.wear.flush_texture(true)
			print("BENCH wear_upload_ms=%d active_texels=%d" % [Time.get_ticks_msec() - before, world.wear._active.size()])
			if size_m == 1536.0:
				var saved := world.wear.capture()
				var blank := WearField.new()
				blank.setup(size_m)
				world.wear.apply_state(blank.capture())
				var local := Vector2i(floori((far + 10) / 2.0), floori(far / 2.0)) - tile * 96 + Vector2i.ONE
				var pixel := (local.y * 98 + local.x) * 4
				check(world.wear._tiles[tile].texture == texture and world.wear._tiles[tile].pixels[pixel] == 0,
						"restoring empty wear updates the existing terrain tile texture")
				world.wear.apply_state(saved)
				check(world.wear._tiles[tile].texture == texture and world.wear._tiles[tile].pixels[pixel] > 0,
						"restoring traffic repaints the existing terrain tile texture")
			world.terrain.update_detail(Vector3(far, 0, far), true)
			check(world.terrain._detail_chunks.size() <= 25 and world.wear._tiles.size() <= 26,
					"camera travel bounds high-detail terrain and wear tiles %dm" % size_m)
		check(world.wear.wear_at(far + 10, far) > 0, "far traffic records wear %dm" % size_m)
		check(world.wear.fertility_texture() == fertility_texture
				and world.wear._fertility_image.get_data() == fertility_bytes,
				"local road uploads and camera travel preserve static fertility %dm" % size_m)
		print("BENCH size=%d generation_ms=%d route_ms=%d points=%d resources=%d chunks=%d memory_mb=%.1f" % [
				size_m, generated, route_ms, route.size(), world.nodes.records.size(), world.terrain._chunks.size(),
				float(OS.get_static_memory_usage()) / 1048576.0])
		world.free()
	check(Config.GRID == 192 and Config.WORLD_SIZE == 768.0, "legacy global defaults are immutable")
	print("World size failures: %d" % failures)
	quit(0 if failures == 0 else 1)
