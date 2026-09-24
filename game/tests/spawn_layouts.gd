extends "res://tests/long_run.gd"

## Exercise the same staged new-world operation exposed by the World dialog.
## Check actual starting buildings after all placement and terrain edits; no
## test building is force-placed and no live layout is repaired by this test.
const SIZES := [768, 1536, 3072, 6144]
const FOUNDATION_TOLERANCE := 0.20


func _footprint(b: Building) -> Rect2:
	var size := b.plan_footprint()
	return Rect2(Vector2(b.position.x, b.position.z) - size * 0.5, size)


func _inspect(game: SeededGame, world_seed: int, size_m: int) -> void:
	var label := "seed=%d size=%d" % [world_seed, size_m]
	var buildings: Array = game.sim.buildings.duplicate()
	buildings.append_array(game.sim.campaign.enemy_buildings.values())
	_check(game.sim.buildings.size() == 9 and game.sim.campaign.enemy_buildings.size() == 6,
			label + " contains the complete nine-building opening and six-building rival")
	var issues: Array[String] = []
	var max_foundation_gap := 0.0
	var wells := 0
	for b: Building in buildings:
		var owner := "player" if game.sim.buildings.has(b) else "rival"
		var name := "%s %s#%d at %s" % [owner, b.type_id, b.id, str(b.position)]
		var area := _footprint(b)
		if b.type_id == "well":
			wells += 1
			var door: Vector3 = game.sim.entrance_of(b, "att_entrance")
			var cell := game.world.world_to_cell(door)
			if game.world.nav.is_solid(cell.x, cell.y) or area.has_point(Vector2(door.x, door.z)) \
					or not game.world.nav.can_reach(game.sim.entrance_of(game.sim.keep, "att_entrance"), door):
				issues.append(name + " has no dry, reachable entrance beyond its stone ring")
		if area.position.x < 0 or area.position.y < 0 or area.end.x > size_m or area.end.y > size_m:
			issues.append(name + " extends beyond the map")
		var worst_gap := 0.0
		var worst_slope := 0.0
		var in_water := false
		# Sample the rotated footprint itself, including corners and walls.
		for iz in 5:
			for ix in 5:
				var local := Vector3((float(ix) / 4.0 - 0.5) * b.footprint.x, 0,
						(float(iz) / 4.0 - 0.5) * b.footprint.y)
				var at: Vector3 = b.global_transform * local
				var hm := game.world.heightmap
				var cell := hm.world_to_cell(at)
				worst_gap = maxf(worst_gap, absf(at.y - hm.height_at(at.x, at.z)))
				worst_slope = maxf(worst_slope, hm.cell_slope(cell.x, cell.y))
				in_water = in_water or hm.cell_surface(cell.x, cell.y) == Heightmap.Surface.WATER
		max_foundation_gap = maxf(max_foundation_gap, worst_gap)
		if in_water:
			issues.append(name + " footprint touches water")
		if worst_slope > Config.MAX_BUILD_SLOPE + 0.001:
			issues.append(name + " footprint slope %.3f exceeds build limit" % worst_slope)
		if worst_gap > FOUNDATION_TOLERANCE:
			issues.append(name + " foundation floats/is buried by %.3f m" % worst_gap)
		for rec in game.world.nodes.records:
			if rec.depleted:
				continue
			if rec.kind == ResourceNodes.Kind.TREE:
				# Crown overhang is natural; a standing trunk inside a structure is not.
				if area.has_point(Vector2(rec.position.x, rec.position.z)):
					issues.append(name + " intersects tree trunk #%d" % rec.id)
			else:
				var bounds: AABB = game.world.nodes._pick_world_bounds.get(rec.id, AABB())
				var deposit := Rect2(bounds.position.x, bounds.position.z, bounds.size.x, bounds.size.z)
				if area.intersects(deposit):
					issues.append(name + " intersects deposit #%d at %s" % [rec.id, str(rec.position)])
	for i in buildings.size():
		for j in range(i + 1, buildings.size()):
			if _footprint(buildings[i]).intersects(_footprint(buildings[j])):
				issues.append("building #%d overlaps #%d" % [buildings[i].id, buildings[j].id])
	for issue in issues:
		print("SPAWN_ISSUE %s %s" % [label, issue])
	_check(wells == 3, label + " supplies the player's two wells and the rival's one")
	_check(issues.is_empty(), label + " has dry, grounded, unobstructed, nonoverlapping starting buildings")
	print("SPAWN_METRIC %s buildings=%d max_foundation_gap=%.3f issues=%d" %
			[label, buildings.size(), max_foundation_gap, issues.size()])


func _run() -> void:
	var selected_seeds: Array = SEEDS.duplicate()
	var selected_sizes: Array = SIZES.duplicate()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--spawn-seed="):
			selected_seeds = [int(arg.trim_prefix("--spawn-seed="))]
		elif arg.begins_with("--spawn-size="):
			selected_sizes = [int(arg.trim_prefix("--spawn-size="))]
	var game := _new_game(selected_seeds[0])
	for world_seed in selected_seeds:
		for size_m in selected_sizes:
			var start := Time.get_ticks_msec()
			var error := game.new_world(world_seed, size_m)
			_check(error == "", "actual new-world creation seed=%d size=%d: %s" % [world_seed, size_m, error])
			if error == "":
				_inspect(game, world_seed, size_m)
			print("SPAWN_TIME seed=%d size=%d elapsed_ms=%d" % [world_seed, size_m, Time.get_ticks_msec() - start])
			await process_frame
	game.free()
	await process_frame
	print("Spawn layout regression failures: %d" % _failures)
	quit(1 if _failures else 0)
