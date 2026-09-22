extends RefCounted

## Validate data before any world, clock, selection, or inventory is changed.
## Optional fields are the additions made during save version 1; their restore
## defaults remain supported. Packed arrays must have exactly the expected size.

# Generous gameplay bounds also leave headroom for float32 storage, arithmetic
# and integer calendar/ID conversions. Finiteness alone does not prevent those
# downstream conversions from overflowing.
const MAX_NUMBER := 1.0e12
const MAX_ENTITY_ID := 2147483647
const MAX_SEED := 4611686018427387903
const ENTITY_EDGE_MARGIN := 8.0

static func validate(data: Variant, registry: AssetRegistry = null,
		expected_version: int = 1) -> String:
	if not data is Dictionary:
		return "save must be a dictionary"
	var settings: Variant = data.get("world_settings", {})
	var settings_error := _world_settings(settings)
	if settings_error != "": return settings_error
	var world_size: float = settings.get("size_m", Config.WORLD_SIZE)
	var error := _fields(data, {
		"version": TYPE_INT, "seed": TYPE_INT, "day": TYPE_FLOAT,
		"elapsed_days": TYPE_FLOAT, "speed_index": TYPE_INT,
		"next_building_id": TYPE_INT, "next_citizen_id": TYPE_INT,
		"terrain_edits": TYPE_ARRAY, "wear": TYPE_DICTIONARY,
		"nodes": TYPE_DICTIONARY, "buildings": TYPE_ARRAY,
		"citizens": TYPE_ARRAY, "cart": TYPE_BOOL, "cart_position": TYPE_VECTOR3,
	}, "save")
	if error != "":
		return error
	if data.version != expected_version:
		return "save is version %d, this build reads version %d" \
				% [data.version, expected_version]
	if data.get("resource_layout", 2) != 2:
		return "unknown resource layout"
	error = RoadResearch.validate(data.get("research", {}))
	if error != "": return "research: " + error
	# This first pass checks the campaign schema. Player-target references
	# are checked below, after the complete friendly building table is known.
	error = FrontierCampaign.validate(data.get("campaign", {}), null, world_size)
	if error != "": return "campaign: " + error
	error = Husbandry.validate(data.get("husbandry", {}), world_size)
	if error != "": return "husbandry: " + error
	error = Bridges.validate(data.get("bridges", {}), world_size)
	if error != "": return "bridges: " + error
	error = TradeRoutes.validate(data.get("trade", {}), world_size)
	if error != "": return "trade: " + error
	error = Scouting.validate(data.get("scouting", {}), world_size)
	if error != "": return "scouting: " + error
	error = WaterSystem.validate(data.get("water", {}), world_size)
	if error != "": return "water: " + error
	if data.seed < -MAX_SEED or data.seed > MAX_SEED:
		return "save seed exceeds the supported range"
	error = _fields(data, {"saved_at": TYPE_STRING, "day_marker": TYPE_FLOAT,
		"resume_speed_index": TYPE_INT, "speed_layout": TYPE_INT,
		"resource_layout": TYPE_INT}, "save", true)
	if error != "":
		return error
	if data.get("speed_layout", 1) not in [1, 2]:
		return "unknown speed menu version"
	if data.day < 0 or data.elapsed_days < 0:
		return "save days must be nonnegative"
	if data.get("day_marker", data.day) < 0 \
			or data.get("day_marker", data.day) > data.day:
		return "save.day_marker must be between zero and the current day"
	if not _index(data.speed_index, Config.SPEEDS.size()) \
			or not _index(data.get("resume_speed_index", Config.NORMAL_SPEED),
				Config.SPEEDS.size(), 1):
		return "save speed index is out of range"
	if not _position(data.cart_position, ENTITY_EDGE_MARGIN, world_size):
		return "save.cart_position is outside the world or nonfinite"

	for i in data.terrain_edits.size():
		var edit: Variant = data.terrain_edits[i]
		error = _fields(edit, {"x": TYPE_FLOAT, "z": TYPE_FLOAT,
			"half_w": TYPE_FLOAT, "half_d": TYPE_FLOAT}, "terrain_edits[%d]" % i)
		if error != "":
			return error
		if not _coordinate(edit.x, world_size) or not _coordinate(edit.z, world_size) \
				or edit.half_w <= 0 or edit.half_d <= 0 \
				or edit.half_w > world_size or edit.half_d > world_size:
			return "terrain_edits[%d] has invalid bounds" % i

	error = _fields(data.wear, {"wear": TYPE_PACKED_FLOAT32_ARRAY,
		"locked": TYPE_PACKED_BYTE_ARRAY}, "wear")
	if error != "":
		return error
	var resolution := int(world_size / Config.WEAR_CELL)
	var texels := resolution * resolution
	if data.wear.wear.size() != texels or data.wear.locked.size() != texels:
		return "wear arrays must contain %d texels" % texels
	for i in texels:
		if not _quantity(data.wear.wear[i]):
			return "wear[%d] must be finite and nonnegative" % i
		if data.wear.locked[i] > Config.RoadLevel.PAVED:
			return "wear.locked[%d] is not a road level" % i

	error = _validate_nodes(data.nodes)
	if error != "":
		return error
	var buildings := {}
	var citizens := {}
	var seats := 0
	for i in data.buildings.size():
		var b: Variant = data.buildings[i]
		error = _building(b, registry, world_size)
		if error != "":
			return "buildings[%d]: %s" % [i, error]
		if buildings.has(b.id):
			return "duplicate building id %d" % b.id
		buildings[b.id] = b
		if BuildingDefs.get_def(b.type_id).role == BuildingDefs.Role.SEAT:
			seats += 1
	if seats != 1:
		return "save must contain exactly one keep"
	var husbandry: Dictionary = data.get("husbandry", {})
	for cow in husbandry.get("cows", []):
		if cow.ranch_id >= 0 and (not buildings.has(cow.ranch_id)
				or buildings[cow.ranch_id].type_id != "ranch"
				or buildings[cow.ranch_id].under_construction):
			return "cattle must belong to a completed ranch"
	for breeding in husbandry.get("breeding", []):
		if not buildings.has(breeding.ranch_id) or buildings[breeding.ranch_id].type_id != "ranch" \
				or buildings[breeding.ranch_id].under_construction:
			return "breeding must belong to a completed ranch"
	error = FrontierCampaign.validate(data.get("campaign", {}), buildings, world_size)
	if error != "":
		return error
	error = TradeRoutes.validate(data.get("trade", {}), world_size, buildings)
	if error != "": return "trade: " + error
	for i in data.citizens.size():
		var c: Variant = data.citizens[i]
		error = _citizen(c, registry, world_size)
		if error != "":
			return "citizens[%d]: %s" % [i, error]
		if citizens.has(c.id):
			return "duplicate citizen id %d" % c.id
		citizens[c.id] = c
	var local_citizens := citizens.keys()
	# Serving soldiers still own a civilian identity and home, but cannot also
	# appear in the civilian workforce or duplicate another person's identity.
	for unit in data.get("campaign", {}).get("units", []):
		if unit.get("faction", 1) != 0 or not unit.has("civilian"):
			continue
		var civilian: Variant = unit.civilian
		error = _citizen(civilian, registry, world_size)
		if error != "":
			return "serving citizen: " + error
		if citizens.has(civilian.id):
			return "civilian identity is shared by a citizen and soldier"
		if civilian.get("workplace_id", -1) != -1 or civilian.get("immigrant", false):
			return "serving citizen cannot have civilian employment or be an immigrant"
		citizens[civilian.id] = civilian
	var promised_imports := {}
	var rival_buildings := {}
	for building in data.get("campaign", {}).get("buildings", []): rival_buildings[building.id] = building
	for route in data.get("trade", {}).get("caravans", []):
		var civilian: Variant = route.citizen
		error = _citizen(civilian, registry, world_size)
		if error != "": return "merchant: " + error
		if citizens.has(civilian.id): return "merchant identity is already assigned to another role"
		citizens[civilian.id] = civilian
		if route.promised and rival_buildings.has(route.target_id):
			promised_imports[route.target_id] = float(promised_imports.get(route.target_id, 0)) + route.import_amount
			if promised_imports[route.target_id] > rival_buildings[route.target_id].inventory[Config.Res.IRON] + 0.001:
				return "caravans promise more iron than the neighboring town owns"
	error = Scouting.validate(data.get("scouting", {}), world_size, buildings)
	if error != "": return "scouting: " + error
	for entry in data.get("scouting", {}).get("scouts", []):
		var civilian: Dictionary = entry.citizen
		error = _citizen(civilian, registry, world_size)
		if error != "": return "scout: " + error
		if citizens.has(civilian.id): return "scout identity is already assigned to another role"
		citizens[civilian.id] = civilian
	if data.get("scouting", {}).get("report", {}).get("last_seen_day", 0.0) > data.day:
		return "city report is dated in the future"
	# Scout packs and caravan cargo reserve from the same physical counters.
	var service_reservations := {}
	var commitments: Array = []
	for entry in data.get("scouting", {}).get("scouts", []):
		commitments.append_array([[entry.food_reserved,entry.food_source,Config.Res.FOOD,Scouting.FOOD_PACK],
			[entry.tools_reserved,entry.tool_source,Config.Res.TOOLS,Scouting.TOOL_COST]])
	for route in data.get("trade", {}).get("caravans", []):
		commitments.append_array([[route.food_reserved,route.food_source_id,Config.Res.FOOD,route.pack_amount],
			[route.source_reserved,route.source_id,TradeRoutes.EXPORT,route.export_amount]])
	for item in commitments:
		if not item[0] or not buildings.has(item[1]): continue
		var key := "%d:%d" % [item[1],item[2]]
		service_reservations[key] = float(service_reservations.get(key,0.0))+item[3]
		if service_reservations[key] > buildings[item[1]].inventory[item[2]] + 0.001:
			return "service reservations exceed physical stock"
	for entry in data.get("water", {}).get("carriers", []):
		var civilian: Dictionary = entry.citizen
		error = _citizen(civilian, registry, world_size)
		if error != "": return "water carrier: " + error
		if citizens.has(civilian.id): return "water carrier identity is already assigned to another role"
		citizens[civilian.id] = civilian
	var scouts_by_id := {}
	for scout in data.get("scouting", {}).get("scouts", []): scouts_by_id[scout.id] = scout
	for job in data.get("water", {}).get("poison_jobs", []):
		if not scouts_by_id.has(job.scout_id): return "sabotage mission has no scout"
		if scouts_by_id[job.scout_id].state not in ["ready","exploring","visiting"]: return "sabotage mission requires a trained scout"
		var scout: Dictionary = scouts_by_id[job.scout_id]
		if scout.food + scout.tools + scout.citizen.carrying_amount + scout.citizen.get("veteran_rations",0.0) + job.kit > Config.CARRY_CAPACITY + 0.001:
			return "sabotage kit overloads the scout"
		if rival_buildings.has(job.target_id) and rival_buildings[job.target_id].type_id != "well": return "sabotage target is not a well"
		if job.reserved and buildings.has(job.source_id):
			var key := "%d:%d" % [job.source_id,Config.Res.TOOLS]
			service_reservations[key] = float(service_reservations.get(key,0.0))+1.0
			if service_reservations[key] > buildings[job.source_id].inventory[Config.Res.TOOLS] + 0.001:
				return "sabotage reservations exceed physical stock"
	var enemy_people := {}
	for unit in data.get("campaign",{}).get("units",[]):
		if unit.faction == 1: enemy_people[unit.id] = true
	for worker in data.get("campaign",{}).get("workers",[]): enemy_people[worker.id] = true
	for drinker in data.get("water",{}).get("drinkers",[]):
		if not (citizens.has(drinker.person_id) if drinker.faction == 0 else enemy_people.has(drinker.person_id)):
			return "drinking order has no living person"
	for cid in citizens:
		if citizens[cid].has("delivery") and not local_citizens.has(cid):
			return "service citizen cannot also hold a local delivery"
	var water_buildings := buildings.duplicate()
	water_buildings.merge(rival_buildings)
	var saved_wells := {}
	for well in data.get("water", {}).get("wells", []):
		if not water_buildings.has(well.id) or water_buildings[well.id].type_id != "well" or water_buildings[well.id].get("under_construction", false):
			return "water reserve has no completed well"
		saved_wells[well.id] = true
	if not data.get("water",{}).is_empty():
		for building in water_buildings.values():
			if building.type_id == "well" and not building.get("under_construction",false) and not saved_wells.has(building.id):
				return "completed well is missing its finite water reserve"
	for id in buildings:
		if data.next_building_id <= id:
			return "next_building_id must exceed every saved building id"
	for id in citizens:
		if data.next_citizen_id <= id:
			return "next_citizen_id must exceed every saved citizen id"
	if data.next_building_id < 1 or data.next_citizen_id < 1 \
			or data.next_building_id > MAX_ENTITY_ID or data.next_citizen_id > MAX_ENTITY_ID:
		return "next entity ids are outside the supported range"
	return _references(buildings, citizens)


static func _fields(value: Variant, schema: Dictionary, path: String,
		optional: bool = false) -> String:
	if not value is Dictionary:
		return "%s must be a dictionary" % path
	for key in schema:
		if not value.has(key):
			if optional:
				continue
			return "%s.%s is missing" % [path, key]
		var expected: int = schema[key]
		var actual := typeof(value[key])
		if actual != expected and not (expected == TYPE_FLOAT and actual == TYPE_INT):
			return "%s.%s must be %s" % [path, key, type_string(expected)]
		if expected == TYPE_FLOAT and (not is_finite(float(value[key]))
				or absf(float(value[key])) > MAX_NUMBER):
			return "%s.%s must be finite and within the supported range" % [path, key]
	return ""


static func _index(value: int, count: int, minimum: int = 0) -> bool:
	return value >= minimum and value < count


static func _coordinate(value: float, world_size: float = Config.WORLD_SIZE) -> bool:
	return is_finite(value) and value >= 0 and value <= world_size


static func _position(value: Vector3, margin: float = 0.0, world_size: float = Config.WORLD_SIZE) -> bool:
	return value.is_finite() and absf(value.y) <= world_size \
			and value.x >= -margin and value.x <= world_size + margin \
			and value.z >= -margin and value.z <= world_size + margin


static func _quantity(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= MAX_NUMBER


static func _resources(value: Dictionary, path: String) -> String:
	for res in value:
		if typeof(res) != TYPE_INT or not _index(res, Config.RES_COUNT):
			return "%s has an invalid resource id" % path
		var amount: Variant = value[res]
		if not (amount is float or amount is int) \
				or not _quantity(float(amount)):
			return "%s amounts must be finite and nonnegative" % path
	return ""


static func _ids(value: Array, path: String, minimum: int = 1,
		maximum: int = 9223372036854775807) -> String:
	var seen := {}
	for id in value:
		if typeof(id) != TYPE_INT or id < minimum or id >= maximum:
			return "%s contains an invalid id" % path
		if seen.has(id):
			return "%s contains a duplicate id" % path
		seen[id] = true
	return ""


static func _building(b: Variant, registry: AssetRegistry, world_size: float = Config.WORLD_SIZE) -> String:
	var error := _fields(b, {"id": TYPE_INT, "type_id": TYPE_STRING,
		"position": TYPE_VECTOR3, "yaw": TYPE_FLOAT,
		"under_construction": TYPE_BOOL, "build_progress": TYPE_FLOAT,
		"delivered": TYPE_DICTIONARY, "inventory": TYPE_PACKED_FLOAT32_ARRAY,
		"workers": TYPE_ARRAY, "residents": TYPE_ARRAY}, "building")
	if error != "":
		return error
	error = _fields(b, {"asset_id": TYPE_STRING, "build_cost": TYPE_DICTIONARY,
		"build_seconds": TYPE_FLOAT, "larder": TYPE_FLOAT, "crop_growth": TYPE_FLOAT,
		"plots": TYPE_ARRAY, "market_stock_target": TYPE_INT, "health": TYPE_FLOAT, "fire": TYPE_FLOAT}, "building", true)
	if error != "":
		return error
	if b.id < 1 or b.id > MAX_ENTITY_ID or not BuildingDefs.has(b.type_id):
		return "invalid building id or type"
	var def := BuildingDefs.get_def(b.type_id)
	if b.get("market_stock_target", 80) not in [40, 80, 120]:
		return "invalid market stock target"
	# Read from the definition, never restated here. This was an inlined copy
	# of the table behind Building.max_health(), and lowering one copy alone
	# refuses every saved building already above the new ceiling as "invalid
	# building damage". Safe to reach `def` for it: an unknown type_id was
	# turned away above, so no save can steer this at a missing definition.
	var maximum_health := def.max_health
	if b.get("health", maximum_health) < 0 or b.get("health", maximum_health) > maximum_health or b.get("fire", 0.0) < 0 or b.get("fire", 0.0) > 1:
		return "invalid building damage"
	var asset: String = b.get("asset_id", def.asset)
	if asset != "" and asset != def.asset and not def.variants.has(asset):
		return "asset '%s' does not belong to %s" % [asset, b.type_id]
	if registry != null and asset != "" and not registry.has(asset):
		return "unknown building asset '%s'" % asset
	if not _position(b.position, 0.0, world_size):
		return "building position is outside the world or nonfinite"
	if b.build_progress < 0 or b.build_progress > 1 \
			or b.get("crop_growth", 0.0) < 0 or b.get("crop_growth", 0.0) > 1 \
			or b.get("larder", 0.0) < 0 or b.get("build_seconds", def.build_time) <= 0:
		return "invalid construction, crop, or larder state"
	if b.inventory.size() != Config.RES_COUNT:
		return "inventory length does not match the resource count"
	for amount in b.inventory:
		if not _quantity(amount):
			return "inventory amounts must be finite and nonnegative"
	for key in ["delivered", "build_cost"]:
		error = _resources(b.get(key, {}), key)
		if error != "":
			return error
	for key in ["workers", "residents"]:
		error = _ids(b[key], key)
		if error != "":
			return error
	if b.workers.size() > def.worker_slots or b.residents.size() > def.houses:
		return "building has more workers or residents than places"
	var plots: Array = b.get("plots", [])
	if plots.size() > def.worker_slots * def.plots_per_worker:
		return "building has too many field plots"
	for p in plots:
		if not p is Vector3 or not _position(p, 0.0, world_size):
			return "field plot must be a finite position inside the world"
	return ""


static func _citizen(c: Variant, registry: AssetRegistry, world_size: float = Config.WORLD_SIZE) -> String:
	var error := _fields(c, {"id": TYPE_INT, "position": TYPE_VECTOR3}, "citizen")
	if error != "":
		return error
	error = _fields(c, {"name": TYPE_STRING, "asset_id": TYPE_STRING,
		"profession": TYPE_STRING, "age": TYPE_INT, "home_id": TYPE_INT,
		"workplace_id": TYPE_INT, "carrying_res": TYPE_INT, "carrying_amount": TYPE_FLOAT,
		"immigrant": TYPE_BOOL, "immigrant_target": TYPE_VECTOR3, "hunger": TYPE_FLOAT,
		"next_meal": TYPE_FLOAT, "meals_taken": TYPE_INT, "morale": TYPE_FLOAT, "service_health": TYPE_FLOAT,
		"hydration": TYPE_FLOAT, "water_bucket": TYPE_FLOAT, "water_sickness": TYPE_FLOAT},
		"citizen", true)
	if error != "":
		return error
	# Older saves may contain arriving settlers scattered just beyond a map
	# corner. Keep that small, legitimate fringe readable; new spawns clamp it.
	if c.id < 1 or c.id > MAX_ENTITY_ID or not _position(c.position, ENTITY_EDGE_MARGIN, world_size) \
			or not _position(c.get("immigrant_target", Vector3.ZERO), 0.0, world_size):
		return "invalid citizen id or position"
	var asset: String = c.get("asset_id", "")
	if asset != "" and asset not in ["citizen_male_base", "citizen_female_base"]:
		return "unknown citizen asset '%s'" % asset
	if registry != null and asset != "" and not registry.has(asset):
		return "missing citizen asset '%s'" % asset
	if c.get("age", 24) < 0 or c.get("age", 24) > MAX_ENTITY_ID \
			or c.get("meals_taken", 0) < 0 or c.get("meals_taken", 0) > MAX_ENTITY_ID \
			or c.get("next_meal", 0.0) < 0:
		return "citizen age and meal values must be nonnegative"
	for key in ["hunger", "morale", "hydration", "water_sickness"]:
		if c.get(key, 0.0) < 0 or c.get(key, 0.0) > 1:
			return "%s must be between zero and one" % key
	if c.get("service_health", 100.0) < 0 or c.get("service_health", 100.0) > 100:
		return "invalid service health"
	if c.get("water_bucket", 0.0) < 0 or c.get("water_bucket", 0.0) > 4.0:
		return "invalid carried water"
	var res: int = c.get("carrying_res", -1)
	var amount: float = c.get("carrying_amount", 0.0)
	if not _index(res, Config.RES_COUNT, -1) or amount < 0 \
			or (amount > 0 and res == -1) or (amount == 0 and res != -1):
		return "invalid carried resource or amount"
	if c.has("body"):
		error = Soldier.validate_body(c.body)
		if error != "":
			return "veteran body: " + error
	if c.has("veteran_rations"):
		if not c.has("body") or typeof(c.veteran_rations) not in [TYPE_FLOAT, TYPE_INT] \
				or not is_finite(float(c.veteran_rations)) \
				or c.veteran_rations < 0 or c.veteran_rations > 4.0:
			return "invalid veteran rations"
	if c.has("delivery"):
		error = _fields(c.delivery,{"source_id":TYPE_INT,"dest_id":TYPE_INT},"loaded delivery")
		if error != "": return error
		if c.get("immigrant",false) or amount <= 0.01 or c.delivery.source_id < 1 \
				or c.delivery.dest_id < 1 or c.delivery.source_id == c.delivery.dest_id:
			return "invalid loaded delivery"
	return ""


static func _references(buildings: Dictionary, citizens: Dictionary) -> String:
	var deliveries := {}
	var storage_claims := {}
	for cid in citizens:
		var c: Dictionary = citizens[cid]
		if c.has("delivery"):
			var delivery: Dictionary = c.delivery
			if not buildings.has(delivery.source_id) or not buildings.has(delivery.dest_id):
				return "loaded delivery has an unknown endpoint"
			var source: Dictionary = buildings[delivery.source_id]
			var destination: Dictionary = buildings[delivery.dest_id]
			var res: int = c.carrying_res
			if source.under_construction or not BuildingDefs.get_def(source.type_id).stores_resource(res):
				return "loaded delivery has an invalid source"
			var key := "%d:%d" % [destination.id,res]
			deliveries[key] = float(deliveries.get(key,0))+c.carrying_amount
			var def := BuildingDefs.get_def(destination.type_id)
			if destination.under_construction:
				var needed := float(destination.get("build_cost",def.cost).get(res,0))-float(destination.delivered.get(res,0))
				if deliveries[key] > needed+0.01:
					return "loaded deliveries exceed outstanding construction materials"
			else:
				if not def.stores_resource(res): return "loaded delivery destination cannot store its cargo"
				storage_claims[destination.id] = float(storage_claims.get(destination.id,0))+c.carrying_amount
				var stocked := 0.0
				for units in destination.inventory: stocked += units
				if stocked+storage_claims[destination.id] > def.storage+0.01:
					return "loaded deliveries exceed destination storage"
		for pair in [["home_id", "residents"], ["workplace_id", "workers"]]:
			var bid: int = c.get(pair[0], -1)
			if bid == -1:
				continue
			if not buildings.has(bid):
				return "citizen %d has unknown %s %d" % [cid, pair[0], bid]
			if not buildings[bid][pair[1]].has(cid):
				return "citizen %d and building %d disagree on %s" % [cid, bid, pair[0]]
			if c.get("immigrant", false):
				return "immigrant %d already has a %s assignment" % [cid, pair[0]]
	for bid in buildings:
		var b: Dictionary = buildings[bid]
		for pair in [["residents", "home_id"], ["workers", "workplace_id"]]:
			for cid in b[pair[0]]:
				if not citizens.has(cid) or citizens[cid].get(pair[1], -1) != bid:
					return "building %d has an inconsistent %s roll" % [bid, pair[0]]
	return ""


static func _validate_nodes(nodes: Dictionary) -> String:
	var error := _fields(nodes, {"count": TYPE_INT, "changed": TYPE_ARRAY}, "nodes")
	if error != "":
		return error
	error = _fields(nodes, {"marked": TYPE_ARRAY}, "nodes", true)
	if error != "":
		return error
	if nodes.count < 0:
		return "nodes.count must be nonnegative"
	var seen := {}
	for entry in nodes.changed:
		error = _fields(entry, {"index": TYPE_INT, "amount": TYPE_FLOAT,
			"depleted": TYPE_BOOL}, "nodes.changed")
		if error != "":
			return error
		error = _fields(entry, {"regrow_at": TYPE_FLOAT}, "nodes.changed", true)
		if error != "":
			return error
		if not _index(entry.index, nodes.count) or seen.has(entry.index):
			return "nodes.changed has an invalid or duplicate index"
		if entry.amount < 0 or entry.get("regrow_at", -1.0) < -1:
			return "resource node amounts or regrowth times are invalid"
		seen[entry.index] = true
	return _ids(nodes.get("marked", []), "nodes.marked", 0, nodes.count)


## These checks need the seeded resource layout. Run on the staged world,
## before applying any saved records or replacing the active march.
static func validate_world(data: Dictionary, world: World) -> String:
	if data.nodes.count != world.nodes.records.size():
		return "resource node count does not match the saved world seed"
	for entry in data.nodes.changed:
		var node: ResourceNodes.NodeRec = world.nodes.records[entry.index]
		if entry.amount > node.max_amount + 0.001:
			return "resource node %d exceeds its generated capacity" % entry.index
	for id in data.nodes.get("marked", []):
		if world.nodes.records[id].kind != ResourceNodes.Kind.TREE:
			return "marked resource node %d is not a tree" % id
	return ""


static func _world_settings(settings: Variant) -> String:
	if not settings is Dictionary:
		return "world_settings must be a dictionary"
	if settings.is_empty(): return ""
	if typeof(settings.get("size_m")) not in [TYPE_INT, TYPE_FLOAT] \
			or float(settings.size_m) not in [768.0, 1536.0, 3072.0, 6144.0]:
		return "world size is not a supported preset"
	if typeof(settings.get("generation_version")) != TYPE_INT \
			or settings.generation_version not in [1, 2]:
		return "unknown world generation version"
	if settings.generation_version == 1 and settings.size_m != 768:
		return "legacy worlds must retain their original dimensions"
	return ""
