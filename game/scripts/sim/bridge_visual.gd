class_name BridgeVisual
extends Node3D

## Timber geometry is shared with placement previews; no generated asset is
## needed to give the deck, railings and bank scaffolds their exact span.
var _deck: Node3D
var _rails: Node3D
var _pick: Area3D
var _span := 0.0


func setup(bridge_id: int, a: Vector3, b: Vector3, width: float,
		progress: float = 1.0, preview: bool = false, valid: bool = true) -> void:
	position = a
	var offset := b - a
	_span = offset.length()
	# Local +Z follows the crossing; local Y remains perpendicular to its slope.
	var forward := offset.normalized()
	var side := Vector3.UP.cross(forward).normalized()
	basis = Basis(side, forward.cross(side).normalized(), forward)
	var timber := StandardMaterial3D.new()
	timber.albedo_color = Color("795438")
	if preview:
		timber.albedo_color = Color(0.3, 0.85, 0.6, 0.65) if valid else Color(0.95, 0.3, 0.22, 0.65)
		timber.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	timber.roughness = 0.95
	_deck = Node3D.new()
	add_child(_deck)
	_rails = Node3D.new()
	add_child(_rails)
	# Continuous beams plus individual plank seams remain readable from above.
	for side_x in [-width * 0.36, width * 0.36]:
		_box(_deck, Vector3(0.24, 0.38, _span), Vector3(side_x, -0.32, _span * 0.5), timber)
	var planks := maxi(1, ceili(_span / 0.75))
	for i in planks:
		_box(_deck, Vector3(width, 0.18, _span / planks - 0.04),
			Vector3(0, -0.1, (float(i) + 0.5) * _span / planks), timber)
	for side_x in [-width * 0.49, width * 0.49]:
		_box(_rails, Vector3(0.13, 0.14, _span), Vector3(side_x, 0.9, _span * 0.5), timber)
		for i in maxi(2, ceili(_span / 6.0) + 1):
			var z := float(i) * _span / float(maxi(1, ceili(_span / 6.0)))
			_box(_rails, Vector3(0.18, 1.35, 0.18), Vector3(side_x, 0.42, z), timber)
		# Piles at the banks and along the span suggest a supported timber deck.
		for i in maxi(2, ceili(_span / 12.0) + 1):
			var z := float(i) * _span / float(maxi(1, ceili(_span / 12.0)))
			_box(self, Vector3(0.35, 3.0, 0.35), Vector3(side_x * 0.8, -1.65, z), timber)
	if not preview:
		_pick = Area3D.new()
		_pick.collision_layer = 64
		_pick.collision_mask = 0
		_pick.monitoring = false
		_pick.set_meta("bridge_id", bridge_id)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(width, 1.5, _span)
		shape.shape = box
		shape.position = Vector3(0, 0.35, _span * 0.5)
		_pick.add_child(shape)
		add_child(_pick)
	set_progress(progress)


func _box(parent: Node3D, dimensions: Vector3, at: Vector3, material: Material) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	node.mesh = mesh
	node.material_override = material
	node.position = at
	parent.add_child(node)


func set_progress(progress: float) -> void:
	if _deck == null:
		return
	_deck.scale.z = maxf(0.04, clampf(progress, 0.0, 1.0))
	_rails.visible = progress >= 1.0
