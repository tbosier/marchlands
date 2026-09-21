class_name Cattle
extends Citizen

## Animals reuse the settlement's tested navigation, but are never citizens,
## workers or soldiers. Husbandry owns their population and production.
var ranch_id := -1
var age_days := 12.0
var marked := false
var wander_at := 0.0
var grazing_anchor := Vector3.ZERO
var _legs: Array[Node3D] = []
var _cow_body: Node3D


func setup_cow(cow_id: int, start: Vector3) -> void:
	id = cow_id
	name = "cattle_%d" % id
	given_name = "Wild cattle"
	speed_scale = 0.72
	position = start
	grazing_anchor = start
	_wear_anchor = start
	_cow_body = Node3D.new()
	add_child(_cow_body)
	var coat := StandardMaterial3D.new()
	coat.albedo_color = Color(0.48, 0.26, 0.13) if id % 2 else Color(0.82, 0.75, 0.60)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.14, 0.10, 0.07)
	var horn := StandardMaterial3D.new()
	horn.albedo_color = Color(0.85, 0.82, 0.67)
	_box(_cow_body, Vector3(1.1, 0.95, 1.9), Vector3(0, 1.15, 0), coat)
	_box(_cow_body, Vector3(0.65, 0.7, 0.8), Vector3(0, 1.25, -1.15), coat)
	_box(_cow_body, Vector3(0.7, 0.26, 0.3), Vector3(0, 0.98, -1.62), dark)
	for side in [-1.0, 1.0]:
		_box(_cow_body, Vector3(0.33, 0.12, 0.26), Vector3(side * 0.5, 1.55, -1.12), coat)
		var tip := _box(_cow_body, Vector3(0.10, 0.4, 0.10), Vector3(side * 0.4, 1.83, -1.08), horn)
		tip.rotation.z = -side * 0.48
		for front in [-0.68, 0.68]:
			var leg := Node3D.new()
			_cow_body.add_child(leg)
			leg.position = Vector3(side * 0.38, 0.82, front)
			_box(leg, Vector3(0.24, 0.78, 0.25), Vector3(0, -0.39, 0), coat)
			_box(leg, Vector3(0.27, 0.16, 0.3), Vector3(0, -0.75, 0), dark)
			_legs.append(leg)
	var tail := _box(_cow_body, Vector3(0.10, 0.8, 0.10), Vector3(0, 0.95, 1.0), dark)
	tail.rotation.x = -0.15
	_body = Area3D.new()
	_body.name = "pick"
	_body.collision_layer = 16
	_body.collision_mask = 0
	_body.monitoring = false
	_body.set_meta("cow_id", id)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.5, 1.9, 3.0)
	shape.shape = box
	shape.position.y = 0.95
	_body.add_child(shape)
	add_child(_body)
	refresh_age()


func _box(parent: Node3D, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.position = at
	parent.add_child(part)
	return part


func refresh_age() -> void:
	if _cow_body != null:
		_cow_body.scale = Vector3.ONE * lerpf(0.48, 1.0, clampf(age_days / 6.0, 0.0, 1.0))
	if _body != null:
		_body.scale = _cow_body.scale


func update_animation(delta: float, speed: float) -> void:
	_anim_phase += delta * (4.0 if speed > 0.15 else 0.5)
	for index in _legs.size():
		_legs[index].rotation.x = sin(_anim_phase + float(index % 3) * PI) \
				* (0.45 if speed > 0.15 else 0.0)


func capture_cow() -> Dictionary:
	return {"id": id, "position": position, "yaw": rotation.y, "ranch_id": ranch_id,
		"age_days": age_days, "marked": marked}
