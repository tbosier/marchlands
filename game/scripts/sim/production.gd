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


func setup(job_board: JobBoard, store_index: Stores, world_node: World) -> void:
	jobs = job_board
	stores = store_index
	world = world_node


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


func _review(b: Building) -> void:
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
