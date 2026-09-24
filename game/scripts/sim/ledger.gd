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
## The same two sums split by where the goods came from or went: resource,
## then source name, then the decaying amount. What the tooltip lists.
var _made_by: Array[Dictionary] = []
var _used_by: Array[Dictionary] = []


func _init() -> void:
	_made.resize(Config.RES_COUNT)
	_used.resize(Config.RES_COUNT)
	for i in Config.RES_COUNT:
		_made_by.append({})
		_used_by.append({})


func made(res: int, amount: float, source: String = "Other") -> void:
	if res >= 0 and res < Config.RES_COUNT and amount > 0.0 and is_finite(amount):
		_made[res] += amount
		_made_by[res][source] = float(_made_by[res].get(source, 0.0)) + amount


func used(res: int, amount: float, source: String = "Other") -> void:
	if res >= 0 and res < Config.RES_COUNT and amount > 0.0 and is_finite(amount):
		_used[res] += amount
		_used_by[res][source] = float(_used_by[res].get(source, 0.0)) + amount


## Take back part of a `used` entry: food charged through `Stores.spend` that
## was only packed, and will be recorded again when it is actually eaten.
func unused(res: int, amount: float, source: String = "Other") -> void:
	if res >= 0 and res < Config.RES_COUNT and amount > 0.0 and is_finite(amount):
		_used[res] = maxf(0.0, _used[res] - amount)
		_used_by[res][source] = maxf(0.0, float(_used_by[res].get(source, 0.0)) - amount)


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
		for table in [_made_by[i], _used_by[i]]:
			for source in table.keys():
				table[source] *= keep
				if table[source] < 0.01:
					table.erase(source)


## Produced per in-game day, recently.
func made_per_day(res: int) -> float:
	return _made[res]


## Consumed per in-game day, recently.
func used_per_day(res: int) -> float:
	return _used[res]


## Where `res` comes from, or goes, per day: [[source, amount], ...], largest
## first, leaving out anything under a tenth of a unit a day.
func sources(res: int, making: bool) -> Array:
	var table: Dictionary = (_made_by if making else _used_by)[res]
	var rows: Array = []
	for source in table:
		if float(table[source]) >= 0.1:
			rows.append([source, float(table[source])])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	return rows
