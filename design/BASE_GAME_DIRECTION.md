# Base game direction — September 21, 2026

The expanded [north star](NORTH_STAR.md) records the subsequent direction on
scouting, imperfect information, persistent wounds, and physical consequences.

**Status: direction document; first trade slice implemented September 21.**
See [implementation and limits](TRADE_2026-09-21.md) for what is playable.
This document also describes future work, including scouting, escorts and
additional settlements. It prioritizes a satisfying base game before adding
more upgrade tiers. Existing research systems remain in the prototype.

## The game we are making

Grow a settlement by organizing people and journeys through a difficult,
beautiful landscape. Work, trade and military supply leave visible roads behind.
A town's shape should tell the story of why people went there.

This follows the original design's pillars: movement creates infrastructure,
the player places meaningful structures, distance creates economic difficulty,
and civilian logistics also supports armies. Trade adds a reason to care about
other settlements before fighting them.

The base loop is:

1. Feed and house the starting population; establish local production.
2. Explore a valley and find another settlement with different surpluses.
3. Assign a resident and cart to a real trading journey.
4. Carry goods out and bring useful goods home; repeated trips wear a route.
5. Shorten or support that journey with a bridge, market or supply stop.
6. Decide whether scarce people should farm, trade, explore or serve as soldiers.

The first playable trade scenario needs one other town. Additional civilizations
can follow once that round trip is interesting and reliable.

## Caravans take people

A caravan requires at least one existing citizen as its merchant. This is a
reassignment, not a population fee that deletes the person or generates a new
merchant. The merchant retains their name, home, food needs and identity. A
settlement of 20 people with 10 soldiers and two merchants has eight civilians
available for local work. The UI should show that breakdown.

Each caravan has a physical cart, finite cargo space, packed food and a route.
Escorts use existing soldiers. Cargo and travel provisions share a stated
capacity budget. Conscripting or assigning everyone away stops local production.

Canceling a route orders a safe return; the merchant resumes civilian work on
arrival. Canceling cannot teleport the person, refund goods already exchanged,
or erase a threatened caravan. If a merchant dies, that person is lost. Cargo
should remain recoverable at the incident site where practical.

### First trading rules

Use simple barter to prove the loop, with a clear offer such as “deliver timber,
receive iron.” The amounts are tuning values, not fixed here. Both towns must
have real, unreserved stock. Loading removes goods from the origin's store;
exchange transfers them at the destination; unloading adds imports at home.
No town gets an infinite export supply.

Before departure show cargo, provisions, expected journey time and the offered
exchange. Reserve the receiving town's promised stock for an accepted trip,
release it on cancellation or expiry, and explain changed offers before taking
payment. At arrival recheck the destination, access and reservations; a burned
store or canceled deal must not create goods or lose the merchant's cargo.

Start with one round trip and an optional repeat toggle. Add a home-stock floor
so a repeating food export cannot silently sell the settlement's last meal.
Stop and explain when stock, provisions, permission or a route is missing.

A peaceful neighbor welcomes exchange; a loner offers fewer trades; an aggressive
neighbor may trade while relations permit it. Personality affects decisions,
not the conservation rules. Active war closes normal trading access.

### Caravans make the road

The player chooses a destination and optional stop, not every road cell. The
cart uses a traversable route weighted by slope, forest, water crossings and
existing paths. Its actual passage deposits wear. Nothing draws a finished road
between towns when the trade button is clicked.

A new bridge can attract traffic and make an old trail fade. Markets and supply
stops should become useful junctions. This gives the player authorship over the
network through destination placement.

## Geography creates decisions

Mountains should form ridges with usable passes, forests should form recognizable
stands with clearings, and rivers should flow through connected valleys to a
lake or map outlet. Scattered height noise alone is insufficient.

Place resources so local survival is possible but different regions have useful
surpluses. A timber-rich valley might trade with an iron-rich upland town. A
river detour must be visible and understandable. Every generated starting region
needs food potential, basic construction materials and some route toward the
wider world; map generation should verify these conditions.

Exploration is a strong next base feature: discover routes, herds, deposits and
neighboring settlements. Scouting also reassigns an existing person. Revealing
a pass or a bridge site is a useful reward without another upgrade tree.

## Bridges

A basic timber bridge is a base building, with material and labor costs. Select
opposite banks; preview its span, entrances, cost and any invalid placement.
Both ends need reachable approaches, and the span must obey a clear maximum
length and slope. Do not require road research for this first crossing.

Builders bring materials to a bank. The crossing becomes traversable only when
complete. People and carts then walk on the deck, and ordinary traffic forms
its approaches. Preview the expected detour saved so its value is apparent.

Blocking, demolishing or destroying a bridge invalidates routes immediately.
Travelers already on the deck need an explicit evacuation/fall rule; they must
never become permanently stranded above non-traversable water. New travelers
reroute or wait with a visible explanation. Repair and alternate routes can
come after the first complete crossing works.

## Selectable worlds

Implemented initial presets; the intended feel still needs player testing:

| Preset | Side length | Area relative to current map | Intended feel |
| --- | ---: | ---: | --- |
| Small | 768 m | 1× | One compact valley and neighbor |
| Medium | 1,536 m | 4× | Several districts and a meaningful trade journey |
| Large | 3,072 m | 16× | Distinct valleys, passes and river crossings |
| Extra large | 6,144 m | 64× | A region requiring outposts and long-distance supply |

These four sizes are now available from **World**. Extra large contains
several geographic regions; its performance evidence is recorded in the
implementation report. Every size starts with the same manageable population;
world size controls room and geography rather than immediately spawning huge
numbers of people.

Travel must remain enjoyable. At the current unmodified walking speed, crossing
6,144 metres takes roughly 39 minutes at 1× before terrain and stops. That makes
provisions and outposts important, but early useful trade must be much closer
than the far edge. Fast-forward does not excuse empty travel or poor feedback.

World dimensions are now saved per world. Terrain uses chunks, distant terrain
uses simpler meshes, and wear updates touch active regions. Navigation uses a
native grid with cached reachability queries. Distant settlements may eventually
tick less frequently while preserving people, goods and travel time. Old saves
keep their original size.

## What makes the base feel alive

Prioritize a few consequences of these systems before more production chains:

- **Useful arrivals:** carts visibly unload, trade alerts name what arrived,
  and the market becomes busy on caravan days.
- **Geographic discoveries:** a pass, herd or iron deposit changes a practical
  decision instead of merely adding another map icon.
- **Readable logistics:** explain “waiting for food,” “bridge unfinished” or
  “destination at war,” and show where people and goods are committed.
- **Persistent places:** routes gain roadside activity and a junction develops
  because trips actually converge there. Permanent buildings remain player placed.

Weather, tolls, bandits, boats, diplomacy trees, caravan tiers and additional
armor/road tiers can wait. The base should be enjoyable with one cart, one
neighbor and one worthwhile bridge.

## Implementation order and acceptance

First finish and verify the current citizen, livestock and military foundation.
Then make world size explicit in generation, navigation and saves; keep the
small-map baseline working. Implement one finite-stock trade round trip on that
baseline before expanding to large generated river-and-mountain worlds. Add a
working timber crossing, then validate the complete geographic trade scenario.
Do not expose Extra large until its performance and travel pacing are measured.

The first trade slice is complete when:

- One citizen leaves production, carries a paid load to the neighbor and returns
  with imports; population and every resource are conserved.
- Repeated trips visibly wear a route, and a completed bridge changes the route.
- Missing goods, blocked paths, war and interrupted orders produce clear outcomes.
- Saving during loading, travel, exchange and return cannot duplicate people,
  cargo or reservations.
- The same basic rules work at every offered map size, including distant travel
  and route recovery after a crossing disappears.

The design test is a choice: **is that bridge worth its materials and labor to
bring trade home sooner, and can I spare another resident to use it?**
