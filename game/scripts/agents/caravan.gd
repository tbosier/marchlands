class_name Caravan
extends Node3D

## A role and a cart around the same resident node, including injured veterans.
var id := -1
var merchant: Citizen
var cart: Cart
var origin_id := -1
var target_id := -1
var source_id := -1
var food_source_id := -1
var state := "loading"
var loading_stage := "food"
var status := "Loading provisions"
var repeat := false
var export_amount := 24.0
var import_amount := 8.0
var provisions := 0.0
var pack_amount := 0.0
var cargo_res := -1
var cargo_amount := 0.0
var promised := false
var source_reserved := false
var food_reserved := false
var expires_in := 0.0
var health := 100.0
var completed_trips := 0


func setup(route_id: int, person: Citizen, registry: AssetRegistry) -> void:
	id = route_id
	name = "caravan_%d" % id
	merchant = person
	merchant.reparent(self)
	merchant.profession = "merchant"
	merchant.clear_goal()
	merchant._wear_anchor = merchant.global_position
	merchant._body.collision_layer = 32
	if merchant._body.has_meta("citizen_id"): merchant._body.remove_meta("citizen_id")
	if merchant._body.has_meta("unit_id"): merchant._body.remove_meta("unit_id")
	merchant._body.set_meta("caravan_id", id)
	cart = Cart.new()
	add_child(cart)
	cart.setup(registry, merchant.global_position)
	cart.take(merchant)


func occupied_capacity() -> float:
	return cargo_amount + provisions + merchant.carrying_amount + (merchant.rations if merchant is Soldier else 0.0)


func record() -> Dictionary:
	return {"id": id, "citizen": SaveGame._capture_citizen(merchant),
		"origin_id": origin_id, "target_id": target_id, "source_id": source_id,
		"food_source_id": food_source_id, "state": state, "loading_stage": loading_stage,
		"status": status, "repeat": repeat, "export_amount": export_amount,
		"import_amount": import_amount, "provisions": provisions, "pack_amount": pack_amount,
		"cargo_res": cargo_res, "cargo_amount": cargo_amount, "promised": promised,
		"source_reserved": source_reserved, "food_reserved": food_reserved,
		"expires_in": expires_in, "health": health, "completed_trips": completed_trips,
		"cart_position": cart.global_position}
