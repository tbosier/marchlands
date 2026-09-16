class_name Population
extends RefCounted

## Food, hunger and immigration — everything that decides how many people the
## march holds and how they are faring.
##
## Split out of the simulation so the daily economy is readable on its own and
## can be tuned without touching the per-tick behaviour code.

signal alert(text: String, position: Vector3)

var stores: Stores
var jobs: JobBoard
var _rng := RandomNumberGenerator.new()
var _famine_days := 0.0


func setup(store_index: Stores, job_board: JobBoard, seed_value: int) -> void:
	stores = store_index
	jobs = job_board
	_rng.seed = seed_value + 991


# ---------------------------------------------------------------------------
# Food
# ---------------------------------------------------------------------------

func housing_capacity(buildings: Array[Building]) -> int:
	var total := 0
	for b in buildings:
		if not b.under_construction:
			total += b.def.houses
	return total


func food_days_remaining(citizens: Array[Citizen]) -> float:
	var eaten := maxf(1.0, citizens.size() * Config.HUNGER_PER_DAY)
	return stores.total(Config.Res.FOOD) / eaten


## Eat. Returns true if the settlement went short.
func consume_food(citizens: Array[Citizen], elapsed_days: float,
				  keep_position: Vector3, day: int) -> bool:
	var needed := citizens.size() * Config.HUNGER_PER_DAY * elapsed_days
	var short := stores.consume(Config.Res.FOOD, needed)

	if short > 0.5:
		_famine_days += elapsed_days
		for c in citizens:
			c.hunger = minf(3.0, c.hunger + 0.4)
			c.morale = maxf(0.0, c.morale - 0.06)
		if day % 2 == 0:
			alert.emit("The settlement is going hungry.", keep_position)
		return true

	_famine_days = 0.0
	for c in citizens:
		c.hunger = maxf(0.0, c.hunger - 0.5)
		c.morale = minf(1.0, c.morale + 0.03)
	return false


func famine_days() -> float:
	return _famine_days


func grow_crops(buildings: Array[Building], elapsed_days: float) -> void:
	for b in buildings:
		if b.under_construction or not b.def.is_farm() or b.field_count() == 0:
			continue
		b.set_crop_growth(b.crop_growth + elapsed_days / Config.FARM_GROWTH_DAYS)


# ---------------------------------------------------------------------------
# Immigration (design doc 9.2)
# ---------------------------------------------------------------------------

## How attractive the march looks to outsiders, 0..1, with the reasons why.
func appeal(buildings: Array[Building], citizens: Array[Citizen]) -> Dictionary:
	var spare := housing_capacity(buildings) - citizens.size()
	var food_days := food_days_remaining(citizens)
	var open := jobs.open_jobs()

	var score := 0.20
	score += clampf(spare / 12.0, 0.0, 0.30)
	score += clampf(food_days / 40.0, 0.0, 0.25)
	score += clampf(open / 14.0, 0.0, 0.20)

	var reasons: Array[String] = []
	if spare > 4:
		reasons.append("land to settle")
	if food_days > 12.0:
		reasons.append("food in your granaries")
	if open > 3:
		reasons.append("work to be had")
	if reasons.is_empty():
		reasons.append("word of your march")

	return {
		"score": score,
		"spare_housing": spare,
		"food_days": food_days,
		"reasons": reasons,
	}


## Decide whether a group sets out this day. Returns how many, and why.
func consider_immigration(buildings: Array[Building],
						  citizens: Array[Citizen]) -> Dictionary:
	var info := appeal(buildings, citizens)
	var spare: int = info["spare_housing"]
	if spare < Config.IMMIGRATION_GROUP_MIN:
		return {"count": 0}
	if float(info["food_days"]) < Config.IMMIGRATION_MIN_FOOD_DAYS:
		return {"count": 0}
	if _rng.randf() > float(info["score"]):
		return {"count": 0}

	var count: int = mini(spare, _rng.randi_range(
			Config.IMMIGRATION_GROUP_MIN, Config.IMMIGRATION_GROUP_MAX))
	return {"count": count, "reasons": info["reasons"]}


## A walkable point on the map edge, so settlers can be seen arriving.
func edge_entry_point(world: World) -> Vector3:
	for _attempt in 24:
		var p: Vector3
		match _rng.randi() % 4:
			0: p = Vector3(_rng.randf() * Config.WORLD_SIZE, 0, 6.0)
			1: p = Vector3(_rng.randf() * Config.WORLD_SIZE, 0,
					Config.WORLD_SIZE - 6.0)
			2: p = Vector3(6.0, 0, _rng.randf() * Config.WORLD_SIZE)
			_: p = Vector3(Config.WORLD_SIZE - 6.0, 0,
					_rng.randf() * Config.WORLD_SIZE)
		var c := Config.world_to_cell(p)
		if not world.nav.is_solid(c.x, c.y):
			p.y = world.heightmap.height_at(p.x, p.z)
			return p
	return Vector3.INF


func scatter_offset() -> Vector3:
	return Vector3(_rng.randf_range(-6, 6), 0, _rng.randf_range(-6, 6))
