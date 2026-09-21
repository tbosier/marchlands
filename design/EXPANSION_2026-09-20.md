# Markets and the frontier — September 20, 2026

This expansion follows the original game's physical logistics and emergent roads:
the player places destinations, people carry goods between them, and those trips
make the road network. The requested military experiment extends the same idea
with food relays and one rival town.

## Playing the new loop

Build a market near homes. Two vendors carry food from existing stores and farms;
households collect food there. Select the market to choose a stock target of 40,
80 or 120 and inspect its service area. A market does not create food.

After completing a market, open Research. Studies require both materials and
time; only one runs at once. Roadworks permits road commissions, Paving permits
the final road surface, Civic building opens warehouse expansion and advanced
studies, Metallurgy opens the forge, and Fortification opens forts. These studies
do not pay for the subsequent construction.

Select an existing route to preview work on roughly 20%, 50%, or all of its
connected network. The smaller options start at the busiest cell in that
network and follow its strongest traffic. The highlight shows which cells will improve, and the
price scales with their area. Already improved cells are not charged again.
Natural wear tops out at dirt; the better surfaces require paid work.

Build a barracks and open Army. Each swordsman costs five tools and ten food,
drawn from the existing civilian population (see the subsequent
[society expansion](SOCIETY_2026-09-20.md)). Muster selects all friendly units; right-click ground to
move or a rival guard/building to attack. Find the rival town moves the camera
to Ashcombe. Individual units can also be selected and focused with F.

Place supply huts along the march. Each needs workers and an upstream food
source within 160 metres. Quartermasters physically carry the food, and a
soldier within 24 metres can refill a four-day pack. Empty packs slow movement
and eventually kill the soldier. Fortification research lets a hut become a
fort with more food capacity and durability.

Ashcombe has fertile fields, walking growers, finite food stocks and guards.
Its seeded random personality is aggressive, peaceful or loner. F3 displays
the personality and provides an editable dropdown. Aggressive behavior has a
five-day grace period and starts only once the player has an army. Peaceful and
loner personalities differ in their defensive pursuit range.

Units swing swords and throw incendiary pots at buildings. Buildings track
health internally, but show damage through scorching, flames and collapse
instead of health bars. Destruction clears navigation and cancels associated
jobs; destroyed stock is lost. Losing the player's keep pauses play. The fallen
keep remains a valid save state.

## Presentation and persistence

The terrain continues beyond the playable north edge and the water has a bed;
the camera stays above the ground/water surface. Iron has a distinct dark,
rust-veined material. Hovering or selecting deposits identifies the resource
and remaining quantity.

The speed menu is 1×, 2×, 4×, 16×, 32× and 64×, plus pause. Old saved indices
preserve their former rates; retired fractional rates become 1×. Saves retain
research, market targets, damage, fires, rival personality, military orders,
rations and attacks in flight. Missing expansion fields in older saves receive
defaults. Loading validates the new records before replacing the live world.

## Scope

This is a first supplied-army encounter, with a small simulated opponent. It
does not implement diplomacy, an expanding rival economy, multiple opponents,
siege engines, cavalry, or a campaign progression system. The original full
design remains a roadmap rather than a claim that those systems exist.

## Regressions repaired during integration

Payments now use current, unreserved stock and charge all resources atomically.
Road commissions retain the reviewed surface and reject a changed price or
extent before charging. Rapid placement clicks recheck occupancy, and selection
panels safely handle buildings or units destroyed between UI refreshes.

Movement permits citizens spawned inside a building footprint to leave while
retaining corner collision checks on ordinary routes. Food carriers immediately
seek another store after a partial deposit. Construction accepts its final
fractional delivery instead of leaving a site permanently short by less than
half a unit. The paid-opening regression reproduces that last failure with
0.203575 stone still required.

## Verification

Focused regressions include 38 road/research checks, 51 market/logistics checks,
35 production checks, 42 campaign checks, 30 game integration checks and 20 world
presentation checks. Save validation rejects 110 malformed fixtures, and the
independent save fingerprint has 52 checks. The real game loop is exercised at
32× and 64×, including pause and restored resume speed.

The rendered expansion test clicks research, market policies, all road scopes,
commissioning, recruitment, mustering, movement, attacks and the developer
personality dropdown. It renders the restored world before checking shutdown.
Screenshots are written to `artifacts/expansion_ui/`.

The complete gate also runs ten gameplay scenarios, three 90-day settlements,
three 120-day paid openings, shader compilation and the original viewport tests.

**Final result: all 31 stages passed across the full run and its targeted
bootstrap rerun.** The original full run passed 30/31. Seed 42 exposed a scenario
scheduling deadlock: its first iron vein ran out before the planned forge
upgrade, but replacement mines were gated on that upgrade. The scenario now
replaces an exhausted mine independently of the upgrade. No resource gifts,
assertion removals or diagnostic exceptions were added. The corrected standard
bootstrap stage passed all three seeds over 120 days in 220.2 seconds.

Evidence, retaining the original failed result as well as the rerun:

- Full run: `artifacts/verification/20260920-155108-2964383/summary.json`
- Corrected bootstrap: `artifacts/verification/20260920-160209-bootstrap-recheck/summary.json`
- Combined coverage: `artifacts/verification/expansion_final_summary.json`
- Final flame attachment: `artifacts/expansion_soldier_final.log` (17 checks)

The rendered expansion stage passed 70 checks without engine errors, including
the restored personality dropdown. The full 90-day settlement stage passed all
three seeds. All three corrected paid openings completed researched forges,
retained tools at day 120 and reported zero famine days. These are deterministic
regression scenarios, not a claim that every layout or military strategy is
balanced.
