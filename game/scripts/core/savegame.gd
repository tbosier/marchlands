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
## **Save state, not schedules.** Jobs, reservations and claimed haulage are
## not written. They are a cache of decisions the simulation makes afresh every
## tick, and a half-finished delivery reconstructed from a file is a source of
## phantom reservations rather than continuity. On load everyone stands idle
## for one tick and the job board refills from the same rota that filled it
## before. A hauler loses the leg they were walking; nothing else changes.
##
## The file is Godot's own binary variant format, zstd-compressed. The wear
## field alone is 147k floats, and a JSON save would spend most of its size
## base64-encoding it.

const VERSION := 1
const DIR := "user://saves"
const EXTENSION := "sav"
const QUICK_SLOT := "quicksave"

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
## Written beside the slot and moved into place only once it is whole. Opening
## the slot itself for writing truncates it first, so a failure part way
## through — a full disk, a removed drive — would take the previous save down
## with it while the game still reported "Saved".
static func write(game: Node, slot: String) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := slot_path(slot)
	var temp := path + ".part"

	var file := FileAccess.open_compressed(temp, FileAccess.WRITE,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return "could not write %s (%s)" % [
				temp, error_string(FileAccess.get_open_error())]
	var stored := file.store_var(capture(game), true)
	file.close()
	if not stored:
		DirAccess.remove_absolute(temp)
		return "writing %s failed; the previous save is untouched" % path

	var dir := DirAccess.open(DIR)
	if dir == null:
		return "could not open %s" % DIR
	if dir.file_exists(path.get_file()):
		dir.remove(path.get_file())
	var moved := dir.rename(temp.get_file(), path.get_file())
	if moved != OK:
		return "could not replace %s (%s)" % [path, error_string(moved)]
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
		citizens.append(_capture_citizen(c))

	return {
		"version": VERSION,
		"seed": world.world_seed,
		"saved_at": Time.get_datetime_string_from_system(true),
		"day": sim.day,
		"elapsed_days": clock.elapsed_days,
		"day_marker": sim.day_marker(),
		"speed_index": clock.speed_index,
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
		"crop_growth": b.crop_growth,
		"workers": b.workers.duplicate(),
		"residents": b.residents.duplicate(),
		# The plot layout, not just the count: see Building.adopt_plots.
		"plots": b.all_plots().duplicate(),
	}


static func _capture_citizen(c: Citizen) -> Dictionary:
	return {
		"id": c.id,
		"name": c.given_name,
		"asset_id": c.asset_id,
		"profession": c.profession,
		"age": c.age,
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
		"morale": c.morale,
	}


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

## Returns the saved dictionary, or an empty one if the slot is unusable.
## `problem` is filled with a human-readable reason when that happens.
static func read(slot: String, problem: Array[String] = []) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		problem.append("no save named '%s'" % slot)
		return {}
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		problem.append("could not read %s (%s)" % [
				path, error_string(FileAccess.get_open_error())])
		return {}
	var data: Variant = file.get_var(true)
	file.close()

	if typeof(data) != TYPE_DICTIONARY:
		problem.append("%s is not a Marchlands save" % path)
		return {}
	var version := int(data.get("version", 0))
	if version != VERSION:
		# There is one version so far. When there are more this is where the
		# upgrade path goes; refusing to guess is the honest behaviour until
		# then, because a silently mis-read save loses a march.
		problem.append("save is version %d, this build reads version %d"
				% [version, VERSION])
		return {}
	return data


# ---------------------------------------------------------------------------
# Restoring
# ---------------------------------------------------------------------------

## Rebuild the settlement described by `data` into a freshly generated world.
##
## The caller is responsible for the world already matching `data["seed"]` —
## Game does that by reloading the scene with the seed from the save.
static func restore(game: Node, data: Dictionary) -> void:
	var sim: Simulation = game.sim
	var world: World = game.world
	var clock: Clock = game.clock

	clock.elapsed_days = float(data.get("elapsed_days", 0.0))
	# Otherwise the first advance after loading sees the whole-day number jump
	# from zero and announces a day change that did not happen.
	clock.set_day_marker(floori(clock.elapsed_days))
	clock.set_speed(int(data.get("speed_index", Config.NORMAL_SPEED)))
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
			Config.WORLD_SIZE, Config.WORLD_SIZE)

	# The pathfinder is told about the restored roads by finish_restore, once
	# every building has been placed: placing one flattens the ground under it,
	# and a weight worked out before that flattening is wrong.
	world.wear.apply_state(data.get("wear", {}))
	world.nodes.apply_state(data.get("nodes", {}))
	# A felled outcrop leaves walkable ground behind, exactly as it does when
	# it is mined out during play.
	for rec in world.nodes.records:
		if rec.kind != ResourceNodes.Kind.TREE:
			var c := Config.world_to_cell(rec.position)
			world.nav.set_blocked(c.x, c.y, not rec.depleted)

	for entry in data.get("buildings", []):
		_restore_building(sim, entry)
	for entry in data.get("citizens", []):
		_restore_citizen(sim, entry)

	sim.set_next_ids(int(data.get("next_building_id", 1)),
			int(data.get("next_citizen_id", 1)))

	if data.get("cart", false):
		var cart := Cart.new()
		world.effects_root.add_child(cart)
		var at: Vector3 = data.get("cart_position", world.centre())
		at.y = world.heightmap.height_at(at.x, at.z)
		cart.setup(game.registry, at)
		sim.set_cart(cart)

	sim.finish_restore()


static func _restore_building(sim: Simulation, entry: Dictionary) -> void:
	# `instant` is what tells place_building to finish the structure, register
	# it with the stores and lay out its fields — precisely the work a saved
	# completed building needs done again.
	var completed := not bool(entry.get("under_construction", false))
	var b := sim.place_building(entry["type_id"], entry["position"],
			float(entry["yaw"]), completed, String(entry.get("asset_id", "")),
			int(entry.get("id", -1)), false, true)
	if b == null:
		return
	var plots: Array = entry.get("plots", [])
	if not plots.is_empty():
		b.adopt_plots(plots, sim.world.heightmap, sim.world.nav, sim.registry)
	b.apply_state(entry)


static func _restore_citizen(sim: Simulation, entry: Dictionary) -> void:
	var c := sim.add_citizen(entry["position"],
			bool(entry.get("immigrant", false)),
			String(entry.get("asset_id", "")), int(entry.get("id", -1)))
	if c == null:
		return
	c.apply_state(entry, sim.registry)
