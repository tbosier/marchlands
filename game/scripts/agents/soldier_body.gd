extends RefCounted

## Deterministic body damage and armor coverage, independent of scene lifetime.
## Points describe local injury, not a displayed health bar. Plate is worn over
## mail; stopped cuts and points can still transmit a smaller blunt impact.

const LOCATIONS := ["head", "torso", "arm_l", "arm_r", "leg_l", "leg_r"]
const LIMBS := ["arm_l", "arm_r", "leg_l", "leg_r"]
const ARMOR := ["none", "leather", "mail", "plate"]
const KINDS := ["slash", "stab", "blunt"]
const DISABLED_AT := 45.0
const SEVERED_AT := 75.0
# Per-location stopping strength: slash, stab, blunt.
const COVERAGE := {
	"leather": {"head": [8.0, 4.0, 2.0], "torso": [12.0, 6.0, 3.0],
		"arm_l": [6.0, 2.0, 1.0], "arm_r": [6.0, 2.0, 1.0],
		"leg_l": [5.0, 2.0, 1.0], "leg_r": [5.0, 2.0, 1.0]},
	"mail": {"head": [18.0, 10.0, 3.0], "torso": [22.0, 12.0, 4.0],
		"arm_l": [16.0, 8.0, 2.0], "arm_r": [16.0, 8.0, 2.0],
		"leg_l": [12.0, 6.0, 2.0], "leg_r": [12.0, 6.0, 2.0]},
	"plate": {"head": [26.0, 20.0, 7.0], "torso": [32.0, 24.0, 10.0],
		"arm_l": [22.0, 16.0, 6.0], "arm_r": [22.0, 16.0, 6.0],
		"leg_l": [24.0, 18.0, 7.0], "leg_r": [24.0, 18.0, 7.0]},
}


static func healthy(tier: String = "none") -> Dictionary:
	var parts := {}
	for location in LOCATIONS:
		parts[location] = {"bruise": 0.0, "cut": 0.0, "puncture": 0.0, "severed": false}
	return {"version": 1, "armor": tier, "strain": 0.0, "parts": parts}


static func _number(value: Variant, maximum: float = 100.0) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
			and float(value) >= 0.0 and float(value) <= maximum


static func validate(data: Variant) -> String:
	if not data is Dictionary or data.size() != 4:
		return "invalid body state"
	for key in ["version", "armor", "strain", "parts"]:
		if not data.has(key):
			return "incomplete body state"
	if not data.version is int or data.version != 1 or not data.armor is String or data.armor not in ARMOR:
		return "invalid body version or armor"
	if not _number(data.strain) or not data.parts is Dictionary or data.parts.size() != LOCATIONS.size():
		return "invalid body strain or locations"
	for location in LOCATIONS:
		if not data.parts.has(location) or not data.parts[location] is Dictionary:
			return "missing body location"
		var part: Dictionary = data.parts[location]
		if part.size() != 4:
			return "invalid body injury"
		for key in ["bruise", "cut", "puncture"]:
			if not part.has(key) or not _number(part[key]):
				return "invalid injury severity"
		if not part.has("severed") or not part.severed is bool:
			return "invalid missing limb"
		if part.severed and (location not in LIMBS or float(part.cut) < SEVERED_AT):
			return "inconsistent missing limb"
	return ""


static func trauma(part: Dictionary) -> float:
	return minf(100.0, float(part.bruise) * 0.75 + float(part.cut) + float(part.puncture) * 1.2)


static func disabled(part: Dictionary) -> bool:
	return part.severed or trauma(part) >= DISABLED_AT


static func health(data: Dictionary) -> float:
	var parts: Dictionary = data.parts
	var head := trauma(parts.head)
	var torso := trauma(parts.torso)
	if head >= 60.0 or torso >= 100.0:
		return 0.0
	var total := float(data.strain) + torso + head * 1.25
	for location in LIMBS:
		total += trauma(parts[location]) * 0.18
	return maxf(0.0, 100.0 - total)


static func protection(tier: String, location: String, kind: String) -> float:
	if tier == "none" or not COVERAGE.has(tier) or location not in LOCATIONS or kind not in KINDS:
		return 0.0
	var amount: float = COVERAGE[tier][location][KINDS.find(kind)]
	if tier == "plate":
		amount += float(COVERAGE.mail[location][KINDS.find(kind)])
	return amount


static func hit(data: Dictionary, location: String, kind: String, force: float) -> Dictionary:
	if location not in LOCATIONS or kind not in KINDS or not _number(force, 1000.0) or force <= 0.0:
		return {"ok": false, "reason": "invalid hit"}
	if health(data) <= 0.0 or data.parts[location].severed:
		return {"ok": false, "reason": "target location is unavailable"}
	var before := health(data)
	var part: Dictionary = data.parts[location]
	var absorbed := minf(force, protection(data.armor, location, kind))
	var penetrating := force - absorbed
	var transmitted := absorbed * (0.35 if kind == "blunt" else 0.12)
	part.bruise = minf(100.0, float(part.bruise) + transmitted + (penetrating if kind == "blunt" else 0.0))
	var outcome := "bruise"
	if kind == "slash" and penetrating > 0.0:
		part.cut = minf(100.0, float(part.cut) + penetrating)
		outcome = "cut"
		# Light repeated cuts can disable a limb. Severing additionally needs
		# one substantial unabsorbed slash; it is never caused by a stab.
		if location in LIMBS and penetrating >= 40.0 and float(part.cut) >= SEVERED_AT:
			part.severed = true
			outcome = "severed"
	elif kind == "stab" and penetrating > 0.0:
		part.puncture = minf(100.0, float(part.puncture) + penetrating)
		outcome = "puncture"
	var after := health(data)
	return {"ok": true, "location": location, "kind": kind, "outcome": outcome,
		"damage": before - after, "absorbed": absorbed, "severed": part.severed,
		"disabled": disabled(part), "fatal": after <= 0.0}
