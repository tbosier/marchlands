class_name RoadResearch
extends RefCounted

## Paid technology belongs to the simulation calendar, independent of the UI.
## Payment is atomic through the supplied callback; saves retain already paid
## work, so restoring or completing it never charges the settlement again.

const TECH_IDS: Array[String] = ["civic_building", "roadworks", "paving", "metallurgy", "fortification",
	"ranching", "leatherworking", "mail", "plate"]
const BENEFITS := {
	"civic_building": "Expand a granary into a grain warehouse; unlock advanced building studies.",
	"roadworks": "Improve proven routes for faster travel; choose how much of the network to fund.",
	"paving": "Commission paved roads, the fastest and most durable surface.",
	"metallurgy": "Upgrade a blacksmith into a forge for greater tool production.",
	"fortification": "Upgrade supply huts into durable forts with larger food stores.",
	"ranching": "Learn from your first domesticated cow to breed a herd and produce food and hides.",
	"leatherworking": "Process hides at a tannery and fit leather protection at a barracks.",
	"mail": "Fit mail armor to resist cuts; it offers less protection against strong thrusts.",
	"plate": "Fit a plate harness over mail for stronger protection against cuts and thrusts.",
}
const TECHS := {
	"civic_building": {"name": "Civic building", "duration_days": 2.0,
		"cost": {Config.Res.TIMBER: 15, Config.Res.STONE: 10}, "requires": ""},
	"roadworks": {"name": "Roadworks", "duration_days": 2.0,
		"cost": {Config.Res.TIMBER: 10, Config.Res.STONE: 5}, "requires": ""},
	"paving": {"name": "Paving", "duration_days": 4.0,
		"cost": {Config.Res.STONE: 30, Config.Res.TOOLS: 10}, "requires": "roadworks"},
	"metallurgy": {"name": "Metallurgy", "duration_days": 3.0,
		"cost": {Config.Res.TIMBER: 15, Config.Res.STONE: 20, Config.Res.TOOLS: 5},
		"requires": "civic_building"},
	"fortification": {"name": "Fortification", "duration_days": 3.0,
		"cost": {Config.Res.TIMBER: 20, Config.Res.STONE: 30, Config.Res.TOOLS: 10},
		"requires": "civic_building"},
	"ranching": {"name": "Ranching", "duration_days": 2.0,
		"cost": {Config.Res.TIMBER: 12, Config.Res.FOOD: 15}, "requires": ""},
	"leatherworking": {"name": "Leatherworking", "duration_days": 2.0,
		"cost": {Config.Res.TIMBER: 15, Config.Res.HIDES: 4}, "requires": "ranching"},
	"mail": {"name": "Mail armor", "duration_days": 3.0,
		"cost": {Config.Res.IRON: 20, Config.Res.LEATHER: 4, Config.Res.TOOLS: 5},
		"requires": "leatherworking"},
	"plate": {"name": "Plate armor", "duration_days": 4.0,
		"cost": {Config.Res.IRON: 35, Config.Res.LEATHER: 6, Config.Res.TOOLS: 10},
		"requires": "mail"},
}

var completed: Array[String] = []
var active := ""
var remaining_days := 0.0
var ranching_known := false


func discover_ranching() -> void:
	ranching_known = true


func quote(tech_id: String, market_built: bool) -> Dictionary:
	if not TECHS.has(tech_id):
		return {"id": tech_id, "name": tech_id, "cost": {}, "duration_days": 0.0,
			"can_start": false, "reason": "Unknown technology", "progress": 0.0,
			"completed": false, "active": false}
	var def: Dictionary = TECHS[tech_id]
	var reason := ""
	if completed.has(tech_id):
		reason = "Already researched"
	elif active != "":
		reason = "Research already in progress"
	elif not market_built:
		reason = "Build a market first"
	elif tech_id == "ranching" and not ranching_known:
		reason = "Send a rancher to domesticate a wild cow first"
	elif def.requires != "" and not completed.has(def.requires):
		reason = "Research %s first" % TECHS[def.requires].name
	var progress := 1.0 if completed.has(tech_id) else 0.0
	if active == tech_id:
		progress = 1.0 - remaining_days / float(def.duration_days)
	return {"id": tech_id, "name": def.name, "cost": def.cost.duplicate(),
		"benefit": BENEFITS[tech_id],
		"duration_days": def.duration_days, "can_start": reason == "", "reason": reason,
		"progress": clampf(progress, 0.0, 1.0), "completed": completed.has(tech_id),
		"active": active == tech_id, "remaining_days": remaining_days if active == tech_id else 0.0}


func start(tech_id: String, market_built: bool, pay: Callable) -> String:
	var offer := quote(tech_id, market_built)
	if not offer.can_start:
		return offer.reason
	if not pay.is_valid() or pay.call(offer.cost.duplicate()) != true:
		return "Not enough available resources"
	active = tech_id
	remaining_days = offer.duration_days
	return ""


## Returns the technology completed this tick, or an empty string.
func advance(delta_days: float) -> String:
	if active == "" or not is_finite(delta_days) or delta_days <= 0.0:
		return ""
	remaining_days = maxf(0.0, remaining_days - delta_days)
	if remaining_days > 0.000000001:
		return ""
	var finished := active
	completed.append(finished)
	active = ""
	remaining_days = 0.0
	return finished


func allows_road_upgrade(level: int) -> bool:
	if level < Config.RoadLevel.WORN or level > Config.RoadLevel.PAVED:
		return false
	return completed.has("paving" if level == Config.RoadLevel.PAVED else "roadworks")

func allows_building_upgrade(type_id: String) -> bool:
	if type_id == "supply_hut":
		return completed.has("fortification")
	return completed.has("metallurgy" if type_id == "blacksmith" else "civic_building")


func building_upgrade_reason(type_id: String) -> String:
	if allows_building_upgrade(type_id):
		return ""
	if type_id == "supply_hut":
		return "Research Fortification first"
	return "Research Metallurgy first" if type_id == "blacksmith" else "Research Civic building first"


func capture() -> Dictionary:
	return {"completed": completed.duplicate(), "active": active, "remaining_days": remaining_days,
		"ranching_known": ranching_known}


func restore(data: Variant) -> String:
	var error := validate(data)
	if error != "":
		return error
	completed.clear()
	for tech_id in data.get("completed", []):
		completed.append(tech_id)
	active = data.get("active", "")
	remaining_days = float(data.get("remaining_days", 0.0))
	# The same default `validate` accepts: a file from before the flag that is
	# researching or has researched ranching had already made the discovery.
	ranching_known = data.get("ranching_known",
			completed.has("ranching") or active == "ranching")
	return ""


static func validate(data: Variant) -> String:
	if not data is Dictionary:
		return "research must be a dictionary"
	# Version-one saves have no research; the integration supplies this default.
	if data.is_empty():
		return ""
	if data.has("ranching_known") and not data.ranching_known is bool:
		return "research.ranching_known must be a boolean"
	if not data.get("completed") is Array or not data.get("active") is String \
			or typeof(data.get("remaining_days")) not in [TYPE_FLOAT, TYPE_INT]:
		return "research requires completed, active and remaining_days"
	var known := {}
	for tech_id in data.completed:
		if not tech_id is String or not TECHS.has(tech_id) or known.has(tech_id):
			return "research.completed contains an unknown or repeated technology"
		known[tech_id] = true
	for tech_id in known:
		var prerequisite: String = TECHS[tech_id].requires
		if prerequisite != "" and not known.has(prerequisite):
			return "research.completed is missing a prerequisite"
	if (known.has("ranching") or data.active == "ranching") \
			and not data.get("ranching_known", true):
		return "ranching research requires a domestication discovery"
	var left := float(data.remaining_days)
	if not is_finite(left) or left < 0.0:
		return "research.remaining_days must be finite and nonnegative"
	if data.active == "":
		return "" if left == 0.0 else "idle research cannot have remaining time"
	if not TECHS.has(data.active) or known.has(data.active):
		return "research.active is unknown or already complete"
	var def: Dictionary = TECHS[data.active]
	if left <= 0.0 or left > float(def.duration_days):
		return "active research time is outside its duration"
	if def.requires != "" and not known.has(def.requires):
		return "research.active is missing a prerequisite"
	return ""
