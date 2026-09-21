extends "res://tests/navigation.gd"

## Resource stock survives rejected previews and remains real harvested cargo
## when clearing makes a site available. Uses the rendered resource bounds.
func _resource_sites() -> void:
	var nodes := _world.nodes
	for item in [["oak_tree_01", ResourceNodes.Kind.TREE, 200.0, 26.0],
			["stone_node_01", ResourceNodes.Kind.STONE, 280.0, 140.0],
			["iron_node_01", ResourceNodes.Kind.IRON, 360.0, 120.0],
			["oak_tree_02", ResourceNodes.Kind.TREE, 440.0, 26.0]]:
		nodes._build_multimesh(item[0], [{"position": Vector3(item[2], 9, 200),
				"scale": 1.15, "yaw": 0.7, "kind": item[1], "amount": item[3]}], _registry)
	nodes._index_cells()
	var tree: ResourceNodes.NodeRec = nodes.records[0]
	var stone: ResourceNodes.NodeRec = nodes.records[1]
	var iron: ResourceNodes.NodeRec = nodes.records[2]
	var falling_tree: ResourceNodes.NodeRec = nodes.records[3]
	var quantities: Array = []
	for rec in nodes.records: quantities.append(rec.amount)
	for rec in [tree, stone, iron]:
		var result := _sim.can_place("house", rec.position)
		_check(not result.ok and result.reason.contains("trees" if rec.kind == ResourceNodes.Kind.TREE else "deposit"),
				"placement explains the resource that must be cleared: " + result.reason)
	var unchanged := true
	for i in nodes.records.size():
		unchanged = unchanged and nodes.records[i].amount == quantities[i] and not nodes.records[i].depleted
	_check(unchanged and _sim.buildings.is_empty(), "rejected placements do not erase resources or commission buildings")
	var bounds: AABB = nodes._pick_world_bounds[stone.id]
	var edge_site := Vector3(bounds.end.x + _registry.footprint("house_small_01").x * 0.5 - 0.5, 9, stone.position.z)
	_check(not _sim.can_place("house", edge_site).ok,
			"a deposit's visible edge blocks placement even when its centre is outside the building")
	var timber := nodes.harvest(tree, tree.amount, _sim.day)
	_check(timber == 26.0 and tree.regrow_at > _sim.day and _sim.can_place("house", tree.position).ok,
			"harvesting the finite tree stock opens the site")
	var house := _sim.place_building("house", tree.position, 0.0, true)
	nodes.tick_regrowth(_sim.day + ResourceNodes.TREE_REGROW_DAYS + 1.0)
	_check(tree.depleted and tree.regrow_at < 0.0 and house != null and timber == 26.0,
			"a harvested tree cannot regrow through a new building or erase its paid timber")
	var rock := nodes.harvest(stone, stone.amount, _sim.day)
	_check(rock == 140.0 and _sim.can_place("house", stone.position).ok,
			"working out a finite mineral deposit opens its site without losing the harvested stock")
	var felled := nodes.fell(falling_tree, falling_tree.amount)
	_check(felled == 26.0 and not _sim.can_place("house", falling_tree.position).ok,
			"a falling trunk must leave the site before construction can begin")
	nodes.tick_falling(ResourceNodes.FALL_TIME + 0.1)
	_check(_sim.can_place("house", falling_tree.position).ok,
			"finished tree clearing opens the building footprint")
	var keep := _sim.place_building("keep", Vector3(100, 9, 400), 0.0, true)
	keep.inventory[Config.Res.TIMBER] = 100.0
	keep.inventory[Config.Res.STONE] = 100.0
	_sim.research.completed.append("civic_building")
	var granary := _sim.place_building("granary", Vector3(560, 9, 400), 0.0, true)
	var width := _registry.footprint("granary_large").x
	var edge := granary.position + Vector3(width * 0.5 - 0.1, 0, 0)
	nodes._build_multimesh("oak_tree_01", [{"position": edge, "scale": 1.0,
			"yaw": 0.0, "kind": ResourceNodes.Kind.TREE, "amount": 26.0}], _registry)
	nodes._index_cells()
	var edge_tree: ResourceNodes.NodeRec = nodes.records.back()
	var before := keep.inventory.duplicate()
	var blocked := _sim.upgrade(granary)
	_check(not blocked.ok and blocked.reason.contains("trees") and granary.type_id == "granary"
			and edge_tree.amount == 26.0 and keep.inventory == before,
			"an expanded upgrade footprint cannot erase a tree or spend its construction stock")
	var cleared := nodes.harvest(edge_tree, edge_tree.amount, _sim.day)
	var upgraded := _sim.upgrade(granary)
	nodes.tick_regrowth(_sim.day + ResourceNodes.TREE_REGROW_DAYS + 1.0)
	_check(upgraded.ok and granary.type_id == "grain_warehouse" and edge_tree.depleted
			and edge_tree.regrow_at < 0.0 and cleared == 26.0,
			"clearing the expanded footprint enables the upgrade and prevents later trunk clipping")


func _run() -> void:
	_registry.load_all()
	_flat_world()
	_resource_sites()
	_sim.free()
	_world.free()
	await process_frame
	print("Building placement regression failures: %d" % _failures)
	quit(1 if _failures else 0)
