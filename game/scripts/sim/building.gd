class_name Building
extends Node3D

## A placed structure: its inventory, its workers, and its construction state.
##
## Construction is physical (design doc 6.3): a blueprint is placed, materials
## are hauled to the site, and only then do builders raise it. The visual mesh
## grows out of the ground as construction progresses, so a settlement under
## construction reads at a glance.

signal construction_finished(building: Building)

var id: int = -1
var type_id: String = ""
var def: BuildingDefs.Def = null
var asset_id: String = ""

var footprint := Vector2(4, 4)
var ground_y := 0.0
var yaw := 0.0

## Goods held here. Index by Config.Res.
var inventory := PackedFloat32Array()
var incoming := PackedFloat32Array()   # already promised by a hauler
var reserved := PackedFloat32Array()   # already claimed for collection

var workers: Array[int] = []
var residents: Array[int] = []
## Food kept in by the household, in food units.
##
## Deliberately NOT part of the stores index. A larder is not settlement stock:
## a road crew must not be able to requisition the family's supper, and a
## hauler must not be able to take it back out again to supply a building site.
## It only ever goes in by somebody carrying it home, and only ever comes out
## at a meal.
var larder := 0.0

var under_construction := true
var delivered := {}                    # Res -> amount delivered so far
var build_progress := 0.0              # 0..1 once materials are on site
## What this particular piece of work costs and how long it takes. Normally the
## definition's own figures; during an upgrade, the upgrade's. Held here rather
## than read from the def each time because an upgrading building already wears
## the *finished* definition — that is what makes the blueprint show what is
## coming — and the finished definition does not know the price of getting
## there.
var build_cost: Dictionary = {}
var build_seconds := 10.0
## Plots currently under crop — one per employed farmhand.
var fields: Array[Vector3] = []
## Every plot the farm could work if it were fully staffed.
var _all_plots: Array[Vector3] = []
var crop_growth := 0.0

var _height := 4.0
var _visual: Node3D
var _blueprint: Node3D
var _site_pad: MeshInstance3D
var _ghost_material: StandardMaterial3D
var _body: StaticBody3D
var _field_mm: MultiMeshInstance3D
var _soil_mm: MultiMeshInstance3D
var _smoke: GPUParticles3D
## Goods shown sitting in the yard, keyed by the attachment slot they fill.
var _stock_slots: Array[Node3D] = []
var _stock_shown: Array[int] = []
var _registry: AssetRegistry


func setup(building_id: int, definition: BuildingDefs.Def,
		   registry: AssetRegistry, variant: String = "") -> void:
	id = building_id
	def = definition
	type_id = def.type_id
	asset_id = variant if variant != "" else def.asset
	footprint = registry.footprint(asset_id)
	_height = registry.height(asset_id)

	inventory.resize(Config.RES_COUNT)
	incoming.resize(Config.RES_COUNT)
	reserved.resize(Config.RES_COUNT)

	build_cost = def.cost.duplicate()
	build_seconds = def.build_time
	for res in build_cost:
		delivered[res] = 0.0

	_registry = registry
	name = "%s_%d" % [type_id, building_id]
	_build_visual(registry)
	_build_body()


func _build_visual(registry: AssetRegistry) -> void:
	_visual = registry.instantiate_with_lods(asset_id)
	add_child(_visual)

	if under_construction:
		# Two visuals while building: a translucent ghost of the finished
		# structure, so the player can see what is coming and how it sits on
		# the site, and the real building rising inside it as work proceeds.
		_blueprint = registry.instantiate(asset_id, 1)
		_blueprint.name = "blueprint"
		add_child(_blueprint)
		_set_material_on(_blueprint, _blueprint_material())
		_add_site_pad()

	_apply_construction_visual()

	if registry.has_attachment(asset_id, "att_smoke"):
		_add_smoke(registry.attachment(asset_id, "att_smoke"))


## The translucent shape of the finished building, standing over the site while
## the real one is raised inside it.
##
## Unshaded, for the same reason the placement ghost is: a lit translucent
## surface at a quarter alpha takes its value from whatever the sun is doing to
## it, which on a bright morning is nothing at all. Holding one constant tone
## instead means the plan reads the same at dawn as at noon, and against grass
## as against the brown of its own site pad — which is the entire job of a
## drawing laid over a scene.
func _blueprint_material() -> StandardMaterial3D:
	if _ghost_material == null:
		_ghost_material = StandardMaterial3D.new()
		_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_material.albedo_color = Color(0.58, 0.76, 0.96, 0.32)
		_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_ghost_material.no_depth_test = false
	return _ghost_material


## A flat patch of cleared earth marking the footprint, so a site reads as a
## site from the moment it is ordered.
func _add_site_pad() -> void:
	var plane := PlaneMesh.new()
	plane.size = footprint + Vector2(1.4, 1.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.28, 0.19)
	mat.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.name = "site_pad"
	mi.mesh = plane
	mi.material_override = mat
	mi.position.y = 0.04
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_site_pad = mi


func _build_body() -> void:
	## A simple box body, sized from the manifest, is all the game needs for
	## click-picking. Terrain uses analytic raycasts, not physics.
	_body = StaticBody3D.new()
	_body.name = "pick"
	_body.collision_layer = 2
	_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Sized from what the generator actually produced, so tall structures are
	# as easy to click as low ones.
	var h: float = clampf(_height, 2.0, 18.0)
	box.size = Vector3(footprint.x, h, footprint.y)
	shape.shape = box
	shape.position.y = h * 0.5
	_body.add_child(shape)
	_body.set_meta("building_id", id)
	add_child(_body)


## Smoke swells as it rises, so a plume thins out instead of marching upward
## as a row of identical squares.
func _smoke_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.35))
	curve.add_point(Vector2(0.45, 1.0))
	curve.add_point(Vector2(1.0, 1.6))
	var tex := CurveTexture.new()
	tex.curve = curve
	return tex


func _add_smoke(local: Vector3) -> void:
	var particles := GPUParticles3D.new()
	particles.name = "smoke"
	particles.position = local
	particles.amount = 14
	particles.lifetime = 3.2
	particles.explosiveness = 0.0
	# Without this the plume keeps climbing for as long as it lives and reads
	# as a dotted line ruled up the sky.
	particles.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 7, 6))

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0.25, 1, 0.1)
	mat.spread = 18.0
	mat.initial_velocity_min = 0.35
	mat.initial_velocity_max = 0.6
	mat.gravity = Vector3(0.5, 0.2, 0.0)
	mat.damping_min = 0.4
	mat.damping_max = 0.8
	mat.scale_min = 0.7
	mat.scale_max = 1.5
	mat.scale_curve = _smoke_scale_curve()
	mat.color = Color(0.72, 0.72, 0.70, 0.30)
	particles.process_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(1.3, 1.3)
	var qmat := StandardMaterial3D.new()
	qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.albedo_color = Color(0.80, 0.79, 0.77, 0.16)
	qmat.vertex_color_use_as_albedo = true
	quad.material = qmat
	particles.draw_pass_1 = quad
	particles.emitting = false
	add_child(particles)
	_smoke = particles


# --- Construction -----------------------------------------------------------

## What still has to reach the site. Subtracts deliveries already on their way,
## without which a 15-timber building ordered two 12-timber loads and quietly
## destroyed the 9 it could not use.
func materials_needed() -> Dictionary:
	var out := {}
	for res in build_cost:
		var need: float = (float(build_cost[res])
				- float(delivered.get(res, 0.0)) - incoming[res])
		if need > 0.01:
			out[res] = need
	return out


## What the site is still short of ignoring deliveries in flight — the figure
## the player is shown, and the test for whether building can begin.
func materials_outstanding() -> Dictionary:
	var out := {}
	for res in build_cost:
		var need: float = float(build_cost[res]) - float(
				delivered.get(res, 0.0))
		if need > 0.01:
			out[res] = need
	return out


## Accept a delivery, returning whatever the site had no use for so the hauler
## can put it back rather than it vanishing into the foundations.
func deliver_material(res: int, amount: float) -> float:
	var wanted: float = maxf(0.0,
			float(build_cost.get(res, 0.0)) - float(delivered.get(res, 0.0)))
	var used: float = minf(amount, wanted)
	delivered[res] = float(delivered.get(res, 0.0)) + used
	_apply_construction_visual()
	return amount - used


func materials_complete() -> bool:
	return materials_outstanding().is_empty()


## Builders advance this. Returns true on the tick it completes.
func advance_construction(delta_seconds: float) -> bool:
	if not under_construction or not materials_complete():
		return false
	var build_time: float = maxf(0.1, build_seconds)
	build_progress = minf(1.0, build_progress + delta_seconds / build_time)
	_apply_construction_visual()
	if build_progress >= 1.0:
		finish_construction()
		return true
	return false


func finish_construction() -> void:
	if not under_construction:
		return
	under_construction = false
	build_progress = 1.0
	_apply_construction_visual()
	if _smoke and def.role in [BuildingDefs.Role.HOUSING,
			BuildingDefs.Role.SEAT, BuildingDefs.Role.FARM]:
		_smoke.emitting = true
	construction_finished.emit(self)


## Grow this building into the next tier in place (design doc 6.4).
##
## Deliberately not "demolish and rebuild": the structure keeps its id, its
## stock, its staff and its residents, and goes back to being a site that
## haulers supply and builders raise. What the settlement has built stays where
## it was built — which is the whole point of upgrading rather than replacing.
## `cost` and `seconds` are the *current* definition's price for growing, not
## the next one's — the next tier's upgrade figures describe the tier after
## that, and reading them here quietly made every upgrade free.
## Returns whatever stock the new tier cannot hold, for the caller to put back
## into the settlement's stores.
func begin_upgrade(next: BuildingDefs.Def, cost: Dictionary, seconds: float,
				   registry: AssetRegistry) -> Dictionary:
	def = next
	type_id = next.type_id
	asset_id = next.asset
	footprint = registry.footprint(asset_id)
	_height = registry.height(asset_id)

	under_construction = true
	build_progress = 0.0
	build_cost = cost.duplicate()
	build_seconds = seconds
	delivered = {}
	for res in build_cost:
		delivered[res] = 0.0

	# Anything the smaller building held that the larger one does not stock
	# goes back out through the usual channels rather than being deleted. The
	# comment said as much long before the code did: this used to zero the
	# inventory and return nothing, so the goods were simply destroyed.
	var orphaned := {}
	for res in Config.RES_COUNT:
		if inventory[res] > 0.0 and not stores(res):
			orphaned[res] = inventory[res]
			inventory[res] = 0.0

	for child in [_visual, _blueprint, _site_pad, _smoke]:
		if child != null and is_instance_valid(child):
			child.queue_free()
	_visual = null
	_blueprint = null
	_site_pad = null
	_smoke = null
	for slot in _stock_slots:
		if slot != null and is_instance_valid(slot):
			slot.queue_free()
	_stock_slots.clear()
	_stock_shown.clear()

	_build_visual(registry)
	if _body != null:
		_body.queue_free()
		_body = null
	_build_body()
	return orphaned


## Re-apply the parts of a saved building that construction alone does not
## imply: what it holds, how far its crop has come on, and who belongs to it.
##
## Placement has already happened by the time this is called, so nothing here
## touches the terrain, the navigation grid or the stores index — the caller
## owns those, exactly as it does when a building is placed during play.
func apply_state(entry: Dictionary) -> void:
	var saved_inventory: PackedFloat32Array = entry.get(
			"inventory", PackedFloat32Array())
	for res in mini(saved_inventory.size(), Config.RES_COUNT):
		inventory[res] = saved_inventory[res]

	delivered = (entry.get("delivered", {}) as Dictionary).duplicate()
	build_progress = float(entry.get("build_progress", 0.0))
	build_cost = (entry.get("build_cost", build_cost) as Dictionary).duplicate()
	build_seconds = float(entry.get("build_seconds", build_seconds))
	crop_growth = float(entry.get("crop_growth", 0.0))
	larder = float(entry.get("larder", 0.0))

	workers.assign(entry.get("workers", []))
	residents.assign(entry.get("residents", []))

	if under_construction:
		_apply_construction_visual()
	else:
		if def.is_farm():
			sync_fields_to_workers()
		refresh_stock_display()


## While a building is going up it is shown as a translucent blueprint that
## fills in from the ground as work proceeds.
func _apply_construction_visual() -> void:
	if _visual == null:
		return
	if not under_construction:
		_visual.visible = true
		_visual.scale = Vector3.ONE
		_visual.position.y = 0.0
		if _blueprint:
			_blueprint.queue_free()
			_blueprint = null
		if _site_pad:
			_site_pad.queue_free()
			_site_pad = null
		return

	var needed := build_cost
	var total := 0.0
	var have := 0.0
	for res in needed.keys():
		total += float(needed[res])
		have += float(delivered.get(res, 0.0))
	var supply: float = 1.0 if total <= 0.0 else clampf(have / total, 0.0, 1.0)

	# Materials on site raise the frame a little; the builders' labour does the
	# rest. A site that has everything delivered but no worker still looks
	# unfinished, which is the point of making construction physical.
	var raised := clampf(supply * 0.30 + build_progress * 0.70, 0.0, 1.0)

	_visual.visible = raised > 0.02
	_visual.scale = Vector3(1.0, maxf(0.02, raised), 1.0)
	if _blueprint:
		_blueprint.visible = true
		_blueprint_material().albedo_color.a = lerpf(0.30, 0.10, raised)


func _set_material_on(root: Node3D, mat: Material) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			child.material_override = mat


# --- Inventory --------------------------------------------------------------

func stores(res: int) -> bool:
	return def.stores_resource(res)


func capacity() -> float:
	return def.storage


## How much a household will keep in: a few days' eating for everyone housed.
func larder_capacity() -> float:
	return def.houses * Config.HUNGER_PER_DAY * Config.LARDER_DAYS


func larder_space() -> float:
	return maxf(0.0, larder_capacity() - larder)


## Put food in the larder, returning what would not fit.
func stock_larder(amount: float) -> float:
	var taken: float = minf(amount, larder_space())
	larder += taken
	return amount - taken


## Sit down to a meal. False when the cupboard is bare.
##
## A seat that stores food feeds its own household straight from that store —
## the keep has no separate pantry, and asking settlers living in it to walk to
## a granary that is fifty metres away and also themselves would be absurd.
func take_meal() -> bool:
	if larder >= Config.MEAL_FOOD:
		larder -= Config.MEAL_FOOD
		return true
	if stores(Config.Res.FOOD) and inventory[Config.Res.FOOD] >= Config.MEAL_FOOD:
		inventory[Config.Res.FOOD] -= Config.MEAL_FOOD
		return true
	return false


## Whether this household wants somebody to fetch food home.
func larder_is_low() -> bool:
	return def.houses > 0 and larder < larder_capacity() * 0.5


func total_stored() -> float:
	var total := 0.0
	for v in inventory:
		total += v
	return total


func space_for(res: int) -> float:
	if not stores(res):
		return 0.0
	var used := total_stored()
	for v in incoming:
		used += v
	return maxf(0.0, capacity() - used)


## Put goods in. Never accepts more than there is room for: `space_for` has
## already reserved the pending deliveries, and adding that allowance back was
## letting a full building keep accepting loads past its own capacity.
func add(res: int, amount: float) -> float:
	var room := maxf(0.0, capacity() - total_stored())
	if not stores(res):
		return 0.0
	var taken: float = minf(amount, room)
	inventory[res] += taken
	return taken


func remove(res: int, amount: float) -> float:
	var taken: float = minf(amount, inventory[res])
	inventory[res] -= taken
	return taken


## Stock not already promised to a hauler.
func available(res: int) -> float:
	return maxf(0.0, inventory[res] - reserved[res])


# --- Workplace --------------------------------------------------------------

## The footprint as it lies in world axes. A building rotated a quarter turn
## occupies its depth along X, which placement and navigation both need to know
## and previously both ignored.
func plan_footprint() -> Vector2:
	var c: float = absf(cos(yaw))
	var sn: float = absf(sin(yaw))
	return Vector2(footprint.x * c + footprint.y * sn,
			footprint.x * sn + footprint.y * c)


func has_worker_space() -> bool:
	return workers.size() < def.worker_slots


func has_house_space() -> bool:
	return residents.size() < def.houses


func display_name() -> String:
	return def.display_name


# --- Farm fields ------------------------------------------------------------

## Lay out the farm's fields and show them.
##
## The plots grow outward from the farmyard as one connected block, snapped to
## the simulation grid, so a farm has a *field* beside it rather than a dozen
## plots scattered over wherever the fertility noise happened to peak. Each
## candidate is scored on fertility and flatness but only considered once it
## touches ground the farm already works, which is what keeps it contiguous.
func create_fields(hm: Heightmap, nav: NavGrid,
				   registry: AssetRegistry) -> void:
	if not def.is_farm():
		return

	var wanted := plot_capacity()
	var origin := Config.world_to_cell(global_position)
	var radius_cells := int(def.work_radius / Config.CELL)
	var claimed := {}
	var frontier := {}

	# Seed the frontier with the cells immediately around the farmyard.
	for d in _ring_offsets(2):
		var c: Vector2i = origin + d
		if _plot_is_viable(c, hm, nav):
			frontier[c] = _plot_score(c, origin, hm)

	while _all_plots.size() < wanted and not frontier.is_empty():
		var best: Vector2i = Vector2i.ZERO
		var best_score := -INF
		for c in frontier:
			var score: float = frontier[c]
			if score > best_score:
				best_score = score
				best = c
		frontier.erase(best)
		if claimed.has(best):
			continue
		claimed[best] = true

		var p := Config.cell_to_world(best)
		p.y = hm.height_at(p.x, p.z)
		_all_plots.append(p)

		# Only cells adjoining the field so far become candidates, which is
		# what makes the result a block instead of a scatter.
		for d in _ring_offsets(1):
			var n: Vector2i = best + d
			if claimed.has(n) or frontier.has(n):
				continue
			if origin.distance_to(Vector2(n)) > radius_cells:
				continue
			if _plot_is_viable(n, hm, nav):
				frontier[n] = _plot_score(n, origin, hm)

	if _all_plots.is_empty():
		return

	# Which plots count as worked ground — costly to cross, and refusing to
	# record a track — is decided in one place, Simulation._protect_fields,
	# because it follows the staffing rather than the layout. Setting it here
	# too meant a farm with one hand made its whole potential field expensive
	# to walk across while showing bare grass over most of it.

	_soil_mm = _make_field_layer(registry, "field_plot", "field_soil")
	_field_mm = _make_field_layer(registry, "wheat_crop", "field_crop")
	sync_fields_to_workers()

	# Fields are sown as the farmstead is built, so a new farm is not a week
	# of nothing before its first harvest.
	set_crop_growth(Config.FARM_INITIAL_GROWTH)


## Replace a generated field layout with the one from a save.
##
## The layout has to be stored rather than recomputed. It is chosen by growing
## a block outward over whichever ground is passable at the moment the farm is
## founded, so a farm rebuilt after the rest of the settlement already exists
## lays its field somewhere else — and since worked ground is protected from
## wear, that silently erased tracks the player had spent days making.
func adopt_plots(plots: Array, hm: Heightmap, nav: NavGrid,
				 registry: AssetRegistry) -> void:
	if not def.is_farm():
		return
	# Whichever ground the generated layout had claimed goes back to being
	# ordinary grass; Simulation._protect_fields then marks the plots this farm
	# is actually working, which is the one place that decides it.
	for p in _all_plots:
		var old := Config.world_to_cell(p)
		nav.set_cultivated(old.x, old.y, false)

	_all_plots.clear()
	for p in plots:
		var world_p: Vector3 = p
		world_p.y = hm.height_at(world_p.x, world_p.z)
		_all_plots.append(world_p)

	if _soil_mm:
		_soil_mm.queue_free()
	if _field_mm:
		_field_mm.queue_free()
	_soil_mm = _make_field_layer(registry, "field_plot", "field_soil")
	_field_mm = _make_field_layer(registry, "wheat_crop", "field_crop")
	sync_fields_to_workers()
	set_crop_growth(crop_growth)


## How many plots this farm would work at full staffing.
func plot_capacity() -> int:
	return def.worker_slots * def.plots_per_worker


## Bring the visible field into line with who is actually employed here.
##
## Ground nobody works is ground that goes back to grass, so an understaffed
## farm shows a smaller field rather than a dozen plots tended by two people.
## Returns true when the set of worked plots actually changed, so the caller
## can re-apply whatever depends on it.
func sync_fields_to_workers() -> bool:
	if def.plots_per_worker <= 0 or _all_plots.is_empty():
		return false
	var active: int = clampi(workers.size() * def.plots_per_worker,
			0, _all_plots.size())
	if active == fields.size():
		return false

	fields.clear()
	for i in active:
		fields.append(_all_plots[i])

	if _soil_mm:
		for i in _all_plots.size():
			var visible := i < active
			var basis := Basis() if visible else Basis().scaled(Vector3.ZERO)
			_soil_mm.multimesh.set_instance_transform(
					i, Transform3D(basis, _all_plots[i]))
	set_crop_growth(crop_growth)
	return true


func _ring_offsets(r: int) -> Array:
	var out: Array[Vector2i] = []
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx == 0 and dz == 0:
				continue
			out.append(Vector2i(dx, dz))
	return out


func _plot_is_viable(c: Vector2i, hm: Heightmap, nav: NavGrid) -> bool:
	if not Config.in_bounds(c):
		return false
	if nav.is_solid(c.x, c.y):
		return false
	if hm.cell_slope(c.x, c.y) > 0.22:
		return false
	if hm.cell_surface(c.x, c.y) == Heightmap.Surface.WATER:
		return false
	return hm.cell_fertility(c.x, c.y) >= 0.12


## Good ground close to the farmhouse first — a farmer should not walk past
## three empty fields to reach the one being worked.
func _plot_score(c: Vector2i, origin: Vector2i, hm: Heightmap) -> float:
	var dist := Vector2(c - origin).length()
	return hm.cell_fertility(c.x, c.y) * 2.0 - dist * 0.12 \
			- hm.cell_slope(c.x, c.y) * 1.5


func _make_field_layer(registry: AssetRegistry, asset: String,
					   node_name: String) -> MultiMeshInstance3D:
	var mesh := registry.mesh(asset, 0)
	if mesh == null:
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = _all_plots.size()

	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.top_level = true
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


## Crops visibly grow. Only the grain scales — the ploughed soil beneath it
## stays put, so a young field reads as a tilled field rather than a stain.
func set_crop_growth(t: float) -> void:
	crop_growth = clampf(t, 0.0, 1.0)
	if _field_mm == null:
		return
	var height := lerpf(0.06, 1.0, crop_growth)
	var spread := lerpf(0.72, 1.0, crop_growth)
	for i in _all_plots.size():
		var scale := Vector3(spread, height, spread) if i < fields.size() \
				else Vector3.ZERO
		_field_mm.multimesh.set_instance_transform(i, Transform3D(
				Basis().scaled(scale), _all_plots[i]))


## Show what the building is actually holding.
##
## Every storage asset declares att_stock_0..3 and nothing had ever read them,
## so a full warehouse looked exactly like an empty one. Each slot takes the
## most plentiful resource not already on display, and the pile grows with the
## amount held.
func refresh_stock_display() -> void:
	if _registry == null or under_construction:
		return
	var slots := _stock_positions()
	if slots.is_empty():
		return

	# Rank what is here, most plentiful first.
	var ranked: Array = []
	for res in Config.RES_COUNT:
		if inventory[res] > 0.5 and def.stores_resource(res):
			ranked.append({"res": res, "amount": inventory[res]})
	ranked.sort_custom(func(a, b): return a["amount"] > b["amount"])

	while _stock_slots.size() < slots.size():
		_stock_slots.append(null)
		_stock_shown.append(-1)

	for i in slots.size():
		var res := -1
		var fill := 0.0
		if i < ranked.size():
			res = int(ranked[i]["res"])
			fill = clampf(float(ranked[i]["amount"]) / maxf(capacity() * 0.4,
					1.0), 0.18, 1.0)

		if _stock_shown[i] != res:
			if _stock_slots[i] != null:
				_stock_slots[i].queue_free()
				_stock_slots[i] = null
			_stock_shown[i] = res
			if res >= 0:
				var node := _registry.instantiate(Res.bulk_asset(res), 0)
				if node != null:
					node.position = slots[i]
					add_child(node)
					_stock_slots[i] = node
		var shown := _stock_slots[i]
		if shown != null:
			# Piles grow rather than pop in, so a filling yard is legible.
			var k: float = lerpf(0.55, 1.15, fill)
			shown.scale = Vector3(k, lerpf(0.4, 1.2, fill), k)


func _stock_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 4:
		var key := "att_stock_%d" % i
		if _registry.has_attachment(asset_id, key):
			out.append(_registry.attachment(asset_id, key))
	return out


## Has this workshop everything it needs for one batch?
func can_craft() -> bool:
	if not def.is_workshop():
		return false
	if space_for(def.produces) < Config.CRAFT_BATCH:
		return false
	for res in def.consumes:
		if inventory[res] < float(def.consumes[res]) * Config.CRAFT_BATCH:
			return false
	return true


## Consume the inputs for one batch and return what was produced.
func craft() -> float:
	if not can_craft():
		return 0.0
	for res in def.consumes:
		inventory[res] -= float(def.consumes[res]) * Config.CRAFT_BATCH
	var made: float = Config.CRAFT_BATCH
	inventory[def.produces] += made
	return made


func all_plots() -> Array[Vector3]:
	return _all_plots


func field_count() -> int:
	return fields.size()
