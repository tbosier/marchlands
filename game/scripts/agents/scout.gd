class_name Scout
extends Node3D

## A service role around the same resident, including their injured body.
var id := -1
var person: Citizen
var lodge_id := -1
var state := "food"
var status := "Collecting training supplies"
var food_source := -1
var tool_source := -1
var food_reserved := true
var tools_reserved := true
var food := 0.0
var tools := 0.0
var training_left := 0.0
var destination := Vector3.ZERO
## An order given while still in training: `destination` holds it, and the
## scout sets out the moment training ends.
var orders_waiting := false
var health: float:
	get: return person.service_health if person != null else 100.0
	set(value):
		if person != null: person.service_health = value

func setup(scout_id: int, resident: Citizen) -> void:
	id = scout_id
	name = "scout_%d" % id
	person = resident
	person.reparent(self)
	person.profession = "scout"
	person.clear_goal()
	person._body.collision_layer = 64
	for key in ["citizen_id", "unit_id"]:
		if person._body.has_meta(key): person._body.remove_meta(key)
	person._body.set_meta("scout_id", id)

func record() -> Dictionary:
	return {"id": id, "citizen": SaveGame._capture_citizen(person), "lodge_id": lodge_id,
		"state": state, "status": status, "food_source": food_source, "tool_source": tool_source,
		"food_reserved": food_reserved, "tools_reserved": tools_reserved,
		"food": food, "tools": tools, "training_left": training_left,
		"destination": destination, "health": health, "orders_waiting": orders_waiting}
