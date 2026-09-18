<p align="center">
  <img src="design/branding/logo.png" alt="Marchlands" width="880">
</p>

---

> ### This is an AI-generated game
>
> I did not write it. I am using this repository to test how well AI can build
> a game end to end — the design, the simulation, the procedural art pipeline,
> the verification harness, the debugging, and this README. My part is
> direction and judgement; the code in `game/` and `tools/`, every asset in
> `assets/`, the screenshots, and the logo above were all produced by AI.
>
> It is an experiment and it is meant to be read as one, including the parts
> that did not come out well — see [Known gaps](#known-gaps), which is a
> deliberate section rather than an oversight.

---

# Marchlands

A 3D kingdom builder whose roads are not drawn by the player. People walk
across the landscape, their routes wear into the ground, and the settlement's
transport network emerges from where its inhabitants actually go.

This repository contains the first vertical slice — the milestone the design
document calls **"The First Road"** (`design/GAME_DESIGN.md` §34) — together
with the procedural asset pipeline that produces everything you see in it.

![The settlement at day 16](design/screenshots/first_road.png)

*Nothing in that road network was placed. The improved road running east was
worn in by woodcutters walking to a logging camp; the branch heading
south-west is the farmers' route to the fields; the streets between the houses
are ordinary daily traffic. The player's only road decision was to pay to
improve the busiest stretch.*

---

## Quick start

```bash
# Install the tools (Arch). Any Blender 4.2+ / Godot 4.4+ will do.
# Pillow is what stitches the contact sheet; rsync is what `sync` uses.
sudo pacman -S blender godot python-pillow rsync xorg-server-xvfb

tools/build.sh all      # generate assets -> validate -> import into Godot
tools/build.sh run      # play
```

`tools/build.sh` looks for `blender` and `godot` on `PATH` first, and falls
back to `tools/vendor/` so a checkout can carry its own toolchain.

### Controls

| | |
|---|---|
| `W` `A` `S` `D` | pan |
| mouse wheel | zoom (and tilt — closer is more oblique) |
| middle-drag / `Q` `E` | rotate |
| left click | select a building, a citizen, or the ground under a route |
| `Space` | pause / resume at the rate you were at |
| `1`–`6` | speed: 0.25× · 0.5× · 1× · 2× · 4× · 16× |
| `[` `]` | step the speed down / up |
| `R` | rotate a building while placing (the tool stays armed after placing) |
| `B` | open / close the build tray · `C` the Clear Ground tool |
| `Delete` | cancel or pull down the selected building, materials returned |
| `F` | focus the selection · `Esc` cancel · `F12` screenshot |
| `Ctrl+S` `Ctrl+L` | save the march / load it back |
| `F3` | developer overlay (off by default; `--dev` to start with it on) |

### Developer mode

`F3`, or launch with `-- --dev`. It shows where frame time is actually going —
the same `Perf` spans the headless scenario runs print — plus population, job
board and draw-call counts. While it is open:

| | |
|---|---|
| `F4` | spawn ten settlers at the keep |
| `F5` | finish every building instantly |
| `F6` | grant 300 of every resource |
| `F7` | wear in the route under the cursor |
| `F8` | navigation overlay: impassable cells red, road cells graded green |
| `F9` | reset the performance counters |

It is deliberately off unless asked for: design doc §30 asks that the game not
advertise how it was made.

The build tray opens from the bottom bar. Alongside the buildings there is a
**Clear Ground** tool: click trees and citizens will fell them and carry the
timber to your stores — which is also how you recover from committing your last
timber to a site you cannot finish, since selecting any building under
construction offers to cancel it and return what was delivered — or to say
plainly what could not be returned, if the stores are full.

Pick a building from the tray, and the cursor tooltip tells you the
footprint, the ground slope, the cost, how far the nearest worker would have to
walk, and which store the site would draw from. Click bare ground to select the
**route** there; if people have worn it in far enough, the panel offers to
improve it.

---

## What is implemented

The design document builds the simulation in layers (§19). Layers 1–5 are
present, plus the parts of the asset pipeline (§5) that feed them.

**Layer 1 — World.** A 768 m × 768 m continuous world on a 4 m simulation
grid: procedural relief, a lake, marsh, woodland and rock classified from
height/slope/moisture, a fertility field that decides where farmland is worth
having, and resource deposits (forest, stone outcrops, iron in the north-west).
Elevated free camera, analytic terrain picking, day/night and seasons.

**Layer 2 — Citizens.** Agents with a name, age, profession, household,
workplace, hunger and morale. They walk the world physically, are animated
procedurally by rotating the limb pivots the Blender export provides (no
armature, no imported clips), and carry visible goods.

They also eat and sleep, and both are physical. There is no settlement-wide
ration: a household keeps a **larder**, the only way food gets into it is a
citizen carrying some home from a granary, and each person sits down to **two
meals a day** out of it. A bare cupboard sends somebody to fetch more; an empty
granary means they go hungry, and hunger is tracked per person rather than as a
kingdom-wide number. At dusk they walk home and go indoors until morning —
except those working too far out to make the trip worth it, who camp where they
are rather than spend the day walking. That second daily journey, house to
granary and back, is one of the largest contributors to the paths that form
through a settlement: the roads a march wears in are partly the roads to
its dinner.

![The settlement at night](design/screenshots/night.png)

*Day 4, a quarter to eleven at night. There is nobody on the map — every one of
the twenty-four is inside their own house — and the paths they wore between
those houses, the granary and the fields are what is left to look at.*

**Layer 3 — Logistics.** Local inventories — there is no global stockpile
(§11.2). Buildings post what they need to a job board; citizens score open
jobs by priority and travel cost and claim them. Production sites fill up and
need emptying into real storage, which is what creates the repeated round
trips. One hand cart, taken up by a citizen for bulk hauls.

**Layer 4 — Emergent roads.** The heart of it. Every moving entity stamps wear
into a fine-grained field as it travels; wear crosses thresholds and the ground
becomes worn grass, then a footpath, then a dirt track, then an improved road.
Those states drive both the terrain shader and the navigation weights, so a
route that forms becomes cheaper to walk, so more people use it, so it deepens.
Unused routes grow back over. The player can pay to improve a route that has
already proven itself — but only one that exists.

**Player tools.** Buildings can be cancelled or pulled down, returning their
materials. Ground can be cleared of trees on the player's order. Goods stored
in the open — a stockpile's deck, a granary's sacks, a farmyard, the keep's own
yard — are physically visible and grow with the amount held, and a farm's
fields are exactly as large as the number of farmhands actually working it.
Ground under crop refuses to record a track, so a route never forms straight
through a field.

**Upgrades.** A building grows into its next tier rather than being replaced
(§6.4): a Granary becomes a Grain Warehouse, a Blacksmith becomes a Forge. The
structure keeps its id, its stock and its residents, goes back to being a site
that haulers supply and builders raise, and reopens larger on the same ground.
Its staff are stood down while the work is on — an upgrading workshop is a
building site — and rehired when it reopens, so they may have taken other posts
in the meantime. That is what preserves the visible history of a settlement — the
granary the player put up on day three is still the building standing there.

**Saving.** `Ctrl+S` writes the march to `user://saves/quicksave.sav`, `Ctrl+L`
reads it back. The file holds what cannot be derived — the wear ground into the
soil, what has been built and how far, who lives here, what the stores hold,
which trees are gone — and the world itself is regenerated from its seed. Jobs
are deliberately not saved: they are a cache the simulation rebuilds every
tick, and reconstructing a half-finished delivery from a file creates phantom
reservations rather than continuity. The `save_load` scenario changes the world
after saving — another building, more trees felled, more ground worn — proves
the change took, and only then reloads, so a load that quietly did nothing
cannot pass. What it compares is per-thing, not per-kingdom: every building by
id with its contents, staffing and resident counts, field count and
construction progress; every citizen by id with their name, home, workplace and
load; road cells counted by level; total wear; standing trees; marked trees;
and the number of terrain edits. It is a fingerprint, not a deep equality: two
edit lists of the same length compare equal, and a site's delivered materials
are covered only through its progress figure. It then checks the pathfinder still agrees with the
roads, and that the reloaded settlement will accept and complete a new
building order.

**Layer 5 — Settlement growth.** Housing, food production with a growth and
harvest cycle, consumption and famine, and immigration: settlers evaluate the
kingdom's spare housing, food security and available work, then physically walk
in from the map edge.

### Not yet built

Layers 6–8 — military, institutions and rail — along with rival kingdoms,
diplomacy and technology. Per §33, none of that should be started until the
core loop is fun to watch, which is exactly what this slice exists to test.

---

## The asset pipeline

Every building, tree, prop and citizen in the game is generated by a Python
program that drives Blender. No asset was downloaded or modelled by hand.

```
assets/specs/*.yaml          machine-readable style + asset specification
        |
tools/blender/marchlands_kit  modular kit: walls, roofs, doors, windows,
        |                     chimneys, awnings, stairs, crenellation, …
        v
   generate_assets.py         assembles, welds, angle-smooths, UVs, LODs,
        |                     collision, attachment points
        v
assets/generated/*.glb        + a .json manifest per asset
        |
   validate_assets.py         scale, origin, materials, triangle budget,
        |                     LOD chain, collision, attachments, silhouette
        v
   render_previews.py         turntable contact sheets for review
        |
        v
      the game                reads the manifest — never hardcodes a size
```

```bash
tools/build.sh assets                 # regenerate everything
tools/build.sh assets house_small_01  # or just one
tools/build.sh validate -v            # full PASS/WARN/FAIL report
tools/build.sh previews               # turntables + assets/previews/_all_assets.png
tools/build.sh icons                  # the build-tray icons
tools/build.sh shaders                # compile the shaders on a real driver
```

`shaders` builds everything under `game/shaders/` on Mesa's llvmpipe under
Xvfb — no GPU needed — and fails if the engine rejects one, or if GDScript sets
a uniform that no longer exists. It runs as the last step of `build.sh all` and
takes about seven seconds. It needs `xvfb-run` (`pacman -S xorg-server-xvfb`).

The **manifest is the contract**. The game asks the registry for a building's
footprint, height and entrance position rather than storing its own copy, so
regenerating an asset at a different size moves the placement footprint and the
spot citizens walk to, with no code change.

`assets/specs/style.yaml` is the machine-readable form of the art direction in
§4.2 — one scale, one forward axis, one origin rule, a material library of
twenty shared materials with a cap of seven per asset, per-category triangle
budgets, and the attachment points the game reads by name (`att_entrance`,
`att_cart_bay`, `att_worksite`, `att_smoke`, `att_stock_*`). The validator
enforces most of it, so style drift is a build failure rather than something
noticed months later — but not all of it: `origin.tolerance_m` is declared as
0.02 m and no asset in the set is built to anything like that, so what is
actually enforced is that the origin sits within 35% of the footprint of its
centre, with a warning past 12%.

The validator reads the live spec and measures the exported `.glb`: bounds come
from the file's own position accessors, LOD levels from its nodes, and the
material count from the materials its visual meshes actually draw with. The
manifest is checked *against* that rather than trusted for it — validating the
manifest against itself proved only that the generator was self-consistent, and
an export scaled a hundredfold or missing both reduced meshes passed. Bounds
are read from each mesh node's own accessor, so the check also asserts that
every node transform is identity; that is what keeps a scale on a parent node
from moving geometry the size check never sees. Two manifest fields the game
reads are *not* reconciled with the geometry — `height_m` and the attachment
coordinates — and the triangle counts of the reduced LODs are taken on trust.
Tightening
a budget or a material cap in `style.yaml` fails assets produced under the old
limit. It does **not** yet check topology — `style.yaml` declares
`non_manifold_allowed: false` and nothing enforces it, so treat that line as
intent rather than a guarantee.

```
$ tools/build.sh validate
=== 28 passed, 0 failed, 3 with warnings ===
```

---

## Verifying it actually works

The simulation is checked by driving real play sessions, not by unit-testing
the pieces in isolation. `tools/scenes/*.json` are scripted scenarios executed
by an in-game harness that can place buildings, run the clock for in-game days,
assert on world state, and photograph the result.

```bash
tools/build.sh harness tools/scenes/first_road.json
```

`first_road.json` is the §34 definition of done, executable:

```
PASS wear_above 100 (peak 1928)
PASS road_level_at_least Footpath (reached Dirt track)
PASS Timber >= 60 (have 326)
PASS population 24 >= 20
upgraded route at (397, 411): Dirt track -> Improved road
PASS navigation weights match road levels (93 cells)
PASS road_level_at_least Dirt track (reached Improved road)
ALL CHECKS PASSED
```

That `nav_matches_roads` line exists because an adversarial review found the
scenario passing with the feature broken: paying to upgrade a route was
changing how the ground looked without ever reweighting the pathfinder, and
every assertion still went green. Asserting on the road's *appearance* was
never enough; the test now asserts on the graph the citizens actually use, and
fails if the defect is reintroduced.

| scenario | what it proves |
|---|---|
| `first_road.json` | paths form from traffic, an upgrade reaches the pathfinder, and routes can be improved |
| `regrowth.json` | an abandoned route grows back over |
| `input_check.json` | cursor rays land where aimed; clicking a building selects that building, or one demonstrably in front of it |
| `ui_check.json` | every building is still clickable at a second window size, and the frame is photographed for inspection |
| `construction.json` | blueprints are supplied by haulers and raised by builders |
| `daynight.json` | the board stays readable around the clock |
| `closeup.json` | citizens, carts and camp detail at player zoom |
| `stress.json` | 160 citizens and twelve buildings, with a timing report |
| `dev.json` | the developer overlay renders |
| `farm_check.json` | fields track the workforce, and worked ground refuses to record a track |
| `tools_check.json` | felling, cancelling a site, the seat's protection, goods on show |
| `industry.json` | mined iron reaches the forge and comes out as tools, with the work-rate bonus those tools earn |
| `save_load.json` | a saved march comes back whole and keeps working |
| `upgrade.json` | a granary and a smithy grow into their next tier in place, and survive a save |
| `households.json` | food is carried home, kept in a larder and eaten twice a day; the march sleeps indoors at night; and both survive a save |

Some defects are transient — a load delivered as the wrong resource is wrong
for a tick or two and then gone — and an assertion placed after a simulation
step samples a moment that has almost certainly already passed. `{"op":
"watch", "check": ...}` arms an invariant that runs on every step of every
`simulate` op instead, and reports the step it first broke on. That is the difference between
a test that could catch the bug and one that could not, and each one was
checked by reintroducing the defect and confirming the watch fires.

Screenshots committed under `design/screenshots/` were all produced this way:
`first_road.png` (above), `path_forming.png` (day 3, the first trails),
`construction.png` (a blueprint being supplied) and `asset_sheet.png` (every
generated asset on one contact sheet).

Screenshots land in `artifacts/`, and the harness exits non-zero on any failed
assertion, so it works as a regression gate.

---

## Known gaps

Published deliberately, because an experiment that only shows its successes is
not reporting anything. These are known and unfixed, not undiscovered:

* **The validator takes some of the manifest on trust.** It measures LOD0
  against the exported geometry, but the reduced LODs' triangle counts, the
  declared `height_m` and the attachment coordinates are only checked for
  presence and plausibility, not against the mesh.
* **Collision meshes are generated, exported, validated and then discarded.**
  The game builds its own pick box from the manifest and picks terrain
  analytically, so every collision mesh in the pipeline is dead weight.
* **The shaders are compiled, but not proven in situ.** `tools/build.sh shaders`
  builds both shaders on a real OpenGL driver — Mesa's llvmpipe under Xvfb, so
  it wants no GPU — and fails on anything the engine complains about. The
  headless harness never did: break a shader and it prints `SHADER ERROR`, then
  `ALL CHECKS PASSED`, and exits 0. What the check compiles them onto is a test
  quad rather than the game, and the cross-check that GDScript still addresses
  uniforms which exist is textual, so it would not catch a parameter moved from
  the terrain material to the water material inside the one file that builds
  both.
* **Screen-space tests need a screen.** `input_check` and `ui_check` click
  through the game's real input handler, which means they need a real viewport;
  headless opens a 64-pixel one where the top bar covers everything. They now
  refuse to run there and say so rather than reporting a result, so those two
  want `tools/build.sh harness <scene>` or `xvfb-run`.

---

## Performance

`stress.json` runs 160 citizens across twelve buildings and prints a frame
budget, so an optimisation can be shown to have worked rather than asserted to.
Measured at 4× on the same machine and scenario:

| span | before | after |
|---|---:|---:|
| `sim.total` | 8.94 ms | **4.76 ms** |
| `wear.flush` | 3.57 ms | **0.40 ms** |
| terrain texels rewritten on the CPU / frame | 8 313 | **59** |
| job-board entries scanned / frame | O(citizens × jobs) | **~4** |

Two caveats on that table, so it is not read for more than it says. The texel
figure counts entries rewritten in the CPU-side pixel buffer, not a partial GPU
upload — `ImageTexture.update()` always submits the whole 384×384 image, and the
saving there came from uploading once per frame instead of once per simulation
step. And the before/after numbers were taken during the work at 4×;
`stress.json` now runs at 16× and reports timings only, so re-running it
reproduces the method, not those exact figures.

What was actually wrong, in order of size:

* **The terrain texture was uploaded once per simulation step, not once per
  frame.** At high speed the game takes many steps between frames, so it was
  uploading the same 384×384 texture ten times for one visible result.
* **Dirty regions were tracked as a bounding box.** Two citizens walking in
  opposite directions dirtied a rectangle covering everything between them, so
  the flush cost grew with the size of the kingdom rather than with the amount
  that changed. It now tracks individual texels.
* **Wear decay walked all 147 456 texels every in-game day.** It now walks only
  ground that has ever been stepped on — typically a few thousand cells.
* **Every idle citizen allocated a closure every tick** to filter the job
  board, and the search was over every job ever posted. Open jobs are now a
  separate list matched with an integer filter.
* **Employment and housing were rebuilt from scratch** on every placement,
  arrival and completion. Besides the cost, it meant a citizen's job was never
  stable — a reshuffle could hand their post to whoever stood closer that
  second. Assignment is now incremental, and only vacancies are filled.
* **The resource readout triggered seventeen full scans** of the building and
  citizen lists four times a second. Totals are computed once per tick.
* **The generated LOD meshes were never used.** Buildings and trees rendered at
  lod0 at any distance; they now use Godot's native visibility ranges, and
  distant vegetation is excluded from the shadow pass.
* **…and once they were used, they were wrong twice over.** The first band
  ended at 70 m while the camera rests at 95, so every building in a default
  session showed its *reduced* mesh and none of the detail the pipeline pays
  for. Worse, those reduced meshes were collapse-decimated: on hard-surface
  geometry this sparse that does not simplify a house, it dissolves the wall
  panels and leaves the timber frame standing as a cage of floating sticks.
  Building LODs are now authored by detail tier — a distant building loses its
  studs, shutters, fences and firewood, never its walls — and the first band
  clears the resting camera. Foliage still decimates, which is what collapse is
  good at.

Pathfinding, the thing most likely to be blamed, turned out to be 0.06 ms and
3 paths per frame — `AStarGrid2D` is native and the route cache was already
doing its job. Measuring first is the point.

The frame rates in those runs (~3 fps) are software rasterisation on a headless
machine and say nothing about the game; only the `sim.*` spans are meaningful.

---

## Layout

```
marchlands/
├── design/
│   ├── GAME_DESIGN.md         the original design document
│   ├── screenshots/           harness output kept for documentation
│   └── branding/              the wordmark (generated, like everything else)
├── assets/
│   ├── specs/                 style + material specification (source)
│   ├── generated/             .glb + .json manifests (build product)
│   └── previews/              turntable contact sheets
├── tools/
│   ├── blender/               the generators and the modular kit
│   ├── validators/            spec enforcement, glb inspection
│   ├── scenes/                scripted verification scenarios
│   ├── branding/              make_logo.py — draws the wordmark from the
│   │                          game's own material palette
│   └── build.sh               the whole pipeline
└── game/                      the Godot 4 project
    ├── scripts/core/          config, resources, clock, camera, registry,
    │                          LOD, profiler, harness
    ├── scripts/world/         heightmap, terrain, wear field, navigation
    ├── scripts/sim/           buildings, jobs, production, stores,
    │                          workforce, population, the simulation
    ├── scripts/agents/        citizens, carts
    ├── scripts/ui/            the interface, developer overlay
    └── shaders/               terrain.gdshader, water.gdshader
```

Two files are worth reading first: `game/scripts/world/wear_field.gd`, which is
the world's memory of movement, and `game/scripts/core/config.gd`, which holds
every tuning constant in one place.

The simulation is split by *cadence*, which is the thing that kept getting
mixed up when it was one class:

| | runs | file |
|---|---|---|
| citizen behaviour | every tick | `sim/simulation.gd` |
| deciding what work exists | a rota, a few times a second | `sim/production.gd` |
| employment and housing | only when something changes | `sim/workforce.gd` |
| goods index and totals | once per tick | `sim/stores.gd` |
| food, hunger, immigration | once per in-game day | `sim/population.gd` |

### Adding things

* **A building**: one entry in the table in `sim/building_defs.gd`. Fields are
  checked against a whitelist and the asset is checked against the registry at
  startup, so a typo is a loud error rather than a silent default.
* **A resource**: one entry in `core/resources.gd` (name, carried prop, colour),
  its enum member in `Config.Res`, and `Config.RES_COUNT` raised to match — the
  per-building inventory, incoming and reserved arrays are sized from that
  constant, so leaving it behind indexes past the end of all three.
* **A verification scenario**: a JSON file in `tools/scenes/`.

---

## Notes on the technical choices

**Godot 4, Compatibility renderer.** The art is flat-shaded low-poly, so
Forward+ buys little, and Compatibility runs on software rasterisers — which is
how the verification screenshots above are produced without a GPU. Switch
`renderer/rendering_method` in `project.godot` for SSAO and better shadows.

**`AStarGrid2D` for navigation.** Native code, which keeps a 192×192 graph fast
enough to repath dozens of citizens without a hierarchical scheme. Road level
changes reweight the affected cells, which is what closes the feedback loop
between where people walk and where walking is cheap. Paths are string-pulled
so citizens walk lines rather than grid staircases — and it is the smoothed
line that gets worn into the map.

**Two grid resolutions.** Navigation and terrain run at 4 m; the wear field
runs at 2 m and is stamped with a soft brush in world space. Paths therefore
look like paths rather than like 4 m blocks, while pathfinding stays cheap.

**The wear texture stores surface level, not raw wear.** Wear is exponential
(100 / 500 / 2 000 / 6 000 / 14 000), which squashes the upper road grades into
a sliver; storing the continuous 0–5 level instead gives every grade an equal,
predictable band in the shader.

**Terrain is picked analytically.** Marching the heightmap is cheaper and more
reliable than giving 74 k triangles a collision shape, and it lets the cursor
read the ground through a building standing on it.

---

## Balance knobs

`game/scripts/core/config.gd`. The one to reach for first is `WEAR_GAIN`: the
per-traveller weights are the design document's relative figures (pedestrian 1,
cart 5, column 8) and should stay as they are, while `WEAR_GAIN` alone decides
how fast routes form. It is currently tuned so a well-used route is a footpath
within about two in-game days and a dirt track within about eight — fast enough
to watch, slow enough to feel earned.
