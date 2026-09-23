extends "res://tests/long_run.gd"

## Storage pressure must stop new output before it strands the whole workforce.
## Exercise the actual job lifecycle, including rejection, deposits and retirement.


func _clear_jobs(sim: Simulation) -> void:
	for job in sim.jobs.all_jobs():
		sim._release_reservations(job)
		sim.jobs.cancel(job)
	for citizen in sim.citizens:
		sim._release_cart(citizen)
		sim._go_idle(citizen)


func _gather_capacity(game: SeededGame) -> void:
	var sim := game.sim
	var node := game.world.nodes.find_nearest(ResourceNodes.Kind.TREE,
			game.world.centre(), 350.0, false)
	_check(node != null, "capacity fixture has timber to harvest")
	if node == null:
		return
	var camp := _build(game, "logging_camp", node.position)
	if camp == null:
		return
	_clear_jobs(sim)
	var res := Config.Res.TIMBER
	camp.inventory[res] = camp.capacity() - 1.0
	for i in camp.def.worker_slots:
		sim.production._post_gathering(camp)
	_check(sim.jobs.total_jobs() == 0 and camp.production_reserved == 0.0,
			"one free slot cannot launch three full timber loads")

	camp.inventory[res] = camp.capacity() - Config.CARRY_CAPACITY
	for i in camp.def.worker_slots:
		sim.production._post_gathering(camp)
	_check(sim.jobs.count_for(JobBoard.Kind.GATHER, camp.id, res) == 1
			and camp.production_reserved == Config.CARRY_CAPACITY and camp.space_for(res) == 0.0,
			"one returning load owns the yard's final capacity")
	if sim.jobs.total_jobs() == 0:
		return
	var job := sim.jobs.all_jobs()[0]
	var citizen := sim.citizens[0]
	citizen.workplace_id = camp.id
	citizen.position = job.position
	citizen.job = sim.jobs.best_for(citizen.id, citizen.position, JobBoard.Accept.ANY, camp.id)
	_check(citizen.job == job, "gatherer claims the capacity-backed order")
	sim._abandon(citizen)
	_check(job.claimed_by == -1 and camp.production_reserved == Config.CARRY_CAPACITY,
			"releasing a worker retains the open job's output claim")
	_check(camp.add(res, 5.0) == 0.0,
			"an unrelated deposit cannot steal a returning worker's slot")

	citizen.job = sim.jobs.best_for(citizen.id, job.position, JobBoard.Accept.ANY, camp.id)
	citizen.state = Citizen.State.TRAVELLING
	citizen.pick_up(res, Config.CARRY_CAPACITY, game.registry)
	citizen.position = sim.entrance_of(camp, "att_stock_0")
	citizen.set_goal(citizen.position)
	sim._tick_gather(citizen, 0.1)
	_check(citizen.carrying_amount == 0.0 and citizen.job == null
			and camp.inventory[res] == camp.capacity() and camp.production_reserved == 0.0,
			"returning gatherer deposits in its own slot without stranded overflow")
	sim.production._post_gathering(camp)
	_check(sim.jobs.total_jobs() == 0, "a full producer rests without issuing futile gathering")
	camp.remove(res, Config.CARRY_CAPACITY)
	sim.production._post_gathering(camp)
	_check(sim.jobs.total_jobs() == 1, "spending a load restarts production")
	if sim.jobs.total_jobs() > 0:
		job = sim.jobs.all_jobs()[0]
		citizen.position = job.position
		citizen.job = sim.jobs.best_for(citizen.id, job.position, JobBoard.Accept.ANY, camp.id)
		sim._retire_job(citizen)
		_check(camp.production_reserved == 0.0 and camp.space_for(res) == Config.CARRY_CAPACITY,
				"retiring an invalid gathering job returns its capacity")
		sim._release_reservations(job)
		_check(camp.production_reserved == 0.0, "releasing an output claim twice is harmless")
	_done("_gather_capacity")


func _harvest_capacity(game: SeededGame) -> void:
	var sim := game.sim
	_clear_jobs(sim)
	var farm := _build(game, "farm", game.world.centre() + Vector3(-36, 0, 48))
	if farm == null:
		return
	sim.workforce.update(sim.buildings, sim.citizens, sim.buildings_by_id)
	farm.sync_fields_to_workers()
	var res := Config.Res.FOOD
	var maximum := Config.harvest_load(1.0)
	farm.crop_growth = Config.FARM_HARVEST_AT
	farm.inventory[res] = farm.capacity() - maximum
	for i in farm.def.worker_slots:
		sim.production._post_gathering(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, res) == 1
			and farm.production_reserved == maximum,
			"harvest reserves the ripe yield even when posted before full maturity")
	_check(farm.add(res, 1.0) == 0.0, "incoming food cannot consume promised harvest room")
	if sim.jobs.total_jobs() == 0:
		return
	var job := sim.jobs.all_jobs()[0]
	var citizen := sim.citizens[0]
	citizen.workplace_id = farm.id
	citizen.position = job.position
	citizen.job = sim.jobs.best_for(citizen.id, citizen.position, JobBoard.Accept.ANY, farm.id)
	citizen.state = Citizen.State.TRAVELLING
	citizen.pick_up(res, maximum, game.registry)
	citizen.position = sim.entrance_of(farm, "att_entrance")
	citizen.set_goal(citizen.position)
	sim._tick_harvest(citizen, 0.1)
	_check(citizen.carrying_amount == 0.0 and farm.inventory[res] == farm.capacity()
			and farm.production_reserved == 0.0,
			"a fully ripe harvest fits its reserved capacity exactly")
	farm.remove(res, maximum)
	sim.production._post_gathering(farm)
	_check(farm.production_reserved == maximum, "another harvest reserves newly freed room")
	sim.demolish(farm)
	_check(farm.production_reserved == 0.0 and sim.jobs.total_jobs() == 0,
			"demolition releases production claims and their jobs")
	_done("_harvest_capacity")


func _workshop_sources(game: SeededGame) -> void:
	var sim := game.sim
	_clear_jobs(sim)
	var shop := _build(game, "blacksmith", game.world.centre() + Vector3(-55, 0, 16))
	if shop == null:
		return
	shop.inventory[Config.Res.IRON] = 6.0  # Less than the eight-iron batch.
	shop.inventory[Config.Res.TIMBER] = 8.0
	for store in sim.stores.buildings_storing(Config.Res.IRON):
		if store != shop:
			store.inventory[Config.Res.IRON] = 0.0
	sim.production._post_crafting(shop)
	_check(sim.jobs.total_jobs() == 0, "an iron-starved workshop does not haul its own input to itself")
	_clear_jobs(sim)
	sim.keep.inventory[Config.Res.IRON] = 12.0
	sim.production._post_crafting(shop)
	var incoming := sim.jobs.all_jobs()
	_check(incoming.size() == 1 and incoming[0].source_id == sim.keep.id
			and incoming[0].dest_id == shop.id and incoming[0].res == Config.Res.IRON,
			"a short workshop sources fresh iron from another store")
	_clear_jobs(sim)
	_done("_workshop_sources")


func _incoming_capacity(game: SeededGame) -> void:
	var keep := game.sim.keep
	for res in Config.RES_COUNT:
		keep.inventory[res] = 0.0
	keep.inventory[Config.Res.TIMBER] = keep.capacity() - 12.0
	keep.incoming[Config.Res.STONE] = 12.0
	_check(keep.add(Config.Res.TIMBER, 4.0) == 0.0,
			"stray goods cannot steal capacity promised to a different resource")
	keep.incoming[Config.Res.STONE] = 0.0
	_check(keep.add(Config.Res.STONE, 12.0) == 12.0,
			"the arriving haul fits after releasing its own claim")
	game.sim.cart.load_goods(Config.Res.TIMBER)
	_check(game.sim.cart._load_visual.position == game.registry.attachment("wood_cart", "att_stock_0"),
			"cart cargo follows the generated bed attachment")
	_done("_incoming_capacity")


func _atomic_payment() -> void:
	var stores := Stores.new()
	var keep := Building.new()
	keep.def = BuildingDefs.get_def("keep")
	keep.inventory.resize(Config.RES_COUNT)
	keep.reserved.resize(Config.RES_COUNT)
	stores.register(keep)
	keep.inventory[Config.Res.TIMBER] = 20.0
	keep.inventory[Config.Res.STONE] = 10.0
	keep.reserved[Config.Res.TIMBER] = 15.0
	var cost := {Config.Res.TIMBER: 6.0, Config.Res.STONE: 2.0}
	_check(not stores.try_spend(cost) and keep.inventory[Config.Res.TIMBER] == 20.0
			and keep.inventory[Config.Res.STONE] == 10.0,
			"payment cannot spend reserved goods or partially charge another resource")
	keep.reserved[Config.Res.TIMBER] = 14.0
	_check(stores.try_spend(cost) and keep.inventory[Config.Res.TIMBER] == 14.0
			and keep.inventory[Config.Res.STONE] == 8.0,
			"payment sees current stock before the next UI totals refresh")
	_check(not stores.try_spend(cost) and keep.inventory[Config.Res.STONE] == 8.0,
			"a second payment cannot reuse spent stock")
	keep.free()
	_done("_atomic_payment")


func _fractional_construction(source_amount: float) -> void:
	var game := _new_game(42)
	var sim := game.sim
	var site := _build(game, "house", game.world.centre() + Vector3(-50, 0, -35), false)
	if site == null:
		game.free()
		return
	_clear_jobs(sim)
	var stone := Config.Res.STONE
	var remaining := 0.203575
	for res in site.build_cost:
		site.delivered[res] = float(site.build_cost[res])
	site.delivered[stone] -= remaining
	for store in sim.stores.buildings_storing(stone):
		store.inventory[stone] = 0.0
	sim.keep.inventory[stone] = source_amount
	sim.production._post_construction(site)
	var posted := sim.jobs.all_jobs()
	_check(posted.size() == 1 and posted[0].kind == JobBoard.Kind.HAUL
			and posted[0].source_id == sim.keep.id and posted[0].dest_id == site.id
			and is_equal_approx(posted[0].amount, remaining),
			"construction posts its final fractional load from %.2f available stone" % source_amount)
	if posted.size() != 1:
		game.free()
		return
	var carrier: Citizen = sim.citizens[0]
	carrier.position = sim.entrance_of(sim.keep, "att_cart_bay")
	carrier.job = sim.jobs.best_for(carrier.id, carrier.position, JobBoard.Accept.ANY, -1)
	for tick in 1600:
		if carrier.job == null:
			break
		sim._tick_haul(carrier, Config.MAX_SIM_STEP)
	_check(carrier.job == null and carrier.carrying_amount == 0.0
			and site.materials_complete()
			and absf(sim.keep.inventory[stone] - (source_amount - remaining)) < 0.00001,
			"fractional stone is physically hauled and accounted for without rounding it away")
	sim.production._post_construction(site)
	carrier.job = sim.jobs.best_for(carrier.id, carrier.position, JobBoard.Accept.ANY, -1)
	for tick in 1600:
		if not site.under_construction or carrier.job == null:
			break
		sim._tick_build(carrier, Config.MAX_SIM_STEP)
	_check(not site.under_construction and site.build_progress == 1.0,
			"builders complete the site after its fractional final delivery")
	game.free()
	_done("_fractional_construction")


# ---------------------------------------------------------------------------
# The agricultural year (design/NORTH_STAR.md — "Seasonal farming")
# ---------------------------------------------------------------------------

## Every seasonal fixture records that it reached its own last line.
##
## A GDScript runtime error aborts the function it happens in, leaves
## `_failures` untouched, and the suite goes on to print zero failures over
## checks that never ran. Renaming one signal was enough to delete the function
## guarding the whole feature and still report a single failure. Nothing else
## in this harness notices a fixture that stopped early.
var _completed: Dictionary = {}


func _done(fixture: String) -> void:
	_completed[fixture] = true


func _all_ran(fixtures: Array) -> void:
	for fixture in fixtures:
		_check(_completed.has(fixture), "%s reached its last line" % fixture)


## Put the whole march on a given day of the calendar.
##
## Both counters, because they are the same day by construction and the
## seasonal rules read one while the interface reads the other; a test that
## moved only one would be testing a march that disagreed with its own clock.
func _set_calendar(game: SeededGame, day: float) -> void:
	game.sim.set_day(day)
	game.clock.elapsed_days = day
	game.clock.set_day_marker(floori(day))


## One tick, which is all it takes for the year to turn.
func _turn(game: SeededGame) -> void:
	game.sim.tick(0.1)


## A farm with its full complement of hands and a named amount of crop up.
func _staffed_farm(game: SeededGame, anchor: Vector3) -> Building:
	var farm := _build(game, "farm", anchor)
	if farm == null:
		return null
	game.sim.workforce.update(game.sim.buildings, game.sim.citizens,
			game.sim.buildings_by_id)
	farm.sync_fields_to_workers()
	return farm


func _calendar_shape() -> void:
	var year := Clock.days_per_year()
	_check(year == Config.DAYS_PER_SEASON * 4, "the year is four seasons long")
	_check(Clock.season_index_at(0.0) == Clock.SPRING
			and Clock.season_index_at(11.9) == Clock.SPRING
			and Clock.season_index_at(12.0) == Clock.SUMMER
			and Clock.season_index_at(24.0) == Clock.AUTUMN
			and Clock.season_index_at(35.9) == Clock.AUTUMN
			and Clock.season_index_at(36.0) == Clock.WINTER,
			"the seasons fall on their own twelve-day blocks")
	_check(Clock.season_index_at(float(year)) == Clock.SPRING
			and Clock.year_at(float(year) - 0.1) == 1
			and Clock.year_at(float(year)) == 2,
			"the year turns back to spring and counts on")
	_check(Clock.is_growing_at(0.0) and Clock.is_growing_at(35.9)
			and not Clock.is_growing_at(36.0)
			and not Clock.is_growing_at(47.9)
			and Clock.is_growing_at(48.0),
			"three seasons grow and the fourth does not")
	# Day 40 matters: inside winter the answer wraps to *next* year's frost, and
	# sampling only day 36 hid a version that returned the year length flat,
	# because at day 36 the right answer happens to equal the year length.
	_check(is_equal_approx(Clock.days_to_frost(0.0), 36.0)
			and is_equal_approx(Clock.days_to_frost(35.0), 1.0)
			and is_equal_approx(Clock.days_to_frost(36.0), float(year))
			and is_equal_approx(Clock.days_to_frost(40.0), float(year) - 4.0)
			and is_equal_approx(Clock.days_to_frost(47.5), float(year) - 11.5),
			"the countdown to the frost is the distance to the next winter")
	# The forgiving first winter, and the one after it that is not.
	_check(not Clock.frost_is_hard_at(36.0) and not Clock.frost_is_hard_at(47.9)
			and Clock.frost_is_hard_at(float(year) + 36.0),
			"the opening winter spares the crop and the next one does not")

	# The date line is the only place the interface mentions the calendar, so
	# the deadline has to be legible there or a player cannot see it coming.
	var clock := Clock.new()
	# Year 1's autumn has to read differently from year 2's. A first year whose
	# countdown looked identical and then turned out not to mean anything
	# teaches that the countdown is decoration.
	clock.elapsed_days = 30.0
	_check(clock.season_note() == "mild winter in 6 days"
			and clock.date_text().contains("mild winter in 6 days")
			and clock.date_text().begins_with("Autumn, Year 1"),
			"the opening autumn counts down and says the winter will be mild")
	clock.elapsed_days = float(year) + 30.0
	_check(clock.season_note() == "frost in 6 days"
			and clock.date_text().begins_with("Autumn, Year 2"),
			"a later autumn counts down to a frost that will bite")
	# Half a day in. The countdown rounds *up* — a player told "5 days" who has
	# five and a half is being told the truth; one told "5" who has five and a
	# half days left to run is being hurried, and one told "5" who has 5.9 is
	# being lied to. Sampling only whole days let either rounding pass.
	clock.elapsed_days = float(year) + 30.5
	_check(clock.season_note() == "frost in 6 days",
			"a part-day left over still counts as a whole day of warning")
	clock.elapsed_days = float(year) + 35.2
	_check(clock.season_note() == "frost in 1 day", "the last day says day, not days")
	clock.elapsed_days = 40.0
	_check(clock.season_note() == "mild winter",
			"the first winter says on screen that it is the mild one")
	clock.elapsed_days = float(year) + 40.0
	_check(clock.season_note() == "fields frozen",
			"a hard winter says the fields are frozen")
	clock.elapsed_days = 5.0
	_check(clock.season_note() == "growing", "spring says the fields are growing")
	_done("_calendar_shape")


## The calendar has to reach the simulation at all. Nothing else here can fail
## honestly if this does: an unbound calendar reports an eternal spring, which
## is precisely the decorative-season behaviour this work replaces.
func _calendar_is_wired(game: SeededGame) -> void:
	# Compared against the day this test set, not against `sim.day` — asking
	# whether `calendar_day()` equals `sim.day` is asking whether `sim.day`
	# equals itself, which is true however the accessor is written, including
	# when it has fallen back to an eternal spring.
	_set_calendar(game, 30.0)
	_check(absf(game.sim.production.calendar_day() - 30.0) < 0.01,
			"production reads the simulation's own day counter")
	_done("_calendar_is_wired")


func _crops_only_grow_in_the_growing_season(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the growing-season check has a farm to grow")
		return
	var sim := game.sim

	# High summer.
	_set_calendar(game, 18.0)
	_turn(game)
	farm.set_crop_growth(0.2)
	sim.population.grow_crops(sim.buildings, 1.0)
	_check(is_equal_approx(farm.crop_growth, 0.2 + 1.0 / Config.FARM_GROWTH_DAYS)
			and not farm.dormant,
			"a summer day brings the crop on by one day's growth")

	# Deep in a winter that bites. The sweep zeroes the field on the way in, so
	# put a crop back in the ground afterwards: freezing something that is
	# already at zero proves only that zero does not rise.
	_set_calendar(game, Clock.days_per_year() + 40.0)
	_turn(game)
	farm.crop_growth = 0.4
	var frozen := farm.crop_growth
	sim.population.grow_crops(sim.buildings, 1.0)
	_check(farm.dormant and is_equal_approx(farm.crop_growth, frozen),
			"nothing comes on under the frost, however many days pass")
	sim.population.grow_crops(sim.buildings, 6.0)
	_check(is_equal_approx(farm.crop_growth, frozen),
			"a whole week of winter still brings nothing on")

	# And the thaw.
	_set_calendar(game, Clock.days_per_year() + 50.0)
	_turn(game)
	_check(not farm.dormant, "spring wakes the fields again")
	sim.population.grow_crops(sim.buildings, 1.0)
	_check(farm.crop_growth > frozen, "the crop comes on again once spring returns")
	sim.demolish(farm)
	_done("_crops_only_grow_in_the_growing_season")


func _the_frost_takes_what_is_still_standing(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the frost check has a farm to freeze")
		return

	# The last hour of autumn, in a year whose winter bites.
	var year := float(Clock.days_per_year())
	_set_calendar(game, year + 35.95)
	_turn(game)
	farm.set_crop_growth(1.0)
	_check(not farm.dormant and farm.field_count() > 0,
			"the field is ripe and worked on the eve of the frost")

	# Worked out here from first principles rather than by asking the building
	# again: a ripe field is FARM_HARVEST_TRIPS loads, each load takes
	# 1/FARM_HARVEST_TRIPS of the growth with it, and `harvest_load` sizes a
	# load by what is left. Checking `standing_crop_food()` against
	# `standing_crop_food()` is a check that agrees with any answer at all —
	# replacing the series with a flat `harvest_load(1.0) * 16` (a third too
	# much) passed it happily.
	var expected := 0.0
	for i in Config.FARM_HARVEST_TRIPS:
		expected += Config.CARRY_CAPACITY * lerpf(0.6, 1.25,
				1.0 - float(i) / float(Config.FARM_HARVEST_TRIPS))
	var standing := farm.standing_crop_food()
	_check(is_equal_approx(standing, expected)
			and standing > float(Config.CARRY_CAPACITY) * 8.0,
			"a ripe field is worth %.0f food, the sum of its shrinking loads"
			% standing)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var before := sim.total_resource(Config.Res.FOOD)

	var reported := {"food": -1.0, "farms": 0}
	sim.production.frost_fell.connect(
			func(food: float, farms: int, _where: Vector3) -> void:
				reported.food = food
				reported.farms = farms, CONNECT_ONE_SHOT)

	_set_calendar(game, year + 36.0)
	_turn(game)

	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var after := sim.total_resource(Config.Res.FOOD)
	_check(farm.crop_growth == 0.0 and farm.dormant,
			"the frost strips the standing crop out of the ground")
	# This is the NORTH_STAR sentence itself: unharvested food never enters
	# the granary. It is not moved, not discounted — it is gone.
	_check(is_equal_approx(after, before),
			"nothing the frost took ever reaches a store (%.1f -> %.1f)" % [before, after])
	_check(is_equal_approx(reported.food, expected) and reported.farms == 1
			and is_equal_approx(sim.production.frost_loss, expected),
			"the frost reports what it destroyed, in food (%.1f)" % reported.food)

	# And the field cannot be worked after it.
	sim.production._post_gathering(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, Config.Res.FOOD) == 0,
			"there is nothing to harvest in a frozen field")
	sim.demolish(farm)
	_done("_the_frost_takes_what_is_still_standing")


func _the_first_winter_is_mild(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the mild-winter check has a farm")
		return

	_set_calendar(game, 35.95)
	_turn(game)
	farm.set_crop_growth(1.0)
	_set_calendar(game, 36.0)
	_turn(game)

	_check(farm.crop_growth == 1.0 and sim.production.frost_loss == 0.0,
			"the first winter leaves the standing crop where it is")
	_check(farm.dormant, "the first winter still stops the fields growing")
	farm.inventory[Config.Res.FOOD] = 0.0
	sim.production._post_gathering(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, Config.Res.FOOD) == 1,
			"a late harvest can still be brought in through the mild winter")
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_the_first_winter_is_mild")


## A farm raised after the year turned has never been told what month it is.
## Without the per-review catch-up it sows itself at FARM_INITIAL_GROWTH and
## stands in ripe wheat all winter — the one rule this feature exists to
## enforce, dodged by building a week late.
func _a_farm_raised_in_winter_does_not_stand_in_wheat(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	_set_calendar(game, float(Clock.days_per_year()) + 38.0)
	_turn(game)
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "a farm can be raised in winter")
		return
	var sown := farm.crop_growth
	_check(sown > 0.0, "a new farm sows itself before anyone reviews it")
	var reported := {"food": 0.0}
	sim.production.frost_fell.connect(
			func(food: float, _farms: int, _where: Vector3) -> void:
				reported.food += food, CONNECT_ONE_SHOT)
	sim.production.frost_loss = 0.0
	sim.production._review(farm)
	_check(farm.dormant and farm.crop_growth == 0.0,
			"a farm raised after the frost is told what month it is")
	# What it loses is as real as what the sweep took. Discarding it left the
	# settlement's account of the winter short by whatever had been sown since
	# the year turned, and said nothing about it.
	# Against the crop that was actually sown, not against the other half of
	# the same assignment: `frost_loss` and the signal both carry the same
	# local, so comparing them to each other shows they are wired together and
	# nothing else.
	var expected_late := 0.0
	var left := sown
	var step := 1.0 / float(Config.FARM_HARVEST_TRIPS)
	while left > step * 0.5:
		expected_late += Config.CARRY_CAPACITY * lerpf(0.6, 1.25, left)
		left -= step
	_check(is_equal_approx(reported.food, expected_late)
			and is_equal_approx(sim.production.frost_loss, expected_late),
			"a late frost reports what the sown crop was worth (%.1f food)"
			% reported.food)
	sim.demolish(farm)
	_done("_a_farm_raised_in_winter_does_not_stand_in_wheat")


## Drafting the hands off a farm must not save its crop from the frost.
##
## `standing_crop_food` values only the plots somebody is working, and the frost
## used to treat "worth nothing to report" as "nothing to do" — so an unstaffed
## farm kept a full ripe field through a hard winter and harvested it in spring.
## Pulling the farmhands off in late autumn was a complete answer to the one
## rule this feature exists to enforce, which is the very decision
## design/NORTH_STAR.md names.
func _drafting_the_hands_does_not_save_the_crop(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var year := float(Clock.days_per_year())
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the drafted-hands check has a farm")
		return
	_set_calendar(game, year + 35.0)
	_turn(game)
	farm.set_crop_growth(1.0)

	# Draft every hand away. No plot is worked any more, but the grain is still
	# in the ground and a harvester would still lift a full load off it.
	for worker in farm.workers.duplicate():
		var hand: Citizen = sim.citizens_by_id.get(worker)
		if hand != null:
			hand.workplace_id = -1
	farm.workers.clear()
	farm.sync_fields_to_workers()
	var standing := farm.standing_crop_food()
	_check(farm.field_count() == 0 and farm.crop_growth == 1.0
			and standing > float(Config.CARRY_CAPACITY) * 8.0,
			"an unstaffed ripe field is still worth a full harvest (%.0f food)"
			% standing)

	# Ground, not staffing, is what makes a crop real — so a farm with no plots
	# at all is a different case, and the frost must still clear it rather than
	# leave `crop_growth` standing on a field that does not exist. Ordering the
	# guard off the *valuation* instead of off the crop let exactly that
	# through: nothing to value, so nothing was cleared. A farm can reach that
	# state — `create_fields` gives up when no cell nearby is viable, which is
	# reachable on the larger world sizes.
	var plotless := _build(game, "farm", game.world.centre() + Vector3(-52, 0, -44))
	if plotless == null:
		_check(false, "the plotless-farm check has a second farm")
		return
	plotless.all_plots().clear()
	plotless.fields.clear()
	plotless.crop_growth = 1.0
	_check(plotless.standing_crop_food() == 0.0,
			"a farm with no ground is worth nothing")
	_check(plotless.lose_standing_crop() == 0.0 and plotless.crop_growth == 0.0,
			"and the frost still clears it rather than leaving a phantom crop")
	sim.demolish(plotless)

	var reported := {"food": 0.0}
	sim.production.frost_fell.connect(
			func(food: float, _farms: int, _where: Vector3) -> void:
				reported.food += food, CONNECT_ONE_SHOT)
	_set_calendar(game, year + 36.0)
	_turn(game)
	_check(farm.crop_growth == 0.0,
			"the frost clears unworked ground too")
	# And says so. Valuing the field by its staffing rather than its ground
	# meant the frost destroyed a full harvest and the settlement's account of
	# the winter read zero.
	_check(is_equal_approx(reported.food, standing)
			and is_equal_approx(sim.production.frost_loss, standing),
			"and reports the whole of it (%.0f food)" % reported.food)

	# And it must not come back in spring.
	_set_calendar(game, year + 50.0)
	_turn(game)
	_check(farm.crop_growth < Config.FARM_HARVEST_AT,
			"there is no ripe field waiting in spring for the hands to return")
	sim.demolish(farm)
	_done("_drafting_the_hands_does_not_save_the_crop")


## A farm raised during the *mild* first winter keeps what it sowed.
##
## The per-review catch-up destroys standing crop, and it is guarded by
## `_hard_frost`. Without that guard a farm founded in the tutorial winter
## loses its crop — the exact thing `Config.MILD_WINTERS` exists to prevent —
## and every other check in this file passed with the guard deleted, because
## they all test year 2 or build their farm before the year turns.
func _a_farm_raised_in_the_mild_winter_keeps_its_crop(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	_set_calendar(game, 38.0)
	_turn(game)
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "a farm can be raised in the mild winter")
		return
	var sown := farm.crop_growth
	_check(sown > 0.0, "a new farm sows itself even in the mild winter")
	sim.production._review(farm)
	_check(farm.dormant and is_equal_approx(farm.crop_growth, sown)
			and sim.production.frost_loss == 0.0,
			"the mild winter stops that field without taking it")
	sim.demolish(farm)
	_done("_a_farm_raised_in_the_mild_winter_keeps_its_crop")


## Winter is meant to change what the settlement does, not multiply a number.
## The farmhands are still employed; there is simply no farm work, so they take
## whatever else is on the board.
##
## Note the actual mechanism, because it is not dormancy: `_post_gathering`
## never reads `Building.dormant`. Farm work stops in a hard winter because the
## frost left the field at zero growth and there is nothing in it to fetch. A
## *mild* winter leaves the crop standing and the hands keep harvesting, which
## is intended — finishing a late harvest is exactly what the mild year is for.
## So this is "an empty field frees the hands", not "winter does".
func _winter_frees_the_farmhands(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the winter-labour check has a farm")
		return

	_set_calendar(game, float(Clock.days_per_year()) + 30.0)
	_turn(game)
	farm.set_crop_growth(1.0)
	farm.inventory[Config.Res.FOOD] = 0.0
	sim.production._post_gathering(farm)
	var autumn_work := sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id,
			Config.Res.FOOD)
	_clear_jobs(sim)

	_set_calendar(game, float(Clock.days_per_year()) + 36.0)
	_turn(game)
	sim.production._post_gathering(farm)
	var winter_work := sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id,
			Config.Res.FOOD)
	_check(autumn_work > 0 and winter_work == 0,
			"a frozen field has no work to post where a ripe one had (%d -> %d)"
			% [autumn_work, winter_work])

	# The hands are not sacked, and the board hands them the settlement's other
	# work — which is what "free for something else" has to mean in practice.
	_check(farm.workers.size() > 0, "the frozen farm keeps its hands on the books")
	var hand: Citizen = null
	if not farm.workers.is_empty():
		hand = sim.citizens_by_id.get(farm.workers[0])
	var haul := sim.jobs.post(JobBoard.Kind.HAUL, sim.keep.global_position, 50.0)
	haul.res = Config.Res.TIMBER
	haul.amount = 1.0
	haul.source_id = sim.keep.id
	haul.dest_id = sim.keep.id
	sim.jobs.index(haul)
	var taken: JobBoard.Job = null
	if hand != null:
		taken = sim.jobs.best_for(hand.id, hand.global_position,
				JobBoard.Accept.ANY, farm.id)
	_check(taken == haul,
			"a farmhand with no field work takes the settlement's hauling instead")
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_winter_frees_the_farmhands")


## A save taken in one season and loaded in another has to come back the same
## march. Nothing seasonal is written to the file — it is all re-derived from
## the day counter that was already there — so this is the check that the
## derivation actually happens.
func _the_season_survives_a_save() -> void:
	# Its own march. The fixtures above assign workplaces by hand to exercise
	# the job lifecycle, and a save taken over that state is rejected by
	# `save_validation` for reasons that have nothing to do with the calendar.
	var game := _new_game(42)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the save check has a farm")
		return
	var year := float(Clock.days_per_year())
	# Held by id: `restore_from` frees the simulation this farm belongs to, and
	# the node reference is dead the moment it returns.
	var farm_id := farm.id

	# Saved in autumn with a ripe field, loaded straight back.
	_set_calendar(game, year + 30.0)
	_turn(game)
	farm.set_crop_growth(0.8)
	var autumn_save := SaveGame.capture(game)
	var error := game.restore_from(autumn_save)
	_check(error == "", "a save taken in autumn loads: " + error)
	var reloaded: Building = game.sim.buildings_by_id.get(farm_id)
	game.sim.tick(0.1)
	_check(reloaded != null and is_equal_approx(reloaded.crop_growth, 0.8)
			and not reloaded.dormant
			and game.clock.season() == "Autumn"
			and absf(game.sim.production.calendar_day() - (year + 30.0)) < 0.01,
			"autumn resumes as autumn, with the crop it had")

	# And across the frost: save in autumn, wind the loaded march into winter.
	var winter_save := SaveGame.capture(game)
	error = game.restore_from(winter_save)
	_check(error == "", "a second round trip loads: " + error)
	reloaded = game.sim.buildings_by_id.get(farm_id)
	if reloaded == null:
		_check(false, "the farm survives the round trip")
		return
	_set_calendar(game, year + 36.0)
	game.sim.tick(0.1)
	_check(reloaded.crop_growth == 0.0 and reloaded.dormant
			and game.sim.production.frost_loss > 0.0,
			"a loaded march still meets the frost on the day it falls")

	# A march loaded *during* a hard winter stays frozen and loses nothing
	# more: the frost already took it, and re-running the sweep is a no-op.
	var frozen_save := SaveGame.capture(game)
	error = game.restore_from(frozen_save)
	_check(error == "", "a save taken in a hard winter loads: " + error)
	reloaded = game.sim.buildings_by_id.get(farm_id)
	game.sim.tick(0.1)
	_check(reloaded != null and reloaded.dormant and reloaded.crop_growth == 0.0
			and game.clock.season() == "Winter",
			"a march loaded in winter resumes in winter, still frozen")

	# Loading must apply the frost without announcing it. A farm raised during
	# a hard winter is sown before anyone has told it what month it is, and a
	# save taken inside that window used to come back reporting a frost worth
	# seventy food that had never happened in the march that was saved: a
	# fabricated loss, on a routine resume.
	_set_calendar(game, year + 38.0)
	game.sim.tick(0.1)
	var winter_farm := _staffed_farm(game, game.world.centre() + Vector3(-44, 0, 40))
	if winter_farm == null:
		_check(false, "a farm can be raised in the hard winter")
		game.free()
		return
	var sown := winter_farm.crop_growth
	var winter_farm_id := winter_farm.id
	var phantom := {"fired": false}
	var raw_save := SaveGame.capture(game)
	error = game.restore_from(raw_save)
	_check(error == "" and sown > 0.0,
			"a save taken before that farm was ever reviewed loads: " + error)
	game.sim.production.frost_fell.connect(
			func(_food: float, _farms: int, _where: Vector3) -> void:
				phantom.fired = true)
	game.sim.tick(0.1)
	var raised: Building = game.sim.buildings_by_id.get(winter_farm_id)
	_check(raised != null and raised.crop_growth == 0.0 and raised.dormant
			and not phantom.fired and game.sim.production.frost_loss == 0.0,
			"resuming applies the frost it missed without announcing one")

	# The case that used to cost a player a harvest for saving. A farm whose
	# hands were drafted away kept its ripe field, because nothing valued it —
	# and then loading rebuilt the workforce, so the first sweep after the load
	# valued the field at a full crop and destroyed it. Quitting preserved the
	# harvest; resuming took it. Both sides must now agree, and both at zero.
	_set_calendar(game, year + 30.0)
	game.sim.tick(0.1)
	reloaded = game.sim.buildings_by_id.get(farm_id)
	if reloaded == null:
		_check(false, "the farm is still there to draft")
		game.free()
		return
	reloaded.set_crop_growth(1.0)
	for worker in reloaded.workers.duplicate():
		var hand: Citizen = game.sim.citizens_by_id.get(worker)
		if hand != null:
			hand.workplace_id = -1
	reloaded.workers.clear()
	reloaded.sync_fields_to_workers()
	_set_calendar(game, year + 36.0)
	game.sim.tick(0.1)
	var before_save := reloaded.crop_growth
	var drafted_save := SaveGame.capture(game)
	error = game.restore_from(drafted_save)
	_check(error == "", "a winter save of an unstaffed farm loads: " + error)
	reloaded = game.sim.buildings_by_id.get(farm_id)
	game.sim.tick(0.1)
	_check(reloaded != null and before_save == 0.0
			and reloaded.crop_growth == before_save
			and game.sim.production.frost_loss == 0.0,
			"loading an unstaffed winter farm costs nothing it had not already lost")
	game.free()
	_done("_the_season_survives_a_save")


## Cancel farm work as fast as it is posted: the farmhands have been drafted
## onto something else and the crop stays in the ground.
func _draft_the_farmhands(sim: Simulation) -> void:
	for job in sim.jobs.all_jobs():
		if job.kind != JobBoard.Kind.HARVEST:
			continue
		var holder: Citizen = sim.citizens_by_id.get(job.claimed_by)
		if holder != null:
			sim._abandon(holder)
		sim._release_reservations(job)
		sim.jobs.cancel(job)


## The whole point, measured: a settlement that gets the harvest in eats
## through the winter, and one that drafted its farmhands onto something else
## for the last of autumn is in trouble by spring.
##
## `draft` suppresses farm work through **autumn only**. That matters, and it
## was wrong the first time: cancelling harvests for the whole thirty days made
## the neglected march starve on plain arithmetic — twenty-four people eating
## for a month with nothing coming in — whether or not a frost existed anywhere
## in the game. Measured: with the suppression running all the way through, the
## mild-winter arm ended at 0 food and 14 famine days, identical to the hard
## one. That experiment proved only that people who never harvest go hungry.
##
## Ending the draft with autumn is also the decision NORTH_STAR actually names.
## The hands go back to the fields at the frost; what separates the two arms
## from then on is whether there is anything left in the ground for them.
func _harvest_decides_the_winter(world_seed: int, draft: bool,
		hard_frost: bool = true) -> Dictionary:
	var game := _new_game(world_seed)
	var sim := game.sim
	# Year 1's winter is mild and year 2's bites, so the year is the only knob
	# that changes whether the frost destroys anything. Running the drafted arm
	# in both years is the one way to measure the frost on its own: everything
	# else about the two runs — day of the year, stores, staffing, the crop in
	# the ground, the suppression — is identical.
	var year := float(Clock.days_per_year()) if hard_frost else 0.0
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		game.free()
		return {}

	# Start of autumn in a year whose winter bites, with a ripe field and a
	# fortnight of food in hand — a march that is doing neither well nor badly.
	_set_calendar(game, year + Config.DAYS_PER_SEASON * Clock.AUTUMN)
	sim.tick(0.1)
	farm.set_crop_growth(1.0)
	for b in sim.buildings:
		if b.def.is_storage():
			b.inventory[Config.Res.FOOD] = 0.0
	# Twenty days of food: enough to eat through autumn either way, so the only
	# thing that can decide the winter is whether the crop was carried in.
	sim.keep.inventory[Config.Res.FOOD] = 20.0 * sim.citizens.size() \
			* Config.HUNGER_PER_DAY
	sim.stores.refresh_totals(sim.citizens, sim.buildings)

	var opening := sim.total_resource(Config.Res.FOOD)
	var at_frost := 0.0
	var low := INF
	var starving := 0
	# `frost_loss` is cleared when the season next turns, so the frost has to
	# be caught as it falls. A test that read it at the end would have read
	# zero for both halves and passed either way.
	var destroyed := {"food": 0.0}
	sim.production.frost_fell.connect(
			func(food: float, _farms: int, _where: Vector3) -> void:
				destroyed.food += food)

	# Autumn, then the winter it leads into, then far enough into spring for
	# the first new crop to be worth anything.
	for d in Config.DAYS_PER_SEASON * 2 + 6:
		if draft and d < Config.DAYS_PER_SEASON:
			# Suppress within the day as well; a job posted and claimed inside
			# one tick would otherwise be worked before the day ended.
			var ticks := roundi(Config.DAY_LENGTH / Config.MAX_SIM_STEP)
			for _i in ticks:
				sim.tick(Config.MAX_SIM_STEP)
				_draft_the_farmhands(sim)
				game.clock.elapsed_days += Config.MAX_SIM_STEP / Config.DAY_LENGTH
			await process_frame
		else:
			await _advance_day(game)
		sim.stores.refresh_totals(sim.citizens, sim.buildings)
		var held := sim.total_resource(Config.Res.FOOD)
		low = minf(low, held)
		if d == Config.DAYS_PER_SEASON - 1:
			at_frost = held
		for c in sim.citizens:
			if c.hunger >= 1.0:
				starving += 1
				break

	_invariants(game, "seasons:%s%s" % ["drafted" if draft else "harvested",
			"" if hard_frost else ":mild"])
	var result := {
		"opening": opening, "at_frost": at_frost, "low": low,
		"final": sim.total_resource(Config.Res.FOOD),
		"frost_loss": destroyed.food,
		"starving_days": starving,
		"famine_days": sim.population.famine_days(),
		"population": sim.citizens.size(),
	}
	game.free()
	return result


## A full year, run day by day from the opening morning, on the settlement the
## game actually starts you with.
func _a_full_year(world_seed: int) -> void:
	var game := _new_game(world_seed)
	var sim := game.sim
	# The same small established economy the long run starts from: two farms,
	# somewhere to put the grain, and the trades that keep building going. A
	# year is a test of whether the harvest carries the winter, not of whether
	# the opening keep can feed twenty people unaided for forty-eight days.
	var centre := game.world.centre()
	_build(game, "farm", centre + Vector3(-36, 0, 48))
	_build(game, "farm", centre + Vector3(44, 0, 48))
	_build(game, "granary", centre + Vector3(40, 0, 4))
	_build(game, "house", centre + Vector3(-42, 0, 8))
	_build(game, "house", centre + Vector3(8, 0, 52))
	for pair in [["logging_camp", ResourceNodes.Kind.TREE], ["quarry", ResourceNodes.Kind.STONE]]:
		var node := game.world.nodes.find_nearest(pair[1], centre, 350.0, false)
		if node != null:
			_build(game, pair[0], node.position)
	var seen: Array[String] = []
	var food_by_season: Dictionary = {}
	var dormant_in: Dictionary = {}
	var awake_in: Dictionary = {}
	var winter_harvest_jobs := 0
	var days := Clock.days_per_year()

	for d in days:
		await _advance_day(game)
		var season := game.clock.season()
		if seen.is_empty() or seen[seen.size() - 1] != season:
			seen.append(season)
		sim.stores.refresh_totals(sim.citizens, sim.buildings)
		food_by_season[season] = sim.total_resource(Config.Res.FOOD)
		# The farms' own state, not the clock's name for the month. Everything
		# else here would be satisfied by a calendar that turned on screen and
		# reached nothing — which is the bug this work exists to fix, so the
		# whole-year run has to be the thing that would notice.
		for b in sim.buildings:
			if b.under_construction or not b.def.is_farm():
				continue
			if b.dormant:
				dormant_in[season] = true
			else:
				awake_in[season] = true
		if season == "Winter":
			for job in sim.jobs.all_jobs():
				if job.kind == JobBoard.Kind.HARVEST:
					winter_harvest_jobs += 1

	_check(", ".join(seen).begins_with("Spring, Summer, Autumn, Winter")
			and seen.size() == 5 and seen[4] == "Spring",
			"a full year runs through all four seasons and comes round: %s" % [seen])
	_check(is_equal_approx(game.sim.day, game.clock.elapsed_days)
			and game.clock.year() == 2,
			"the simulation and the clock finish the year on the same day")
	_check(sim.citizens.size() >= Config.START_CITIZENS
			and sim.population.famine_days() < 3.0,
			"the opening settlement comes through its first year alive "
			+ "(%d people, %.1f famine days, %.0f food)"
			% [sim.citizens.size(), sim.population.famine_days(),
			sim.total_resource(Config.Res.FOOD)])
	_check(dormant_in.has("Winter") and not awake_in.has("Winter")
			and awake_in.has("Spring") and awake_in.has("Summer")
			and awake_in.has("Autumn") and not dormant_in.has("Spring")
			and not dormant_in.has("Summer") and not dormant_in.has("Autumn"),
			"across the real year the fields are dormant in winter and only "
			+ "in winter (dormant %s, awake %s)"
			% [dormant_in.keys(), awake_in.keys()])
	_invariants(game, "seasons:year")
	print("METRIC first year seed %d: %s  winter harvest jobs %d"
			% [world_seed, food_by_season, winter_harvest_jobs])
	game.free()
	_done("_a_full_year")


# ---------------------------------------------------------------------------
# Winter labour (design/NORTH_STAR.md — "Seasonal farming")
# ---------------------------------------------------------------------------

## Put every farm's ground at `value`.
##
## This is how the "before" arm of every experiment below is built, and it is
## deliberately not "cancel the jobs as they are posted". That was the first
## version and it was contaminated: `_abandon` on a citizen who had already
## claimed a tillage order sends them home, drops their route and perturbs the
## rest of the economy, so the suppressed arm diverged from the ploughing arm for
## reasons that had nothing to do with ploughing — measured, it moved the
## suppressed arm's own open-job count when nothing but `TILLAGE_PRIORITY`
## changed. A baseline that moves when the feature is tuned is not a baseline.
##
## Standing the ground at 1.0 instead makes `Production._post_tillage` decline to
## post at all, so not one tillage job is ever created and not one citizen is
## ever interrupted. Both arms then run the identical `_advance_day` path. The
## ground is put back to 0.0 before the year turns, so the suppressed arm sows
## nothing — which is the state of the game before any of this existed.
func _set_tilth(sim: Simulation, value: float) -> void:
	for b in sim.buildings:
		if b.def.is_farm():
			b.tilth = value


## Run one winter, day by day, and report what the settlement did with it.
##
## The march is stood at the first morning of a winter in year 2, so the frost
## bites, with granaries that carried the harvest in — forty days of food. That
## last part is deliberate and it is not padding: a starving march measures
## starvation, not labour, and the seed-corn rule means it could not sow anyway.
##
## Sampled in the middle of the day, not at midnight. `_advance_day` returns to
## the same hour it started at, and at midnight the whole settlement is asleep
## and every one of them holds no job — an idleness count taken there would have
## read "everybody idle" in every arm, in every season, for ever.
func _one_winter(world_seed: int, plough: bool) -> Dictionary:
	var game := _new_game(world_seed)
	var sim := game.sim
	var centre := game.world.centre()
	_build(game, "farm", centre + Vector3(-36, 0, 48))
	_build(game, "farm", centre + Vector3(44, 0, 48))
	_build(game, "granary", centre + Vector3(40, 0, 4))
	_build(game, "house", centre + Vector3(-42, 0, 8))
	for pair in [["logging_camp", ResourceNodes.Kind.TREE],
			["quarry", ResourceNodes.Kind.STONE]]:
		var node := game.world.nodes.find_nearest(pair[1], centre, 350.0, false)
		if node != null:
			_build(game, pair[0], node.position)

	var year := float(Clock.days_per_year())
	var winter_day := year + float(Config.DAYS_PER_SEASON * Clock.WINTER)
	_set_calendar(game, winter_day + 0.45)
	sim.tick(0.1)
	# A march that carried its harvest in: enough to eat through the winter and
	# leave seed at the end of it, and *no more than half* of each granary.
	#
	# Both halves of that matter. Too little and the experiment measures
	# starvation rather than labour, and the seed-corn rule means it could not
	# sow anyway. Too much and it measures nothing at all: filled to forty days,
	# every store was saturated, `Production._post_gathering` refuses to post a
	# reaper for a farm with no room for the load (`space_for`), and the spring
	# the whole feature exists to bring forward had nowhere to put a harvest.
	# Measured that way both arms came out of the spring poorer than they went
	# in, and the ploughed one was poorer by exactly its seed bill.
	#
	# Filled through `add`, so nothing is stuffed past a capacity and the storage
	# invariants still mean something.
	for b in sim.buildings:
		if b.def.is_storage():
			b.add(Config.Res.FOOD, minf(b.capacity() * 0.5,
					14.0 * sim.citizens.size() * Config.HUNGER_PER_DAY))
	sim.stores.refresh_totals(sim.citizens, sim.buildings)

	var idle_high := 0
	var idle_low := 1 << 30
	var open_low := 1 << 30
	var open_high := 0
	var ploughing_days := 0
	var hands_on_ground := 0
	var idle_total := 0
	var work_days := 0
	var tilth_high := 0.0

	# One day short of the season. `_advance_day` runs a whole day, so a full
	# twelve from the first morning of winter would carry the march over the
	# turn into spring and take the measurement of the sowing with it — which it
	# did, and both arms then reported the same field because the reading was
	# taken after the event it was meant to catch.
	for d in Config.DAYS_PER_SEASON - 1:
		if not plough:
			_set_tilth(sim, 1.0)
		await _advance_day(game)
		var idle := 0
		var ploughing := 0
		for c in sim.citizens:
			if c.immigrant:
				continue
			if c.job == null:
				idle += 1
			elif c.job.kind == JobBoard.Kind.TILL:
				ploughing += 1
		idle_high = maxi(idle_high, idle)
		idle_low = mini(idle_low, idle)
		open_low = mini(open_low, sim.jobs.open_jobs())
		open_high = maxi(open_high, sim.jobs.open_jobs())
		hands_on_ground += ploughing
		idle_total += idle
		if sim.jobs.open_jobs() > 0 or ploughing > 0:
			work_days += 1
		if ploughing > 0:
			ploughing_days += 1
		# Only in the arm where it means anything. In the suppressed arm the
		# ground is held at 1.0 by the fixture, and reporting that as a
		# measurement would have been the test reading back its own setup.
		if plough:
			for b in sim.buildings:
				if b.def.is_farm():
					tilth_high = maxf(tilth_high, b.tilth)

	# The turn into spring, and then far enough into it for the sowing to be
	# worth something in a granary rather than only in the ground.
	if not plough:
		# Back to bare ground, so the suppressed arm sows nothing at the turn.
		_set_tilth(sim, 0.0)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var before_sowing := sim.total_resource(Config.Res.FOOD)
	var winter_food := before_sowing
	_set_calendar(game, year * 2.0 + 0.45)
	sim.tick(0.1)
	var sown := 0.0
	for b in sim.buildings:
		if b.def.is_farm():
			sown = maxf(sown, b.crop_growth)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var seed_spent := before_sowing - sim.total_resource(Config.Res.FOOD)
	# A full spring, not a week of it. The winter's work buys an earlier start to
	# the harvest, and what that is worth can only be read once the season it
	# belongs to has run: over eight days the seed bill was still in front of
	# the grain it bought.
	var first_harvest := -1
	for d in Config.DAYS_PER_SEASON:
		await _advance_day(game)
		if first_harvest < 0:
			for job in sim.jobs.all_jobs():
				if job.kind == JobBoard.Kind.HARVEST:
					first_harvest = d
					break
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	_invariants(game, "winter:%s" % ["ploughed" if plough else "idle"])
	var result := {
		"population": sim.citizens.size(),
		"idle_high": idle_high, "idle_low": idle_low,
		"open_low": open_low, "open_high": open_high,
		"ploughing_days": ploughing_days, "hands_on_ground": hands_on_ground,
		"idle_total": idle_total, "work_days": work_days,
		"winter_days": Config.DAYS_PER_SEASON - 1,
		"tilth_high": tilth_high, "sown": sown, "seed_spent": seed_spent,
		"winter_food": winter_food,
		"first_harvest_day": first_harvest,
		"spring_food": sim.total_resource(Config.Res.FOOD),
	}
	game.free()
	_done("_one_winter")
	return result


## Winter cannot be reaped, and a sown field is not a ripe one.
##
## The frost's rule is that everything still in the ground when winter arrives
## is destroyed and never reaches a granary. Winter fieldwork is only allowed to
## exist if it cannot be a way round that, so this measures the two things that
## would make it one: food arriving in the settlement during the frozen season,
## and a field that can be reaped the moment the year turns.
func _winter_work_is_never_a_harvest(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(-50, 0, -34))
	if farm == null:
		_check(false, "the winter-harvest check has a farm")
		return
	var year := float(Clock.days_per_year())
	_set_calendar(game, year + float(Config.DAYS_PER_SEASON * Clock.WINTER) + 2.0)
	_turn(game)
	_check(farm.dormant and farm.crop_growth == 0.0,
			"the frost has left this field bare to work on")

	# A whole winter's ploughing, as if the hands had done it.
	farm.tilth = 1.0
	farm.inventory[Config.Res.FOOD] = 0.0
	_clear_jobs(sim)
	sim.production._post_gathering(farm)
	sim.production._post_tillage(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, Config.Res.FOOD) == 0
			and sim.jobs.count_for(JobBoard.Kind.TILL, farm.id, -1) == 0
			and farm.crop_growth == 0.0
			and farm.inventory[Config.Res.FOOD] == 0.0,
			"fully broken ground posts no reaper, no further ploughing, and "
			+ "holds no grain")

	# Spring. The march has food, so there is seed to sow with.
	sim.keep.inventory[Config.Res.FOOD] = 40.0 * sim.citizens.size()
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var before := sim.total_resource(Config.Res.FOOD)
	_set_calendar(game, year * 2.0)
	_turn(game)
	_check(not farm.dormant and farm.tilth == 0.0
			and is_equal_approx(farm.crop_growth, Config.TILLAGE_SOWING),
			"the winter's ploughing is sown on the first tick of spring "
			+ "(growth %.3f)" % farm.crop_growth)
	# Totals are a cache over the buildings and the seed came straight out of
	# them, so ask for them again before reading. A check taken off the stale
	# figure would have read "no seed spent" whatever the rule did.
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var seed_spent := before - sim.total_resource(Config.Res.FOOD)
	_check(is_equal_approx(seed_spent, Config.TILLAGE_SEED_FOOD),
			"and the seed corn it swallowed came out of the granaries "
			+ "(%.1f food)" % seed_spent)
	_clear_jobs(sim)
	sim.production._post_gathering(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, Config.Res.FOOD) == 0,
			"a field that came through the winter prepared is ready, not ripe: "
			+ "nobody can reap it on the first morning of spring")
	# And it is ready: a couple of days of real growth and it is reapable, which
	# is the whole of what the winter bought.
	sim.population.grow_crops(sim.buildings, 2.0)
	_clear_jobs(sim)
	sim.production._post_gathering(farm)
	_check(sim.jobs.count_for(JobBoard.Kind.HARVEST, farm.id, Config.Res.FOOD) == 1,
			"two days of spring and the prepared field is worth reaping")
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_winter_work_is_never_a_harvest")


## Broken ground with nothing to sow in it grows nothing.
##
## The seed-corn rule, measured on its own. A march that ate its way through the
## winter can plough all it likes and comes out of it with bare earth, which is
## what stops winter labour from being a rescue for the march the frost beat.
func _broken_ground_needs_seed(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(52, 0, 36))
	if farm == null:
		_check(false, "the seed-corn check has a farm")
		return
	var year := float(Clock.days_per_year())

	# Year 2's winter, ploughed, with the granaries empty.
	_set_calendar(game, year + float(Config.DAYS_PER_SEASON * Clock.WINTER) + 1.0)
	_turn(game)
	for b in sim.buildings:
		b.inventory[Config.Res.FOOD] = 0.0
		b.larder = 0.0
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	farm.tilth = 1.0
	_set_calendar(game, year * 2.0)
	_turn(game)
	_check(farm.crop_growth == 0.0 and farm.tilth == 0.0,
			"a march with nothing to sow comes out of the winter with bare "
			+ "earth (growth %.3f)" % farm.crop_growth)

	# The same farm, the same winter's work, one year on, with grain in hand.
	_set_calendar(game, year * 2.0 + float(Config.DAYS_PER_SEASON * Clock.WINTER) + 1.0)
	_turn(game)
	sim.keep.inventory[Config.Res.FOOD] = 40.0 * sim.citizens.size()
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	farm.tilth = 1.0
	_set_calendar(game, year * 3.0)
	_turn(game)
	_check(is_equal_approx(farm.crop_growth, Config.TILLAGE_SOWING),
			"and the same work sows the same field when there is seed for it "
			+ "(growth %.3f)" % farm.crop_growth)

	# Half the winter's work is worth half the sowing and half the seed: the
	# payoff is the labour, not a threshold somebody crossed.
	_set_calendar(game, year * 3.0 + float(Config.DAYS_PER_SEASON * Clock.WINTER) + 1.0)
	_turn(game)
	sim.keep.inventory[Config.Res.FOOD] = 40.0 * sim.citizens.size()
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	farm.tilth = 0.5
	var before := sim.total_resource(Config.Res.FOOD)
	_set_calendar(game, year * 4.0)
	_turn(game)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var half_seed := before - sim.total_resource(Config.Res.FOOD)
	_check(is_equal_approx(farm.crop_growth, Config.TILLAGE_SOWING * 0.5)
			and is_equal_approx(half_seed, Config.TILLAGE_SEED_FOOD * 0.5),
			"half a winter's ploughing sows half the field for half the seed "
			+ "(growth %.3f, seed %.1f)" % [farm.crop_growth, half_seed])
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_broken_ground_needs_seed")


## Real work outbids winter work, everywhere in a settlement.
##
## The board scores priority against travel, so "lower priority" is not on its
## own an answer — a cheap job far away loses to an expensive one underfoot. The
## distances here are the ones that matter: a tillage job at the worker's feet
## against a haul and a building site right across a march.
func _real_work_outbids_winter_work(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(-58, 0, 26))
	if farm == null:
		_check(false, "the priority check has a farm")
		return
	_set_calendar(game, float(Clock.days_per_year())
			+ float(Config.DAYS_PER_SEASON * Clock.WINTER) + 3.0)
	_turn(game)
	_clear_jobs(sim)
	sim.production._post_tillage(farm)
	var tillage: JobBoard.Job = null
	for job in sim.jobs.all_jobs():
		if job.kind == JobBoard.Kind.TILL:
			tillage = job
	if tillage == null:
		_check(false, "winter posts ground to break")
		return
	var hand := sim.citizens[0]
	hand.workplace_id = -1
	hand.position = tillage.position
	hand.global_position = tillage.position

	# A haul and a building site, both a long way off.
	var far := tillage.position + Vector3(120, 0, 0)
	var haul := sim.jobs.post(JobBoard.Kind.HAUL, far, 50.0)
	haul.res = Config.Res.TIMBER
	haul.amount = 1.0
	haul.source_id = sim.keep.id
	haul.dest_id = sim.keep.id
	sim.jobs.index(haul)
	var picked := sim.jobs.best_for(hand.id, hand.global_position,
			JobBoard.Accept.ANY, -1)
	_check(picked == haul,
			"a haul 120 m away still outbids ploughing at a worker's feet")
	sim.jobs.release(picked)
	sim.jobs.cancel(haul)

	var site := sim.jobs.post(JobBoard.Kind.BUILD,
			tillage.position + Vector3(190, 0, 0), 68.0)
	site.dest_id = sim.keep.id
	site.res = -1
	sim.jobs.index(site)
	picked = sim.jobs.best_for(hand.id, hand.global_position,
			JobBoard.Accept.ANY, -1)
	_check(picked == site,
			"and so does a building site 190 m away")
	sim.jobs.release(picked)
	sim.jobs.cancel(site)

	# The check above is only worth anything if the tillage job was a real
	# candidate all along. With nothing else on the board it must be taken —
	# otherwise the two results above would have been satisfied by a filter
	# that never offered it in the first place.
	picked = sim.jobs.best_for(hand.id, hand.global_position,
			JobBoard.Accept.ANY, -1)
	_check(picked == tillage,
			"with nothing else going, the same hand takes the ploughing")
	sim.jobs.release(picked)
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_real_work_outbids_winter_work")


## Ploughing exists in winter and nowhere else, and only on ground worth it.
func _tillage_belongs_to_winter(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(30, 0, -56))
	if farm == null:
		_check(false, "the season check has a farm")
		return
	var year := float(Clock.days_per_year())
	var posted := {}
	for season in [Clock.SPRING, Clock.SUMMER, Clock.AUTUMN, Clock.WINTER]:
		_set_calendar(game, year + float(Config.DAYS_PER_SEASON * season) + 1.0)
		_turn(game)
		farm.crop_growth = 0.0
		farm.tilth = 0.0
		_clear_jobs(sim)
		sim.production._post_tillage(farm)
		posted[Clock.SEASONS[season]] = sim.jobs.count_for(
				JobBoard.Kind.TILL, farm.id, -1)
	_check(int(posted["Winter"]) > 0 and int(posted["Spring"]) == 0
			and int(posted["Summer"]) == 0 and int(posted["Autumn"]) == 0,
			"ground is broken in winter and in no other season: %s" % [posted])

	# Still winter, but the field is standing — a mild year, or a harvest that
	# ran late. Ploughing round a crop buys nothing, because the sowing only
	# ever raises growth, and a job that cannot pay is the busywork this must
	# not be.
	#
	# The figure is deliberately *small*. A gate written at
	# `crop_growth >= TILLAGE_SOWING` passes a test that stands the field above
	# the sowing and then charges a whole winter's seed bill for a field reaped
	# down to 0.42 — measured, that cost the mild-winter arm of
	# `_harvest_decides_the_winter` six food a year. A quarter-grown field is
	# standing crop and is not ground to break.
	_clear_jobs(sim)
	for standing in [Config.TILLAGE_SOWING + 0.05, 0.25, 0.01]:
		farm.crop_growth = standing
		farm.tilth = 0.0
		_clear_jobs(sim)
		sim.production._post_tillage(farm)
		_check(sim.jobs.count_for(JobBoard.Kind.TILL, farm.id, -1) == 0,
				"a field standing at %.2f is not ground to break" % standing)

	# And a farm whose hands have gone has no field to prepare.
	# A ceiling across the whole march, not only per farm. `best_for` scores every
	# open job for every job-seeking citizen, and winter is when almost everybody
	# is job-seeking, so a cap that multiplies by the number of farms is not a
	# cap. Filled here with orders belonging to other sites, so what is being
	# tested is the settlement-wide tally and not this farm's own.
	_clear_jobs(sim)
	farm.crop_growth = 0.0
	farm.tilth = 0.0
	for i in Config.TILLAGE_JOBS_MAX:
		var filler := sim.jobs.post(JobBoard.Kind.TILL, sim.keep.global_position,
				Config.TILLAGE_PRIORITY)
		filler.res = -1
		filler.dest_id = sim.keep.id + 1000 + i
		sim.jobs.index(filler)
	sim.production._post_tillage(farm)
	_check(sim.jobs.count_of_kind(JobBoard.Kind.TILL) == Config.TILLAGE_JOBS_MAX
			and sim.jobs.count_for(JobBoard.Kind.TILL, farm.id, -1) == 0,
			"a board already carrying %d orders takes no more ploughing"
			% Config.TILLAGE_JOBS_MAX)
	_clear_jobs(sim)
	farm.crop_growth = 0.0
	for worker in farm.workers.duplicate():
		var held: Citizen = sim.citizens_by_id.get(worker)
		if held != null:
			held.workplace_id = -1
	farm.workers.clear()
	farm.sync_fields_to_workers()
	sim.production._post_tillage(farm)
	_check(farm.field_count() == 0
			and sim.jobs.count_for(JobBoard.Kind.TILL, farm.id, -1) == 0,
			"and ground that has gone back to grass is nobody's winter work")
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_tillage_belongs_to_winter")


## One spell of work moves the ground, and moves it on the farm it was posted
## for — the whole loop, from claim to broken earth.
func _a_spell_of_ploughing(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(-30, 0, -50))
	if farm == null:
		_check(false, "the ploughing loop has a farm")
		return
	_set_calendar(game, float(Clock.days_per_year())
			+ float(Config.DAYS_PER_SEASON * Clock.WINTER) + 4.0)
	_turn(game)
	_clear_jobs(sim)
	sim.production._post_tillage(farm)
	var hand := sim.citizens[0]
	hand.workplace_id = -1
	hand.job = sim.jobs.best_for(hand.id, hand.global_position,
			JobBoard.Accept.ANY, -1)
	if hand.job == null or hand.job.kind != JobBoard.Kind.TILL:
		_check(false, "an idle hand can claim winter fieldwork")
		return
	_check(hand.job.describe() == "Break ground for spring",
			"the job says what it is: %s" % hand.job.describe())

	# Stand the worker on the plot the job chose and let the spell run out.
	sim._tick_till(hand, 0.01)
	var plot := hand.job.target
	_check(plot != Vector3.INF and farm.fields.has(plot),
			"the ploughman is sent to one of this farm's own plots")
	hand.position = plot
	hand.global_position = plot
	hand.set_goal(plot)
	sim._tick_till(hand, 0.01)
	_check(hand.state == Citizen.State.WORKING
			and hand.task_label == "breaking ground",
			"arriving at the plot starts the spell")
	var before := farm.tilth
	# The settlement's whole larder, before and after a real spell of work. This
	# is the check that stands between winter fieldwork and the frost: the rule
	# is that nothing the frozen season produces reaches a granary, and the way
	# that rule gets broken is a `_deposit` creeping into `_tick_till`. Measured
	# on the state of the building, not on the absence of a line of code.
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var larder_before := sim.total_resource(Config.Res.FOOD)
	var farm_food_before := farm.inventory[Config.Res.FOOD]
	sim._tick_till(hand, Config.TILLAGE_SECONDS + 1.0)
	_check(is_equal_approx(farm.tilth - before, Config.TILLAGE_STEP)
			and hand.job == null and hand.carrying_amount == 0.0,
			"a finished spell breaks %.4f of the ground and carries nothing "
			% (farm.tilth - before) + "home")
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	_check(is_equal_approx(sim.total_resource(Config.Res.FOOD), larder_before)
			and is_equal_approx(farm.inventory[Config.Res.FOOD],
					farm_food_before),
			"and puts not one grain into the settlement: %.2f food before, "
			% larder_before + "%.2f after"
			% sim.total_resource(Config.Res.FOOD))

	# Broken ground is not a crop. Nothing about the field has grown and the
	# frost's rule is untouched.
	_check(farm.crop_growth == 0.0 and farm.dormant,
			"and the field is still frozen and still bare")

	# The year turning takes the work with it, on both sides of the board: the
	# ploughman caught by the spring is not left breaking ground in a field that
	# has woken up, and the orders nobody ever got to do not sit there until next
	# winter. They used to: nothing cancelled an unclaimed TILL job, so it kept
	# counting against the following winter's `TILLAGE_HANDS` cap and cost a
	# wasted claim-and-retire to whichever idle citizen bid for it in the spring.
	sim.production._post_tillage(farm)
	sim.production._post_tillage(farm)
	hand.job = sim.jobs.best_for(hand.id, hand.global_position,
			JobBoard.Accept.ANY, -1)
	var claimed := hand.job
	_check(claimed != null and claimed.kind == JobBoard.Kind.TILL
			and sim.jobs.count_of_kind(JobBoard.Kind.TILL) == 2,
			"two orders out, one of them claimed, before the year turns")
	_set_calendar(game, float(Clock.days_per_year()) * 2.0)
	_turn(game)
	_check(sim.jobs.count_of_kind(JobBoard.Kind.TILL) == 1,
			"spring clears the ploughing nobody claimed (%d left)"
			% sim.jobs.count_of_kind(JobBoard.Kind.TILL))
	sim._tick_till(hand, 0.01)
	_check(claimed != null and hand.job == null and claimed.cancelled
			and sim.jobs.count_of_kind(JobBoard.Kind.TILL) == 0,
			"and the ploughman who held one puts it down himself")
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_a_spell_of_ploughing")


## What a file carries, and what it does not.
##
## A march saved in mid-winter keeps the ground it had broken: the file carries
## `tilth`, and the first tick after the load (where `_turn_the_year` sees a
## fresh season counter) does not wipe it.
func _tilth_and_the_save_file() -> void:
	var game := _new_game(42)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(42, 0, -30))
	if farm == null:
		_check(false, "the tilth save check has a farm")
		game.free()
		return
	var farm_id := farm.id
	var year := float(Clock.days_per_year())
	_set_calendar(game, year + float(Config.DAYS_PER_SEASON * Clock.WINTER) + 3.0)
	sim.tick(0.1)
	farm.tilth = 0.9

	var winter_save := SaveGame.capture(game)
	var error := game.restore_from(winter_save)
	_check(error == "",
			"a save taken over a march with broken ground still loads: " + error)
	var reloaded: Building = game.sim.buildings_by_id.get(farm_id)
	game.sim.tick(0.1)
	if reloaded == null:
		_check(false, "the farm survives the winter round trip")
		game.free()
		return
	# Asked of the file as well as of the reloaded farm. "tilth came back as
	# 0.9" alone would not separate a restore from a value that was never
	# touched; the key has to be in the file.
	var saved_entry := {}
	for entry in winter_save.get("buildings", []):
		if int(entry.get("id", -1)) == farm_id:
			saved_entry = entry
	_check(is_equal_approx(float(saved_entry.get("tilth", -1.0)), 0.9),
			"the file carries the winter's ploughing")
	_check(reloaded.dormant and is_equal_approx(reloaded.tilth, 0.9),
			"and a march saved in winter comes back frozen with its ground "
			+ "still broken, a tick after loading (tilth %.2f)" % reloaded.tilth)

	# The read side on its own. A restore that names tilth restores it; one
	# that does not (an older file) says unbroken, rather than keeping whatever
	# this object happened to hold.
	var entry := {"inventory": reloaded.inventory.duplicate(),
			"crop_growth": reloaded.crop_growth, "larder": reloaded.larder,
			"workers": reloaded.workers.duplicate(),
			"residents": reloaded.residents.duplicate(),
			"tilth": 0.7}
	reloaded.apply_state(entry)
	_check(is_equal_approx(reloaded.tilth, 0.7),
			"apply_state restores the tilth a file names")
	entry.erase("tilth")
	reloaded.apply_state(entry)
	_check(reloaded.tilth == 0.0,
			"and a file that names none restores unbroken ground")
	game.free()
	_done("_tilth_and_the_save_file")


## Each winter's work starts from bare ground — except on the tick after a load.
##
## Two rules in one fixture because they are one line of code, and that line has
## to say both things at once. Tilth is spent by the spring that follows the
## winter it was earned in and by no other, so the turn into winter clears it.
## But a march *resuming* a winter save arrives at that same turn with its season
## counter unset, and clearing there would destroy the very ploughing the file
## had just restored. It is the mistake that ruled `crop_growth` out as a home
## for this in the first place, and it was made again one branch away from it:
## with `"tilth": b.tilth` added to `SaveGame._capture_building`, a winter save
## restored 0.9 and was back to 0.0 one tick later, with the whole suite green.
func _tilth_does_not_bank(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(58, 0, -18))
	if farm == null:
		_check(false, "the tilth-reset check has a farm")
		return
	var year := float(Clock.days_per_year())

	# Autumn of a year whose winter bites, carrying ploughing it cannot have.
	_set_calendar(game, year * 2.0 + float(Config.DAYS_PER_SEASON * Clock.AUTUMN))
	_turn(game)
	farm.tilth = 0.8
	_set_calendar(game, year * 2.0 + float(Config.DAYS_PER_SEASON * Clock.WINTER))
	_turn(game)
	_check(farm.tilth == 0.0,
			"the turn into winter starts the season's work from bare ground "
			+ "(tilth %.2f)" % farm.tilth)

	# The same turn, reached the way a load reaches it: a season counter that
	# has never been set, three days into a winter, with ploughing to keep.
	farm.tilth = 0.65
	_set_calendar(game, year * 2.0
			+ float(Config.DAYS_PER_SEASON * Clock.WINTER) + 3.0)
	sim.production._season = -1
	sim.production._season_year = -1
	_turn(game)
	_check(is_equal_approx(farm.tilth, 0.65) and farm.dormant,
			"and a march resuming a winter keeps the ploughing its file "
			+ "carried (tilth %.2f)" % farm.tilth)
	farm.tilth = 0.0
	_clear_jobs(sim)
	sim.demolish(farm)
	_done("_tilth_does_not_bank")


## Seed is never spent on a sowing the field would not notice.
##
## `sow_prepared_ground` refuses to plough a standing crop back in, and the seed
## has to be refused with it. Taking the grain first and testing afterwards meant
## a march paid a full winter's seed bill for a field it could not improve —
## which is the same money-for-nothing the standing-crop gate now prevents at
## the posting end, tested here at the spending end because both ends have to
## hold: the gate reads the farm when the job is posted, and this reads it again
## twelve days later when the year turns.
func _seed_is_not_spent_for_nothing(game: SeededGame) -> void:
	_clear_jobs(game.sim)
	var sim := game.sim
	var farm := _staffed_farm(game, game.world.centre() + Vector3(-22, 0, 58))
	if farm == null:
		_check(false, "the wasted-seed check has a farm")
		return
	var year := float(Clock.days_per_year())
	_set_calendar(game, year + float(Config.DAYS_PER_SEASON * Clock.WINTER) + 2.0)
	_turn(game)
	sim.keep.inventory[Config.Res.FOOD] = 40.0 * sim.citizens.size()
	sim.stores.refresh_totals(sim.citizens, sim.buildings)

	# Part-broken ground under a part-reaped crop: the sowing it would lay down
	# is worth less than what is already standing there.
	farm.tilth = 0.4
	farm.crop_growth = 0.30
	var standing := farm.crop_growth
	var before := sim.total_resource(Config.Res.FOOD)
	_set_calendar(game, year * 2.0)
	_turn(game)
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	var spent := before - sim.total_resource(Config.Res.FOOD)
	_check(spent == 0.0 and farm.tilth == 0.0
			and farm.crop_growth >= standing,
			"ground worth less than the crop already on it costs no seed "
			+ "(%.1f food spent, growth %.2f)" % [spent, farm.crop_growth])
	# And it comes out of grain nobody has already promised. `Stores.consume`,
	# which is how this was written first, goes through `Building.remove` and
	# looks at `inventory` alone: it will strip a granary that has every last
	# sack reserved for a hauler and leave an unpromised one further down the
	# index untouched, and the hauler then lifts less than the job says it took.
	# `Stores.try_spend` only ever takes a building's `available`.
	_clear_jobs(sim)
	farm.crop_growth = 0.0
	farm.tilth = 1.0
	var promised := 30.0
	for b in sim.buildings:
		if b.def.is_storage():
			b.inventory[Config.Res.FOOD] = 0.0
			b.reserved[Config.Res.FOOD] = 0.0
	sim.keep.inventory[Config.Res.FOOD] = promised
	sim.keep.reserved[Config.Res.FOOD] = promised
	var spare := _build(game, "granary", game.world.centre() + Vector3(64, 0, 64))
	if spare == null:
		_check(false, "the reservation check has a second granary")
		return
	spare.inventory[Config.Res.FOOD] = 40.0 * sim.citizens.size()
	sim.stores.refresh_totals(sim.citizens, sim.buildings)
	_set_calendar(game, year * 2.0
			+ float(Config.DAYS_PER_SEASON * Clock.WINTER) + 2.0)
	_turn(game)
	farm.crop_growth = 0.0
	farm.tilth = 1.0
	_set_calendar(game, year * 3.0)
	_turn(game)
	_check(is_equal_approx(farm.crop_growth, Config.TILLAGE_SOWING)
			and is_equal_approx(sim.keep.inventory[Config.Res.FOOD], promised),
			"and it is taken from unpromised grain, leaving the %.0f sacks a "
			% promised + "hauler was sent for where they were (%.1f left, "
			% sim.keep.inventory[Config.Res.FOOD] + "growth %.2f)"
			% farm.crop_growth)
	sim.keep.reserved[Config.Res.FOOD] = 0.0
	_clear_jobs(sim)
	sim.demolish(spare)
	sim.demolish(farm)
	_done("_seed_is_not_spent_for_nothing")


## A sowing nobody is told about is work the player never sees the point of.
##
## `Production` cannot reach the alert channel, so `Simulation` relays
## `ground_sown` exactly as it relays `frost_fell`. Until the relay existed a
## march could spend a whole winter in its fields and the only cue was a green
## field in the spring. The count is in the message because one field sown and
## every field sown are different pieces of news.
func _the_sowing_is_announced() -> void:
	var game := _new_game(42)
	var heard: Array = []
	game.sim.alert.connect(func(text: String, _p: Vector3):
		if "ploughing" in text: heard.append(text))
	game.sim.production.ground_sown.emit(3, Vector3.ZERO)
	game.sim.production.ground_sown.emit(1, Vector3.ZERO)
	_check(heard.size() == 2, "a winter's ploughing coming up is announced")
	_check(heard.size() > 0 and "3 fields" in heard[0],
			"the announcement names how many fields went in: %s"
			% ("" if heard.is_empty() else heard[0]))
	_check(heard.size() > 1 and "a field" in heard[1],
			"and one field reads as one field, not as a count")
	game.free()
	_done("_the_sowing_is_announced")


## A frost that nobody is told about is a bug, not a hardship.
##
## `Production` emits `frost_fell` and cannot reach the alert channel itself, so
## `Simulation` relays it. Until that relay existed the whole year's crop could
## go and the only cue was the fields turning bare -- the settlement's own
## account of the winter said nothing at all. The count is part of the message
## on purpose: one late-sown field lost is a mistake, every field lost is the
## winter arriving before the harvest did, and a player wants to react
## differently to each.
func _the_frost_is_announced() -> void:
	var game := _new_game(42)
	var heard: Array = []
	game.sim.alert.connect(func(text: String, _p: Vector3):
		if "Frost" in text: heard.append(text))
	game.sim.production.frost_fell.emit(181.5, 3, Vector3.ZERO)
	game.sim.production.frost_fell.emit(54.0, 1, Vector3.ZERO)
	# A frost over ground worth nothing is not news. Announcing it would cry
	# famine every winter on a march that had already brought its harvest in.
	game.sim.production.frost_fell.emit(0.0, 4, Vector3.ZERO)
	_check(heard.size() == 2, "a frost that takes food is announced, one that takes none is not")
	_check(heard.size() > 0 and "3 fields" in heard[0] and "182" in heard[0],
			"the announcement names the food and how many fields went with it")
	_check(heard.size() > 1 and "a field" in heard[1],
			"one field lost reads as one field, not as a count")
	game.free()


func _run() -> void:
	_atomic_payment()
	_fractional_construction(2.0)
	_fractional_construction(0.25)
	var game := _new_game(42)
	_gather_capacity(game)
	_harvest_capacity(game)
	_workshop_sources(game)
	_incoming_capacity(game)
	_calendar_shape()
	_calendar_is_wired(game)
	_crops_only_grow_in_the_growing_season(game)
	_the_frost_takes_what_is_still_standing(game)
	_the_first_winter_is_mild(game)
	_a_farm_raised_in_winter_does_not_stand_in_wheat(game)
	_a_farm_raised_in_the_mild_winter_keeps_its_crop(game)
	_drafting_the_hands_does_not_save_the_crop(game)
	_winter_frees_the_farmhands(game)
	_winter_work_is_never_a_harvest(game)
	_broken_ground_needs_seed(game)
	_real_work_outbids_winter_work(game)
	_tillage_belongs_to_winter(game)
	_a_spell_of_ploughing(game)
	_tilth_does_not_bank(game)
	_seed_is_not_spent_for_nothing(game)
	game.free()
	_the_season_survives_a_save()
	_tilth_and_the_save_file()
	_the_sowing_is_announced()
	_the_frost_is_announced()

	await _a_full_year(42)
	var kept: Dictionary = await _harvest_decides_the_winter(42, false)
	var lost: Dictionary = await _harvest_decides_the_winter(42, true)
	print("METRIC harvested: %s" % kept)
	print("METRIC drafted:   %s" % lost)
	_check(not kept.is_empty() and not lost.is_empty(),
			"both halves of the harvest experiment ran")
	if not kept.is_empty() and not lost.is_empty():
		# A march that works its fields normally still leaves the last few days'
		# growth in the ground — the fields do not stop coming on because the
		# calendar is running out. That residue is small. Abandoning the
		# harvest leaves the whole ripe field standing.
		_check(float(lost.frost_loss) > float(kept.frost_loss) * 2.0,
				"the frost takes %.0f food off the march that kept harvesting "
				% kept.frost_loss + "and %.0f off the one that did not"
				% lost.frost_loss)
		# Named for what it measures. At this instant the frost has only just
		# fallen, so the gap is what twelve days of harvesting put in the
		# granary — not what the frost destroyed. Both halves of the year
		# matter and they are not the same measurement.
		_check(float(kept.at_frost) > float(lost.at_frost),
				"twelve days of harvest is the difference by the frost "
				+ "(%.0f vs %.0f food)" % [kept.at_frost, lost.at_frost])
		_check(float(kept.low) > 0.0 and int(kept.starving_days) == 0,
				"the march that harvested never runs its stores out")
		_check(float(lost.low) <= 0.0 or int(lost.starving_days) > 0
				or float(lost.famine_days) > 0.0,
				"the march that did not is in real trouble by spring "
				+ "(low %.0f food, %d starving days, %.1f famine days)"
				% [lost.low, lost.starving_days, lost.famine_days])

	# The frost on its own. Same seed, same day of the year, same stores, same
	# draft — the only difference is that year 1's winter is the mild one. Both
	# arms send their hands back to the fields at the frost; the hard-winter arm
	# finds bare earth and the mild one finds its crop still standing, so
	# whatever separates them is the frost and nothing else.
	var spared: Dictionary = await _harvest_decides_the_winter(42, true, false)
	print("METRIC drafted, mild winter: %s" % spared)
	_check(not spared.is_empty(), "the mild-winter arm of the experiment ran")
	if not spared.is_empty() and not lost.is_empty():
		_check(float(spared.frost_loss) == 0.0 and float(lost.frost_loss) > 0.0,
				"only the hard winter destroys anything (%.0f vs %.0f food)"
				% [spared.frost_loss, lost.frost_loss])
		_check(float(spared.final) > float(lost.final),
				"the same neglected march ends the spring better off for a "
				+ "mild frost (%.0f vs %.0f food)" % [spared.final, lost.final])
		_check(float(spared.low) > float(lost.low)
				and int(spared.starving_days) < int(lost.starving_days),
				"and comes through the winter where the other starves "
				+ "(low %.0f vs %.0f food, %d vs %d starving days)"
				% [spared.low, lost.low, spared.starving_days,
				lost.starving_days])

	# The observation that started this: a march in mid-winter with every hand
	# idle and nothing on the board. Both arms are the same settlement on the
	# same seed through the same winter; the only difference is whether anyone
	# is allowed to break ground.
	var ploughed: Dictionary = await _one_winter(42, true)
	var untouched: Dictionary = await _one_winter(42, false)
	print("METRIC winter, ploughed: %s" % ploughed)
	print("METRIC winter, idle:     %s" % untouched)
	# No "both arms ran" check here: it could not fail. `_one_winter` has no
	# early return, so the dictionary is always populated, and a check that
	# cannot fail is worse than no check — it reads like coverage. A fixture that
	# died half way through is caught by `_all_ran` below, which is what that
	# machinery is for.
	if not ploughed.is_empty() and not untouched.is_empty():
		# The state of things before this change, reproduced: with nobody
		# allowed to break ground, a settlement in mid-winter has all but
		# nothing on its board and most of the march is standing still.
		_check(int(untouched.open_high) <= 2
				and int(untouched.idle_high) >= int(untouched.population) * 3 / 4,
				"suppressing winter fieldwork puts the march back where it was: "
				+ "at most %d jobs open on any winter day and %d of %d people "
				% [untouched.open_high, untouched.idle_high,
				untouched.population] + "idle at the worst of it")
		# And with it: work on nearly every day of the season, hands on the
		# ground, and fewer people standing about at every reading.
		_check(int(ploughed.hands_on_ground) > 0
				and int(ploughed.ploughing_days)
						>= int(ploughed.winter_days) / 2
				and int(ploughed.work_days) > int(untouched.work_days),
				"ploughing gives the winter work on %d of its %d days "
				% [ploughed.ploughing_days, ploughed.winter_days]
				+ "(%d worker-days on the ground; %d days with work against %d)"
				% [ploughed.hands_on_ground, ploughed.work_days,
				untouched.work_days])
		_check(int(ploughed.open_high) > int(untouched.open_high)
				and int(ploughed.idle_total) < int(untouched.idle_total)
				and int(ploughed.idle_low) < int(untouched.idle_low),
				"and takes people off the board's waiting list: %d open jobs "
				% ploughed.open_high + "against %d, %d idle-days against %d, "
				% [untouched.open_high, ploughed.idle_total,
				untouched.idle_total] + "fewest idle %d against %d"
				% [ploughed.idle_low, untouched.idle_low])
		# The consequence, in spring. The sowing is the ploughing paid out; the
		# seed is what it cost; the earlier first harvest is what it bought.
		_check(is_equal_approx(float(ploughed.sown), Config.TILLAGE_SOWING)
				and float(untouched.sown) == 0.0,
				"the ploughed march wakes in spring with its fields sown "
				+ "(%.2f growth against %.2f)"
				% [ploughed.sown, untouched.sown])
		_check(float(ploughed.seed_spent) > float(untouched.seed_spent)
				+ Config.TILLAGE_SEED_FOOD,
				"and pays for it in seed corn (%.1f food against %.1f)"
				% [ploughed.seed_spent, untouched.seed_spent])
		_check(int(ploughed.first_harvest_day)
						< int(untouched.first_harvest_day)
				and int(ploughed.first_harvest_day) >= 0,
				"its first reaper goes out on spring day %d instead of %d"
				% [ploughed.first_harvest_day, untouched.first_harvest_day])
		# Differenced against each arm's own food at the end of winter, not
		# against each other's. Two simulations of thirty people diverge over
		# twelve days for reasons that have nothing to do with ploughing, and
		# comparing the spring totals directly credited that divergence to the
		# feature: the first version of this check reported "60 food better off"
		# when 39 of it was already there before a grain of seed was spent.
		# What the winter's work is worth is what each march *gained* over the
		# same eight days of spring, seed bill included.
		var ploughed_gain := float(ploughed.spring_food) \
				- float(ploughed.winter_food)
		var idle_gain := float(untouched.spring_food) \
				- float(untouched.winter_food)
		_check(ploughed_gain > idle_gain,
				"and the first spring is worth %.0f food to it "
				% ploughed_gain + "against %.0f to the march that left its "
				% idle_gain + "fields alone — %.0f better off, seed bill and all"
				% (ploughed_gain - idle_gain))

	# Nothing above records a fixture that stopped half way through, so ask each
	# one whether it got to the end. A runtime error inside a fixture aborts it
	# silently and leaves the suite reporting on checks that never ran.
	_all_ran(["_atomic_payment", "_fractional_construction", "_gather_capacity",
			"_harvest_capacity", "_workshop_sources", "_incoming_capacity",
			"_calendar_shape", "_calendar_is_wired",
			"_crops_only_grow_in_the_growing_season",
			"_the_frost_takes_what_is_still_standing",
			"_the_first_winter_is_mild",
			"_a_farm_raised_in_winter_does_not_stand_in_wheat",
			"_a_farm_raised_in_the_mild_winter_keeps_its_crop",
			"_drafting_the_hands_does_not_save_the_crop",
			"_winter_frees_the_farmhands", "_the_season_survives_a_save",
			"_winter_work_is_never_a_harvest", "_broken_ground_needs_seed",
			"_real_work_outbids_winter_work", "_tillage_belongs_to_winter",
			"_a_spell_of_ploughing", "_tilth_and_the_save_file",
			"_the_sowing_is_announced", "_one_winter",
			"_tilth_does_not_bank", "_seed_is_not_spent_for_nothing",
			"_a_full_year"])

	await process_frame
	print("Production regression failures: %d" % _failures)
	quit(1 if _failures else 0)
