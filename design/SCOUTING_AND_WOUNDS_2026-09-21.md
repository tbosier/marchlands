# Scouting, intelligence, wounds and field medicine

Implementation record for the September 21, 2026 slice. This records the playable
systems and their present limits; it does not mark the longer-term design complete.

## Scouting controls and costs

- Build a **Scout Lodge** (24 timber, 8 stone), then use **Scouts → Train a citizen
  scout**, or the lodge's action. Training assigns an existing resident and removes
  that person from civilian production while they serve.
- The scout physically collects eight food and two tools, walks to the lodge, and
  trains for half a simulation day. Tools are consumed at training; food remains a
  finite travel supply and is eaten during service. A previously trained resident
  needs one quarter of the training time on a later assignment.
- Select the trained scout, then **right-click traversable ground** to explore.
  **Visit known castle** sends them to a discovered settlement's keep to ask its
  ruler for a report. **Return to civilian work** recalls them to unload remaining
  supplies before resuming civilian work. Low food also triggers recall.
- Merchants provide observations along their existing trade routes. They cannot
  be ordered to explore. A new game offers no undiscovered rival trade destination.

The person keeps their name, home, personal cargo and veteran body across these
roles. Reserved provisions cannot simultaneously fund a merchant and a scout.
Death removes the person permanently; supplies carried by a lost scout are lost.

## Fog and dated intelligence

Unknown terrain is covered; explored terrain outside current sight is dimmed.
Completed friendly buildings, residents, soldiers, merchants and scouts reveal
their surroundings. Trained scouts have the widest mobile sight radius. Visibility
uses a 32-metre grid and radial distance; mountains and trees do not yet obstruct
line of sight.

Seeing a settlement creates a dated population estimate and a count of troops
actually observed. Reaching its castle and meeting the ruler provides a confirmed
report at that time. The map marker and report panel use stored observations, so
population and military changes elsewhere do not silently update an old report.
Later observations retain the previous ruler report as history. Existing legacy
merchant routes preserve knowledge of their destination without inventing a census.

Enemy actors and effects outside current sight are hidden, including their picking
colliders. Resource and cattle panels clear when those objects leave sight. This is
one rival settlement with a simplified town economy and census; it is not yet a
network of independently simulated cities or an espionage system.

Newly seen troops generate a contact alert at their observed position. Peaceful
neighbors are identified as armed neighbors; entering war produces a hostile
warning. Continuous sight does not repeat notifications, and a 60-second simulation
cooldown limits repeated sightings. Contact state survives saves, and alerts retain
their original observed position when the troops leave sight.

Town guards detect hostile scouts within a 60-metre radial sight range and walk to
intercept them. A peaceful visitor does not provoke an attack, but an approaching
well-sabotage mission does. Contact damage uses the guard's ordinary strike cooldown.
Beyond that sight radius, guards stop following the scout's current position. This
is distance-based detection; terrain and foliage occlusion are not implemented.

## Bodies and combat

Soldiers retain individual damage in sixteen regions: head, neck, chest, abdomen,
upper and lower arms, hands, thighs, lower legs and feet. Cuts, punctures, bruises,
fractures, severed parts, artery damage and selected internal-organ injuries persist.
Armor changes penetration and transmitted impact; vulnerable regions have less
coverage. The existing six-part visual rig remains compatible with older saves.

Blood loss and shock continue with simulation time. A living person may become
incapacitated and unable to fight, walk or work before dying. Serious arterial or
internal bleeding can kill after the original strike. Melee and dodge skills affect
hit chances and improve through use; medicine affects treatment. Skills, blood,
shock, wounds, treatments, armor, medical duty and kits are saved with the body.

Selecting a soldier shows text for skills, blood, shock and injuries, including
affected regions and organs. There are no health bars. Wound marks differ from
actual bandages and splints. The model still uses the established character meshes;
sixteen independently articulated anatomical meshes are not implemented.

Veterans keep their body when discharged, recruited again, assigned as scouts or
sent as merchants. Their condition advances once per simulation tick in each role.
Ordinary residents and service workers still use a simpler injury value until first
recruited; existing damage becomes systemic strain rather than disappearing.

## Field medicine controls and limits

Select a soldier near a completed, reachable barracks and choose **Medic · 2 kits
for 4 tools, 4 food**. Replenishment consumes actual available resources. The same
soldier takes medical duty; no additional citizen is created.

A medic seeks treatable friendly patients within 24 metres, prioritizes
incapacitated patients, walks to within three metres and treats them. Patients may
be active soldiers or veterans serving as civilians, scouts or merchants. Each
effective bandage or splint uses one kit; repeating a completed treatment does not
consume another. A short treatment cooldown limits repeated actions.

Bandages reduce external bleeding; splints support fractured limbs. Treatment does
not restore severed parts, erase organ injury, stop every internal bleed or revive
the dead. Stable living patients slowly recover blood. Surgery, prosthetics, organ
repair, infection and a hospital workflow remain outside this slice.

## Persistence and verification

Legacy version-one bodies migrate without creating new bleeding in old injuries.
New saves include exploration, dated reports, training progress, service identities,
reserved stock and detailed bodies. Validation checks role identity collisions and
combined supply promises before staged restoration replaces the current world.

Focused regressions cover detailed wounds and legacy migration; finite field kits
and full-save treatment state; training, return and death of actual residents;
stale reports; shared merchant/scout stock; and veteran physiology across roles.
These checks complement the broader release gate and visual review; they do not
establish long-session balance or performance on every world size.

## Wells, thirst, firefighting and sabotage

New settlements include a physical well; additional **Wells** cost 12 timber and
20 stone. Each completed well holds up to 80 water and replenishes 40 per day.
Residents, soldiers, merchants, scouts and rival workers lose hydration over time
and physically visit their own settlement's wells to drink. Very low hydration
slows movement; dehydration damages the person. Individual hydration and sickness,
well contents, drinking journeys and active assignments persist in saves.

Fires can summon available civilian bucket carriers automatically, or the player
can request a responder from a burning building's panel. The responder leaves
ordinary work, fetches up to four water from a reachable well, carries a visible
bucket to the fire and spends that water to reduce it. They return to civilian
work afterward. There is no global water wallet or remote instant extinguishing.

With a trained scout selected and an enemy well currently in sight, **Poison enemy
well** assigns sabotage. The scout must collect one tool from a friendly store,
approach the well and remain there for twelve simulation seconds. Nearby guards
intercept the hostile approach even if the rival had been peaceful. An interrupted
attempt recalls the scout with its unused paid kit; success consumes the kit and
contaminates the well for four days. Only people who actually drink contaminated
water acquire sickness; damage is applied to those people over time.

Water replenishment and illness are simplified systems. Wells do not draw from a
simulated underground water table, water is not a general trade resource, and
sabotage has no stealth skill contest or terrain-based concealment. Legacy saves
without wells need a well constructed before their residents become dehydrated.
