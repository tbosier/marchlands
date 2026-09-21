class_name Cart
extends Node3D

## The settlement's single hand cart (design doc 25: "one cart").
##
## The cart is not an independent agent. It is taken up by a citizen for a
## bulk haul and trails behind them until the load is delivered, which keeps
## the simulation honest — a cart still needs a person — and makes its effect
## on the world visible: a loaded cart grinds five times as much wear into the
## ground as a walker, so the routes carts use are the ones that become roads
## first.

const FOLLOW_DISTANCE := 1.55
const CAPACITY := 48.0

var carrier: Citizen = null
var parked_at := Vector3.ZERO

var _load_visual: Node3D
var _registry: AssetRegistry


func setup(registry: AssetRegistry, park: Vector3) -> void:
	_registry = registry
	name = "cart"
	var visual := registry.instantiate("wood_cart", 0)
	add_child(visual)
	parked_at = park
	global_position = park
	rotation.y = PI * 0.25


func is_free() -> bool:
	return carrier == null


func take(c: Citizen) -> void:
	carrier = c
	# A stored modifier, not a scaling of speed_scale: multiplying on take and
	# dividing on release accumulated float drift every time the cart changed
	# hands, and citizens slowly got faster.
	c.speed_modifier = Config.CART_SPEED / Config.WALK_SPEED
	c.wear_rate_override = Config.WEAR_CART
	c.brush_override = Config.WEAR_BRUSH_CART


func release(hm: Heightmap, world: World = null) -> void:
	if carrier != null:
		carrier.speed_modifier = 1.0
		carrier.wear_rate_override = -1.0
		carrier.brush_override = -1.0
		carrier = null
	_set_load(-1)
	# Left where it was last used, which is exactly where the next hauler
	# wants it — carts accumulate at busy places, as they should.
	parked_at = global_position
	parked_at.y = world.surface_height_at(parked_at.x, parked_at.z) if world != null else hm.height_at(parked_at.x, parked_at.z)
	global_position = parked_at


## Trail behind the carrier, matching their heading.
func follow(hm: Heightmap, delta: float, world: World = null) -> void:
	if carrier == null:
		return
	var heading := carrier.rotation.y
	var back := Vector3(sin(heading), 0.0, cos(heading)) * FOLLOW_DISTANCE
	var want := carrier.global_position + back
	want.y = world.surface_height_at(want.x, want.z) if world != null else hm.height_at(want.x, want.z)
	var k := clampf(delta * 9.0, 0.0, 1.0)
	global_position = global_position.lerp(want, k)
	rotation.y = lerp_angle(rotation.y, heading, k)

	# Tilt with the slope so it does not look like it is hovering.
	var n := Vector3.UP if world != null and world.bridge_id_at(global_position.x, global_position.z) >= 0 else hm.normal_at(global_position.x, global_position.z)
	rotation.x = lerp_angle(rotation.x, -asin(clampf(n.z, -1.0, 1.0)) * 0.6, k)
	rotation.z = lerp_angle(rotation.z, asin(clampf(n.x, -1.0, 1.0)) * 0.6, k)


## Show what is being carried, sitting in the bed.
func _set_load(res: int) -> void:
	if _load_visual:
		_load_visual.queue_free()
		_load_visual = null
	if res < 0 or _registry == null:
		return
	var node := _registry.instantiate(Res.bulk_asset(res), 0)
	if node == null:
		return
	node.name = "load"
	node.position = _registry.attachment("wood_cart", "att_stock_0")
	node.scale = Vector3.ONE * 0.85
	add_child(node)
	_load_visual = node


func load_goods(res: int) -> void:
	_set_load(res)


func unload() -> void:
	_set_load(-1)
