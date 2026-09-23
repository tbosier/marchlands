class_name Building
extends Node3D

## A placed structure: its inventory, its workers, and its construction state.
##
## Construction is physical (design doc 6.3): a blueprint is placed, materials
## are hauled to the site, and only then do builders raise it. The visual mesh
## grows out of the ground as construction progresses, so a settlement under
## construction reads at a glance.

signal construction_finished(building: Building)

const MARKET_STOCK_TARGETS := [40, 80, 120]
const MARKET_SERVICE_RADIUS := 80.0
const SUPPLY_RELAY_RANGE := 160.0

## How far a blaze reaches, in metres of clear ground between two footprints.
## Placement allows neighbours as close as 1 m apart (Simulation.can_place pads
## only the building being placed, by CLEARANCE), so this covers a packed row
## and a narrow lane and stops short of anything that reads as a street.
const FIRE_SPREAD_REACH := 10.0
## Fire an exposed building gains per second per unit of exposure, set against
## the 0.01/s `tick_fire` takes back off. A firepot leaves fire 0.55, so that
## building can hold a neighbour's blaze up out to about 5.7 m of clear ground;
## past that the neighbour loses more each second than it gains and never gets
## going, whatever the reach above allows. That is the distance the ask was
## really about: houses built together, not houses across a lane.
const FIRE_SPREAD_RATE := 0.10
## The most exposure one building can take on at once, whatever is burning
## around it: a roof has its own rate of catching, and being ringed by six fires
## does not set it alight six times as fast. Fire feeds back — a neighbour that
## catches starts lighting its neighbours — so without a ceiling the feedback is
## superlinear in how many buildings are in range, and an uncapped nine-house
## quarter went from one firepot to every roof at full blaze in about ten
## seconds, which no bucket chain can answer.
##
## 0.20 is the whole answerability budget, and it was chosen by running packed
## layouts rather than by eye. It holds the worst case at +0.01/s net however
## many neighbours are alight, which gives a building taking maximum exposure
## from cold about ninety seconds before `tick_fire` has destroyed it. Measured
## at the tightest packing can_place allows, one firepot into a four-house row:
## ignored, the row is lost entirely; answered by two carriers on a
## forty-second round trip, two of the four survive; answered by a carrier sent
## to each fire, all four survive at about half condition. A nine-house block
## needs the player to answer every fire -- two carriers do not hold it — but
## answering does save it.
##
## Every one of those answered figures is an UPPER BOUND, not a prediction. The
## carriers in them are `regressions.gd::_buckets`, which empties the two worst
## fires in the settlement every forty seconds; a real WaterSystem carrier holds
## one target for the life of its job, draws a bucket only as deep as the well
## it walked to, and goes home when it is hungry. The real response is weaker
## than every number above, by an amount this cap has never been measured
## against -- see that function for the three ways it differs. What the figures
## do support is the ordering: ignored is worse than answered, and answering
## every fire is better than answering two.
##
## Raise this and each of those falls a step: the row stops surviving two
## carriers and the block stops being saveable at all.
const FIRE_SPREAD_EXPOSURE_CAP := 0.20
## What a blaze loses per second to nothing in particular — a roof falling in,
## a thatch that has already burned. Named because the spread threshold above is
## only meaningful against it.
const FIRE_DECAY := 0.01

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
## Capacity promised to gathering/harvesting jobs, including loads on their
## way back. Transient like incoming: rebuilt from jobs, never saved as stock.
var production_reserved := 0.0

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
## Desired food on the market's counters, including deliveries on the road.
## Lowering the target never destroys food or cancels a load already carried.
var market_stock_target := 80
var health := 200.0
var fire := 0.0

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
## True while the frost is on this ground: nothing standing in the field comes
## on any further, whoever asks.
##
## Deliberately *not* saved. It is a pure function of the calendar, and
## `Production` re-derives it from the simulation's day counter — which is
## saved — on the first tick after a load. Persisting it would have meant a new
## save field, and `save_validation.gd` rejects a version mismatch outright
## with no migration path, so every existing file would have stopped loading.
var dormant := false

## How far this farm's ground has been broken for the coming spring, 0..1.
##
## Winter work has to be remembered between the day it is done and the morning
## it pays off, and it deliberately does NOT ride on `crop_growth`. That was
## tried first and it cannot be made to work: `Production._turn_the_year` runs
## `lose_standing_crop()` over every farm on the first tick after a load, so a
## march saved in a hard winter would have come back with the whole winter's
## ploughing destroyed. The sweep cannot be taught to spare it either — it has
## no way to tell broken ground from a crop that dodged the frost by being sown
## a day late, because `dormant` is not saved and every farm comes back awake.
##
## Restored by `apply_state` with a default of zero, so a file written before
## winter work existed loads as unbroken ground and nothing has to migrate.
##
## Written by `SaveGame._capture_building`. `Production._turn_the_year`'s
## start-of-winter reset is gated on `first_turn` so that a winter save keeps
## the ploughing it carried; spring sowing clears it, so a spring save never
## carries any to sow twice.
var tilth := 0.0

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
var _damage_stage := -1
var _damage_material: StandardMaterial3D
var _fire_visual: Node3D
var _fire_time := 0.0


func setup(building_id: int, definition: BuildingDefs.Def,
		   registry: AssetRegistry, variant: String = "") -> void:
	id = building_id
	def = definition
	type_id = def.type_id
	health = max_health()
	asset_id = variant if variant != "" else def.asset
	footprint = registry.footprint(asset_id)
	_apply_height_floor(registry)

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


## Measure the finished building, not just the mesh the generator produced.
##
## `_height` sizes the box the player clicks, and several types wear
## fittings added after the registry measured them: market stalls on a food
## depot, a palisade on a fort, a banner on a barracks. The stockpile and
## camp meshes those share are short, so without a floor the upper part of
## the building the player can see is not part of the building they can hit.
##
## Placement and upgrading both come through here, and used to repeat this
## floor and its list of type ids line for line.
func _apply_height_floor(registry: AssetRegistry) -> void:
	_height = registry.height(asset_id)
	if def.is_food_depot():
		_height = maxf(_height, 3.6)
	_height = maxf(_height, def.min_height)


func _build_visual(registry: AssetRegistry) -> void:
	_visual = registry.instantiate_with_lods(asset_id)
	add_child(_visual)
	if def.is_food_depot():
		_add_market_stalls(_visual)
	if type_id == "fort":
		_add_palisade(_visual)
	if type_id == "barracks":
		_add_military_banner(_visual)
	if def.is_ranch():
		_add_ranch_fittings(_visual)

	if under_construction:
		# Two visuals while building: a translucent ghost of the finished
		# structure, so the player can see what is coming and how it sits on
		# the site, and the real building rising inside it as work proceeds.
		_blueprint = registry.instantiate(asset_id, 1)
		_blueprint.name = "blueprint"
		add_child(_blueprint)
		if def.is_food_depot():
			_add_market_stalls(_blueprint)
		if type_id == "fort":
			_add_palisade(_blueprint)
		if type_id == "barracks":
			_add_military_banner(_blueprint)
		if def.is_ranch():
			_add_ranch_fittings(_blueprint)
		_set_material_on(_blueprint, _blueprint_material())
		_add_site_pad()

	_apply_construction_visual()

	if registry.has_attachment(asset_id, "att_smoke"):
		_add_smoke(registry.attachment(asset_id, "att_smoke"))


## A pair of counters and striped awnings give the market its own silhouette
## while sharing the existing goods-yard footprint and loading attachments.
func _add_ranch_fittings(parent: Node3D) -> void:
	var fittings := Node3D.new()
	fittings.name = "ranch_fittings"
	parent.add_child(fittings)
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color(0.38, 0.23, 0.10)
	for x in [-3.0, 3.0]:
		for z in [-2.5, 0.0, 2.5]:
			_market_box(fittings, Vector3(0.18, 1.4, 0.18), Vector3(x, 0.7, z), timber)
		for y in [0.5, 1.05]:
			_market_box(fittings, Vector3(0.12, 0.14, 5.0), Vector3(x, y, 0), timber)
	_market_box(fittings, Vector3(2.6, 0.45, 0.75), Vector3(0, 0.4, 2.4), timber)
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.25, 0.46, 0.49)
	_market_box(fittings, Vector3(2.35, 0.05, 0.52), Vector3(0, 0.65, 2.4), water)


func _add_market_stalls(parent: Node3D) -> void:
	var stalls := Node3D.new()
	stalls.name = "market_stalls"
	parent.add_child(stalls)
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color(0.32, 0.20, 0.10)
	timber.roughness = 0.95
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.72, 0.23, 0.12)
	cloth.roughness = 0.9
	var linen := StandardMaterial3D.new()
	linen.albedo_color = Color(0.90, 0.78, 0.53)
	linen.roughness = 0.95
	for z in [-1.8, 1.8]:
		_market_box(stalls, Vector3(5.8, 0.20, 1.15), Vector3(0, 1.05, z), timber)
		for x in [-2.8, 2.8]:
			for dz in [-0.85, 0.85]:
				_market_box(stalls, Vector3(0.16, 3.25, 0.16),
						Vector3(x, 1.625, z + dz), timber)
		for strip in 6:
			var awning := _market_box(stalls, Vector3(1.02, 0.10, 2.1),
					Vector3(float(strip) - 2.5, 3.25, z), cloth if strip % 2 == 0 else linen)
			awning.rotation.x = -0.12
			_market_box(stalls, Vector3(1.02, 0.27, 0.08),
					Vector3(float(strip) - 2.5, 3.12, z + 1.04), cloth if strip % 2 == 0 else linen)


func _market_box(parent: Node3D, size: Vector3, at: Vector3,
		material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	parent.add_child(node)
	return node


func set_market_stock_target(target: int) -> bool:
	if not def.is_market() or not MARKET_STOCK_TARGETS.has(target):
		return false
	market_stock_target = target
	return true


func food_stock_target() -> int:
	if type_id == "supply_hut":
		return 60
	if type_id == "fort":
		return 120
	return market_stock_target if def.is_market() else 0


## Damage this building takes before it is destroyed.
##
## The figure belongs to the definition, not to this class: save validation
## has to check a saved health against its type's ceiling with no Building
## to ask, and it used to restate this table inline. Lower one copy and not
## the other and every saved building already above the new ceiling is
## refused as "invalid building damage", which no migration can undo.
func max_health() -> float:
	return def.max_health


func apply_damage(amount: float, incendiary: float = 0.0) -> bool:
	if not is_finite(amount) or not is_finite(incendiary):
		return health <= 0.0
	health = maxf(0.0, health - maxf(0.0, amount))
	fire = clampf(fire + maxf(0.0, incendiary), 0.0, 1.0)
	_refresh_damage_visual()
	return health <= 0.0


## Fire is physical damage over game seconds. The owner removes a destroyed
## building through its normal lifecycle so jobs and navigation stay valid.
func tick_fire(delta: float) -> bool:
	if delta <= 0.0 or not is_finite(delta):
		return health <= 0.0
	if fire > 0.0:
		health = maxf(0.0, health - fire * max_health() * 0.025 * delta)
		fire = maxf(0.0, fire - delta * FIRE_DECAY)
		_fire_time += delta
	_refresh_damage_visual()
	return health <= 0.0


# --- Fire spread ------------------------------------------------------------

## The clear ground between two buildings, measured footprint to footprint
## rather than centre to centre; overlapping footprints return 0.
##
## Centres say nothing about whether two walls are close enough for one thatch
## to light the other: a grain warehouse and a cottage 13.2 m apart already
## touch, while two cottages at that distance have 2.8 m of lane between them.
## The footprints are the world-axis ones from `plan_footprint`, the same ground
## `can_place` and `NavGrid` treat as occupied; at 45° that is the box around
## the building, which only ever makes fire reach further, never shorter.
## Takes both footprints so the spread scan, which already holds them, keeps
## trigonometry out of its innermost loop.
static func footprint_gap_between(a: Vector3, a_plan: Vector2,
		b: Vector3, b_plan: Vector2) -> float:
	var dx: float = absf(a.x - b.x) - (a_plan.x + b_plan.x) * 0.5
	var dz: float = absf(a.z - b.z) - (a_plan.y + b_plan.y) * 0.5
	return Vector2(maxf(0.0, dx), maxf(0.0, dz)).length()


## What this building's blaze does to something standing `gap` metres clear of
## it: proportional to how hard this one is burning, and falling away with the
## square of the reach left. Squared rather than linear because the owner's ask
## was about houses "built together" — at 2 m a neighbour takes 64% of the full
## exposure and at 8 m only 4%, which is the difference between a packed row and
## the far side of a lane.
func fire_exposure_at(gap: float) -> float:
	if fire <= 0.0 or gap >= FIRE_SPREAD_REACH or not is_finite(gap):
		return 0.0
	var near: float = 1.0 - maxf(0.0, gap) / FIRE_SPREAD_REACH
	return fire * near * near


## Take on heat from the fires around this building over `delta` seconds.
## Returns true on the scan it catches, so the caller can warn the player once
## instead of every scan.
##
## Everything standing is flammable, building sites included: an unroofed frame
## with the week's timber stacked against it is the most combustible thing in a
## settlement. Exempting sites was tried and abandoned. It hands the player a
## firebreak — ring a street in blueprints and never finish them — and worse,
## `begin_upgrade` puts a finished, stocked, occupied building back into
## `under_construction` with an empty `delivered`, so the exemption quietly made
## every building fireproof for as long as its upgrade waited on materials.
##
## What counts as catching is "was completely out, and is now taking on more
## heat per second than it sheds". Both halves matter. A threshold on intensity
## cannot be used: a fire climbing slowly across one straddles it — up on the
## scan's gain, back under on the decay between — and warns over and over,
## while a slightly different frame rate steps clean across it and never warns
## at all. `tick_fire` clamps `fire` to exactly 0.0 whenever a building sheds
## more than it takes, so "exactly 0.0" is an honest latch that needs nothing
## saved, and the rate test stops the trickle a far-off blaze leaves on a roof
## it could never light from being reported as a fire.
func take_fire_exposure(exposure: float, delta: float) -> bool:
	if delta <= 0.0 or exposure <= 0.0 or not is_finite(exposure) or not is_finite(delta):
		return false
	var gain := FIRE_SPREAD_RATE * minf(exposure, FIRE_SPREAD_EXPOSURE_CAP)
	var caught := fire == 0.0 and gain > FIRE_DECAY
	fire = clampf(fire + gain * delta, 0.0, 1.0)
	_refresh_damage_visual()
	return caught


func _add_palisade(parent: Node3D) -> void:
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color(0.24, 0.17, 0.11)
	for side in [-1.0, 1.0]:
		for step in 12:
			var along := -3.7 + float(step) * 0.67
			_market_box(parent, Vector3(0.44, 3.5, 0.44), Vector3(side * 3.7, 1.75, along), timber)
			if side > 0.0 or absf(along) > 1.4:
				_market_box(parent, Vector3(0.44, 3.5, 0.44), Vector3(along, 1.75, side * 3.7), timber)
	_add_military_banner(parent)


func _add_military_banner(parent: Node3D) -> void:
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color(0.22, 0.15, 0.10)
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.28, 0.43, 0.62)
	_market_box(parent, Vector3(0.14, 5.0, 0.14), Vector3(-2.8, 2.5, -2.8), timber)
	_market_box(parent, Vector3(1.8, 1.0, 0.06), Vector3(-1.9, 4.3, -2.8), cloth)


func _refresh_damage_visual() -> void:
	if _visual == null:
		return
	var stage := clampi(int((1.0 - health / max_health()) * 5.0), 0, 5)
	if stage != _damage_stage:
		_damage_stage = stage
		if stage > 0 and _damage_material == null:
			_damage_material = StandardMaterial3D.new()
			_damage_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_damage_material.roughness = 1.0
		if _damage_material != null:
			_damage_material.albedo_color = Color(0.07, 0.045, 0.03, float(stage) * 0.14)
			_set_damage_overlay(_visual, _damage_material if stage > 0 else null)
	if fire > 0.0 and _fire_visual == null:
		_fire_visual = Node3D.new()
		_fire_visual.name = "fire"
		add_child(_fire_visual)
		var flame_materials: Array[StandardMaterial3D] = []
		for color in [Color(1.0, 0.16, 0.02, 0.65), Color(1.0, 0.40, 0.04, 0.78),
				Color(1.0, 0.76, 0.18, 0.82)]:
			var flame := StandardMaterial3D.new()
			flame.albedo_color = color
			flame.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			flame.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			flame_materials.append(flame)
		# Small varied clusters sit outside the shell at wall and eave height.
		# A fixed origin ring was hidden inside houses; full-height cones looked
		# like orange stakes instead of tongues of fire.
		var bounds := AABB(Vector3(-footprint.x * 0.5, 0, -footprint.y * 0.5),
				Vector3(footprint.x, _height, footprint.y))
		var mesh := _registry.mesh(asset_id)
		var roof_vertices := PackedVector3Array()
		if mesh != null and not type_id in ["market", "supply_hut", "fort", "barracks"]:
			bounds = mesh.get_aabb()
			for surface in mesh.get_surface_count():
				var material := mesh.surface_get_material(surface)
				if material != null and (material.resource_name == "thatch"
						or material.resource_name.begins_with("roof_")):
					roof_vertices.append_array(mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
		var centre := bounds.get_center()
		var corners: Array[Vector2] = [Vector2(-1, -1), Vector2(1, -1),
				Vector2(1, 1), Vector2(-1, 1)]
		for cluster in 4:
			var anchor := Vector3(centre.x + corners[cluster].x * (bounds.size.x * 0.5 + 0.12),
					0.05, centre.z + corners[cluster].y * bounds.size.z * 0.32)
			if cluster % 2 == 0 and not roof_vertices.is_empty():
				# Yard fences and chimneys enlarge the overall AABB. Anchor an
				# eave fire to a real roof vertex so it cannot float beside it.
				var closest := INF
				var target := anchor
				for vertex in roof_vertices:
					var distance := Vector2(vertex.x - target.x, vertex.z - target.z).length_squared()
					if distance < closest:
						closest = distance
						anchor = vertex + Vector3(corners[cluster].x * 0.05, 0.03, 0)
			for strand in 3:
				var shape := CylinderMesh.new()
				shape.top_radius = 0.0
				shape.bottom_radius = [0.46, 0.33, 0.22][strand]
				shape.height = clampf(_height * 0.22, 1.6, 3.2) * [0.85, 1.2, 0.65][strand]
				shape.radial_segments = 5
				shape.material = flame_materials[strand]
				var tongue := MeshInstance3D.new()
				tongue.mesh = shape
				tongue.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				tongue.position = anchor + Vector3(corners[cluster].x * strand * 0.08, 0, (strand - 1) * 0.28)
				tongue.set_meta("base_y", anchor.y)
				_fire_visual.add_child(tongue)
	if _fire_visual != null:
		_fire_visual.visible = fire > 0.0
		for i in _fire_visual.get_child_count():
			var tongue := _fire_visual.get_child(i) as MeshInstance3D
			var flicker := 0.80 + sin(_fire_time * 11.0 + float(i) * 1.9) * 0.20
			tongue.scale = Vector3.ONE * maxf(0.15, fire) * flicker
			tongue.scale.y *= 1.0 + sin(_fire_time * 7.0 + float(i) * 2.7) * 0.22
			# Scaling around the centre must not lift small flames off the ground.
			tongue.position.y = tongue.mesh.height * tongue.scale.y * 0.5 + float(tongue.get_meta("base_y"))


func _set_damage_overlay(node: Node, material: Material) -> void:
	if node is GeometryInstance3D:
		node.material_overlay = material
	for child in node.get_children():
		_set_damage_overlay(child, material)


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
	var condition := health / max_health()
	def = next
	type_id = next.type_id
	health = max_health() * condition
	asset_id = next.asset
	footprint = registry.footprint(asset_id)
	_apply_height_floor(registry)

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
	_damage_stage = -1
	_refresh_damage_visual()
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
	# Absent from every file written before winter work existed. The default is
	# the honest one — a march whose file says nothing of ploughing has not
	# ploughed.
	tilth = float(entry.get("tilth", 0.0))
	larder = float(entry.get("larder", 0.0))
	market_stock_target = int(entry.get("market_stock_target", 80))
	health = float(entry.get("health", max_health()))
	fire = float(entry.get("fire", 0.0))
	_refresh_damage_visual()

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

func total_stored() -> float:
	var total := 0.0
	for v in inventory:
		total += v
	return total


func space_for(res: int) -> float:
	if not stores(res):
		return 0.0
	var used := total_stored() + production_reserved
	for v in incoming:
		used += v
	return maxf(0.0, capacity() - used)


## Unreserved deposits cannot occupy room promised to another delivery or
## harvest. A job releases its own capacity claim immediately before adding.
func add(res: int, amount: float) -> float:
	var room := space_for(res)
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
	var origin := nav.world_to_cell(global_position)
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
func adopt_plots(plots: Array, _hm: Heightmap, nav: NavGrid,
				 registry: AssetRegistry) -> void:
	if not def.is_farm():
		return
	# Whichever ground the generated layout had claimed goes back to being
	# ordinary grass; Simulation._protect_fields then marks the plots this farm
	# is actually working, which is the one place that decides it.
	for p in _all_plots:
		var old := nav.world_to_cell(p)
		nav.set_cultivated(old.x, old.y, false)

	_all_plots.clear()
	for p in plots:
		var world_p: Vector3 = p
		# Keep the saved elevation, including plots whose surrounding terrain
		# was edited after the farm laid them out.
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
	if def.plots_per_worker <= 0:
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
	var target := clampf(t, 0.0, 1.0)
	# The frost is enforced in the setter rather than at the one caller that
	# advances growth, because that caller is not the only one: a farm sows
	# FARM_INITIAL_GROWTH the moment its plots are laid out, and a farm raised
	# in the middle of winter has no business standing in half-ripe wheat.
	# Decreases always go through — that is harvesting, and the frost itself.
	#
	# Two consequences worth knowing before marking anything else dormant. A
	# farm whose plots are laid out during a winter has its opening sowing
	# refused here and stands as bare earth until spring: correct, but the
	# player is told nothing about why that field is a week behind. And the
	# refusal is silent, so any caller that assumed its value took simply would
	# not have. Nothing outside `Simulation.buildings` is ever marked dormant
	# today — the rival town's farms are held by `frontier_campaign.gd`, are
	# never swept, and set their own growth — so no such caller exists yet.
	if dormant and target > crop_growth:
		target = crop_growth
	crop_growth = target
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
	if def.is_food_depot():
		# The physical grain pile sits on the front counter beneath the awning.
		out.append(Vector3(-1.5, 1.18, -1.8))
		return out
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


## What the crop still in the ground is worth, in food, if every load of it
## were carried in.
##
## Not one load times the trip count. A field is worth FARM_HARVEST_TRIPS loads
## at full growth, each load takes 1/FARM_HARVEST_TRIPS of the growth away with
## it (see `Simulation._tick_harvest`), and `Config.harvest_load` sizes a load
## by the growth *remaining* — so the yield is the sum of a shrinking series.
## Naively multiplying overstated a ripe field by about a third, which is a
## poor number to be putting in front of a player who has just lost it.
##
## What it is NOT: a prediction of what this particular march would have got
## in. Harvest jobs stop being posted below FARM_HARVEST_AT (see
## `Production._post_gathering`), so the tail of the series is only reachable
## because the field goes on growing back above that floor while it is being
## worked. Under the frost it does not, so a settlement that had left the whole
## field standing could never have carried all of this in during the days it
## had left. This is the yield in the ground, not the yield in the cart.
## Measured against the ground, not the staffing. `fields` is the subset of
## plots somebody is working, and gating on it valued a fully ripe field at
## nothing the moment its hands were drafted away — while the yield a harvester
## actually lifts depends on `crop_growth` alone (`Simulation._tick_harvest`
## takes `harvest_load(farm.crop_growth)` and never looks at the plot count).
## So an unstaffed field is worth exactly what a staffed one is worth, and
## reporting zero for it understated the frost by a whole harvest.
func standing_crop_food() -> float:
	if _all_plots.is_empty() or crop_growth <= 0.0:
		return 0.0
	var total := 0.0
	var remaining := crop_growth
	var step := 1.0 / float(Config.FARM_HARVEST_TRIPS)
	# Bounded rather than `while remaining > 0` so no rounding can spin here,
	# and stopped on half a step rather than on zero: at the current sixteen
	# trips the step is dyadic and the subtraction lands exactly on 0.0, but at
	# ten or twelve it would leave a residue of about 1e-16, which is greater
	# than zero and would buy one more whole load — 7.2 food of rounding error
	# in the figure this exists to report.
	for _i in Config.FARM_HARVEST_TRIPS + 1:
		if remaining <= step * 0.5:
			break
		total += Config.harvest_load(remaining)
		remaining -= step
	return total


## The frost takes the standing crop. Returns what it was worth, because that
## is the number worth saying out loud — "the frost took 180 food" tells a
## player what happened; "crop growth is now zero" does not.
##
## The ground is always cleared, even when the loss is worth nothing to report.
## Those are two different questions and conflating them left the headline rule
## with a free bypass: `standing_crop_food` values only the plots somebody is
## actually working, so a farm whose hands had been drafted away valued its
## ripe field at zero, never had `crop_growth` cleared, and walked a full crop
## through the winter to be harvested the moment the hands came back. Pulling
## the farmhands off in late autumn was a complete answer to the frost.
##
## It also made saving and loading destructive: the workforce is rebuilt on
## load, so the reloaded farm had its plots back, the first sweep after the
## load now valued the crop at a full field, and resuming a saved march cost
## the player a harvest that quitting had preserved.
func lose_standing_crop() -> float:
	if crop_growth <= 0.0:
		return 0.0
	var lost := standing_crop_food()
	set_crop_growth(0.0)
	return lost


## Break a little more of this farm's ground for the spring. Returns what was
## actually gained, which is zero once the field is fully prepared.
##
## A separate quantity from `crop_growth`, not a back door into it. That setter
## refuses every increase while the field is dormant — the rule that keeps a
## farm raised in January from standing in half-ripe wheat — and this does not
## go near it. Nothing grows in a frozen field. The ground is simply readier
## than it was, and it stays readier until something sows it.
func break_ground(step: float) -> float:
	if not def.is_farm() or _all_plots.is_empty():
		return 0.0
	var target := clampf(tilth + maxf(0.0, step), 0.0, 1.0)
	# `TILLAGE_STEP` summed 120 times lands a hair under 1.0, which would post
	# a 121st spell for ground that is already finished.
	if is_equal_approx(target, 1.0):
		target = 1.0
	var gained := target - tilth
	tilth = target
	return gained


## Sow ground broken over the winter, and return the growth it was worth.
##
## Called once, on the tick the year turns into spring, after the field has
## been woken — `set_crop_growth` would refuse this while `dormant` still
## stood, and refuse it silently.
##
## The sowing is capped at what a newly founded farm lays down, and that cap is
## below `Config.FARM_HARVEST_AT` on purpose. A field that came through the
## winter prepared is *ready*, not *ripe*: `Production._post_gathering` will not
## post a reaper for it until it has grown, so no amount of winter labour can
## put a single grain in a granary on the first morning of spring. That is what
## keeps this from being a way to buy back the crop the frost took.
##
## It only ever raises the crop. A mild winter leaves the standing field alone,
## and can leave it standing at more than a sowing is worth; ploughing that
## back in would have made winter work actively destructive in the one year it
## is easiest to do.
func sow_prepared_ground() -> float:
	if not def.is_farm() or tilth <= 0.0:
		tilth = 0.0
		return 0.0
	var sown := Config.TILLAGE_SOWING * tilth
	tilth = 0.0
	if sown <= crop_growth:
		return 0.0
	set_crop_growth(sown)
	return sown


func all_plots() -> Array[Vector3]:
	return _all_plots


func field_count() -> int:
	return fields.size()
