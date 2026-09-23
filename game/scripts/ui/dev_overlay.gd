class_name DevOverlay
extends Control

## Developer tools. Off unless asked for, and never part of the shipping
## presentation (design doc 30: the game should not advertise how it was made).
##
## Toggle with F3, or start with `--dev`. The panel reports where frame time is
## actually going — the same `Perf` spans the headless scenario runs print — so
## a performance regression is visible while playing rather than only in a
## build log.

## Keys this panel owns itself, as opposed to the commands below.
const KEYS := [
	["F3", "hide this panel"],
]

## Every developer command: its name, the key it answers to, and what it does.
##
## This table is the single source of truth for the bindings, not a description
## of them. `Game._build_dev_keys` parses column two into keycodes and dispatches
## column one, so a tool cannot acquire a key without this list documenting it
## and cannot be documented with a key it does not answer to. That is deliberate:
## the previous version of this list was hand-maintained beside a `match` in
## `game.gd`, which is exactly the arrangement that lets the two drift.
##
## Each row is also rendered as a button, because a first playtest should not
## require memorising eleven chords. "Alt+" means the developer modifier; see
## `Game._unhandled_input`.
const TOOLS := [
	["scout",    "Alt+T", "trained scout at the keep"],
	["saboteur", "Alt+B", "scout at the rival well, kit in hand"],
	["soldier",  "Alt+F", "recruit one friendly soldier"],
	["rival",    "Alt+R", "rival soldier at your keep, and war"],
	["war",      "Alt+X", "declare war on the rival town"],
	["kill",     "Alt+K", "kill the selected soldiers"],
	["wound",    "Alt+J", "wound the selected soldier"],
	["poison",   "Alt+P", "poison one of your own wells"],
	["ignite",   "Alt+I", "set the selected building alight"],
	["season",   "Alt+N", "jump to the next season"],
	["frost",    "Alt+Z", "jump to the eve of the next hard frost"],
	["settlers", "F4",    "spawn 10 settlers at the keep"],
	["finish",   "F5",    "finish every building instantly"],
	["grant",    "F6",    "grant 300 of every resource"],
	["wear",     "F7",    "wear in the route under the cursor"],
	["nav",      "F8",    "toggle navigation overlay"],
	["perf",     "F9",    "reset performance counters"],
]

## Where a wound lands, and how hard. Both are read by the wound command at the
## moment it fires, so the same key wounds a different limb once the dropdown
## moves. The forces are chosen against `soldier_body.gd`: DISABLED_AT is 45 and
## SEVERED_AT is 75 of accumulated cut, and a plate arm absorbs 38 of a slash —
## so 120 severs through the best armour in the game, 60 disables an unarmoured
## limb without taking it off, and 18 is a wound that heals.
const WOUND_LOCATIONS := ["arm_r", "arm_l", "leg_r", "leg_l", "torso", "head"]
const WOUND_SEVERITIES := [["graze", 18.0], ["cripple", 60.0], ["maim", 120.0]]

signal command(name: String)

var _panel: PanelContainer
var _text: RichTextLabel
var _keys: RichTextLabel
var _timer := 0.0
var campaign: Node
var _personality: OptionButton
var _campaign_label: Label
var _tool_buttons: Dictionary = {}
var _wound_location: OptionButton
var _wound_severity: OptionButton

var sim: Simulation
var clock: Clock
var world: World
var camera: RTSCamera


## Point the overlay at a simulation and build its panel.
##
## Loading a save replaces the world and the simulation under an overlay that
## outlives both, so this runs more than once a session. Only the rebind may
## repeat: building the panel again left the old one parented and only the
## newest receiving text, and resetting `visible` closed an overlay the player
## had deliberately opened.
func setup(p_sim: Simulation, p_clock: Clock, p_world: World,
		   p_camera: RTSCamera) -> void:
	sim = p_sim
	clock = p_clock
	world = p_world
	camera = p_camera
	if _panel != null:
		return

	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.07, 0.90)
	style.border_color = Color(0.35, 0.55, 0.45, 0.9)
	style.set_border_width_all(1)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", style)
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 12
	_panel.offset_top = 52
	# Stops clicks: the gaps between its rows used to reach the world beneath.
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_panel.add_child(col)

	var title := Label.new()
	title.text = "DEV"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.55, 0.85, 0.68))
	col.add_child(title)

	_text = _mono(430)
	col.add_child(_text)

	_keys = _mono(430)
	_keys.add_theme_color_override("default_color", Color(0.62, 0.66, 0.64))
	var lines: Array[String] = []
	for row in KEYS:
		lines.append("%-4s %s" % [row[0], row[1]])
	_keys.text = "\n".join(lines)
	col.add_child(_keys)
	_campaign_label = Label.new()
	_campaign_label.text = "Rival personality"
	col.add_child(_campaign_label)
	_personality = OptionButton.new()
	_personality.focus_mode = Control.FOCUS_NONE
	for value in ["aggressive", "peaceful", "loner"]:
		_personality.add_item(value.capitalize())
	_personality.item_selected.connect(func(index):
		if is_instance_valid(campaign):
			campaign.set_personality(["aggressive", "peaceful", "loner"][index]))
	col.add_child(_personality)

	# Below the personality selector, deliberately. `tests/expansion_ui.gd`
	# clicks that dropdown through a real viewport and then clicks inside its
	# popup; anything inserted above it moves it and its popup, and the rendered
	# suite needs a display to notice. Growing downwards moves nothing.
	#
	# Two columns rather than one: seventeen full-width rows pushed the panel
	# off the bottom of a 720-line window, and a tool nobody can see is the
	# problem this list exists to solve.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 0)
	col.add_child(grid)
	for row in TOOLS:
		var id: String = row[0]
		var button := Button.new()
		button.text = "%-5s %s" % [row[1], row[2]]
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_color_override("font_color", Color(0.72, 0.80, 0.76))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Space and Enter belong to the game, not to the last button clicked.
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(command.emit.bind(id))
		grid.add_child(button)
		_tool_buttons[id] = button

	var wounds := HBoxContainer.new()
	wounds.add_theme_constant_override("separation", 4)
	col.add_child(wounds)
	var wound_label := Label.new()
	wound_label.text = "Wound"
	wound_label.add_theme_font_size_override("font_size", 11)
	wounds.add_child(wound_label)
	_wound_location = OptionButton.new()
	_wound_location.focus_mode = Control.FOCUS_NONE
	for location in WOUND_LOCATIONS:
		_wound_location.add_item(location)
	wounds.add_child(_wound_location)
	_wound_severity = OptionButton.new()
	_wound_severity.focus_mode = Control.FOCUS_NONE
	for severity in WOUND_SEVERITIES:
		_wound_severity.add_item(severity[0])
	# A severed arm is the injury the persistence rule is actually about — a
	# veteran who loses one works at 45% and one who loses both cannot work at
	# all — so that is what the panel offers first.
	_wound_severity.select(WOUND_SEVERITIES.size() - 1)
	wounds.add_child(_wound_severity)


func _mono(width: int) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.custom_minimum_size = Vector2(width, 0)
	label.add_theme_font_size_override("normal_font_size", 11)
	label.add_theme_font_size_override("mono_font_size", 11)
	label.add_theme_color_override("default_color", Color(0.84, 0.88, 0.86))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = 0.25
		_refresh()


func _refresh() -> void:
	if sim == null:
		return
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)

	var rows: Array[String] = []
	rows.append("[b]%5.1f fps[/b]   %6.2f ms/frame   sim %s"
			% [fps, frame_ms, clock.speed_label()])
	# The year and the frost note are here because two of the commands above
	# move the calendar, and a jump the panel cannot confirm is a jump the
	# player has to take on trust. `season_note` is also the line the top bar
	# drops first when the window is narrow, so this is sometimes the only
	# place the frost deadline is legible at all.
	rows.append("day %.2f   year %d   %s · %s"
			% [sim.day, Clock.year_at(sim.day), clock.season(), clock.season_note()])
	rows.append("")
	rows.append("citizens %-5d buildings %-4d jobs %d open / %d total"
			% [sim.citizens.size(), sim.buildings.size(),
			   sim.jobs.open_jobs(), sim.jobs.total_jobs()])
	rows.append("idle %-9d homeless %-6d" % [sim.stat_idle, sim.stat_homeless])

	var counts := _render_counts()
	rows.append("draw calls %-6d verts %s"
			% [counts["draw"], _thousands(counts["verts"])])

	rows.append("")
	rows.append("[b]frame budget[/b]")
	var report := Perf.report()
	if report.is_empty():
		rows.append("  (no samples yet)")
	else:
		for line in report:
			rows.append(line)

	_text.text = "\n".join(rows)


func _render_counts() -> Dictionary:
	return {
		"draw": RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"verts": RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
	}


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = " " + out
	return out


## Where the next developer wound lands, and how hard.
##
## Read at the moment the command fires rather than remembered when the dropdown
## moves, so the key and the button always agree with what the panel shows. Both
## answer for an overlay whose `setup` has not run, with the same defaults the
## built panel opens on, so a wound command can never fail on a missing control.
func wound_location() -> String:
	if _wound_location == null:
		return WOUND_LOCATIONS[0]
	return WOUND_LOCATIONS[clampi(_wound_location.selected, 0,
			WOUND_LOCATIONS.size() - 1)]


func wound_force() -> float:
	var last := WOUND_SEVERITIES.size() - 1
	if _wound_severity == null:
		return float(WOUND_SEVERITIES[last][1])
	return float(WOUND_SEVERITIES[clampi(_wound_severity.selected, 0, last)][1])


func bind_campaign(value: Node) -> void:
	campaign = value
	if _personality != null and is_instance_valid(campaign):
		_personality.select(["aggressive", "peaceful", "loner"].find(campaign.personality))
		_campaign_label.text = "Ashcombe personality · edits apply immediately"


## Whether a click at `at` lands on the panel rather than the world.
func blocks_mouse(at: Vector2) -> bool:
	return visible and _panel != null and _panel.visible \
			and _panel.get_global_rect().has_point(at)
