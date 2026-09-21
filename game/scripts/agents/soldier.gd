class_name Soldier
extends Citizen

## Campaign units reuse the walking/limb rig. Demobilized veterans keep this
## body as ordinary citizens, so returning to work cannot restore lost limbs.

const Body = preload("res://scripts/agents/soldier_body.gd")

var _body_state: Dictionary = Body.healthy()
var faction: int = 0
## Compatibility for campaign removal and old saves. Injury locations remain
## authoritative; assigning legacy health changes systemic strain, never limbs.
var health: float:
	get:
		return Body.health(_body_state)
	set(value):
		if is_finite(value):
			_body_state.strain = clampf(float(_body_state.strain) + health - value, 0.0, 100.0)
var armor_tier: String:
	get:
		return _body_state.armor
var medical_role: String:
	get:
		return _body_state.role
var medical_supplies: int:
	get:
		return _body_state.medical_supplies
var rations: float = 4.0
var target_id: int = -1
var target_kind: String = ""
var cooldown: float = 0.0
var fire_cooldown: float = 0.0

var _attack_left := 0.0
var _unit_visual: Node3D
var _effects_root: Node3D
var _terrain: Heightmap
var _civilian_mode := false
var _sword: Node3D
var _shield: Node3D
var _armor_visuals: Array[Node3D] = []
var _injury_visuals: Array[Node3D] = []
var _dead_visualized := false
var _injury_signature := ""


## A visual projectile has its own lifetime, so an attacker's removal cannot
## leave a floating firepot or call a method on a freed unit. It deals no damage.
class FirepotVisual extends Node3D:
	var start: Vector3
	var finish: Vector3
	var flight := 0.8
	var elapsed := 0.0
	var pot: MeshInstance3D
	var flames: Array[MeshInstance3D] = []

	func _ready() -> void:
		# The campaign advances this with simulation seconds. Real-frame process
		# time would leave pots hanging after their impacts during fast-forward.
		set_process(false)
		pot = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.16
		sphere.height = 0.28
		sphere.radial_segments = 8
		sphere.rings = 4
		pot.mesh = sphere
		var clay := StandardMaterial3D.new()
		clay.albedo_color = Color(0.40, 0.18, 0.07)
		pot.material_override = clay
		add_child(pot)
		for i in 5:
			var flame := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.14
			cone.height = 0.8
			cone.radial_segments = 5
			flame.mesh = cone
			var material := StandardMaterial3D.new()
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.albedo_color = Color(1.0, 0.40 + 0.08 * i, 0.06)
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			flame.material_override = material
			flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			flame.position = Vector3(cos(i * 2.4) * 0.25, 0.4, sin(i * 2.4) * 0.25)
			add_child(flame)
			flames.append(flame)
		global_position = start

	func _process(delta: float) -> void:
		elapsed += delta
		var progress := clampf(elapsed / flight, 0.0, 1.0)
		global_position = start.lerp(finish, progress)
		global_position.y += sin(progress * PI) * maxf(2.0, start.distance_to(finish) * 0.18)
		pot.visible = elapsed < flight
		for i in flames.size():
			var flame := flames[i]
			var size := 0.22 if elapsed < flight else maxf(0.0, 1.0 - (elapsed - flight) / 1.5)
			flame.scale = Vector3.ONE * size
			flame.scale.y *= 1.0 + sin(elapsed * 20.0 + i * 1.7) * 0.25
			flame.position = Vector3(cos(i * 2.4) * 0.25 * size,
					0.12 if elapsed < flight else 0.4 * size, sin(i * 2.4) * 0.25 * size)
			var mat: StandardMaterial3D = flame.material_override
			mat.albedo_color.a = minf(1.0, size * 2.0)
		if elapsed > flight + 1.5:
			queue_free()


static func advance_projectiles(effects: Node3D, delta: float) -> void:
	if not is_instance_valid(effects) or delta <= 0.0 or not is_finite(delta):
		return
	for effect in effects.get_children():
		if effect is FirepotVisual and not effect.is_queued_for_deletion():
			effect._process(delta)


func setup_unit(registry: AssetRegistry, hm: Heightmap, unit_id: int,
		unit_faction: int, start: Vector3, body_asset: String = "citizen_male_base") -> void:
	faction = unit_faction
	_terrain = hm
	var rng := RandomNumberGenerator.new()
	rng.seed = unit_id * 31 + faction * 997
	super.setup(unit_id, registry, rng, body_asset)
	name = "soldier_%d" % unit_id
	given_name = "March guard" if faction == 0 else "Raider"
	profession = "soldier"
	task_label = "Standing guard"
	speed_scale = 1.0
	position = start
	position.y = hm.height_at(start.x, start.z)
	_wear_anchor = position
	_unit_visual = get_child(0) as Node3D
	_body.collision_layer = 8
	_body.remove_meta("citizen_id")
	_body.set_meta("unit_id", id)
	_equip()
	_refresh_condition(false)


func _tint(visual: Node3D, _rng: RandomNumberGenerator) -> void:
	for child in visual.get_children():
		if not child is MeshInstance3D:
			continue
		var mesh: MeshInstance3D = child
		for surface in mesh.mesh.get_surface_count():
			var original := mesh.mesh.surface_get_material(surface) as StandardMaterial3D
			if original == null or original.resource_name != "fabric_muted":
				continue
			var material := original.duplicate() as StandardMaterial3D
			material.albedo_color = _faction_color()
			mesh.set_surface_override_material(surface, material)


func _faction_color() -> Color:
	return Color(0.12, 0.31, 0.66) if faction == 0 else Color(0.66, 0.12, 0.09)


func _equipment_mesh(parent: Node3D, mesh: Mesh, at: Vector3,
		color: Color, metallic: float = 0.0) -> MeshInstance3D:
	var item := MeshInstance3D.new()
	item.mesh = mesh
	item.position = at
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.4 if metallic > 0.0 else 0.85
	item.material_override = material
	parent.add_child(item)
	return item


func _equip() -> void:
	var sword_arm: Node3D = _parts.get("arm_r", _unit_visual)
	_sword = Node3D.new()
	_sword.name = "sword"
	sword_arm.add_child(_sword)
	var blade := BoxMesh.new()
	blade.size = Vector3(0.075, 0.72, 0.035)
	_equipment_mesh(_sword, blade, Vector3(0, -0.85, -0.08), Color(0.62, 0.66, 0.69), 0.8)
	var guard := BoxMesh.new()
	guard.size = Vector3(0.24, 0.045, 0.065)
	_equipment_mesh(_sword, guard, Vector3(0, -0.47, -0.08), Color(0.25, 0.24, 0.19), 0.6)
	var shield_arm: Node3D = _parts.get("arm_l", _unit_visual)
	var shield := CylinderMesh.new()
	shield.top_radius = 0.34
	shield.bottom_radius = 0.34
	shield.height = 0.07
	shield.radial_segments = 10
	var held := _equipment_mesh(shield_arm, shield, Vector3(0, -0.30, -0.20), _faction_color())
	_shield = held
	held.name = "shield"
	held.rotation.x = PI * 0.5
	var boss := SphereMesh.new()
	boss.radius = 0.11
	boss.height = 0.10
	boss.radial_segments = 8
	boss.rings = 4
	_equipment_mesh(held, boss, Vector3(0, -0.06, 0), Color(0.5, 0.53, 0.56), 0.7)


func capture_body() -> Dictionary:
	return _body_state.duplicate(true)


static func validate_body(data: Variant) -> String:
	return Body.validate(data)


static func body_health(data: Dictionary) -> float:
	return Body.health(data)


func restore_body(data: Variant) -> String:
	var problem := validate_body(data)
	if problem != "":
		return problem
	_body_state = Body.migrate(data)
	if health > 0.0:
		_dead_visualized = false
		visible = not indoors
		if _body != null:
			_body.collision_layer = 4 if _civilian_mode else 8
	_rebuild_armor()
	_refresh_condition(false)
	return ""


func equip_armor(tier: String) -> bool:
	if tier not in Body.ARMOR or health <= 0.0:
		return false
	_body_state.armor = tier
	_rebuild_armor()
	_refresh_condition(false)
	return true


func receive_hit(location: String, kind: String, force: float, anatomy_roll: float = 0.5) -> Dictionary:
	var result := Body.hit(_body_state, location, kind, force, anatomy_roll)
	if result.ok:
		_refresh_condition(true)
	return result


func hit_locations() -> Array[String]:
	var locations: Array[String] = []
	for location in Body.REGIONS:
		if Body.available(_body_state, location):
			locations.append(location)
	return locations


func can_strike() -> bool:
	return not _civilian_mode and health > 0.0 and Body.usable(_body_state, "arm_r")


func can_throw_firepot() -> bool:
	return can_strike()


func can_use_shield() -> bool:
	return not _civilian_mode and health > 0.0 and Body.usable(_body_state, "arm_l")


func mobility_scale() -> float:
	if health <= 0.0 or incapacitated():
		return 0.0
	var usable := 0
	var burden := 0.0
	for location in ["leg_l", "leg_r"]:
		var part: Dictionary = _body_state.parts[location]
		usable += int(Body.usable(_body_state, location))
		burden += Body.trauma(part)
	if usable == 0:
		return 0.0
	if usable == 1:
		return 0.25
	return maxf(0.50, 1.0 - burden / 140.0)


func walking_speed() -> float:
	return super.walking_speed() * mobility_scale()


func workability() -> float:
	if health <= 0.0 or incapacitated():
		return 0.0
	var usable := int(Body.usable(_body_state, "arm_l")) + int(Body.usable(_body_state, "arm_r"))
	return [0.0, 0.45, 1.0][usable]


func incapacitated() -> bool:
	return Body.incapacitated(_body_state)


## The owner ticks this exactly once for every person: army, civilian,
## merchant or scout. Movement calls must not double-count bleeding.
func advance_condition(delta: float) -> void:
	Body.advance(_body_state, delta)
	_refresh_condition(true)


func skill_level(skill: String) -> float:
	return float(_body_state.skills.get(skill, 0.0))


func practice(skill: String, amount: float = 0.05) -> void:
	if skill not in Body.SKILLS or not is_finite(amount) or amount <= 0.0 or health <= 0.0:
		return
	_body_state.skills[skill] = minf(100.0, skill_level(skill) + amount)


func hit_probability(target: Soldier) -> float:
	if not can_strike() or target == null or target.health <= 0.0: return 0.0
	if target.incapacitated(): return 0.98
	var chance := 0.68 + (skill_level("melee") - target.skill_level("dodge")) * 0.004
	if target.can_use_shield(): chance -= 0.10
	chance -= float(_body_state.shock) * 0.002
	chance -= (100.0 - float(_body_state.blood)) * 0.001
	if target.mobility_scale() < 0.5: chance += 0.15
	return clampf(chance, 0.10, 0.97)


func skill_summary() -> String:
	return "Melee %d · Dodge %d · Medicine %d · Scouting %d" % [
		roundi(skill_level("melee")), roundi(skill_level("dodge")),
		roundi(skill_level("medicine")), roundi(skill_level("scouting"))]


func configure_medic(kits: int) -> bool:
	if kits < 0 or kits > Body.MAX_MEDICAL_SUPPLIES - medical_supplies or health <= 0.0 or incapacitated():
		return false
	_body_state.role = "medic"
	_body_state.medical_supplies += kits
	profession = "field medic"
	return true


func treatment_need() -> Dictionary:
	return Body.treatment_need(_body_state)


func can_treat(target: Soldier) -> bool:
	return medical_role == "medic" and medical_supplies > 0 and health > 0.0 and not incapacitated() \
			and workability() > 0.0 and target != null and target.faction == faction \
			and target.health > 0.0 and not target.treatment_need().is_empty()


func treat(target: Soldier) -> Dictionary:
	if not can_treat(target): return {"ok": false, "reason": "No usable kit or treatable wound"}
	if global_position.distance_to(target.global_position) > 3.0:
		return {"ok": false, "reason": "Move within three metres to treat this soldier"}
	var need := target.treatment_need()
	var result: Dictionary = Body.treat(target._body_state, need.wound_id, need.treatment, skill_level("medicine"))
	if result.ok:
		_body_state.medical_supplies -= 1
		practice("medicine", 0.5)
		task_label = "Treating " + target.given_name
		target._refresh_condition(false)
	return result


func work_tick(delta: float) -> bool:
	if workability() <= 0.0:
		return false
	return super.work_tick(delta * workability())


func set_civilian_mode(value: bool) -> void:
	_civilian_mode = value
	if value:
		_attack_left = 0.0
	if _body != null:
		_body.collision_layer = 4 if value else 8
		_body.remove_meta("unit_id" if value else "citizen_id")
		_body.set_meta("citizen_id" if value else "unit_id", id)
	_refresh_condition(false)


func injury_summary() -> String:
	var lines: Array[String] = []
	lines.append("Blood %.0f%% · Shock %.0f%%" % [_body_state.blood, _body_state.shock])
	if _body_state.parts.arm_r.severed: lines.append("Sword arm: missing")
	if _body_state.parts.arm_l.severed: lines.append("Shield arm: missing")
	var injured := false
	for location in Body.REGIONS:
		var part: Dictionary = _body_state.regions[location]
		if Body.trauma(part) < 0.01:
			continue
		injured = true
		var condition := "missing" if part.severed else ("disabled" if Body.disabled(part)
				else ("punctured" if float(part.puncture) > 0.0 else ("cut" if float(part.cut) > 0.0 else "bruised")))
		lines.append("%s: %s" % [_region_label(location), condition])
	for wound in _body_state.wounds:
		if wound.artery != "": lines.append(wound.artery.capitalize() + " artery injured" + (" (bandaged)" if wound.bandaged else ""))
		if wound.fracture: lines.append(_region_label(wound.region) + (": splinted fracture" if wound.splinted else ": fracture"))
		elif wound.bandaged: lines.append(_region_label(wound.region) + ": bandaged")
	for organ in Body.ORGANS:
		if _body_state.organs[organ] > 0.0: lines.append(_region_label(organ) + " injured")
	if Body.bleeding_rate(_body_state) > 0.001: lines.append("Bleeding" + (" heavily" if Body.bleeding_rate(_body_state) > 0.20 else ""))
	if _body_state.blood < 70.0: lines.append("Severe blood loss" if _body_state.blood <= 50.0 else "Blood loss")
	if incapacitated(): lines.append("Incapacitated — alive, needs aid")
	elif _body_state.shock >= 25.0: lines.append("In shock")
	if float(_body_state.strain) >= 25.0:
		lines.append("Exhausted")
	if health <= 0.0: lines.append("Dead")
	elif not injured: lines.append("Uninjured")
	return "; ".join(lines)


static func _region_label(region: String) -> String:
	var side := "Left " if region.ends_with("_l") else ("Right " if region.ends_with("_r") else "")
	var label := region.trim_suffix("_l").trim_suffix("_r").replace("_", " ")
	return (side + label).capitalize()


func update_animation(delta: float, speed: float) -> void:
	super.update_animation(delta, speed)
	for location in Body.LIMBS:
		if not _parts.has(location):
			continue
		var part: Node3D = _parts[location]
		if not Body.usable(_body_state, location):
			part.rotation = Vector3(0.06, 0, 0.12 if location.ends_with("_l") else -0.12)
	if mobility_scale() < 0.5 and _parts.has("torso"):
		_parts.torso.rotation.z = 0.12 if Body.disabled(_body_state.parts.leg_l) else -0.12
	if incapacitated() and _unit_visual != null:
		_unit_visual.rotation.z = PI * 0.42
	elif _unit_visual != null:
		_unit_visual.rotation.z = 0.0


func _rebuild_armor() -> void:
	for visual in _armor_visuals:
		visual.free()
	_armor_visuals.clear()
	if _unit_visual == null or armor_tier == "none":
		return
	for location in Body.LOCATIONS:
		var part: Node3D = _parts.get(location)
		if part == null:
			continue
		var armor := Node3D.new()
		armor.name = "armor_" + location
		part.add_child(armor)
		_armor_visuals.append(armor)
		var metal := armor_tier != "leather"
		var color := Color(0.31, 0.20, 0.12) if not metal else Color(0.29, 0.33, 0.37)
		var box := BoxMesh.new()
		var at := Vector3.ZERO
		if location == "torso":
			box.size = Vector3(0.455, 0.49, 0.30)
			at.y = 0.36
		elif location == "head":
			box.size = Vector3(0.225, 0.15, 0.235)
			at.y = 0.235
		elif location.begins_with("arm"):
			box.size = Vector3(0.115, 0.46, 0.115)
			at.y = -0.28
		else:
			box.size = Vector3(0.13, 0.40, 0.14)
			at.y = -0.26
		_equipment_mesh(armor, box, at, color, 0.55 if metal else 0.0)
		if metal and location == "torso":
			for row in 5:
				var links := BoxMesh.new()
				links.size = Vector3(0.445, 0.014, 0.012)
				_equipment_mesh(armor, links, Vector3(0, 0.16 + row * 0.085, -0.158), Color(0.49, 0.53, 0.55), 0.6)
		if armor_tier == "plate":
			var plate := BoxMesh.new()
			plate.size = box.size * Vector3(1.06, 0.76, 1.07)
			var shell := _equipment_mesh(armor, plate, at + Vector3(0, 0.025, -0.016), Color(0.61, 0.66, 0.70), 0.85)
			shell.name = "plate_over_mail"
			if location == "torso":
				var badge := BoxMesh.new()
				badge.size = Vector3(0.10, 0.17, 0.02)
				_equipment_mesh(armor, badge, at + Vector3(0, 0.04, -0.19), _faction_color())


func _refresh_condition(play_effects: bool) -> void:
	if _unit_visual == null:
		return
	if play_effects and _sword.visible and not can_strike():
		_drop_equipment(_sword)
	if play_effects and _shield.visible and not can_use_shield():
		_drop_equipment(_shield)
	_sword.visible = can_strike()
	_shield.visible = can_use_shield()
	for location in Body.LOCATIONS:
		if _parts.has(location):
			_parts[location].visible = not _body_state.parts[location].severed
	for armor in _armor_visuals:
		armor.visible = not _civilian_mode
	_refresh_injury_marks()
	if mobility_scale() <= 0.0:
		clear_goal()
	if health <= 0.0:
		if play_effects:
			_die()
		else:
			visible = false
			_body.collision_layer = 0


func _refresh_injury_marks() -> void:
	var treatments := {}
	for wound in _body_state.wounds:
		if wound.bandaged or wound.splinted:
			treatments[wound.region] = true
	var signature := str(_body_state.regions) + str(treatments)
	if signature == _injury_signature:
		return
	_injury_signature = signature
	for visual in _injury_visuals:
		visual.free()
	_injury_visuals.clear()
	for location in Body.REGIONS:
		var injury: Dictionary = _body_state.regions[location]
		var group := Body.group_of(location)
		if Body.trauma(injury) < 8.0 or not _parts.has(group):
			continue
		var mark := Node3D.new()
		mark.name = "injury_" + location
		_injury_visuals.append(mark)
		var part: Node3D = _parts[group]
		if injury.severed and _body_state.parts[group].severed:
			_unit_visual.add_child(mark)
			mark.position = _rest[group]
			var cap := SphereMesh.new()
			cap.radius = 0.06
			cap.height = 0.10
			cap.radial_segments = 6
			cap.rings = 3
			_equipment_mesh(mark, cap, Vector3.ZERO, Color(0.72, 0.69, 0.57))
		else:
			part.add_child(mark)
			var at := Vector3(0, -0.32, -0.076)
			if group == "torso":
				at = Vector3(0.06, 0.43 if location == "chest" else 0.22, -0.17)
			elif location == "head":
				at = Vector3(0, 0.23, -0.125)
			elif location == "neck":
				at = Vector3(0, 0.03, -0.12)
			elif location.begins_with("hand"):
				at.y = -0.59
			elif location.begins_with("foot"):
				at.y = -0.72
			elif location.begins_with("lower"):
				at.y = -0.48
			else:
				at.y = -0.18
			var color := Color(0.79, 0.75, 0.62) if treatments.has(location) else (
					Color(0.49, 0.08, 0.06) if injury.cut > 0.0 or injury.puncture > 0.0 else Color(0.36, 0.22, 0.28))
			for strip in 2:
				var bandage := BoxMesh.new()
				bandage.size = Vector3(0.115, 0.024, 0.013)
				var mesh := _equipment_mesh(mark, bandage, at, color)
				mesh.rotation.z = 0.6 if strip == 0 else -0.6


func _drop_equipment(equipment: Node3D) -> void:
	var effects := _effects_root if is_instance_valid(_effects_root) else get_parent() as Node3D
	if effects == null:
		return
	var dropped := equipment.duplicate() as Node3D
	dropped.name = "dropped_" + equipment.name
	effects.add_child(dropped)
	dropped.global_position = global_position + Vector3(0.35 if equipment == _sword else -0.35, 0.08, 0.1)
	dropped.rotation = Vector3(0, rotation.y, PI * 0.5 if equipment == _sword else 0.0)
	dropped.visible = true
	var tween := dropped.create_tween()
	tween.tween_interval(12.0)
	tween.tween_callback(dropped.queue_free)


func order_move(at: Vector3) -> void:
	if health <= 0.0 or mobility_scale() <= 0.0:
		return
	state = State.TRAVELLING
	task_label = "Marching"
	set_goal(at)


func tick(delta: float, world: World) -> void:
	_effects_root = world.effects_root
	if health <= 0.0:
		return
	if mobility_scale() <= 0.0:
		clear_goal()
	advance(delta, world)
	if has_goal() and has_arrived():
		clear_goal()
		state = State.IDLE
		task_label = "Standing guard"
	_attack_left = maxf(0.0, _attack_left - delta)
	if _attack_left > 0.0 and can_strike():
		_set_part("arm_r", Vector3(-1.25 - sin(_attack_left * 12.0) * 0.9, 0, -0.2))
		if can_use_shield():
			_set_part("arm_l", Vector3(-0.65, 0, 0.15))


func strike(at: Vector3) -> bool:
	if not can_strike():
		return false
	face_towards(at)
	_attack_left = 0.5
	task_label = "Fighting"
	return true


func throw_firepot(at: Vector3) -> bool:
	if not can_throw_firepot():
		return false
	strike(at)
	task_label = "Throwing firepot"
	var projectile := FirepotVisual.new()
	projectile.name = "firepot"
	projectile.start = global_position + Vector3(0, 1.5, 0)
	projectile.finish = at
	projectile.finish.y = _terrain.height_at(at.x, at.z) + 0.1
	projectile.flight = clampf(projectile.start.distance_to(projectile.finish) / 18.0, 0.45, 1.4)
	var effects := _effects_root if is_instance_valid(_effects_root) else get_parent() as Node3D
	effects.add_child(projectile)
	return true


func apply_damage(damage: float) -> void:
	if health <= 0.0 or damage <= 0.0 or not is_finite(damage):
		return
	_body_state.strain = minf(100.0, float(_body_state.strain) + damage)
	_refresh_condition(true)


func _die() -> void:
	if _dead_visualized:
		return
	_dead_visualized = true
	clear_goal()
	_body.collision_layer = 0
	_leave_corpse()
	visible = false


func _leave_corpse() -> void:
	var corpse := _unit_visual.duplicate() as Node3D
	corpse.name = "fallen_guard"
	var effects := _effects_root if is_instance_valid(_effects_root) else get_parent() as Node3D
	effects.add_child(corpse)
	corpse.global_transform = global_transform
	var materials: Array[StandardMaterial3D] = []
	for node in corpse.find_children("*", "MeshInstance3D", true, false):
		var mesh: MeshInstance3D = node
		for surface in mesh.mesh.get_surface_count():
			var original := mesh.get_active_material(surface) as StandardMaterial3D
			if original == null:
				continue
			var material := original.duplicate() as StandardMaterial3D
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mesh.material_override = null
			mesh.set_surface_override_material(surface, material)
			materials.append(material)
	var tween := corpse.create_tween()
	tween.tween_property(corpse, "rotation:z", PI * 0.5, 0.25)
	tween.tween_interval(1.5)
	for i in materials.size():
		if i > 0:
			tween.parallel()
		tween.tween_property(materials[i], "albedo_color:a", 0.0, 0.8)
	tween.tween_callback(corpse.queue_free)
