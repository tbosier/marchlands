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

A medieval settlement simulation and RTS built around real residents, physical
supplies, and imperfect information. People walk across the landscape, their
routes wear into the ground, and the transport network emerges from their
journeys. Every soldier, merchant, and scout leaves a civilian job behind.

This repository builds on **"The First Road"** (`design/GAME_DESIGN.md` §34)
with markets, researched infrastructure, and a first supplied-army scenario
against one rival town. The procedural asset pipeline produces the base art;
stalls, fortifications and combat effects are assembled in code.

The first [base-game trade slice](design/TRADE_2026-09-21.md) is playable:
citizen-run caravans, finite barter with the rival town, selectable worlds,
river crossings built by workers, and recovery of goods from lost carts.

See the [current integration review and remaining priorities](design/STATUS_2026-09-21.md)
for what is implemented, what was deferred, and what should come next.
The [design north star](design/NORTH_STAR.md) records the intended identity and
the larger ideas that remain future work.

![The settlement at day 16](design/screenshots/first_road.png)

*Nothing in that road network was placed. The improved road running east was
worn in by woodcutters walking to a logging camp; the branch heading
south-west is the farmers' route to the fields; the streets between the houses
are ordinary daily traffic. The player's only road decision was to pay to
improve the busiest stretch.*

---

## Quick start

```bash
# Install the tools (Arch). The verification gate tests Godot 4.7.2.
# Pillow is what stitches the contact sheet; rsync is what `sync` uses.
sudo pacman -S blender godot python-pillow rsync xorg-server-xvfb xorg-xauth mesa

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
| left click | select a building, citizen, soldier, cow, resource deposit, or route |
| click a soldier | selects his whole company · `Alt`-click just him · `Shift`-click adds to the selection |
| `G` | form the selected soldiers into a company, split them off, or merge companies |
| right click | order selected scouts to explore, or soldiers to move/attack; otherwise cancel selection |
| `Space` | pause / resume at the rate you were at |
| `1`–`6` | speed: 1× · 2× · 4× · 16× · 32× · 64× |
| `[` `]` | step the speed down / up |
| `R` | rotate a building while placing (the tool stays armed after placing) |
| `B` | open / close the build tray · `C` the Clear Ground tool |
| `Delete` | cancel or pull down the selected building, materials returned |
| `F` | focus the selection · `Esc` cancel (or clear alerts) · `F12` screenshot |
| `P` | footfall overlay: where traffic is wearing routes in |
| `Ctrl+S` `Ctrl+L` | save the march / load it back |
| `F3` | developer overlay (development builds, or any build launched with `--dev`) |

Choose **World** on the bottom bar to start a river-and-mountain landscape:
Small (768 m), Medium (1,536 m), Large (3,072 m), or Extra large (6,144 m).
Save the current march before replacing it. Existing saves retain their original
geography; the default opening also keeps the original small landscape.
For a fresh generated landscape at launch, use
`tools/build.sh run -- --world-size=small` (also `medium`, `large`, or `xl`).

Build a **Scout lodge**, train a resident through **Scouts**, select that person,
and right-click to explore. Unknown ground is obscured; remembered terrain is
dimmed. Discovered towns leave dated reports. **Visit known castle** sends a
scout to seek the ruler's account; ordinary observations are estimates. Merchants
can bring observations from established routes, but cannot explore on command.

After discovering the neighboring town, build a **Market** and open **Trade**
to assign a resident and cart. The first
offer exchanges 24 timber for 8 iron, with separate travel provisions. The
merchant leaves local production until they return. **Bridge** lets you choose
two river banks, inspect the cost and detour saved, and commission a timber
crossing without research. Workers must deliver materials and finish the deck.

Select a soldier to inspect wounds, blood loss, shock, armor, and learned skills.
At a barracks, **Medic** equips that person with two paid medical kits. Medics
walk to nearby wounded and bandage or splint them; each treatment consumes a kit.
Injuries persist through discharge and later service. There are no floating
health bars. See [scouting and wounds](design/SCOUTING_AND_WOUNDS_2026-09-21.md)
for the implemented limits.

The opening settlement has a **Well**. Build more where people work and travel:
citizens physically visit them to drink, and fire responders carry buckets from
wells to burning buildings. Select a burning building to request a responder.
Visible enemy units generate contact alerts. Scouts can sabotage a visible enemy
well, but must collect supplies and spend time there; town guards can spot the
approach and interrupt it. Older saves without a well need one built.

### Developer mode

`F3` in a development build, or launch any build with `-- --dev`; an exported
release ignores `F3` otherwise, and the tool keys do nothing while it is off. It shows where frame time is actually going —
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
| `Alt+T` · `Alt+B` | a trained scout at the keep · a scout at the rival well with a sabotage kit |
| `Alt+F` · `Alt+R` | recruit a friendly soldier · a rival soldier at your keep, and war |
| `Alt+X` · `Alt+K` | declare war · kill the selected soldiers |
| `Alt+J` | wound the selected soldier (location and severity from the panel) |
| `Alt+P` · `Alt+I` | poison one of your own wells · set the selected building alight |
| `Alt+N` · `Alt+Z` | jump to the next season · to just before the next hard frost |

Every row is also a button on the panel.

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

**Layer 1 — World.** Selectable 768–6,144 m square worlds on a 4 m simulation
grid. New geography includes connected rivers, forest stands, mountain ridges
and passes, with a fertile starting clearing. Terrain and wear rendering use
chunks so the largest world has 64 times the original area. Legacy worlds keep
their original relief, lake, marsh, woodland and resource layout.
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
becomes worn grass, then a footpath, then a dirt track. Improved roads require
researched, paid roadworks.
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
which trees are gone — and the world itself is regenerated from its seed,
saved size and generation version. Local job-board assignments are rebuilt.
Caravan phases, people, cargo and trade promises are saved explicitly; bridge
deliveries, construction progress and lost-cart recovery orders also persist.

Loading checks record types, numeric bounds, IDs, assignments, asset names,
resource arrays and terrain edits before building a replacement march in an
isolated viewport. Resource records are checked against that regenerated world
before they are applied. The current world, clock and controls stay intact when
a save is rejected; the replacement takes over only after restoration succeeds.
Variant decoding cannot instantiate objects. Existing version-1 saves retain
their documented defaults for fields added later, including meals and resume speed.

The `save_load` scenario changes the world after saving — another building,
more trees felled, more ground worn — proves the change took, and only then
reloads. Its snapshot reads live state independently of the save writer and
compares individual buildings, citizens, inventories, larders, meal schedules,
construction deliveries, field layouts, terrain edits, wear texels, resource
history and clock state. Quantities compare exactly; positions allow only
0.1 mm of transform noise. It then checks that the pathfinder still agrees with
the roads and that the reloaded settlement completes a newly ordered building.

**Layer 5 — Settlement growth.** Housing, food production with a growth and
harvest cycle, consumption and famine, and immigration: settlers evaluate the
kingdom's spare housing, food security and available work, then physically walk
in from the map edge.

### Markets, research and the frontier

See the [expansion notes](design/EXPANSION_2026-09-20.md) for the implemented
rules, verification evidence and current scope.

Build a **Market** near homes or an emerging junction. Its two vendors carry
food from actual stores and farms; households fetch from those counters. Select
it to choose a target of 40, 80 or 120 food and inspect the nearby district.
Those journeys wear their own routes into the terrain.

Open **Research** on the bottom bar after completing a market. Studies cost
materials and simulation days. Roadworks unlocks commissioned routes; Paving
unlocks the final surface. Civic building and Metallurgy unlock building
expansions, and Fortification lets supply huts become forts. Construction costs
still apply after research. Natural traffic makes dirt tracks; improved and
paved surfaces require investment.

Select worn ground to compare **Busiest route**, **Main routes** and **Entire
connected network**. The highlighted cells are the quoted work. Prices scale
with the actual area being improved; the smaller choices cover approximately
20% and 50% of the connected network. Already improved ground is not charged
again.

To try combat:

1. Build a **Barracks**, then open **Army** and recruit swordsmen for 5 tools
   and up to 10 food each. Each recruit is an existing citizen: recruiting 10
   of 20 residents leaves 10 workers and 10 soldiers. Recruiting everyone stops
   production, including food hauling. Discharged veterans keep their injuries.
2. Build stocked **Supply huts** toward the rival town. Each relay needs an
   upstream food source within 160 m and workers to carry it. Soldiers refill
   their four-day packs within 24 m of a supply point. Empty packs slow them
   down and eventually cost lives.
3. Choose **Muster all swordsmen**, then right-click ground to march. Use
   **Find the rival town** to locate Ashcombe, then right-click an enemy guard
   or building to attack. Individual soldiers can also be selected.
4. Soldiers fight with swords and throw burning pots at buildings. Buildings
   scorch, catch fire and collapse; there are no health bars. Research
   Fortification to upgrade a supply hut into a more durable fort.

For a quick combat preview, open developer mode with `F3`, grant materials
with `F6`, place a barracks and finish it with `F5`. Then use Army to recruit,
muster and find the rival. Normal play earns those materials through production.

Ashcombe has its own growers, food stores and guards. Its randomly assigned
personality is **aggressive**, **peaceful** or **loner**. `F3` reveals the
personality and lets developers change it immediately. Aggressive rivals can
raid military infrastructure after a grace period once you recruit a force;
other personalities govern defensive behavior. This is one combat scenario,
not diplomacy, siege engineering or a complete military campaign.

Soldiers have location-based wounds rather than visible health bars. Severe
unarmored slashes can sever limbs; losing the sword arm disables sword attacks,
and leg injuries slow movement. Armor protects the locations it covers. Plate
includes mail beneath it, so a moderate stab may cause bruising instead of a
penetrating wound. Injuries persist through discharge, reenlistment and saves.

Build a **Cattle Ranch**, use **Wild cattle** to find a herd, and select a cow to
send a rancher. The worker must reach it and lead it home. That first successful
domestication discovers **Ranching**, which still needs paid research. Staffed
ranches breed cattle and slaughter surplus adults for food and hides. Research
**Leatherworking** and build a **Tannery** to turn hides and timber into leather.
Then research **Mail armor** and **Plate armor** for stronger equipment.
Select a soldier near a completed barracks to pay for and fit an unlocked suit.
See [citizens, cattle and armor](design/SOCIETY_2026-09-20.md) for exact rules.

Hover stone or iron to see the resource and remaining amount; click for details.
Iron has dark metallic rock with rusty veins. Saves include research, market
policies, rival personality, military orders, rations, building damage, fires,
cattle, armor and permanent wounds. Older five-resource inventories migrate to
the expanded resource layout with zero hides and leather.
Older speed indices migrate to the new menu; retired fractional rates become 1×.

### Not yet built

Rail, regional administration, diplomacy, multiple rival kingdoms, cavalry,
formations and a campaign victory structure remain outside this slice.

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
        |                     attachment points
        v
assets/generated/*.glb        + a .json manifest per asset
        |
   validate_assets.py         bounds, height, origin, materials, triangles,
        |                     LOD chain, attachments, structure
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

Exports contain visual meshes and attachment nodes. Building selection uses a
box made at runtime from the manifest's footprint and height; terrain picking
uses the heightmap. The pipeline no longer generates unused collision meshes.

`assets/specs/style.yaml` is the machine-readable form of the art direction in
§4.2 — one scale, one forward axis, one origin rule, a material library of
twenty shared materials with a cap of seven per asset, per-category triangle
budgets, and the attachment points the game reads by name (`att_entrance`,
`att_cart_bay`, `att_worksite`, `att_smoke`, `att_stock_*`). The validator
enforces the material library, budgets and export contract. Some style rules
remain guidance: `origin.tolerance_m` is declared as 0.02 m, but the enforced
horizontal limit is 35% of the footprint, with a warning past 12%.

The validator reads the live spec and decodes the exported `.glb` vertex and
index buffers. It checks buffer extents, offsets, strides, finite values and
indices, verifies accessor bounds against the bytes, and measures rendered
triangles. Materials come from the visual meshes' primitives. It compares bounds against
the manifest within 2 cm and `height_m` within 5 mm. Every declared LOD's
triangle count must match exactly; buildings, props, vegetation and resource
nodes must export all three nonempty levels, with nonincreasing counts. Authored
detail tiers must retain at least 25% of LOD0's triangles at LOD1. Tightening a
budget or a material cap in `style.yaml` fails assets produced under the old
limit.

Mesh and attachment names must match the manifest in both directions.
Attachment coordinates must match their exported nodes within 1 mm after the
Blender-to-Godot axis conversion, and must lie near the asset's bounds. The
validator requires a root at the origin, unique node names and direct children,
with unit scale and no rotation; each child's translation is included in the
measurements. It also checks asset IDs and category folders against the paths
the game's registry loads. Degenerate or duplicate faces and inconsistent
winding along edges shared by exactly two geometric faces fail validation.
The spec explicitly allows boundary edges and junctions where assembled kit
pieces meet; their counts are checked against those allowances. This is an
assembled-surface contract, not a requirement for one watertight solid.
Unsupported sparse, compressed, morphed or skinned geometry is rejected.

```
$ tools/build.sh validate
=== 28 passed, 0 failed, 0 with warnings ===
```

---

## Verifying it actually works

Run the complete Linux verification gate with one command:

```bash
tools/build.sh test
```

It validates the committed assets, syncs and imports them, runs Python and Godot
regressions, exercises ten gameplay scenarios, 90-day established settlements
and 120-day paid bootstraps across three seeds, then compiles shaders and checks
picking/UI under Xvfb. Focused checks cover market deliveries, researched road
quotes, supply relays, combat, campaign saves and the expansion's controls.
The trade checks cover all map sizes, finite barter, physical recovery, paid
crossings, a merchant's complete bridge journey, and saves taken mid-crossing.
Rendered checks click through the new controls at several window sizes. Godot,
Python 3, rsync, Xvfb, xauth and Mesa are required; Blender is only needed when
regenerating assets. Set `GODOT=/path/to/godot` to choose an engine explicitly.

Every stage has a timeout and retains its complete log. Tests must reach their
success marker and have no unexpected engine errors; Godot exiting zero alone
does not pass. Expected decoder diagnostics are narrowly allowed only in the
malformed-save tests. Summaries and logs land in timestamped directories under
`artifacts/verification/`, and test saves use a separate directory under
`.godot-home/verification/`.

For an explicitly partial local check, use `tools/build.sh test --headless`
to omit graphics tests or `--skip-long-run` to omit endurance runs. The
[GitHub Actions workflow](.github/workflows/verify.yml) runs the full command on
pushes, pull requests, manual dispatches and weekly, with
[Godot 4.7.2](https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable)
pinned by version and download checksum. It uploads logs and screenshots even
when a check fails.

The simulation is checked by driving real play sessions, not by unit-testing
the pieces in isolation. `tools/scenes/*.json` are scripted scenarios executed
by an in-game harness that can place buildings, run the clock for in-game days,
assert on world state, and photograph the result.

```bash
tools/build.sh harness tools/scenes/first_road.json
```

For fast simulation checks without rendering, add `--headless --fixed-fps 60`.
The fixed timestep lets scenarios with `run` steps advance without pacing them
in real time. Screen-space scenarios still require a real or virtual display.

Focused regressions exercise overnight gathering, expired resource jobs,
pause/resume, malformed-save rejection, preservation of saved state, and
navigation around blocked destinations and changing building footprints:

```bash
tools/godot_env.sh --headless --path game --script res://tests/regressions.gd
tools/godot_env.sh --headless --path game --script res://tests/save_validation.gd
tools/godot_env.sh --headless --path game --script res://tests/save_fingerprint.gd
tools/godot_env.sh --headless --path game --script res://tests/navigation.gd
tools/godot_env.sh --headless --path game --script res://tests/production.gd
tools/godot_env.sh --headless --path game --script res://tests/long_run.gd
tools/godot_env.sh --headless --path game --script res://tests/bootstrap.gd
```

The validation runner checks that rejected loads preserve the current march
and controls. Its object-bearing fixture deliberately triggers Godot decoder
errors, marked as expected in the output; the final failure count must be zero.
The fingerprint runner also changes individual values to prove the comparisons
detect missing food, meal history, deliveries and terrain edits.

The endurance test runs 90 days on seeds `20260911`, `1776` and `42`, records
economy metrics, and checks inventory, reservations and construction recovery.
For a shorter diagnostic, append `-- --long-seed=42 --long-days=12` to its command.
The paid bootstrap starts with the ordinary opening settlement and builds its
farms, quarry, mine, smith and forge using real deliveries. It follows the tools
chain for 120 days, replacing depleted mines through normal construction.
Use `-- --bootstrap-seed=42 --bootstrap-days=60` for a shorter diagnostic.
See the [production and balance follow-up](design/BALANCE_2026-09-18.md) and
[earlier verification report](design/VERIFICATION_2026-09-18.md) for the fixes,
before/after observations and test limitations.

`first_road.json` is the §34 definition of done, executable:

```
PASS wear_above 100 (peak 1373)
PASS road_level_at_least Footpath (reached Dirt track)
PASS Timber >= 60 (have 156)
PASS population 24 >= 22 (4 settled since day one)
upgraded route at (375, 395): Dirt track -> Improved road
PASS navigation weights match the ground (26041 walkable cells, 468 of them road)
PASS road_level_at_least Dirt track (reached Improved road)
ALL CHECKS PASSED
```

That `nav_matches_roads` line exists because an adversarial review found the
scenario passing with the feature broken: paying to upgrade a route was
changing how the ground looked without ever reweighting the pathfinder, and
every assertion still went green. Asserting on the road's *appearance* was
never enough; the test now asserts on the graph the citizens actually use, and
fails if the defect is reintroduced.

A second review found the check itself passing by accident. It only looked at
road cells, and a road cell is repriced whenever its level moves — so the one
kind of cell it inspected was the one kind that healed itself. The cells that
stayed wrong were the quiet ones ringing each building pad, where the ground is
flattened wider than the footprint the placement refreshes. It now sweeps every
walkable cell, and the road-level comparison is what keeps it honest about
there being roads to check at all.

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

* **Geometry checks do not establish visual quality.** Vertex/index buffers
  and triangle topology are validated, with explicit allowances for open and
  intersecting assembled surfaces. Self-intersections and watertight volume
  are not checked. The silhouette warning compares rounded bounding-box
  dimensions, so visual quality still needs preview inspection.
* **Footprints and origins have broad tolerances.** The spec's 2 cm origin
  tolerance is not enforced globally. The granary footprint and the keep/cart
  origins have been corrected in their generators; the current set passes
  without warnings.
* **Long-run balance needs more playtesting.** The gate covers three 90-day
  established settlements and three 120-day paid openings through the forge.
  Full stores now stop new gathering before workers collect excess cargo.
  Occasional remote meals still run late, and ore remains finite; the industry
  test measures paid mine replacement and tool reserves after exhaustion.
  These fixtures cover one opening strategy, not every player layout.
* **Combat is an initial encounter.** The rival produces food and commands
  guards, but does not build out its town or negotiate. Military balance needs
  player feedback beyond the automated food, combat and save checks.
* **Trade is one finite barter scenario.** The neighbor begins with 32 iron;
  it does not replenish an export industry. Repeating trips stop when stock
  runs out. There are no negotiated prices, multiple civilizations, scouting,
  automatic escorts or caravan waypoints yet.
* **Extra large needs long-session playtesting.** Its geography, distant
  routes, wear updates and saves are tested. Generation takes tens of seconds,
  and crossing the whole region is a long journey. The opening neighbor stays
  near home; larger maps do not currently add more towns.
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

These are historical small-map measurements. The newer world implementation
uploads touched terrain tiles; see [current scale measurements](design/TRADE_2026-09-21.md#measured-scale-and-limits).
In the earlier implementation, the texel
figure counts entries rewritten in the CPU-side pixel buffer, not a partial GPU
upload — `ImageTexture.update()` submitted the whole 384×384 image, and the
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
