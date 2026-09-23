class_name Citizen
extends Node3D

## One person.
##
## Citizens walk the world physically, and that walking is what creates the
## road network: every step stamps wear into the world (design doc 2.1). They
## take work from the job board rather than being scripted, and they are
## animated procedurally by rotating the limb pivots the Blender export
## provides — no armature, no imported clips.

enum State { IDLE, TRAVELLING, WORKING, ARRIVING, EATING, SLEEPING }

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
## Damage sustained while serving outside the civilian workforce.
var service_health := 100.0
var hydration := 1.0
var water_bucket := 0.0
var water_sickness := 0.0

var carrying_res: int = -1
var carrying_amount: float = 0.0
## 0 is fed, 1 is starving. Rises only once a meal has actually fallen due, so
## a citizen who eats on time sits at zero rather than drifting upward.
var hunger: float = 0.0
## The absolute day on which the next meal falls due. Absolute rather than a
## time of day so it crosses midnight, survives a save, and needs no special
## casing when the calendar is set from a file.
var next_meal: float = 0.0
## Meals this citizen has actually sat down to, for the record and for the
## interface. Not load-bearing.
var meals_taken := 0
## Set when a meal errand found no food anywhere. Without it a starving march
## would spend every tick walking to an empty granary and back, and the farmers
## would never reap the crop that would have fed it.
var meal_retry_at: float = 0.0
## A route estimate for starting dinner before the walk itself makes hunger
## urgent. Transient like paths; cached so active workers do not run A* per tick.
var meal_route_check_at: float = 0.0
var meal_walk_seconds: float = 0.0
var meal_route_revision := -1
var meal_delivery_seconds: float = 0.0
var meal_route_job_id := -1
var meal_delivery_target := Vector3.INF
var meal_route_speed: float = 0.0
var morale: float = 0.75
## True while they are inside their own house for the night: hidden, and not
## clickable, because a person indoors is not on the map to be selected.
var indoors := false

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
var _arrival_goal := Vector3.ZERO
var _path_revision := -1
var _has_goal := false
var _repath_timer := 0.0
var _stuck_timer := 0.0
var _wear_anchor := Vector3.ZERO
var _wear_rate := Config.WEAR_PEDESTRIAN

var _work_timer := 0.0
var _anim_phase := 0.0
## The lerp weight the last `update_animation()` posed the limbs with, or 0.0
## if that call skipped the pose because the actor was too far from the camera
## to be worth it. Soldier reads it after calling `super`, so that the two
## levels of the animation agree about whether this frame is being drawn at
## all rather than one of them writing limbs the other left alone. See
## `LOD.animation_step()` for the policy and for what happens with no camera.
var _pose_weight := 0.0

var _parts := {}
var _rest := {}
var _carried_visual: Node3D
var _body: Area3D


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Detach per-person materials while their meshes still exist. Releasing
	# the last tinted actor during scene teardown otherwise leaves a renderer
	# instance querying a material RID already freed by its surface override.
	# PREDELETE matters: reparenting a staged save also exits the tree, but
	# must retain its clothing and faction colors.
	for part in _parts.values():
		if not is_instance_valid(part) or not part is MeshInstance3D:
			continue
		for surface in part.get_surface_override_material_count():
			part.set_surface_override_material(surface, null)


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


## Re-apply a saved person and their physical cargo. SaveGame separately
## rebuilds a loaded delivery's destination claim; other local work is assigned
## again by the production rota.
func apply_state(entry: Dictionary, registry: AssetRegistry = null) -> void:
	given_name = String(entry.get("name", given_name))
	profession = String(entry.get("profession", profession))
	age = int(entry.get("age", age))
	home_id = int(entry.get("home_id", -1))
	workplace_id = int(entry.get("workplace_id", -1))
	hunger = float(entry.get("hunger", 0.0))
	service_health = float(entry.get("service_health", 100.0))
	hydration = float(entry.get("hydration", 1.0))
	water_bucket = float(entry.get("water_bucket", 0.0))
	water_sickness = float(entry.get("water_sickness", 0.0))
	# A save written before meals existed has no schedule in it; leaving
	# next_meal at zero would have every restored citizen owed a meal at once.
	next_meal = float(entry.get("next_meal", next_meal))
	meals_taken = int(entry.get("meals_taken", 0))
	morale = float(entry.get("morale", 0.75))

	if immigrant:
		# Keep walking to the same place they were walking to, not to wherever
		# the seat happens to be when the save is read.
		immigrant_target = entry.get("immigrant_target", immigrant_target)
		set_goal(immigrant_target)

	var res := int(entry.get("carrying_res", -1))
	var amount := float(entry.get("carrying_amount", 0.0))
	if res >= 0 and amount > 0.0 and registry != null:
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
	_arrival_goal = target
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
	if unreachable:
		return false
	return Vector2(global_position.x - _arrival_goal.x,
				   global_position.z - _arrival_goal.z).length() <= Config.ARRIVE_RADIUS

func walking_speed() -> float:
	var carry_penalty := 1.0 - 0.14 * clampf(
			(carrying_amount + water_bucket) / float(Config.CARRY_CAPACITY), 0.0, 1.0)
	return Config.WALK_SPEED * speed_scale * speed_modifier * carry_penalty \
			* (0.6 if hydration <= 0.1 else 1.0) * (1.0 - water_sickness * 0.2)


## Advance the citizen by `delta` in-game seconds. Returns the distance moved,
## having already stamped that movement into the wear field.
func advance(delta: float, world: World) -> float:
	if not _has_goal:
		update_animation(delta, 0.0)
		return 0.0

	_repath_timer -= delta
	if _path_revision != world.nav.revision or _repath_timer <= 0.0 \
			or (not _path.is_empty() and _path_index >= _path.size()):
		_repath(world)

	if _path.is_empty():
		update_animation(delta, 0.0)
		return 0.0

	var here := global_position
	var start_cell := world.world_to_cell(here)
	var escaping := world.nav.is_solid(start_cell.x, start_cell.y)
	var target: Vector3 = _path[_path_index]
	var flat_to_target := Vector2(target.x - here.x, target.z - here.z)

	while flat_to_target.length() < 0.35 and _path_index < _path.size() - 1:
		var next_waypoint := _path[_path_index + 1]
		# A valid route can just clear the corner of an obstacle. Turning a
		# third of a metre early cuts through that corner unless the shortcut
		# from the person's actual position is also clear.
		if not escaping and not world.nav._clear_line(Vector2(here.x, here.z),
				Vector2(next_waypoint.x, next_waypoint.z)):
			break
		_path_index += 1
		target = _path[_path_index]
		flat_to_target = Vector2(target.x - here.x, target.z - here.z)

	var dist := flat_to_target.length()
	# Finish even the last sub-millimetre when a corner forbids an early turn.
	# Stopping short here left a rounded position clipping the next diagonal,
	# so both the corner guard and this tolerance refused to move forever.
	if dist <= 0.0:
		update_animation(delta, 0.0)
		return 0.0

	var road_mult: float = world.wear.speed_multiplier_at(here.x, here.z)
	# Clamped, because `int(x / CELL)` on a position that has drifted to the
	# edge of the world indexes past the grid, reads as water, and stops the
	# citizen dead.
	var surf_mult: float = world.surface_speed_at(here.x, here.z)
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
		to.y = world.surface_height_at(to.x, to.z)
		global_position = to
		_path.clear()
		# Move the wear anchor with them without stamping. Wading leaves no
		# track — and leaving the anchor behind in the water would have the
		# first stamp after they reached dry land draw a road across the lake.
		_wear_anchor = to
		update_animation(delta, wade.length() / maxf(delta, 0.0001))
		return wade.length()
	var speed: float = walking_speed() * road_mult * surf_mult
	var step: float = minf(speed * delta, dist)
	var dir := flat_to_target / dist
	var moved := Vector3(dir.x, 0, dir.y) * step
	var next := here + moved
	if step == dist:
		# Finish exactly on the waypoint rather than a rounded point beside
		# it, which could keep a tight corner's next segment obstructed.
		next.x = target.x
		next.z = target.z
	next.y = world.surface_height_at(next.x, next.z)
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


## How long this person keeps their cached route before recomputing it.
##
## Everyone given an order in the same tick used to renew exactly
## PATH_CACHE_SECONDS later, together, and then together again, forever: a
## column ordered out of the keep kept coming due on one frame, and a few
## hundred routes landing on a single frame is what puts a multi-second frame
## next to a four-millisecond median. Bringing each person's renewal forward by
## their own share of the window breaks the column up. Forward only — see
## Config.PATH_CACHE_JITTER for why nobody's route may outlive the plain
## window.
##
## The share is derived from the citizen id and not from randf(): where a
## person walks decides the position that is saved and fingerprinted, and a
## route that depended on the RNG cursor or on the order actors happened to be
## advanced in would make a reloaded save diverge from the one that wrote it.
func _path_cache_interval() -> float:
	# Multiplying by a large odd constant first, because ids are handed out in
	# sequence: taken raw, the people ordered out together — neighbours in the
	# roster, usually — would land on neighbouring shares, which is the
	# synchronised renewal again with a second or two of smear on it. Odd times
	# id is a bijection modulo a power of two, so the shares stay evenly spread
	# while consecutive ids fall far apart in the window.
	var share := float(posmod(id * 2654435761, 65536)) / 65536.0
	return Config.PATH_CACHE_SECONDS * (1.0 - Config.PATH_CACHE_JITTER * share)


func _repath(world: World) -> void:
	# Carry the overshoot instead of restarting the window from this frame.
	# Simulation steps are capped at MAX_SIM_STEP and a fast-forwarded game sits
	# on that cap, so a bare reset rounds every interval up to the same multiple
	# of the step: two people a tenth of a second apart in their windows come due
	# on the same frame anyway, cycle after cycle, and the spread buys nothing
	# beyond its first turn. Keeping the fraction they overran by lets their
	# renewals keep walking apart. Only the overshoot, and only one step of it:
	# a repath forced early — by a road change, or by being wedged — starts its
	# next window whole.
	_repath_timer = _path_cache_interval() \
			+ clampf(_repath_timer, -Config.MAX_SIM_STEP, 0.0)
	_path = world.nav.find_path(global_position, _goal)
	_path_index = 0
	_path_revision = world.nav.revision
	unreachable = _path.is_empty()
	_arrival_goal = _goal if unreachable else _path[_path.size() - 1]
	_wear_anchor = global_position


# --- Animation --------------------------------------------------------------

func update_animation(delta: float, speed: float) -> void:
	if _parts.is_empty():
		_pose_weight = 0.0
		return

	var moving := speed > 0.15
	if moving:
		_anim_phase += delta * (2.2 + speed * 1.5)
	else:
		# Settle limbs back to rest instead of freezing mid-stride.
		_anim_phase += delta * 0.6

	# The phase advances above the gate, on every frame, for everyone. It is
	# two multiplies and two adds, and keeping it tied to elapsed time means a
	# distant actor's walk cycle runs at the right speed rather than at his
	# share of it, and that walking back into the near band resumes the stride
	# where it should be instead of wherever it was left. Everything below the
	# gate is a transform write, and that is the part worth not doing.
	_pose_weight = LOD.animation_step(self, id)
	if _pose_weight <= 0.0:
		return

	var swing: float = sin(_anim_phase * 2.0) * (0.55 if moving else 0.0)
	var bob: float = absf(sin(_anim_phase * 2.0)) * (0.045 if moving else 0.0)

	_set_part("leg_l", Vector3(swing, 0, 0), _pose_weight)
	_set_part("leg_r", Vector3(-swing, 0, 0), _pose_weight)

	if state == State.WORKING:
		# Working: both arms rise and fall together (chopping, cutting, reaping).
		var chop: float = sin(_anim_phase * 5.0)
		_set_part("arm_l", Vector3(-1.15 + chop * 0.75, 0, 0), _pose_weight)
		_set_part("arm_r", Vector3(-1.15 + chop * 0.75, 0, 0), _pose_weight)
		_set_part("torso", Vector3(0.10 + chop * 0.08, 0, 0), _pose_weight)
	elif carrying_amount > 0.0:
		# Carrying: arms held forward under the load.
		_set_part("arm_l", Vector3(-1.25, 0, 0.12), _pose_weight)
		_set_part("arm_r", Vector3(-1.25, 0, -0.12), _pose_weight)
		_set_part("torso", Vector3(0.08, 0, 0), _pose_weight)
	else:
		_set_part("arm_l", Vector3(-swing * 0.8, 0, 0), _pose_weight)
		_set_part("arm_r", Vector3(swing * 0.8, 0, 0), _pose_weight)
		_set_part("torso", Vector3(0, 0, 0), _pose_weight)

	var torso: Node3D = _parts.get("torso")
	if torso:
		torso.position = _rest["torso"] + Vector3(0, bob, 0)
	var head: Node3D = _parts.get("head")
	if head:
		head.position = _rest["head"] + Vector3(0, bob, 0)
		head.rotation = Vector3(sin(_anim_phase * 2.0) * 0.04, 0, 0)


## `weight` defaults to the plain per-frame smoothing rate, which is what the
## one-off poses driven from outside the walk cycle — a soldier's swing — want.
## `update_animation()` passes the weight its band earned instead; see
## `LOD.ACTOR_ANIMATION_WEIGHTS`.
func _set_part(key: String, euler: Vector3, weight: float = 0.35) -> void:
	var part: Node3D = _parts.get(key)
	if part == null:
		return
	part.rotation = part.rotation.lerp(euler, weight)


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
	if job != null and job.work_left > 0.0:
		_work_timer = minf(seconds, job.work_left)
		job.work_left = -1.0


## Injured veterans override this; ordinary citizens retain full ability.
func workability() -> float:
	return 1.0


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


## Go inside for the night, or come back out. Hiding the node takes the visual
## with it; the pick body has to be told separately, or the settlement would be
## full of invisible people who could still be clicked on.
func set_indoors(value: bool) -> void:
	if indoors == value:
		return
	indoors = value
	visible = not value
	if _body != null and is_instance_valid(_body):
		_body.collision_layer = 0 if value else 4


## Hunger rises only after a meal has been missed, and reaches starving after
## Config.STARVE_DAYS. `day` is the simulation's own day counter.
func update_hunger(day: float, delta_days: float) -> void:
	if day <= next_meal:
		return
	hunger = minf(1.0, hunger + delta_days / Config.STARVE_DAYS)


## Sit down to a meal: clears the hunger and books the next one.
func take_meal(day: float) -> void:
	meals_taken += 1
	hunger = 0.0
	# A late breakfast just before dinner still feeds the citizen for one meal
	# interval. Otherwise the next calendar slot could be seconds away, making
	# a remote worker turn back for food immediately after finally eating.
	var minimum_gap := 1.0
	var previous: float = Config.MEAL_TIMES.back() - 1.0
	for meal_time in Config.MEAL_TIMES:
		minimum_gap = minf(minimum_gap, meal_time - previous)
		previous = meal_time
	next_meal = maxf(Config.next_meal_after(day), day + minimum_gap)
	meal_route_check_at = 0.0


func is_hungry(day: float) -> bool:
	return day >= next_meal


func status_line() -> String:
	if carrying_amount > 0.0 and carrying_res >= 0:
		return "%s (carrying %d %s)" % [task_label, int(carrying_amount),
				Res.display(carrying_res)]
	return task_label
