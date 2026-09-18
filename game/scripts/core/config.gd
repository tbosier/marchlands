class_name Config
extends RefCounted

## Central tuning constants for the Marchlands prototype.
##
## Anything a designer would want to reach for while balancing lives here
## rather than being scattered through the systems. Values marked "placeholder"
## come straight from the design document and are expected to move.

# --- World -----------------------------------------------------------------

## Side length of the playable world, in metres.
const WORLD_SIZE := 768.0

## Simulation/navigation cell size. Terrain mesh vertices share this spacing.
const CELL := 4.0

## Cells per side (WORLD_SIZE / CELL).
const GRID := 192

## The wear/road texture is finer than the nav grid so paths read as paths
## rather than as 4 m blocks.
const WEAR_SCALE := 2          # wear texels per nav cell, per axis
const WEAR_RES := GRID * WEAR_SCALE
const WEAR_CELL := CELL / float(WEAR_SCALE)

const SEA_LEVEL := 2.2
const MAX_BUILD_SLOPE := 0.42  # rise/run; steeper ground rejects buildings

# --- Time ------------------------------------------------------------------

## Real seconds per in-game day at 1x speed.
const DAY_LENGTH := 180.0
const DAYS_PER_SEASON := 12

## Time controls. The sub-1x rates exist for watching a single citizen make a
## decision; 16x is for letting a settlement run while you wait for a road to
## wear in. NORMAL_SPEED is the index the game starts at.
const SPEEDS: Array[float] = [0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 16.0]
const SPEED_LABELS: Array[String] = [
	"Paused", "0.25x", "0.5x", "1x", "2x", "4x", "16x",
]
const NORMAL_SPEED := 3

## Above this rate the simulation is stepped in slices, so one frame's work
## never explodes just because the clock is running fast.
const MAX_SIM_STEP := 0.5

# --- Movement (design doc 7.2 — placeholders) ------------------------------

## Base walking speed in m/s.
const WALK_SPEED := 2.6
const CART_SPEED := 2.0

## Terrain speed multipliers by surface.
const SPEED_WATER := 0.0
const SPEED_MARSH := 0.45
const SPEED_FOREST := 0.60
const SPEED_GRASS := 1.00
const SPEED_ROCK := 0.75

## Road speed multipliers by road level (index = RoadLevel).
const ROAD_SPEED: Array[float] = [1.00, 1.10, 1.22, 1.35, 1.55, 1.85]

# --- Emergent roads (design doc 7.1 — placeholders) ------------------------

enum RoadLevel { NATURAL, WORN, PATH, DIRT, IMPROVED, PAVED }

const ROAD_NAMES: Array[String] = [
	"Open ground", "Worn grass", "Footpath", "Dirt track",
	"Improved road", "Paved road",
]

## Wear required to reach each level. Index matches RoadLevel.
const ROAD_THRESHOLD: Array[float] = [0.0, 100.0, 500.0, 2000.0, 6000.0, 14000.0]

## Global scale applied to every wear stamp.
##
## The per-traveller weights below are the design document's relative figures
## (pedestrian 1, cart 5, and so on) and should stay as they are; this is the
## single knob that decides how quickly routes form. It is tuned so that a
## well-used route is a footpath within about two in-game days and a dirt
## track within about eight — fast enough to watch, slow enough to feel earned.
const WEAR_GAIN := 30.0

## Wear contributed per metre travelled, by traveller type. The design
## document's full table is kept here even though only two of these move yet:
## these ratios are the balance decision, and the systems that will use the
## rest (cavalry, marching columns, freight) should inherit them rather than
## invent new numbers.
const WEAR_PEDESTRIAN := 1.0
const WEAR_HORSE := 2.0          ## unused until mounted travel exists
const WEAR_CART := 5.0
const WEAR_COLUMN := 8.0         ## unused until armies march (design doc 13.2)
const WEAR_HEAVY_WAGON := 10.0   ## unused until bulk freight exists

## Wear bleeds away on untravelled ground, so abandoned routes grow over.
## Fraction of the *current level's* threshold lost per in-game day.
##
## At the original 0.035 a dirt track needed about seventy days to return to
## grass, which is four seasons — long enough that no player would ever see it
## happen. At 0.10 a grade is shed in roughly eight days and a track is gone
## inside two seasons, while a route in daily use still gains far faster than
## it loses. It also means heavy grades no longer sustain themselves on foot
## traffic alone: past a dirt track, keeping a road is a decision, not a
## side effect, which is what `locked` is for.
const WEAR_DECAY_PER_DAY := 0.10

## Wear stamps are a soft brush, in metres.
const WEAR_BRUSH_PEDESTRIAN := 1.3
const WEAR_BRUSH_CART := 2.4

## Cost, in resources, to have a route deliberately upgraded one level.
const UPGRADE_COST_TIMBER := 8
const UPGRADE_COST_STONE := 12

# --- Pathfinding -----------------------------------------------------------

## How much dearer it is to cross worked ground than open grass. High enough
## that traffic routes around a field rather than through it, low enough that
## the farmhands who work it still walk straight to their plots.
const CULTIVATED_COST := 7.0

## Cached paths are reused for this long before being recomputed, so that
## improving roads actually changes where people walk.
const PATH_CACHE_SECONDS := 12.0
const ARRIVE_RADIUS := 1.1

# --- Citizens --------------------------------------------------------------

const CARRY_CAPACITY := 12

## How many units a workshop makes in one spell at the bench.
const CRAFT_BATCH := 4.0

## The share of a workshop's store its raw materials may occupy. The rest is
## held back for finished goods, so a shop can never stock itself into a halt.
const WORKSHOP_INPUT_SHARE := 0.30

## Tools wear out in use. A march with tools in store works faster; one without
## goes back to bare hands, which is what gives iron a point.
const TOOLS_PER_WORKER_DAY := 0.10
const TOOLS_WORK_BONUS := 0.35

## Farming. A mature field is worth about FARM_HARVEST_TRIPS loads, then has to
## regrow — which sets how many mouths one farm can feed.
const FARM_GROWTH_DAYS := 7.0
const FARM_HARVEST_TRIPS := 16
const FARM_HARVEST_AT := 0.55
const FARM_INITIAL_GROWTH := 0.45
const START_CITIZENS := 20
const WORK_TICKS_PER_UNIT := 1.15   # in-game seconds to gather one unit
const HUNGER_PER_DAY := 1.0         # food eaten per citizen per day

## Meals, sleep and the household larder (design doc 9.1).
##
## Food is not drawn from a settlement-wide pool. A household keeps a larder,
## somebody has to physically carry food home to fill it, and each citizen sits
## down to eat twice a day. The totals are unchanged — two meals of MEAL_FOOD
## is still HUNGER_PER_DAY — so this changes where the food has to *be*, not
## how much of it the march gets through.
const MEALS_PER_DAY := 2
## When the household eats, as a fraction of the day: a little after dawn, and
## again before dark. Kept apart from the sleeping hours on purpose, so nobody
## has to choose between supper and bed.
const MEAL_TIMES: Array[float] = [0.30, 0.78]
const MEAL_FOOD := HUNGER_PER_DAY / float(MEALS_PER_DAY)
## Days of food a household will keep in, and therefore how often somebody has
## to walk to a granary. One trip carries a full larder for a four-person
## house, which is what keeps this from swamping the job board.
const LARDER_DAYS := 3.0
## How long a missed meal takes to become starvation.
const STARVE_DAYS := 2.5
## Hunger past this and a citizen drops what they are doing to go and eat.
const HUNGER_URGENT := 0.45
## How long a citizen who found no food waits before trying again.
const MEAL_RETRY_DAYS := 0.06

## Night. Citizens walk home and go inside; the settlement sleeps. The hours
## are deliberately not symmetrical about midnight — the march rises early.
const SLEEP_FROM := 0.88            # 21:07
const SLEEP_UNTIL := 0.22           # 05:17
## How far a citizen will walk home to sleep. Beyond this they bed down where
## they are: a woodcutter working the far woods camps out rather than walking
## two hundred metres home at dusk and two hundred metres back at dawn, which
## costs more of the day than the work itself.
const SLEEP_WALK_MAX := 70.0


## Whether `fraction` of a day falls in the small hours.
static func is_night(fraction: float) -> bool:
	var t := fposmod(fraction, 1.0)
	return t >= SLEEP_FROM or t < SLEEP_UNTIL


## The next time a meal falls due, as an absolute day, given the day it is now.
## Absolute rather than a fraction so it survives midnight and a save without
## any special casing.
static func next_meal_after(day: float) -> float:
	var whole := floorf(day)
	for t in MEAL_TIMES:
		if day < whole + t:
			return whole + t
	return whole + 1.0 + MEAL_TIMES[0]

# --- Economy ---------------------------------------------------------------

enum Res { FOOD, TIMBER, STONE, IRON, TOOLS }

## Display names, carried props and colours live in `Res`; this is only the
## count, because it sizes every per-resource array in the simulation.
const RES_COUNT := 5

# --- Immigration (design doc 9.2) -----------------------------------------

const IMMIGRATION_MIN_FOOD_DAYS := 4.0
const IMMIGRATION_GROUP_MIN := 2
const IMMIGRATION_GROUP_MAX := 6

# --- Presentation ----------------------------------------------------------

## The ground palette, authored in sRGB. Terrain converts to linear before
## handing these to the shader.
##
## Two rules govern it. The meadow needs a real range between its wet green and
## its dry straw, because that range is all the shader has to model a landscape
## with. Weighting the authored sRGB components the way the eye does, the
## previous pair sat at 0.44 and 0.54 — ten points apart, which is why the
## whole world came out one shade. This pair sits at 0.36 and 0.58, better than
## twice the room, and that range is the difference between rolling ground and
## billiard cloth.
##
## And the five road surfaces have to *alternate* in value, not march quietly
## up a brown ramp. Trodden earth is pale and dry; a cart track is churned,
## damp and dark; an improved road is laid with pale drained gravel; a paved
## one is cold grey sett. Each upgrade therefore steps light, dark, light,
## grey — so a player watching a route mature sees each grade arrive, which is
## the entire promise of the mechanic.
const COLOR_GRASS := Color(0.29, 0.40, 0.21)
const COLOR_GRASS_DRY := Color(0.61, 0.59, 0.34)
const COLOR_SOIL := Color(0.31, 0.25, 0.17)
const COLOR_ROCK := Color(0.45, 0.44, 0.41)
const COLOR_SAND := Color(0.72, 0.66, 0.49)
const COLOR_WATER := Color(0.12, 0.25, 0.31)
const COLOR_MARSH := Color(0.25, 0.30, 0.22)
const COLOR_PATH := Color(0.54, 0.45, 0.32)
const COLOR_TRACK := Color(0.40, 0.34, 0.26)
const COLOR_IMPROVED := Color(0.64, 0.59, 0.47)
const COLOR_PAVED := Color(0.51, 0.50, 0.49)


static func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(floor(p.x / CELL)), 0, GRID - 1),
		clampi(int(floor(p.z / CELL)), 0, GRID - 1)
	)


static func cell_to_world(c: Vector2i) -> Vector3:
	return Vector3((c.x + 0.5) * CELL, 0.0, (c.y + 0.5) * CELL)


static func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GRID and c.y < GRID


static func road_level_for_wear(wear: float) -> int:
	for level in range(ROAD_THRESHOLD.size() - 1, 0, -1):
		if wear >= ROAD_THRESHOLD[level]:
			return level
	return RoadLevel.NATURAL


## The road level as a continuous 0..5 value.
##
## The terrain shader wants a quantity where each surface stage occupies an
## equal, predictable slice — raw wear is exponential and squashes the upper
## levels into a sliver, so a paved road would never look paved.
static func road_level_continuous(wear: float) -> float:
	var top := ROAD_THRESHOLD.size() - 1
	for level in range(top, 0, -1):
		if wear >= ROAD_THRESHOLD[level]:
			if level >= top:
				return float(top)
			var lo: float = ROAD_THRESHOLD[level]
			var hi: float = ROAD_THRESHOLD[level + 1]
			return level + clampf((wear - lo) / maxf(hi - lo, 1.0), 0.0, 1.0)
	return clampf(wear / ROAD_THRESHOLD[1], 0.0, 1.0)
