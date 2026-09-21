class_name World
extends Node3D

## Owns the physical world: terrain, wear field, navigation, resource nodes,
## lighting and the containers everything else parents into.

var heightmap := Heightmap.new()
var wear := WearField.new()
var nav := NavGrid.new()
var terrain: Terrain
var nodes: ResourceNodes
## Attached only when a simulation supplies a scouting manager.
var fog: Node3D

var buildings_root: Node3D
var citizens_root: Node3D
var effects_root: Node3D

var sun: DirectionalLight3D
## Cool, shadowless counter-key standing in for skylight bouncing off the
## landscape. Without it the shaded side of every roof is one flat ambient
## value and the buildings read as cut-outs rather than as solids.
var fill: DirectionalLight3D
var environment: WorldEnvironment

var size_m := Config.WORLD_SIZE
var grid_size := Config.GRID
var generation_version := 1
var generation_settings: Dictionary = {}

var world_seed := 20260911
var _nav_overlay: MultiMeshInstance3D

## Where in the year we are, 0 at the first day of spring. Held here because
## the sun, the sky, the fog and the ground shader all grade off it together.
var _year_fraction := 0.0
## Only pushed at the terrain shader when it actually moves; the caller drives
## this every frame.
var _last_season_push := -1.0
## Likewise for the sky gradient, which is far more expensive to touch than it
## looks — see the note in set_time_of_day.
var _last_sky_push := -1.0


func generate(registry: AssetRegistry, seed_value: int, settings: Dictionary = {}) -> void:
	world_seed = seed_value
	generation_version = int(settings.get("generation_version", 1 if settings.is_empty() else Config.GENERATION_VERSION))
	size_m = float(settings.get("size_m", Config.WORLD_SIZE))
	if not Config.WORLD_SIZES.values().has(size_m):
		size_m = Config.WORLD_SIZE
	grid_size = roundi(size_m / Config.CELL)
	generation_settings = {"size_m": size_m, "generation_version": generation_version}
	heightmap.generate(seed_value, size_m, generation_version)
	wear.setup(size_m)
	wear.bake_fertility(heightmap)
	nav.setup(heightmap, wear)

	terrain = Terrain.new()
	terrain.name = "terrain"
	add_child(terrain)
	terrain.build(heightmap, wear)

	nodes = ResourceNodes.new()
	nodes.name = "resources"
	add_child(nodes)
	nodes.generate(heightmap, registry, seed_value)

	# Stone and iron block the ground they stand on, so routes bend around an
	# outcrop. Trees deliberately do not: a wood is slow to cross rather than
	# impassable, and blocking every trunk on a 4 m grid would wall off whole
	# valleys that a person can plainly walk through.
	for rec in nodes.records:
		if rec.kind != ResourceNodes.Kind.TREE:
			var c := world_to_cell(rec.position)
			nav.set_blocked(c.x, c.y, true)

	buildings_root = Node3D.new()
	buildings_root.name = "buildings"
	add_child(buildings_root)

	citizens_root = Node3D.new()
	citizens_root.name = "citizens"
	add_child(citizens_root)

	effects_root = Node3D.new()
	effects_root.name = "effects"
	add_child(effects_root)

	_build_lighting()


# --- The lighting rig -------------------------------------------------------
#
# Key + fill + sky, graded by hour and by season.
#
# The rig it replaces was a single warm key at 1.15 over a broad neutral
# ambient at 0.62, and two things went wrong with it.
#
# The first is measurable in the shipped screenshots. Sampling
# design/screenshots/first_road.png, a thatched roof comes out at (255, 234,
# 144) — two channels hard against the ceiling — while the material library
# asks for #b79556. In path_forming.png the keep's stone reads (223, 222, 215)
# against an authored #63605a. So the roofs had no ridge, no slope break and
# no modelling of any kind, because there was no headroom left to model them
# in, and the keep was a white cut-out rather than a stone building.
#
# The second is that a wide, flat, neutral ambient at that strength fills
# shadow to within a stop of light, which is precisely what removes form from
# a low-poly model: faceted geometry has nothing but the step between planes
# to describe itself with.
#
# So: a stronger, warmer key; a much dimmer and distinctly *blue* ambient; a
# cool counter-key for the planes the sun cannot reach; and a global exposure
# low enough to bring the brightest materials back down off the ceiling.

## Exposure.
##
## Chosen by working backwards from the measured screenshots above: the roofs
## were landing at or past full scale, so the whole image needed roughly a
## third taking off it to put the library's brightest channels — skin_light's
## red at #d2, grain_gold's at #c9, thatch's at #b7 — near the top of the range
## rather than through it. Grain and thatch are the ones that matter in
## practice: a citizen is a few pixels tall, a roof is not. That is an estimate
## from pixels, not from a meter — if thatch
## still clips, or if the ground has gone muddy, this is the one number to
## move, and everything else in this file is scaled relative to it.
const EXPOSURE := 0.92

## How far shadows are drawn.
##
## Every extra metre is paid for in shadow-map resolution everywhere, so this
## is a trade rather than a covering. It is comfortably past anything visible
## at the camera's resting distance and deliberately short of the far edge of
## the frame at full zoom-out, where the ground can be better than 450 m away:
## out there the fog is two thirds of the way to the sky and a missing shadow
## costs nothing. directional_shadow_fade_start softens the boundary itself.
const SHADOW_DISTANCE := 380.0


func _build_lighting() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.29, 0.45, 0.70)
	sky_mat.sky_horizon_color = Color(0.68, 0.76, 0.82)
	# A softer curve keeps the gradient working across the whole upper sky
	# rather than crushing it into a band just above the horizon, which is what
	# made the old sky look like a strip of paper behind the hills.
	sky_mat.sky_curve = 0.18
	sky_mat.ground_bottom_color = sky_mat.sky_horizon_color
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	sky_mat.ground_curve = 0.06
	sky_mat.sun_angle_max = 8.0
	sky_mat.sun_curve = 0.08
	sky.sky_material = sky_mat
	env.sky = sky

	# Ambient is driven explicitly rather than from the sky, so the night sky
	# can be genuinely dark without the settlement below becoming unreadable.
	#
	# It is also deliberately *blue*, and deliberately weak. Shadow on a sunlit
	# day is lit by the sky and nothing else; a neutral grey ambient at this
	# strength is the single most common reason stylised scenes look like flat
	# vertex colour.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.56, 0.80)
	env.ambient_light_energy = 0.34

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = EXPOSURE
	env.tonemap_white = 2.2

	# Aerial perspective. The old fog was too thin to do any work — the far
	# hills came out *lighter and more saturated* than the near ground, which
	# reads as depth running backwards. Exponential fog at this density leaves
	# the settlement itself close to untouched — about a seventh at the resting
	# camera distance of 95 m — while the far corner of a 768 m map sits some
	# seventy per cent of the way back into the sky. That is what puts the
	# kingdom in a landscape rather than on a table.
	#
	# Plain depth fog only. Height-banked fog would be the better tool here and
	# is deliberately not used: fog_height_density's exact meaning could not be
	# confirmed for this renderer without running it, and the failure mode if
	# it is wrong by an order of magnitude is the entire valley filling with
	# opaque haze. Not a thing to guess at.
	env.fog_enabled = true
	env.fog_light_color = Color(0.66, 0.74, 0.82)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.12
	env.fog_density = 0.0016
	env.fog_sky_affect = 0.35
	env.fog_aerial_perspective = 0.6

	# A gentle grade on top: slightly lifted contrast to restore the punch the
	# lowered exposure costs, and saturation held just under 1 so the greens
	# stop shouting.
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 0.96

	environment = WorldEnvironment.new()
	environment.name = "environment"
	environment.environment = env
	add_child(environment)

	sun = DirectionalLight3D.new()
	sun.name = "sun"
	sun.light_energy = 1.45
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_specular = 0.6
	sun.shadow_enabled = true
	# Shadows carry most of the sun/shade contrast now, so they are allowed to
	# be properly dark — but not black, because the sky still fills them.
	sun.shadow_opacity = 0.94
	# Godot's default depth bias is left alone — it is tuned for this shadow
	# mode and tightening it on a 768 m terrain buys acne, not contact. The
	# normal bias is nudged *up* instead, because the map now covers more
	# ground per texel than it did.
	sun.shadow_normal_bias = 2.4
	sun.shadow_blur = 1.1
	sun.light_angular_distance = 0.6
	sun.directional_shadow_max_distance = SHADOW_DISTANCE
	sun.directional_shadow_fade_start = 0.86
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_mode = \
			DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.rotation_degrees = Vector3(-48, 34, 0)
	add_child(sun)

	# The counter-key. Cool, weak, shadowless, and aimed from the opposite
	# quarter and slightly below the key so it catches the planes the sun
	# cannot reach — eaves, the shaded gable, the north face of a hill. It
	# costs one directional light and is what stops the shaded side of the
	# settlement from going to a single dead tone.
	fill = DirectionalLight3D.new()
	fill.name = "sky_fill"
	fill.light_energy = 0.30
	fill.light_color = Color(0.60, 0.74, 1.0)
	fill.light_specular = 0.0
	fill.shadow_enabled = false
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	fill.rotation_degrees = Vector3(-26, 214, 0)
	add_child(fill)


## Drive the sun from the clock so the settlement reads differently morning
## and evening. Night never goes fully dark — this is a strategy game and the
## board has to stay legible.
##
## `year_fraction` is the position in the year, 0 at the first day of spring.
## Passing a negative value leaves the season where it was, so callers that
## only have the hour need not invent one.
func set_time_of_day(fraction: float, year_fraction: float = -1.0) -> void:
	if year_fraction >= 0.0:
		_year_fraction = fposmod(year_fraction, 1.0)

	var t := fposmod(fraction, 1.0)

	# Days are longer in summer and shorter in winter. It is a small thing, but
	# it is the difference between four palettes and four seasons: winter is
	# not merely bluer, the light also stays lower all day.
	#
	# Two terms, and both are needed. `arc` is how high the sun climbs; the
	# seasonal *offset* is what moves sunrise and sunset, by lifting the whole
	# curve so it crosses zero later in summer and earlier in winter. Scaling
	# the amplitude alone — which is what this did — changed only the noon
	# elevation and left the sun setting at 17:17 every day of the year,
	# midsummer included, while this comment claimed otherwise.
	var summer: float = cos((_year_fraction - 0.375) * TAU)   # +1 midsummer
	var arc := 56.0 + summer * 13.0
	var elevation: float = sin((t - 0.22) * TAU) * arc + summer * 16.0

	# The sun is never allowed to graze the horizon. At a few degrees of
	# elevation every building throws a shadow across half the map, which
	# looks dramatic for one frame and makes the game unreadable for an hour.
	# The floor is low enough to give a long raking morning — raking light is
	# what makes faceted geometry legible — and no lower.
	# The azimuth sweeps a full 360 degrees across the day, not 300. The span it
	# used to sweep left the sun at 240 degrees a moment before midnight and at
	# -60 a moment after, which is a sixty-degree jump: every shadow in the
	# settlement swung across the ground in one frame. -60 to 300 is the same
	# opening bearing and lands exactly back on it, so the wrap is seamless.
	sun.rotation_degrees = Vector3(
		-clampf(elevation, 17.0, 74.0),
		lerpf(-60.0, 300.0, t),
		0.0
	)

	# Night never falls all the way. This is a strategy game before it is a
	# simulation of daylight: the board has to stay readable at 03:00, so the
	# darkest hour is a cool moonlit blue rather than actual darkness.
	var day_amount := clampf((elevation + 20.0) / 55.0, 0.34, 1.0)

	# Golden hour is the sun sitting *near* the horizon, not merely a dim sky.
	# Driving it from `day_amount` alone gave midnight exactly the same warm
	# cast as sunset — both sit on the floor of that curve — so the small hours
	# came out brown instead of the moonlit blue two comments in this file
	# promise. Fade it out once the sun is well down.
	var golden := (1.0 - smoothstep(0.30, 0.66, day_amount)) \
			* smoothstep(-26.0, -6.0, elevation)

	const NIGHT := Color(0.52, 0.66, 1.0)
	const GOLDEN := Color(1.0, 0.74, 0.47)
	const NOON := Color(1.0, 0.95, 0.85)
	var light := NIGHT.lerp(GOLDEN, smoothstep(0.16, 0.48, day_amount))
	light = light.lerp(NOON, smoothstep(0.44, 0.90, day_amount))

	# Winter light is thinner and bluer even at noon; high summer is brassy.
	var season_warm := Color(1.0, 1.0, 1.0).lerp(
			Color(1.04, 0.99, 0.90), maxf(summer, 0.0))
	season_warm = season_warm.lerp(
			Color(0.94, 0.97, 1.06), maxf(-summer, 0.0))
	light = Color(
		light.r * season_warm.r,
		light.g * season_warm.g,
		light.b * season_warm.b)

	sun.light_energy = lerpf(0.42, 1.45, day_amount) \
			* lerpf(0.88, 1.06, (summer + 1.0) * 0.5)
	sun.light_color = light

	# The fill tracks the sun's azimuth from the far side, so the cool side of
	# a building is always the side the sun is not on.
	fill.rotation_degrees = Vector3(
		-lerpf(18.0, 34.0, day_amount),
		lerpf(-60.0, 300.0, t) + 168.0,
		0.0
	)
	fill.light_energy = lerpf(0.16, 0.30, day_amount)

	var env := environment.environment

	# Twilight: the ambient goes blue and comparatively strong, because at dusk
	# the sky really is the main light. At noon it steps back and lets the key
	# do the work, which is what keeps the shadows crisp.
	# The night end of this curve is doing a different job from the day end.
	# By day the ambient deliberately steps back so the key light does the
	# modelling; after dark there is no key, so the ambient *is* the light, and
	# taking it down to daylight levels left the foreground at a fifteenth of
	# the luminance of the lit scene — unreadable, and flatly contrary to the
	# promise two comments above that the board stays legible at 03:00.
	env.ambient_light_energy = lerpf(0.82, 0.32, day_amount)
	env.ambient_light_color = Color(0.34, 0.46, 0.80).lerp(
			Color(0.44, 0.58, 0.82), day_amount)

	# The sky material is the one thing here that is not free to touch: writing
	# to it marks the sky dirty, and the renderer then regenerates its radiance
	# map. Doing that on every one of sixty frames a second, to move a gradient
	# by a thousandth, is pure waste — and at 16x speed the clock is driven
	# hard enough that it would happen on every frame of a long session. The
	# sky is therefore stepped rather than swept: 0.0015 of a day is a little
	# over four in-game minutes, which no eye will catch on a gradient this
	# soft, and it takes the update from every frame to roughly one in twenty
	# at normal speed. The sun itself still moves continuously, because moving
	# a light is cheap and a stepping shadow would not be.
	if absf(t - _last_sky_push) > 0.0015 or _last_sky_push < 0.0:
		_last_sky_push = t
		var sky_mat: ProceduralSkyMaterial = env.sky.sky_material
		sky_mat.sky_top_color = Color(0.07, 0.10, 0.22).lerp(
				Color(0.29, 0.45, 0.70), day_amount)
		# Sunrise and sunset warm the horizon band without warming the zenith,
		# which is the whole reason a low sun looks like a low sun.
		var horizon := Color(0.20, 0.22, 0.34).lerp(
				Color(0.68, 0.76, 0.82), day_amount)
		sky_mat.sky_horizon_color = horizon.lerp(Color(0.92, 0.66, 0.44),
				golden * smoothstep(0.26, 0.42, day_amount))
		# The lower sky is visible beyond the far water clip at shallow angles.
		# Its horizon must meet the upper hemisphere without a grey stripe.
		sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
		sky_mat.ground_bottom_color = sky_mat.sky_horizon_color

	# Fog carries the same warmth, so the distance sits under the same sky the
	# settlement does instead of behind a grey card.
	var fog := Color(0.17, 0.21, 0.34).lerp(Color(0.66, 0.74, 0.82), day_amount)
	env.fog_light_color = fog.lerp(Color(0.86, 0.68, 0.52), golden * 0.55)

	_apply_season(env)


## Season grading: the ground colour, the haze and the amount of colour in the
## picture. Pushed at the terrain shader only when it has actually moved, since
## the caller drives the clock every frame.
func _apply_season(env: Environment) -> void:
	# Spring 0.00 · summer 0.25 · autumn 0.50 · winter 0.75, wrapping.
	var s := _year_fraction * 4.0
	var i := int(floor(s)) % 4
	var f: float = smoothstep(0.0, 1.0, s - floor(s))

	var tint := _season_tint(i).lerp(_season_tint((i + 1) % 4), f)
	var dry := lerpf(_season_dry(i), _season_dry((i + 1) % 4), f)
	var frost := lerpf(_season_frost(i), _season_frost((i + 1) % 4), f)
	var haze := lerpf(_season_haze(i), _season_haze((i + 1) % 4), f)

	env.fog_density = 0.0016 * haze
	# Autumn mist and winter flatness both pull colour out of the distance;
	# high summer is the only time the world is allowed to be fully saturated.
	env.adjustment_saturation = lerpf(0.96, 0.82, frost)

	if terrain == null:
		return
	# The whole season collapses to one monotonic number, so the guard that
	# skips a redundant shader upload is a single comparison rather than four.
	# One unit of it is a season, so the threshold is about three quarters of
	# an in-game hour at the fastest part of the curve — far finer than any eye
	# could catch on a grade this slow, and coarse enough that the upload
	# happens a handful of times a day rather than sixty times a second. Note
	# that only the *upload* is skipped; the interpolation and the two
	# environment writes above are cheap and run every time.
	var key := float(i) + f
	if absf(key - _last_season_push) < 0.004:
		return
	_last_season_push = key
	terrain.set_season(tint, dry, frost)


func _season_tint(index: int) -> Color:
	match index:
		0: return Color(0.97, 1.08, 0.88)   # spring — new growth, yellow-green
		1: return Color(1.05, 1.00, 0.82)   # summer — sun-bleached, warm
		2: return Color(1.10, 0.95, 0.78)   # autumn — amber
		_: return Color(0.93, 0.96, 1.03)   # winter — cold and grey


func _season_dry(index: int) -> float:
	match index:
		0: return 0.10
		1: return 0.52
		2: return 0.82
		_: return 0.46


## How much the season drains colour and lays frost on exposed ground.
func _season_frost(index: int) -> float:
	match index:
		0: return 0.04
		1: return 0.0
		2: return 0.16
		_: return 0.82


func _season_haze(index: int) -> float:
	match index:
		0: return 0.95
		1: return 0.80
		2: return 1.35   # autumn mornings
		_: return 1.15


## A debug view of what the pathfinder believes: impassable cells in red,
## road-bearing cells graded green. Built lazily, since most sessions never
## ask for it.
func set_nav_overlay(enabled: bool) -> void:
	if not enabled:
		if _nav_overlay:
			_nav_overlay.visible = false
		return
	if _nav_overlay == null:
		_nav_overlay = _build_nav_overlay()
		add_child(_nav_overlay)
	else:
		# The builder returns a node; only its multimesh is wanted here. The
		# node itself has no parent and nothing else refers to it, so without
		# this it is simply leaked — once per time the overlay is reopened,
		# each one still holding a full-map MultiMesh.
		var rebuilt := _build_nav_overlay()
		_nav_overlay.multimesh = rebuilt.multimesh
		rebuilt.free()
	_nav_overlay.visible = true


func _build_nav_overlay() -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(Config.CELL * 0.9, Config.CELL * 0.9)
	quad.orientation = PlaneMesh.FACE_Y

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1, 0.45)
	quad.material = mat

	var cells: Array[Vector2i] = []
	var colours: Array[Color] = []
	for cz in grid_size:
		for cx in grid_size:
			var solid := nav.is_solid(cx, cz)
			var level := wear.road_level_of_cell(cx, cz)
			if not solid and level == Config.RoadLevel.NATURAL:
				continue
			cells.append(Vector2i(cx, cz))
			colours.append(Color(0.9, 0.2, 0.2) if solid
					else Color(0.2, 0.9, 0.4).lerp(Color(0.9, 0.9, 0.3),
							level / 5.0))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = cells.size()
	for i in cells.size():
		var c := cells[i]
		var p := Config.cell_to_world(c)
		p.y = heightmap.height_at(p.x, p.z) + 0.25
		mm.set_instance_transform(i, Transform3D(Basis(), p))
		mm.set_instance_color(i, colours[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "nav_overlay"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


func centre() -> Vector3:
	var half := size_m * 0.5
	return Vector3(half, heightmap.height_at(half, half), half)


func world_to_cell(p: Vector3) -> Vector2i:
	return heightmap.world_to_cell(p)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size


func clamp_world(p: Vector3, margin: float = 0.0) -> Vector3:
	return Vector3(clampf(p.x, margin, size_m - margin), p.y,
			clampf(p.z, margin, size_m - margin))


func install_bridge(id: int, a: Vector3, b: Vector3, width: float = 4.0) -> void:
	nav.install_bridge(id, a, b, width)


func remove_bridge(id: int) -> void:
	nav.remove_bridge(id)


func surface_height_at(x: float, z: float) -> float:
	return nav.surface_height_at(x, z)


func surface_speed_at(x: float, z: float) -> float:
	var c := world_to_cell(Vector3(x, 0, z))
	return nav.surface_speed(c.x, c.y)


func bridge_id_at(x: float, z: float) -> int:
	return nav.bridge_id_at(world_to_cell(Vector3(x, 0, z)))
