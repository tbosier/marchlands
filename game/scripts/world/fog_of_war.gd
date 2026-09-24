class_name FogOfWar
extends Node3D

## A depth-aware overlay covers terrain, water and scenery without rebuilding
## their materials or uploading any navigation-resolution visibility field.
## The scouting manager owns the small RG8 map and its update cadence.
var scouting: Node
var _world: World
var _campaign: Node
var _overlay: MeshInstance3D
var _material: ShaderMaterial
var _hidden: Dictionary = {}
## Rival buildings the player's people have seen, by instance id. Once seen, a
## building stays drawn where it stood, dimmed by the overlay, so a castle
## visited does not vanish the moment the scout walks away, and a scout can
## still be sent to it. It is the building itself that is drawn, not a picture
## of it: one burnt down out of sight disappears. One raised since the last
## look stays hidden until somebody sees it. Not saved: after a load, anything
## standing on explored ground counts as seen.
var _remembered: Dictionary = {}


func setup(manager: Node, world: World, campaign: Node = null) -> void:
	scouting = manager
	_world = world
	_campaign = campaign
	_world.fog = self
	name = "fog_of_war"
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/fog_of_war.gdshader")
	_material.render_priority = 127
	_material.set_shader_parameter("visibility_map", scouting.texture())
	_material.set_shader_parameter("world_size", world.size_m)
	_material.set_shader_parameter("sea_level", Config.SEA_LEVEL)
	_overlay = MeshInstance3D.new()
	_overlay.name = "visibility_overlay"
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	_overlay.mesh = quad
	_overlay.material_override = _material
	_overlay.extra_cull_margin = 100000.0
	_overlay.ignore_occlusion_culling = true
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_overlay)
	scouting.changed.connect(refresh)
	refresh()


func refresh() -> void:
	if not is_instance_valid(scouting): return
	_material.set_shader_parameter("visibility_map", scouting.texture())
	refresh_entities()


func _process(_delta: float) -> void:
	# Units can cross a sight boundary between the manager's batched updates.
	# This walks actors and short-lived effects, never the world grid.
	refresh_entities()


func refresh_entities() -> void:
	if not is_instance_valid(scouting): return
	var checked := {}
	if is_instance_valid(_campaign):
		for child in _campaign.get_children():
			if not child is Node3D or child.is_queued_for_deletion(): continue
			var friendly: bool = child is Soldier and child.faction == 0
			var alive: bool = not child is Soldier or child.health > 0
			var seen: bool = scouting.visibility_at(child.global_position)
			var drawn := seen
			if child is Building:
				if seen or (not _remembered.has(child.get_instance_id())
						and _loaded_memory(child)):
					_remembered[child.get_instance_id()] = true
				drawn = seen or _remembered.has(child.get_instance_id())
			_filter(child, alive and (friendly or drawn), alive and (friendly or seen))
			checked[child.get_instance_id()] = true
	if is_instance_valid(_world) and is_instance_valid(_world.effects_root):
		for effect in _world.effects_root.get_children():
			if effect is Node3D and not effect.is_queued_for_deletion():
				# The player's own order markers show where they clicked, fog or not.
				_filter(effect, effect.has_meta(&"fog_exempt")
						or scouting.visibility_at(effect.global_position))
				checked[effect.get_instance_id()] = true
	if scouting is Scouting and scouting.sim.husbandry != null:
		for cow in scouting.sim.husbandry.cows.values():
			if not is_instance_valid(cow) or cow.is_queued_for_deletion(): continue
			_filter(cow, cow.ranch_id >= 0 or scouting.visibility_at(cow.global_position))
			checked[cow.get_instance_id()] = true
	_memory_seeded = true
	# Reclaimed buildings and demobilized people can leave the campaign tree.
	# Release their presentation filter instead of leaving a friendly hidden.
	for id in _hidden.keys():
		if not checked.has(id): _release(id)


## Whether a rival building the player's people have seen is remembered.
func remembers(building: Node) -> bool:
	return is_instance_valid(building) and _remembered.has(building.get_instance_id())


var _memory_seeded := false

## After a load the memory is empty; the first pass treats buildings on
## explored ground as seen, which is as close as the save can say.
func _loaded_memory(building: Node3D) -> bool:
	return not _memory_seeded and scouting.explored_at(building.global_position)


## `shown` draws the node; `pickable` also gives back its collision. A
## remembered building under the fog is drawn but not pickable: clicks and
## soldiers' target rays pass through to what is actually there.
func _filter(node: Node3D, shown: bool, pickable: bool = true) -> void:
	var id := node.get_instance_id()
	if shown and pickable:
		_release(id)
		return
	if not _hidden.has(id):
		var bodies: Array = []
		for child in node.find_children("*", "CollisionObject3D", true, false):
			bodies.append({"node": weakref(child), "layer": child.collision_layer})
			child.collision_layer = 0
		_hidden[id] = {"node": weakref(node), "visible": node.visible, "bodies": bodies}
	elif node.visible and not shown:
		# Fog set this false last time; only its owner can have turned it back
		# on since, so that is what it should return to once seen again.
		_hidden[id].visible = true
	node.visible = bool(_hidden[id].visible) if shown else false


func _release(id: int) -> void:
	if not _hidden.has(id): return
	var record: Dictionary = _hidden[id]
	var node: Node = record.node.get_ref()
	if is_instance_valid(node) and not node.is_queued_for_deletion():
		node.visible = record.visible
		for item in record.bodies:
			var body: Node = item.node.get_ref()
			if is_instance_valid(body): body.collision_layer = item.layer
	_hidden.erase(id)


func _exit_tree() -> void:
	for id in _hidden.keys(): _release(id)
