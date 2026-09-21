extends SceneTree

## Real-shader comparison of coarse and detailed terrain at the same place.
## xvfb-run -a tools/godot_env.sh --path game --script res://tests/terrain_fertility.gd

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok: failures += 1


func _capture(view: SubViewport, label: String) -> Image:
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	var directory := ProjectSettings.globalize_path("res://../artifacts/terrain_fertility")
	DirAccess.make_dir_recursive_absolute(directory)
	image.save_png(directory.path_join(label + ".png"))
	return image


func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var left := a.get_pixel(x, y)
			var right := b.get_pixel(x, y)
			total += absf(left.r - right.r) + absf(left.g - right.g) + absf(left.b - right.b)
	return total / float(a.get_width() * a.get_height() * 3)


func _run() -> void:
	var hm := Heightmap.new()
	hm.generate(42, 1536.0, 2)
	hm.heights.fill(9.0)
	hm.surface.fill(Heightmap.Surface.GRASS)
	for z in hm.grid_size:
		for x in hm.grid_size:
			hm.fertility[z * hm.grid_size + x] = 0.3 + 0.6 * float(x) / float(hm.grid_size - 1)
	var wear := WearField.new()
	wear.setup(hm.world_size)
	wear.bake_fertility(hm)
	var terrain := Terrain.new()
	terrain.build(hm, wear)
	var tile := Vector2i(4, 4)
	var fine: ShaderMaterial = terrain._detail_materials[tile]
	var coarse := terrain._material
	_check(fine.get_shader_parameter("fertility_map") == coarse.get_shader_parameter("fertility_map"),
		"coarse and detailed materials share the world fertility map")
	_check(fine.get_shader_parameter("wear_map") != coarse.get_shader_parameter("wear_map"),
		"comparison uses independent local and coarse wear maps")
	var view := SubViewport.new()
	view.size = Vector2i(192, 192)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var centre := Vector3(864, 9, 864)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 128
	view.add_child(camera)
	camera.position = centre + Vector3(0, 100, 0)
	camera.look_at(centre, Vector3.FORWARD)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.0
	camera.environment = environment
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(128, 128)
	ground.mesh = plane
	ground.position = centre
	ground.material_override = coarse
	view.add_child(ground)
	var distant := await _capture(view, "coarse")
	ground.material_override = fine
	var detailed := await _capture(view, "detail")
	var difference := _difference(distant, detailed)
	print("METRIC coarse_detail_difference=", difference)
	_check(difference < 0.002, "switching terrain detail does not change fertile ground color")
	_check(detailed.get_pixel(96, 96).get_luminance() > 0.05,
		"comparison renders lit terrain rather than an empty viewport")
	var static_pixels := wear._fertility_image.get_data()
	wear.stamp_segment(centre - Vector3(58, 0, 0), centre + Vector3(58, 0, 0), 100, 10)
	wear.flush_texture(true)
	var road := await _capture(view, "road")
	_check(_difference(detailed, road) > 0.002, "local wear still changes the rendered road")
	_check(wear._fertility_image.get_data() == static_pixels,
		"road upload leaves static fertility untouched")
	view.free()
	terrain.free()
	print("Terrain fertility failures: %d" % failures)
	quit(1 if failures else 0)
