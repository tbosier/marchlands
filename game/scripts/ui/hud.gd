class_name HUD
extends Control

## The whole prototype interface, built in code so there is no .tscn to keep
## in sync with the scripts.
##
## Four regions: a resource bar across the top, the build bar along the bottom,
## a selection panel on the right, and an alert feed on the left.
##
## Everything is drawn from one small design system declared at the top of this
## file — a five-step type scale, a palette of warm near-blacks and inks, and a
## handful of shared style boxes — rather than from Godot's stock control theme.
## That is the difference between an interface and a debug harness: stock Button
## chrome is a grey bevel that belongs to no game, and six of them in a row over
## a sunlit landscape look exactly like what they are. The bars here are ink and
## iron with a single gilt accent, which is the same material language as the
## settlement underneath them.

signal build_requested(type_id: String)
signal build_cancelled()
signal speed_requested(index: int)
signal upgrade_route_requested()
signal road_scope_requested(scope: String)
signal research_open_requested()
signal tips_toggle_requested()
signal idle_focus_requested()
## A tile in the unit grid was clicked: select just that soldier, or with
## Shift held, drop him from the selection.
signal unit_pick_requested(unit_id: int, remove: bool)
signal research_requested(tech_id: String)
signal army_open_requested()
signal scouting_open_requested()
signal scout_train_requested(lodge_id: int)
signal scout_select_requested(scout_id: int)
signal scout_recall_requested(scout_id: int)
signal scout_visit_requested(scout_id: int)
signal city_report_requested()
signal medic_requested(unit_id: int)
signal firefighting_requested(building_id: int)
signal poison_well_requested(scout_id: int)
signal purge_well_requested(well_id: int)
signal purge_cancel_requested(well_id: int)
signal recruit_requested()
signal muster_requested()
signal company_form_requested()
signal company_disband_requested(company_id: int)
signal rival_focus_requested()
signal armor_requested(unit_id: int, tier: String)
signal demobilize_requested(unit_id: int)
signal domesticate_requested(cow_id: int)
signal cattle_focus_requested()
signal trade_open_requested()
signal trade_dispatch_requested(origin_id: int, target_id: int)
signal caravan_recall_requested(caravan_id: int)
signal caravan_repeat_requested(caravan_id: int, enabled: bool)
signal wreck_recovery_requested(wreck_id: int, enabled: bool)
signal bridge_tool_requested()
signal bridge_remove_requested(bridge_id: int)
signal new_world_requested(seed_value: int, size_m: int)
signal market_target_requested(building: Building, target: int)
signal demolish_requested(building: Building)
signal upgrade_requested(building: Building)
signal clear_ground_requested()
signal focus_requested(position: Vector3)

# --- The design system -------------------------------------------------------

## Type scale. Five steps, each used for one job, so the interface has a
## rhythm instead of eleven arbitrary sizes.
const F_MICRO := 11     ## costs, captions, the hint line
const F_SMALL := 12     ## body copy, button labels
const F_BODY := 13      ## readouts — the numbers you scan
const F_LEAD := 15      ## panel titles
const F_TITLE := 16     ## the wordmark

## Palette. Warm near-blacks rather than neutral grey, because the world below
## is warm and a neutral chrome floats off it.
const BG := Color(0.086, 0.082, 0.076, 0.965)
const BG_PANEL := Color(0.105, 0.100, 0.092, 0.975)
const BG_SUNK := Color(0.052, 0.050, 0.046, 0.92)
const BG_RAISED := Color(0.158, 0.150, 0.138, 1.0)
const LINE := Color(0.27, 0.25, 0.22, 0.95)
const LINE_SOFT := Color(0.20, 0.19, 0.17, 0.75)

const INK := Color(0.93, 0.90, 0.84)
const INK_DIM := Color(0.63, 0.60, 0.55)
const INK_FAINT := Color(0.44, 0.42, 0.39)
const WARN := Color(0.90, 0.69, 0.35)
const BAD := Color(0.86, 0.45, 0.39)
const ACCENT := Color(0.83, 0.71, 0.43)
const ACCENT_DEEP := Color(0.46, 0.38, 0.22)

## Bar and tray metrics, in one place so the panels that have to clear them can
## be derived rather than guessed.
##
## The top bar has to be tall enough for the tallest thing in it, which is the
## speed control: 26 px of button inside 3 px of well on each side is 32, and
## the holder that carries it clips its contents, so anything less would
## silently shave the top and bottom off every rate button.
const TOP_BAR_H := 46.0
const TOP_BAR_INNER_H := 34.0
const TRAY_CARD_H := 54.0
## Open, the bar is two rows: the toggle with the category tabs, then the
## cards. Sharing one row, the tabs pushed the cards off a 640 px window.
const BAR_OPEN_H := BAR_CLOSED_H + TRAY_CARD_H + 16.0
const BAR_CLOSED_H := 46.0

var _res_labels: Array[Label] = []
var _res_name_labels: Array[Label] = []
var _clock_label: Label
var _city_marker: Button
var _pop_label: Label
var _speed_buttons: Array[Button] = []
var _build_buttons: Dictionary = {}
## type_id -> { "name": Label, "cost": Label, "icon": TextureRect }.
## The build tray's cards are laid out by hand inside the buttons, because a
## stock Button can only colour its whole label at once and the name and the
## price want to read differently.
var _build_cards: Dictionary = {}
var _selection_panel: PanelContainer
var _selection_title: Label
var _selection_rule: HSeparator
var _selection_body: RichTextLabel
var _selection_actions: VBoxContainer
var _selection_scroll: ScrollContainer
var _selection_content: VBoxContainer
var _alert_box: VBoxContainer
var _hint_label: Label
var _tooltip: PanelContainer
var _tooltip_label: RichTextLabel

var _title_label: Label
var _date_label: Label
var _top_row: HBoxContainer
var _build_toggle: Button
var _build_tray: HBoxContainer
var _build_scroll: ScrollContainer
var _build_spacer: Control
var _clear_button: Button
var _build_bar: PanelContainer
var _controls_row: HBoxContainer
var _speed_group: PanelContainer
var _sim: Simulation
## Set once the widgets exist, so a rebind after a load does not build them
## a second time.
var _built := false
var _clock: Clock
var _active_build := ""
var _compact := false
var _primary_actions: Array[Button] = []
## The build tray's category tabs, shown in place of the primary actions while
## the tray is open, and which one is showing.
var _tray_tabs: Dictionary = {}
## What the resource and population tooltips say, rebuilt each refresh and read
## by LiveTipLabel when a tooltip opens.
var _res_tips: Array[String] = []
var _pop_tip := ""
var _idle_button: Button
var _tips_button: Button
var _tray_category := ""
var _world_dialog: ConfirmationDialog
var _world_size_choice: OptionButton
var _world_seed_input: LineEdit
var _selection_scroll_limit := 600.0
var _idle_reason := ""
var _base_hint := ""
var _hint_room := true
## What the selection panel's action buttons currently represent. See
## _actions_changed: this is what stops a periodic refresh from destroying a
## button the player is in the middle of pressing.
var _actions_signature := ""

# Shared style boxes. Built once and handed to every control that wants them:
# a StyleBox is a resource, so one instance can dress thirty buttons.
var _sb_btn: StyleBoxFlat
var _sb_btn_hover: StyleBoxFlat
var _sb_btn_pressed: StyleBoxFlat
var _sb_btn_disabled: StyleBoxFlat
var _sb_card: StyleBoxFlat
var _sb_card_hover: StyleBoxFlat
var _sb_card_pressed: StyleBoxFlat
var _sb_chip: StyleBoxFlat
var _sb_chip_hover: StyleBoxFlat
var _sb_chip_pressed: StyleBoxFlat


## Point the interface at a simulation and build the widgets.
##
## Loading a save replaces the world and the simulation beneath a HUD that
## outlives both, so this is called more than once per session. Everything it
## does past the rebind is guarded accordingly — building the bars twice would
## stack two of every readout, and connecting to `size_changed` twice is an
## error Godot reports and then ignores.
func setup(sim: Simulation, clock: Clock) -> void:
	_sim = sim
	_clock = clock
	if _built:
		clear_alerts()
		clear_selection()
		refresh()
		return
	_built = true

	# Anchors alone do not size a Control that hangs off a CanvasLayer: it
	# stays zero-sized, every anchored child lands somewhere meaningless, and
	# the selection panel ends up off the left edge of the screen where a
	# player clicking a building never sees it. Offsets have to be set too,
	# and the whole thing re-fitted whenever the window changes.
	# The viewport size is assigned explicitly below; equal anchors keep
	# Godot from overriding it after _ready and warning on every launch.
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(_fit_to_viewport)

	_build_styles()
	_build_top_bar()
	_build_bottom_bar()
	_build_selection_panel()
	_build_unit_grid()
	_build_alerts()
	_build_tooltip()
	_fit_to_viewport()
	refresh()


func _fit_to_viewport() -> void:
	if _city_marker != null: _city_marker.hide()
	var rect := get_viewport_rect().size
	position = Vector2.ZERO
	size = rect
	_relayout(rect)


## Size the tray's cards for the window and the tab showing. Only the cards
## in the open tab share the row, so a tab of three spreads them wider than
## the old single tray of fifteen could.
func _layout_tray_cards() -> void:
	var width := size.x
	var shown := 0
	for type_id in _build_buttons:
		if BuildingDefs.tray_category(type_id) == _tray_category:
			shown += 1
	for type_id in _build_buttons:
		var b: Button = _build_buttons[type_id]
		var def := BuildingDefs.get_def(type_id)
		b.tooltip_text = "%s\n%s\n\n%s" % [def.display_name,
				def.cost_text(), def.description]
		# The tray scrolls horizontally, so preserve complete names and prices
		# instead of squeezing every building into the visible row.
		var per: float = (width - 128.0) / float(maxi(1, shown))
		var button_w: float = clampf(per, 152.0, 176.0)
		b.custom_minimum_size = Vector2(button_w, TRAY_CARD_H)

		var parts: Dictionary = _build_cards[type_id]
		var name_label: Label = parts["name"]
		var cost_label: Label = parts["cost"]
		var icon_rect: TextureRect = parts["icon"]
		name_label.text = def.display_name
		cost_label.text = def.cost_text()
		name_label.add_theme_font_size_override("font_size", F_SMALL)
		cost_label.visible = true
		var icon_size := 32.0
		icon_rect.visible = icon_rect.texture != null
		icon_rect.custom_minimum_size = Vector2(icon_size, icon_size)

		# Fit the price to the column rather than letting it clip. At the
		# widest the tray ever gets, "26 Timber, 14 Stone" is a few pixels
		# wider than the text column, so every card with a two-resource price
		# read "14 Stor" — in the one place the player goes to find out what
		# something costs.
		if cost_label.visible:
			var text_w: float = button_w - 16.0
			if icon_rect.visible:
				text_w -= icon_size + 8.0
			_fit_label(cost_label, text_w, [F_MICRO, 10, 9])


## Keep the interface usable in a narrow window.
##
## Nothing here is cosmetic: at 793 px the speed controls were pushed clean off
## the right-hand edge, and a control the player cannot reach is a broken game.
## The rule is that the things you act on — speed, build buttons — survive, and
## the things you only read — the title, the date, the cost text — are what get
## dropped.
##
## The decision is made by measuring, not by guessing a breakpoint: the bar is
## laid out at full dress and then degraded a step at a time until it fits.
## Every hand-picked threshold here was wrong at some window size.
func _relayout(rect: Vector2) -> void:
	var width := rect.x

	# Start at full dress, then fill the labels in before measuring anything.
	# Measuring first used stale widths — "Population 0" rather than
	# "Population 24 (0 homeless, 24 idle)" — so the bar was sized for text it
	# was about to replace, and the two groups overlapped by a hundred pixels.
	for b in _speed_buttons:
		b.custom_minimum_size = Vector2(42, 26)
		b.add_theme_font_size_override("font_size", F_SMALL)
	if _title_label:
		_title_label.visible = true
	if _date_label:
		_date_label.visible = true
	_compact = false
	_apply_top_spacing()
	_refresh_readouts()

	# Degrade until the top bar fits, cheapest loss first. The resource names
	# go before the wordmark does: at that width the coloured tick and the
	# number still say which store is which.
	for stage in 4:
		if _top_fits(width):
			break
		match stage:
			0:
				if _date_label:
					_date_label.visible = false
			1:
				_compact = true
				_apply_top_spacing()
				_refresh_readouts()
			2:
				if _title_label:
					_title_label.visible = false
			3:
				for b in _speed_buttons:
					b.custom_minimum_size.x = 34.0

	_hint_room = width >= 1180.0
	_apply_hint_visibility()
	_apply_tips_button_visibility()
	_layout_tray_cards()

	if _selection_panel:
		var panel_w: float = clampf(width * 0.34, 208.0, 306.0)
		_selection_panel.offset_left = -panel_w - 12.0
		_selection_panel.offset_right = -12.0
		_selection_panel.offset_bottom = _selection_panel.offset_top
		if _selection_body:
			_selection_body.custom_minimum_size = Vector2.ZERO
		var avail: float = rect.y - _selection_panel.offset_top - 96.0
		_selection_panel.custom_minimum_size = Vector2(panel_w, 0)
		_selection_scroll_limit = maxf(120.0, avail)
		if _selection_body:
			_selection_body.custom_minimum_size.y = 0
			_selection_body.fit_content = true
		_selection_panel.size.y = minf(_selection_panel.size.y,
				_selection_scroll_limit)
		_fit_selection_height.call_deferred()
	if _alert_box:
		var alert_w: float = clampf(width * 0.40, 220.0, 330.0)
		_alert_box.custom_minimum_size = Vector2(alert_w, 0)
		_alert_box.offset_right = _alert_box.offset_left + alert_w

	refresh()


func _apply_top_spacing() -> void:
	if _top_row:
		_top_row.add_theme_constant_override(
				"separation", 5 if _compact else 18)
	for label in _res_name_labels:
		label.visible = not _compact


## Would the readouts run into the speed controls? Asked after each step of the
## degrade loop. Both groups are measured from their own minimum sizes, which
## for a container is derived from its children and so is valid before layout.
func _top_fits(width: float) -> bool:
	if _top_row == null or _controls_row == null:
		return true
	var left := _top_row.get_combined_minimum_size().x
	var right := _controls_row.get_combined_minimum_size().x
	return left + right + 90.0 <= width


# --- Construction of the interface ------------------------------------------

## One style box, described the way the rest of this file wants to ask for one.
func _box(color: Color, radius: int, border: Color = LINE,
		  border_width: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	sb.border_color = border
	sb.set_border_width_all(border_width)
	return sb


## The shared chrome, built once.
##
## Three button families — chip, button, card — sharing one language for the
## three states that matter. At rest the surface sits a step above the bar it
## is on. Hovered, it lifts another step and its border brightens. Pressed,
## which in this interface means *armed*, it turns to the gilt accent: that
## colour appears nowhere else except the wordmark and panel titles, so a
## player can always find what is currently armed by looking for the only
## warm thing on the screen.
##
## The bar and panel backgrounds are built elsewhere, by _bar_box and _panel.
func _build_styles() -> void:
	_sb_btn = _box(BG_RAISED, 3, LINE)
	_sb_btn.content_margin_left = 10
	_sb_btn.content_margin_right = 10
	_sb_btn.content_margin_top = 5
	_sb_btn.content_margin_bottom = 5

	_sb_btn_hover = _sb_btn.duplicate() as StyleBoxFlat
	_sb_btn_hover.bg_color = Color(0.215, 0.203, 0.184, 1.0)
	_sb_btn_hover.border_color = Color(0.40, 0.36, 0.29, 1.0)

	_sb_btn_pressed = _sb_btn.duplicate() as StyleBoxFlat
	_sb_btn_pressed.bg_color = Color(0.255, 0.208, 0.118, 1.0)
	_sb_btn_pressed.border_color = ACCENT

	_sb_btn_disabled = _sb_btn.duplicate() as StyleBoxFlat
	_sb_btn_disabled.bg_color = Color(0.115, 0.110, 0.104, 1.0)
	_sb_btn_disabled.border_color = LINE_SOFT

	_sb_card = _box(Color(0.140, 0.133, 0.122, 1.0), 4, LINE_SOFT)
	_sb_card.content_margin_left = 8
	_sb_card.content_margin_right = 8
	_sb_card.content_margin_top = 6
	_sb_card.content_margin_bottom = 6

	_sb_card_hover = _sb_card.duplicate() as StyleBoxFlat
	_sb_card_hover.bg_color = Color(0.205, 0.194, 0.176, 1.0)
	_sb_card_hover.border_color = Color(0.42, 0.37, 0.29, 1.0)

	_sb_card_pressed = _sb_card.duplicate() as StyleBoxFlat
	_sb_card_pressed.bg_color = Color(0.250, 0.204, 0.116, 1.0)
	_sb_card_pressed.border_color = ACCENT
	_sb_card_pressed.border_width_left = 2

	_sb_chip = _box(Color(0.0, 0.0, 0.0, 0.0), 2, Color(0, 0, 0, 0), 0)
	_sb_chip.content_margin_left = 6
	_sb_chip.content_margin_right = 6
	_sb_chip.content_margin_top = 3
	_sb_chip.content_margin_bottom = 3

	_sb_chip_hover = _sb_chip.duplicate() as StyleBoxFlat
	_sb_chip_hover.bg_color = Color(0.22, 0.21, 0.19, 0.9)

	_sb_chip_pressed = _sb_chip.duplicate() as StyleBoxFlat
	_sb_chip_pressed.bg_color = Color(0.255, 0.208, 0.118, 1.0)
	_sb_chip_pressed.border_color = ACCENT_DEEP
	_sb_chip_pressed.set_border_width_all(1)


## A bar flush to an edge of the screen: square, opaque, with one bright
## hairline along the side that faces the game.
func _bar_box(edge_top: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	sb.border_color = Color(0.30, 0.27, 0.22, 0.95)
	if edge_top:
		sb.border_width_bottom = 1
	else:
		sb.border_width_top = 1
	return sb


## A panel that floats over the world: rounded, bordered and shadowed, so it
## stays legible over grass, roof and sky alike.
func _panel(color: Color) -> StyleBoxFlat:
	var sb := _box(color, 4, LINE)
	sb.content_margin_left = 13
	sb.content_margin_right = 13
	sb.content_margin_top = 10
	sb.content_margin_bottom = 11
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 7
	sb.shadow_offset = Vector2(0, 2)
	return sb


## A label whose tooltip is asked for when it is about to show, rather than
## rewritten into `tooltip_text` on every quarter-second refresh.
class LiveTipLabel extends Label:
	var source: Callable

	func _get_tooltip(_at: Vector2) -> String:
		return String(source.call()) if source.is_valid() else tooltip_text


func _make_live_label(text: String, size: int, color: Color, source: Callable) -> Label:
	var l := LiveTipLabel.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.source = source
	# Non-empty, so the viewport knows there is a tooltip to ask for.
	l.tooltip_text = " "
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	return l


func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## Dress a button in the shared chrome. `family` picks the size and weight.
func _style_button(b: Button, family: String = "button") -> void:
	var normal := _sb_btn
	var hover := _sb_btn_hover
	var pressed := _sb_btn_pressed
	match family:
		"card":
			normal = _sb_card
			hover = _sb_card_hover
			pressed = _sb_card_pressed
		"chip":
			normal = _sb_chip
			hover = _sb_chip_hover
			pressed = _sb_chip_pressed
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("disabled", _sb_btn_disabled)
	b.add_theme_color_override("font_color", INK_DIM)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", ACCENT)
	b.add_theme_color_override("font_hover_pressed_color", ACCENT)
	b.add_theme_color_override("font_focus_color", INK)
	b.add_theme_color_override("font_disabled_color", INK_FAINT)
	b.focus_mode = Control.FOCUS_NONE


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "top_bar"
	bar.add_theme_stylebox_override("panel", _bar_box(true))
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = TOP_BAR_H
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bar)

	# Two independently anchored groups rather than one row.
	#
	# With a single flow the speed controls were whatever fell off the end:
	# add one more resource, or run the game in a narrow window, and they left
	# the screen. Anchoring them to the right edge makes that structurally
	# impossible — the readouts on the left clip instead, which costs nothing
	# you cannot get elsewhere.
	var holder := Control.new()
	holder.name = "top_holder"
	holder.custom_minimum_size.y = TOP_BAR_INNER_H
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.clip_contents = true
	bar.add_child(holder)

	_top_row = HBoxContainer.new()
	_top_row.name = "readouts"
	_top_row.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_top_row.grow_horizontal = Control.GROW_DIRECTION_END
	_top_row.add_theme_constant_override("separation", 18)
	_top_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	_top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(_top_row)

	# A wordmark is not a readout: it is the only thing in the bar set in the
	# largest step of the scale, and the gilt belongs to it and to armed
	# controls and to nothing else.
	_title_label = _make_label("MARCHLANDS", F_TITLE, ACCENT)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_top_row.add_child(_title_label)
	_top_row.add_child(_rule())

	_res_tips.resize(Config.RES_COUNT)
	for i in Config.RES_COUNT:
		_top_row.add_child(_build_resource_chip(i))

	_top_row.add_child(_rule())
	_pop_label = _make_live_label("Population 0", F_BODY, INK, func() -> String: return _pop_tip)
	_pop_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Labels ignore the mouse by default, which quietly meant the tooltip
	# explaining *why* nobody is working never appeared.
	_pop_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_top_row.add_child(_pop_label)
	# Who is idle, one click at a time — the RTS idle-worker button.
	_idle_button = Button.new()
	_idle_button.flat = true
	_idle_button.focus_mode = Control.FOCUS_NONE
	_idle_button.add_theme_font_size_override("font_size", F_SMALL)
	_idle_button.add_theme_color_override("font_color", WARN)
	_idle_button.tooltip_text = "Show the next idle civilian"
	_idle_button.visible = false
	_idle_button.pressed.connect(func(): idle_focus_requested.emit())
	_top_row.add_child(_idle_button)

	_controls_row = HBoxContainer.new()
	_controls_row.name = "controls"
	_controls_row.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_controls_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_controls_row.add_theme_constant_override("separation", 12)
	_controls_row.alignment = BoxContainer.ALIGNMENT_END
	holder.add_child(_controls_row)

	_date_label = _make_label("", F_BODY, INK_DIM)
	_date_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_controls_row.add_child(_date_label)
	_clock_label = _date_label

	# The rates are one control with several positions, not seven buttons that
	# happen to be adjacent. Sinking them into a shared well says so.
	_speed_group = PanelContainer.new()
	_speed_group.name = "speeds"
	var well := _box(BG_SUNK, 4, LINE_SOFT)
	well.content_margin_left = 3
	well.content_margin_right = 3
	well.content_margin_top = 3
	well.content_margin_bottom = 3
	_speed_group.add_theme_stylebox_override("panel", well)
	_speed_group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_controls_row.add_child(_speed_group)

	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 2)
	_speed_group.add_child(speed_row)

	for i in Config.SPEED_LABELS.size():
		var b := Button.new()
		b.text = "II" if i == 0 else Config.SPEED_LABELS[i]
		b.custom_minimum_size = Vector2(42, 26)
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", F_SMALL)
		b.tooltip_text = "Pause" if i == 0 \
				else "Run at %s" % Config.SPEED_LABELS[i]
		_style_button(b, "chip")
		b.pressed.connect(func(): speed_requested.emit(i))
		speed_row.add_child(b)
		_speed_buttons.append(b)


## A hairline between groups in the top bar. Godot's stock VSeparator draws a
## grey line at full height; this one is short, dim and centred, which is what
## separates without shouting.
func _rule() -> VSeparator:
	var sep := VSeparator.new()
	var line := StyleBoxLine.new()
	line.color = LINE
	line.thickness = 1
	line.vertical = true
	line.grow_begin = -5.0
	line.grow_end = -5.0
	sep.add_theme_stylebox_override("separator", line)
	sep.add_theme_constant_override("separation", 6)
	return sep


## A resource readout: a coloured tick, the store's name, and the number.
##
## The name is dim and the number is bright, so a glance along the bar reads
## the quantities and only a deliberate look reads the labels. That ordering is
## the whole job of a resource bar and the previous one — five identical
## "Food 211" strings in one weight — did not do it.
func _build_resource_chip(index: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var tick := ColorRect.new()
	tick.color = Res.colour(index)
	tick.custom_minimum_size = Vector2(3, 15)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tick)

	# Hovering the name shows the same rates as hovering the number.
	var name_label := _make_live_label(Res.display(index), F_SMALL, INK_DIM,
			func() -> String: return _res_tips[index])
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)
	_res_name_labels.append(name_label)

	var value := _make_live_label("0", F_BODY, INK, func() -> String: return _res_tips[index])
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	_res_labels.append(value)
	return row


func _build_bottom_bar() -> void:
	# The bar is a tray that opens, not a permanent shelf. It keeps the bottom
	# of the screen clear while playing, and it gives the build options room to
	# be legible when they are actually wanted.
	var bar := PanelContainer.new()
	bar.name = "build_bar"
	bar.add_theme_stylebox_override("panel", _bar_box(false))
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -BAR_CLOSED_H
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_build_bar = bar
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bar)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 4)
	bar.add_child(rows)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	rows.add_child(row)

	_build_toggle = Button.new()
	_build_toggle.text = "▲  Build"
	_build_toggle.toggle_mode = true
	_build_toggle.custom_minimum_size = Vector2(92, 32)
	_build_toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_build_toggle.add_theme_font_size_override("font_size", F_BODY)
	_build_toggle.tooltip_text = "Show the build options   (B)"
	_style_button(_build_toggle)
	_build_toggle.add_theme_color_override("font_color", INK)
	_build_toggle.toggled.connect(_on_build_tray_toggled)
	row.add_child(_build_toggle)

	for entry in [["Research", research_open_requested], ["Army", army_open_requested],
			["Scouts", scouting_open_requested],
			["Wild cattle", cattle_focus_requested], ["Trade", trade_open_requested],
			["Bridge", bridge_tool_requested]]:
		var action := Button.new()
		action.text = entry[0]
		action.custom_minimum_size = Vector2(58, 32)
		action.add_theme_font_size_override("font_size", F_SMALL)
		action.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_style_button(action)
		action.pressed.connect(func(): entry[1].emit())
		row.add_child(action)
		_primary_actions.append(action)
	_tips_button = Button.new()
	_tips_button.text = "Tips"
	_tips_button.toggle_mode = true
	_tips_button.focus_mode = Control.FOCUS_NONE
	_tips_button.tooltip_text = "Show advice for new players"
	_tips_button.custom_minimum_size = Vector2(46, 32)
	_tips_button.add_theme_font_size_override("font_size", F_SMALL)
	_tips_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_button(_tips_button)
	_tips_button.pressed.connect(func(): tips_toggle_requested.emit())
	row.add_child(_tips_button)
	var world_button := Button.new()
	world_button.text = "World"
	world_button.custom_minimum_size = Vector2(58, 32)
	world_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	world_button.add_theme_font_size_override("font_size", F_SMALL)
	_style_button(world_button)
	world_button.pressed.connect(_show_world_dialog)
	row.add_child(world_button)
	_primary_actions.append(world_button)

	# Category tabs share the primary actions' place in the row: those hide
	# while the tray is open, so the bar keeps its height.
	var tab_group := ButtonGroup.new()
	var categories: Array[String] = []
	for row_def in BuildingDefs.TRAY_CATEGORIES:
		categories.append(row_def[0])
	for type_id in BuildingDefs.buildable():
		var category := BuildingDefs.tray_category(type_id)
		if not categories.has(category):
			categories.append(category)
	for category in categories:
		var tab := Button.new()
		tab.text = category
		tab.toggle_mode = true
		tab.button_group = tab_group
		tab.focus_mode = Control.FOCUS_NONE
		tab.custom_minimum_size = Vector2(58, 32)
		tab.add_theme_font_size_override("font_size", F_SMALL)
		tab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tab.visible = false
		_style_button(tab)
		tab.pressed.connect(_select_tray_category.bind(category))
		row.add_child(tab)
		_tray_tabs[category] = tab

	_build_scroll = ScrollContainer.new()
	_build_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_build_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_build_scroll.visible = false
	_build_scroll.custom_minimum_size.y = TRAY_CARD_H + 6.0
	rows.add_child(_build_scroll)
	_build_tray = HBoxContainer.new()
	_build_tray.add_theme_constant_override("separation", 6)
	_build_tray.visible = false
	_build_scroll.add_child(_build_tray)

	for type_id in BuildingDefs.buildable():
		var def := BuildingDefs.get_def(type_id)
		_build_tray.add_child(_build_card(type_id, def))

	# Clearing ground is a tool, not a building, so it sits apart from them.
	_build_tray.add_child(_rule())
	_clear_button = Button.new()
	_clear_button.text = "Clear\nGround"
	_clear_button.custom_minimum_size = Vector2(88, TRAY_CARD_H)
	_clear_button.toggle_mode = true
	_clear_button.add_theme_font_size_override("font_size", F_SMALL)
	_clear_button.tooltip_text = ("Order trees felled. The timber is carried "
			+ "to your stores.   (C)")
	_style_button(_clear_button, "card")
	_clear_button.add_theme_color_override("font_color", INK)
	_clear_button.pressed.connect(func(): clear_ground_requested.emit())
	_build_tray.add_child(_clear_button)

	_build_spacer = Control.new()
	_build_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_build_spacer)

	_hint_label = _make_label("", F_MICRO, INK_FAINT)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# It is the last thing in the row and the first thing that should give way:
	# clipping it beats pushing the tray off the screen, which is what the
	# unclipped label used to do at 1400 px with the tray open.
	_hint_label.clip_text = true
	_hint_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(_hint_label)
	set_hint("WASD pan · wheel zoom · middle-drag rotate · click to select")
	_select_tray_category(BuildingDefs.TRAY_CATEGORIES[0][0])


## Show one tab's buildings. Clear Ground stays in every tab: it is a tool, not
## a building, and the player reaches for it from wherever they are.
func _select_tray_category(category: String) -> void:
	_tray_category = category
	for key in _tray_tabs:
		_tray_tabs[key].set_pressed_no_signal(key == category)
	for type_id in _build_buttons:
		_build_buttons[type_id].visible = BuildingDefs.tray_category(type_id) == category
	if _build_scroll != null:
		_build_scroll.scroll_horizontal = 0
	_layout_tray_cards()


## One building in the tray.
##
## Laid out by hand inside the Button because a stock Button gives its whole
## label one colour, and the name and the price want different weights — and
## because the price has to be able to turn red on its own when the settlement
## cannot afford it, without dragging the name down with it.
func _build_card(type_id: String, def) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(150, TRAY_CARD_H)
	b.toggle_mode = true
	b.tooltip_text = def.description
	_style_button(b, "card")
	b.pressed.connect(_on_build_pressed.bind(type_id))

	# Anchored rather than parented to a container: a Button is not a
	# container, but anchors resolve against any Control parent.
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 8)
	pad.add_theme_constant_override("margin_right", 8)
	pad.add_theme_constant_override("margin_top", 5)
	pad.add_theme_constant_override("margin_bottom", 5)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(row)

	var icon := TextureRect.new()
	icon.texture = def.icon()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(32, 32)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.visible = icon.texture != null
	row.add_child(icon)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)

	var name_label := _make_label(def.display_name, F_SMALL, INK)
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_label)

	var cost_label := _make_label(def.cost_text(), F_MICRO, INK_DIM)
	cost_label.clip_text = true
	cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(cost_label)

	_build_buttons[type_id] = b
	_build_cards[type_id] = {
		"name": name_label, "cost": cost_label, "icon": icon,
	}
	return b


## Step a label's font down until its text fits `available` pixels, so a price
## shrinks rather than losing its last characters. Returns nothing: the label
## keeps the largest size in `sizes` that fits, or the smallest if none does.
func _fit_label(label: Label, available: float, sizes: Array) -> void:
	var font := label.get_theme_font("font")
	if font == null or available <= 0.0:
		return
	for size in sizes:
		var w: float = font.get_string_size(label.text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, int(size)).x
		if w <= available:
			label.add_theme_font_size_override("font_size", int(size))
			return
	label.add_theme_font_size_override("font_size", int(sizes[-1]))


func _on_build_tray_toggled(pressed: bool) -> void:
	for action in _primary_actions:
		action.visible = not pressed
	_apply_tips_button_visibility()
	for tab in _tray_tabs.values():
		tab.visible = pressed
	_build_tray.visible = pressed
	_build_scroll.visible = pressed
	_build_toggle.text = "▼  Build" if pressed else "▲  Build"
	if _build_bar:
		_build_bar.offset_top = -BAR_OPEN_H if pressed else -BAR_CLOSED_H
	_apply_hint_visibility()
	if not pressed:
		set_active_build("")
		build_cancelled.emit()


func _apply_hint_visibility() -> void:
	if _hint_label == null:
		return
	# The hint shares its row with the tray. While the tray is open there is
	# only room for both on a wide window, and the tray wins.
	var open := _build_toggle != null and _build_toggle.button_pressed
	_hint_label.visible = _hint_room and (not open or size.x >= 1480.0)


func set_tray_open(open: bool) -> void:
	_build_toggle.button_pressed = open
	_on_build_tray_toggled(open)


func tray_is_open() -> bool:
	return _build_toggle != null and _build_toggle.button_pressed


func set_clear_tool_active(active: bool) -> void:
	if _clear_button:
		_clear_button.button_pressed = active


func _build_selection_panel() -> void:
	_selection_panel = PanelContainer.new()
	_selection_panel.name = "selection"
	_selection_panel.add_theme_stylebox_override("panel", _panel(BG_PANEL))
	_selection_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_selection_panel.offset_left = -318
	_selection_panel.offset_right = -12
	_selection_panel.offset_top = TOP_BAR_H + 12.0
	# offset_bottom is the one that matters: without it the panel is a
	# zero-height box anchored to the top right and clicking a building looks
	# like nothing happening at all. grow_horizontal has to be flipped so it
	# opens leftward from the right edge; grow_vertical is already END by
	# default and is set here only so the pair reads together.
	_selection_panel.offset_bottom = _selection_panel.offset_top
	_selection_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_selection_panel.grow_vertical = Control.GROW_DIRECTION_END
	_selection_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_selection_panel.visible = false
	add_child(_selection_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	_selection_panel.add_child(col)

	_selection_title = _make_label("", F_LEAD, ACCENT)
	col.add_child(_selection_title)

	# A rule under the title, so the panel has a head and a body rather than
	# one undifferentiated block of text.
	_selection_rule = HSeparator.new()
	var line := StyleBoxLine.new()
	line.color = ACCENT_DEEP
	line.thickness = 1
	_selection_rule.add_theme_stylebox_override("separator", line)
	_selection_rule.add_theme_constant_override("separation", 3)
	col.add_child(_selection_rule)
	_selection_scroll = ScrollContainer.new()
	_selection_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_selection_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_selection_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_selection_scroll)
	_selection_content = VBoxContainer.new()
	_selection_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selection_content.add_theme_constant_override("separation", 7)
	_selection_scroll.add_child(_selection_content)
	_selection_content.minimum_size_changed.connect(_fit_selection_height.call_deferred)

	_selection_body = RichTextLabel.new()
	_selection_body.bbcode_enabled = true
	_selection_body.fit_content = true
	_selection_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selection_body.add_theme_font_size_override("normal_font_size", F_SMALL)
	_selection_body.add_theme_font_size_override("bold_font_size", F_SMALL)
	_selection_body.add_theme_color_override("default_color", INK)
	# Air between the lines. A dense block of statistics is unreadable at
	# 12 px over a moving scene, and this costs nothing but pixels.
	_selection_body.add_theme_constant_override("line_separation", 3)
	_selection_body.scroll_active = false
	_selection_content.add_child(_selection_body)

	_selection_actions = VBoxContainer.new()
	_selection_actions.add_theme_constant_override("separation", 5)
	_selection_content.add_child(_selection_actions)
	_build_bar.resized.connect(_fit_selection_height.call_deferred)


func _fit_selection_height() -> void:
	if not is_instance_valid(_selection_scroll):
		return
	var available := get_viewport_rect().size.y - _selection_panel.offset_top - _build_bar.size.y - 12.0
	var frame := _selection_panel.get_combined_minimum_size().y - _selection_scroll.custom_minimum_size.y
	var content_height := _selection_content.get_combined_minimum_size().y
	_selection_scroll.custom_minimum_size.y = minf(content_height, maxf(40.0, available - frame))
	_selection_panel.size.y = _selection_panel.get_combined_minimum_size().y


## An action button in the selection panel: full width, so the panel reads as a
## stack of one decision per row.
func _action_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", F_SMALL)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 30)
	_style_button(b)
	b.add_theme_color_override("font_color", INK)
	return b


func _build_alerts() -> void:
	_alert_box = VBoxContainer.new()
	_alert_box.name = "alerts"
	_alert_box.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_alert_box.offset_left = 12
	_alert_box.offset_top = -140
	_alert_box.offset_right = 342
	_alert_box.offset_bottom = -140
	_alert_box.grow_vertical = Control.GROW_DIRECTION_END
	_alert_box.custom_minimum_size = Vector2(320, 0)
	_alert_box.add_theme_constant_override("separation", 6)
	_alert_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_alert_box)


func _build_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.name = "cursor_tooltip"
	var sb := _panel(Color(0.078, 0.074, 0.070, 0.97))
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	# The cursor tooltip is the one panel that is always over the landscape and
	# never over chrome, so it gets the accent edge and the deepest shadow.
	sb.border_color = ACCENT_DEEP
	sb.border_width_left = 2
	_tooltip.add_theme_stylebox_override("panel", sb)
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	add_child(_tooltip)

	_tooltip_label = RichTextLabel.new()
	_tooltip_label.bbcode_enabled = true
	_tooltip_label.fit_content = true
	_tooltip_label.custom_minimum_size = Vector2(212, 0)
	_tooltip_label.add_theme_font_size_override("normal_font_size", F_SMALL)
	_tooltip_label.add_theme_font_size_override("bold_font_size", F_SMALL)
	_tooltip_label.add_theme_color_override("default_color", INK)
	_tooltip_label.add_theme_constant_override("line_separation", 2)
	_tooltip_label.scroll_active = false
	_tooltip.add_child(_tooltip_label)


# --- Behaviour --------------------------------------------------------------

func _on_build_pressed(type_id: String) -> void:
	if _active_build == type_id:
		set_active_build("")
		build_cancelled.emit()
		return
	set_active_build(type_id)
	build_requested.emit(type_id)


func set_active_build(type_id: String) -> void:
	_active_build = type_id
	for key in _build_buttons.keys():
		_build_buttons[key].button_pressed = (key == type_id)
	if type_id != "":
		set_clear_tool_active(false)
		if BuildingDefs.tray_category(type_id) != _tray_category:
			_select_tray_category(BuildingDefs.tray_category(type_id))
		if _build_toggle and not _build_toggle.button_pressed:
			_build_toggle.button_pressed = true
			_build_tray.visible = true
			_build_scroll.visible = true
			_build_toggle.text = "▼  Build"
			_apply_hint_visibility()
	if type_id == "":
		set_hint("WASD pan · wheel zoom · middle-drag rotate · click to select")
	else:
		set_hint("Click to place (keeps placing) · R rotate · right click / Esc to stop")


func set_hint(text: String) -> void:
	_base_hint = text
	_apply_hint()


func _apply_hint() -> void:
	if _hint_label == null:
		return
	# A stalled settlement is worth more of the hint line than the controls are.
	_hint_label.text = _idle_reason if _idle_reason != "" else _base_hint
	_hint_label.add_theme_color_override("font_color",
			WARN if _idle_reason != "" else INK_FAINT)


func refresh() -> void:
	_refresh_readouts()
	if _sim == null:
		return
	for type_id in _build_buttons:
		var def := BuildingDefs.get_def(type_id)
		var affordable := _sim.can_afford(def.cost)
		var parts: Dictionary = _build_cards[type_id]
		var cost_label: Label = parts["cost"]
		var icon_rect: TextureRect = parts["icon"]
		# Only the price reddens. Greying the icon as well makes the whole
		# card read as unavailable at a glance, without the name — the thing
		# the player is actually looking for — ever changing colour.
		cost_label.add_theme_color_override("font_color",
				INK_DIM if affordable else BAD)
		icon_rect.modulate = Color(1, 1, 1, 1.0 if affordable else 0.42)
	_apply_hint()


func _refresh_readouts() -> void:
	if _sim == null:
		return
	# A game day is DAY_LENGTH seconds at 1x, so a per-minute figure depends on
	# the speed the player is running at; per day does not.
	var scale: float = _clock.scale() if _clock != null and not _clock.paused() else 1.0
	var per_minute := 60.0 * scale / Config.DAY_LENGTH
	for i in Config.RES_COUNT:
		var amount := _sim.total_resource(i)
		_res_labels[i].text = "%d" % int(amount)
		var made := _sim.ledger.made_per_day(i)
		var used := _sim.ledger.used_per_day(i)
		var tip := "%s: %d\nProduced %.1f a day · used %.1f a day · net %+.1f" \
				% [Res.display(i), int(amount), made, used, made - used]
		# Where it comes from and where it goes, largest first.
		for side in [[true, "From"], [false, "To"]]:
			var rows: Array = _sim.ledger.sources(i, side[0])
			if rows.is_empty():
				continue
			var parts: Array[String] = []
			for row in rows.slice(0, 4):
				parts.append("%s %.1f" % [row[0], row[1]])
			tip += "\n%s: %s" % [side[1], ", ".join(parts)]
		tip += "\nAt %s: +%.1f / −%.1f a minute · averaged over the last day or so" \
				% ["this speed" if scale != 1.0 else "1x", made * per_minute, used * per_minute]
		_res_tips[i] = tip

	var bonus := _sim.tools_bonus
	_res_tips[Config.Res.TOOLS] += ("\n\nTools in store make every "
			+ "trade faster. Current work rate: %d%%" % int(bonus * 100.0))
	_res_labels[Config.Res.TOOLS].add_theme_color_override("font_color",
			INK if bonus > 1.01 else INK_DIM)

	var food_days := _sim.food_days_remaining()
	_res_labels[Config.Res.FOOD].add_theme_color_override("font_color",
			BAD if food_days < 4.0 else (WARN if food_days < 10.0 else INK))

	var homeless := _sim.stat_homeless
	var soldiers: int = _sim.campaign.friendly_ids().size() if _sim.campaign != null else 0
	var merchants: int = _sim.trade.caravans.size() if _sim.trade != null else 0
	var scouts: int = _sim.scouting.scouts.size() if _sim.scouting != null else 0
	var responders: int = _sim.water.carriers.size() if _sim.water != null else 0
	var civilians := _sim.citizens.size()
	if _compact:
		_pop_label.text = "C%d S%d" % [civilians, soldiers] if soldiers > 0 else "Pop %d" % civilians
		if merchants > 0:
			_pop_label.text = "C%d S%d M%d" % [civilians, soldiers, merchants] if soldiers > 0 else "C%d M%d" % [civilians, merchants]
		if scouts > 0: _pop_label.text = "C%d S%d M%d Sc%d" % [civilians, soldiers, merchants, scouts]
		if responders > 0: _pop_label.text = "%d people · %d with buckets" % [civilians + soldiers + merchants + scouts + responders, responders]
	else:
		_pop_label.text = "%d people · %d civilians · %d soldiers" % [civilians + soldiers, civilians, soldiers] \
				if soldiers > 0 else "Population %d  (%d homeless, %d idle)" % [civilians, homeless, _sim.stat_idle]
		if merchants > 0:
			_pop_label.text = "%d people · %d civilians · %d soldiers · %d merchants" % [civilians + soldiers + merchants, civilians, soldiers, merchants]
		if scouts > 0:
			_pop_label.text = "%d people · %d civilians · %d soldiers · %d merchants · %d scouts" % [civilians + soldiers + merchants + scouts, civilians, soldiers, merchants, scouts]
		if responders > 0:
			_pop_label.text = "%d people · %d at work · %d carrying water" % [civilians + soldiers + merchants + scouts + responders, civilians, responders]
	_pop_label.add_theme_color_override("font_color",
			WARN if homeless > 0 else INK)

	# Idle people are a symptom; the tooltip carries the diagnosis.
	var reason := _sim.idle_diagnosis()
	_pop_tip = "%d people: %d civilians and %d soldiers; %d merchants; %d scouts. People away on service do not produce locally.\n" % [civilians + soldiers + merchants + scouts, civilians, soldiers, merchants, scouts] + (reason if reason != ""
			else "%d of %d at work" % [_sim.stat_population - _sim.stat_idle,
					_sim.stat_population])
	if responders > 0:
		_pop_tip = "%d people: %d civilians, %d soldiers, %d merchants, %d scouts, %d bucket carriers. Responders leave production to carry water." % [civilians + soldiers + merchants + scouts + responders, civilians, soldiers, merchants, scouts, responders]
	var idle_names: Array[String] = []
	for c in _sim.citizens:
		if _sim.is_idle(c):
			idle_names.append(c.given_name)
	if _idle_button != null:
		_idle_button.visible = not idle_names.is_empty() and not _compact
		_idle_button.text = "%d idle" % idle_names.size()
	if not idle_names.is_empty():
		_pop_tip += "\nIdle: " + ", ".join(idle_names.slice(0, 8)) \
				+ (" and %d more" % (idle_names.size() - 8) if idle_names.size() > 8 else "") \
				+ " — click the idle count to find them."
	var blocker := _sim.immigration_blocker()
	if blocker != "":
		_pop_tip += "\n" + blocker
	var staffing: Dictionary = _sim.staffing_summary()
	if staffing.open_places > 0:
		var empty: Array = staffing.empty
		var text := "\n%d work place%s open" % [staffing.open_places,
				"" if staffing.open_places == 1 else "s"]
		if not empty.is_empty():
			var counts := {}
			for name in empty:
				counts[name] = int(counts.get(name, 0)) + 1
			var named: Array[String] = []
			for name in counts:
				named.append(name if counts[name] == 1 else "%s ×%d" % [name, counts[name]])
			text += " · no workers at: " + ", ".join(named)
		if staffing.short > 0:
			text += " · %d more short-handed" % staffing.short
		_pop_tip += text
	else:
		_pop_tip += "\nEvery workplace is fully staffed."
	if reason != "":
		_pop_label.add_theme_color_override("font_color", WARN)
		_idle_reason = reason
	else:
		_idle_reason = ""

	if _clock:
		_clock_label.text = _clock.date_text()
		for i in _speed_buttons.size():
			_speed_buttons[i].button_pressed = (i == _clock.speed_index)


# --- Selection --------------------------------------------------------------

## Rebuild the panel's action buttons only when the set of them actually
## changes, and say whether that happened.
##
## The selection panel is refreshed four times a second for as long as it is
## open, and it used to free and recreate its buttons on every one of those
## refreshes. That quietly ate clicks. A button only fires if the press and the
## release both land on the same instance; a refresh in between replaces it
## with a new node that never saw the press, so the click goes nowhere. Since
## the refresh is on a quarter-second timer and a click takes about a tenth of
## a second, cancelling a site or paying for an upgrade failed a good part of
## the time, at random, with no feedback — the worst kind of interface bug.
##
## The signature names what the buttons *are*. While it holds, the existing
## nodes are kept and only their changeable state — whether they are affordable
## — is updated.
func _actions_changed(signature: String) -> bool:
	if signature == _actions_signature:
		return false
	_actions_signature = signature
	_selection_scroll.scroll_vertical = 0
	for child in _selection_actions.get_children():
		_selection_actions.remove_child(child)
		child.queue_free()
	return true


## The selected force, one tile a man, along the bottom of the screen — the
## way a real-time strategy game shows who is under the player's hand. Tiles
## carry the soldier's name, health and water, and pick him out on click.
const UNIT_GRID_MAX := 24
const UNIT_TILE := Vector2(86, 46)
var _unit_grid_panel: PanelContainer
var _unit_grid: GridContainer
var _unit_grid_more: Label
var _unit_grid_ids: Array[int] = []


func _build_unit_grid() -> void:
	_unit_grid_panel = PanelContainer.new()
	_unit_grid_panel.name = "unit_grid"
	_unit_grid_panel.add_theme_stylebox_override("panel", _bar_box(true))
	_unit_grid_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_unit_grid_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_unit_grid_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_unit_grid_panel.offset_bottom = -BAR_OPEN_H - 6.0
	_unit_grid_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_unit_grid_panel.visible = false
	add_child(_unit_grid_panel)
	var column := VBoxContainer.new()
	_unit_grid_panel.add_child(column)
	_unit_grid = GridContainer.new()
	_unit_grid.columns = 8
	_unit_grid.add_theme_constant_override("h_separation", 4)
	_unit_grid.add_theme_constant_override("v_separation", 4)
	column.add_child(_unit_grid)
	_unit_grid_more = _make_label("", F_MICRO, INK_DIM)
	_unit_grid_more.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_unit_grid_more)


## Show `units` (Soldier nodes, the player's own) in the grid, or hide it when
## there are none. Tiles are rebuilt only when the set of men changes; their
## readings are refreshed on every call.
## The Tips toggle is the first thing to go on a narrow window: at 640 px it
## pushed World off the end of the bar. It hides with the other actions while
## the tray is open.
func _apply_tips_button_visibility() -> void:
	if _tips_button == null:
		return
	var open := _build_toggle != null and _build_toggle.button_pressed
	_tips_button.visible = not open and size.x >= 800.0


func set_tips_on(on: bool) -> void:
	if _tips_button != null:
		_tips_button.set_pressed_no_signal(on)


func show_unit_grid(units: Array, total: int = -1) -> void:
	if units.is_empty():
		_unit_grid_panel.visible = false
		_unit_grid_ids.clear()
		return
	if total < 0:
		total = units.size()
	var shown := units.slice(0, UNIT_GRID_MAX)
	var ids: Array[int] = []
	for unit in shown:
		ids.append(unit.id)
	if ids != _unit_grid_ids:
		_unit_grid_ids = ids
		for child in _unit_grid.get_children():
			_unit_grid.remove_child(child)
			child.queue_free()
		_unit_grid.columns = clampi(shown.size(), 1, 8)
		for unit in shown:
			var tile := Button.new()
			tile.custom_minimum_size = UNIT_TILE
			tile.focus_mode = Control.FOCUS_NONE
			tile.clip_text = true
			tile.add_theme_font_size_override("font_size", F_MICRO)
			_style_button(tile, "card")
			var unit_id: int = unit.id
			tile.gui_input.connect(func(event: InputEvent):
				if event is InputEventMouseButton and event.pressed \
						and event.button_index == MOUSE_BUTTON_LEFT:
					unit_pick_requested.emit(unit_id, event.shift_pressed)
					accept_event())
			_unit_grid.add_child(tile)
	for i in shown.size():
		var unit = shown[i]
		var tile: Button = _unit_grid.get_child(i)
		var health := int(round(unit.health))
		var first: String = String(unit.given_name).split(" ")[0]
		tile.text = "%s\n%d%% · water %d%%" % [first, health, int(round(unit.hydration * 100.0))]
		tile.tooltip_text = "%s — %s\nHealth %d%% · water %d%% · %s armour\nClick to pick him out · Shift-click to drop him" \
				% [unit.given_name, unit.task_label, health,
				int(round(unit.hydration * 100.0)), String(unit.armor_tier)]
		var colour := INK if health >= 70 else (WARN if health >= 35 else Color(0.86, 0.42, 0.36))
		tile.add_theme_color_override("font_color", colour)
	_unit_grid_more.visible = total > shown.size()
	_unit_grid_more.text = "+%d more" % (total - shown.size())
	_unit_grid_panel.visible = true


func clear_selection() -> void:
	_selection_panel.visible = false
	_actions_signature = ""
	for child in _selection_actions.get_children():
		_selection_actions.remove_child(child)
		child.queue_free()


## A button can outlive its building until the next panel refresh. A weak
## reference also prevents an old queued click from targeting a reused ID
## after a save replaces the simulation.
func _live_building(reference: WeakRef) -> Building:
	var building := reference.get_ref() as Building
	if building == null or not is_instance_valid(_sim):
		return null
	return building if _sim.buildings_by_id.get(building.id) == building else null


func show_building(b: Building) -> void:
	var building_ref: WeakRef = weakref(b)
	_selection_panel.visible = true
	_selection_title.text = b.display_name()
	# A different building, or the same one that has changed between being a
	# site and being finished, is a different set of buttons. Anything else is
	# the same panel being redrawn.
	var rebuild := _actions_changed("b%d:%s" % [
			b.id, "site" if b.under_construction else "built"])

	var lines: Array[String] = []
	lines.append("[color=#a9a49b]%s[/color]" % b.def.description)

	if b.under_construction:
		lines.append("")
		lines.append("[b]Under construction[/b]")
		if rebuild:
			var cancel := _action_button("Cancel site  (materials returned)")
			cancel.pressed.connect(func():
				var live := _live_building(building_ref)
				if live != null:
					demolish_requested.emit(live))
			_selection_actions.add_child(cancel)
		var cost := b.build_cost
		for res in cost.keys():
			var have := float(b.delivered.get(res, 0.0))
			var want := float(cost[res])
			var colour := "#9ec983" if have >= want else "#e0a85c"
			lines.append("  [color=%s]%s %d / %d[/color]"
					% [colour, Res.display(res), int(have), int(want)])
		lines.append("  Construction: %d%%" % int(b.build_progress * 100.0))
	else:
		_add_upgrade_action(b, rebuild)
		if b.type_id == "scout_lodge" and _sim.scouting != null:
			# The Scouts screen is where scouts are sent out, recalled and
			# followed, and it has to be reachable from the lodge without
			# training somebody new to get there.
			if rebuild:
				var manage := _action_button("Manage scouts")
				manage.pressed.connect(func(): scouting_open_requested.emit())
				_selection_actions.add_child(manage)
				var train := _action_button("Train a citizen scout")
				train.name = "train_scout"
				train.pressed.connect(func():
					var live := _live_building(building_ref)
					if live != null: scout_train_requested.emit(live.id))
				_selection_actions.add_child(train)
			var scouting: Dictionary = _sim.scouting.info()
			var training := 0
			for row in scouting.scouts:
				if row.training: training += 1
			lines.append("\n[b]Scouts[/b] %d in service · %d in training"
					% [scouting.scouts.size() - training, training])
			var train_button := _selection_actions.get_node_or_null("train_scout") as Button
			if train_button != null:
				train_button.disabled = not scouting.can_train
				train_button.tooltip_text = String(scouting.reason)
			if not scouting.can_train and String(scouting.reason) != "":
				lines.append("[color=#a9a49b]%s[/color]" % scouting.reason)
		if b.type_id == "keep" and _sim.research != null:
			if rebuild:
				var research := _action_button("Open research")
				research.pressed.connect(func(): research_open_requested.emit())
				_selection_actions.add_child(research)
			var active: String = _sim.research.active
			if active == "":
				lines.append("\n[b]Research[/b] none in progress")
			else:
				var quote: Dictionary = _sim.research.quote(active, true)
				lines.append("\n[b]Researching[/b] %s — %d%% · %.1f days left"
						% [quote.name, int(quote.progress * 100.0), quote.remaining_days])
		if b.fire > 0.0:
			lines.append("\n[color=#e0a85c]Burning — the fire is spreading through the building[/color]")
		elif b.health < b.max_health() * 0.7:
			lines.append("\n[color=#e0a85c]Scorched and damaged[/color]")
		if b.type_id == "well" and _sim.water != null:
			var water: Dictionary = _sim.water.well_info(b.id)
			lines.append("\n[b]Water[/b] %.1f / %.0f\nPeople walk here to drink. Firefighters collect buckets here and carry them to fires." % [water.get("water", 0.0), water.get("capacity", 80.0)])
			# What the well can sustain against what is being taken from it.
			var drawn: float = water.get("drawn_per_day", 0.0)
			var refill: float = water.get("refill_per_day", 14.0)
			var people := int(round(drawn / (refill / maxf(1.0, water.get("serves", 20.0)))))
			lines.append("[color=%s]Drinking %.0f a day of %.0f it refills · about %d of the ~%d people it can serve[/color]"
					% ["#e0a85c" if drawn > refill else "#a9a49b", drawn, refill, people, int(water.get("serves", 20.0))])
			if water.get("purging", false):
				# Two different sentences, because a sole well makes the usual one
				# false: `_drink` lets go of everyone walking here and `_well_for`
				# then offers nowhere else, so they do not drink elsewhere — they
				# go thirsty and start taking damage at zero hydration.
				if water.get("sole_well", false):
					lines.append("[color=#e0a85c]Being scrubbed out — the shaft is baled dry, and it is your only well, so the settlement has nowhere to drink until it refills.[/color]")
					lines.append("[color=#e0a85c]No firefighting water either. A fire breaks the scrubbing off, and the buckets then wait on the shaft refilling.[/color]")
				else:
					lines.append("[color=#e0a85c]Being scrubbed out — the shaft is baled dry, so people are drinking elsewhere.[/color]")
			elif float(water.get("poison", 0.0)) > 0.0:
				lines.append("[color=#e0a85c]Contaminated water — drinking is dangerous for about %.1f more days.[/color]" % float(water.get("poison_days", 0.0)))
				if water.get("purge_ordered", false):
					# Not "until they arrive": arriving only starts the work. The
					# poison is cleared when the scrubbing finishes, and not at all
					# if the worker is recalled or a fire breaks the job off.
					lines.append("[color=#e0a85c]A worker is on their way. The water stays dangerous until the scrubbing is finished.[/color]")
		if rebuild:
			var fight_fire := _action_button("Send a worker with water")
			fight_fire.name = "fight_fire"
			fight_fire.pressed.connect(func():
				var live := _live_building(building_ref)
				if live != null: firefighting_requested.emit(live.id))
			_selection_actions.add_child(fight_fire)
			if b.type_id == "well":
				var purge := _action_button("Send a worker to scrub the well out")
				purge.name = "purge_well"
				purge.pressed.connect(func():
					var live := _live_building(building_ref)
					if live != null: purge_well_requested.emit(live.id))
				_selection_actions.add_child(purge)
				var recall := _action_button("Recall the well-scrubbing worker")
				recall.name = "purge_cancel"
				recall.pressed.connect(func():
					var live := _live_building(building_ref)
					if live != null: purge_cancel_requested.emit(live.id))
				_selection_actions.add_child(recall)
		var fire_button: Button = _selection_actions.get_node_or_null("fight_fire")
		if fire_button != null: fire_button.visible = b.fire > 0.0
		# The button shows only once there is something to scrub out, and its
		# tooltip carries the same refusal the order itself would return, so the
		# player never has to press it to find out why it cannot run.
		var purge_button: Button = _selection_actions.get_node_or_null("purge_well")
		if purge_button != null and _sim.water != null:
			var offer: Dictionary = _sim.water.purge_quote(b.id)
			purge_button.visible = offer.get("poisoned", false) or offer.get("purging", false)
			purge_button.disabled = not offer.get("can_purge", false)
			# The tooltip carries the sole-well warning as well as the refusal: a
			# purge on the settlement's only well takes the firefighting buckets
			# down with the drinking water, and the player should read that
			# before pressing rather than after the keep catches.
			var offered := "A resident walks here, bales the shaft dry and scrubs it clean. Half a day of their labour, and no drinking water here until the work is done and the well refills."
			if offer.get("sole_well", false):
				offered += " This is your only well, so no firefighting bucket can be filled either while it is dry: a fire breaks the scrubbing off, and the buckets then wait on the shaft refilling."
			purge_button.tooltip_text = offer.get("reason", "") if not offer.get("can_purge", false) else offered
			var recall_button: Button = _selection_actions.get_node_or_null("purge_cancel")
			if recall_button != null:
				recall_button.visible = offer.get("purging", false)
				recall_button.tooltip_text = "Send them back to ordinary work. The well stays poisoned and stays empty until it refills."
		if b.type_id in ["supply_hut", "fort"]:
			lines.append("\n[b]Military food relay[/b]\nStock target %d · supply link up to 160 m\nSoldiers refill within 24 m. Assignments are automatic when workers are available." % b.food_stock_target())
		if b.type_id == "ranch" and _sim.husbandry != null:
			lines.append("\n[b]Herd[/b] %d cattle · %d adults\nKeep two adults for breeding. Ranchers tend the herd and turn surplus animals into food and hides." % [
				_sim.husbandry.herd_at(b.id).size(), _sim.husbandry.herd_at(b.id, true).size()])
			if not _sim.research.completed.has("ranching"):
				lines.append("[color=#e0a85c]Domesticate a wild cow, then research Ranching to begin breeding and hide production.[/color]")
		if b.type_id == "tannery" and not _sim.research.completed.has("leatherworking"):
			lines.append("\n[color=#e0a85c]Research Leatherworking to turn hides into leather.[/color]")
		if b.type_id == "market":
			var service := _sim.market_service(b)
			lines.append("\n[b]Market district[/b] %d homes · %d residents" % [service.homes, service.residents])
			lines.append("Food target %d · %.1f days in stock\nIncoming food: %.0f" % [service.target, service.days_supply, service.incoming])
			if b.workers.is_empty():
				lines.append("[color=#e0a85c]Vendors needed to collect supplies[/color]")
			for target in [40, 80, 120]:
				if rebuild:
					var policy := _action_button("Keep %d food" % target)
					policy.name = "market_target_%d" % target
					policy.pressed.connect(func():
						var live := _live_building(building_ref)
						if live != null:
							market_target_requested.emit(live, target))
					_selection_actions.add_child(policy)
				var policy_button: Button = _selection_actions.get_node("market_target_%d" % target)
				policy_button.text = ("✓ " if b.market_stock_target == target else "") + "Keep %d food" % target

		if b.def.houses > 0:
			lines.append("")
			lines.append("[b]Larder[/b] %d / %d  [color=#a9a49b]%s[/color]"
					% [int(b.larder), int(b.larder_capacity()),
					   "%d housed" % b.residents.size()])
			if b.larder < Config.MEAL_FOOD:
				lines.append("  [color=#e0a85c]bare — somebody will fetch "
						+ "food[/color]")
		if b.capacity() > 0.0:
			lines.append("")
			lines.append("[b]Stores[/b] (%d / %d)"
					% [int(b.total_stored()), int(b.capacity())])
			var any := false
			for res in b.def.stores:
				if b.inventory[res] > 0.01:
					lines.append("  %s %d" % [Res.display(res),
							int(b.inventory[res])])
					any = true
			if not any:
				lines.append("  [color=#7d7871]empty[/color]")

		if b.def.worker_slots > 0:
			lines.append("")
			lines.append("[b]Workers[/b] %d / %d"
					% [b.workers.size(), b.def.worker_slots])
			for cid in b.workers:
				var c: Citizen = _sim.citizens_by_id.get(cid)
				if c:
					lines.append("  [color=#a9a49b]%s — %s[/color]"
							% [c.given_name, c.status_line()])

		if b.def.houses > 0:
			lines.append("")
			lines.append("[b]Residents[/b] %d / %d"
					% [b.residents.size(), b.def.houses])

		if b.field_count() > 0:
			lines.append("")
			lines.append("[b]Fields[/b] %d tiles — crop %d%%"
					% [b.field_count(), int(b.crop_growth * 100.0)])

	_selection_body.text = "\n".join(lines)


## The "grow this building" button, when the definition has somewhere to grow.
##
## Shown whether or not the settlement can afford it, greyed out with the price
## on it when it cannot: a player who cannot see that the granary has a bigger
## version has no reason to save up for one.
func _add_upgrade_action(b: Building, rebuild: bool) -> void:
	if not b.def.can_upgrade():
		return
	var next := BuildingDefs.get_def(b.def.upgrades_to)
	if next == null:
		return
	var check: Dictionary = _sim.can_upgrade(b)
	var button: Button = null
	if rebuild:
		var building_ref: WeakRef = weakref(b)
		button = _action_button("Make into a %s  (%s)" % [
				next.display_name, Res.cost_text(b.def.upgrade_cost)])
		button.pressed.connect(func():
			var live := _live_building(building_ref)
			if live != null:
				upgrade_requested.emit(live))
		_selection_actions.add_child(button)
	elif _selection_actions.get_child_count() > 0:
		# This branch is the only action a finished building offers, so it is
		# always the first child when one exists.
		button = _selection_actions.get_child(0) as Button
	if button == null:
		return
	# Affordability is the one thing about it that moves while it is on screen.
	button.disabled = not check["ok"]
	button.tooltip_text = (next.description if check["ok"]
			else String(check["reason"]))


func show_citizen(c: Citizen) -> void:
	_selection_panel.visible = true
	_selection_title.text = c.given_name
	# A citizen offers no actions, so this only has to clear whatever the
	# previous selection left behind.
	_actions_changed("c%d" % c.id)

	var home := "none"
	var work := "none"
	if _sim.buildings_by_id.has(c.home_id):
		home = _sim.buildings_by_id[c.home_id].display_name()
	if _sim.buildings_by_id.has(c.workplace_id):
		work = _sim.buildings_by_id[c.workplace_id].display_name()

	# Hunger runs 0 (just eaten) to 1 (starving), and only rises once a meal has
	# actually been missed.
	var hunger_word := "well fed"
	if c.hunger > 0.75:
		hunger_word = "[color=#d97368]starving[/color]"
	elif c.hunger > 0.35:
		hunger_word = "[color=#e0a85c]hungry[/color]"
	elif c.hunger > 0.0:
		hunger_word = "[color=#e0a85c]peckish[/color]"
	var meal_in: float = c.next_meal - _sim.day
	var meal_word := "due now"
	if meal_in > 0.0:
		var hours: float = meal_in * 24.0
		meal_word = ("in %d min" % int(maxf(1.0, hours * 60.0))) if hours < 1.0 \
				else ("in %.1f h" % hours)

	var lines: Array[String] = [
		"[color=#a9a49b]%s, age %d[/color]" % [c.profession.capitalize(), c.age],
		"",
		"[b]Doing[/b] %s" % c.status_line(),
		"[b]Home[/b] %s" % home,
		"[b]Works at[/b] %s" % work,
		"[b]Condition[/b] %s" % hunger_word,
		"[b]Hydration[/b] %d%% · bucket %.1f water" % [roundi(c.hydration * 100.0), c.water_bucket],
		"[b]Next meal[/b] %s  [color=#a9a49b](%d taken)[/color]"
				% [meal_word, c.meals_taken],
		"[b]Morale[/b] %d%%" % int(c.morale * 100.0),
	]
	if c.water_sickness > 0.0: lines.append("[color=#e0a85c]Ill after drinking contaminated water[/color]")
	if c is Soldier:
		lines.append("[b]Injuries[/b] %s" % c.injury_summary())
		lines.append("[b]Work capacity[/b] %d%%" % roundi(c.workability() * 100.0))
	_selection_body.text = "\n".join(lines)


func show_road(info: Dictionary) -> void:
	_selection_panel.visible = true
	_selection_title.text = "Improve a route"
	var rebuild := _actions_changed("road:%d:%s" % [info.level, info.scope])
	var proposal: Dictionary = info.proposal
	var lines: Array[String] = ["Traffic creates the route. Research and materials improve it.",
		"", "[b]Surface[/b] %s → %s" % [Config.ROAD_NAMES[info.level], Config.ROAD_NAMES[info.target]],
		"[b]Selected[/b] %d m² of %d m² connected" % [proposal.area_m2, proposal.network_count * Config.WEAR_CELL * Config.WEAR_CELL],
		"[b]Materials[/b] %s" % Res.cost_text(proposal.cost)]
	if info.reason != "":
		lines.append("[color=#e0a85c]%s[/color]" % info.reason)
	lines.append("The highlighted ground is the exact area you will improve.")
	_selection_body.text = "\n".join(lines)
	var scopes := ["busiest", "local", "all"]
	var labels := ["Busiest route · about 20%", "Main routes · about half", "Entire connected network"]
	for i in scopes.size():
		var button: Button
		if rebuild:
			button = _action_button(labels[i])
			button.pressed.connect(func(): road_scope_requested.emit(scopes[i]))
			_selection_actions.add_child(button)
		else:
			button = _selection_actions.get_child(i)
		button.text = ("✓ " if info.scope == scopes[i] else "") + labels[i] \
				+ "\n" + Res.cost_text(info.options[scopes[i]].cost)
		button.tooltip_text = Res.cost_text(info.options[scopes[i]].cost)
	var commit: Button
	if rebuild:
		commit = _action_button("Commission improvement")
		commit.pressed.connect(func(): upgrade_route_requested.emit())
		_selection_actions.add_child(commit)
	else:
		commit = _selection_actions.get_child(3)
	commit.disabled = not info.can_upgrade
	commit.tooltip_text = info.reason


func show_research(quotes: Array) -> void:
	_selection_panel.visible = true
	_selection_title.text = "Research at the keep"
	var rebuild := _actions_changed("research")
	var lines: Array[String] = ["A working market supports the town's engineers. Fund one study at a time; building and road work still costs materials afterward."]
	for i in quotes.size():
		var q: Dictionary = quotes[i]
		var status: String = "Complete" if q.completed else q.reason
		if q.active:
			status = "%d%% · %.1f days remaining" % [q.progress * 100.0, q.remaining_days]
		lines.append("\n[b]%s[/b] — %s" % [q.name, status if status != "" else "Ready"])
		var button: Button
		if rebuild:
			button = _action_button("")
			button.pressed.connect(func(): research_requested.emit(q.id))
			_selection_actions.add_child(button)
		else:
			button = _selection_actions.get_child(i)
		button.text = "%s · %s" % [q.name, "Learned" if q.completed else Res.cost_text(q.cost)]
		button.tooltip_text = "%s · %.0f days\n%s\n%s" % [q.name, q.duration_days,
				q.get("benefit", ""), q.reason]
		button.disabled = not q.can_start or not _sim.can_afford(q.cost)
	_selection_body.text = "\n".join(lines)


func show_resource(info: Dictionary) -> void:
	_selection_panel.visible = true
	_selection_title.text = info.title
	_actions_changed("resource:%d" % info.id)
	_selection_body.text = "[b]Remaining[/b] %d\n\n%s" % [info.amount, info.description]


func show_army(info: Dictionary) -> void:
	_selection_panel.visible = true
	_selection_title.text = "The march's army"
	var rebuild := _actions_changed("army")
	_selection_body.text = "Civilians: %d · Soldiers: %d\nRations in packs: %.0f\n\nEach recruit leaves a civilian job. Conscript everyone and production stops. Select a soldier to fit researched armor or return them to civilian life.\n\nSupply huts need food and civilian workers; keep each relay within 160 m of an upstream store.\n\nMuster selects your force. Right-click to march or attack.\n\n[b]%s[/b]\n%s" % [_sim.citizens.size(), info.units, info.rations, info.rival_name, info.status]
	if rebuild:
		var recruit := _action_button("Recruit · 5 tools, up to 10 food")
		recruit.tooltip_text = "Enlist an existing resident. Returning veterans keep their remaining rations."
		recruit.pressed.connect(func(): recruit_requested.emit())
		_selection_actions.add_child(recruit)
		var muster := _action_button("Muster all swordsmen")
		muster.pressed.connect(func(): muster_requested.emit())
		_selection_actions.add_child(muster)
		var rival := _action_button("Known settlements")
		rival.pressed.connect(func(): city_report_requested.emit())
		_selection_actions.add_child(rival)
	_selection_actions.get_child(0).disabled = not info.can_recruit


## `company` is the one this soldier marches with, empty when he marches loose.
## It is named here, and offers its own disband button, because a company can
## shrink to one man — split one off, or lose the rest to casualties — and the
## block panel that normally carries that button needs two soldiers to appear.
## Without this he would be permanently enlisted in a company he cannot see.
func show_soldier(unit: Node, company: Dictionary = {}) -> void:
	_selection_panel.visible = true
	_selection_title.text = unit.given_name if unit.faction == 0 else "Rival guard"
	var company_id: int = company.get("id", -1)
	var rebuild := _actions_changed("unit:%d:%d" % [unit.id, company_id])
	_selection_body.text = "[b]Orders[/b] %s\n[b]Food[/b] %.1f days\n[b]Armor[/b] %s\n\n%s\n\n%s" % [unit.task_label, unit.rations,
		String(unit.armor_tier).capitalize(), unit.injury_summary(),
		"Armor is fitted at a barracks. Protection depends on the struck body part and attack. Injuries persist after discharge." if unit.faction == 0 else "This guard defends the rival settlement."]
	_selection_body.text += "\n\n[b]Skills[/b]\n" + unit.skill_summary()
	_selection_body.text += "\n[b]Hydration[/b] %d%%" % roundi(unit.hydration * 100.0)
	_selection_body.text += "\n[b]Duty[/b] %s · Medical kits: %d" % [unit.medical_role.capitalize(), unit.medical_supplies]
	if company_id >= 0:
		_selection_body.text += "\n[b]Company[/b] %s · %d soldier%s, %d files wide" \
				% [company.name, company.size, "" if company.size == 1 else "s", company.width]
	if unit.faction != 0: return
	var unit_id: int = unit.id
	for i in MilitaryEquipment.TIERS.size():
		var tier: String = MilitaryEquipment.TIERS[i]
		var offer := MilitaryEquipment.quote(_sim, unit_id, tier)
		var button: Button
		if rebuild:
			button = _action_button("")
			button.pressed.connect(func(): armor_requested.emit(unit_id, tier))
			_selection_actions.add_child(button)
		else:
			button = _selection_actions.get_child(i)
		button.text = "Remove armor" if tier == "none" else "%s · %s" % [tier.capitalize(), Res.cost_text(offer.cost)]
		button.disabled = not offer.can_fit
		button.tooltip_text = offer.reason if offer.reason != "" else "Fit to this soldier. Existing equipment is not refunded."
	if rebuild:
		var discharge := _action_button("Return to civilian life")
		discharge.pressed.connect(func(): demobilize_requested.emit(unit_id))
		_selection_actions.add_child(discharge)
		var medic := _action_button("Medic · 2 kits for 4 tools, 4 food")
		medic.name = "medic"
		medic.pressed.connect(func(): medic_requested.emit(unit_id))
		_selection_actions.add_child(medic)
		if company_id >= 0:
			var disband := _action_button("Disband %s" % company.name)
			disband.tooltip_text = "He stops marching as part of a block; nothing else about him changes."
			disband.pressed.connect(func(): company_disband_requested.emit(company_id))
			_selection_actions.add_child(disband)
	var medic_button: Button = _selection_actions.get_node_or_null("medic")
	var medic_offer: Dictionary = _sim.campaign.medic_quote(unit_id)
	medic_button.disabled = not medic_offer.can_fit
	medic_button.tooltip_text = medic_offer.reason if medic_offer.reason != "" else "Tends nearby wounded automatically. Each treatment uses one kit; lost limbs stay lost."


## Name the one company verb after whatever the current selection expresses.
## Forming, splitting and merging are the same order from three different
## starting points, and a button that says which one it is about to perform
## teaches that faster than three buttons two of which are always greyed out.
func _company_action_text(report: Dictionary) -> String:
	var rows: Array = report.get("companies", [])
	if report.get("whole", -1) >= 0:
		return "Already one company"
	if report.get("split_from", -1) >= 0:
		return "Split these %d soldiers off from %s" % [report.get("total", 0), rows[0].name]
	if report.get("mergeable", false):
		return "Merge these %d companies into one" % rows.size()
	return "Form a company from these %d soldiers" % report.get("total", 0)


## The panel for a block of soldiers. One soldier keeps his own panel — armor,
## wounds, discharge are decisions about a man. Two or more is a block, and
## this panel is about the block: which companies the selection covers, how
## much of each, and the single verb that reshapes it.
func show_company(report: Dictionary) -> void:
	_selection_panel.visible = true
	var rows: Array = report.get("companies", [])
	var total: int = report.get("total", 0)
	var loose: int = report.get("loose", 0)
	var whole: int = report.get("whole", -1)
	_selection_title.text = rows[0].name if rows.size() == 1 and loose == 0 \
			else "%d soldiers" % total
	var action := _company_action_text(report)
	var rebuild := _actions_changed("company:%s:%d" % [action, whole])
	var lines: Array[String] = []
	for row in rows:
		lines.append("[b]%s[/b] — %d of %d soldiers, %d files wide"
				% [row.name, row.selected, row.size, row.width])
	if loose > 0:
		lines.append("[b]%d soldier%s in no company[/b]" % [loose, "" if loose == 1 else "s"])
	lines.append("\nRight-click to march or attack. Each company arrives in its own block, in its own shape.")
	lines.append("Click one soldier to take his whole company. Alt-click for that soldier alone, Shift-click to add another company. [b]G[/b], or the button below, makes the selection one company — that is how a company is formed, split and merged.")
	_selection_body.text = "\n".join(lines)
	if rebuild:
		var form := _action_button(action)
		form.tooltip_text = "The selected soldiers become one company, leaving whatever company they were in."
		form.pressed.connect(func(): company_form_requested.emit())
		_selection_actions.add_child(form)
		var disband := _action_button("Disband this company")
		disband.tooltip_text = "The soldiers stay; they simply stop marching as a block."
		disband.pressed.connect(func(): company_disband_requested.emit(whole))
		_selection_actions.add_child(disband)
	_selection_actions.get_child(0).disabled = whole >= 0
	_selection_actions.get_child(1).disabled = whole < 0


func show_scouts(info: Dictionary, selected_id: int = -1) -> void:
	_selection_panel.visible = true
	_selection_title.text = "Scouts and reports"
	var rows: Array = info.get("scouts", [])
	var keys: Array = []
	for row in rows: keys.append([row.id, row.training, row.can_explore])
	var rebuild := _actions_changed("scouts:%s:%d:%d" % [str(keys), selected_id, info.get("lodge_id", -1)])
	var lines: Array[String] = ["Scouts are your citizens. Training takes time away from work.",
		"Training needs 2 tools, 8 packed food and half a day at a completed lodge.",
		"Select a trained scout, then right-click the map to explore. Visit a known castle to ask its ruler for details.",
		"Merchants report what they see on established trade routes; they cannot explore."]
	if not info.get("can_train", false): lines.append("\n" + str(info.get("reason", "Build a scout lodge to train residents.")))
	for row in rows:
		if selected_id >= 0 and row.id != selected_id: continue
		var progress := ""
		if row.training:
			progress = " · training %d%%" % int(float(row.get("training_progress", 0.0)) * 100.0)
		lines.append("\n[b]%s[/b]\n%s%s" % [row.name, row.status, progress])
		var scout: Scout = _sim.scouting.scouts.get(row.id)
		if scout != null: lines.append("Hydration %d%% · food %.1f days" % [roundi(scout.person.hydration * 100.0), scout.food])
	_selection_body.text = "\n".join(lines)
	if rebuild:
		var train := _action_button("Train a citizen scout")
		train.name = "train_scout"
		var lodge_id: int = info.get("lodge_id", -1)
		train.pressed.connect(func(): scout_train_requested.emit(lodge_id))
		_selection_actions.add_child(train)
		var reports := _action_button("Known settlement reports")
		reports.pressed.connect(func(): city_report_requested.emit())
		_selection_actions.add_child(reports)
		for row in rows:
			var scout_id: int = row.id
			if selected_id >= 0 and scout_id != selected_id: continue
			var select := _action_button("Select · " + str(row.name))
			select.pressed.connect(func(): scout_select_requested.emit(scout_id))
			_selection_actions.add_child(select)
			if row.can_explore:
				var visit := _action_button("Visit known castle · " + str(row.name))
				visit.pressed.connect(func(): scout_visit_requested.emit(scout_id))
				_selection_actions.add_child(visit)
				var poison := _action_button("Poison enemy well · " + str(row.name))
				poison.name = "poison_%d" % scout_id
				poison.pressed.connect(func(): poison_well_requested.emit(scout_id))
				_selection_actions.add_child(poison)
			var recall := _action_button("Return to civilian work · " + str(row.name))
			recall.pressed.connect(func(): scout_recall_requested.emit(scout_id))
			_selection_actions.add_child(recall)
	_selection_actions.get_node("train_scout").disabled = not info.get("can_train", false)
	if _sim.water != null:
		for row in rows:
			var button: Button = _selection_actions.get_node_or_null("poison_%d" % int(row.id))
			if button == null: continue
			var offer: Dictionary = _sim.water.poison_quote(row.id)
			button.disabled = not offer.get("can_poison", false)
			button.tooltip_text = offer.get("reason", "") if not offer.get("can_poison", false) else "Collect paid supplies, travel to the enemy well and contaminate its water."


func show_city_report(report: Dictionary, day: float) -> void:
	_selection_panel.visible = true
	_selection_title.text = str(report.get("name", "Known settlements"))
	var rebuild := _actions_changed("city_report:%s" % str(report.is_empty()))
	if report.is_empty():
		_selection_body.text = "No settlements have been reported. Train a citizen at a scout lodge and send them beyond your borders."
	else:
		_selection_body.text = "[b]Last visited[/b] %.1f days ago\n[b]Last known population[/b] %s\n[b]Observed military[/b] %s\n[b]Source[/b] %s\n\nThis is a dated report. It does not update while nobody is there. A scout must reach the castle and speak to the ruler for confirmed details." % [maxf(0.0, day - float(report.last_seen_day)), report.population_text, report.military_text, report.source]
		var history: Dictionary = report.get("ruler_history", {})
		if not history.is_empty():
			_selection_body.text += "\n\n[b]Earlier ruler report[/b] %.1f days ago\n%s\n%s" % [maxf(0.0, day - float(history.last_seen_day)), history.population_text, history.military_text]
		if rebuild:
			var locate := _action_button("Locate reported town")
			locate.pressed.connect(func(): rival_focus_requested.emit())
			_selection_actions.add_child(locate)
	if rebuild:
		var scouts := _action_button("Manage scouts")
		scouts.pressed.connect(func(): scouting_open_requested.emit())
		_selection_actions.add_child(scouts)


func update_city_marker(report: Dictionary, day: float, screen: Vector2, on_screen: bool) -> void:
	if _city_marker == null:
		_city_marker = Button.new()
		_city_marker.name = "known_city_marker"
		_city_marker.add_theme_font_size_override("font_size", F_SMALL)
		_style_button(_city_marker)
		_city_marker.pressed.connect(func(): city_report_requested.emit())
		add_child(_city_marker)
		move_child(_city_marker, 0)
	_city_marker.visible = on_screen and not report.is_empty()
	if not _city_marker.visible: return
	_city_marker.text = "%s · last visited %.0f days ago" % [report.name, maxf(0.0, day - float(report.last_seen_day))]
	_city_marker.tooltip_text = "Last known population: %s\nObserved military: %s\n%s" % [report.population_text, report.military_text, report.source]
	_city_marker.size = _city_marker.get_minimum_size()
	_city_marker.position = screen - Vector2(_city_marker.size.x * 0.5, _city_marker.size.y)
	_city_marker.position.x = clampf(_city_marker.position.x, 8.0, maxf(8.0, size.x - _city_marker.size.x - 8.0))
	_city_marker.position.y = clampf(_city_marker.position.y, TOP_BAR_H + 8.0, maxf(TOP_BAR_H + 8.0, size.y - BAR_OPEN_H - _city_marker.size.y))
	if _selection_panel.visible and _selection_panel.get_global_rect().intersects(_city_marker.get_global_rect()):
		_city_marker.hide()


func show_cow(info: Dictionary) -> void:
	_selection_panel.visible = true
	_selection_title.text = "Wild cattle" if info.wild else "Ranch cattle"
	var rebuild := _actions_changed("cow:%d:%s" % [info.id, info.wild])
	_selection_body.text = "%s\n\nBuild and staff a ranch, then send its ranchers for this animal's herd: they win each beast's trust in turn and lead the group home together. Your first successful domestication unlocks Ranching research. Keep a breeding pair; surplus cattle provide food and hides. A tannery turns hides into leather for armor." % info.status
	if info.wild:
		var id: int = info.id
		var button: Button
		if rebuild:
			button = _action_button("Send ranchers for this herd")
			button.pressed.connect(func(): domesticate_requested.emit(id))
			_selection_actions.add_child(button)
		else:
			button = _selection_actions.get_child(0)
		button.disabled = not info.can_domesticate
		button.tooltip_text = info.reason


# --- Cursor tooltip (placement feedback, design doc 6.1) --------------------

func show_cursor_tooltip(lines: Array, screen_pos: Vector2) -> void:
	_tooltip_label.text = "\n".join(lines)
	_tooltip.visible = true
	_tooltip.position = screen_pos + Vector2(22, 20)
	var vp := get_viewport_rect().size
	_tooltip.position.x = minf(_tooltip.position.x, vp.x - 250)
	_tooltip.position.y = minf(_tooltip.position.y, vp.y - 140)


func hide_cursor_tooltip() -> void:
	_tooltip.visible = false


# --- Alerts -----------------------------------------------------------------

func push_alert(text: String, position: Vector3) -> void:
	var panel := PanelContainer.new()
	var sb := _panel(BG_PANEL)
	sb.content_margin_left = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	sb.content_margin_right = 4
	# A gilt spine down the left edge. It marks the feed as one thing at a
	# glance and gives the eye somewhere to land on a moving background.
	sb.border_color = ACCENT_DEEP
	sb.border_width_left = 3
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	panel.add_child(row)

	var button := Button.new()
	button.text = text
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", F_SMALL)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", ACCENT)
	button.tooltip_text = "Show me"
	button.pressed.connect(func(): focus_requested.emit(position))
	row.add_child(button)

	# Messages are dismissible. They used to sit there until a timer removed
	# them, over the part of the map the message was about.
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(24, 24)
	close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close.tooltip_text = "Dismiss"
	close.add_theme_font_size_override("font_size", F_MICRO)
	close.add_theme_color_override("font_color", INK_FAINT)
	close.add_theme_color_override("font_hover_color", INK)
	close.pressed.connect(func(): _dismiss_alert(panel))
	row.add_child(close)

	_alert_box.add_child(panel)
	while _alert_box.get_child_count() > 5:
		var oldest := _alert_box.get_child(0)
		_alert_box.remove_child(oldest)
		oldest.queue_free()

	# They fade up over about a fifth of a second rather than snapping in,
	# which is enough for the eye to catch that something is new without it
	# costing any attention.
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.18)

	# They also fade on their own, so ignoring them costs nothing either.
	var tween := panel.create_tween()
	tween.tween_interval(14.0)
	tween.tween_property(panel, "modulate:a", 0.0, 1.6)
	tween.tween_callback(func(): _dismiss_alert(panel))


func _dismiss_alert(panel: Control) -> void:
	if not is_instance_valid(panel) or panel.get_parent() != _alert_box:
		return
	_alert_box.remove_child(panel)
	panel.queue_free()


func clear_alerts() -> void:
	for child in _alert_box.get_children():
		_dismiss_alert(child)


## True when the cursor is over interface rather than the world, so a click on
## a button never also places a building. Recurses, because the alert feed is a
## pass-through container holding clickable panels.
func blocks_mouse(at: Vector2) -> bool:
	return _blocks(self, at)


func _blocks(node: Node, at: Vector2) -> bool:
	for child in node.get_children():
		if not (child is Control):
			continue
		var control: Control = child
		if not control.visible:
			continue
		if control.clip_contents and not control.get_global_rect().has_point(at):
			continue
		if control.mouse_filter != Control.MOUSE_FILTER_IGNORE \
				and control.get_global_rect().has_point(at):
			return true
		if _blocks(control, at):
			return true
	return false


func _show_world_dialog() -> void:
	if _world_dialog == null:
		_world_dialog = ConfirmationDialog.new()
		_world_dialog.title = "Start a new march"
		_world_dialog.ok_button_text = "Create world"
		_world_dialog.min_size = Vector2i(440, 250)
		var rows := VBoxContainer.new()
		rows.add_theme_constant_override("separation", 12)
		_world_dialog.add_child(rows)
		var notice := Label.new()
		notice.text = "Choose the landscape for a new settlement.\nThis replaces the current march. Save it first with Ctrl+S."
		notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		notice.custom_minimum_size.x = 400
		rows.add_child(notice)
		_world_size_choice = OptionButton.new()
		for preset in [["Small · 768 m", 768], ["Medium · 1.5 km", 1536],
				["Large · 3.1 km", 3072], ["Extra large · 6.1 km", 6144]]:
			_world_size_choice.add_item(preset[0], preset[1])
		rows.add_child(_world_size_choice)
		_world_seed_input = LineEdit.new()
		_world_seed_input.placeholder_text = "World seed (whole number)"
		_world_seed_input.text = str(_sim.world.world_seed) if _sim != null else "20260911"
		rows.add_child(_world_seed_input)
		var note := Label.new()
		note.text = "Rivers, forested valleys and mountain passes.\nLarger worlds take longer to generate and travel across."
		rows.add_child(note)
		add_child(_world_dialog)
		_world_dialog.confirmed.connect(func():
			if not _world_seed_input.text.is_valid_int():
				push_alert("Enter a whole number for the world seed.", Vector3.ZERO)
				return
			new_world_requested.emit(int(_world_seed_input.text), _world_size_choice.get_selected_id()))
	_world_dialog.popup_centered(Vector2i(460, 280))


func show_trade(info: Dictionary, selected_id: int = -1) -> void:
	_selection_panel.visible = true
	var report: Dictionary = _sim.scouting.city_report() if _sim.scouting != null else {}
	_selection_title.text = "Trade" if report.is_empty() else "Trade with " + str(report.name)
	var quote: Dictionary = info.get("quote", {})
	var rows: Array = info.get("caravans", [])
	var keys: Array = []
	for row in rows: keys.append(row.id)
	for wreck in info.get("lost_carts", []): keys.append("wreck:%d:%s" % [wreck.id, str(wreck.recovery_requested)])
	var rebuild := _actions_changed("trade:%s:%d:%d" % [str(keys), selected_id, int(quote.get("origin_id", -1))])
	var lines: Array[String] = ["Assign a citizen and cart to carry real goods between markets.",
		"", "[b]Merchants away[/b] %d" % info.get("merchants", 0)]
	if int(quote.get("target_id", -1)) >= 0:
		lines.append("[b]Offer[/b] %d timber for %d iron" % [quote.get("export_amount", 24), quote.get("import_amount", 8)])
		lines.append("[b]Travel food[/b] %d · keep two days of food at home" % quote.get("provisions", 0))
	if quote.get("travel_seconds", 0.0) > 0:
		lines.append("[b]Estimated round trip[/b] %.1f days before loading and stops" % (float(quote.travel_seconds) / Config.DAY_LENGTH))
	if not quote.get("ok", false): lines.append("[color=#e0a85c]%s[/color]" % quote.get("reason", "Unavailable"))
	for row in rows:
		if selected_id >= 0 and row.id != selected_id: continue
		lines.append("\n[b]%s[/b] · %s\n%s" % [row.name, row.state, row.status])
		lines.append("Food %.1f · %s · trips %d" % [row.provisions,
				"Empty cart" if row.cargo_res < 0 else "%d %s" % [row.cargo_amount, Res.display(row.cargo_res)], row.completed_trips])
	if int(info.get("wrecks", 0)) > 0:
		lines.append("\nLost carts: %d. Send civilian workers to collect their goods." % info.wrecks)
		for wreck in info.get("lost_carts", []):
			var goods: Array[String] = []
			for res in Config.RES_COUNT:
				if wreck.cargo[res] > 0: goods.append("%.1f %s" % [wreck.cargo[res], Res.display(res)])
			lines.append("%s: %s" % [wreck.name, ", ".join(goods)])
	_selection_body.text = "\n".join(lines)
	var dispatch: Button
	if rebuild:
		dispatch = _action_button("Dispatch citizen caravan")
		dispatch.name = "dispatch"
		_selection_actions.add_child(dispatch)
		var origin := int(quote.get("origin_id", -1))
		var target := int(quote.get("target_id", -1))
		dispatch.pressed.connect(func(): trade_dispatch_requested.emit(origin, target))
		var neighbor := _action_button("Find trading town")
		_selection_actions.add_child(neighbor)
		neighbor.pressed.connect(func(): rival_focus_requested.emit())
		for row in rows:
			if selected_id >= 0 and row.id != selected_id: continue
			var route_id := int(row.id)
			var follow := _action_button("Find " + String(row.name))
			_selection_actions.add_child(follow)
			follow.pressed.connect(func():
				if _sim.trade != null and _sim.trade.caravans.has(route_id):
					focus_requested.emit(_sim.trade.caravans[route_id].merchant.global_position))
			var recall := _action_button("Return home · " + String(row.name))
			_selection_actions.add_child(recall)
			recall.pressed.connect(func(): caravan_recall_requested.emit(route_id))
			var repeat_button := _action_button("")
			repeat_button.name = "repeat_%d" % route_id
			_selection_actions.add_child(repeat_button)
			repeat_button.pressed.connect(func():
				if _sim.trade != null and _sim.trade.caravans.has(route_id):
					caravan_repeat_requested.emit(route_id, not _sim.trade.caravans[route_id].repeat))
		for wreck in info.get("lost_carts", []):
			var wreck_id := int(wreck.id)
			var location: Vector3 = wreck.position
			var find := _action_button("Find lost cart · " + String(wreck.name))
			_selection_actions.add_child(find)
			find.pressed.connect(func(): focus_requested.emit(location))
			var recovering: bool = wreck.recovery_requested
			var salvage := _action_button(("Cancel recovery · " if recovering else "Recover goods · ") + String(wreck.name))
			_selection_actions.add_child(salvage)
			salvage.pressed.connect(func(): wreck_recovery_requested.emit(wreck_id, not recovering))
	else:
		dispatch = _selection_actions.get_node_or_null("dispatch")
	if dispatch != null:
		dispatch.disabled = not quote.get("ok", false)
		dispatch.tooltip_text = quote.get("reason", "")
	for row in rows:
		var button: Button = _selection_actions.get_node_or_null("repeat_%d" % int(row.id))
		if button != null: button.text = "Repeat trips: %s · %s" % ["on" if row.repeat else "off", row.name]


func show_bridge(info: Dictionary) -> void:
	_selection_panel.visible = true
	_selection_title.text = "Timber bridge"
	var bridge_id := int(info.id)
	var rebuild := _actions_changed("bridge:%d" % bridge_id)
	var lines: Array[String] = [String(info.get("status", "Building")),
		"[b]Span[/b] %.0f m" % float(info.length), "[b]Work[/b] %d%%" % roundi(float(info.progress) * 100.0)]
	for res in info.cost:
		lines.append("%s delivered: %d / %d" % [Res.display(res), info.delivered.get(res, 0), info.cost[res]])
	lines.append("\nCompleted crossings carry people and carts. Their traffic forms the approaches.")
	_selection_body.text = "\n".join(lines)
	var remove: Button
	if rebuild:
		remove = _action_button("Remove bridge")
		remove.name = "remove_bridge"
		_selection_actions.add_child(remove)
		remove.pressed.connect(func(): bridge_remove_requested.emit(bridge_id))
	else:
		remove = _selection_actions.get_node_or_null("remove_bridge")
	if remove != null:
		remove.disabled = not info.get("can_remove", false)
		remove.tooltip_text = "Wait until people and carts have cleared the crossing." if remove.disabled else "Cancel construction or dismantle the crossing."


func show_bridge_preview(quote: Dictionary, chosen_bank: bool) -> void:
	_selection_panel.visible = true
	_selection_title.text = "Place timber bridge"
	_actions_changed("bridge_preview")
	var lines: Array[String] = ["Click the first bank, then the opposite bank. Right-click or Esc cancels.",
		"No research required. Workers deliver the materials before building the deck."]
	if chosen_bank:
		lines.append("\n" + String(quote.get("reason", "Choose the opposite bank.")))
		if quote.has("length"):
			lines.append("[b]Span[/b] %.0f m · maximum 64 m" % float(quote.length))
		for res in quote.get("cost", {}):
			lines.append("%d %s" % [quote.cost[res], Res.display(res)])
		if float(quote.get("detour_saved", -1)) >= 0:
			lines.append("[b]Walking detour saved[/b] about %.0f m" % float(quote.detour_saved))
		if quote.get("ok", false): lines.append("[color=#8fc58c]Click to begin construction.[/color]")
	_selection_body.text = "\n".join(lines)
