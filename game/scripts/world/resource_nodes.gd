class_name ResourceNodes
extends Node3D

## Trees, stone outcrops and iron deposits — the harvestable world.
##
## Visuals go through MultiMeshInstance3D (hundreds of trees, a handful of draw
## calls) while the logical state lives in plain arrays. Felling a tree scales
## its instance to zero rather than rebuilding the buffer, so harvesting stays
## cheap even with a forest on screen.

## Raised whenever a node's depletion changes, in either direction. The ground
## under a worked-out outcrop becomes walkable, and the pathfinder is the only
## thing that needs telling.
signal depletion_changed(rec)

enum Kind { TREE, STONE, IRON }

class NodeRec:
	var id: int
	var kind: int
	var asset_id: String
	var position: Vector3
	var amount: float
	var max_amount: float
	var reserved_by: int = -1
	var mm_index: int = -1
	var mm_key: String = ""
	var basis: Basis
	var depleted: bool = false
	var regrow_at: float = -1.0
	## Seconds left in the topple animation, or -1 when standing.
	var falling: float = -1.0
	var fall_yaw: float = 0.0


var records: Array[NodeRec] = []
var _pick_tiles: Dictionary = {}
var _by_cell: Dictionary = {}        # Vector2i -> Array[int]
## asset_id -> [near MultiMeshInstance3D, far MultiMeshInstance3D]. Vegetation
## cannot vary LOD per instance inside one MultiMesh, so each scatter is drawn
## twice: a detailed copy for the near band and a cheap one beyond it, each
## culled to its own distance range.
var _multimeshes: Dictionary = {}
## Tile key -> the world position its MultiMeshInstance3D nodes sit at.
var _mm_origin: Dictionary = {}
var _pick_bounds: Dictionary = {}    # asset_id -> local AABB
## Keep the visible transforms on the CPU too: the headless renderer has no
## MultiMesh buffer to read back, and GPU readbacks are unnecessary for hover.
var _visual_transforms: Dictionary = {}   # node id -> world Transform3D
var _pick_world_bounds: Dictionary = {}  # node id -> broad-phase AABB

## Edge length of a scatter tile, in metres. Small enough that the near and far
## copies of a tile are a meaningful distance apart, large enough that the map
## is not paved with draw calls.
const SCATTER_TILE := 96.0
var _rng := RandomNumberGenerator.new()
var _hm: Heightmap

## Trees the player has ordered cleared, shown with a marker so the order is
## visible before anyone has walked over to carry it out.
var _marker_mm: MultiMeshInstance3D
var _marked: Array[int] = []
var _falling: Array[int] = []

## How long a tree takes to go over.
const FALL_TIME := 1.1

const TREE_TIMBER := 26.0
const STONE_YIELD := 140.0
const IRON_YIELD := 120.0
const TREE_REGROW_DAYS := 9.0


func generate(hm: Heightmap, registry: AssetRegistry, seed_value: int) -> void:
	_hm = hm
	_rng.seed = seed_value + 555

	var plan := {
		"oak_tree_01": [], "oak_tree_02": [], "pine_tree_01": [],
		"stone_node_01": [], "iron_node_01": [],
	}

	_plan_forest(plan)
	_plan_minerals(plan)
	if _hm.generation_version >= 2:
		_plan_start_resources(plan)

	for asset_id in plan.keys():
		var entries: Array = plan[asset_id]
		if entries.is_empty():
			continue
		_build_multimesh(asset_id, entries, registry)

	_index_cells()


func _plan_forest(plan: Dictionary) -> void:
	if _hm.generation_version >= 2:
		_plan_regional_forest(plan)
		return
	## Trees cluster in the woodland the heightmap classified, thinning at the
	## edges so the forest has a soft, natural boundary.
	var attempts := 5200
	for _i in attempts:
		var x := _rng.randf() * _hm.world_size
		var z := _rng.randf() * _hm.world_size
		var c := _world_to_cell(Vector3(x, 0, z))
		var surf := _hm.cell_surface(c.x, c.y)
		var density := 0.0
		if surf == Heightmap.Surface.FOREST:
			density = 0.85
		elif surf == Heightmap.Surface.GRASS:
			density = 0.07
		if _rng.randf() > density:
			continue
		if _hm.cell_slope(c.x, c.y) > 0.55:
			continue
		var h := _hm.height_at(x, z)
		if h < Config.SEA_LEVEL + 0.8:
			continue

		var asset_id := "oak_tree_01"
		var roll := _rng.randf()
		if h > 19.0:
			asset_id = "pine_tree_01" if roll < 0.72 else "oak_tree_02"
		elif roll < 0.18:
			asset_id = "oak_tree_02"
		elif roll < 0.36:
			asset_id = "pine_tree_01"

		plan[asset_id].append({
			"position": Vector3(x, h, z),
			"scale": _rng.randf_range(0.82, 1.22),
			"yaw": _rng.randf() * TAU,
			"kind": Kind.TREE,
			"amount": TREE_TIMBER,
		})


func _plan_minerals(plan: Dictionary) -> void:
	## Stone favours the high northern ground; iron sits in the north-west,
	## following the design doc's starting scenario.
	var regional_scale := maxi(1, roundi(_hm.world_size / Config.WORLD_SIZE))
	var stone_clusters := 14 * regional_scale
	var iron_clusters := 6 * regional_scale

	for _c in stone_clusters:
		var cx := _rng.randf_range(0.12, 0.88) * _hm.world_size
		var cz := _rng.randf_range(0.05, 0.55) * _hm.world_size
		for _k in _rng.randi_range(3, 7):
			var x := cx + _rng.randf_range(-22.0, 22.0)
			var z := cz + _rng.randf_range(-22.0, 22.0)
			if not _valid_mineral_site(x, z, 12.0):
				continue
			plan["stone_node_01"].append({
				"position": Vector3(x, _hm.height_at(x, z), z),
				"scale": _rng.randf_range(0.85, 1.3),
				"yaw": _rng.randf() * TAU,
				"kind": Kind.STONE,
				"amount": STONE_YIELD,
			})

	for _c in iron_clusters:
		var cx := _rng.randf_range(0.05, 0.42) * _hm.world_size
		var cz := _rng.randf_range(0.05, 0.42) * _hm.world_size
		for _k in _rng.randi_range(2, 4):
			var x := cx + _rng.randf_range(-16.0, 16.0)
			var z := cz + _rng.randf_range(-16.0, 16.0)
			if not _valid_mineral_site(x, z, 14.0):
				continue
			plan["iron_node_01"].append({
				"position": Vector3(x, _hm.height_at(x, z), z),
				"scale": _rng.randf_range(0.9, 1.2),
				"yaw": _rng.randf() * TAU,
				"kind": Kind.IRON,
				"amount": IRON_YIELD,
			})


func _valid_mineral_site(x: float, z: float, min_height: float) -> bool:
	if x < 8.0 or z < 8.0 or x > _hm.world_size - 8.0 \
			or z > _hm.world_size - 8.0:
		return false
	var h := _hm.height_at(x, z)
	if h < min_height:
		return false
	var c := _world_to_cell(Vector3(x, 0, z))
	return _hm.cell_surface(c.x, c.y) != Heightmap.Surface.WATER


## Build the scatter for one asset, as one near/far pair *per tile*.
##
## A MultiMesh is one object to the renderer: it has a single transform and a
## single bounding box, and a visibility range applies to the whole of it. One
## MultiMesh holding every oak in the world therefore cannot show near trees at
## full detail and far ones reduced — it switches the entire forest at once on
## the distance to a single point, which is both wrong and invisible enough to
## look plausible. Splitting the scatter into tiles gives the renderer
## something it can genuinely choose between, and gives frustum culling
## something smaller than the world to reject.
func _build_multimesh(asset_id: String, entries: Array,
					  registry: AssetRegistry) -> void:
	var near_mesh := registry.mesh(asset_id, 0)
	if near_mesh == null:
		push_warning("ResourceNodes: no mesh for %s" % asset_id)
		return
	# lod1, not lod2: a tree is already only a couple of hundred triangles, and
	# decimating a conifer to fifteen percent leaves a shard rather than a
	# smaller tree. The saving that matters here is the shadow pass, which the
	# far instance skips entirely.
	var far_mesh := registry.mesh(asset_id, 1)
	if far_mesh == null:
		far_mesh = near_mesh
	_pick_bounds[asset_id] = near_mesh.get_aabb()
	if asset_id == "iron_node_01":
		near_mesh = _iron_mesh(near_mesh)
		far_mesh = _iron_mesh(far_mesh)

	# Group by tile first, so each MultiMesh is built once at its final size.
	var by_tile: Dictionary = {}
	for e in entries:
		var p: Vector3 = e["position"]
		var tile := Vector2i(int(p.x / SCATTER_TILE), int(p.z / SCATTER_TILE))
		if not by_tile.has(tile):
			by_tile[tile] = []
		by_tile[tile].append(e)

	for tile in by_tile:
		var tile_entries: Array = by_tile[tile]
		var key := "%s#%d_%d" % [asset_id, tile.x, tile.y]
		var origin := Vector3((tile.x + 0.5) * SCATTER_TILE, 0.0,
				(tile.y + 0.5) * SCATTER_TILE)
		_mm_origin[key] = origin

		var instances: Array[MultiMeshInstance3D] = []
		for pass_index in 2:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = near_mesh if pass_index == 0 else far_mesh
			mm.instance_count = tile_entries.size()

			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_%s" % [key, "near" if pass_index == 0 else "far"]
			mmi.multimesh = mm
			# The node sits at the tile's centre and its instances are placed
			# relative to it, so the distance the visibility range is measured
			# against is the distance to this patch of forest.
			mmi.position = origin
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			add_child(mmi)
			instances.append(mmi)

		LOD.apply_to_multimesh(instances[0], instances[1])
		if _hm != null and _hm.world_size > Config.WORLD_SIZE:
			instances[1].visibility_range_end = 1000.0
		_multimeshes[key] = instances

		for i in tile_entries.size():
			var e: Dictionary = tile_entries[i]
			var rec := NodeRec.new()
			rec.id = records.size()
			rec.kind = e["kind"]
			rec.asset_id = asset_id
			rec.position = e["position"]
			rec.amount = e["amount"]
			rec.max_amount = e["amount"]
			rec.mm_index = i
			rec.mm_key = key
			rec.basis = Basis(Vector3.UP, e["yaw"]).scaled(
					Vector3.ONE * e["scale"])
			records.append(rec)
			_write_transform(rec, Transform3D(rec.basis, rec.position))


## Keep the authored oxidized seams, but give ore a dark metallic host rock.
## Copy only this asset's materials so ordinary stone and buildings stay stone.
func _iron_mesh(source: Mesh) -> Mesh:
	var styled := source.duplicate() as ArrayMesh
	if styled == null:
		return source
	for surface in styled.get_surface_count():
		var original := source.surface_get_material(surface)
		var rust := original != null and original.resource_name == "brick_red"
		var material := StandardMaterial3D.new()
		material.resource_name = "ore_oxide" if rust else "ore_metal"
		material.albedo_color = Color(0.72, 0.30, 0.10) if rust else Color(0.19, 0.23, 0.25)
		material.metallic = 0.12 if rust else 0.68
		material.roughness = 0.78 if rust else 0.38
		styled.surface_set_material(surface, material)
	return styled


## Clear everything inside a radius, as though the site had been cleared before
## the first hall was raised. Without it the opening settlement is threaded
## with trees standing inside the houses and the stockpile.
func clear_area(centre: Vector3, radius: float) -> int:
	var removed := 0
	var r2 := radius * radius
	for rec in records:
		if rec.depleted:
			continue
		if rec.position.distance_squared_to(centre) > r2:
			continue
		rec.amount = 0.0
		rec.regrow_at = -1.0
		_set_depleted(rec, true)
		set_marked(rec, false)
		removed += 1
	return removed


func _index_cells() -> void:
	_by_cell.clear()
	_pick_tiles.clear()
	for rec in records:
		var c := _world_to_cell(rec.position)
		if not _by_cell.has(c):
			_by_cell[c] = []
		_by_cell[c].append(rec.id)
		var tile := Vector2i(floori(rec.position.x / SCATTER_TILE), floori(rec.position.z / SCATTER_TILE))
		var bounds: AABB = _pick_world_bounds.get(rec.id, AABB(rec.position, Vector3.ONE))
		if not _pick_tiles.has(tile):
			_pick_tiles[tile] = {"bounds": bounds, "ids": []}
		_pick_tiles[tile].bounds = _pick_tiles[tile].bounds.merge(bounds)
		_pick_tiles[tile].ids.append(rec.id)


# --- Queries ----------------------------------------------------------------

func _write_transform(rec: NodeRec, xform: Transform3D) -> void:
	_visual_transforms[rec.id] = xform
	if _pick_bounds.has(rec.asset_id):
		_pick_world_bounds[rec.id] = xform * (_pick_bounds[rec.asset_id] as AABB)
	# Instance transforms are local to the tile node they belong to.
	var local := xform
	local.origin -= _mm_origin.get(rec.mm_key, Vector3.ZERO) as Vector3
	for mmi in _multimeshes.get(rec.mm_key, []):
		mmi.multimesh.set_instance_transform(rec.mm_index, local)


func get_node_rec(id: int) -> NodeRec:
	if id < 0 or id >= records.size():
		return null
	return records[id]


## Placement tests trunks and the visible extent of deposits. A nearby tree
## crown can overhang a yard; its trunk cannot grow through the building.
func building_obstruction(footprint: Rect2) -> NodeRec:
	for rec in _building_site_nodes(footprint):
		if not rec.depleted:
			return rec
	return null


## Logging leaves regrowth timers. Once that cleared ground becomes a site,
## keep its harvested trees from returning through the completed structure.
func prevent_building_regrowth(footprint: Rect2) -> void:
	for rec in _building_site_nodes(footprint):
		if rec.kind == Kind.TREE and rec.depleted:
			rec.regrow_at = -1.0


func _building_site_nodes(footprint: Rect2) -> Array[NodeRec]:
	var found: Array[NodeRec] = []
	if _pick_tiles.is_empty() and not records.is_empty(): _index_cells()
	for tile in _pick_tiles.values():
		var bounds: AABB = tile.bounds
		if not footprint.intersects(Rect2(bounds.position.x, bounds.position.z,
				bounds.size.x, bounds.size.z)):
			continue
		for id in tile.ids:
			var rec: NodeRec = records[id]
			if rec.kind == Kind.TREE:
				if footprint.has_point(Vector2(rec.position.x, rec.position.z)):
					found.append(rec)
			else:
				var deposit: AABB = _pick_world_bounds.get(rec.id, AABB(rec.position, Vector3.ONE))
				if footprint.intersects(Rect2(deposit.position.x, deposit.position.z,
						deposit.size.x, deposit.size.z)):
					found.append(rec)
	return found


## Pick the nearest live resource through its transformed visual bounds.
## Callers can cap max_distance at a terrain/building hit to respect occlusion.
func pick_ray(origin: Vector3, direction: Vector3,
		max_distance: float = 4000.0) -> NodeRec:
	if direction.is_zero_approx() or max_distance <= 0.0:
		return null
	var ray := direction.normalized()
	var best: NodeRec = null
	var best_distance := max_distance
	var candidates: Array[NodeRec] = []
	if _pick_tiles.is_empty():
		candidates = records
	else:
		for tile in _pick_tiles.values():
			if tile.bounds.intersects_ray(origin, ray) == null:
				continue
			for id in tile.ids:
				candidates.append(records[id])
	for rec in candidates:
		if rec.depleted or rec.falling >= 0.0 or not _pick_bounds.has(rec.asset_id):
			continue
		var transform: Transform3D = _visual_transforms.get(rec.id,
				Transform3D(rec.basis, rec.position))
		var bounds: AABB = _pick_bounds[rec.asset_id]
		var world_bounds: AABB = (_pick_world_bounds[rec.id] if _pick_world_bounds.has(rec.id)
				else transform * bounds)
		if world_bounds.intersects_ray(origin, ray) == null:
			continue
		if is_zero_approx(transform.basis.determinant()):
			continue
		var inverse := transform.affine_inverse()
		var hit: Variant = bounds.intersects_ray(inverse * origin, inverse.basis * ray)
		if hit == null:
			continue
		var distance_to_hit := origin.distance_to(transform * (hit as Vector3))
		if distance_to_hit < best_distance:
			best_distance = distance_to_hit
			best = rec
	return best


## Nearest live, unclaimed node of `kind` within `radius` metres of `from`.
func find_nearest(kind: int, from: Vector3, radius: float,
				  exclude_reserved: bool = true) -> NodeRec:
	var best: NodeRec = null
	var best_d := radius * radius
	var cell_radius := int(ceil(radius / Config.CELL))
	var centre := _world_to_cell(from)
	for dz in range(-cell_radius, cell_radius + 1):
		for dx in range(-cell_radius, cell_radius + 1):
			var c := Vector2i(centre.x + dx, centre.y + dz)
			if not _by_cell.has(c):
				continue
			for id in _by_cell[c]:
				var rec: NodeRec = records[id]
				if rec.depleted or rec.kind != kind:
					continue
				if exclude_reserved and rec.reserved_by >= 0:
					continue
				var d := from.distance_squared_to(rec.position)
				if d < best_d:
					best_d = d
					best = rec
	return best


# --- Harvesting -------------------------------------------------------------

## Take up to `amount` from a node. Returns what was actually taken.
func harvest(rec: NodeRec, amount: float, now_days: float) -> float:
	if rec == null or rec.depleted:
		return 0.0
	var taken: float = minf(amount, rec.amount)
	rec.amount -= taken

	if rec.kind == Kind.TREE:
		# A tree is felled in one go once enough has been cut from it.
		if rec.amount <= 0.001:
			_set_depleted(rec, true)
			rec.regrow_at = now_days + TREE_REGROW_DAYS
		else:
			_set_scale(rec, 1.0)
	else:
		if rec.amount <= 0.001:
			_set_depleted(rec, true)
		else:
			# Outcrops visibly shrink as they are worked out.
			_set_scale(rec, lerpf(0.45, 1.0, rec.amount / rec.max_amount))
	return taken


## Take the whole thing down and do not let it grow back: the player cleared
## this ground on purpose, and a tree returning to a building site would be a
## bug rather than a feature.
func fell(rec: NodeRec, want: float) -> float:
	if rec == null or rec.depleted:
		return 0.0
	var taken: float = minf(want, rec.amount)
	rec.amount -= taken
	if rec.amount <= 0.001:
		# Ground the player cleared on purpose stays clear.
		rec.regrow_at = -1.0
		begin_fall(rec)
		set_marked(rec, false)
	else:
		_set_scale(rec, lerpf(0.5, 1.0, rec.amount / rec.max_amount))
	return taken


## Put timber back that could not be delivered, rather than deleting it.
func restore(rec: NodeRec, amount: float) -> void:
	if rec == null or amount <= 0.0:
		return
	if rec.depleted:
		_set_depleted(rec, false)
	if rec.falling >= 0.0:
		# The trunk emptied, so it was already toppling. Stand it back up:
		# otherwise the topple finishes a second later, depletes the node, and
		# takes the timber we just put back in it with it — which is exactly
		# the case this function exists to prevent, and exactly the state a
		# player is in when they clear ground to recover from full stores.
		rec.falling = -1.0
		_falling.erase(rec.id)
		_write_transform(rec, Transform3D(rec.basis, rec.position))
	rec.amount = minf(rec.max_amount, rec.amount + amount)
	_set_scale(rec, lerpf(0.5, 1.0, rec.amount / rec.max_amount))


## Start a tree toppling instead of blinking it out of existence.
func begin_fall(rec: NodeRec) -> void:
	if rec == null or rec.depleted or rec.falling >= 0.0:
		return
	rec.falling = FALL_TIME
	rec.fall_yaw = _rng.randf() * TAU
	if not _falling.has(rec.id):
		_falling.append(rec.id)


## Advance topple animations. `delta` is in-game seconds.
func tick_falling(delta: float) -> void:
	if _falling.is_empty():
		return
	var still: Array[int] = []
	for id in _falling:
		var rec: NodeRec = records[id]
		rec.falling -= delta
		if rec.falling <= 0.0:
			rec.falling = -1.0
			_set_depleted(rec, true)
			continue
		still.append(id)
		# Rotate about the base, easing in as the trunk gives way.
		var t: float = 1.0 - (rec.falling / FALL_TIME)
		var lean: float = (PI * 0.5) * (t * t)
		var axis := Vector3(cos(rec.fall_yaw), 0.0, sin(rec.fall_yaw))
		var basis := Basis(axis, lean) * rec.basis
		_write_transform(rec, Transform3D(basis, rec.position))
	_falling = still


# --- Felling orders ---------------------------------------------------------

func set_marked(rec: NodeRec, value: bool) -> void:
	if rec == null:
		return
	if value and not _marked.has(rec.id):
		_marked.append(rec.id)
	elif not value:
		_marked.erase(rec.id)
	_refresh_markers()


func _refresh_markers() -> void:
	if _marker_mm == null:
		_marker_mm = _build_marker_layer()
		add_child(_marker_mm)
	var live: Array[int] = []
	for id in _marked:
		var rec: NodeRec = records[id]
		if not rec.depleted and rec.falling < 0.0:
			live.append(id)
	_marked = live

	var mm := _marker_mm.multimesh
	mm.instance_count = _marked.size()
	for i in _marked.size():
		var rec: NodeRec = records[_marked[i]]
		var p := rec.position
		p.y += 5.4 * rec.basis.get_scale().y
		mm.set_instance_transform(i, Transform3D(
				Basis(Vector3.UP, PI * 0.25).scaled(Vector3.ONE * 1.1), p))
	_marker_mm.visible = _marked.size() > 0


func _build_marker_layer() -> MultiMeshInstance3D:
	# A floating chevron. Unshaded and drawn on top, because it is an order the
	# player gave, not a thing in the world.
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.55, 0.55, 0.55)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.95, 0.62, 0.22)
	mat.no_depth_test = true
	mat.render_priority = 2
	mesh.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 0

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "felling_markers"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


func _set_depleted(rec: NodeRec, value: bool) -> void:
	if rec.depleted == value:
		rec.reserved_by = -1
		return
	rec.depleted = value
	rec.reserved_by = -1
	var basis := Basis().scaled(Vector3.ZERO) if value else rec.basis
	_write_transform(rec, Transform3D(basis, rec.position))
	depletion_changed.emit(rec)


func _set_scale(rec: NodeRec, factor: float) -> void:
	_write_transform(rec,
			Transform3D(rec.basis.scaled(Vector3.ONE * factor), rec.position))


# --- Persistence ------------------------------------------------------------

## What the world has had taken out of it.
##
## Only the mutable part is written: the layout, the assets and the per-instance
## rotations all come back from the seed, and a felled forest is described by
## which records are empty rather than by repeating the whole scatter. The
## record order is part of that contract — it is seeded generation, so it is
## the same every time.
func capture() -> Dictionary:
	var changed: Array = []
	for i in records.size():
		var rec := records[i]
		if (is_equal_approx(rec.amount, rec.max_amount) and not rec.depleted
				and rec.regrow_at < 0.0):
			continue
		changed.append({
			"index": i,
			"amount": rec.amount,
			"depleted": rec.depleted,
			"regrow_at": rec.regrow_at,
		})
	return {"count": records.size(), "changed": changed,
			"marked": _marked.duplicate()}


## The trees the player has ordered cleared.
func is_marked(node_id: int) -> bool:
	return _marked.has(node_id)


func marked_ids() -> Array[int]:
	return _marked.duplicate()


func apply_state(data: Dictionary) -> void:
	var count := int(data.get("count", records.size()))
	if count != records.size():
		push_error("world has %d resource nodes, save holds %d — the seed does "
				% [records.size(), count]
				+ "not match; ignoring resource state")
		return

	for entry in data.get("changed", []):
		var rec := records[int(entry["index"])]
		rec.amount = float(entry["amount"])
		rec.regrow_at = float(entry.get("regrow_at", -1.0))
		rec.reserved_by = -1
		rec.falling = -1.0
		# A tree saved between the last axe stroke and the end of its topple is
		# already gone as far as the player is concerned; standing it back up
		# empty is worse than finishing the fall off-screen.
		var gone: bool = (bool(entry.get("depleted", false))
				or (rec.kind == Kind.TREE and rec.amount <= 0.01))
		_set_depleted(rec, gone)

	_marked.clear()
	for id in data.get("marked", []):
		var rec := get_node_rec(int(id))
		if rec != null and not rec.depleted:
			_marked.append(rec.id)
	_refresh_markers()


## Forests grow back, so a woodcutter's camp is a renewable site rather than a
## one-way strip mine.
func tick_regrowth(now_days: float) -> void:
	for rec in records:
		if not rec.depleted or rec.regrow_at < 0.0:
			continue
		if now_days >= rec.regrow_at:
			rec.amount = rec.max_amount
			rec.regrow_at = -1.0
			_set_depleted(rec, false)


## Every starting region has a small workable wood and construction stone;
## larger regional deposits still reward exploring the ridges. Generated after
## the old scatter only in version two, preserving old save resource IDs.
func _plan_start_resources(plan: Dictionary) -> void:
	var centre := Vector2.ONE * (_hm.world_size * 0.5)
	for kind in [Kind.TREE, Kind.STONE, Kind.IRON]:
		var count := 60 if kind == Kind.TREE else (14 if kind == Kind.STONE else 6)
		var anchor := centre + (Vector2(-92, -72) if kind == Kind.TREE else
				(Vector2(-115, 55) if kind == Kind.STONE else Vector2(-140, -100)))
		for i in count:
			var p := anchor + Vector2(_rng.randf_range(-28, 28), _rng.randf_range(-28, 28))
			var cell := _world_to_cell(Vector3(p.x, 0, p.y))
			if not _hm.is_passable(cell.x, cell.y):
				continue
			var asset := "oak_tree_01" if kind == Kind.TREE else (
					"stone_node_01" if kind == Kind.STONE else "iron_node_01")
			plan[asset].append({"position": Vector3(p.x, _hm.height_at(p.x, p.y), p.y),
					"scale": _rng.randf_range(0.85, 1.2), "yaw": _rng.randf() * TAU,
					"kind": kind, "amount": TREE_TIMBER if kind == Kind.TREE else
					(STONE_YIELD if kind == Kind.STONE else IRON_YIELD)})


func _world_to_cell(p: Vector3) -> Vector2i:
	return _hm.world_to_cell(p) if _hm else Config.world_to_cell(p)


func _plan_regional_forest(plan: Dictionary) -> void:
	# Use stands, rather than distributing a thin dusting of trees across a
	# 64-times-larger map. The number of independently culled instances grows
	# with side length, and forest interiors keep believable local density.
	var stands := maxi(10, roundi(_hm.world_size / Config.WORLD_SIZE * 12.0))
	for stand in stands:
		var anchor := Vector2.ZERO
		var found := false
		for attempt in 100:
			anchor = Vector2(_rng.randf_range(40, _hm.world_size - 40),
					_rng.randf_range(40, _hm.world_size - 40))
			var cell := _world_to_cell(Vector3(anchor.x, 0, anchor.y))
			if _hm.cell_surface(cell.x, cell.y) == Heightmap.Surface.FOREST:
				found = true
				break
		if not found:
			continue
		for tree in 100:
			var angle := _rng.randf() * TAU
			var radius := sqrt(_rng.randf()) * 54.0
			var point := anchor + Vector2(cos(angle), sin(angle)) * radius
			if point.x < 4 or point.y < 4 or point.x >= _hm.world_size - 4 or point.y >= _hm.world_size - 4:
				continue
			var cell := _world_to_cell(Vector3(point.x, 0, point.y))
			var ground := _hm.cell_surface(cell.x, cell.y)
			if ground == Heightmap.Surface.WATER or ground == Heightmap.Surface.ROCK or _hm.cell_slope(cell.x, cell.y) > 0.5:
				continue
			if point.distance_to(Vector2.ONE * _hm.world_size * 0.5) < 85:
				continue
			var h := _hm.height_at(point.x, point.y)
			var asset := "pine_tree_01" if h > 18.0 else ("oak_tree_01" if stand % 3 != 0 else "oak_tree_02")
			plan[asset].append({"position": Vector3(point.x, h, point.y),
					"scale": _rng.randf_range(0.82, 1.22), "yaw": _rng.randf() * TAU,
					"kind": Kind.TREE, "amount": TREE_TIMBER})
