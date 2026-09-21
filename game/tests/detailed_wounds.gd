extends "res://tests/soldier_injuries.gd"

## Persistent anatomy, bleeding, skills and finite-kit field treatment.
## Owners exercise the once-per-person physiology hook in integration suites.
const Model = preload("res://scripts/agents/soldier_body.gd")


func _legacy_and_validation(world: World, registry: AssetRegistry) -> void:
	var legacy := {"version": 1, "armor": "mail", "strain": 0.0,
		"parts": Model.healthy().parts.duplicate(true)}
	legacy.parts.arm_l.cut = 80.0
	legacy.parts.arm_l.severed = true
	legacy.parts.torso.bruise = 8.0
	var veteran := _unit(world, registry)
	var previous := legacy.duplicate(true)
	_check(Unit.validate_body(legacy) == "" and veteran.restore_body(legacy) == "",
			"six-location version-one body saves still validate and restore")
	var migrated := veteran.capture_body()
	_check(migrated.version == 2 and migrated.regions.upper_arm_l.severed
			and is_equal_approx(veteran.health, 79.6) and veteran.health == Unit.body_health(legacy),
			"legacy injuries retain exact health and missing limbs in detailed regions")
	_check(migrated.wounds.is_empty() and migrated.blood == 100.0 and legacy == previous,
			"migration does not reopen old wounds, create bleeding or mutate the save")
	veteran.advance_condition(60.0)
	_check(veteran.capture_body().blood == 100.0 and veteran.capture_body().parts == legacy.parts,
			"legacy wounds remain stable after the physiology clock starts")
	var body := Model.healthy()
	Model.hit(body, "thigh_l", "stab", 35.0)
	var valid := body.duplicate(true)
	_check(veteran.restore_body(valid) == "", "detailed arterial wound can be restored")
	var bads: Array = []
	var bad := valid.duplicate(true); bad.blood = INF; bads.append(bad)
	bad = valid.duplicate(true); bad.shock = -1.0; bads.append(bad)
	bad = valid.duplicate(true); bad.organs.heart = 101.0; bads.append(bad)
	bad = valid.duplicate(true); bad.skills.melee = NAN; bads.append(bad)
	bad = valid.duplicate(true); bad.regions.erase("hand_r"); bads.append(bad)
	bad = valid.duplicate(true); bad.parts.leg_l.puncture = 0.0; bads.append(bad)
	bad = valid.duplicate(true); bad.wounds.append(bad.wounds[0].duplicate(true)); bads.append(bad)
	bad = valid.duplicate(true); bad.wounds[0].organ = "brain"; bads.append(bad)
	bad = valid.duplicate(true); bad.wounds[0].artery = "carotid"; bads.append(bad)
	bad = valid.duplicate(true); bad.wounds[0].splinted = true; bads.append(bad)
	bad = valid.duplicate(true); bad.medical_supplies = 21; bads.append(bad)
	bad = valid.duplicate(true); bad.medical_supplies = 1.5; bads.append(bad)
	bad = valid.duplicate(true); bad.next_wound_id = 1; bads.append(bad)
	bad = valid.duplicate(true); bad.role = "wizard"; bads.append(bad)
	var rejected := true
	for record in bads:
		rejected = rejected and Unit.validate_body(record) != "" and veteran.restore_body(record) != ""
		rejected = rejected and veteran.capture_body() == valid
	_check(rejected, "malformed anatomy, skills, bleeding, identities and kit counts reject atomically")


func _anatomy(world: World, registry: AssetRegistry) -> void:
	var hand := _unit(world, registry)
	_check(hand.hit_locations().size() == 16 and hand.hit_locations().has("neck")
			and hand.hit_locations().has("lower_arm_r") and hand.hit_locations().has("foot_l"),
			"attacks can locate neck, limb segments, hands and feet")
	var hit := hand.receive_hit("hand_r", "slash", 80.0)
	_check(hit.severed and not hand.can_strike() and hand._parts.arm_r.visible
			and hand.hit_locations().has("upper_arm_r") and not hand.hit_locations().has("hand_r"),
			"a lost sword hand disables weapons while retaining the upper-arm visual and targets")
	var plate := _unit(world, registry)
	plate.equip_armor("plate")
	hit = plate.receive_hit("chest", "stab", 36.0, 0.1)
	_check(hit.penetrating == 0.0 and hit.organ == "" and Model.bleeding_rate(plate.capture_body()) == 0.0,
			"plate over mail stops a chest point before it reaches organs or opens a bleed")
	var pierced := _unit(world, registry)
	hit = pierced.receive_hit("chest", "stab", 30.0, 0.1)
	var chest := pierced.capture_body()
	_check(hit.organ == "heart" and chest.organs.heart > 0.0 and chest.wounds[0].internal_bleeding > 0.0,
			"an unarmored penetrating chest wound records an injured organ and internal bleeding")
	var internal: float = chest.wounds[0].internal_bleeding
	Model.treat(chest, chest.wounds[0].id, "bandage", 80.0)
	_check(chest.wounds[0].internal_bleeding == internal and chest.organs.heart > 0.0,
			"bandaging an external opening does not repair the heart or erase internal bleeding")
	var neck := Model.healthy()
	hit = Model.hit(neck, "neck", "slash", 35.0)
	_check(not hit.fatal and hit.artery == "carotid", "a carotid wound can leave a living patient who needs urgent help")
	Model.advance(neck, 300.0)
	_check(Model.health(neck) == 0.0, "an untreated severed carotid causes death through elapsed blood loss")


func _bleeding_and_medicine(world: World, registry: AssetRegistry) -> void:
	var untreated := _unit(world, registry)
	untreated.receive_hit("thigh_l", "stab", 35.0)
	var treated := _unit(world, registry, untreated.position + Vector3(1, 0, 0))
	treated.restore_body(untreated.capture_body())
	var medic := _unit(world, registry, untreated.position + Vector3(2, 0, 0))
	_check(medic.configure_medic(2) and medic.medical_role == "medic" and medic.medical_supplies == 2,
			"a field medic owns an explicit finite stock of medical kits")
	var before := medic.capture_body()
	_check(not medic.configure_medic(19) and medic.capture_body() == before,
			"overfilling a medic is rejected without changing their role, skills or supplies")
	medic.position += Vector3(20, 0, 0)
	_check(medic.can_treat(treated) and not medic.treat(treated).ok and medic.medical_supplies == 2,
			"triage can identify a distant patient but treatment cannot happen remotely")
	medic.position = treated.position + Vector3(1, 0, 0)
	var medicine := medic.skill_level("medicine")
	var result := medic.treat(treated)
	_check(result.ok and result.treatment == "bandage" and medic.medical_supplies == 1
			and medic.skill_level("medicine") > medicine,
			"physical bandaging consumes one real kit and gives medicine practice")
	_check(not medic.treat(treated).ok and medic.medical_supplies == 1,
			"repeating an already-completed bandage consumes no kit")
	untreated.advance_condition(170.0)
	treated.advance_condition(170.0)
	_check(untreated.incapacitated() and untreated.health > 0.0 and untreated.visible
			and not untreated.can_strike() and untreated.mobility_scale() == 0.0,
			"blood loss incapacitates a living visible soldier before it kills them")
	_check(treated.health > 0.0 and not treated.incapacitated() and treated.capture_body().blood > 90.0,
			"prompt pressure bandaging lets the same arterial wound stabilize")
	var saved := untreated.capture_body()
	var resumed := _unit(world, registry)
	_check(resumed.restore_body(saved) == "" and resumed.capture_body() == saved and resumed.incapacitated(),
			"saving an incapacitated patient retains exact blood, shock, wounds and elapsed ages")
	untreated.advance_condition(100.0)
	resumed.advance_condition(100.0)
	_check(untreated.health == 0.0 and resumed.capture_body() == untreated.capture_body(),
			"restoring and continuing an untreated bleed reaches the same permanent death")
	var dead := untreated.capture_body()
	_check(not medic.can_treat(untreated) and not medic.treat(untreated).ok
			and untreated.capture_body() == dead and medic.medical_supplies == 1,
			"a medic cannot revive a dead patient or spend a kit on them")
	var fractured := _unit(world, registry, medic.position + Vector3(1, 0, 0))
	fractured.receive_hit("lower_leg_l", "blunt", 80.0)
	var trauma: float = fractured.capture_body().regions.lower_leg_l.bruise
	var speed := fractured.mobility_scale()
	result = medic.treat(fractured)
	_check(result.ok and result.treatment == "splint" and medic.medical_supplies == 0
			and fractured.mobility_scale() > speed and fractured.capture_body().regions.lower_leg_l.bruise == trauma,
			"the last kit splints a fracture and supports movement without erasing the injury")
	fractured.receive_hit("hand_l", "slash", 12.0)
	var wound := fractured.capture_body()
	_check(not medic.can_treat(fractured) and not medic.treat(fractured).ok and fractured.capture_body() == wound,
			"an empty medic cannot create bandages or silently treat another wound")
	var medic_copy := _unit(world, registry)
	_check(medic_copy.restore_body(medic.capture_body()) == "" and medic_copy.medical_role == "medic"
			and medic_copy.medical_supplies == 0 and medic_copy.skill_level("medicine") == medic.skill_level("medicine"),
			"medical role, depleted supplies and learned skills survive body restoration")


func _skills_and_history(world: World, registry: AssetRegistry) -> void:
	var attacker := _unit(world, registry)
	var defender := _unit(world, registry)
	var initial := attacker.hit_probability(defender)
	attacker.practice("melee", 50.0)
	var trained := attacker.hit_probability(defender)
	defender.practice("dodge", 50.0)
	_check(trained > initial and attacker.hit_probability(defender) < trained,
			"melee practice improves hit probability while a trained opponent dodges more")
	var shocked := Model.healthy()
	shocked.shock = 80.0
	defender.restore_body(shocked)
	_check(defender.incapacitated() and defender.health == 100.0 and attacker.hit_probability(defender) == 0.98,
			"shock can incapacitate without pretending the patient is dead or can dodge")
	defender.advance_condition(900.0)
	_check(not defender.incapacitated() and defender.health > 0.0,
			"a survivor can recover from shock over time without regrowing injured anatomy")
	var crowded := Model.healthy("mail")
	for i in Model.MAX_WOUNDS:
		Model.hit(crowded, "chest", "slash", 0.1)
	var before: int = crowded.next_wound_id
	var hit := Model.hit(crowded, "neck", "slash", 50.0)
	_check(hit.ok and crowded.wounds.size() == Model.MAX_WOUNDS and crowded.next_wound_id == before + 1
			and crowded.wounds.back().region == "neck" and Model.bleeding_rate(crowded) > 0.3
			and Model.validate(crowded) == "",
			"a full wound history compacts old entries and retains bleeding from a newly hit region")
	Model.advance(crowded, 300.0)
	_check(Model.health(crowded) == 0.0, "filling wound history cannot make a soldier immune to a later arterial injury")
	_check(attacker.injury_summary().contains("Blood") and attacker.injury_summary().contains("Shock")
			and attacker.skill_summary().contains("Melee"), "individual inspection exposes condition and learned skills as text")


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
	_legacy_and_validation(world, registry)
	_anatomy(world, registry)
	_bleeding_and_medicine(world, registry)
	_skills_and_history(world, registry)
	world.free()
	await process_frame
	print("Detailed wound regression failures: %d" % _failures)
	quit(1 if _failures else 0)
