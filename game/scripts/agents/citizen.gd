class_name Citizen
extends Node3D

## One person.
##
## Citizens walk the world physically, and that walking is what creates the
## road network: every step stamps wear into the world (design doc 2.1). They
## take work from the job board rather than being scripted, and they are
## animated procedurally by rotating the limb pivots the Blender export
## provides — no armature, no imported clips.

enum State { IDLE, TRAVELLING, WORKING, ARRIVING }

const STUCK_LIMIT := 4.0

var id: int = -1
var given_name: String = ""
## The body mesh this person was given. Recorded so a reloaded save shows the
## same crowd, rather than reshuffling everyone's appearance.
var asset_id: String = ""
var profession: String = "settler"
var home_id: int = -1
var workplace_id: int = -1
var age: int = 24

var carrying_res: int = -1
var carrying_amount: float = 0.0
var hunger: float = 0.0
var morale: float = 0.75

var state: int = State.IDLE
var job: JobBoard.Job = null
var task_label: String = "idle"

var speed_scale := 1.0
## Set while pulling a cart: a loaded cart grinds far more wear into the
## ground, over a wider track, than a person on foot does.
var wear_rate_override := -1.0
var brush_override := -1.0
## Applied on top of speed_scale while pulling something.
var speed_modifier := 1.0
## Set when the navigator could find no route to the current goal.
var unreachable := false
var immigrant := false
var immigrant_target := Vector3.ZERO

var _path: PackedVector3Array = PackedVector3Array()
var _path_index := 0
var _goal := Vector3.ZERO
var _has_goal := false
var _repath_timer := 0.0
var _stuck_timer := 0.0
var _wear_anchor := Vector3.ZERO
var _wear_rate := Config.WEAR_PEDESTRIAN

var _work_timer := 0.0
var _anim_phase := 0.0

var _parts := {}
var _rest := {}
var _carried_visual: Node3D
var _body: Area3D


func setup(citizen_id: int, registry: AssetRegistry,
		   rng: RandomNumberGenerator, forced_asset: String = "") -> void:
	id = citizen_id
	given_name = _make_name(rng)
	age = rng.randi_range(17, 58)
	name = "citizen_%d" % citizen_id

	# The draw happens either way, so that a restored citizen consumes the same
	# amount of the sequence as a newly born one and the rest of the crowd is
	# not re-rolled behind them.
	var rolled := "citizen_male_base" if rng.randf() < 0.5 \
			else "citizen_female_base"
	asset_id = forced_asset if forced_asset != "" else rolled
	var visual := registry.instantiate(asset_id, 0)
	add_child(visual)

	# Cache the limb pivots the exporter named, so the walk cycle can drive
	# them directly.
	for child in visual.get_children():
		var n := String(child.name)
		for part in ["torso", "head", "arm_l", "arm_r", "leg_l", "leg_r"]:
			if n.ends_with("_" + part):
				_parts[part] = child
				_rest[part] = child.position
	_tint(visual, rng)

	# Slight per-person variation keeps a crowd from marching in lockstep.
	speed_scale = rng.randf_range(0.92, 1.09)
	_anim_phase = rng.randf() * TAU

	_body = Area3D.new()
	_body.name = "pick"
	_body.collision_layer = 4
	_body.collision_mask = 0
	_body.monitoring = false
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.45
	capsule.height = 1.9
	shape.shape = capsule
	shape.position.y = 0.95
	_body.add_child(shape)
	_body.set_meta("citizen_id", id)
	add_child(_body)


## Re-apply a saved person. Their job is deliberately not restored: the board
## is rebuilt from scratch on load, so everyone starts the first tick idle and
## is given work by the same rota that would have given it to them anyway.
## Whatever they were carrying stays on their back, so a load in transit is
## delivered rather than destroyed.
func apply_state(entry: Dictionary, registry: AssetRegistry = null) -> void:
	given_name = String(entry.get("name", given_name))
	profession = String(entry.get("profession", profession))
	age = int(entry.get("age", age))
	home_id = int(entry.get("home_id", -1))
	workplace_id = int(entry.get("workplace_id", -1))
	hunger = float(entry.get("hunger", 0.0))
	morale = float(entry.get("morale", 0.75))

	if immigrant:
		# Keep walking to the same place they were walking to, not to wherever
		# the seat happens to be when the save is read.
		immigrant_target = entry.get("immigrant_target", immigrant_target)
		set_goal(immigrant_target)

	var res := int(entry.get("carrying_res", -1))
	var amount := float(entry.get("carrying_amount", 0.0))
	if res >= 0 and amount > 0.01 and registry != null:
		pick_up(res, amount, registry)


func _make_name(rng: RandomNumberGenerator) -> String:
	const FIRST := ["Alder", "Bryn", "Cerys", "Dain", "Edda", "Fenn", "Gwyn",
		"Hale", "Isolde", "Joris", "Kestrel", "Lowri", "Maud", "Nerys",
		"Osric", "Petra", "Quill", "Rhoda", "Sable", "Tam", "Ulric", "Vesna",
		"Wren", "Ysolt"]
	const LAST := ["of the March", "Ashdown", "Blackwater", "Coldfell",
		"Dunmore", "Eastmere", "Fairholt", "Greyburn", "Harrow", "Ivenbrook",
		"Longmoor", "Northwood", "Oakhanger", "Redwater", "Stonecroft",
		"Thornby", "Westfen"]
	return "%s %s" % [FIRST[rng.randi() % FIRST.size()],
					  LAST[rng.randi() % LAST.size()]]


func _tint(visual: Node3D, rng: RandomNumberGenerator) -> void:
	## Randomised clothing keeps a shared base mesh from reading as clones
	## (design doc 27: simple shared rigs and randomised clothing).
	var hue_shift := rng.randf_range(-0.06, 0.06)
	var value := rng.randf_range(0.86, 1.14)
	for child in visual.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi: MeshInstance3D = child
		for s in mi.mesh.get_surface_count():
			var base := mi.mesh.surface_get_material(s)
			if base == null:
				continue
			var mat: StandardMaterial3D = base.duplicate()
			var c := mat.albedo_color
			# Leave skin alone; only recolour cloth.
			if c.r > 0.55 and c.g > 0.4 and c.b > 0.3 and c.r > c.b * 1.25:
				mi.set_surface_override_material(s, mat)
				continue
			c.h = fposmod(c.h + hue_shift, 1.0)
			c.v = clampf(c.v * value, 0.0, 1.0)
			mat.albedo_color = c
			mi.set_surface_override_material(s, mat)


# --- Movement ---------------------------------------------------------------

## Re-issuing the same goal is a no-op. Behaviour code calls this every tick,
## and without the guard every citizen would discard and recompute its path
## each frame — which is both ruinously slow and stops them ever arriving.
func set_goal(target: Vector3, wear_rate: float = Config.WEAR_PEDESTRIAN) -> void:
	_wear_rate = wear_rate
	if _has_goal and _goal.distance_squared_to(target) < 0.36:
		return
	_goal = target
	_has_goal = true
	unreachable = false
	_repath_timer = 0.0
	_path.clear()
	_path_index = 0


## Whether this person is on their way somewhere.
func has_goal() -> bool:
	return _has_goal


func clear_goal() -> void:
	_has_goal = false
	unreachable = false
	_path.clear()
	_path_index = 0


func has_arrived() -> bool:
	if not _has_goal:
		return true
	return Vector2(global_position.x - _goal.x,
				   global_position.z - _goal.z).length() <= Config.ARRIVE_RADIUS


func distance_to_goal() -> float:
	return global_position.distance_to(_goal)


## Advance the citizen by `delta` in-game seconds. Returns the distance moved,
## having already stamped that movement into the wear field.
func advance(delta: float, world: World) -> float:
	if not _has_goal:
		update_animation(delta, 0.0)
		return 0.0

	_repath_timer -= delta
	if _path.is_empty() or _path_index >= _path.size() or _repath_timer <= 0.0:
		_repath(world)

	if _path.is_empty():
		update_animation(delta, 0.0)
		return 0.0

	var here := global_position
	var target: Vector3 = _path[_path_index]
	var flat_to_target := Vector2(target.x - here.x, target.z - here.z)

	while flat_to_target.length() < 0.35 and _path_index < _path.size() - 1:
		_path_index += 1
		target = _path[_path_index]
		flat_to_target = Vector2(target.x - here.x, target.z - here.z)

	var dist := flat_to_target.length()
	if dist < 0.001:
		update_animation(delta, 0.0)
		return 0.0

	var road_mult: float = world.wear.speed_multiplier_at(here.x, here.z)
	# Clamped, because `int(x / CELL)` on a position that has drifted to the
	# edge of the world indexes past the grid, reads as water, and stops the
	# citizen dead.
	var cell := Config.world_to_cell(here)
	var surf_mult: float = world.heightmap.surface_speed(cell.x, cell.y)
	if surf_mult <= 0.0:
		# Impassable ground — a settler scattered into the shallows, or a path
		# that crossed something it should not have. Wade slowly towards the
		# nearest firm ground instead of standing here for the rest of the
		# game: refusing to move at all left them frozen with no way out,
		# still eating and still counted against the housing the settlement
		# needed to attract anyone else.
		var escape := Config.cell_to_world(world.nav.nearest_free(here))
		var away := Vector2(escape.x - here.x, escape.z - here.z)
		if away.length() < 0.001:
			update_animation(delta, 0.0)
			return 0.0
		var wade := away.normalized() * minf(
				Config.WALK_SPEED * 0.35 * delta, away.length())
		var to := here + Vector3(wade.x, 0.0, wade.y)
		to.y = world.heightmap.height_at(to.x, to.z)
		global_position = to
		_path.clear()
		# Move the wear anchor with them without stamping. Wading leaves no
		# track — and leaving the anchor behind in the water would have the
		# first stamp after they reached dry land draw a road across the lake.
		_wear_anchor = to
		update_animation(delta, wade.length() / maxf(delta, 0.0001))
		return wade.length()
	var carry_penalty := 1.0 - 0.14 * clampf(
			carrying_amount / float(Config.CARRY_CAPACITY), 0.0, 1.0)

	var speed: float = (Config.WALK_SPEED * speed_scale * speed_modifier
			* road_mult * surf_mult * carry_penalty)
	var step: float = minf(speed * delta, dist)
	var dir := flat_to_target / dist
	var moved := Vector3(dir.x, 0, dir.y) * step
	var next := here + moved
	next.y = world.heightmap.height_at(next.x, next.z)
	global_position = next

	# Face the direction of travel.
	if step > 0.0005:
		var want := atan2(-dir.x, -dir.y)
		rotation.y = lerp_angle(rotation.y, want, clampf(delta * 7.0, 0.0, 1.0))

	# The world remembers this. Stamping in segments rather than per frame
	# keeps the trail continuous at any simulation speed.
	if _wear_anchor.distance_to(next) > 0.9:
		var rate: float = _wear_rate if wear_rate_override < 0.0 \
				else wear_rate_override
		var brush: float = (Config.WEAR_BRUSH_PEDESTRIAN
				if brush_override < 0.0 else brush_override)
		world.wear.stamp_segment(_wear_anchor, next, rate, brush)
		_wear_anchor = next

	# Detect and break out of being wedged against geometry.
	if here.distance_to(next) < 0.004:
		_stuck_timer += delta
		if _stuck_timer > STUCK_LIMIT:
			_stuck_timer = 0.0
			_repath(world)
	else:
		_stuck_timer = 0.0

	update_animation(delta, step / maxf(delta, 0.0001))
	return step


func _repath(world: World) -> void:
	_repath_timer = Config.PATH_CACHE_SECONDS
	_path = world.nav.find_path(global_position, _goal)
	_path_index = 0
	unreachable = _path.is_empty()
	_wear_anchor = global_position


# --- Animation --------------------------------------------------------------

func update_animation(delta: float, speed: float) -> void:
	if _parts.is_empty():
		return

	var moving := speed > 0.15
	if moving:
		_anim_phase += delta * (2.2 + speed * 1.5)
	else:
		# Settle limbs back to rest instead of freezing mid-stride.
		_anim_phase += delta * 0.6

	var swing: float = sin(_anim_phase * 2.0) * (0.55 if moving else 0.0)
	var bob: float = absf(sin(_anim_phase * 2.0)) * (0.045 if moving else 0.0)

	_set_part("leg_l", Vector3(swing, 0, 0))
	_set_part("leg_r", Vector3(-swing, 0, 0))

	if state == State.WORKING:
		# Working: both arms rise and fall together (chopping, cutting, reaping).
		var chop: float = sin(_anim_phase * 5.0)
		_set_part("arm_l", Vector3(-1.15 + chop * 0.75, 0, 0))
		_set_part("arm_r", Vector3(-1.15 + chop * 0.75, 0, 0))
		_set_part("torso", Vector3(0.10 + chop * 0.08, 0, 0))
	elif carrying_amount > 0.0:
		# Carrying: arms held forward under the load.
		_set_part("arm_l", Vector3(-1.25, 0, 0.12))
		_set_part("arm_r", Vector3(-1.25, 0, -0.12))
		_set_part("torso", Vector3(0.08, 0, 0))
	else:
		_set_part("arm_l", Vector3(-swing * 0.8, 0, 0))
		_set_part("arm_r", Vector3(swing * 0.8, 0, 0))
		_set_part("torso", Vector3(0, 0, 0))

	var torso: Node3D = _parts.get("torso")
	if torso:
		torso.position = _rest["torso"] + Vector3(0, bob, 0)
	var head: Node3D = _parts.get("head")
	if head:
		head.position = _rest["head"] + Vector3(0, bob, 0)
		head.rotation = Vector3(sin(_anim_phase * 2.0) * 0.04, 0, 0)


func _set_part(key: String, euler: Vector3) -> void:
	var part: Node3D = _parts.get(key)
	if part == null:
		return
	part.rotation = part.rotation.lerp(euler, 0.35)


# --- Carrying ---------------------------------------------------------------

func pick_up(res: int, amount: float, registry: AssetRegistry) -> void:
	carrying_res = res
	carrying_amount = amount
	_update_carried_visual(registry)


func drop() -> float:
	var amount := carrying_amount
	carrying_amount = 0.0
	carrying_res = -1
	if _carried_visual:
		_carried_visual.queue_free()
		_carried_visual = null
	return amount


func _update_carried_visual(registry: AssetRegistry) -> void:
	if _carried_visual:
		_carried_visual.queue_free()
		_carried_visual = null
	if carrying_amount <= 0.0:
		return
	var node := registry.instantiate(Res.carried_asset(carrying_res), 1)
	if node == null:
		return
	node.name = "carried"
	node.position = Vector3(0, 0.95, -0.42)
	node.scale = Vector3.ONE * 0.55
	add_child(node)
	_carried_visual = node


# --- Work timing ------------------------------------------------------------

func begin_work(seconds: float) -> void:
	state = State.WORKING
	_work_timer = seconds


func work_tick(delta: float) -> bool:
	_work_timer -= delta
	return _work_timer <= 0.0


func work_remaining() -> float:
	return maxf(0.0, _work_timer)


## Turn to face a point on the ground, without changing course.
func face_towards(target: Vector3) -> void:
	var d := Vector2(target.x - global_position.x, target.z - global_position.z)
	if d.length() > 0.01:
		rotation.y = atan2(-d.x, -d.y)


func has_cart() -> bool:
	return wear_rate_override > 0.0


func status_line() -> String:
	if carrying_amount > 0.0 and carrying_res >= 0:
		return "%s (carrying %d %s)" % [task_label, int(carrying_amount),
				Res.display(carrying_res)]
	return task_label
