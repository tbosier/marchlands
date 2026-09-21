class_name Clock
extends RefCounted

## Real-time simulation with pause and speed controls (design doc 3.2).

signal speed_changed(index: int)
signal day_changed(day: int)

const SEASONS: Array[String] = ["Spring", "Summer", "Autumn", "Winter"]

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
	var index := floori(elapsed_days / Config.DAYS_PER_SEASON) % SEASONS.size()
	return SEASONS[index]


## Position in the year as 0..1, with 0 the first morning of spring. The
## lighting rig grades the sun, the sky, the haze and the colour of the ground
## off this, so it wants the continuous value rather than the season's name.
func season_fraction() -> float:
	return fposmod(elapsed_days
			/ float(Config.DAYS_PER_SEASON * SEASONS.size()), 1.0)


func year() -> int:
	return 1 + floori(elapsed_days
			/ (Config.DAYS_PER_SEASON * SEASONS.size()))


func clock_text() -> String:
	var minutes := int(day_fraction() * 24.0 * 60.0)
	return "%02d:%02d" % [minutes / 60, minutes % 60]


func speed_label() -> String:
	return Config.SPEED_LABELS[speed_index]


func date_text() -> String:
	return "%s, Year %d — Day %d  %s" % [season(), year(), day_number(),
			clock_text()]
