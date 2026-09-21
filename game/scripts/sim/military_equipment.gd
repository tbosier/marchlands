class_name MilitaryEquipment
extends RefCounted

## Equipment is fitted to an existing person at a working barracks. Research
## unlocks the pattern; each suit still consumes physical, unreserved stock.
const TIERS: Array[String] = ["none", "leather", "mail", "plate"]
const TECH := {"leather": "leatherworking", "mail": "mail", "plate": "plate"}
const COSTS := {
	"none": {},
	"leather": {Config.Res.LEATHER: 6, Config.Res.TOOLS: 1},
	"mail": {Config.Res.LEATHER: 3, Config.Res.IRON: 12, Config.Res.TOOLS: 2},
	"plate": {Config.Res.LEATHER: 4, Config.Res.IRON: 24, Config.Res.TOOLS: 4},
}
const REACH := 24.0


static func quote(sim: Simulation, unit_id: int, tier: String) -> Dictionary:
	var reason := ""
	var unit: Soldier = sim.campaign.units.get(unit_id) if sim.campaign != null else null
	if tier not in TIERS:
		reason = "Unknown armor pattern"
	elif unit == null or unit.faction != 0:
		reason = "Select one of your soldiers"
	elif unit.health <= 0.0:
		reason = "This soldier has fallen"
	elif unit.armor_tier == tier:
		reason = "Already equipped"
	elif tier != "none" and not sim.research.completed.has(TECH[tier]):
		reason = "Research %s first" % RoadResearch.TECHS[TECH[tier]].name
	else:
		var nearby := false
		for building in sim.buildings:
			if building.type_id == "barracks" and not building.under_construction \
					and unit.position.distance_to(sim.entrance_of(building, "att_cart_bay")) <= REACH \
					and sim.world.nav.can_reach(unit.position, sim.entrance_of(building, "att_cart_bay")):
				nearby = true
				break
		if not nearby:
			reason = "Return within 24 m of a completed barracks"
		elif not sim.stores.can_afford(COSTS[tier]):
			reason = "Not enough unreserved materials"
	return {"tier": tier, "cost": COSTS.get(tier, {}).duplicate(),
		"can_fit": reason == "", "reason": reason}


static func fit(sim: Simulation, unit_id: int, tier: String) -> String:
	var offer := quote(sim, unit_id, tier)
	if not offer.can_fit:
		return offer.reason
	var unit: Soldier = sim.campaign.units.get(unit_id)
	if not sim.stores.try_spend(offer.cost):
		return "Those materials are already reserved"
	unit.equip_armor(tier)
	return ""
