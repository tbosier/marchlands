extends "res://tests/long_run.gd"


func _run() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var campaign: FrontierCampaign = sim.campaign
	campaign.set_personality("peaceful")
	var barracks := _build(game, "barracks", game.world.centre() + Vector3(65, 0, 15))
	if barracks == null:
		quit(1)
		return
	_check(campaign.recruit() == "" and campaign.recruit() == "", "two residents enter military service")
	var ids := campaign.friendly_ids()
	var medic: Soldier = campaign.units[ids[0]]
	var patient: Soldier = campaign.units[ids[1]]
	var door := sim.entrance_of(barracks, "att_cart_bay")
	medic.position = door
	patient.position = door + Vector3(1, 0, 0)
	var tools_before: float = sim.keep.inventory[Config.Res.TOOLS]
	var food_before: float = sim.keep.inventory[Config.Res.FOOD]
	_check(campaign.equip_medic(medic.id) == "" and medic.medical_role == "medic"
		and medic.medical_supplies == 2 and sim.keep.inventory[Config.Res.TOOLS] == tools_before - 4
		and sim.keep.inventory[Config.Res.FOOD] == food_before - 4,
		"field medical kits consume real tools and food without creating another citizen")
	medic.position += Vector3(100, 0, 0)
	tools_before = sim.keep.inventory[Config.Res.TOOLS]
	_check(campaign.equip_medic(medic.id) != "" and medic.medical_supplies == 2
		and sim.keep.inventory[Config.Res.TOOLS] == tools_before,
		"distant medic cannot replenish supplies remotely")
	medic.position = door
	patient.receive_hit("lower_arm_r", "slash", 18.0)
	var bleed_before: float = Soldier.Body.bleeding_rate(patient.capture_body())
	campaign.tick(0.1)
	_check(medic.medical_supplies == 1 and Soldier.Body.bleeding_rate(patient.capture_body()) < bleed_before * 0.2,
		"campaign medic automatically bandages a nearby wounded soldier using one kit")
	var remaining := medic.medical_supplies
	for i in 40: campaign.tick(0.1)
	_check(medic.medical_supplies == remaining, "treated wounds do not repeatedly consume medical kits")
	var saved := SaveGame.capture(game)
	var body := patient.capture_body()
	var barracks_id := barracks.id
	var medic_id := medic.id
	var patient_id := patient.id
	_check(game.restore_from(saved) == "", "a campaign with a field medic and bandaged patient loads")
	sim = game.sim
	campaign = sim.campaign
	medic = campaign.units[medic_id]
	patient = campaign.units[patient_id]
	_check(medic.medical_role == "medic" and medic.medical_supplies == remaining
		and patient.capture_body() == body, "loading preserves kits, skills, blood and individual treatments")
	var civilian_patient_id: int = campaign._civilian_ids[patient.id]
	_check(campaign.demobilize(patient.id) == "" and sim.citizens_by_id.get(civilian_patient_id) == patient,
		"an injured veteran keeps their body when returning to civilian work")
	patient.receive_hit("lower_arm_l", "slash", 18.0)
	medic.cooldown = 0.0
	bleed_before = Soldier.Body.bleeding_rate(patient.capture_body())
	campaign.tick(0.1)
	_check(medic.medical_supplies == remaining - 1
		and Soldier.Body.bleeding_rate(patient.capture_body()) < bleed_before * 0.3,
		"active medic physically treats a civilian veteran and consumes one kit")
	barracks = sim.buildings_by_id[barracks_id]
	medic.position = sim.entrance_of(barracks, "att_cart_bay")
	_check(campaign.equip_medic(medic.id) == "", "medic replenishes real kits for another field patient")
	var lodge := _build(game, "scout_lodge", game.world.centre() + Vector3(-48, 0, 24))
	patient.rations = 0.0
	patient.receive_hit("lower_arm_r", "slash", 18.0)
	_check(sim.scouting.train(lodge.id, civilian_patient_id) == ""
		and sim.scouting.scouts.values()[0].person == patient,
		"scout service keeps the wounded veteran rather than replacing their body")
	medic.position = patient.position + Vector3(1, 0, 0)
	medic.cooldown = 0.0
	remaining = medic.medical_supplies
	bleed_before = Soldier.Body.bleeding_rate(patient.capture_body())
	campaign.tick(0.1)
	_check(medic.medical_supplies == remaining - 1
		and Soldier.Body.bleeding_rate(patient.capture_body()) < bleed_before * 0.35,
		"active medic reaches and bandages a veteran scout using one finite kit")
	# Compare treated and untreated catastrophic bleeding without regeneration.
	var untreated: Soldier = campaign.units.values().filter(func(u): return u.faction == 1)[0]
	untreated.receive_hit("neck", "slash", 35.0)
	var lost_id := untreated.id
	var population_before: int = campaign.town_population + campaign.units.size() - campaign.friendly_ids().size()
	for i in 300:
		campaign.tick(1.0)
		if not campaign.units.has(lost_id): break
	_check(not campaign.units.has(lost_id) and campaign.town_population + campaign.units.size() - campaign.friendly_ids().size() == population_before - 1,
		"an untreated severed neck artery bleeds out and permanently removes the person")
	game.free()
	await process_frame
	print("Field medicine regression failures: %d" % _failures)
	quit(1 if _failures else 0)
