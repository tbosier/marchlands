class_name Res
extends RefCounted

## The resource table.
##
## Everything about a resource — its name, the prop a citizen is shown
## carrying, how it reads in the interface — lives here, so adding one is a
## single entry rather than a hunt through five files. `Config.Res` remains the
## enum used for array indices; this is the metadata that hangs off it.

class Def:
	var id: int
	var key: String
	var display: String
	var carried_asset: String      ## prop shown in a citizen's hands
	var bulk_asset: String         ## prop shown in a cart bed
	var colour: Color
	var is_food: bool

	func _init(p_id: int, p_key: String, p_display: String,
			   p_carried: String, p_bulk: String, p_colour: Color,
			   p_food: bool = false) -> void:
		id = p_id
		key = p_key
		display = p_display
		carried_asset = p_carried
		bulk_asset = p_bulk
		colour = p_colour
		is_food = p_food


static var _defs: Array[Def] = []


static func all() -> Array[Def]:
	if _defs.is_empty():
		_defs = [
			Def.new(Config.Res.FOOD, "food", "Food",
					"grain_sack", "grain_sack", Color(0.82, 0.70, 0.34), true),
			Def.new(Config.Res.TIMBER, "timber", "Timber",
					"log_pile", "log_pile", Color(0.60, 0.45, 0.28)),
			Def.new(Config.Res.STONE, "stone", "Stone",
					"stone_pile", "stone_pile", Color(0.60, 0.59, 0.56)),
			Def.new(Config.Res.IRON, "iron", "Iron",
					"stone_pile", "crate", Color(0.52, 0.42, 0.40)),
			Def.new(Config.Res.TOOLS, "tools", "Tools",
					"crate", "crate", Color(0.45, 0.50, 0.55)),
		]
	return _defs


static func get_def(res: int) -> Def:
	var list := all()
	if res < 0 or res >= list.size():
		return list[0]
	return list[res]


static func display(res: int) -> String:
	return get_def(res).display


static func carried_asset(res: int) -> String:
	return get_def(res).carried_asset


static func bulk_asset(res: int) -> String:
	return get_def(res).bulk_asset


static func colour(res: int) -> Color:
	return get_def(res).colour


## Format a cost dictionary as "20 Timber, 8 Stone".
static func cost_text(cost: Dictionary) -> String:
	if cost.is_empty():
		return "free"
	var parts: Array[String] = []
	for res in cost:
		parts.append("%d %s" % [int(cost[res]), display(res)])
	return ", ".join(parts)
