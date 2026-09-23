class_name JobBoard
extends RefCounted

## The systemic work queue (design doc 22).
##
## Nothing scripts a citizen directly. Buildings post what they need, idle
## citizens score the open jobs by priority and travel cost, and behaviour
## emerges from that. The distance term is what makes geography matter: a
## distant quarry genuinely is less attractive than a near one, which is the
## economic pressure the whole design rests on.
##
## Performance notes, because this is the hottest structure in the simulation:
##
##   * open jobs live in their own list, so a citizen looking for work scans
##     candidates rather than the whole history of the settlement;
##   * the counts the posting logic needs are maintained incrementally rather
##     than recomputed by walking every job;
##   * matching uses an integer filter rather than a Callable, because
##     allocating one closure per idle citizen per tick was, measurably, the
##     largest single source of garbage in the game.

## Appended to, never inserted into. Nothing writes a job kind to a save: the
## board is rebuilt from nothing on load and `SaveGame` reconstructs exactly one
## job, the haul a citizen was already carrying, by posting a fresh HAUL. So the
## numbering is not a save format and a new kind cannot break an old file —
## which was worth checking before adding one, because `save_validation.gd`
## rejects a version mismatch outright and there is no migration path. Keeping
## it append-only costs nothing and keeps that true for anything that starts
## persisting jobs later.
enum Kind { HAUL, GATHER, BUILD, HARVEST, FELL, CRAFT, TAME, TEND, BUTCHER, BRIDGE_HAUL, BRIDGE_BUILD, SALVAGE, TILL }

## Filters a citizen can apply when looking for work.
enum Accept {
	ANY,             ## anything going
	OWN_SITE_ONLY,   ## only work belonging to this citizen's own workplace
}


class Job:
	extends RefCounted

	var id := 0
	var kind := Kind.HAUL
	var res := -1
	var amount := 0.0
	## Maximum output whose storage capacity this gather/harvest job owns.
	## Kept separate from HAUL quantities and released on deposit/cancellation.
	var output_reserved := 0.0
	## Building this job draws from, or -1. Resource nodes live in `node_id`:
	## sharing one field made completing building 7 cancel a gathering job on
	## resource node 7, stranding that node's reservation forever.
	var source_id := -1
	var node_id := -1
	## Livestock IDs have their own namespace, independent of resource nodes.
	var cow_id := -1
	## Bridges are independent of building IDs; never overload dest_id.
	var bridge_id := -1
	## Abandoned trading carts use their own identifier namespace.
	var wreck_id := -1
	var dest_id := -1
	var position := Vector3.ZERO     ## where the work starts
	## A specific spot chosen when the job is first executed (which field to
	## reap, say). Kept on the job so the worker does not re-decide every tick.
	var target := Vector3.INF
	## Set when the job was sized for the cart rather than for a pair of arms.
	var uses_cart := false
	## Work time still owed on a spell that nightfall interrupted, or -1. The
	## next `Citizen.begin_work` on this job resumes from it instead of starting
	## the whole spell again.
	var work_left := -1.0
	var priority := 40.0
	var claimed_by := -1
	var cancelled := false
	## Citizens who took this job and found they could not walk to it. They are
	## not offered it again until the shape of the world changes. Without this
	## the nearest worker re-claims an unreachable job every tick, for ever,
	## instead of the job falling to someone who can actually get there.
	var refused_by: Dictionary = {}
	## True once the source leg of a haul has been executed, so the goods are
	## on the carrier rather than in the source's store. The reservation that
	## covered them has already been consumed and must not be released twice.
	var loaded := false
	## Staffed services procure their own stock. Ordinary hauling stays open
	## to every labourer; a market order belongs to that market's vendors.
	var required_workplace := -1

	func describe() -> String:
		match kind:
			Kind.HAUL:
				var verb := "Cart" if uses_cart else "Haul"
				return "%s %d %s" % [verb, int(amount), Res.display(res)]
			Kind.GATHER:
				return "Gather %s" % Res.display(res)
			Kind.HARVEST:
				return "Harvest"
			Kind.BUILD:
				return "Build"
			Kind.FELL:
				return "Clear ground"
			Kind.CRAFT:
				return "Make %s" % Res.display(res)
			Kind.TAME:
				return "Tame cattle"
			Kind.TEND:
				return "Tend the herd"
			Kind.BUTCHER:
				return "Prepare food and hides"
			Kind.BRIDGE_HAUL:
				return "Carry %s to bridge" % Res.display(res)
			Kind.BRIDGE_BUILD:
				return "Build timber bridge"
			Kind.SALVAGE:
				return "Recover %s from lost cart" % Res.display(res)
			Kind.TILL:
				return "Break ground for spring"
		return "Work"


var _open: Array[Job] = []
var _claimed: Array[Job] = []
var _next_id := 1

## Incrementally maintained tallies, so the posting logic never counts by
## scanning. Keyed "<kind>:<dest_id>:<res>" and "<kind>:<source_id>".
var _by_dest: Dictionary = {}
var _by_source: Dictionary = {}
## Live jobs of each kind, so a poster can ask "how much of this is the whole
## settlement already carrying?" without walking the board. Winter tillage needs
## it: a cap that is per-farm is not a cap at all once a march has ten farms,
## and every open job is scored by every job-seeking citizen.
var _by_kind := PackedInt32Array()
var _cart_jobs := 0


# --- Posting ----------------------------------------------------------------

## Create a job. Fill in its fields, then call `index` to register it.
func post(kind: int, position: Vector3, priority: float) -> Job:
	var job := Job.new()
	job.id = _next_id
	_next_id += 1
	job.kind = kind
	job.position = position
	job.priority = priority
	_open.append(job)
	Perf.count("jobs.posted")
	return job


## Register a fully populated job in the tallies. Must be called after the
## dest/source/res fields are set, or the counts will not match reality.
func index(job: Job) -> void:
	_bump(_by_dest, _dest_key(job.kind, job.dest_id, job.res), 1)
	_bump(_by_source, _source_key(job.kind, job.source_id), 1)
	_count_kind(job.kind, 1)
	if job.uses_cart:
		_cart_jobs += 1


## Move a job to a different destination *through the board*, so the tally
## keyed on that destination moves with it.
##
## A felling order is posted before anyone knows where the timber will go, so
## it is indexed under destination -1 and only later given a real store.
## Reassigning `job.dest_id` directly left the -1 count permanently one higher
## per tree felled; past twelve, the reposting gate stopped issuing felling
## work at all and standing orders simply stopped being carried out.
func set_destination(job: Job, dest_id: int) -> void:
	if job == null or job.dest_id == dest_id:
		return
	if not job.cancelled:
		_bump(_by_dest, _dest_key(job.kind, job.dest_id, job.res), -1)
	job.dest_id = dest_id
	if not job.cancelled:
		_bump(_by_dest, _dest_key(job.kind, job.dest_id, job.res), 1)


func _dest_key(kind: int, dest_id: int, res: int) -> String:
	return "%d:%d:%d" % [kind, dest_id, res]


func _source_key(kind: int, source_id: int) -> String:
	return "%d:%d" % [kind, source_id]


## Indexed by kind rather than keyed by a string: this runs on every post and
## retire, and a `str(kind)` there was per-haul garbage.
func _count_kind(kind: int, by: int) -> void:
	if _by_kind.size() < Kind.size():
		_by_kind.resize(Kind.size())
	_by_kind[kind] = maxi(0, _by_kind[kind] + by)


func _bump(table: Dictionary, key: String, by: int) -> void:
	var n: int = int(table.get(key, 0)) + by
	if n <= 0:
		table.erase(key)
	else:
		table[key] = n


# --- Queries ----------------------------------------------------------------

func open_jobs() -> int:
	return _open.size()


func total_jobs() -> int:
	return _open.size() + _claimed.size()


func count_for(kind: int, dest_id: int, res: int) -> int:
	return int(_by_dest.get(_dest_key(kind, dest_id, res), 0))


func count_from_source(kind: int, source_id: int) -> int:
	return int(_by_source.get(_source_key(kind, source_id), 0))


## Live jobs of one kind across the whole settlement, open and claimed.
func count_of_kind(kind: int) -> int:
	return _by_kind[kind] if kind < _by_kind.size() else 0


func cart_promised() -> bool:
	return _cart_jobs > 0


func _accepts(job: Job, filter: int, workplace_id: int,
			  citizen_id: int) -> bool:
	if job.refused_by.has(citizen_id):
		return false
	if job.required_workplace >= 0:
		return job.required_workplace == workplace_id
	# Gathering and harvesting belong to a specific site; hauling and building
	# are open to anyone, which is what keeps logistics moving when the
	# specialists are busy.
	if job.kind == Kind.GATHER or job.kind == Kind.HARVEST \
			or job.kind == Kind.CRAFT:
		return job.dest_id == workplace_id
	# Felling is open to anyone: it is the player telling the settlement to
	# clear a piece of ground, not a workplace's own business. So is winter
	# tillage, and for a sharper reason — the whole point of it is that it is
	# work for hands that are not the farm's own. Binding it to the farm the way
	# harvesting is bound would have left it doing nothing about the season it
	# exists to fill: the farmhands are three people out of twenty-two, and it
	# was the other nineteen who were standing still.
	return filter == Accept.ANY


## Pick the best open job for a citizen standing at `from`, and claim it.
##
## Score falls off with travel distance so that, all else equal, people work
## close to home — and so that a road which shortens the effective distance
## changes who takes which job.
func best_for(citizen_id: int, from: Vector3, filter: int,
			  workplace_id: int) -> Job:
	var best: Job = null
	var best_score := -INF
	var best_index := -1

	for i in _open.size():
		var job := _open[i]
		if not _accepts(job, filter, workplace_id, citizen_id):
			continue
		var score: float = job.priority - from.distance_to(job.position) * 0.28
		if score > best_score:
			best_score = score
			best = job
			best_index = i

	Perf.count("jobs.scanned", _open.size())
	if best == null:
		return null

	best.claimed_by = citizen_id
	_open.remove_at(best_index)
	_claimed.append(best)
	return best


# --- Lifecycle --------------------------------------------------------------

## Put a claimed job back on the board for someone else to take.
##
## `refused_by_citizen` is set when that particular citizen could not reach the
## work. The job stays open for everyone else, but is not offered back to them.
func release(job: Job, refused_by_citizen: int = -1) -> void:
	if job == null or job.cancelled:
		return
	if refused_by_citizen >= 0:
		job.refused_by[refused_by_citizen] = true
	job.claimed_by = -1
	# A taming job's progress is the trust one rancher built with the animal.
	# It does not pass to whoever takes the job next, who would otherwise skip
	# the taming and have the cow walk to wherever they happened to be.
	if job.kind == Kind.TAME:
		job.loaded = false
		job.amount = 0.0
	var i := _claimed.find(job)
	if i >= 0:
		_claimed.remove_at(i)
		_open.append(job)


func complete(job: Job) -> void:
	_retire(job)


func cancel(job: Job) -> void:
	_retire(job)


func _retire(job: Job) -> void:
	if job == null or job.cancelled:
		return
	job.cancelled = true
	_bump(_by_dest, _dest_key(job.kind, job.dest_id, job.res), -1)
	_bump(_by_source, _source_key(job.kind, job.source_id), -1)
	_count_kind(job.kind, -1)
	if job.uses_cart:
		_cart_jobs = maxi(0, _cart_jobs - 1)
	var i := _open.find(job)
	if i >= 0:
		_open.remove_at(i)
	i = _claimed.find(job)
	if i >= 0:
		_claimed.remove_at(i)


## Give up a job's cart allocation without retiring the job — used when a
## hauler finds the cart already taken and falls back to carrying by hand.
func drop_cart_claim(job: Job) -> void:
	if job != null and job.uses_cart:
		job.uses_cart = false
		_cart_jobs = maxi(0, _cart_jobs - 1)


## Retire everything touching a building and return all of it — open jobs
## included. Returning only the claimed ones left the reservations held by
## unclaimed jobs (a source's goods, a tree's claim) stranded forever.
func cancel_for_building(building_id: int) -> Array[Job]:
	var affected: Array[Job] = []
	for job in _claimed.duplicate():
		if _touches_building(job, building_id):
			affected.append(job)
			_retire(job)
	for job in _open.duplicate():
		if _touches_building(job, building_id):
			affected.append(job)
			_retire(job)
	return affected


func _touches_building(job: Job, building_id: int) -> bool:
	return job.source_id == building_id or job.dest_id == building_id


## Retire every *unclaimed* job of one kind, and return how many went.
##
## Claimed work is left alone deliberately. A job held by a citizen owns
## whatever that citizen is in the middle of, and this board has been bitten
## before by retiring work out from under its claimant — the reservations go
## with the job, not with the worker (see `release` and `_abandon`). A holder
## whose work has stopped mattering drops it on its own next tick.
##
## Used when a standing reason for work expires rather than a single job
## finishing: the year turning out of winter, which ends the ploughing.
func cancel_open_of_kind(kind: int) -> int:
	var went := 0
	for job in _open.duplicate():
		if job.kind != kind:
			continue
		_retire(job)
		went += 1
	return went


## Retire the unclaimed jobs of one kind bound for one building. The same
## rule as `cancel_open_of_kind`, for a single destination whose reason for the
## work has lapsed while the rest of the settlement's has not.
##
## Like `cancel`, it does not give back goods or room a job reserved — that
## accounting lives in `Simulation._release_reservations`. Only use it for kinds
## that reserve nothing, such as TILL.
func cancel_open_for(kind: int, dest_id: int) -> int:
	var went := 0
	for job in _open.duplicate():
		if job.kind != kind or job.dest_id != dest_id:
			continue
		_retire(job)
		went += 1
	return went


## Every live job, open or claimed.
func all_jobs() -> Array[Job]:
	var out: Array[Job] = []
	out.append_array(_open)
	out.append_array(_claimed)
	return out


## Forget every "I could not get there" mark. Called when the world changes
## shape — a road wears in, a building goes up or comes down — because a job
## that was unreachable a moment ago may be perfectly reachable now.
func clear_refusals() -> void:
	for job in _open:
		if not job.refused_by.is_empty():
			job.refused_by.clear()
	for job in _claimed:
		if not job.refused_by.is_empty():
			job.refused_by.clear()


func clear() -> void:
	_open.clear()
	_claimed.clear()
	_by_dest.clear()
	_by_source.clear()
	_by_kind.fill(0)
	_cart_jobs = 0
