# Marchlands: people, knowledge, and consequences

User direction, September 21, 2026. This is the design north star, not a claim
that every mechanic below is implemented. See STATUS_2026-09-21.md for delivery
and validation evidence.

Marchlands is a medieval settlement simulation and RTS with little or no
fantasy, physical logistics, and lasting human consequences. Its distinguishing
rule is that every expedition, army, and productive job uses actual residents
and actual materials. Roads record their journeys. The ruler knows what those
people have learned, rather than receiving an omniscient view of the map.

## Current implementation slice

Finish the terrain, building-placement, and UI review. Then connect exploration
and combat consequences to the existing citizen, army, caravan, and save systems:

- Fog separates unseen ground, remembered geography, and current observation.
- A scout lodge trains an existing citizen. Training and travel remove that
  person from local work. Food, elapsed travel, and safe return matter.
- A discovered city leaves a dated report: last visit, observed population and
  military estimates, and the source. A scout visiting its castle can obtain
  the ruler's account. Unknown changes never update an old report automatically.
- Merchants observe along established trading journeys, but cannot receive
  exploration orders. Scouts can die; their disappearance must not magically
  disclose who killed them or reveal the destination they never reached.
- Soldiers have persistent body injuries, organs, blood loss, shock, and skills.
  Armor changes penetration. Skills change hit/dodge likelihood, not immunity
  to lethal injury. No floating health bars.
- Field medics are existing soldiers carrying finite supplies. They can control
  bleeding and stabilize fractures; they cannot replace lost limbs or instantly
  restore an incapacitated veteran to full fitness.
- Wells supply drinking and carried firefighting water. Sabotage requires a
  physical scout, supplies, travel, and time at an enemy well. Guards can spot
  and interrupt the attempt. Sighted threats produce player alerts.

These establish the contracts for later systems. They do not promise a complete
medical simulation, sophisticated diplomacy, or all of the following mechanics.

## Consequences to develop next

| System | Player decision | Physical consequence |
| --- | --- | --- |
| Seasonal farming | Draft workers now or finish harvest? | Unharvested food never enters the granary. |
| Convoy raids | Escort a cart or defend the town? | Lost people, animals, and cargo interrupt real production. |
| Wounded evacuation | Commit two fighters to carrying someone? | Both carriers leave the fight while saving a persistent citizen. |
| More field medicine | Bandage, splint, tourniquet, or risky surgery? | Time, supplies, skill, and permanent injury decide the outcome. |
| Weapons and shields | Spears, swords, axes, bows, or crossbows? | Reach, recovery, penetration, and protection suit different ground. |
| Morale and surrender | Continue a losing fight or withdraw? | Witnessed deaths, encirclement, and burning homes can cause flight. |
| Livestock theft | Guard the herd or pursue the raiders? | Stolen animals physically leave with the thieves. |
| Prisoners | Release, ransom, exchange, hold, or recruit? | Captives need food and space; rulers remember treatment. |
| Migration and refugees | Accept new residents despite shortages? | Named people arrive with skills, needs, wounds, and political history. |
| Training policy | Militia, professional core, or civilian economy? | Practice improves skills while taking time away from production. |
| Formations | Hold a bridge, form a spear wall, or spread out? | People must occupy positions; flanks and restricted ground matter. |
| Restrained weather | Campaign in rain, snow, or dry wind? | Mud, visibility, provisions, and fire behavior change. |
| Fortifications | Gate, palisade, tower, or stone wall? | Destruction requires suitable tools; swords cannot cut stone walls. |
| Fire response | Draft everyone or retain a bucket crew? | Wells, water, labor, spacing, and firebreaks limit destruction. |
| Bells and emergency policy | Who shelters and who musters? | Existing civilians change jobs and move to actual destinations. |

Food and industry retain physical chains: farm → cart → granary → market →
people; mine → cart → smithy → equipment; forest → cart → store → construction.
A raid on six wagons or a granary may matter more than winning a pitched battle.
No magical inventory refund, unit queue, or instant replacement population
should erase that consequence.

Names and a small number of learnable skills are enough to make residents
recognizable. Injured veterans can take suitable civilian roles. Training makes
a survivor valuable, but never invulnerable. Losing twelve people from a village
of forty should damage its economy and future, not simply empty a build queue.

## Knowledge is a game system

Enemy population and army numbers need an attributable observation. Reports
should express uncertainty, for example “20–30 armed people, seen 41 days ago.”
A ruler's statement is a source, not a permanent subscription to their census.
Merchants can refresh observations only when they physically arrive. Losing
contact with a scout is an absence of information, not a kill notification that
reveals an unseen attacker. Remembered geography remains useful even when
current military activity is unknown.

## Deliberate boundaries

Keep the initial game legible: a handful of wound consequences, finite medical
supplies, one neighboring town, and useful journeys. Add evacuation and morale
before a large catalogue of diseases. Add functional counterplay to arson before
expanding siege weapons. Well poisoning uses abstract game rules and must have
physical exposure and defensive counterplay. Children,
aging, and generations remain undecided until campaign timescale is settled.
Do not add more building or research tiers merely to create activity.

The test for a new feature is whether it creates a meaningful choice about real
people, material movement, terrain, or imperfect information—and whether its
consequences remain understandable on the map.
