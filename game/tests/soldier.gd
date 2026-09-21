extends SceneTree

const Unit = preload("res://scripts/agents/soldier.gd")
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1


func _shot(world: World, friendly: Soldier, enemy: Soldier, projectile: Node3D) -> void:
	world._build_lighting()
	world.set_time_of_day(0.38)
	world.terrain = Terrain.new()
	world.add_child(world.terrain)
	world.terrain.build(world.heightmap, world.wear)
	enemy.position = friendly.position + Vector3(6, 0, 0)
	projectile.finish = enemy.position + Vector3(0, 0.1, 0)
	projectile._process(0.0)
	var camera := RTSCamera.new()
	world.add_child(camera)
	camera.set_process(false)
	camera.bind_terrain(world.heightmap)
	camera.look_at_position((friendly.position + enemy.position) * 0.5, 14.0)
	camera.camera().current = true
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/world_presentation")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("soldiers.png")
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _run() -> void:
	var registry := AssetRegistry.new()
	registry.load_all()
	for type_id in ["house", "keep", "fort"]:
		var building := Building.new()
		root.add_child(building)
		building.under_construction = false
		building.setup(900, BuildingDefs.get_def(type_id), registry)
		building.apply_damage(building.max_health() * 0.25, 0.55)
		var mesh_bounds := registry.mesh(building.asset_id).get_aabb()
		var roof_vertices := PackedVector3Array()
		var building_mesh := registry.mesh(building.asset_id)
		for surface in building_mesh.get_surface_count():
			var material := building_mesh.surface_get_material(surface)
			if material.resource_name == "thatch" or material.resource_name.begins_with("roof_"):
				roof_vertices.append_array(building_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
		var exterior := true
		var grounded := true
		for tongue in building._fire_visual.get_children():
			var base := Vector3(tongue.position.x, float(tongue.get_meta("base_y")), tongue.position.z)
			if base.y > 0.1:
				var on_roof := false
				for vertex in roof_vertices:
					on_roof = on_roof or base.distance_to(vertex) < 0.5
				exterior = exterior and on_roof
			else:
				exterior = exterior and (tongue.position.x < mesh_bounds.position.x
						or tongue.position.x > mesh_bounds.end.x)
			grounded = grounded and absf(tongue.position.y
					- tongue.mesh.height * tongue.scale.y * 0.5 - float(tongue.get_meta("base_y"))) < 0.001
		_check(exterior and grounded and building._damage_stage > 0,
				"%s fire stays outside its shell, anchored at walls/eaves and accompanied by scorch" % type_id)
		building.free()
	var world := World.new()
	root.add_child(world)
	world.heightmap.heights.resize(Heightmap.N * Heightmap.N)
	world.heightmap.heights.fill(9.0)
	world.heightmap.surface.resize(Config.GRID * Config.GRID)
	world.heightmap.surface.fill(Heightmap.Surface.GRASS)
	world.heightmap.fertility.resize(Config.GRID * Config.GRID)
	world.heightmap.fertility.fill(0.5)
	world.nav.setup(world.heightmap, world.wear)
	world.effects_root = Node3D.new()
	world.add_child(world.effects_root)
	var friendly := Unit.new()
	world.effects_root.add_child(friendly)
	friendly.setup_unit(registry, world.heightmap, 1001, 0, Vector3(10, 0, 10))
	var enemy := Unit.new()
	world.effects_root.add_child(enemy)
	enemy.setup_unit(registry, world.heightmap, 1002, 1, Vector3(60, 0, 10))
	_check(friendly.position.y == 9.0 and friendly._body.collision_layer == 8
			and friendly._body.get_meta("unit_id") == 1001 and not friendly._body.has_meta("citizen_id"),
			"soldier is grounded and has only military picking metadata")
	_check(friendly._faction_color().b > friendly._faction_color().r
			and enemy._faction_color().r > enemy._faction_color().b,
			"friendly blue and enemy red are distinct")
	_check(friendly._unit_visual.find_child("sword", true, false) != null
			and friendly._unit_visual.find_child("shield", true, false) != null,
			"soldier visibly carries a sword and shield")
	await physics_frame
	await physics_frame
	var query := PhysicsRayQueryParameters3D.create(Vector3(10, 20, 10), Vector3(10, 8, 10), 8)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
	_check(not hit.is_empty() and hit.collider.get_meta("unit_id", -1) == 1001,
			"physics ray on military layer selects its unit")
	for z in 9:
		if z != 6:
			world.nav.set_blocked(6, z, true)
	friendly.cooldown = 2.0
	friendly.fire_cooldown = 3.0
	friendly.order_move(Vector3(42, 9, 10))
	var avoided_obstacles := true
	for i in 600:
		friendly.tick(0.1, world)
		var cell := Config.world_to_cell(friendly.position)
		if avoided_obstacles and world.nav.is_solid(cell.x, cell.y):
			print("BLOCKED_STEP position=%s cell=%s path=%s index=%d" % [
					friendly.position, cell, friendly._path, friendly._path_index])
		avoided_obstacles = avoided_obstacles and not world.nav.is_solid(cell.x, cell.y)
		if not friendly.has_goal():
			break
	if friendly.has_goal() or not avoided_obstacles:
		print("MOVE_DIAGNOSTIC position=%s goal=%s unreachable=%s path=%s" % [
				friendly.position, friendly.has_goal(), friendly.unreachable, friendly._path])
	_check(not friendly.has_goal() and friendly.position.distance_to(Vector3(42, 9, 10)) < 1.5
			and avoided_obstacles, "military movement follows walkable navigation around a wall")
	# A citizen can already stand inside a footprint when a building is placed
	# or an old save is loaded. Skip the duplicate starting waypoint so the
	# navigator's resolved free start remains reachable, then enforce corners.
	world.nav.set_blocked(15, 2, true)
	enemy.order_move(Vector3(74, 9, 10))
	var escaped := false
	var reentered := false
	for i in 240:
		enemy.tick(0.1, world)
		var cell := Config.world_to_cell(enemy.position)
		var solid := world.nav.is_solid(cell.x, cell.y)
		reentered = reentered or (escaped and solid)
		escaped = escaped or not solid
		if not enemy.has_goal():
			break
	_check(escaped and not reentered and not enemy.has_goal(),
			"a unit starting inside a new footprint escapes and resumes a valid route")
	_check(friendly.rations == 4.0 and friendly.cooldown == 2.0 and friendly.fire_cooldown == 3.0
			and friendly.job == null and friendly.home_id == -1 and friendly.workplace_id == -1,
			"unit movement leaves campaign food/cooldowns and civilian employment untouched")
	friendly.strike(enemy.position)
	_check(friendly._attack_left > 0.0, "melee attack starts the sword swing")
	friendly.throw_firepot(enemy.position)
	var projectile: Node3D = world.effects_root.get_node("firepot")
	await process_frame
	_check(not projectile.is_processing() and projectile.elapsed == 0.0,
			"paused simulation leaves projectile timing unchanged across rendered frames")
	Unit.advance_projectiles(world.effects_root, projectile.flight * 0.5)
	var midpoint: Vector3 = projectile.start.lerp(projectile.finish, 0.5)
	_check(projectile.global_position.y > midpoint.y + 1.0,
			"firepot follows a visible arc above the ground")
	if "--soldier-shot" in OS.get_cmdline_user_args():
		await _shot(world, friendly, enemy, projectile)
	friendly.apply_damage(1000.0)
	_check(friendly.health == 0.0 and friendly._body.collision_layer == 0
			and not friendly.visible and not friendly.has_goal(),
			"defeated unit stops moving and can no longer be selected")
	_check(world.effects_root.get_node_or_null("fallen_guard") != null,
			"defeated unit leaves a temporary falling body")
	friendly.free()
	Unit.advance_projectiles(world.effects_root, projectile.flight)
	_check(is_instance_valid(projectile) and not projectile.pot.visible
			and not projectile.flames.is_empty(),
			"firepot lands and burns after its owner has been removed")
	Unit.advance_projectiles(world.effects_root, 2.0)
	await process_frame
	_check(not is_instance_valid(projectile), "finished firepot effects clean themselves up")
	world.free()
	await process_frame
	print("Soldier regression failures: %d" % _failures)
	quit(1 if _failures else 0)
