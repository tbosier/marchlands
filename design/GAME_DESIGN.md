# Marchlands
## Starter Game Design & Technical Direction

Current base-game priorities are recorded in [Base game direction](BASE_GAME_DIRECTION.md):
finite-population caravans, geographic trade routes, selectable worlds and timber bridges.
That document is a proposal; this broader design remains the long-term roadmap.

**Genre:** 3D real-time kingdom builder / logistics strategy / light grand strategy  
**Perspective:** Fully 3D, elevated free camera, continuous world  
**Simulation:** Real-time with pause and speed controls  
**Core fantasy:** Begin with a small keep and a few settlers, then grow an organic kingdom whose roads, towns, logistics networks, institutions, and military power emerge from how people actually live and move through the world.

---

# 1. High-Level Pitch

**Marchlands** is a 3D kingdom-building strategy game where the player chooses where settlements, farms, mines, workshops, depots, forts, railways, and civic buildings are constructed, but does **not** manually paint the basic transportation network.

People initially walk directly across the landscape using terrain-aware pathfinding. Frequently traveled routes become worn paths. Paths become dirt roads. Important roads can be upgraded into improved roads, paved highways, and eventually supplemented by rail.

The kingdom therefore leaves a visible physical history on the map.

A trail from the original keep to a nearby quarry may become the main commercial street of a city several hours later. A military supply road may become the spine of a frontier settlement. A rail line may eventually parallel a path first created by six woodcutters at the beginning of the game.

The central problem is not producing millions of increasingly abstract materials.

The central problem is:

> **How do I organize people, resources, geography, transportation, institutions, and military force into a functioning kingdom?**

---

# 2. Design Pillars

## 2.1 The World Remembers Movement

Infrastructure should emerge from actual behavior.

- Citizens walk across terrain.
- Carts seek efficient routes.
- Soldiers prefer roads.
- Heavy traffic wears paths into the landscape.
- Players improve successful routes rather than drawing every road in advance.
- Settlements naturally form around useful transportation corridors.

The map should visibly record the history of the player's kingdom.

---

## 2.2 The Player Places Buildings

Buildings are **deliberately placed by the player**.

The player should be able to say:

- Put the bakery here.
- Put the blacksmith beside the market.
- Put the warehouse beside the railway.
- Put houses along this street.
- Put the castle on this hill.
- Put the fort at this mountain pass.

This is important for attachment, aesthetics, defense, and logistics.

The game should not automatically generate entire towns in a way that removes player authorship.

However, citizens may create small non-critical objects organically:

- fences
- footpaths
- gardens
- carts
- market stalls
- wood piles
- clotheslines
- temporary camps
- roadside shrines
- informal gathering areas

The player controls **meaningful permanent structures**.  
The simulation fills in the visual life around them.

---

## 2.3 Distance Is the Main Economic Enemy

Do not create Factorio-style exponential production scaling.

Production chains should remain understandable.

Example:

```text
Iron Ore -> Iron
Iron + Wood -> Tools
Iron + Wood -> Weapons
Iron + Coal -> Steel
Steel + Timber -> Railway
```

Difficulty should arise because:

- resources are geographically dispersed
- workers need to reach jobs
- food must reach towns
- armies must be supplied
- wagons have limited throughput
- bridges become strategic
- mountain passes matter
- bad roads slow the economy
- winter or weather can disrupt movement
- enemies can attack logistics

The late game should increase **organizational complexity**, not require 400,000 iron plates per minute.

---

## 2.4 Institutions Automate the Kingdom

Automation should come from civilization becoming more sophisticated.

Early game:

- player assigns workers
- player assigns carts
- player chooses storage priorities
- player handles simple logistics manually

Later:

### Logistics Office

Allows rules such as:

```text
Maintain at least 200 grain in every town.
Send excess stone to the capital.
Prioritize food deliveries during shortages.
```

### Quartermaster

Allows:

```text
Keep Fort Greywatch supplied with:
- 60 days food
- 30 days ammunition
- 20 medical supplies
```

### Railway Bureau

Allows automatic freight scheduling based on supply and demand.

### Provincial Administration

Allows local governors to manage lower-priority needs according to player policy.

Automation should make the player feel like they are becoming a ruler rather than becoming a better mouse operator.

---

## 2.5 Civilian Infrastructure Is Military Infrastructure

Roads, warehouses, bridges, ports, depots, farms, and railways determine military power.

A large army without supplies should fail.

An army tracks:

```text
Army of the North
Soldiers: 1,840
Food: 24 days
Ammunition: 71%
Medical Supply: 63%
Morale: High
Fatigue: Low
```

Armies automatically draw supplies from the player's logistics network.

The player's strategic task is creating and defending that network.

Destroying one bridge may matter more than killing fifty soldiers.

---

# 3. Presentation

## 3.1 Fully 3D

The game should be fully 3D.

A top-down-only presentation would lose too much of the charm of:

- watching citizens physically travel
- seeing carts climb roads
- watching towns grow around the keep
- trains moving through valleys
- armies marching in formation
- bridges crossing rivers
- seeing the castle dominate the skyline
- observing seasons and weather
- recognizing individual buildings from a distance

The game should feel like a miniature living kingdom rather than a diagram.

---

## 3.2 Camera

Use an elevated free camera similar to a city builder / RTS.

Required controls:

- WASD pan
- mouse-edge pan optional
- mouse wheel zoom
- middle mouse rotate
- tilt camera
- focus selected object
- jump to alerts
- pause
- 1x
- 2x
- 4x
- optional 8x during peace

Recommended camera limits:

- close enough to inspect individual citizens
- far enough to see an entire town
- strategic zoom should remain in the same physical world

Avoid switching to a separate "world map."

The kingdom should always exist in one continuous space.

---

# 4. Visual Direction

## 4.1 Art Style

Initial target:

**Stylized low-to-mid-poly 3D with readable silhouettes and strong materials.**

Not voxel.

Not ultra-realistic.

Not cartoonishly exaggerated.

Think:

- handcrafted miniature terrain
- believable architecture
- warm lighting
- readable resource buildings
- visually distinct towns
- simple enough geometry for automated asset creation

A stylized visual language makes AI-generated Blender assets much easier to keep consistent.

---

## 4.2 Asset Constraints

Every generated asset should obey a shared style specification.

Example:

```text
Scale:
1 Blender unit = 1 meter

Architecture:
- grounded medieval / early industrial
- timber, stone, brick, iron
- no fantasy ornament unless explicitly requested

Geometry:
- clean topology
- low-to-mid poly
- strong silhouette
- modular where practical

Materials:
- small reusable material library
- wood
- stone
- plaster
- brick
- iron
- roof tile
- thatch
- glass

Performance:
- LOD-ready
- collision mesh
- origin correctly positioned
- consistent forward direction
```

This style guide should become machine-readable so agents can generate assets consistently.

---

# 5. AI-Generated Asset Pipeline

The development process should assume agents can directly operate Blender.

Do **not** depend on manually hunting asset stores for every object.

The workflow should be:

```text
Game requirement
      |
      v
Asset specification
      |
      v
Agent generates Blender Python / Blender operations
      |
      v
.blend asset
      |
      v
Automated validation
      |
      +-- scale
      +-- topology
      +-- triangle count
      +-- materials
      +-- collision
      +-- pivots
      +-- naming
      +-- UVs
      |
      v
Export GLB/FBX
      |
      v
Import into game
```

---

## 5.1 Asset Specification Example

```yaml
asset_id: building_blacksmith_tier1
category: building
footprint:
  width_m: 8
  depth_m: 10

style:
  period: late_medieval
  wealth: modest
  region: temperate_european

required_features:
  - stone furnace
  - chimney
  - timber frame
  - covered exterior work area
  - visible wood pile

materials:
  - timber_dark
  - plaster_warm
  - stone_grey
  - roof_tile_red

lod:
  - lod0
  - lod1
  - lod2

collision:
  type: simplified_mesh
```

Agents should consume specifications like this and produce Blender assets.

---

## 5.2 Blender Automation

Prefer scripted generation wherever practical.

Agents should be able to:

- create geometry
- assign materials
- generate UVs
- create LOD variants
- produce collision geometry
- place attachment points
- render preview images
- export assets
- modify existing assets
- generate variations

Buildings can initially be generated from modular components:

```text
walls/
roofs/
doors/
windows/
chimneys/
supports/
awnings/
stairs/
foundations/
props/
```

The agent can assemble them procedurally while retaining a consistent art style.

---

## 5.3 Asset Review Loop

Generated assets should not automatically enter production.

Run automated checks.

Example:

```text
PASS: dimensions valid
PASS: origin at foundation center
PASS: material count <= 6
PASS: collision present
PASS: triangle budget
PASS: no non-manifold geometry
WARN: roof silhouette too similar to bakery
```

Then render a standardized turntable preview.

A human or reviewing agent can approve or regenerate it.

---

# 6. Building System

## 6.1 Placement

Buildings are player placed.

Placement should be satisfying.

When placing a structure, display:

- footprint
- terrain slope
- entrance direction
- road/path accessibility
- resource accessibility
- desirability effects if applicable
- construction cost
- expected travel time for workers
- storage connections

Buildings should naturally flatten or adapt modest terrain.

Do not force everything onto a rigid grid.

Use free placement with sensible snapping.

Possible snapping:

- nearby buildings
- cardinal alignment
- road frontage
- walls
- rail
- shoreline
- resource deposits

Allow rotation.

---

## 6.2 Entrances Matter

Buildings should have explicit access points.

Example blacksmith:

```text
[ Workshop ]
     |
 Entrance
     |
   Path
```

Citizens path to entrances rather than teleporting into building footprints.

Warehouses may have multiple logistics points:

- worker entrance
- cart loading bay
- rail loading point

This creates meaningful town layouts without requiring artificial adjacency bonuses everywhere.

---

## 6.3 Construction Is Physical

When a building is ordered:

1. Player places blueprint.
2. Surveyor / builder marks site.
3. Required materials are delivered.
4. Workers physically construct it.
5. Building becomes operational.

Example:

```text
Blacksmith
Timber: 28 / 40
Stone: 60 / 60
Iron: 8 / 10
Construction: 32%
```

Building speed should depend partly on actual logistics.

---

## 6.4 Building Upgrades

Avoid replacing buildings constantly.

Prefer visible upgrades.

Example:

```text
Small Granary
    ->
Expanded Granary
    ->
Regional Grain Warehouse
```

The building physically changes.

Likewise:

```text
Village Smithy
    ->
Blacksmith
    ->
Industrial Forge
```

This helps preserve the visible history of the settlement.

---

# 7. Roads

## 7.1 Emergent Path Creation

Terrain stores a traffic value.

Example conceptual value:

```text
traffic[x, y]
```

Each moving entity contributes wear.

Example:

```text
pedestrian = 1
horse = 2
cart = 5
military column = 8
heavy wagon = 10
```

Terrain transitions at thresholds.

Example:

```text
0-99       natural terrain
100-499    worn grass
500-1999   footpath
2000+      dirt track
```

Exact numbers require balancing.

---

## 7.2 Route Reinforcement

Pathfinding cost should depend on both:

- physical distance
- terrain speed

Once a path appears, future travelers prefer it.

That naturally reinforces useful routes.

Example movement modifiers:

| Terrain | Speed |
|---|---:|
| mud | 0.45x |
| dense forest | 0.60x |
| grass | 1.00x |
| worn path | 1.10x |
| dirt road | 1.35x |
| improved dirt road | 1.55x |
| paved road | 1.85x |

Values are placeholders.

---

## 7.3 Player Road Intervention

The player should be able to interact with emergent routes.

Commands:

```text
Upgrade Route
Improve Drainage
Widen Road
Pave Road
Build Bridge
Mark Preferred Route
Restrict Civilian Traffic
Military Priority
Close Route
```

The player may also be allowed to commission a completely new road where no path exists.

However, this should be expensive.

Organic routes should usually be cheaper because they have already demonstrated utility.

---

# 8. Railways

Rail is a late-game transportation revolution.

Rail should not behave like Factorio conveyor belts.

A railway exists to connect regions.

Core components:

- track
- stations
- freight terminals
- passenger stations
- locomotives
- wagons
- signals
- depots

---

## 8.1 Logistics Model

Stations expose supply and demand.

Example:

```text
North Iron Station
Exports:
- Iron Ore

Imports:
- Food
- Tools
```

```text
Capital Freight Station
Imports:
- Iron Ore
- Coal
- Grain

Exports:
- Tools
- Machinery
- Weapons
```

The Railway Bureau can automatically create schedules according to demand.

Advanced players can manually create routes.

---

# 9. Population

## 9.1 No "Spawn Villager" Button

People should be part of the world.

Population comes from:

- births
- immigration
- refugees
- annexation
- conquered settlements
- recruited specialists
- population transfers
- prisoner integration

Citizens physically arrive.

A migrant group can be seen crossing the world.

---

## 9.2 Immigration

People should evaluate kingdoms according to factors such as:

```text
food security
housing
wages
safety
freedom
tax burden
war
reputation
religion/culture if modeled
family connections
employment
land availability
```

Example event:

```text
17 settlers from Westmere are traveling toward your kingdom.

Reason:
- high wages
- available farmland
- regional war
```

They physically travel to the settlement.

They can be:

- attacked
- robbed
- escorted
- diverted
- refused entry

---

## 9.3 Population Agency

Citizens should have professions and households without becoming RimWorld-level individual micromanagement.

Possible level of detail:

```text
Name
Age
Household
Profession
Home
Workplace
Health
Morale
Culture
Skills
```

The simulation may internally track more, but the player should generally manage groups and institutions.

---

# 10. Coercion, Prisoners, and Slavery

If the game permits morally bad strategies, they must have systemic consequences.

Potential prisoner policies:

```text
Release
Ransom
Exchange
Integrate
Conscript
Imprison
Forced Labor
```

Forced labor provides immediate labor but creates costs:

- guards required
- escape attempts
- sabotage
- rebellion
- international hostility
- reduced voluntary immigration
- local resentment
- administrative burden
- lower productivity
- radicalization

It should be a viable strategic choice in some circumstances without becoming an obvious optimization.

A coercive empire should require substantial resources merely to remain coercive.

---

# 11. Economy

## 11.1 Core Resources

Start small.

Possible early resources:

```text
Food
Timber
Stone
Iron
Coal
Tools
Weapons
Cloth
```

Later:

```text
Steel
Machinery
Ammunition
Medicine
Rail Components
```

Avoid dozens of intermediate materials unless they produce meaningful gameplay.

---

## 11.2 Local Inventories

Resources should physically exist somewhere.

Example:

```text
Capital Warehouse
Grain: 942
Timber: 230
Iron: 84
Tools: 61
```

No magical global inventory.

This makes logistics meaningful.

---

## 11.3 Markets

Settlements may have internal markets.

Producers deliver goods.

Households consume them.

The player can influence:

- taxes
- prices
- rationing
- exports
- strategic reserves

The initial implementation can abstract money heavily.

---

# 12. Food

Food should be a major driver of settlement geography.

Farm types might include:

- grain
- vegetables
- livestock
- orchards

Workers physically travel to farms.

Harvests are seasonal.

Food must be:

- harvested
- transported
- stored
- distributed

Granaries matter.

A prosperous kingdom should accumulate reserves.

War may disrupt planting or harvest.

---

# 13. Military

## 13.1 Units

Military control should sit between Total War and city-builder abstraction.

Player creates formations such as:

```text
1st Infantry Company
2nd Pike Company
Royal Cavalry
Field Artillery Battery
```

Individual soldiers exist visually but are commanded as formations.

---

## 13.2 Movement

Military movement strongly depends on infrastructure.

Example:

```text
Paved Royal Road:
march speed 1.5x

Grass:
1.0x

Forest:
0.6x

Mud:
0.4x
```

Armies traveling off-road should also create temporary military tracks.

Repeated campaigns can literally create roads.

---

## 13.3 Supply

Armies consume:

- food
- ammunition
- medical supplies
- replacement equipment

Supply automatically travels through:

```text
Capital
   ->
Regional Warehouse
   ->
Military Depot
   ->
Supply Wagon
   ->
Army
```

The player controls priorities and infrastructure rather than individual bread loaves.

---

## 13.4 Foraging

Armies can forage.

Advantages:

- reduced supply burden

Costs:

- damages local economy
- consumes civilian food
- harms loyalty
- slows army
- may create famine

Enemy armies may devastate your agricultural regions simply by existing there.

---

# 14. Diplomacy and Rival Kingdoms

Other factions should participate in the same underlying simulation.

They:

- build settlements
- gather resources
- form roads
- trade
- recruit populations
- construct armies
- expand
- negotiate
- fight

Ideally their roads are also generated by movement.

The player should be able to discover rival infrastructure through scouts.

Seeing a newly paved foreign road near your border should itself be meaningful intelligence.

---

# 15. World

## 15.1 Continuous World

No separate strategic layer.

The world contains:

- rivers
- forests
- hills
- mountains
- plains
- marshes
- coastline
- resource deposits
- villages
- ruins
- rival settlements

Everything exists in one continuous 3D scene / streamed world.

---

## 15.2 Fog of War

The player knows:

- explored terrain
- last-known enemy information
- current visible information

Scouts and towers matter.

Trade may reveal foreign regions.

---

# 16. Technology

Avoid rigid Civilization-style eras.

The technological range should roughly span:

**late medieval to early industrial**

Possible progression:

```text
Agrarian
    ->
Mercantile
    ->
Proto-Industrial
    ->
Industrial
```

Technologies unlock capabilities rather than arbitrary stat bonuses.

Examples:

```text
Stone Masonry
Improved Plows
Water Power
Printing
Advanced Metallurgy
Steam Power
Railways
Telegraph
Modern Artillery
```

Stop before modern mechanized warfare.

No tanks required.

No airplanes required.

No computers required.

The final world can aesthetically resemble roughly the late 19th century while retaining older infrastructure.

---

# 17. Research

Research should emerge from institutions and expertise.

Structures:

```text
Monastery / Archive
University
Engineering Academy
Military Academy
Industrial Laboratory
```

Potential requirements:

```text
Steam Power requires:
- Engineering Academy
- metallurgy knowledge
- functioning ironworks
- qualified engineer
```

Experts can immigrate.

Example:

```text
Elena Voss
Mechanical Engineer

Interested in immigrating because:
- high industrial investment
- strong wages
- political stability
```

Experts may also be recruited abroad.

---

# 18. Victory / Campaign Objective

The campaign fantasy is:

> **Turn one frontier keep into the dominant power of the region.**

Potential victory structure:

The map contains several recognized sovereign powers represented by **Crowns**.

To become High King / dominant sovereign, control enough Crowns through:

- conquest
- vassalization
- federation
- dynastic union
- diplomatic submission

Economic or prestige conditions could provide alternate victories later.

Do not force every game to end in extermination.

---

# 19. Simulation Architecture

The first prototype does not need every system.

Build the simulation in layers.

---

## Layer 1 — World

Implement:

- 3D terrain
- navigation
- camera
- selectable units
- resource nodes
- building placement

---

## Layer 2 — Citizens

Implement:

- citizen agents
- home
- workplace
- task assignment
- walking
- carrying resource
- basic needs

---

## Layer 3 — Logistics

Implement:

- stockpiles
- warehouses
- hauling jobs
- carts
- distance-aware job selection

---

## Layer 4 — Emergent Roads

Implement:

- terrain traffic accumulation
- visual path appearance
- movement modifiers
- path preference
- road upgrades

This is the first major proof that the game has its own identity.

---

## Layer 5 — Settlement Growth

Implement:

- housing
- food
- immigration
- employment
- happiness / attractiveness

---

## Layer 6 — Military

Implement:

- formations
- movement
- supply
- combat
- forts

---

## Layer 7 — Institutions

Implement:

- logistics automation
- quartermaster
- governors
- policy controls

---

## Layer 8 — Rail

Implement:

- tracks
- locomotives
- stations
- freight
- automatic schedules

---

# 20. Suggested Technical Architecture

Engine choice can remain open initially, but favor an engine that supports:

- large numbers of agents
- navmesh or custom navigation
- terrain deformation / decals
- procedural meshes
- strong scripting
- asset hot reload
- Blender-friendly pipeline

Candidate approaches:

```text
Godot
Unity
Unreal Engine
custom engine only if absolutely necessary
```

For a rapid agent-heavy prototype, prioritize iteration speed over theoretical maximum performance.

---

# 21. Entity Model

Conceptual citizen:

```json
{
  "id": 1042,
  "home": 83,
  "workplace": 29,
  "profession": "woodcutter",
  "position": [122.4, 18.2, 93.1],
  "inventory": {
    "timber": 0
  },
  "current_task": "travel_to_work"
}
```

Conceptual building:

```json
{
  "id": 29,
  "type": "woodcutter_camp",
  "position": [180, 14, 120],
  "entrances": [
    [176, 14, 116]
  ],
  "workers": [1042, 1094, 1112],
  "inventory": {
    "timber": 42
  }
}
```

---

# 22. Task System

Use jobs rather than scripting every citizen directly.

Example job:

```json
{
  "type": "haul",
  "resource": "timber",
  "amount": 20,
  "source": 29,
  "destination": 83,
  "priority": 40
}
```

Available workers evaluate jobs based on:

```text
priority
distance
skill
available carrying capacity
urgency
institution rules
```

This creates systemic behavior.

---

# 23. Pathfinding

This system is critical.

Path cost:

```text
cost =
distance
* terrain_cost
* congestion_cost
* danger_cost
* policy_cost
```

Possible implementation:

- navmesh for traversability
- coarse regional path graph for long trips
- local steering for units
- road/path modifier field

Do not individually run expensive full-map pathfinding for every citizen every frame.

Cache routes.

Group common destinations.

Use hierarchical navigation.

---

# 24. Emergent Road Implementation Prototype

Maintain a terrain-aligned traffic field.

Pseudo-code:

```python
for agent in moving_agents:
    for cell in cells_crossed(agent):
        traffic[cell] += agent.road_wear

for cell in terrain:
    if traffic[cell] > DIRT_ROAD_THRESHOLD:
        terrain_state[cell] = DIRT_ROAD
    elif traffic[cell] > PATH_THRESHOLD:
        terrain_state[cell] = PATH
```

Visual representation can initially use:

- terrain splat masks
- decals
- spline generation after route stabilization

Eventually, stable path clusters can be converted into road splines.

---

# 25. Minimal First Playable

The first real build should include only:

### World

- one map
- hills
- trees
- stone
- iron
- fertile land

### Buildings

- keep
- house
- stockpile
- logging camp
- quarry
- farm
- granary

### Population

- 20 citizens
- immigrants

### Economy

- food
- timber
- stone

### Logistics

- workers carry goods
- stockpiles
- one cart

### Roads

- foot traffic creates visible paths
- paths improve movement speed
- player can upgrade one path into road

### Camera

- full 3D camera
- selectable citizens
- selectable buildings

If this is fun to watch for thirty minutes, continue.

If it is not fun, do not add warfare, diplomacy, or trains yet.

---

# 26. First Prototype Scenario

Player begins with:

```text
1 Keep
4 Houses
1 Stockpile
20 Citizens
200 Food
50 Tools
```

Nearby:

```text
Forest: 150 m east
Stone: 300 m north
Fertile land: south
Iron deposit: 700 m northwest
```

Player actions:

1. Place logging camp.
2. Assign workers.
3. Workers walk toward forest.
4. Repeated travel creates path.
5. Place quarry.
6. Quarry route forms another path.
7. Build farm.
8. Food begins moving toward settlement.
9. Immigration begins.
10. Player upgrades busiest path.

That is enough to validate the core premise.

---

# 27. Immediate Asset List

Generate only what the prototype requires.

## Buildings

```text
keep_tier1
house_small_01
house_small_02
stockpile
logging_camp
quarry
farmhouse
granary
```

## Resources

```text
oak_tree_01
oak_tree_02
pine_tree_01
stone_node_01
iron_node_01
wheat_crop
```

## Props

```text
log_pile
stone_pile
grain_sack
wood_cart
barrel
crate
fence
```

## Characters

```text
citizen_male_base
citizen_female_base
```

Initially use simple shared rigs and randomized clothing.

---

# 28. Asset Generation Repository Layout

Suggested structure:

```text
marchlands/
├── game/
├── simulation/
├── assets/
│   ├── source/
│   │   └── blender/
│   ├── generated/
│   │   ├── buildings/
│   │   ├── props/
│   │   ├── vegetation/
│   │   └── characters/
│   ├── specs/
│   │   ├── buildings/
│   │   ├── props/
│   │   └── materials/
│   └── previews/
├── tools/
│   ├── blender/
│   ├── validators/
│   └── exporters/
├── design/
│   └── GAME_DESIGN.md
└── README.md
```

---

# 29. Blender Agent Tasks

Useful agent commands should resemble:

```text
Generate building_blacksmith_tier1 from asset spec.
```

```text
Create three visual variants of house_small using the existing modular kit.
```

```text
Reduce LOD1 triangle count to 40% of LOD0 while preserving silhouette.
```

```text
Generate collision meshes for all buildings missing them.
```

```text
Render turntable previews of every new asset.
```

```text
Check every building against the Marchlands asset specification.
```

The goal is that asset production itself becomes an automated pipeline.

---

# 30. Development Rule

The project should aggressively use agents for:

- implementation
- tests
- Blender scripting
- asset generation
- shaders
- UI
- balance simulation
- profiling
- documentation
- regression testing

But the game itself should not visually advertise its development process.

No novelty "AI aesthetic."

No unnecessary generative UI.

No meta references.

The final product should simply look like a coherent handcrafted game.

---

# 31. Things to Avoid

Do not drift into:

### Factorio

Avoid huge recipe chains and exponential resource requirements.

### RimWorld

Avoid forcing the player to micromanage every citizen's psychology and bedroom furniture.

### Civilization

Avoid abstract cities existing as single tiles and armies teleporting between strategic representations.

### Total War

Avoid separating city management and battles into unrelated games.

### Kingdoms and Castles

Avoid mandatory manually painted road grids.

### Pure City Painter

The economy and logistics need to matter.

---

# 32. The Signature Screenshot

A successful late-game screenshot might show:

- original stone keep in the center
- dense old town around it
- irregular streets created from ancient paths
- newer paved avenues
- farms beyond the city
- industrial buildings beside river and rail
- freight train entering a station
- smoke from workshops
- fortified hill in the distance
- army marching out on the Royal Road
- villages visible across the valley

Everything in the screenshot should tell the story of how the kingdom developed.

---

# 33. Development Priority

Build in this order:

```text
3D world
    ->
building placement
    ->
citizen movement
    ->
resource hauling
    ->
emergent paths
    ->
road upgrades
    ->
food/population
    ->
carts
    ->
larger settlements
    ->
military logistics
    ->
rival kingdoms
    ->
rail
    ->
deep diplomacy
```

Do **not** start with technology trees, diplomacy trees, or hundreds of buildings.

The first question is:

> Is it enjoyable to place five buildings and watch twenty little people organically create a settlement between them?

If yes, the rest of the game has a foundation.

---

# 34. First Development Goal

**Milestone: "The First Road"**

Definition of done:

1. Player loads into a 3D terrain.
2. Player can freely move and rotate the camera.
3. A keep and stockpile exist.
4. Player places a logging camp.
5. Citizens leave the keep and walk to the logging camp.
6. Citizens chop trees.
7. Citizens carry timber back.
8. Their repeated route visibly wears into the terrain.
9. The worn path provides a movement-speed bonus.
10. The player selects the path and upgrades it into a dirt road.
11. Citizens begin favoring the improved road.

If that moment feels satisfying, proceed.

That is the first vertical slice of **Marchlands**.
