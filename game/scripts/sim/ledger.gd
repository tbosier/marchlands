class_name ResourceLedger
extends RefCounted

## What the settlement makes and uses of each resource, as rates.
##
## Only real creation and destruction is recorded — gathering, reaping,
## crafting, slaughter and imports on one side; meals, tool wear, building
## materials, research and exports on the other. Moving goods between stores is
## neither, and is never written here.
##
## Each side is a sum that decays with a time constant of one in-game day, so
## it reads as "about this much per day" over the last day or so. It is a
## readout for the interface and is not saved: a loaded march starts it again.

var _made := PackedFloat32Array()
var _used := PackedFloat32Array()


func _init() -> void:
	_made.resize(Config.RES_COUNT)
	_used.resize(Config.RES_COUNT)


func made(res: int, amount: float) -> void:
	if res >= 0 and res < Config.RES_COUNT and amount > 0.0 and is_finite(amount):
		_made[res] += amount


func used(res: int, amount: float) -> void:
	if res >= 0 and res < Config.RES_COUNT and amount > 0.0 and is_finite(amount):
		_used[res] += amount


## Take back part of a `used` entry: food charged through `Stores.spend` that
## was only packed, and will be recorded again when it is actually eaten.
func unused(res: int, amount: float) -> void:
	if res >= 0 and res < Config.RES_COUNT and amount > 0.0 and is_finite(amount):
		_used[res] = maxf(0.0, _used[res] - amount)


func used_cost(cost: Dictionary) -> void:
	for res in cost:
		used(int(res), float(cost[res]))


func decay(delta: float) -> void:
	if delta <= 0.0:
		return
	var keep := exp(-delta / Config.DAY_LENGTH)
	for i in Config.RES_COUNT:
		_made[i] *= keep
		_used[i] *= keep


## Produced per in-game day, recently.
func made_per_day(res: int) -> float:
	return _made[res]


## Consumed per in-game day, recently.
func used_per_day(res: int) -> float:
	return _used[res]
