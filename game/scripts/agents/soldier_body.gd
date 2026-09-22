extends RefCounted

## Located trauma is authoritative; health is a compatibility value for death
## checks. Legacy six-part bodies migrate to detailed regions without inventing
## fresh bleeding in a veteran's old, already-survived injuries.
const LOCATIONS := ["head", "torso", "arm_l", "arm_r", "leg_l", "leg_r"]
const LIMBS := ["arm_l", "arm_r", "leg_l", "leg_r"]
const REGIONS := ["head", "neck", "chest", "abdomen", "upper_arm_l", "lower_arm_l", "hand_l",
	"upper_arm_r", "lower_arm_r", "hand_r", "thigh_l", "lower_leg_l", "foot_l", "thigh_r", "lower_leg_r", "foot_r"]
const GROUPS := {"head": ["head", "neck"], "torso": ["chest", "abdomen"],
	"arm_l": ["upper_arm_l", "lower_arm_l", "hand_l"], "arm_r": ["upper_arm_r", "lower_arm_r", "hand_r"],
	"leg_l": ["thigh_l", "lower_leg_l", "foot_l"], "leg_r": ["thigh_r", "lower_leg_r", "foot_r"]}
const ALIASES := {"torso": "chest", "arm_l": "upper_arm_l", "arm_r": "upper_arm_r", "leg_l": "thigh_l", "leg_r": "thigh_r"}
const ORGANS := ["brain", "heart", "lung_l", "lung_r", "liver", "gut"]
const SKILLS := ["melee", "dodge", "medicine", "scouting"]
const ARMOR := ["none", "leather", "mail", "plate"]
const KINDS := ["slash", "stab", "blunt"]
const DISABLED_AT := 45.0
const SEVERED_AT := 75.0
const MAX_WOUNDS := 128
const MAX_MEDICAL_SUPPLIES := 20
const COVERAGE := {
	"leather": {"head": [8.0, 4.0, 2.0], "torso": [12.0, 6.0, 3.0],
		"arm_l": [6.0, 2.0, 1.0], "arm_r": [6.0, 2.0, 1.0], "leg_l": [5.0, 2.0, 1.0], "leg_r": [5.0, 2.0, 1.0]},
	"mail": {"head": [18.0, 10.0, 3.0], "torso": [22.0, 12.0, 4.0],
		"arm_l": [16.0, 8.0, 2.0], "arm_r": [16.0, 8.0, 2.0], "leg_l": [12.0, 6.0, 2.0], "leg_r": [12.0, 6.0, 2.0]},
	"plate": {"head": [26.0, 20.0, 7.0], "torso": [32.0, 24.0, 10.0],
		"arm_l": [22.0, 16.0, 6.0], "arm_r": [22.0, 16.0, 6.0], "leg_l": [24.0, 18.0, 7.0], "leg_r": [24.0, 18.0, 7.0]},
}


static func _part() -> Dictionary:
	return {"bruise": 0.0, "cut": 0.0, "puncture": 0.0, "severed": false}


static func healthy(tier: String = "none") -> Dictionary:
	var regions := {}
	for region in REGIONS: regions[region] = _part()
	var organs := {}
	for organ in ORGANS: organs[organ] = 0.0
	return {"version": 2, "armor": tier, "strain": 0.0, "parts": _project_parts(regions),
		"regions": regions, "wounds": [], "organs": organs, "blood": 100.0, "shock": 0.0,
		"skills": {"melee": 35.0, "dodge": 25.0, "medicine": 15.0, "scouting": 10.0},
		"role": "soldier", "medical_supplies": 0, "next_wound_id": 1}


static func _project_parts(regions: Dictionary) -> Dictionary:
	var parts := {}
	for group in LOCATIONS:
		var part := _part()
		for region in GROUPS[group]:
			for kind in ["bruise", "cut", "puncture"]:
				part[kind] = minf(100.0, float(part[kind]) + float(regions[region][kind]))
		# The old visual rig has whole limbs. Distal wounds disable their
		# functions without hiding an intact upper arm or thigh.
		part.severed = bool(regions[GROUPS[group][0]].severed)
		parts[group] = part
	return parts


static func _number(value: Variant, maximum: float = 100.0) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= maximum


static func _valid_part(part: Variant, can_sever: bool) -> bool:
	if not part is Dictionary or part.size() != 4: return false
	for key in ["bruise", "cut", "puncture"]:
		if not part.has(key) or not _number(part[key]): return false
	return part.has("severed") and part.severed is bool and (not part.severed or (can_sever and float(part.cut) >= SEVERED_AT))


static func validate(data: Variant) -> String:
	if not data is Dictionary: return "invalid body state"
	for key in ["version", "armor", "strain", "parts"]:
		if not data.has(key): return "incomplete body state"
	if not data.version is int or data.version not in [1, 2] or not data.armor is String or data.armor not in ARMOR:
		return "invalid body version or armor"
	if not _number(data.strain) or not data.parts is Dictionary or data.parts.size() != LOCATIONS.size():
		return "invalid body strain or locations"
	for location in LOCATIONS:
		if not data.parts.has(location) or not _valid_part(data.parts[location], location in LIMBS): return "invalid body injury"
	if data.version == 1:
		return "" if data.size() == 4 else "invalid legacy body fields"
	if data.size() != 13: return "invalid detailed body fields"
	for key in ["regions", "wounds", "organs", "blood", "shock", "skills", "role", "medical_supplies", "next_wound_id"]:
		if not data.has(key): return "incomplete detailed body"
	if not data.regions is Dictionary or data.regions.size() != REGIONS.size(): return "invalid body regions"
	for region in REGIONS:
		if not data.regions.has(region) or not _valid_part(data.regions[region], region not in ["head", "neck", "chest", "abdomen"]):
			return "invalid regional injury"
	var projected := _project_parts(data.regions)
	for location in LOCATIONS:
		for key in ["bruise", "cut", "puncture"]:
			if not is_equal_approx(float(projected[location][key]), float(data.parts[location][key])): return "body regions disagree with visible limbs"
		if projected[location].severed != data.parts[location].severed: return "body regions disagree with missing limbs"
	if not _number(data.blood) or not _number(data.shock): return "invalid blood or shock"
	if not data.organs is Dictionary or data.organs.size() != ORGANS.size(): return "invalid organs"
	for organ in ORGANS:
		if not data.organs.has(organ) or not _number(data.organs[organ]): return "invalid organ injury"
	if not data.skills is Dictionary or data.skills.size() != SKILLS.size(): return "invalid skills"
	for skill in SKILLS:
		if not data.skills.has(skill) or not _number(data.skills[skill]): return "invalid skill level"
	if not data.role is String or data.role not in ["soldier", "medic"]: return "invalid military role"
	if not data.medical_supplies is int or data.medical_supplies < 0 or data.medical_supplies > MAX_MEDICAL_SUPPLIES:
		return "invalid medical supplies"
	if not data.next_wound_id is int or data.next_wound_id < 1 or data.next_wound_id > 1000000000: return "invalid wound counter"
	if not data.wounds is Array or data.wounds.size() > MAX_WOUNDS: return "invalid wound history"
	var ids := {}
	for wound in data.wounds:
		if not wound is Dictionary or wound.size() != 13: return "invalid wound record"
		for key in ["id", "region", "kind", "severity", "bleeding", "internal_bleeding", "artery", "organ", "fracture", "bandaged", "splinted", "age", "penetrating"]:
			if not wound.has(key): return "incomplete wound"
		if not wound.id is int or wound.id < 1 or wound.id >= data.next_wound_id or ids.has(wound.id): return "invalid wound identity"
		ids[wound.id] = true
		if not wound.region is String or wound.region not in REGIONS or not wound.kind is String or wound.kind not in KINDS:
			return "invalid wound location or type"
		for key in ["severity", "penetrating"]:
			if not _number(wound[key], 1000.0): return "invalid wound severity"
		for key in ["bleeding", "internal_bleeding"]:
			if not _number(wound[key], 10.0): return "invalid bleeding rate"
		if not _number(wound.age, 1000000000.0): return "invalid wound age"
		for key in ["fracture", "bandaged", "splinted"]:
			if not wound[key] is bool: return "invalid treatment state"
		if wound.splinted and not wound.fracture: return "splint without fracture"
		if wound.fracture and wound.region in ["head", "neck", "chest", "abdomen"]: return "invalid splintable fracture"
		if wound.fracture and wound.kind != "blunt": return "invalid fracture cause"
		if not wound.artery is String or (wound.artery != "" and wound.artery != _artery(wound.region)): return "invalid arterial injury"
		if not wound.organ is String or (wound.organ != "" and wound.organ not in _organs_at(wound.region)): return "invalid wound organ"
		if wound.bleeding > 0.0 and (wound.kind == "blunt" or wound.penetrating <= 0.0): return "external bleeding requires a penetrating wound"
		if wound.artery != "" and (wound.kind == "blunt" or wound.penetrating <= 0.0): return "invalid arterial penetration"
		if wound.internal_bleeding > 0.0 and wound.organ == "": return "internal bleeding requires an injured organ"
		if wound.organ != "" and float(data.organs[wound.organ]) <= 0.0: return "wound organ has no recorded injury"
		if wound.severity < wound.penetrating: return "penetration exceeds wound severity"
		if wound.bandaged and wound.kind == "blunt": return "a closed bruise cannot be bandaged"
		if trauma(data.regions[wound.region]) <= 0.0: return "wound has no regional injury"
	return ""


static func migrate(data: Dictionary) -> Dictionary:
	if data.version == 2: return data.duplicate(true)
	var result := healthy(data.armor)
	result.strain = float(data.strain)
	for location in LOCATIONS:
		result.regions[ALIASES.get(location, location)] = data.parts[location].duplicate(true)
	result.parts = _project_parts(result.regions)
	return result


static func trauma(part: Dictionary) -> float:
	return minf(100.0, float(part.bruise) * 0.75 + float(part.cut) + float(part.puncture) * 1.2)


static func disabled(part: Dictionary) -> bool:
	return part.severed or trauma(part) >= DISABLED_AT


static func health(data: Dictionary) -> float:
	var head := trauma(data.parts.head)
	var torso := trauma(data.parts.torso)
	if head >= 60.0 or torso >= 100.0: return 0.0
	if data.get("version", 1) == 2:
		if data.blood <= 20.0 or data.organs.brain >= 70.0 or data.organs.heart >= 60.0: return 0.0
	var total := float(data.strain) + torso + head * 1.25
	for location in LIMBS: total += trauma(data.parts[location]) * 0.18
	return maxf(0.0, 100.0 - total)


static func incapacitated(data: Dictionary) -> bool:
	return health(data) > 0.0 and data.get("version", 1) == 2 and (data.blood <= 50.0 or data.shock >= 65.0
		or data.organs.brain >= 35.0 or float(data.organs.lung_l) + float(data.organs.lung_r) >= 90.0)


static func group_of(region: String) -> String:
	for group in LOCATIONS:
		if region in GROUPS[group]: return group
	return ""


static func available(data: Dictionary, region: String) -> bool:
	if region not in REGIONS or health(data) <= 0.0: return false
	for parent in GROUPS[group_of(region)]:
		if data.regions[parent].severed: return false
		if parent == region: return true
	return false


## The limb's own condition, with the systemic gate (dead, bled white,
## unconscious) left to the caller. Splitting it out is purely for the benefit
## of callers that ask about several limbs in a row: `health()` walks all six
## parts, and `incapacitated()` calls `health()` again before looking at blood,
## shock and organs, so each `usable()` below costs two whole-body walks and
## asking four limbs costs eight — for a systemic answer that cannot have
## changed between the four questions. Soldier's per-frame cache settles the
## gate once and comes straight here. Nothing about the verdict differs;
## `usable()` below is still the complete question and remains what callers
## without such a cache should ask.
static func limb_usable(data: Dictionary, group: String) -> bool:
	for region in GROUPS[group]:
		var part: Dictionary = data.regions[region]
		if part.severed: return false
	var effective := trauma(data.parts[group])
	var fractures := 0
	var supported := 0
	for wound in data.wounds:
		if wound.region in GROUPS[group] and wound.fracture:
			fractures += 1
			supported += int(wound.splinted)
	if fractures > 0 and fractures == supported:
		var part: Dictionary = data.parts[group]
		effective = float(part.cut) + float(part.puncture) * 1.2 + float(part.bruise) * 0.25
	return effective < DISABLED_AT


static func usable(data: Dictionary, group: String) -> bool:
	if health(data) <= 0.0 or incapacitated(data): return false
	return limb_usable(data, group)


static func protection(tier: String, location: String, kind: String) -> float:
	var region: String = ALIASES.get(location, location)
	var group := group_of(region)
	if tier == "none" or not COVERAGE.has(tier) or group == "" or kind not in KINDS: return 0.0
	var amount: float = COVERAGE[tier][group][KINDS.find(kind)]
	if tier == "plate": amount += float(COVERAGE.mail[group][KINDS.find(kind)])
	if region == "neck": amount *= 0.5
	elif region.begins_with("hand") or region.begins_with("foot"): amount *= 0.65
	return amount


static func _artery(region: String) -> String:
	if region == "neck": return "carotid"
	if region.begins_with("upper_arm"): return "brachial"
	if region.begins_with("lower_arm"): return "radial"
	if region.begins_with("thigh"): return "femoral"
	if region.begins_with("lower_leg"): return "tibial"
	return ""


static func _organs_at(region: String) -> Array:
	if region == "head": return ["brain"]
	if region == "chest": return ["heart", "lung_l", "lung_r"]
	if region == "abdomen": return ["liver", "gut"]
	return []


static func hit(data: Dictionary, location: String, kind: String, force: float, anatomy_roll: float = 0.5) -> Dictionary:
	var region: String = ALIASES.get(location, location)
	if region not in REGIONS or kind not in KINDS or not _number(force, 1000.0) or force <= 0.0 or not _number(anatomy_roll, 1.0):
		return {"ok": false, "reason": "invalid hit"}
	if not available(data, region): return {"ok": false, "reason": "target location is unavailable"}
	var before := health(data)
	var part: Dictionary = data.regions[region]
	var absorbed := minf(force, protection(data.armor, region, kind))
	var penetrating := force - absorbed
	var transmitted := absorbed * (0.35 if kind == "blunt" else 0.12)
	part.bruise = minf(100.0, float(part.bruise) + transmitted + (penetrating if kind == "blunt" else 0.0))
	var outcome := "bruise"
	if kind == "slash" and penetrating > 0.0:
		part.cut = minf(100.0, float(part.cut) + penetrating)
		outcome = "cut"
		if group_of(region) in LIMBS and penetrating >= 40.0 and float(part.cut) >= SEVERED_AT:
			part.severed = true
			outcome = "severed"
	elif kind == "stab" and penetrating > 0.0:
		part.puncture = minf(100.0, float(part.puncture) + penetrating)
		outcome = "puncture"
	data.parts = _project_parts(data.regions)
	var artery := ""
	var organ := ""
	var external := penetrating * (0.0012 if kind == "stab" else 0.0008) if kind != "blunt" else 0.0
	if kind != "blunt" and penetrating >= (22.0 if region == "neck" else 32.0) and _artery(region) != "":
		artery = _artery(region)
		external += 0.20 + penetrating * 0.003
	var internal := 0.0
	if region == "head" and penetrating >= 25.0:
		organ = "brain"
	elif region == "chest" and kind == "stab" and penetrating >= 18.0:
		organ = "heart" if anatomy_roll < 0.18 else ("lung_l" if anatomy_roll < 0.60 else "lung_r")
	elif region == "abdomen" and penetrating >= 20.0 and kind != "blunt":
		organ = "liver" if anatomy_roll < 0.4 else "gut"
	if organ != "":
		data.organs[organ] = minf(100.0, float(data.organs[organ]) + penetrating * (0.8 if organ == "brain" else 0.75))
		internal = penetrating * (0.004 if organ in ["heart", "liver"] else 0.002)
	var fracture := kind == "blunt" and penetrating >= 32.0 and group_of(region) in LIMBS
	var wound := {"id": data.next_wound_id, "region": region, "kind": kind,
		"severity": penetrating + transmitted, "penetrating": penetrating, "bleeding": external,
		"internal_bleeding": internal, "artery": artery, "organ": organ, "fracture": fracture,
		"bandaged": false, "splinted": false, "age": 0.0}
	# Bounded history merges two existing entries of the same region/type
	# before admitting a new wound, never discarding its active bleeding.
	if data.wounds.size() >= MAX_WOUNDS:
		_compact_history(data)
	data.wounds.append(wound)
	data.next_wound_id += 1
	data.shock = minf(100.0, float(data.shock) + penetrating * 0.1 + transmitted * 0.05)
	var after := health(data)
	return {"ok": true, "location": location, "region": region, "kind": kind, "outcome": outcome,
		"damage": before - after, "absorbed": absorbed, "penetrating": penetrating, "severed": part.severed,
		"disabled": not usable(data, group_of(region)), "fatal": after <= 0.0, "wound_id": wound.id,
		"artery": artery, "organ": organ}


static func _compact_history(data: Dictionary) -> void:
	var seen := {}
	for index in data.wounds.size():
		var wound: Dictionary = data.wounds[index]
		var key: String = wound.region + ":" + wound.kind
		if seen.has(key):
			var old: Dictionary = data.wounds[seen[key]]
			old.severity = minf(1000.0, float(old.severity) + float(wound.severity))
			old.penetrating = minf(1000.0, float(old.penetrating) + float(wound.penetrating))
			old.bleeding = minf(10.0, float(old.bleeding) + float(wound.bleeding))
			old.internal_bleeding = minf(10.0, float(old.internal_bleeding) + float(wound.internal_bleeding))
			old.fracture = old.fracture or wound.fracture
			old.bandaged = old.bandaged and wound.bandaged
			old.splinted = old.splinted and wound.splinted
			if wound.artery != "": old.artery = wound.artery
			if wound.organ != "": old.organ = wound.organ
			data.wounds.remove_at(index)
			return
		seen[key] = index


static func bleeding_rate(data: Dictionary) -> float:
	var rate := 0.0
	for wound in data.wounds: rate += float(wound.bleeding) + float(wound.internal_bleeding)
	return rate


## Returns whether anything in `data` actually moved. Every mutation below is
## to `blood`, to `shock`, or to a wound's age and bleeding, so those three
## facts decide it exactly — the blood and shock comparisons are deliberately
## exact rather than approximate, because a tick that changes a float's last
## bit is a tick the save fingerprint will notice. Callers ignoring the return
## lose nothing; Soldier uses it to leave its derived cache standing for the
## unwounded, unshocked, full-blooded soldier, which is most of a marching
## army and for whom this function provably does nothing at all.
static func advance(data: Dictionary, delta: float) -> bool:
	if not is_finite(delta) or delta <= 0.0 or health(data) <= 0.0: return false
	var blood_before := float(data.blood)
	var shock_before := float(data.shock)
	var lost := 0.0
	for wound in data.wounds:
		wound.age = minf(1000000000.0, float(wound.age) + delta)
		# Ordinary wounds clot slowly; pressure bandages permit severed
		# arteries to clot too. Deep internal wounds are not cured by a wrap.
		var tau := 120.0 if wound.bandaged else (300.0 if wound.artery == "" else INF)
		var factor := exp(-delta / tau) if is_finite(tau) else 1.0
		lost += float(wound.bleeding) * (tau * (1.0 - factor) if is_finite(tau) else delta)
		wound.bleeding *= factor
		var internal_factor := exp(-delta / 1800.0)
		lost += float(wound.internal_bleeding) * 1800.0 * (1.0 - internal_factor)
		wound.internal_bleeding *= internal_factor
	data.blood = maxf(0.0, float(data.blood) - lost)
	data.shock = clampf(float(data.shock) + lost * 0.7 - delta * 0.025, 0.0, 100.0)
	# Stabilization is not instant healing. Surviving patients replenish blood
	# slowly only after bleeding subsides; dead bodies never enter this path.
	if data.blood > 20.0 and bleeding_rate(data) < 0.001:
		data.blood = minf(100.0, float(data.blood) + delta * 0.015)
	# A body carrying wounds always changed: every wound's age advanced above.
	return not data.wounds.is_empty() or float(data.blood) != blood_before \
			or float(data.shock) != shock_before


static func treatment_need(data: Dictionary) -> Dictionary:
	if health(data) <= 0.0: return {}
	var result := {}
	var priority := -1.0
	for wound in data.wounds:
		if wound.bleeding > 0.0001 and not wound.bandaged:
			var urgency := 10.0 + float(wound.bleeding) * 100.0
			if urgency > priority:
				priority = urgency
				result = {"wound_id": wound.id, "treatment": "bandage", "region": wound.region, "priority": urgency}
		elif wound.fracture and not wound.splinted and not data.regions[wound.region].severed and priority < 5.0:
			priority = 5.0
			result = {"wound_id": wound.id, "treatment": "splint", "region": wound.region, "priority": priority}
	return result


static func treat(data: Dictionary, wound_id: int, treatment: String, skill: float) -> Dictionary:
	if health(data) <= 0.0 or not _number(skill) or treatment not in ["bandage", "splint"]:
		return {"ok": false, "reason": "Treatment is unavailable"}
	for wound in data.wounds:
		if wound.id != wound_id: continue
		if treatment == "bandage":
			if wound.bandaged or wound.bleeding <= 0.0001: return {"ok": false, "reason": "This wound needs no bandage"}
			wound.bandaged = true
			wound.bleeding *= lerpf(0.14, 0.02, skill / 100.0)
		else:
			if not wound.fracture or wound.splinted or data.regions[wound.region].severed:
				return {"ok": false, "reason": "This wound cannot be splinted"}
			wound.splinted = true
		data.shock = maxf(0.0, float(data.shock) - 3.0 - skill * 0.05)
		return {"ok": true, "treatment": treatment, "region": wound.region, "wound_id": wound.id}
	return {"ok": false, "reason": "The wound is no longer present"}
