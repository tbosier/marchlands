class_name BuildingDefs
extends RefCounted

## Data for every building the player can place.
##
## The table at the bottom is the only thing you edit to add a building; it is
## parsed once into typed `Def` objects, so the rest of the codebase asks
## `def.role` rather than `def.get("role", -1)` and a typo becomes a startup
## error instead of a silent default.
##
## Deliberately small (design doc 33: do not start with hundreds of buildings).

enum Role { SEAT, HOUSING, STORAGE, GATHER_WOOD, GATHER_STONE,
		GATHER_IRON, WORKSHOP, FARM, GRANARY, MARKET, SUPPLY, BARRACKS, RANCH, SCOUT_LODGE, WELL }

## Roles whose buildings exist to hold goods for the settlement at large.
const STORAGE_ROLES := [Role.STORAGE, Role.GRANARY, Role.SEAT]


class Def:
	extends RefCounted

	var type_id := ""
	var asset := ""
	var variants: Array[String] = []
	var display_name := ""
	var description := ""
	var role := Role.HOUSING
	var profession := "labourer"

	var cost: Dictionary = {}          ## Config.Res -> amount
	var build_time := 10.0

	var worker_slots := 0
	var houses := 0
	var storage := 0.0
	var stores: Array[int] = []

	var produces := -1                 ## Config.Res, or -1
	## What a workshop turns into its output, per unit produced.
	var consumes: Dictionary = {}
	var harvest_kind := -1             ## ResourceNodes.Kind, or -1
	var work_radius := 40.0
	## Plots of ground one farmhand works. The field is exactly this many
	## times the number of farmers actually employed — a farm with two hands
	## has two plots under crop, not a dozen.
	var plots_per_worker := 0
	var buildable := true

	## The type this building can grow into (design doc 6.4), and what that
	## costs. Upgrading keeps the structure where it is and rebuilds it in
	## place, which is what preserves the visible history of a settlement:
	## the granary the player put up on day three is still the building that
	## stands there, only larger.
	var upgrades_to := ""
	var upgrade_cost: Dictionary = {}
	var upgrade_time := 24.0

	func can_upgrade() -> bool:
		return upgrades_to != ""

	func is_storage() -> bool:
		return storage > 0.0 and not stores.is_empty()

	func is_public_store() -> bool:
		return STORAGE_ROLES.has(role)

	func is_producer() -> bool:
		return produces >= 0 and worker_slots > 0

	## A workshop makes goods out of other goods rather than out of the ground.
	func is_workshop() -> bool:
		return not consumes.is_empty()

	func is_gatherer() -> bool:
		return harvest_kind >= 0

	func is_farm() -> bool:
		return role == Role.FARM

	func is_ranch() -> bool:
		return role == Role.RANCH

	func is_market() -> bool:
		return role == Role.MARKET

	func is_food_depot() -> bool:
		return role == Role.MARKET or role == Role.SUPPLY

	func stores_resource(res: int) -> bool:
		return stores.has(res)

	func cost_text() -> String:
		return Res.cost_text(cost)

	## Build-bar icon, rendered from this building's own asset by
	## tools/blender/render_icons.py. Null if it has not been rendered.
	func icon() -> Texture2D:
		if type_id == "well":
			return load("res://ui/well.svg")
		var path := "res://assets/icons/%s.png" % asset
		if not ResourceLoader.exists(path):
			return null
		return load(path)

	func random_asset(rng: RandomNumberGenerator) -> String:
		if variants.is_empty():
			return asset
		return variants[rng.randi() % variants.size()]


static var _defs: Dictionary = {}       # type_id -> Def
static var _order: Array[String] = []


static func all() -> Dictionary:
	if _defs.is_empty():
		_build()
	return _defs


static func get_def(type_id: String) -> Def:
	var table := all()
	return table.get(type_id)


static func has(type_id: String) -> bool:
	return all().has(type_id)


## Buildings offered in the build bar, in display order.
static func buildable() -> Array[String]:
	all()
	return _order


static func cost_text(type_id: String) -> String:
	var def := get_def(type_id)
	return def.cost_text() if def else "?"


# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------

static func _build() -> void:
	_defs = {}
	_order = []

	_add({
		"type_id": "keep",
		"asset": "keep_tier1",
		"display_name": "Keep",
		"role": Role.SEAT,
		"description": "Your seat. Stores goods and houses the first settlers.",
		"houses": 6,
		"storage": 400.0,
		"stores": [Config.Res.FOOD, Config.Res.TIMBER, Config.Res.STONE,
				   Config.Res.IRON, Config.Res.TOOLS, Config.Res.HIDES, Config.Res.LEATHER],
		"buildable": false,
	})
	_add({
		"type_id": "house",
		"asset": "house_small_01",
		"variants": ["house_small_01", "house_small_02"],
		"display_name": "House",
		"role": Role.HOUSING,
		"description": "Homes four citizens. Settlers will not come without room.",
		"cost": {Config.Res.TIMBER: 20, Config.Res.STONE: 8},
		"build_time": 26.0,
		"houses": 4,
	})
	_add({
		"type_id": "well",
		"asset": "well",
		"display_name": "Well",
		"role": Role.WELL,
		"description": "A replenishing water source for drinking and firefighting. Keep its water clean.",
		"cost": {Config.Res.TIMBER: 12, Config.Res.STONE: 20},
		"build_time": 24.0,
	})
	_add({
		"type_id": "stockpile",
		"asset": "stockpile",
		"display_name": "Stockpile",
		"role": Role.STORAGE,
		"description": "An open goods yard. Haulers deliver here.",
		"cost": {Config.Res.TIMBER: 12},
		"build_time": 12.0,
		"storage": 250.0,
		"stores": [Config.Res.FOOD, Config.Res.TIMBER, Config.Res.STONE,
				   Config.Res.IRON, Config.Res.TOOLS, Config.Res.HIDES, Config.Res.LEATHER],
	})
	_add({
		"type_id": "market",
		"asset": "stockpile",
		"display_name": "Market",
		"role": Role.MARKET,
		"profession": "vendor",
		"description": "Two vendors bring food to nearby homes. Choose a stocking "
				+ "target to balance local supplies against food kept elsewhere.",
		"cost": {Config.Res.TIMBER: 24, Config.Res.STONE: 8},
		"build_time": 24.0,
		"worker_slots": 2,
		"storage": 120.0,
		"stores": [Config.Res.FOOD],
	})
	_add({
		"type_id": "supply_hut",
		"asset": "stockpile",
		"display_name": "Supply Hut",
		"role": Role.SUPPLY,
		"profession": "quartermaster",
		"description": "Two quartermasters carry food forward from stores and "
				+ "markets. Holds sixty rations close to travelling troops.",
		"cost": {Config.Res.TIMBER: 30, Config.Res.STONE: 12},
		"build_time": 28.0,
		"worker_slots": 2,
		"storage": 80.0,
		"stores": [Config.Res.FOOD],
		"upgrades_to": "fort",
		"upgrade_cost": {Config.Res.TIMBER: 45, Config.Res.STONE: 35, Config.Res.TOOLS: 8},
		"upgrade_time": 40.0,
	})
	_add({
		"type_id": "fort",
		"asset": "stockpile",
		"display_name": "Fort",
		"role": Role.SUPPLY,
		"profession": "quartermaster",
		"description": "A fortified supply yard. Its two quartermasters keep "
				+ "one hundred and twenty rations behind a timber palisade.",
		"build_time": 40.0,
		"worker_slots": 2,
		"storage": 180.0,
		"stores": [Config.Res.FOOD],
		"buildable": false,
	})
	_add({
		"type_id": "barracks",
		"asset": "logging_camp",
		"display_name": "Barracks",
		"role": Role.BARRACKS,
		"description": "Muster a militia company here. Soldiers need real food "
				+ "from a market, supply hut or another reachable store.",
		"cost": {Config.Res.TIMBER: 40, Config.Res.STONE: 20},
		"build_time": 32.0,
	})
	_add({
		"type_id": "scout_lodge", "asset": "logging_camp",
		"display_name": "Scout Lodge", "role": Role.SCOUT_LODGE,
		"description": "Train existing residents in fieldcraft. Each scout collects eight food and two tools before half a day of training, then explores on foot.",
		"cost": {Config.Res.TIMBER: 24, Config.Res.STONE: 8}, "build_time": 24.0,
	})
	_add({
		"type_id": "logging_camp",
		"asset": "logging_camp",
		"display_name": "Logging Camp",
		"role": Role.GATHER_WOOD,
		"profession": "woodcutter",
		"description": "Woodcutters fell nearby trees and carry timber home.",
		"cost": {Config.Res.TIMBER: 15},
		"build_time": 18.0,
		"worker_slots": 3,
		"storage": 60.0,
		"stores": [Config.Res.TIMBER],
		"produces": Config.Res.TIMBER,
		"harvest_kind": ResourceNodes.Kind.TREE,
		"work_radius": 70.0,
	})
	_add({
		"type_id": "quarry",
		"asset": "quarry",
		"display_name": "Quarry",
		"role": Role.GATHER_STONE,
		"profession": "quarrier",
		"description": "Cuts stone from nearby outcrops.",
		"cost": {Config.Res.TIMBER: 18, Config.Res.STONE: 6},
		"build_time": 24.0,
		"worker_slots": 3,
		"storage": 60.0,
		"stores": [Config.Res.STONE],
		"produces": Config.Res.STONE,
		"harvest_kind": ResourceNodes.Kind.STONE,
		"work_radius": 55.0,
	})
	_add({
		"type_id": "farm",
		"asset": "farmhouse",
		"display_name": "Farm",
		"role": Role.FARM,
		"profession": "farmer",
		"description": "Works the fields around it. Yields at harvest.",
		"cost": {Config.Res.TIMBER: 22, Config.Res.STONE: 6},
		"build_time": 22.0,
		"worker_slots": 3,
		"houses": 2,
		"storage": 120.0,
		"stores": [Config.Res.FOOD],
		"produces": Config.Res.FOOD,
		"work_radius": 34.0,
		"plots_per_worker": 1,
	})
	_add({
		"type_id": "mine",
		"asset": "mine",
		"display_name": "Mine",
		"role": Role.GATHER_IRON,
		"profession": "miner",
		"description": "Works an ore outcrop for iron.",
		"cost": {Config.Res.TIMBER: 24, Config.Res.STONE: 10},
		"build_time": 26.0,
		"worker_slots": 3,
		"storage": 60.0,
		"stores": [Config.Res.IRON],
		"produces": Config.Res.IRON,
		"harvest_kind": ResourceNodes.Kind.IRON,
		"work_radius": 60.0,
	})
	_add({
		"type_id": "blacksmith",
		"asset": "blacksmith",
		"display_name": "Blacksmith",
		"role": Role.WORKSHOP,
		"profession": "smith",
		"description": "Works iron and timber into tools. Tools speed every "
				+ "trade in the march.",
		"cost": {Config.Res.TIMBER: 28, Config.Res.STONE: 16},
		"build_time": 30.0,
		"worker_slots": 2,
		"storage": 90.0,
		"stores": [Config.Res.IRON, Config.Res.TIMBER, Config.Res.TOOLS],
		"produces": Config.Res.TOOLS,
		"consumes": {Config.Res.IRON: 2.0, Config.Res.TIMBER: 1.0},
		"work_radius": 12.0,
		"upgrades_to": "forge",
		"upgrade_cost": {Config.Res.TIMBER: 30, Config.Res.STONE: 40,
						 Config.Res.IRON: 10},
		"upgrade_time": 40.0,
	})
	_add({
		"type_id": "forge",
		"asset": "forge",
		"display_name": "Forge",
		"role": Role.WORKSHOP,
		"profession": "smith",
		"description": "Two hearths and a trip hammer. Four smiths, and far "
				+ "more tools than one bench could turn out.",
		"build_time": 40.0,
		"worker_slots": 4,
		"storage": 170.0,
		"stores": [Config.Res.IRON, Config.Res.TIMBER, Config.Res.TOOLS],
		"produces": Config.Res.TOOLS,
		"consumes": {Config.Res.IRON: 2.0, Config.Res.TIMBER: 1.0},
		"work_radius": 14.0,
		"buildable": false,
	})
	_add({
		"type_id": "granary",
		"asset": "granary",
		"display_name": "Granary",
		"role": Role.GRANARY,
		"description": "Keeps grain dry and close to the people who eat it.",
		"cost": {Config.Res.TIMBER: 26, Config.Res.STONE: 14},
		"build_time": 28.0,
		"storage": 500.0,
		"stores": [Config.Res.FOOD],
		"upgrades_to": "grain_warehouse",
		"upgrade_cost": {Config.Res.TIMBER: 40, Config.Res.STONE: 24},
		"upgrade_time": 36.0,
	})
	_add({
		"type_id": "grain_warehouse",
		"asset": "granary_large",
		"display_name": "Grain Warehouse",
		"role": Role.GRANARY,
		"description": "A second storey, a loading stage and twin hoists. "
				+ "Enough grain to carry a march through a bad winter.",
		"build_time": 36.0,
		"storage": 1400.0,
		"stores": [Config.Res.FOOD],
		"buildable": false,
	})
	_add({
		"type_id": "ranch", "asset": "stockpile", "display_name": "Cattle Ranch",
		"role": Role.RANCH, "profession": "rancher",
		"description": "Two ranchers tame wild cattle and lead them home. Research ranching "
				+ "to breed a herd and turn surplus adult cattle into food and hides.",
		"cost": {Config.Res.TIMBER: 24, Config.Res.STONE: 8}, "build_time": 24.0,
		"worker_slots": 2, "storage": 100.0,
		"stores": [Config.Res.FOOD, Config.Res.HIDES], "produces": Config.Res.HIDES,
		"work_radius": 240.0,
	})
	_add({
		"type_id": "tannery", "asset": "logging_camp", "display_name": "Tannery",
		"role": Role.WORKSHOP, "profession": "tanner",
		"description": "After leatherworking research, two tanners cure real hides with bark "
				+ "from timber into leather for armour.",
		"cost": {Config.Res.TIMBER: 24, Config.Res.STONE: 10}, "build_time": 26.0,
		"worker_slots": 2, "storage": 80.0,
		"stores": [Config.Res.HIDES, Config.Res.TIMBER, Config.Res.LEATHER],
		"produces": Config.Res.LEATHER,
		"consumes": {Config.Res.HIDES: 1.0, Config.Res.TIMBER: 0.25},
	})


const _FIELDS := [
	"type_id", "asset", "variants", "display_name", "description", "role",
	"profession", "cost", "build_time", "worker_slots", "houses", "storage",
	"stores", "produces", "consumes", "harvest_kind", "work_radius",
	"plots_per_worker", "buildable",
	"upgrades_to", "upgrade_cost", "upgrade_time",
]


static func _add(row: Dictionary) -> void:
	for key in row:
		assert(_FIELDS.has(key),
				"BuildingDefs: unknown field '%s' in '%s'"
				% [key, row.get("type_id", "?")])

	var def := Def.new()
	def.type_id = row["type_id"]
	def.asset = row["asset"]
	def.display_name = row["display_name"]
	def.role = row["role"]
	def.description = row.get("description", "")
	def.profession = row.get("profession", "labourer")
	def.cost = row.get("cost", {})
	def.build_time = float(row.get("build_time", 10.0))
	def.worker_slots = int(row.get("worker_slots", 0))
	def.houses = int(row.get("houses", 0))
	def.storage = float(row.get("storage", 0.0))
	def.produces = int(row.get("produces", -1))
	def.consumes = row.get("consumes", {})
	def.harvest_kind = int(row.get("harvest_kind", -1))
	def.work_radius = float(row.get("work_radius", 40.0))
	def.plots_per_worker = int(row.get("plots_per_worker", 0))
	def.buildable = bool(row.get("buildable", true))
	def.upgrades_to = String(row.get("upgrades_to", ""))
	def.upgrade_cost = row.get("upgrade_cost", {})
	def.upgrade_time = float(row.get("upgrade_time", 24.0))

	for v in row.get("variants", []):
		def.variants.append(String(v))
	for r in row.get("stores", []):
		def.stores.append(int(r))

	for res in def.consumes:
		assert(def.stores_resource(res),
				"BuildingDefs: '%s' consumes a resource it cannot store"
				% def.type_id)
	assert(def.produces < 0 or def.stores_resource(def.produces),
			"BuildingDefs: '%s' produces a resource it cannot store"
			% def.type_id)

	_defs[def.type_id] = def
	if def.buildable:
		_order.append(def.type_id)


## Check every definition against the asset registry. Called once at startup so
## a renamed or missing asset is a loud failure rather than a pink box.
static func validate(registry: AssetRegistry) -> Array[String]:
	var problems: Array[String] = []
	for type_id in all():
		var def: Def = _defs[type_id]
		var assets := def.variants.duplicate()
		if assets.is_empty():
			assets.append(def.asset)
		for asset_id in assets:
			if not registry.has(asset_id):
				problems.append("%s: no generated asset '%s'"
						% [type_id, asset_id])
		# An upgrade that names a type nobody defined is a dead button, and a
		# chain that loops is a settlement that can be upgraded forever.
		if def.upgrades_to != "":
			if not _defs.has(def.upgrades_to):
				problems.append("%s: upgrades to unknown type '%s'"
						% [type_id, def.upgrades_to])
			elif def.upgrades_to == type_id:
				problems.append("%s: upgrades to itself" % type_id)
			elif def.upgrade_cost.is_empty():
				problems.append("%s: upgrade to '%s' costs nothing"
						% [type_id, def.upgrades_to])
	return problems
