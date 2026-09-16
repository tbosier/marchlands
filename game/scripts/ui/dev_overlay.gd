class_name DevOverlay
extends Control

## Developer tools. Off unless asked for, and never part of the shipping
## presentation (design doc 30: the game should not advertise how it was made).
##
## Toggle with F3, or start with `--dev`. The panel reports where frame time is
## actually going — the same `Perf` spans the headless scenario runs print — so
## a performance regression is visible while playing rather than only in a
## build log.

const KEYS := [
	["F3", "hide this panel"],
	["F4", "spawn 10 settlers at the keep"],
	["F5", "finish every building instantly"],
	["F6", "grant 300 of every resource"],
	["F7", "wear in the route under the cursor"],
	["F8", "toggle navigation overlay"],
	["F9", "reset performance counters"],
]

signal command(name: String)

var _panel: PanelContainer
var _text: RichTextLabel
var _keys: RichTextLabel
var _timer := 0.0

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
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	rows.append("day %.2f   %s" % [sim.day, clock.season()])
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
