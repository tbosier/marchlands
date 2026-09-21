extends SceneTree

## Render real fog over hills and transparent water, and check enemy picking.
const FogRenderer = preload("res://scripts/world/fog_of_war.gd")

class Vision extends Node:
	signal changed
	var state := [0, 1, 2] # unseen, remembered, visible
	var image: Image
	var map: ImageTexture
	func _init() -> void:
		image = Image.create(12, 12, false, Image.FORMAT_RG8)
		map = ImageTexture.create_from_image(image)
		update_map()
	func update_map() -> void:
		for z in 12:
			for x in 12:
				var value: int = state[x / 4]
				image.set_pixel(x, z, Color(float(value >= 1), float(value == 2), 0, 1))
		map.update(image)
		changed.emit()
	func texture() -> Texture2D: return map
	func visibility_at(p: Vector3) -> bool:
		return p.x >= 0 and p.x < 384 and state[clampi(int(p.x / 128), 0, 2)] == 2

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok: failures += 1


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _plane(parent: Node, size: Vector2, at: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = material
	parent.add_child(node)
	node.position = at
	return node


func _enemy(parent: Node, at: Vector3) -> Node3D:
	var node := Node3D.new()
	parent.add_child(node)
	node.position = at
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(18, 10, 18)
	mesh.mesh = box
	mesh.material_override = _material(Color(0.95, 0.12, 0.08))
	node.add_child(mesh)
	var body := StaticBody3D.new()
	body.name = "pick"
	body.collision_layer = 8
	body.set_meta("rival_building_id", 123)
	var shape := CollisionShape3D.new()
	var bounds := BoxShape3D.new()
	bounds.size = box.size
	shape.shape = bounds
	body.add_child(shape)
	node.add_child(body)
	return node


func _capture(label: String) -> Image:
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var directory := ProjectSettings.globalize_path("res://../artifacts/fog_presentation")
	DirAccess.make_dir_recursive_absolute(directory)
	_check(image.save_png(directory.path_join(label + ".png")) == OK, "saved fog screenshot " + label)
	return image


func _sample(image: Image, camera: Camera3D, point: Vector3) -> Color:
	var screen := camera.unproject_position(point)
	return image.get_pixel(clampi(roundi(screen.x), 0, image.get_width() - 1),
		clampi(roundi(screen.y), 0, image.get_height() - 1))


func _delta(a: Color, b: Color) -> float:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)


func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	for y in a.get_height():
		for x in a.get_width(): total += _delta(a.get_pixel(x, y), b.get_pixel(x, y))
	return total / float(a.get_width() * a.get_height())


func _run() -> void:
	root.size = Vector2i(512, 512)
	var world := World.new()
	world.size_m = 384
	root.add_child(world)
	world.effects_root = Node3D.new()
	world.add_child(world.effects_root)
	world.buildings_root = Node3D.new()
	world.add_child(world.buildings_root)
	var campaign := Node3D.new()
	world.add_child(campaign)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 420
	world.add_child(camera)
	camera.position = Vector3(192, 400, 192)
	camera.look_at(Vector3(192, 0, 192), Vector3.FORWARD)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.25, 0.30, 0.35)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.4
	camera.environment = environment
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, -90, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 700
	world.add_child(sun)
	_plane(world, Vector2(384, 384), Vector3(192, -8, 192), _material(Color(0.45, 0.38, 0.25)))
	var grass := _material(Color(0.35, 0.60, 0.25))
	grass.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_plane(world, Vector2(384, 224), Vector3(192, 9, 112), grass)
	var water := ShaderMaterial.new()
	water.shader = load("res://shaders/water.gdshader")
	water.set_shader_parameter("wave_speed", 0.0)
	_plane(world, Vector2(384, 384), Vector3(192, Config.SEA_LEVEL, 192), water)
	var mountain := MeshInstance3D.new()
	var peak := BoxMesh.new()
	peak.size = Vector3(36, 80, 36)
	mountain.mesh = peak
	mountain.material_override = _material(Color(0.7, 0.65, 0.60))
	world.add_child(mountain)
	mountain.position = Vector3(64, 49, 96)
	var unseen := _enemy(campaign, Vector3(64, 14, 192))
	var known := _enemy(campaign, Vector3(192, 14, 192))
	var current := _enemy(campaign, Vector3(320, 14, 192))
	var baseline := await _capture("without_fog")
	var vision := Vision.new()
	world.add_child(vision)
	var fog := FogRenderer.new()
	world.add_child(fog)
	fog.setup(vision, world, campaign)
	var image := await _capture("unknown_remembered_visible")
	_check(not unseen.visible and not known.visible and current.visible,
		"enemy buildings require current sight, including on remembered ground")
	_check(unseen.get_node("pick").collision_layer == 0 and known.get_node("pick").collision_layer == 0
		and current.get_node("pick").collision_layer == 8,
		"hidden enemies cannot be selected or targeted through physics picking")
	var unknown_ground := _sample(image, camera, Vector3(64, 9, 160))
	var hidden_peak := _sample(image, camera, Vector3(64, 89, 96))
	var unknown_water := _sample(image, camera, Vector3(64, Config.SEA_LEVEL, 300))
	_check(_delta(unknown_ground, hidden_peak) < 0.02 and _delta(unknown_ground, unknown_water) < 0.02,
		"unexplored grass, high peaks and transparent water share opaque fog")
	var remembered := _sample(image, camera, Vector3(192, 9, 160)).get_luminance()
	var fresh := _sample(baseline, camera, Vector3(192, 9, 160)).get_luminance()
	_check(remembered > unknown_ground.get_luminance() and remembered < fresh * 0.8,
		"remembered terrain remains legible but visibly dimmed")
	_check(_delta(_sample(image, camera, Vector3(320, 9, 160)),
		_sample(baseline, camera, Vector3(320, 9, 160))) < 0.02,
		"currently visible land keeps its normal appearance")
	_check(_delta(_sample(image, camera, Vector3(320, Config.SEA_LEVEL, 300)),
		_sample(baseline, camera, Vector3(320, Config.SEA_LEVEL, 300))) < 0.02,
		"currently visible transparent water keeps its normal appearance")
	campaign.remove_child(unseen)
	campaign.remove_child(known)
	var removed := await _capture("hidden_casters_removed")
	_check(_difference(image, removed) < 0.0001,
		"hidden enemies cast no leaking shadows: removing them leaves identical pixels")
	campaign.add_child(unseen)
	campaign.add_child(known)
	vision.state[0] = 2
	vision.update_map()
	await physics_frame
	_check(unseen.visible and unseen.get_node("pick").collision_layer == 8,
		"entering sight restores the existing enemy and its picking layer")
	vision.state[0] = 1
	vision.update_map()
	_check(not unseen.visible and unseen.get_node("pick").collision_layer == 0,
		"departing sight hides the live enemy again without erasing exploration")
	unseen.reparent(world.buildings_root)
	fog.refresh_entities()
	_check(unseen.visible and unseen.get_node("pick").collision_layer == 8,
		"reclaiming a hidden building releases the enemy presentation filter")
	var old_fog: WeakRef = weakref(fog)
	fog.free()
	var replacement := Vision.new()
	replacement.state = [2, 2, 2]
	replacement.update_map()
	world.add_child(replacement)
	var next_fog := FogRenderer.new()
	world.add_child(next_fog)
	next_fog.setup(replacement, world, campaign)
	vision.state = [0, 0, 0]
	vision.update_map()
	_check(old_fog.get_ref() == null and world.fog == next_fog
		and next_fog._material.get_shader_parameter("visibility_map") == replacement.texture()
		and known.visible and current.visible,
		"replacing fog binds only the new visibility map and disconnects old signals")
	world.free()
	print("Fog presentation failures: %d" % failures)
	quit(1 if failures else 0)
