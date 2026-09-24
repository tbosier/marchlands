class_name Tips
extends PanelContainer

## Advice for a player who has not yet found out how the march works.
##
## Each tip watches for the situation it is about — beds all taken, the wells
## at their limit, food running short — and is shown once, the first time that
## situation arises, with a pause of at least GAP_MS between tips so they never
## pile up. "Don't show tips" turns them off for good; the Tips button on the
## bottom bar turns them back on. Both that choice and which tips have been
## seen are kept in the settings file, not the save, so a returning player is
## not told again what they already know.

signal enabled_changed(on: bool)

const SETTINGS := "user://settings.cfg"
const GAP_MS := 45000
const FIRST_AFTER_MS := 8000

## id, then the advice. The situation each one watches for is in `_applies`.
const TIPS := [
	["beds", "Want more people? Settlers only come to free beds. Build hovels "
			+ "from the Homes tab; later, research lets you upgrade them to cottages."],
	["water", "Each well keeps about twenty people in water. Newcomers will not "
			+ "come until there is another well."],
	["timber", "Timber builds almost everything. Put a logging camp near trees "
			+ "(Industry tab)."],
	["stone", "Stone runs short fast. A quarry on an outcrop (Industry tab) "
			+ "keeps building going."],
	["food", "Food is running low. Farms (Food tab) feed the march; a granary "
			+ "near the houses keeps it close to the people who eat it."],
	["winter", "Winter is coming: nothing grows until spring. Bring the harvest "
			+ "in and keep enough food to last until the fields wake."],
	["idle", "People are standing idle. Place a building or a workplace to give "
			+ "them something to do. Hover the population to see why."],
	["tools", "Tools are wearing out, and work slows without them. A blacksmith "
			+ "makes tools from iron and timber."],
	["research", "The market is up: open Research for roadworks, better tools "
			+ "and cottages."],
	["scouts", "Beyond the fog is a rival town. Build a scout lodge and send a "
			+ "scout out: select him, then right-click where to go."],
	["army", "Right-click the ground to march your soldiers, or right-click an "
			+ "enemy to attack. Hold Shift to add to the selection."],
]

var enabled := true
var _game: Node
var _seen: Dictionary = {}
var _showing := ""
var _next_at := 0
var _label: Label


func setup(game: Node) -> void:
	_game = game
	var settings := ConfigFile.new()
	if settings.load(SETTINGS) == OK:
		enabled = bool(settings.get_value("tips", "enabled", true))
		for id in settings.get_value("tips", "seen", []):
			_seen[String(id)] = true
	_next_at = Time.get_ticks_msec() + FIRST_AFTER_MS

	name = "tips"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Middle of the left edge: clear of the alerts, the selection panel on the
	# right, and the unit grid and build tray along the bottom.
	set_anchors_preset(Control.PRESET_CENTER_LEFT)
	grow_vertical = Control.GROW_DIRECTION_BOTH
	offset_left = 12.0
	custom_minimum_size = Vector2(320, 0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.10, 0.10, 0.09, 0.93)
	box.border_color = Color(0.78, 0.64, 0.36)
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	box.set_content_margin_all(10)
	add_theme_stylebox_override("panel", box)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	var title := Label.new()
	title.text = "Tip"
	title.add_theme_color_override("font_color", Color(0.90, 0.75, 0.45))
	column.add_child(title)
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(300, 0)
	column.add_child(_label)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)
	var ok := Button.new()
	ok.name = "got_it"
	ok.text = "Got it"
	ok.focus_mode = Control.FOCUS_NONE
	ok.pressed.connect(dismiss)
	buttons.add_child(ok)
	var off := Button.new()
	off.name = "no_tips"
	off.text = "Don't show tips"
	off.focus_mode = Control.FOCUS_NONE
	off.pressed.connect(func(): set_enabled(false))
	buttons.add_child(off)


## Look for the first unseen tip whose situation has arisen. Cheap enough for
## the interface's quarter-second refresh: it returns at once while a tip is up
## or the gap since the last one has not run.
func poll() -> void:
	if not enabled or visible or _game == null or Time.get_ticks_msec() < _next_at:
		return
	for row in TIPS:
		var id: String = row[0]
		if not _seen.has(id) and _applies(id):
			show_tip(id)
			return


func show_tip(id: String) -> void:
	for row in TIPS:
		if row[0] == id:
			_showing = id
			_label.text = row[1]
			_seen[id] = true
			visible = true
			_save()
			return


func dismiss() -> void:
	visible = false
	_showing = ""
	_next_at = Time.get_ticks_msec() + GAP_MS


## Turning tips back on starts them over: a player who asks for them again
## wants to be reminded, and every tip may already have been seen.
func set_enabled(on: bool) -> void:
	enabled = on
	if on:
		_seen.clear()
	else:
		visible = false
		_showing = ""
	_next_at = Time.get_ticks_msec() + FIRST_AFTER_MS
	_save()
	enabled_changed.emit(on)


func showing() -> String:
	return _showing


func _applies(id: String) -> bool:
	var sim: Simulation = _game.sim
	if sim == null or sim.keep == null:
		return false
	var members := sim.population_members()
	match id:
		"beds":
			return sim.population.housing_capacity(sim.buildings) - members.size() \
					< Config.IMMIGRATION_GROUP_MIN
		"water":
			var room := sim.water_room()
			return room >= 0 and room < Config.IMMIGRATION_GROUP_MIN
		"timber":
			return not _has(sim, "logging_camp") and sim.total_resource(Config.Res.TIMBER) < 40.0
		"stone":
			return not _has(sim, "quarry") and sim.total_resource(Config.Res.STONE) < 20.0
		"food":
			return sim.food_days_remaining() < 8.0
		"winter":
			return Clock.season_index_at(sim.day) == Clock.AUTUMN
		"idle":
			return sim.idle_diagnosis() != ""
		"tools":
			return sim.total_resource(Config.Res.TOOLS) < 10.0 and not _has(sim, "blacksmith")
		"research":
			return _has(sim, "market") and sim.research.active == "" \
					and sim.research.completed.is_empty()
		"scouts":
			return sim.day > 6.0 and not _has(sim, "scout_lodge") \
					and sim.scouting != null and sim.scouting.city_report().is_empty()
		"army":
			return not _game.selected_units.is_empty()
	return false


static func _has(sim: Simulation, type_id: String) -> bool:
	for b in sim.buildings:
		if b.type_id == type_id and not b.under_construction:
			return true
	return false


func _save() -> void:
	var settings := ConfigFile.new()
	settings.load(SETTINGS)
	settings.set_value("tips", "enabled", enabled)
	settings.set_value("tips", "seen", _seen.keys())
	settings.save(SETTINGS)
