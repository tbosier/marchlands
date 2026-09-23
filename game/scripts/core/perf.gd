class_name Perf
extends RefCounted

## A tiny always-on profiler.
##
## Godot's own profiler needs the editor attached, which is no use for the
## headless scenario runs that verify this project. This records named spans
## and counters cheaply enough to leave enabled, so `tools/build.sh harness`
## can print a performance report next to its correctness assertions.
##
## Usage:
##     Perf.begin("sim.jobs")
##     ...
##     Perf.end("sim.jobs")
##     Perf.count("paths", 1)
##
## Spans are wall-clock microseconds, averaged over a rolling window of frames.

const WINDOW := 60

static var enabled := true

static var _open: Dictionary = {}          # name -> start usec
static var _frame: Dictionary = {}         # name -> usec accumulated this frame
static var _history: Dictionary = {}       # name -> Array[float] of frame usec
static var _counters: Dictionary = {}      # name -> count this frame
static var _counter_history: Dictionary = {}


static func begin(span: String) -> void:
	if not enabled:
		return
	_open[span] = Time.get_ticks_usec()


static func end(span: String) -> void:
	if not enabled:
		return
	var start: Variant = _open.get(span)
	if start == null:
		return
	var elapsed := Time.get_ticks_usec() - int(start)
	_frame[span] = float(_frame.get(span, 0.0)) + elapsed
	_open.erase(span)


static func count(name: String, n: int = 1) -> void:
	if not enabled:
		return
	_counters[name] = int(_counters.get(name, 0)) + n


## Call once per frame, after everything else has run.
static func flush_frame() -> void:
	if not enabled:
		return
	for name in _frame:
		var series: Array = _history.get(name, [])
		series.append(_frame[name])
		if series.size() > WINDOW:
			series.pop_front()
		_history[name] = series
	# A span that ran last frame but not this one must record a zero, or its
	# average silently reports the last busy frame forever.
	for name in _history:
		if not _frame.has(name):
			var series: Array = _history[name]
			series.append(0.0)
			if series.size() > WINDOW:
				series.pop_front()

	for name in _counters:
		var series: Array = _counter_history.get(name, [])
		series.append(_counters[name])
		if series.size() > WINDOW:
			series.pop_front()
		_counter_history[name] = series
	for name in _counter_history:
		if not _counters.has(name):
			var series: Array = _counter_history[name]
			series.append(0)
			if series.size() > WINDOW:
				series.pop_front()

	_frame.clear()
	_counters.clear()
	_open.clear()


static func average_ms(span: String) -> float:
	var series: Array = _history.get(span, [])
	if series.is_empty():
		return 0.0
	var total := 0.0
	for v in series:
		total += float(v)
	return (total / series.size()) / 1000.0


static func peak_ms(span: String) -> float:
	var series: Array = _history.get(span, [])
	var top := 0.0
	for v in series:
		top = maxf(top, float(v))
	return top / 1000.0


static func average_count(name: String) -> float:
	var series: Array = _counter_history.get(name, [])
	if series.is_empty():
		return 0.0
	var total := 0.0
	for v in series:
		total += float(v)
	return total / series.size()


static func span_names() -> Array:
	var names := _history.keys()
	names.sort()
	return names


static func counter_names() -> Array:
	var names := _counter_history.keys()
	names.sort()
	return names


static func reset() -> void:
	_open.clear()
	_frame.clear()
	_history.clear()
	_counters.clear()
	_counter_history.clear()


## A one-line-per-span report, slowest first.
static func report() -> Array[String]:
	var rows: Array[String] = []
	var names := span_names()
	names.sort_custom(func(a, b): return average_ms(a) > average_ms(b))
	for name in names:
		var avg := average_ms(name)
		if avg < 0.001:
			continue
		rows.append("  %-26s %7.3f ms avg   %7.3f ms peak"
				% [name, avg, peak_ms(name)])
	for name in counter_names():
		var avg := average_count(name)
		if avg < 0.01:
			continue
		rows.append("  %-26s %9.1f per frame" % [name, avg])
	return rows
