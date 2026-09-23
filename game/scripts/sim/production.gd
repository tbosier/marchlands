class_name Production
extends RefCounted

## Decides what work the settlement needs doing, and posts it to the job board.
##
## Two things matter here beyond the rules themselves.
##
## First, buildings are re-evaluated on a rota rather than all at once. Asking
## every structure every tick whether it would like something hauled is pure
## waste — nothing changes in a sixtieth of a second — so each building gets
## reconsidered a few times a second and the cost is spread across frames.
##
## Second, the ordering is deliberate: materials before labour, gathering
## before delivery. A site with no timber on it should be pulling timber, not
## queuing builders who will stand about.

## The frost has fallen and taken `lost_food` worth of standing crop off
## `farms` fields. Emitted when the year turns, and again for any farm that
## meets the frost later than that — one raised after the turn has to be told
## what month it is when it is first reviewed, and what it loses then is as
## real as what the sweep took.
##
## Not emitted on the first turn after a load: see `_turn_the_year`.
signal frost_fell(lost_food: float, farms: int, position: Vector3)

## The winter's ploughing has come up: `farms` fields were sown on the first
## tick of spring because somebody spent the frozen season breaking their
## ground. Emitted only when there was work to show for it.
signal ground_sown(farms: int, position: Vector3)

## How often any individual building is reconsidered, in in-game seconds.
const REVIEW_INTERVAL := 0.4

## Never spend longer than this on posting in a single tick, however many
## buildings are due. They simply get looked at next tick instead.
const MAX_REVIEWS_PER_TICK := 24

var jobs: JobBoard
var stores: Stores
var world: World
var husbandry: Node
var research: RoadResearch
var _cart: Cart
var _next_review: Dictionary = {}       # building id -> in-game seconds
var _clock := 0.0
var _cursor := 0

# --- The agricultural year -------------------------------------------------
#
# None of this is persisted. The season is a pure function of the simulation's
# day counter (see the block comment in `clock.gd`), which every save already
# carries, so a march loaded in the middle of autumn resumes in the middle of
# autumn and a march loaded in winter resumes frozen — without one new save
# field. That was a hard requirement: `save_validation.gd` rejects a version
# mismatch outright and there is no migration system to lean on.

## Season index last acted on, or -1 before the first tick. The *year* is kept
## beside it because whether a frost bites depends on which winter it is: two
## consecutive winters carry the same season index and are not the same event.
var _season := -1
var _season_year := -1
var _growing := true
var _hard_frost := false
## What the last frost destroyed. Kept for the interface and for tests.
var frost_loss := 0.0
## The simulation, for its day counter. See `_bind_calendar`.
var _sim: Simulation = null
var _calendar_warned := false


func setup(job_board: JobBoard, store_index: Stores, world_node: World) -> void:
	jobs = job_board
	stores = store_index
	world = world_node
	_bind_calendar()


## Find the day counter the rest of the simulation runs on.
##
## Production is handed the job board, the stores and the world at setup, and
## the calendar is the one thing it needs that nobody passes it. It is *read*
## from `Simulation` every time rather than counted here off `delta`, and that
## is the point: a private counter would be silently wrong the moment a save
## was loaded, because loading builds a fresh `Production` beside a
## `Simulation.day` restored to whatever day the player left off on. The season
## would then have been a different season from the one on the clock, in the
## sky and on the ground — which is exactly the decorative-calendar bug this
## work exists to fix.
##
## The simulation is the world's sibling: both are added to the game node —
## or, while a save is being staged, to the staging node — in the same breath
## (`Game._build_world_and_sim`, `Game.restore_from`, `Game.new_world`), and
## `Simulation.setup` calls this before its own first tick. Reaching for it
## through the tree is not pretty; it is what could be done without editing a
## file this change does not own.
func _bind_calendar() -> void:
	if _sim != null or world == null:
		return
	var parent := world.get_parent()
	if parent == null:
		return
	for sibling in parent.get_children():
		if sibling is Simulation:
			_sim = sibling
			return


## The calendar day. Falls back to the opening day — an eternal spring, which
## is how the game behaved before there were seasons — but says so loudly,
## once, because a silently seasonless march is the failure mode here.
func calendar_day() -> float:
	if _sim == null:
		_bind_calendar()
	if _sim != null:
		return _sim.day
	if not _calendar_warned:
		_calendar_warned = true
		push_error("Production cannot see the simulation's calendar: "
				+ "the year will not turn and nothing will ever be harvested "
				+ "late.")
	return Clock.START_TIME_OF_DAY


func set_cart(cart: Cart) -> void:
	_cart = cart


func forget(building_id: int) -> void:
	_next_review.erase(building_id)


## Review a slice of the building list and post whatever work is wanted.
func tick(delta: float, buildings: Array[Building]) -> void:
	if buildings.is_empty():
		return
	Perf.begin("sim.production")
	_clock += delta
	_turn_the_year(buildings)

	var reviewed := 0
	var examined := 0
	while examined < buildings.size() and reviewed < MAX_REVIEWS_PER_TICK:
		_cursor = (_cursor + 1) % buildings.size()
		examined += 1
		var b := buildings[_cursor]
		var due: float = _next_review.get(b.id, -1.0)
		if _clock < due:
			continue
		# Stagger the rota so buildings do not all come due on the same tick.
		_next_review[b.id] = _clock + REVIEW_INTERVAL * randf_range(0.85, 1.15)
		reviewed += 1
		_review(b)

	Perf.count("production.reviews", reviewed)
	Perf.end("sim.production")


# ---------------------------------------------------------------------------
# The year turns (design/NORTH_STAR.md — "Seasonal farming")
# ---------------------------------------------------------------------------

## Everything seasonal happens here: once, on the tick the season changes, over
## the building list once.
##
## Not per frame and not per farm. The per-frame budget for "ask every field
## what month it is" is zero — this project has just spent a great deal of
## effort taking a 1,400-actor frame from 442 ms to 59 ms — and the season is
## the slowest-moving quantity in the simulation. The only per-tick cost left
## is one integer divide and one compare.
func _turn_the_year(buildings: Array[Building]) -> void:
	var day := calendar_day()
	var season := Clock.season_index_at(day)
	var year := Clock.year_at(day)
	if season == _season and year == _season_year:
		return
	var first_turn := _season < 0
	_season = season
	_season_year = year
	# Asked of the calendar rather than restated as `season != WINTER`. It was
	# written that way first, and the result was that turning the growing season
	# off in `Clock` changed nothing in the simulation: two definitions of the
	# same rule, one of which nothing read.
	_growing = Clock.is_growing_at(day)
	_hard_frost = not _growing and Clock.frost_is_hard_at(day)

	# A load lands here too, on its first tick, with `_season` still -1, and it
	# has to apply the state: a march saved in a hard winter is frozen, and a
	# fresh `Production` works that out again from the day counter.
	#
	# Whether it should *say so* depends on when the frost fell. A march played
	# across the boundary — including one loaded in autumn and then played on
	# into winter, which is the ordinary case — is living through the event and
	# must be told. A march resuming a save taken days into a winter is not:
	# that frost fell before the save, and announcing it again told the player
	# they had just lost a harvest every time they reloaded, with a fabricated
	# figure against it. One day's grace separates the two, and a save cannot
	# land inside it by accident — the whole window is a single in-game day.
	#
	# A *mild* winter never sweeps at all, so the crop it was letting stand
	# still stands.
	var announce := not first_turn or _growing \
			or Clock.days_since_frost(day) < 1.0
	var lost := 0.0
	var farms := 0
	var where := Vector3.ZERO
	var sown := 0
	var sown_where := Vector3.ZERO
	for b in buildings:
		if not b.def.is_farm():
			continue
		b.dormant = not _growing
		# Winter work, resolved here and nowhere else, because this is the one
		# place in the game that knows the year has turned.
		#
		# Order matters and is not incidental: the field is woken on the line
		# above before it is sown, because `set_crop_growth` refuses every
		# increase on a dormant field and refuses it *silently*. Sowing first
		# would have thrown the whole winter away without a word.
		if season == Clock.SPRING:
			if _sow_broken_ground(b):
				sown += 1
				sown_where = b.global_position
		elif season == Clock.WINTER and not first_turn:
			# Each winter's work starts from bare ground. A field is prepared
			# for the spring that follows it and for no other, so tilth that
			# somehow survived a year does not bank.
			#
			# `not first_turn` is doing the same job here that it does for the
			# frost a few lines down, and it is the difference between the save
			# note on `Building.tilth` being true and being a trap. A fresh
			# `Production` reaches this on its first tick with the loaded day
			# already inside winter, so an ungated reset wiped the ploughing out
			# of every file that carried it — the identical bug that ruled
			# `crop_growth` out as a home for this in the first place,
			# reintroduced one branch away from it. Measured: with
			# `"tilth": b.tilth` added to `SaveGame._capture_building`, tilth
			# was restored as 0.9 and was 0.0 again after one tick.
			b.tilth = 0.0
		if not _hard_frost:
			continue
		var taken := b.lose_standing_crop()
		if taken > 0.0:
			lost += taken
			farms += 1
			where = b.global_position
	if _growing:
		# Ground nobody got to is not still wanted. Only the *open* orders go:
		# a ploughman still holding one retires it himself on his next tick
		# (`Simulation._tick_till` refuses a field that has woken), and pulling
		# a job out from under its claimant is how reservations get stranded
		# elsewhere in this file. Left on the board they kept counting against
		# next winter's `TILLAGE_HANDS` cap and cost one wasted claim-and-retire
		# each to whichever idle citizen bid for them in the spring.
		jobs.cancel_open_of_kind(JobBoard.Kind.TILL)
	# Not gated the way the frost is, and the reason is worth writing down
	# because the gate was tried and was dead code. `announce` is
	# `not first_turn or _growing or ...`, and the sowing only ever happens on a
	# spring turn, where `_growing` is true by definition — so `and announce`
	# could never be false here and every mutation of it passed the whole suite.
	# A guard that cannot fire is worse than none: it reads as protection.
	#
	# There is no replay to protect against either. Unlike the frost, which is
	# reported after the fact, this *is* the event: the tick that emits it is
	# the tick that spends the seed and puts the crop in the ground. `tilth` is
	# saved, but every branch of `_sow_broken_ground` clears it on the spring
	# turn, so no file written in spring carries any for a reload to sow again.
	if sown > 0:
		ground_sown.emit(sown, sown_where)
	# A turn that is not announcing is not reporting either. This is what
	# the interface would put in front of the player, and a frost that fell
	# before the save the player just resumed is not news they can act on.
	frost_loss = lost if announce else 0.0
	if farms > 0 and announce:
		frost_fell.emit(lost, farms, where)


## Sow one farm's broken ground, if the march has seed corn to put in it.
##
## Winter labour breaks the ground; grain is what makes it a crop. Both have to
## be there, and the seed is the half that stops this from being a way back out
## of the frost: a march that has eaten its way to the bottom of its granaries
## cannot sow, however many hands it spent in the fields. See
## `Config.TILLAGE_SEED_FOOD` for the measurement that made that necessary.
##
## The grain is taken from the stores rather than carried out by somebody, the
## same way `Simulation._consume_tools` takes tools. The journey to the field
## has already been made — that is what the tillage jobs were — and adding a
## second errand on the one tick the year turns would have meant holding the
## sowing open across the first days of spring, when the same hands are wanted
## for the harvest that sowing exists to bring forward.
##
## Ground broken with nothing to sow in it is simply lost. That is the point of
## it, and `sow_prepared_ground` clears the tilth either way: a field is
## prepared for the spring in front of it and for no other.
func _sow_broken_ground(b: Building) -> bool:
	if b.tilth <= 0.0:
		return false
	# Ground with nobody on the farm's books has gone back to grass
	# (`Building.sync_fields_to_workers`); sowing it would spend seed on meadow.
	if b.field_count() == 0:
		b.tilth = 0.0
		return false
	# Nothing is bought here that the field does not already have. A mild winter
	# can leave a part-reaped crop standing at more than a part-broken field is
	# worth, and `sow_prepared_ground` rightly refuses to plough that back in —
	# but the seed had already been taken out of the granaries by then, so the
	# march paid for a sowing it did not get.
	if Config.TILLAGE_SOWING * b.tilth <= b.crop_growth:
		b.tilth = 0.0
		return false
	var wanted: float = Config.TILLAGE_SEED_FOOD * b.tilth
	if not _can_spare_seed(wanted):
		b.tilth = 0.0
		return false
	# `try_spend`, not `consume`. Both take food out of the stores, but
	# `Stores.consume` goes through `Building.remove`, which looks at
	# `inventory` alone — it will strip grain already promised to a hauler off
	# the first granary in the index while an unpromised one further down is
	# left untouched, and the hauler then lifts less than the job says it
	# reserved. `try_spend` validates against `spendable` and only ever takes a
	# building's `available`, which is the same quantity `_can_spare_seed` asked
	# about. It also refuses the whole payment rather than taking part of it.
	if not stores.try_spend({Config.Res.FOOD: wanted}):
		b.tilth = 0.0
		return false
	return b.sow_prepared_ground() > 0.0


## Whether the march can put `wanted` food in the ground without eating into
## what it needs to get through to the harvest.
##
## Days of eating, not a flat quantity: twenty people and two hundred do not
## mean the same thing by "sixty food in store". The population is read off the
## simulation the same way the calendar is (see `_bind_calendar`), and a march
## whose simulation cannot be seen falls back to requiring the seed several
## times over — wrong in detail, safe in direction.
func _can_spare_seed(wanted: float) -> bool:
	if wanted <= 0.0 or stores == null:
		return false
	var held := stores.spendable(Config.Res.FOOD)
	if held < wanted:
		return false
	if _sim == null:
		_bind_calendar()
	if _sim == null:
		return held >= wanted * 4.0
	var mouths := maxf(1.0, _sim.citizens.size() * Config.HUNGER_PER_DAY)
	return (held - wanted) / mouths >= Config.TILLAGE_SEED_MIN_DAYS


## Tell one farm what month it is.
##
## The sweep above catches every farm standing when the year turned; this
## catches the ones raised afterwards. Without it a farm built the week after
## the frost would sow itself at FARM_INITIAL_GROWTH, come on all winter and be
## harvested in the snow — the one rule this whole feature exists to enforce,
## dodged by building a day late. It costs a bool compare per farm review.
func _sync_season(b: Building) -> void:
	if b.dormant == (not _growing):
		return
	b.dormant = not _growing
	if not _hard_frost:
		return
	# What a late-caught farm loses counts. Dropping the return value here meant
	# the frost quietly destroyed food that was never added to `frost_loss` and
	# never announced, so the settlement's own account of the winter was short
	# by however much had been sown after the year turned.
	var lost := b.lose_standing_crop()
	if lost <= 0.0:
		return
	frost_loss += lost
	frost_fell.emit(lost, 1, b.global_position)


func _review(b: Building) -> void:
	# Before the construction branch, not after it. A farm sows its plots as it
	# is raised, and a site still going up is still a farm with wheat in the
	# ground — one finished during a winter would otherwise stand ripe until
	# whichever came first, spring or somebody noticing.
	if b.def.is_farm():
		_sync_season(b)
	if b.under_construction:
		_post_construction(b)
		return
	if b.def.is_food_depot():
		_post_market(b)
		return
	if b.def.is_ranch():
		if husbandry != null:
			husbandry.post_ranch_jobs(b)
		_post_delivery(b)
		_post_delivery(b, Config.Res.FOOD)
		return
	if b.type_id == "tannery" and (research == null or not research.completed.has("leatherworking")):
		return
	if b.def.is_farm():
		_post_tillage(b)
	_post_gathering(b)
	_post_delivery(b)


## Market stock is carried by its employed vendors. Incoming claims count
## against the chosen target, so repeated reviews cannot flood the counters.
func _post_market(b: Building) -> void:
	if b.under_construction or b.workers.is_empty():
		return
	var res := Config.Res.FOOD
	if jobs.count_for(JobBoard.Kind.HAUL, b.id, res) >= b.workers.size():
		return
	var wanted := float(b.food_stock_target()) - b.inventory[res] - b.incoming[res]
	if wanted < 1.0:
		return
	var source := stores.find_market_source(b)
	if source == null:
		return
	var take := minf(float(Config.CARRY_CAPACITY), wanted)
	take = minf(take, minf(stores.market_surplus(source), b.space_for(res)))
	if take < 1.0:
		return
	var job := jobs.post(JobBoard.Kind.HAUL, source.global_position, 64.0)
	job.res = res
	job.amount = take
	job.source_id = source.id
	job.dest_id = b.id
	job.required_workplace = b.id
	jobs.index(job)
	source.reserved[res] += take
	b.incoming[res] += take


# ---------------------------------------------------------------------------
# Construction: materials first, then labour (design doc 6.3)
# ---------------------------------------------------------------------------

func _post_construction(b: Building) -> void:
	var outstanding := b.materials_needed()
	if not outstanding.is_empty():
		var gross := b.materials_outstanding()
		for res in outstanding:
			var want: float = outstanding[res]
			# Size the gate off what the site is short of *before* deliveries in
			# flight are subtracted. `want` has already had them taken off, so
			# comparing trips derived from it against the count of the very jobs
			# that produced them held the last partial load back until the
			# previous one had arrived — an extra round trip on every site.
			var trips_needed := int(ceil(
					float(gross.get(res, want)) / float(Config.CARRY_CAPACITY)))
			if jobs.count_for(JobBoard.Kind.HAUL, b.id, res) >= trips_needed:
				continue
			var take: float = minf(Config.CARRY_CAPACITY, want)
			var source := stores.find_source(res, b.global_position, take)
			if source == null:
				continue
			take = minf(take, source.available(res))
			# Construction waits for every amount above its material epsilon.
			# Ignoring a fractional last load leaves a paid site stalled forever.
			if take <= 0.01:
				continue
			var job := jobs.post(JobBoard.Kind.HAUL, source.global_position, 72.0)
			job.res = res
			job.amount = take
			job.source_id = source.id
			job.dest_id = b.id
			jobs.index(job)
			source.reserved[res] += take
			b.incoming[res] += take
		return

	# Reserved deliveries are still at the store or on somebody's back.
	# Posting labour now can occupy every free worker at the near-empty site
	# while the last haul remains unclaimed forever.
	if not b.materials_complete():
		return
	if jobs.count_for(JobBoard.Kind.BUILD, b.id, -1) < 2:
		var job := jobs.post(JobBoard.Kind.BUILD, b.global_position, 68.0)
		job.dest_id = b.id
		job.res = -1
		jobs.index(job)


# ---------------------------------------------------------------------------
# Gathering and harvesting
# ---------------------------------------------------------------------------

## Winter work: break the ground for the spring sowing.
##
## This is the whole answer to a season that had nothing in it. Measured on a
## real march at day 92, mid-winter: twenty-two people, twenty-two idle, zero
## open jobs, and no food. Nothing was blocked — the logging camp was staffed
## 3/3 and posted nothing because there were 658 timber in store and no room
## for more. The economy simply had no work that exists in winter, because
## every job it knows how to post is either "fetch more of a good we are
## already full of" or "carry a good nobody is producing". Ploughing is neither.
##
## Three gates, each doing a job:
##
##   * `_growing` — this is winter work and only winter work. There is no
##     breaking ground a crop is standing in, and while one is standing the
##     hands are wanted for the harvest anyway.
##   * `field_count()` — ground nobody works has gone back to grass
##     (`Building.sync_fields_to_workers`). A farm with no hands on its books
##     has no field to prepare, and posting for one would have put people to
##     work on a strip of meadow.
##   * the open-job count — every open job is scanned by every job-seeking
##     citizen (`JobBoard.best_for`), so an uncapped queue is a cost the whole
##     settlement pays. `TILLAGE_HANDS` at a time, reposted as they finish.
##
## What is deliberately *not* here is any check on whether the settlement has
## better things to do. That decision belongs to the board: tillage is posted at
## a priority below every productive job, so a building site, a haul or a
## standing felling order outbids it unless that work is far further away —
## about 136 m for the cheapest haul and 200 m for a building site (see
## `Config.TILLAGE_PRIORITY`) — and the hands it takes are, within that reach,
## the hands nothing else wanted.
func _post_tillage(b: Building) -> void:
	if _growing:
		return
	# A farm that stops wanting ploughing mid-winter — its ground finished, its
	# hands gone, a crop still standing — takes its open orders off the board.
	# Left there they held places under `TILLAGE_JOBS_MAX` that other farms
	# needed, until an idle citizen happened to claim and discard each one.
	if b.tilth >= 1.0 or b.field_count() == 0 or b.crop_growth > 0.0:
		jobs.cancel_open_for(JobBoard.Kind.TILL, b.id)
		return
	# `crop_growth > 0.0` above: ground with anything at all standing in it is
	# not ground to break.
	#
	# Bare earth, not "less crop than a sowing is worth". The looser test was
	# written first and it cost the mild winter real food: a field reaped down
	# from the 0.55 posting floor sits at 0.4875 after one load and 0.425 after
	# two, so it passed a `>= TILLAGE_SOWING` gate, got a full winter's
	# ploughing, and then paid the *whole* seed bill at the spring turn for a
	# growth gain of 0.45 minus whatever was already there — a few hundredths.
	# Measured on `_harvest_decides_the_winter`, that took the mild-winter arm
	# from 46.5 food at HEAD down to 40.0 and halved the margin by which a mild
	# winter beats a hard one. The margin is the season's whole incentive, and
	# it was being paid down inside the slack of an inequality that still
	# passed. At `> 0.0` the mild arm is bit-identical to HEAD again.
	#
	# It also retires the case `sow_prepared_ground` refuses: ploughing a
	# standing crop back in, which would make winter work destructive in the
	# one year it is easiest to do.
	if jobs.count_for(JobBoard.Kind.TILL, b.id, -1) >= Config.TILLAGE_HANDS:
		return
	# And a ceiling across the whole march, not only per farm. The per-farm cap
	# was justified by the cost of a long `_open` list — `JobBoard.best_for`
	# walks it once per job-seeking citizen per tick — and then multiplied by
	# the number of farms, in the one season when almost everybody is looking
	# for work. Ten farms would have put sixty orders on the board for every
	# idle person to score. This project has just spent a release taking a
	# 1,400-actor frame from 442 ms to 73 ms; a cap that grows with the
	# settlement is not a cap.
	if jobs.count_of_kind(JobBoard.Kind.TILL) >= Config.TILLAGE_JOBS_MAX:
		return
	var job := jobs.post(JobBoard.Kind.TILL, b.global_position,
			Config.TILLAGE_PRIORITY)
	job.res = -1
	job.dest_id = b.id
	jobs.index(job)


func _post_gathering(b: Building) -> void:
	var def := b.def
	if not def.is_producer():
		return
	var res := def.produces

	# A workshop makes things out of other things, so it pulls its inputs in
	# rather than sending anyone out to a resource node. It is also exempt from
	# the "is there room for the output" test here: its store holds inputs too,
	# and `can_craft` does that check properly.
	if def.is_workshop():
		_post_crafting(b)
		return

	# Each posted trip owns room for its output. Checking only for one free
	# unit let three workers collect 36 units for a yard with one slot left;
	# once every store was full they were all stranded carrying the overflow.
	var output := Config.harvest_load(1.0) if def.is_farm() else float(Config.CARRY_CAPACITY)
	if b.space_for(res) < output:
		return

	var kind := JobBoard.Kind.HARVEST if def.is_farm() else JobBoard.Kind.GATHER
	if jobs.count_for(kind, b.id, res) >= def.worker_slots:
		return

	if def.is_farm():
		if b.crop_growth < Config.FARM_HARVEST_AT or b.field_count() == 0:
			return
		var harvest := jobs.post(kind, b.global_position, 58.0)
		harvest.res = res
		harvest.dest_id = b.id
		harvest.output_reserved = output
		b.production_reserved += output
		jobs.index(harvest)
		return

	# The job is posted at the node, so the job board's distance term naturally
	# prefers close, unworked resources.
	var node := world.nodes.find_nearest(def.harvest_kind, b.global_position,
			def.work_radius)
	if node == null:
		return
	node.reserved_by = b.id
	var gather := jobs.post(kind, node.position, 56.0)
	gather.res = res
	gather.dest_id = b.id
	gather.node_id = node.id
	gather.output_reserved = output
	b.production_reserved += output
	jobs.index(gather)


## Shed raw materials a workshop has more of than it can use. Belt and braces
## against a bench that has somehow silted up with one input.
func _post_workshop_delivery(b: Building) -> void:
	for input in b.def.consumes:
		var cap: float = b.def.storage * Config.WORKSHOP_INPUT_SHARE
		var excess: float = b.available(input) - cap
		if excess < Config.CARRY_CAPACITY:
			continue
		if jobs.count_from_source(JobBoard.Kind.HAUL, b.id) >= 2:
			return
		var dest := stores.find_store(input, b.global_position, b.id)
		if dest == null:
			return
		var take: float = minf(Config.CARRY_CAPACITY, excess)
		take = minf(take, dest.space_for(input))
		if take <= 0.5:
			continue
		var job := jobs.post(JobBoard.Kind.HAUL, b.global_position, 48.0)
		job.res = input
		job.amount = take
		job.source_id = b.id
		job.dest_id = dest.id
		jobs.index(job)
		b.reserved[input] += take
		dest.incoming[input] += take


## A workshop wants two things: its raw materials brought to it, and someone
## standing at the bench turning them into goods.
func _post_crafting(b: Building) -> void:
	var def := b.def
	var res := def.produces

	# Inputs first — a smith with no iron is not a smith.
	for input in def.consumes:
		var per_unit: float = float(def.consumes[input])
		var want: float = per_unit * Config.CRAFT_BATCH * 2.0
		if b.inventory[input] + b.incoming[input] >= want:
			continue
		if jobs.count_for(JobBoard.Kind.HAUL, b.id, input) >= 2:
			continue
		var source := stores.find_source(input, b.global_position,
				Config.CARRY_CAPACITY, b.id)
		if source == null:
			continue
		var take: float = minf(Config.CARRY_CAPACITY, source.available(input))
		# Leave room for what the shop is going to make. Without this the
		# forge fills to the roof with iron, has nowhere to put a finished
		# tool, and quietly stops working.
		var input_room: float = minf(b.space_for(input),
				def.storage * Config.WORKSHOP_INPUT_SHARE
				- b.inventory[input] - b.incoming[input])
		take = minf(take, input_room)
		if take <= 0.5:
			continue
		var haul := jobs.post(JobBoard.Kind.HAUL, source.global_position, 66.0)
		haul.res = input
		haul.amount = take
		haul.source_id = source.id
		haul.dest_id = b.id
		jobs.index(haul)
		source.reserved[input] += take
		b.incoming[input] += take

	if not b.can_craft():
		return
	if jobs.count_for(JobBoard.Kind.CRAFT, b.id, res) >= def.worker_slots:
		return
	var job := jobs.post(JobBoard.Kind.CRAFT, b.global_position, 60.0)
	job.res = res
	job.dest_id = b.id
	jobs.index(job)


# ---------------------------------------------------------------------------
# Delivery
# ---------------------------------------------------------------------------

## Production buildings are not warehouses. Once stock accumulates it needs
## carrying to real storage, which is what creates the repeated round trips
## that wear roads in.
func _post_delivery(b: Building, output_res: int = -1) -> void:
	if b.def.is_workshop():
		_post_workshop_delivery(b)
	var res := b.def.produces if output_res < 0 else output_res
	if res < 0:
		return
	var surplus := b.available(res)
	var keep_back: float = b.def.storage * 0.2
	if surplus < maxf(Config.CARRY_CAPACITY, keep_back):
		return
	if jobs.count_from_source(JobBoard.Kind.HAUL, b.id) >= 3:
		return

	var dest := stores.find_store(res, b.global_position, b.id)
	if dest == null:
		return

	# A single haul that would take several trips is worth the cart, if the
	# cart is idle and no other job has already been planned around it.
	var by_cart := (_cart != null and _cart.is_free()
			and not jobs.cart_promised()
			and surplus >= Config.CARRY_CAPACITY * 2.0)
	var limit: float = Cart.CAPACITY if by_cart else float(Config.CARRY_CAPACITY)

	var take: float = minf(limit, surplus)
	take = minf(take, dest.space_for(res))
	if take <= 0.5:
		return

	var job := jobs.post(JobBoard.Kind.HAUL, b.global_position,
			56.0 if by_cart else 50.0)
	job.res = res
	job.amount = take
	job.source_id = b.id
	job.dest_id = dest.id
	job.uses_cart = by_cart
	jobs.index(job)
	b.reserved[res] += take
	dest.incoming[res] += take
