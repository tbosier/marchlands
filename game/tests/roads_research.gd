extends SceneTree

## tools/godot_env.sh --headless --path game --script res://tests/roads_research.gd

var _failures := 0
var _wallet := {}
var _payments := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		_failures += 1


func _pay(cost: Dictionary) -> bool:
	_payments += 1
	for resource in cost:
		if _wallet.get(resource, 0) < cost[resource]:
			return false
	for resource in cost:
		_wallet[resource] -= cost[resource]
	return true


func _research() -> void:
	var research := RoadResearch.new()
	_check(not research.allows_road_upgrade(Config.RoadLevel.IMPROVED)
			and not research.allows_road_upgrade(Config.RoadLevel.PATH)
			and not research.allows_road_upgrade(Config.RoadLevel.PAVED),
			"all commissioned road surfaces begin locked behind research")
	_check(not research.allows_building_upgrade("house")
			and not research.allows_building_upgrade("granary")
			and not research.allows_building_upgrade("blacksmith")
			and not research.allows_building_upgrade("supply_hut"),
			"civic, forge and fort upgrades begin locked")
	_check(research.start("roadworks", false, _pay) != "" and _payments == 0,
			"an absent market rejects research before requesting payment")
	_check(research.start("paving", true, _pay) != "" and _payments == 0,
			"paving requires completed roadworks before requesting payment")
	_wallet = {Config.Res.TIMBER: 9, Config.Res.STONE: 100, Config.Res.TOOLS: 100}
	var original := _wallet.duplicate()
	var state := research.capture()
	_check(research.start("roadworks", true, _pay) != ""
			and _wallet == original and research.capture() == state,
			"insufficient resources change neither inventories nor research state")
	_wallet[Config.Res.TIMBER] = 100
	_check(research.start("roadworks", true, _pay) == ""
			and _wallet[Config.Res.TIMBER] == 90 and _wallet[Config.Res.STONE] == 95,
			"starting research pays its quoted resources exactly once")
	var paid := _wallet.duplicate()
	var payment_count := _payments
	_check(research.start("civic_building", true, _pay) != "" and _payments == payment_count,
			"busy research cannot start a second project or charge again")
	_check(research.advance(0.0) == "" and research.advance(NAN) == ""
			and research.remaining_days == 2.0,
			"paused and invalid elapsed time do not advance research")
	research.advance(1.5)
	_check(not research.allows_road_upgrade(Config.RoadLevel.IMPROVED)
			and is_equal_approx(research.quote("roadworks", true).progress, 0.75),
			"paid research stays locked until its full duration elapses")
	var restored := RoadResearch.new()
	_check(restored.restore(research.capture()) == "" and restored.capture() == research.capture(),
			"an active paid project round-trips with its exact remaining time")
	_check(restored.advance(0.5) == "roadworks"
			and restored.allows_road_upgrade(Config.RoadLevel.IMPROVED)
			and not restored.allows_road_upgrade(Config.RoadLevel.PAVED) and _wallet == paid,
			"completion after restore unlocks only its technology without another payment")
	_check(restored.start("roadworks", true, _pay) != "" and _payments == payment_count,
			"a completed technology cannot be bought a second time")
	_check(restored.start("paving", true, _pay) == "" and restored.advance(4.0) == "paving"
			and restored.allows_road_upgrade(Config.RoadLevel.PAVED),
			"paving unlocks after its prerequisite, payment and four days")
	_check(restored.start("civic_building", true, _pay) == ""
			and restored.advance(2.0) == "civic_building"
			and restored.allows_building_upgrade("house")
			and restored.allows_building_upgrade("granary")
			and not restored.allows_building_upgrade("blacksmith"),
			"civic research unlocks household and granary upgrades separately from metallurgy")
	_check(restored.start("fortification", true, _pay) == ""
			and restored.advance(3.0) == "fortification"
			and restored.allows_building_upgrade("supply_hut"),
			"fortification unlocks supply-hut upgrades after civic research")
	_check(restored.start("metallurgy", true, _pay) == ""
			and restored.advance(3.0) == "metallurgy"
			and restored.allows_building_upgrade("blacksmith"),
			"metallurgy unlocks the forge through its own paid project")
	var invalid: Array = [
		{"completed": ["paving"], "active": "", "remaining_days": 0.0},
		{"completed": ["roadworks", "roadworks"], "active": "", "remaining_days": 0.0},
		{"completed": ["unknown"], "active": "", "remaining_days": 0.0},
		{"completed": [], "active": "paving", "remaining_days": 1.0},
		{"completed": [], "active": "roadworks", "remaining_days": 3.0},
		{"completed": [], "active": "roadworks", "remaining_days": 0.0},
		{"completed": [], "active": "", "remaining_days": 1.0},
		{"completed": [], "active": "", "remaining_days": NAN},
		{"completed": [], "active": "", "remaining_days": false},
		{"completed": "roadworks", "active": "", "remaining_days": 0.0},
	]
	state = restored.capture()
	var rejected := true
	for data in invalid:
		rejected = rejected and restored.restore(data) != "" and restored.capture() == state
	_check(rejected, "invalid research saves are rejected without changing existing progress")
	_check(restored.restore({}) == "" and restored.completed.is_empty() and restored.active == "",
			"legacy saves default to unresearched technology")


func _at(x: int, y: int) -> Vector3:
	return Vector3((x + 0.5) * Config.WEAR_CELL, 0.0, (y + 0.5) * Config.WEAR_CELL)


func _set_wear(wear: WearField, x: int, y: int, value: float) -> void:
	wear.wear[y * WearField.RES + x] = value


func _connected(cells: PackedInt32Array) -> bool:
	if cells.is_empty():
		return false
	var available := {}
	for index in cells:
		available[index] = true
	var reached := {cells[0]: true}
	var queue := PackedInt32Array([cells[0]])
	var head := 0
	while head < queue.size():
		var index := queue[head]
		head += 1
		var p := Vector2i(index % WearField.RES, index / WearField.RES)
		for direction in WearField.NEIGHBOURS_8:
			var next := p + direction
			var next_index := next.y * WearField.RES + next.x
			if available.has(next_index) and not reached.has(next_index):
				reached[next_index] = true
				queue.append(next_index)
	return reached.size() == cells.size()


func _contains_all(outer: PackedInt32Array, inner: PackedInt32Array) -> bool:
	for cell in inner:
		if not outer.has(cell):
			return false
	return true


func _roads() -> void:
	var wear := WearField.new()
	for x in range(20, 100):
		_set_wear(wear, x, 50, 500.0 + 50.0 * x)
	for y in range(51, 82):
		_set_wear(wear, 35, y, 500.0)
		_set_wear(wear, 75, y, 1500.0)
	_set_wear(wear, 180, 180, 50000.0) # A busier, disconnected island cannot be selected.
	wear.apply_state(wear.capture())
	var origin := _at(20, 50)
	var small := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "busiest")
	var medium := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "local")
	var whole := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "all")
	_check(small.count == ceili(142 * 0.20) and medium.count == 71 and whole.count == 142,
			"usage scopes quote twenty, fifty and one hundred percent of the connected network")
	_check(_connected(small.route_cells) and _connected(medium.route_cells)
			and _connected(whole.route_cells), "every scope is connected")
	_check(_contains_all(medium.route_cells, small.route_cells)
			and _contains_all(whole.route_cells, medium.route_cells),
			"broader scopes contain the entire smaller selection")
	_check(small.cells.has(50 * WearField.RES + 99)
			and not whole.cells.has(180 * WearField.RES + 180),
			"selection begins on the strongest connected backbone and ignores detached islands")
	_check(small.area_m2 == small.count * Config.WEAR_CELL * Config.WEAR_CELL
			and small.cost[Config.Res.STONE] < medium.cost[Config.Res.STONE]
			and medium.cost[Config.Res.STONE] < whole.cost[Config.Res.STONE],
			"larger changed areas quote proportionally larger material costs")
	var previous_wear := wear.wear.duplicate()
	_check(wear.apply_upgrade(small) == small.count and wear.wear == previous_wear,
			"applying a quote changes exactly its cells without inflating traffic counts")
	var changed_count := 0
	for level in wear.locked:
		changed_count += int(level == Config.RoadLevel.IMPROVED)
	_check(changed_count == small.count and wear.validate_upgrade(small) != ""
			and wear.apply_upgrade(small) == 0,
			"an already applied quote cannot upgrade or charge the same cells twice")
	var repeated := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "busiest")
	_check(repeated.count == 0 and repeated.area_m2 == 0.0 and repeated.cost.is_empty(),
			"unchanged surfaces have an empty, zero-cost quote")
	var remainder := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "all")
	_check(remainder.count == whole.count - small.count and _connected(remainder.route_cells),
			"existing upgrades remain connected but are excluded from the larger area's charge")
	var quote := wear.preview_upgrade(origin, Config.RoadLevel.PAVED, "all")
	var traffic := _at(40, 50)
	wear.stamp_point(traffic.x, traffic.z, 1000.0, 0.4)
	_check(wear.validate_upgrade(quote) == "", "ordinary traffic increases preserve a quoted price and area")
	var saved_locks := wear.locked.duplicate()
	var tampered := quote.duplicate(true)
	tampered.cost[Config.Res.STONE] = 0
	_check(wear.validate_upgrade(tampered) != "" and wear.apply_upgrade(tampered) == 0
			and wear.locked == saved_locks, "a mismatched road price is rejected before any surface changes")
	wear.set_protected(_at(60, 50), Config.WEAR_CELL * 0.49, true)
	_check(wear.validate_upgrade(quote) != "" and wear.apply_upgrade(quote) == 0,
			"a newly protected connector invalidates the old quote atomically")
	_check(wear.preview_upgrade(_at(60, 50), Config.RoadLevel.PAVED).count == 0,
			"protected ground cannot be commissioned as a road")


func _natural_and_saved_surfaces() -> void:
	var wear := WearField.new()
	var p := _at(30, 30)
	wear.stamp_point(p.x, p.z, Config.ROAD_THRESHOLD[Config.RoadLevel.PAVED] * 20.0, 0.4)
	wear.refresh_levels()
	_check(wear.road_level_at(p.x, p.z) == Config.RoadLevel.DIRT
			and wear.road_level_of_cell(15, 15) == Config.RoadLevel.DIRT
			and wear.speed_multiplier_at(p.x, p.z) == Config.ROAD_SPEED[Config.RoadLevel.DIRT],
			"even extreme traffic stops at dirt in both movement and navigation")
	var quote := wear.preview_upgrade(p, Config.RoadLevel.PAVED)
	wear.apply_upgrade(quote)
	wear.decay(100000.0)
	wear.refresh_levels()
	_check(wear.wear_at(p.x, p.z) == 0.0 and wear.road_level_at(p.x, p.z) == Config.RoadLevel.PAVED,
			"paid paving survives when its traffic history decays away")
	var restored := WearField.new()
	restored.apply_state(wear.capture())
	_check(restored.road_level_of_cell(15, 15) == Config.RoadLevel.PAVED
			and restored.speed_multiplier_at(p.x, p.z) == Config.ROAD_SPEED[Config.RoadLevel.PAVED],
			"saved paid surfaces restore navigation and walking speed independently of raw wear")
	restored.flush_texture(true)
	# Headless dummy textures do not retain GPU updates; inspect the image
	# passed to the renderer so this still verifies the uploaded surface data.
	var pixel := restored._image.get_pixel(30, 30)
	_check(pixel.r == 1.0, "the restored terrain texture also displays the paid paved surface")
	var illegal := restored.preview_upgrade(Vector3(-1, 0, 2), Config.RoadLevel.PAVED)
	_check(illegal.error != "" and restored.apply_upgrade(illegal) == 0,
			"out-of-bounds proposals are rejected instead of clamped onto another route")


func _large_network() -> void:
	var wear := WearField.new()
	for y in range(10, 120):
		for x in range(10, 210):
			_set_wear(wear, x, y, 800.0)
	var origin := _at(10, 10)
	var quote := wear.preview_upgrade(origin, Config.RoadLevel.IMPROVED, "all")
	_check(quote.count == 22000 and wear.route_extent(origin, 6000) == 22000,
			"all connected routes includes more than both former preview and application limits")
	_check(wear.apply_upgrade(quote) == 22000,
			"the complete quoted network is exactly the network that gets upgraded")



# --- The footfall overlay ---------------------------------------------------
#
# The overlay is presentation, so what these have to prove is mostly negative:
# that it draws from data the simulation was already uploading, that it writes
# nothing the simulation or a save reads back, and that it neither runs nor
# costs anything until it is asked for. The display suites cannot run without
# a display, so the picture itself is not checked here — only every number
# that goes into it.


## The shader's `const vec3 FOOT_* = vec3(r, g, b);` lines, in linear.
func _shader_constants(code: String) -> Dictionary:
	var found := {}
	var pattern := RegEx.create_from_string(
			"const vec3 (FOOT_[A-Z]+) = vec3\\(([^)]*)\\)")
	for match in pattern.search_all(code):
		var parts := match.get_string(2).split(",")
		if parts.size() == 3:
			found[match.get_string(1)] = Color(float(parts[0]), float(parts[1]),
					float(parts[2]))
	return found


## The shader's linear literal against the interface's sRGB one. The tolerance
## is the rounding in the shader's four decimal places, not a licence to drift.
func _same_colour(linear: Variant, srgb: Color) -> bool:
	if not linear is Color:
		return false
	var want: Color = srgb.srgb_to_linear()
	return absf(linear.r - want.r) < 0.0005 and absf(linear.g - want.g) < 0.0005 \
			and absf(linear.b - want.b) < 0.0005


func _descendants(node: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child in node.get_children():
		found.append(child)
		found.append_array(_descendants(child))
	return found


func _press(game: Node, key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	game._unhandled_input(event)


func _terrain_materials(terrain: Node) -> Array:
	var shader: Shader = load("res://shaders/terrain.gdshader")
	var found := []
	for child in terrain.get_children():
		var geometry := child as GeometryInstance3D
		if geometry == null:
			continue
		var material := geometry.material_override as ShaderMaterial
		if material != null and material.shader == shader:
			found.append(material)
	return found


## Footfall reaches the shader on its own channel, apart from what was paid for.
func _footfall_channel() -> void:
	var wear := WearField.new()
	var p := _at(40, 60)
	# 300 wear is halfway from a worn patch to a footpath: 1.5 of 5 stages,
	# which the texture carries as int(1.5 * 255/5) = 76.
	wear.stamp_point(p.x, p.z, 300.0, 0.4)
	wear.flush_texture(true)
	var trodden := wear._image.get_pixel(40, 60)
	_check(is_equal_approx(trodden.g, 76.0 / 255.0) and trodden.r == trodden.g,
			"footfall is uploaded on its own channel beside the visible surface")

	var before_wear := wear.wear.duplicate()
	var before_revision := wear.route_revision
	wear.apply_upgrade(wear.preview_upgrade(p, Config.RoadLevel.PAVED, "all"))
	wear.flush_texture(true)
	var paved := wear._image.get_pixel(40, 60)
	# The paid surface is what the ground looks like; the footfall channel still
	# reports the traffic that is actually crossing it, which is the one thing
	# worth knowing about a road somebody paid for.
	_check(paved.r == 1.0 and paved.g == trodden.g
			and Config.road_level_for_wear(wear.wear_at(p.x, p.z)) == Config.RoadLevel.WORN,
			"a commissioned surface hides nothing: footfall under it is unchanged")
	_check(wear.wear == before_wear and wear.route_revision == before_revision,
			"uploading the overlay channel changes no traffic and no route revision")

	# Nothing the simulation or a save reads may move because a texture was
	# written. capture() is exactly what persistence stores.
	wear.refresh_levels()
	var q := _at(41, 60)
	wear.stamp_point(q.x, q.z, 900.0, 0.4)
	var settled := wear.capture()
	var settled_levels := wear.nav_level.duplicate()
	var settled_revision := wear.route_revision
	wear.flush_texture(true)
	var after_state := wear.capture()
	_check(after_state.wear == settled.wear and after_state.locked == settled.locked
			and wear.nav_level == settled_levels
			and wear.route_revision == settled_revision
			and wear.level_from_wear(20, 30) == Config.RoadLevel.PAVED,
			"flushing the texture leaves saved wear and road levels where they were")


## The same channel on a world large enough to use per-tile road textures.
##
## Big worlds never touch the single world-sized image the check above reads:
## they bake and refresh one texture per visible tile instead, by a separate
## path with its own copy of the packing. A channel added to one and not the
## other is an overlay that works on the opening map and goes dark on the ones
## where knowing which way people walk matters most.
func _footfall_on_a_large_world() -> void:
	var wear := WearField.new()
	wear.setup(1536.0)
	_check(wear.grid_size > Config.GRID, "the fixture is large enough to be tiled")
	var p := Vector3((40 + 0.5) * Config.WEAR_CELL, 0.0, (60 + 0.5) * Config.WEAR_CELL)
	wear.stamp_point(p.x, p.z, 300.0, 0.4)
	var tile := Vector2i(40 / WearField.TILE_TEXELS, 60 / WearField.TILE_TEXELS)
	var local := Vector2i(40, 60) - tile * WearField.TILE_TEXELS + Vector2i.ONE
	wear.tile_texture(tile)
	var baked: Color = wear._tiles[tile].image.get_pixel(local.x, local.y)
	_check(is_equal_approx(baked.g, 76.0 / 255.0) and baked.r == baked.g,
			"a freshly baked road tile carries footfall on its own channel")

	# 1200 wear is most of the way from a footpath to a cart track: 2.4667 of
	# five stages, which the tile carries as int(2.4667 * 51) = 125.
	wear.stamp_point(p.x, p.z, 900.0, 0.4)
	wear.apply_upgrade(wear.preview_upgrade(p, Config.RoadLevel.PAVED, "all"))
	wear.flush_texture(true)
	var refreshed: Color = wear._tiles[tile].image.get_pixel(local.x, local.y)
	_check(is_equal_approx(refreshed.g, 125.0 / 255.0) and refreshed.r == 1.0,
			"refreshing a road tile keeps footfall apart from the paid surface")

	# A large world keeps no world-sized wear texture: it is a 1x1 stub, and
	# only the tiles around the camera hold anything. The shader tells the two
	# apart by the map's own width and leaves distant ground alone rather than
	# draining it and then reporting no traffic across it. If that stub ever
	# grows, the overlay silently starts lying over half a kingdom, so the
	# width the shader keys on is pinned here.
	_check(wear.texture().get_width() == 1
			and wear.tile_texture(tile).get_width() == WearField.TILE_TEXELS + 2
			and WearField.new().texture().get_width() == Config.WEAR_RES,
			"only a world small enough to hold one carries a whole-world wear map")


## The toggle reaches every terrain material and only terrain materials.
func _footfall_toggle() -> void:
	var game_script: GDScript = load("res://scripts/core/game.gd")
	var shader: Shader = load("res://shaders/terrain.gdshader")
	var uniforms := []
	for entry in shader.get_shader_uniform_list():
		uniforms.append(entry.get("name", ""))
	_check(uniforms.has("wear_overlay"),
			"the terrain shader declares the overlay uniform the interface sets")

	# Two terrain materials, because the terrain hands its close chunks their
	# own duplicate; one water material, which must not be touched; and a node
	# that is not geometry at all.
	var terrain := Node3D.new()
	var shared := ShaderMaterial.new()
	shared.shader = shader
	var detail := shared.duplicate() as ShaderMaterial
	var water := ShaderMaterial.new()
	water.shader = load("res://shaders/water.gdshader")
	for material in [shared, detail, water]:
		var mesh := MeshInstance3D.new()
		mesh.material_override = material
		terrain.add_child(mesh)
	terrain.add_child(Node3D.new())

	_check(shared.get_shader_parameter("wear_overlay") == null
			and detail.get_shader_parameter("wear_overlay") == null,
			"terrain materials carry no overlay value until the overlay is asked for")
	var touched: int = game_script.apply_footfall_overlay(terrain, true)
	_check(touched == 2 and shared.get_shader_parameter("wear_overlay") == 1.0
			and detail.get_shader_parameter("wear_overlay") == 1.0,
			"switching the overlay on reaches the shared material and each detail duplicate")
	_check(water.get_shader_parameter("wear_overlay") == null,
			"materials belonging to other shaders are left alone")
	touched = game_script.apply_footfall_overlay(terrain, false)
	_check(touched == 2 and shared.get_shader_parameter("wear_overlay") == 0.0
			and detail.get_shader_parameter("wear_overlay") == 0.0,
			"switching it off returns every terrain material to inert")
	_check(game_script.apply_footfall_overlay(null, true) == 0,
			"a missing terrain is not an error")
	terrain.free()

	# The legend is built by a static function with no world, no camera and no
	# viewport in reach, which is the state a headless run is in.
	var legend: Control = game_script.build_footfall_legend()
	var ramp: Gradient = null
	var swatches := PackedColorArray()
	var words := ""
	for node in _descendants(legend):
		if node is TextureRect and node.texture is GradientTexture1D:
			ramp = node.texture.gradient
		elif node is ColorRect:
			swatches.append(node.color)
		elif node is Label:
			words += node.text + " "
	_check(legend != null and ramp != null
			and ramp.colors == PackedColorArray(game_script.FOOTFALL_RAMP)
			and swatches.has(game_script.FOOTFALL_EDGE)
			and swatches.has(game_script.FOOTFALL_BUILT),
			"the legend shows its own ramp and both of its keyed colours")

	# And that those colours are the map's. The interface holds the palette in
	# sRGB and the shader holds it converted to linear, which is two copies of
	# one thing and therefore a thing that drifts — and a legend that disagrees
	# with the ground is a worse failure than no legend, because it is believed.
	# Comparing the constants against each other would only prove they are
	# themselves, so this reads the shader's own source.
	var shader_colours := _shader_constants(shader.code)
	var names: Array[String] = ["FOOT_LOW", "FOOT_MID", "FOOT_HIGH", "FOOT_PEAK"]
	var agrees := shader_colours.size() == 6
	for i in names.size():
		agrees = agrees and _same_colour(shader_colours.get(names[i]),
				game_script.FOOTFALL_RAMP[i])
	agrees = agrees and _same_colour(shader_colours.get("FOOT_EDGE"),
			game_script.FOOTFALL_EDGE)
	agrees = agrees and _same_colour(shader_colours.get("FOOT_BUILT"),
			game_script.FOOTFALL_BUILT)
	_check(agrees, "every colour in the legend is the colour the shader paints")
	_check(words.contains("worn") and words.contains("path")
			and words.contains("track") and words.to_lower().contains("commissioned"),
			"the legend names the stages the ramp is divided into")
	legend.free()


## The same thing again against the real game, where the terrain, the interface
## and the save are all present and none of them may move.
func _footfall_in_game() -> void:
	var game: Node = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var harness: Node = load("res://scripts/core/harness.gd").new()
	harness.game = game

	var before: Dictionary = harness._fingerprint()
	var before_wear: Dictionary = game.world.wear.capture()
	var before_levels: PackedByteArray = game.world.wear.nav_level.duplicate()
	var before_revision: int = game.world.wear.route_revision

	var materials := _terrain_materials(game.world.terrain)
	var untouched := not materials.is_empty()
	for material in materials:
		untouched = untouched and material.get_shader_parameter("wear_overlay") == null
	_check(untouched, "a march that has never asked for the overlay never writes it")

	# Through the key, not the function behind it. Everything else in here
	# calls _toggle_footfall_overlay directly, which would go on passing if P
	# were bound to nothing or bound to something else.
	_press(game, KEY_P)
	var lit: bool = game.show_footfall
	for material in _terrain_materials(game.world.terrain):
		lit = lit and material.get_shader_parameter("wear_overlay") == 1.0
	_check(lit and game._footfall_legend != null and game._footfall_legend.visible,
			"pressing P raises the overlay and its legend on a real terrain")

	_press(game, KEY_P)
	var dark: bool = not game.show_footfall
	for material in _terrain_materials(game.world.terrain):
		dark = dark and material.get_shader_parameter("wear_overlay") == 0.0
	_check(dark and not game._footfall_legend.visible,
			"pressing P again puts the world and the legend back")

	var drift: Array[String] = harness._state_drift("", before, harness._fingerprint())
	for line in drift:
		print("  " + line)
	var after_wear: Dictionary = game.world.wear.capture()
	_check(drift.is_empty() and after_wear.wear == before_wear.wear
			and after_wear.locked == before_wear.locked
			and game.world.wear.nav_level == before_levels
			and game.world.wear.route_revision == before_revision,
			"raising and lowering the overlay moves nothing that is simulated or saved")
	# A load replaces the very terrain the overlay was painted onto. The
	# overlay is a way of looking and is deliberately not in the save, so what
	# has to survive the swap is the live toggle — a march that came back with
	# the legend up and the ground drawn normally would be worse than one that
	# came back with the overlay down.
	game._toggle_footfall_overlay()
	var slot := "footfall_overlay_regression"
	_check(game.save_game(slot) == "" and game.load_game(slot) == "",
			"the fixture saves and loads with the overlay raised")
	var reloaded := _terrain_materials(game.world.terrain)
	var relit: bool = game.show_footfall and not reloaded.is_empty()
	for material in reloaded:
		relit = relit and material.get_shader_parameter("wear_overlay") == 1.0
	_check(relit and game._footfall_legend.visible,
			"a loaded march comes back with the overlay still raised")
	DirAccess.remove_absolute(SaveGame.slot_path(slot))

	game.free()
	harness.free()


func _run() -> void:
	_research()
	_roads()
	_natural_and_saved_surfaces()
	_large_network()
	_footfall_channel()
	_footfall_on_a_large_world()
	_footfall_toggle()
	_footfall_in_game()
	print("Road research regression failures: %d" % _failures)
	quit(1 if _failures else 0)
