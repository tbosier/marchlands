extends "res://tests/long_run.gd"

func _run() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var market := _build(game, "market", game.world.centre() + Vector3(40, 0, 35))
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(-45, 0, -10))
	if market == null or barracks == null:
		game.free()
		quit(1)
		return
	sim.keep.inventory[Config.Res.LEATHER] = 30.0
	sim.keep.inventory[Config.Res.HIDES] = 12.0
	sim.keep.inventory[Config.Res.IRON] = 150.0
	sim.keep.inventory[Config.Res.TIMBER] = 100.0
	sim.keep.inventory[Config.Res.TOOLS] = 100.0
	var opening_people := sim.citizens.size()
	_check(sim.campaign.recruit() == "" and sim.citizens.size() == opening_people - 1,
			"equipment is fitted to a recruited resident, not a newly generated person")
	if sim.campaign.friendly_ids().is_empty():
		game.free()
		quit(1)
		return
	var unit: Soldier = sim.campaign.units[sim.campaign.friendly_ids()[0]]
	unit.position = sim.entrance_of(barracks, "att_cart_bay")
	var before := sim.keep.inventory.duplicate()
	_check(MilitaryEquipment.fit(sim, unit.id, "leather") != "" and sim.keep.inventory == before,
			"armor cannot be bought before its research and rejected fitting charges nothing")
	_check(not sim.research.quote("ranching", true).can_start,
			"ranching must be discovered through domestication before it can be researched")
	sim.research.discover_ranching()
	_check(sim.research.start("ranching", true, sim.stores.try_spend) == "",
			"discovery permits paid ranching research")
	sim.research.advance(2.0)
	var hides := sim.keep.inventory[Config.Res.HIDES]
	_check(sim.research.start("leatherworking", true, sim.stores.try_spend) == ""
			and sim.keep.inventory[Config.Res.HIDES] == hides - 4.0,
			"leatherworking study consumes actual hides from the economy")
	sim.research.advance(2.0)
	before = sim.keep.inventory.duplicate()
	unit.position += Vector3(100, 0, 0)
	_check(MilitaryEquipment.fit(sim, unit.id, "leather") != "" and sim.keep.inventory == before,
			"armor cannot be fitted remotely on the battlefield")
	unit.position = sim.entrance_of(barracks, "att_cart_bay")
	sim.keep.reserved[Config.Res.LEATHER] = sim.keep.inventory[Config.Res.LEATHER]
	_check(MilitaryEquipment.fit(sim, unit.id, "leather") != "" and sim.keep.inventory == before,
			"fitting armor cannot steal leather already reserved for another delivery")
	sim.keep.reserved[Config.Res.LEATHER] = 0.0
	_check(MilitaryEquipment.fit(sim, unit.id, "leather") == "" and unit.armor_tier == "leather"
			and sim.keep.inventory[Config.Res.LEATHER] == before[Config.Res.LEATHER] - 6.0
			and sim.keep.inventory[Config.Res.TOOLS] == before[Config.Res.TOOLS] - 1.0,
			"a researched leather suit consumes its exact materials once")
	before = sim.keep.inventory.duplicate()
	_check(MilitaryEquipment.fit(sim, unit.id, "leather") != "" and sim.keep.inventory == before,
			"repeated clicks cannot charge again for the equipped suit")
	_check(sim.research.start("mail", true, sim.stores.try_spend) == "", "mail study is funded")
	sim.research.advance(3.0)
	_check(sim.research.start("plate", true, sim.stores.try_spend) == "", "plate study is funded after mail")
	sim.research.advance(4.0)
	_check(MilitaryEquipment.fit(sim, unit.id, "plate") == "", "researched plate can be fitted over mail")
	var hit := unit.receive_hit("torso", "stab", 24.0)
	_check(hit.get("outcome") == "bruise" and unit.capture_body().parts.torso.puncture == 0.0,
			"a breastplate over mail stops a moderate stab but transmits a bruise")
	_check(MilitaryEquipment.fit(sim, unit.id, "none") == "", "equipment can be removed without refund")
	unit.receive_hit("arm_r", "slash", 90.0)
	_check(not unit.can_strike() and unit.capture_body().parts.arm_r.severed,
			"an unprotected sword arm can be severed and loses its combat function")
	var body: Dictionary = unit.capture_body()
	var snapshot := SaveGame.capture(game)
	var unit_id := unit.id
	_check(SaveGame.validate(snapshot, game.registry) == "", "wounded resident army produces a valid full save")
	var error := game.restore_from(snapshot)
	_check(error == "" and game.sim.campaign.units[unit_id].capture_body() == body
			and game.sim.research.ranching_known, "full staged load preserves exact injuries and ranching discovery: " + error)
	var bad := SaveGame.capture(game)
	for entry in bad.campaign.units:
		if entry.id == unit_id:
			entry.body.parts.arm_r.cut = NAN
	_check(game.restore_from(bad) != "" and game.sim.campaign.units[unit_id].capture_body() == body,
			"malformed injury state is rejected before touching the live march")
	var legacy := SaveGame.capture(game)
	legacy.erase("resource_layout")
	for entry in legacy.buildings:
		entry.inventory.resize(5)
	for entry in legacy.campaign.buildings:
		entry.inventory.resize(5)
	error = game.restore_from(legacy)
	_check(error == "" and game.sim.keep.inventory.size() == 7
			and game.sim.keep.inventory[Config.Res.HIDES] == 0.0
			and legacy.buildings[0].inventory.size() == 5,
			"five-resource saves migrate with zero new goods without mutating the input: " + error)
	var malformed := SaveGame.capture(game)
	malformed.buildings[0].inventory.resize(5)
	_check(SaveGame.validate(malformed, game.registry) != "", "modern saves cannot disguise a truncated inventory as legacy")
	game.free()
	await process_frame
	print("Military equipment regression failures: %d" % _failures)
	quit(1 if _failures else 0)
