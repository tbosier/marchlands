class_name SaveGame
extends RefCounted

## Persisting a march (design doc 3.3).
##
## Two principles decide what goes in the file.
##
## **Save only what cannot be derived.** The terrain, the forest's layout, the
## mineral seams and the building meshes all fall out of the world seed, and
## regenerating them is faster than reading them back. What is genuinely
## historical is the part the player made: the wear ground into the soil, what
## has been built and how far, who lives here, and what is in the stores.
##
## **Save state, not local job schedules.** Local jobs and claimed haulage are
## rebuilt on load; a loaded haul retains its destination and carried goods.
## Caravan phases,
## identities, cargo and stock promises are persistent orders and are restored
## explicitly. Bridge deliveries and lost-cart recovery orders likewise survive,
## while their transient worker assignments are rebuilt.
##
## The file is Godot's own binary variant format, zstd-compressed. The wear
## field grows with the chosen map size, so its packed arrays stay binary.

const VERSION := 1
const DIR := "user://saves"
const EXTENSION := "sav"
const QUICK_SLOT := "quicksave"
const Validation = preload("res://scripts/core/save_validation.gd")

## A replacement march lives here until it has been checked and restored.
## Its own 3D world keeps lighting and physics out of the active viewport.
class RestoreState:
	extends SubViewport
	var registry: AssetRegistry
	var world: World
	var sim: Simulation
	var clock := Clock.new()


static func validate(data: Variant, registry: AssetRegistry = null) -> String:
	return Validation.validate(migrate(data), registry, VERSION)


## Five-resource version-one saves predate hides and leather. Migrate only
## that known layout, leaving malformed modern arrays for validation to reject.
static func migrate(data: Variant) -> Variant:
	if not data is Dictionary or data.has("resource_layout"):
		return data
	var upgraded: Dictionary = data.duplicate(true)
	upgraded["resource_layout"] = 2
	var records: Array = []
	if upgraded.get("buildings") is Array:
		records.append_array(upgraded.buildings)
	if upgraded.get("campaign") is Dictionary and upgraded.campaign.get("buildings") is Array:
		records.append_array(upgraded.campaign.buildings)
	for record in records:
		if record is Dictionary and record.get("inventory") is PackedFloat32Array \
				and record.inventory.size() == 5:
			var inventory: PackedFloat32Array = record.inventory
			inventory.resize(Config.RES_COUNT)
			record.inventory = inventory
	return upgraded

static func slot_path(slot: String) -> String:
	return "%s/%s.%s" % [DIR, _sanitise(slot), EXTENSION]


static func _sanitise(slot: String) -> String:
	var out := ""
	for c in slot.to_lower():
		out += c if c.is_valid_identifier() or c.is_valid_int() else "_"
	return "save" if out.is_empty() else out


static func list_slots() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for file in dir.get_files():
		if file.ends_with("." + EXTENSION):
			out.append(file.trim_suffix("." + EXTENSION))
	out.sort()
	return out


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

## Returns "" on success, or a message describing what went wrong.
##
## Written beside the slot, read back, and only then moved into place, with the
## previous save kept until the new one has landed. Three things can go wrong
## and all three are guarded:
##
##   * writing into the slot directly would truncate it first, so a failure
##     part way through — a full disk, a removed drive — took the previous save
##     down with it while the game still reported "Saved";
##   * a compressed FileAccess does its real writing on close, and close
##     reports nothing, so `store_var` succeeding proves only that the value
##     was accepted, not that it reached the disk. It is read back instead;
##   * removing the old file before renaming the new one over it left an
##     instant with no save at all. The old one is moved aside to `.prev` and
##     only deleted once the replacement is in place; `read` recovers from it.
static func write(game: Node, slot: String) -> String:
	var snapshot := capture(game)
	var invalid := validate(snapshot, game.registry)
	if invalid != "":
		return "could not save: " + invalid
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := slot_path(slot)
	var temp := path + ".part"

	var file := FileAccess.open_compressed(temp, FileAccess.WRITE,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return "could not write %s (%s)" % [
				temp, error_string(FileAccess.get_open_error())]
	var stored := file.store_var(snapshot, false)
	file.close()
	if not stored:
		DirAccess.remove_absolute(temp)
		return "writing %s failed; the previous save is untouched" % path

	# `store_var` returning true only means the value was accepted into the
	# compression buffer. A compressed FileAccess does its real writing when it
	# is closed, and close reports nothing at all — so a full disk produced a
	# truncated file and a cheerful "Saved". Read it back before trusting it:
	# the moment the player tries to load it is the worst possible time to
	# discover the save was never whole.
	var check := FileAccess.open_compressed(temp, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if check == null:
		DirAccess.remove_absolute(temp)
		return "wrote %s but could not read it back (%s)" % [
				temp, error_string(FileAccess.get_open_error())]
	var round_trip: Variant = check.get_var(false)
	check.close()
	if validate(round_trip, game.registry) != "" or round_trip != snapshot:
		DirAccess.remove_absolute(temp)
		return "wrote %s but it did not read back whole; the previous save " \
				% path + "is untouched"

	var dir := DirAccess.open(DIR)
	if dir == null:
		return "could not open %s" % DIR

	# Keep the old save until the new one is in place. Removing it first left a
	# window with no save in it at all — an interruption there destroyed the
	# previous march, which is the exact accident this function exists to
	# prevent. At every instant one of the two paths holds a whole file.
	var backup := path.get_file() + ".prev"
	var had_previous := dir.file_exists(path.get_file())
	if had_previous:
		if dir.file_exists(backup):
			dir.remove(backup)
		var kept := dir.rename(path.get_file(), backup)
		if kept != OK:
			DirAccess.remove_absolute(temp)
			return "could not set the previous save aside (%s)" \
					% error_string(kept)

	var moved := dir.rename(temp.get_file(), path.get_file())
	if moved != OK:
		if had_previous:
			dir.rename(backup, path.get_file())
		DirAccess.remove_absolute(temp)
		return "could not replace %s (%s)" % [path, error_string(moved)]
	if had_previous:
		dir.remove(backup)
	return ""


static func capture(game: Node) -> Dictionary:
	var sim: Simulation = game.sim
	var world: World = game.world
	var clock: Clock = game.clock

	var buildings: Array = []
	for b in sim.buildings:
		buildings.append(_capture_building(b))

	var citizens: Array = []
	for c in sim.citizens:
		citizens.append(_capture_citizen(c,game.sim))

	return {
		"version": VERSION,
		"resource_layout": 2,
		"seed": world.world_seed,
		"world_settings": world.generation_settings.duplicate(),
		"saved_at": Time.get_datetime_string_from_system(true),
		"day": sim.day,
		"elapsed_days": clock.elapsed_days,
		"day_marker": sim.day_marker(),
		"speed_index": clock.speed_index,
		"speed_layout": 2,
		"resume_speed_index": clock.resume_speed_index(),
		"research": sim.research.capture(),
		"campaign": sim.campaign.capture() if sim.campaign != null else {},
		"husbandry": sim.husbandry.capture() if sim.husbandry != null else {},
		"trade": sim.trade.capture() if sim.trade != null else {},
		"scouting": sim.scouting.capture() if sim.scouting != null else {},
		"water": sim.water.capture() if sim.water != null else {},
		"bridges": sim.bridges.capture() if sim.bridges != null else {},
		"next_building_id": sim.next_building_id(),
		"next_citizen_id": sim.next_citizen_id(),
		"terrain_edits": world.heightmap.capture(),
		"wear": world.wear.capture(),
		"nodes": world.nodes.capture(),
		"buildings": buildings,
		"citizens": citizens,
		"cart": sim.cart != null,
		"cart_position": sim.cart.global_position if sim.cart else Vector3.ZERO,
	}


static func _capture_building(b: Building) -> Dictionary:
	# `delivered` is keyed by the resource enum; store_var keeps integer keys
	# faithfully, so it needs no translation the way a JSON save would.
	return {
		"id": b.id,
		"type_id": b.type_id,
		"asset_id": b.asset_id,
		"position": b.position,
		"yaw": b.yaw,
		"under_construction": b.under_construction,
		"build_progress": b.build_progress,
		# An upgrade in progress wears the finished definition already, so the
		# price of getting there has to travel with it.
		"build_cost": b.build_cost.duplicate(),
		"build_seconds": b.build_seconds,
		"delivered": b.delivered.duplicate(),
		"inventory": b.inventory.duplicate(),
		# The household's own food. Not part of the inventory, and a march that
		# came back with every larder bare would have everybody walking to the
		# granary the moment it loaded.
		"larder": b.larder,
		"crop_growth": b.crop_growth,
		"market_stock_target": b.market_stock_target,
		"health": b.health,
		"fire": b.fire,
		"workers": b.workers.duplicate(),
		"residents": b.residents.duplicate(),
		# The plot layout, not just the count: see Building.adopt_plots.
		"plots": b.all_plots().duplicate(),
	}


static func _capture_citizen(c: Citizen, sim: Simulation = null) -> Dictionary:
	var record := {
		"id": c.id,
		"name": c.given_name,
		"asset_id": c.asset_id,
		"profession": c.profession,
		"age": c.age,
		"service_health": c.service_health,
		"hydration": c.hydration, "water_bucket": c.water_bucket, "water_sickness": c.water_sickness,
		"home_id": c.home_id,
		"workplace_id": c.workplace_id,
		"position": c.position,
		"carrying_res": c.carrying_res,
		"carrying_amount": c.carrying_amount,
		# Settlers still walking in from the map edge are not residents yet,
		# and restoring them as residents hands them housing and work they have
		# not arrived to take up.
		"immigrant": c.immigrant,
		"immigrant_target": c.immigrant_target,
		"hunger": c.hunger,
		# When their next meal falls due, and how many they have sat down to.
		# Without the first, everyone reloads with a meal owed at once.
		"next_meal": c.next_meal,
		"meals_taken": c.meals_taken,
		"morale": c.morale,
	}
	if c is Soldier:
		record["body"] = c.capture_body()
		record["veteran_rations"] = c.rations
	# The goods have already left their source. Their destination is physical
	# intent, not a disposable work schedule: losing it strands workshop and
	# construction loads whenever the general stores are full.
	if sim != null and c.job != null and not c.job.cancelled \
			and c.job.kind == JobBoard.Kind.HAUL and c.job.loaded \
			and c.job.claimed_by == c.id and c.carrying_amount > 0.01 \
			and c.carrying_res == c.job.res and sim.buildings_by_id.has(c.job.source_id) \
			and sim.buildings_by_id.has(c.job.dest_id):
		record["delivery"] = {"source_id":c.job.source_id,"dest_id":c.job.dest_id}
	return record


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

## Returns the saved dictionary, or an empty one if the slot is unusable.
## `problem` is filled with a human-readable reason when that happens.
static func read(slot: String, problem: Array[String] = []) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		# A write interrupted between setting the old save aside and moving the
		# new one in leaves the previous march under `.prev`. It is a whole
		# file, so recover from it rather than telling the player their save
		# does not exist.
		var previous := path + ".prev"
		if FileAccess.file_exists(previous):
			var dir := DirAccess.open(DIR)
			if dir != null and dir.rename(previous.get_file(),
					path.get_file()) == OK:
				push_warning("recovered '%s' from an interrupted save" % slot)
			else:
				problem.append("no save named '%s'" % slot)
				return {}
		else:
			problem.append("no save named '%s'" % slot)
			return {}
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		problem.append("could not read %s (%s)" % [
				path, error_string(FileAccess.get_open_error())])
		return {}
	# Saves contain only values. Never instantiate objects from a save file.
	var data: Variant = file.get_var(false)
	file.close()

	var invalid := validate(data)
	if invalid != "":
		problem.append(invalid)
		return {}
	return data


# ---------------------------------------------------------------------------
# Restoring
# ---------------------------------------------------------------------------

## Rebuild the settlement described by `data` into a freshly generated world.
##
## The caller is responsible for the world already matching `data["seed"]` —
## Game does that in an isolated viewport before swapping in the replacement.
static func restore(game: Node, data: Dictionary) -> String:
	data = migrate(data)
	var sim: Simulation = game.sim
	var world: World = game.world
	var clock: Clock = game.clock

	clock.elapsed_days = float(data.get("elapsed_days", 0.0))
	# Otherwise the first advance after loading sees the whole-day number jump
	# from zero and announces a day change that did not happen.
	clock.set_day_marker(floori(clock.elapsed_days))
	clock.restore_saved_speed(data)
	sim.set_day(float(data.get("day", 0.0)))
	# After `set_day`, which parks the marker on the restored day. The marker
	# is how much of the current day has already been charged for; dropping it
	# meant every reload wrote off the eating, tool wear, crop growth and road
	# decay accrued since the last midnight, and reloading repeatedly wrote it
	# off repeatedly.
	sim.set_day_marker(float(data.get("day_marker", data.get("day", 0.0))))

	# Before anything is placed: building pads sit on top of these, and some of
	# them belong to buildings that were pulled down and are not coming back.
	world.heightmap.apply_state(data.get("terrain_edits", []))
	world.terrain.rebuild_region(world.centre(),
			world.size_m, world.size_m)

	# The pathfinder is told about the restored roads by finish_restore, once
	# every building has been placed: placing one flattens the ground under it,
	# and a weight worked out before that flattening is wrong.
	world.wear.apply_state(data.get("wear", {}))
	world.nodes.apply_state(data.get("nodes", {}))
	# A felled outcrop leaves walkable ground behind, exactly as it does when
	# it is mined out during play.
	for rec in world.nodes.records:
		if rec.kind != ResourceNodes.Kind.TREE:
			var c := world.world_to_cell(rec.position)
			world.nav.set_blocked(c.x, c.y, not rec.depleted)

	for entry in data.get("buildings", []):
		if not _restore_building(sim, entry):
			return "could not restore building %d" % entry.id
	for entry in data.get("citizens", []):
		if not _restore_citizen(sim, entry):
			return "could not restore citizen %d" % entry.id

	sim.set_next_ids(int(data.get("next_building_id", 1)),
			int(data.get("next_citizen_id", 1)))

	if data.get("cart", false):
		var cart := Cart.new()
		world.effects_root.add_child(cart)
		var at: Vector3 = data.get("cart_position", world.centre())
		cart.setup(game.registry, at)
		sim.set_cart(cart)

	var research_error: String = sim.research.restore(data.get("research", {}))
	if research_error != "": return research_error
	sim.finish_restore()
	sim.campaign = FrontierCampaign.new()
	sim.add_child(sim.campaign)
	sim.campaign.setup(sim, world, game.registry)
	var campaign_error: String = sim.campaign.restore(data.get("campaign", {}))
	if campaign_error != "": return campaign_error
	sim.husbandry = Husbandry.new()
	sim.add_child(sim.husbandry)
	sim.husbandry.setup(sim, world, game.registry)
	var husbandry_error: String = sim.husbandry.restore(data.get("husbandry", {}))
	if husbandry_error != "": return husbandry_error
	sim.bridges = Bridges.new()
	sim.add_child(sim.bridges)
	sim.bridges.setup(sim, world, game.registry)
	var bridge_error: String = sim.bridges.restore(data.get("bridges", {}))
	if bridge_error != "": return bridge_error
	sim.trade = TradeRoutes.new()
	sim.add_child(sim.trade)
	sim.trade.setup(sim, world, game.registry)
	var trade_error: String = sim.trade.restore(data.get("trade", {}))
	if trade_error != "": return trade_error
	sim.scouting = Scouting.new()
	sim.add_child(sim.scouting)
	sim.scouting.setup(sim, world, game.registry)
	var scouting_error: String = sim.scouting.restore(data.get("scouting", {}))
	if scouting_error != "": return scouting_error
	sim.water = WaterSystem.new()
	sim.add_child(sim.water)
	sim.water.setup(sim, world, game.registry)
	var water_error: String = sim.water.restore(data.get("water", {}))
	if water_error != "": return water_error
	sim.scouting.refresh_visibility()
	if data.get("water", {}).is_empty() and sim.water.info().wells.is_empty():
		sim.alert.emit("Build a well before your residents run out of drinking water.",world.centre())
	var fog := preload("res://scripts/world/fog_of_war.gd").new()
	world.add_child(fog)
	fog.setup(sim.scouting, world, sim.campaign)
	return ""


static func _restore_building(sim: Simulation, entry: Dictionary) -> bool:
	# `instant` is what tells place_building to finish the structure, register
	# it with the stores and lay out its fields — precisely the work a saved
	# completed building needs done again.
	var completed := not bool(entry.get("under_construction", false))
	var b := sim.place_building(entry["type_id"], entry["position"],
			float(entry["yaw"]), completed, String(entry.get("asset_id", "")),
			int(entry.get("id", -1)), false, true)
	if b == null:
		return false
	var plots: Array = entry.get("plots", [])
	if entry.has("plots"):
		b.adopt_plots(plots, sim.world.heightmap, sim.world.nav, sim.registry)
	b.apply_state(entry)
	return true


static func _restore_citizen(sim: Simulation, entry: Dictionary) -> bool:
	var c := sim.add_citizen(entry["position"],
			bool(entry.get("immigrant", false)),
			String(entry.get("asset_id", "")), int(entry.get("id", -1)), entry.get("body", {}))
	if c == null:
		return false
	c.position = entry["position"]
	c.apply_state(entry, sim.registry)
	if c is Soldier:
		c.rations = float(entry.get("veteran_rations", 0.0))
	if entry.has("delivery"):
		var destination: Building = sim.buildings_by_id[entry.delivery.dest_id]
		var job := sim.jobs.post(JobBoard.Kind.HAUL,c.position,72.0)
		job.source_id = entry.delivery.source_id
		job.dest_id = destination.id
		job.res = c.carrying_res
		job.amount = c.carrying_amount
		job.loaded = true
		sim.jobs.index(job)
		# Each restored load is claimed before the next is posted, so the
		# normal board API removes it from the open list exactly once.
		c.job = sim.jobs.best_for(c.id,c.position,JobBoard.Accept.ANY,c.workplace_id)
		destination.incoming[job.res] += job.amount
		c.state = Citizen.State.TRAVELLING
		c.task_label = job.describe()
		c.set_goal(sim.entrance_of(destination,"att_cart_bay"))
	return true
