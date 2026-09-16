class_name RTSCamera
extends Node3D

## Elevated free camera (design doc 3.2).
##
## The camera is a yaw pivot carrying a pitched arm. Zoom moves along that arm
## and also tilts it, so pulling back gives a strategic overview and pushing in
## gets down among the citizens — all in the same continuous world, never a
## separate map layer.

const PAN_SPEED := 42.0
const PAN_SPEED_ZOOM_FACTOR := 0.055
const ROTATE_SPEED := 0.007
const ZOOM_STEP := 0.10
const EDGE_MARGIN := 6.0

const MIN_DIST := 12.0
const MAX_DIST := 340.0
const NEAR_PITCH := -16.0
const FAR_PITCH := -58.0

@export var edge_pan_enabled := false

var distance := 95.0
var yaw := 0.0
var focus := Vector3.ZERO

var _arm: Node3D
var _camera: Camera3D
var _rotating := false
var _hm: Heightmap
var _target_distance := 95.0
var _target_focus := Vector3.ZERO


func _ready() -> void:
	_arm = Node3D.new()
	_arm.name = "arm"
	add_child(_arm)

	_camera = Camera3D.new()
	_camera.name = "camera"
	# A slightly longer lens than the 52° it opened with. The brief asks for a
	# miniature kingdom rather than a diagram, and a wide angle is the enemy of
	# that: it stretches the buildings at the edges of the frame and makes the
	# ground plane fall away steeply, which reads as a large world seen from
	# inside rather than a small one seen from above.
	_camera.fov = 47.0
	_camera.near = 0.4
	_camera.far = 2200.0
	_arm.add_child(_camera)
	_apply()


func bind_terrain(hm: Heightmap) -> void:
	_hm = hm


func camera() -> Camera3D:
	return _camera


func look_at_position(p: Vector3, dist: float = -1.0) -> void:
	_target_focus = p
	focus = p
	if dist > 0.0:
		distance = clampf(dist, MIN_DIST, MAX_DIST)
		_target_distance = distance
	_apply()


func focus_on(p: Vector3, dist: float = -1.0) -> void:
	_target_focus = Vector3(p.x, p.y, p.z)
	if dist > 0.0:
		_target_distance = clampf(dist, MIN_DIST, MAX_DIST)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_target_distance = clampf(_target_distance * (1.0 - ZOOM_STEP),
					MIN_DIST, MAX_DIST)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_target_distance = clampf(_target_distance * (1.0 + ZOOM_STEP),
					MIN_DIST, MAX_DIST)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_rotating = mb.pressed
			Input.set_default_cursor_shape(
					Input.CURSOR_MOVE if _rotating else Input.CURSOR_ARROW)

	elif event is InputEventMouseMotion and _rotating:
		var mm: InputEventMouseMotion = event
		yaw -= mm.relative.x * ROTATE_SPEED
		_target_distance = clampf(
				_target_distance * (1.0 + mm.relative.y * 0.0016),
				MIN_DIST, MAX_DIST)


func _process(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_action_pressed("pan_left"):
		move.x -= 1.0
	if Input.is_action_pressed("pan_right"):
		move.x += 1.0
	if Input.is_action_pressed("pan_forward"):
		move.y -= 1.0
	if Input.is_action_pressed("pan_back"):
		move.y += 1.0

	if Input.is_action_pressed("rotate_left"):
		yaw += delta * 1.4
	if Input.is_action_pressed("rotate_right"):
		yaw -= delta * 1.4

	if edge_pan_enabled and move == Vector2.ZERO:
		move = _edge_pan_vector()

	if move != Vector2.ZERO:
		move = move.normalized()
		# Pan faster when zoomed out, so crossing the map stays quick.
		var speed := PAN_SPEED * (1.0 + distance * PAN_SPEED_ZOOM_FACTOR)
		var forward := Vector3(sin(yaw), 0, cos(yaw))
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		_target_focus += (right * move.x + forward * move.y) * speed * delta

	var margin := 12.0
	_target_focus.x = clampf(_target_focus.x, -margin,
			Config.WORLD_SIZE + margin)
	_target_focus.z = clampf(_target_focus.z, -margin,
			Config.WORLD_SIZE + margin)
	if _hm:
		_target_focus.y = _hm.height_at(_target_focus.x, _target_focus.z)

	var k := clampf(delta * 11.0, 0.0, 1.0)
	focus = focus.lerp(_target_focus, k)
	distance = lerpf(distance, _target_distance, k)
	_apply()


func _edge_pan_vector() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	var size := vp.get_visible_rect().size
	var mouse := vp.get_mouse_position()
	if mouse.x < 0 or mouse.y < 0 or mouse.x > size.x or mouse.y > size.y:
		return Vector2.ZERO
	var out := Vector2.ZERO
	if mouse.x < EDGE_MARGIN:
		out.x -= 1.0
	elif mouse.x > size.x - EDGE_MARGIN:
		out.x += 1.0
	if mouse.y < EDGE_MARGIN:
		out.y -= 1.0
	elif mouse.y > size.y - EDGE_MARGIN:
		out.y += 1.0
	return out


func _apply() -> void:
	position = focus
	rotation.y = yaw
	var t: float = clampf((distance - MIN_DIST) / (MAX_DIST - MIN_DIST), 0.0, 1.0)
	# Ease the tilt so the close-in view stays comfortably oblique.
	var pitch := lerpf(NEAR_PITCH, FAR_PITCH, pow(t, 0.7))
	_arm.rotation_degrees.x = pitch
	_camera.position = Vector3(0, 0, distance)


## Ray from the cursor into the world, for picking.
func screen_ray(screen_pos: Vector2) -> Dictionary:
	return {
		"origin": _camera.project_ray_origin(screen_pos),
		"direction": _camera.project_ray_normal(screen_pos),
	}


func zoom_fraction() -> float:
	return clampf((distance - MIN_DIST) / (MAX_DIST - MIN_DIST), 0.0, 1.0)
