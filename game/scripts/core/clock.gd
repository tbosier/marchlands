class_name Clock
extends RefCounted

## Real-time simulation with pause and speed controls (design doc 3.2).

signal speed_changed(index: int)
signal day_changed(day: int)

const SEASONS: Array[String] = ["Spring", "Summer", "Autumn", "Winter"]
## Indices into SEASONS. Named because the agricultural rules below turn on
## them and `== 3` says nothing about frost to anyone reading later.
const SPRING := 0
const SUMMER := 1
const AUTUMN := 2
const WINTER := 3

## Play opens in mid-morning light rather than at midnight — the settlement
## has to be legible the moment the game starts.
const START_TIME_OF_DAY := 0.36

var speed_index := Config.NORMAL_SPEED
var elapsed_days := START_TIME_OF_DAY
var _last_whole_day := 0
var _resume_index := Config.NORMAL_SPEED


func scale() -> float:
	return Config.SPEEDS[speed_index]


func paused() -> bool:
	return speed_index == 0


func set_speed(index: int) -> void:
	var clamped := clampi(index, 0, Config.SPEEDS.size() - 1)
	if clamped > 0:
		_resume_index = clamped
	if clamped == speed_index:
		return
	speed_index = clamped
	speed_changed.emit(speed_index)


## Select the speed closest to `rate`. Callers that mean "run at 4x" should say
## so rather than naming an index — the list of available rates is a tuning
## decision and has already changed once.
func set_rate(rate: float) -> void:
	var best := 0
	var best_diff := INF
	for i in Config.SPEEDS.size():
		var diff: float = absf(Config.SPEEDS[i] - rate)
		if diff < best_diff:
			best_diff = diff
			best = i
	set_speed(best)


func toggle_pause() -> void:
	# Unpausing returns to the rate you were at, not to a fixed 1x.
	if speed_index != 0:
		set_speed(0)
	else:
		set_speed(_resume_index)


func resume_speed_index() -> int:
	return _resume_index


## A paused save belongs to its own clock, not the session it replaces.
func restore_speed(index: int, resume_index: int = Config.NORMAL_SPEED) -> void:
	_resume_index = clampi(resume_index, 1, Config.SPEEDS.size() - 1)
	set_speed(index)


## Version-one files before the market update stored indices into the slower
## speed menu. Preserve their rate; retired fractional rates resume at 1x.
func restore_saved_speed(data: Dictionary) -> void:
	if int(data.get("speed_layout", 1)) == 2:
		restore_speed(int(data.speed_index), int(data.get("resume_speed_index", Config.NORMAL_SPEED)))
		return
	var legacy := [0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 16.0]
	set_rate(maxf(1.0, legacy[int(data.get("resume_speed_index", 3))]))
	var resume := speed_index
	if int(data.speed_index) == 0:
		restore_speed(0, resume)
	else:
		set_rate(maxf(1.0, legacy[int(data.speed_index)]))


## Returns in-game seconds elapsed this frame.
func advance(real_delta: float) -> float:
	var sim_delta := real_delta * scale()
	if sim_delta <= 0.0:
		return 0.0
	elapsed_days += sim_delta / Config.DAY_LENGTH
	var whole := floori(elapsed_days)
	if whole != _last_whole_day:
		_last_whole_day = whole
		day_changed.emit(whole)
	return sim_delta


## Put the whole-day marker where a load leaves the calendar, so the first
## advance afterwards does not announce a day that has already passed.
func set_day_marker(whole_day: int) -> void:
	_last_whole_day = whole_day


func day_number() -> int:
	return floori(elapsed_days) + 1


func day_fraction() -> float:
	return fposmod(elapsed_days, 1.0)


func season() -> String:
	return season_at(elapsed_days)


# ---------------------------------------------------------------------------
# The agricultural year (design/NORTH_STAR.md — "Seasonal farming")
# ---------------------------------------------------------------------------
#
# Every rule below is a *pure function of the day counter*, and that is the
# whole design, not an implementation detail. `Simulation.day` and this
# clock's `elapsed_days` are the same number by construction (see the note in
# `Simulation.setup`), and both are already written to every save. So the
# season, the year, the frost and whether that frost bites all survive a save
# and a load without a single new field being persisted — which matters a
# great deal here, because `save_validation.gd` hard-rejects a version
# mismatch and this build has no migration system at all. A season that kept
# its own saved state would have broken every existing file.
#
# They are static so that the simulation can ask "what month is it at day
# 41.6?" without owning a Clock, and so that a test can ask the same question
# without running one.


## Days in a full turn of the year.
static func days_per_year() -> int:
	return Config.DAYS_PER_SEASON * SEASONS.size()


## Which season a given absolute day falls in, as an index into SEASONS.
static func season_index_at(day: float) -> int:
	return posmod(floori(day / float(Config.DAYS_PER_SEASON)), SEASONS.size())


static func season_at(day: float) -> String:
	return SEASONS[season_index_at(day)]


static func year_at(day: float) -> int:
	return 1 + floori(day / float(days_per_year()))


## Whether crops come on at all. Three seasons grow; the fourth takes it away.
static func is_growing_at(day: float) -> bool:
	return season_index_at(day) != WINTER


## How long until the next frost — the first instant of winter. Inside winter
## this is the distance to *next* year's frost, which is the honest answer:
## the deadline you can still act on.
static func days_to_frost(day: float) -> float:
	var year_length := float(days_per_year())
	var year_day := fposmod(day, year_length)
	var frost := float(Config.DAYS_PER_SEASON * WINTER)
	if year_day < frost:
		return frost - year_day
	return year_length - year_day + frost


## How long ago this year's frost fell, in days. Only meaningful inside winter;
## zero or negative anywhere else.
static func days_since_frost(day: float) -> float:
	return fposmod(day, float(days_per_year())) \
			- float(Config.DAYS_PER_SEASON * WINTER)


## Whether the frost that ends this year's growing season takes the standing
## crop with it.
##
## The opening winter does not. A player cannot be expected to anticipate a
## rule the game has never shown them, and losing a settlement to one is how
## this genre loses people in the first hour — so the first winter stops the
## fields, frees the farmhands and turns the world white while destroying
## nothing. See `Config.MILD_WINTERS`.
static func frost_is_hard_at(day: float) -> bool:
	return year_at(day) > Config.MILD_WINTERS


## Position in the year as 0..1, with 0 the first morning of spring. The
## lighting rig grades the sun, the sky, the haze and the colour of the ground
## off this, so it wants the continuous value rather than the season's name.
func season_fraction() -> float:
	return fposmod(elapsed_days
			/ float(Config.DAYS_PER_SEASON * SEASONS.size()), 1.0)


func year() -> int:
	return year_at(elapsed_days)


func clock_text() -> String:
	var minutes := int(day_fraction() * 24.0 * 60.0)
	return "%02d:%02d" % [minutes / 60, minutes % 60]


func speed_label() -> String:
	return Config.SPEED_LABELS[speed_index]


## What the season means for the fields, in as few words as will carry it.
##
## The date line is the only place the interface says anything about the
## calendar, so if the harvest deadline is not here the player has no way to
## see it coming — and a deadline nobody can see is not a deadline, it is an
## ambush. Autumn counts down out loud; winter says plainly whether it is the
## mild one or the one that takes the crop.
##
## Kept as short as it can be said. `hud.gd` drops this whole line first when
## the top bar will not fit (`Hud._layout`, degrade stage 0), so every word
## added here is window width bought at the cost of the deadline disappearing
## sooner on a small screen.
##
## The mild year says so *while there is still time to act on it* — in autumn,
## beside the countdown, not after the frost has come and gone. A first year
## whose countdown read exactly like the second year's, and then turned out
## not to mean anything, would teach a player that the countdown is decoration:
## precisely the wrong lesson, and worse than never having shown it.
func season_note() -> String:
	var season := season_index_at(elapsed_days)
	var hard := frost_is_hard_at(elapsed_days)
	if season == WINTER:
		return "fields frozen" if hard else "mild winter"
	if season == AUTUMN:
		var left := maxi(1, ceili(days_to_frost(elapsed_days)))
		var day_word := "day" if left == 1 else "days"
		# "mild winter", not "mild frost": the opening winter's frost takes
		# nothing at all, and calling it mild would say it bites gently.
		return "frost in %d %s" % [left, day_word] if hard \
				else "mild winter in %d %s" % [left, day_word]
	return "growing"


func date_text() -> String:
	return "%s, Year %d — Day %d  %s · %s" % [season(), year(), day_number(),
			clock_text(), season_note()]
