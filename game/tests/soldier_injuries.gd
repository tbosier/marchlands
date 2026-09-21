extends SceneTree

const Unit = preload("res://scripts/agents/soldier.gd")
var _failures := 0
var _next_id := 5000


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1


func _unit(world: World, registry: AssetRegistry, at: Vector3 = Vector3(10, 9, 10),
		asset: String = "citizen_male_base") -> Soldier:
	var unit := Unit.new()
	world.effects_root.add_child(unit)
	unit.setup_unit(registry, world.heightmap, _next_id, 0, at, asset)
	_next_id += 1
	unit.tick(0.0, world)
	return unit


func _label(unit: Soldier, text: String) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 26
	label.outline_size = 5
	label.pixel_size = 0.007
	label.position.y = 2.15
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	unit.add_child(label)


func _shot(world: World, registry: AssetRegistry) -> void:
	world._build_lighting()
	world.set_time_of_day(0.38)
	world.terrain = Terrain.new()
	world.add_child(world.terrain)
	world.terrain.build(world.heightmap, world.wear)
	for i in 4:
		var tier: String = Unit.Body.ARMOR[i]
		var unit := _unit(world, registry, Vector3(379.5 + i * 3, 9, 382))
		unit.equip_armor(tier)
		_label(unit, "Unarmored" if tier == "none" else ("Plate over mail" if tier == "plate" else tier.capitalize()))
	var missing := _unit(world, registry, Vector3(381, 9, 386))
	missing.receive_hit("arm_r", "slash", 80.0)
	_label(missing, "Sword arm lost\nEquipment dropped")
	var plated := _unit(world, registry, Vector3(384, 9, 386))
	plated.equip_armor("plate")
	plated.receive_hit("arm_r", "stab", 24.0)
	_label(plated, "Stab stopped\nBruise only")
	var limping := _unit(world, registry, Vector3(387, 9, 386))
	limping.receive_hit("leg_l", "slash", 50.0)
	limping.update_animation(0.1, 0.5)
	_label(limping, "Injured leg\nSlow movement")
	var camera := RTSCamera.new()
	world.add_child(camera)
	camera.set_process(false)
	camera.bind_terrain(world.heightmap)
	camera.look_at_position(Vector3(384, 10, 384.5), 14.0)
	camera.camera().current = true
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../artifacts/world_presentation")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("soldier_injuries.png")
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _run() -> void:
	var registry := AssetRegistry.new()
	registry.load_all()
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
	var bare := _unit(world, registry)
	_check(Unit.validate_body(bare.capture_body()) == "" and bare.health == 100.0,
			"a new soldier has six healthy locations and a valid body save")
	var result := bare.receive_hit("arm_r", "stab", 24.0)
	_check(result.ok and result.outcome == "puncture" and bare.capture_body().parts.arm_r.puncture == 24.0,
			"an unarmored arm takes the point of a stab")
	var plate := _unit(world, registry)
	_check(plate.equip_armor("plate") and plate.armor_tier == "plate", "plate armor can be equipped")
	result = plate.receive_hit("arm_r", "stab", 24.0)
	_check(result.outcome == "bruise" and result.absorbed == 24.0
			and plate.capture_body().parts.arm_r.puncture == 0.0 and plate.can_strike(),
			"layered plate and mail turn the same stab into a bruise with the arm usable")
	_check(Unit.Body.protection("mail", "torso", "stab") > Unit.Body.protection("mail", "leg_l", "stab")
			and Unit.Body.protection("plate", "torso", "stab") > Unit.Body.protection("mail", "torso", "stab"),
			"armor coverage varies by location and plate includes its mail layer")
	var damage: Array[float] = []
	for tier in Unit.Body.ARMOR:
		var subject := _unit(world, registry)
		subject.equip_armor(tier)
		damage.append(subject.receive_hit("torso", "slash", 30.0).damage)
	_check(damage[0] > damage[1] and damage[1] > damage[2] and damage[2] > damage[3],
			"none, leather, mail and plate progressively reduce the same torso slash")
	var amputee := _unit(world, registry)
	result = amputee.receive_hit("arm_r", "slash", 80.0)
	_check(result.severed and not result.fatal and not amputee._parts.arm_r.visible,
			"a heavy unarmored arm slash can remove that limb without killing the soldier")
	_check(not amputee.can_strike() and not amputee.can_throw_firepot()
			and not amputee.strike(Vector3.ZERO) and not amputee.throw_firepot(Vector3.ZERO),
			"the missing sword arm cannot swing a weapon or throw a firepot")
	_check(world.effects_root.find_child("dropped_sword", false, false) != null
			and not amputee._sword.visible and amputee.can_use_shield(),
			"the sword drops visibly while the intact shield arm still works")
	_check("arm_r" not in amputee.hit_locations(), "combat cannot target an already missing limb")
	var saved_arm := amputee.capture_body()
	_check(not amputee.receive_hit("arm_r", "slash", 80.0).ok and amputee.capture_body() == saved_arm,
			"repeated hits on a missing limb do not duplicate injury or equipment drops")
	amputee.set_civilian_mode(true)
	amputee.begin_work(10.0)
	amputee.work_tick(10.0)
	_check(amputee._body.collision_layer == 4 and amputee._body.get_meta("citizen_id") == amputee.id
			and not amputee._body.has_meta("unit_id") and not amputee._shield.visible
			and absf(amputee.work_remaining() - 5.5) < 0.001,
			"a demobilized veteran keeps the injury and works more slowly with one usable arm")
	amputee.set_civilian_mode(false)
	_check(not amputee._parts.arm_r.visible and not amputee.can_strike() and amputee.can_use_shield(),
			"reenlisting restores equipment only to limbs the veteran still has")
	amputee.receive_hit("arm_l", "slash", 80.0)
	_check(not amputee.can_use_shield() and amputee.workability() == 0.0
			and world.effects_root.find_child("dropped_shield", false, false) != null,
			"losing the other arm removes the shield and the ability to perform hand work")
	amputee.begin_work(5.0)
	_check(not amputee.work_tick(100.0) and amputee.work_remaining() == 5.0,
			"a veteran with no usable arms cannot complete a pending work timer")
	var legs := _unit(world, registry)
	var normal_speed := legs.walking_speed()
	legs.receive_hit("leg_l", "slash", 50.0)
	_check(absf(legs.walking_speed() - normal_speed * 0.25) < 0.001,
			"a disabled leg materially reduces walking speed")
	legs.order_move(Vector3(20, 9, 10))
	var before := legs.position
	for i in 10:
		legs.tick(0.1, world)
	_check(legs.position.distance_to(before) > 0.1 and legs.position.distance_to(before) < normal_speed,
			"a one-leg injury still permits a slow physical retreat")
	legs.receive_hit("leg_r", "slash", 50.0)
	legs.order_move(Vector3(30, 9, 10))
	_check(legs.mobility_scale() == 0.0 and not legs.has_goal(),
			"two disabled legs stop movement instead of sliding the body across the ground")
	var fatal := _unit(world, registry)
	result = fatal.receive_hit("head", "stab", 55.0)
	_check(result.fatal and fatal.health == 0.0 and fatal._body.collision_layer == 0 and not fatal.visible,
			"a penetrating vital injury is fatal without displaying a health bar")
	var survivor := _unit(world, registry, Vector3(20, 9, 20), "citizen_female_base")
	survivor.receive_hit("arm_l", "slash", 80.0)
	survivor.equip_armor("mail")
	survivor.apply_damage(8.0)
	var saved := survivor.capture_body()
	var restored := _unit(world, registry, Vector3(25, 9, 20), "citizen_female_base")
	_check(restored.restore_body(saved) == "" and restored.capture_body() == saved
			and restored.health == survivor.health and restored.armor_tier == "mail"
			and not restored._parts.arm_l.visible and restored.asset_id == "citizen_female_base",
			"body saves restore exact armor, missing limbs, strain and the chosen citizen mesh")
	var copied := restored.capture_body()
	copied.parts.arm_r.cut = 30.0
	_check(restored.capture_body() == saved, "captured injury records do not alias the living body")
	var invalid: Array = [false, {}, {"version": 9}]
	for key in ["bruise", "cut", "puncture"]:
		var bad := saved.duplicate(true)
		bad.parts.head[key] = NAN
		invalid.append(bad)
	var bad := saved.duplicate(true)
	bad.parts.head.severed = true
	invalid.append(bad)
	bad = saved.duplicate(true)
	bad.parts.arm_r.severed = true
	invalid.append(bad)
	bad = saved.duplicate(true)
	bad.armor = "paper"
	invalid.append(bad)
	bad = saved.duplicate(true)
	bad.parts.leg_l.cut = true
	invalid.append(bad)
	bad = saved.duplicate(true)
	bad.strain = INF
	invalid.append(bad)
	var rejected := true
	for body in invalid:
		rejected = rejected and Unit.validate_body(body) != "" and restored.restore_body(body) != ""
		_check(restored.capture_body() == saved, "rejected body state leaves existing injuries and armor intact")
	_check(rejected, "malformed body saves reject before touching the living unit")
	var before_bad := restored.capture_body()
	for hit in [["tail", "slash", 20.0], ["head", "magic", 20.0], ["head", "stab", NAN], ["head", "stab", -1.0]]:
		_check(not restored.receive_hit(hit[0], hit[1], hit[2]).ok, "invalid hit is rejected")
	_check(restored.capture_body() == before_bad and not restored.equip_armor("paper"),
			"invalid hits and armor cannot mutate the body")
	if "--injury-shot" in OS.get_cmdline_user_args():
		await _shot(world, registry)
	world.free()
	await process_frame
	print("Soldier injury regression failures: %d" % _failures)
	quit(1 if _failures else 0)
