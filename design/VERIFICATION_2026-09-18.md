# Remaining-priority fixes — 18 September 2026

This follow-up adds a repeatable verification gate, fixes navigation and meal
deadlocks, checks longer settlements, and validates exported mesh bytes.

## Behavior changes

- A blocked destination resolves to a walkable access point. Arrival checks use
  that point, and unreachable routes cannot report arrival.
- Path smoothing checks every crossed grid cell, including short corner clips
  and exact boundary endpoints. Construction and demolition invalidate cached
  routes and building access points immediately.
- Food and material searches skip disconnected stores. Citizens with blocked
  homes can eat at accessible stores; carried food remains accounted for.
- Urgently hungry citizens carrying undeliverable goods can eat without
  replacing or losing their cargo. Food carriers can consume one carried ration.
- Meal breaks retain loaded delivery jobs and destination claims, then resume
  the route. The integration gate exposed a forge that never received iron
  because eating canceled its deliveries; the unchanged upgrade scenario now
  completes within its original eight-day window.
- Immigration entry points and scattered arrivals must connect to the keep.
- Save fingerprints sum individual snapshots in sorted ID order using scalar
  precision. Rebuilding store registration order no longer produces a false
  mismatch from Float32 accumulation; individual quantities remain exact checks.

## Verification command and CI

Run `tools/build.sh test` from the repository. It validates and imports assets,
runs Python and Godot regressions, ten simulation scenarios, three 90-day
settlements, shader compilation, and two real-viewport input/UI scenarios.
Blender is not needed to test the committed assets.

Every stage has a timeout, preserved output and checked exit status. Test stages
also require a completion marker; unexpected Godot diagnostics fail even when
the engine exits zero. Only the malformed-save fixtures' bounded, known decoder
errors are allowed. Test saves are isolated from interactive saves. Logs and
`summary.json` are written under `artifacts/verification/`.
Timeout and cancellation tests also verify cleanup of detached shader probes
and their display processes, with partial output retained.

`--headless` omits graphics and `--skip-long-run` omits endurance testing; these
are explicitly reported as partial runs. GitHub Actions runs the complete
command on pushes, pull requests, manual dispatches and weekly. Its Godot 4.7.2
download is checksum-pinned, and logs/screenshots are uploaded on failure too.
Hosted execution requires these changes to be pushed; no hosted result is
claimed here.
Harness scenarios seed production jitter and test citizen placement from the world
seed so repeated CI runs exercise the same choices.

## Final local result

The complete command passed **22/22 stages** from a fresh source copy without
Godot import caches or copied runtime assets. The tested implementation and
test files matched the working tree. This was a local Linux run with Godot
4.7.2 and software OpenGL under Xvfb.

| Check | Result |
| --- | --- |
| Python corruption, verifier and cancellation tests | 42 passed |
| Exported assets | 28 passed; 3 existing warnings |
| Simulation regressions | 17 passed |
| Malformed saves | 95 rejected fixtures; zero failures |
| Save fingerprints | 44 passed |
| Navigation and meal/delivery regressions | 45 passed |
| Gameplay scenarios | All 10 passed, including the unchanged forge upgrade |
| Endurance and recovery | 90 days × 3 seeds; zero failures |
| Real-driver shaders, input and narrow-window UI | All passed |

Logs, the aggregate `summary.json`, and the UI screenshot are retained in
`artifacts/verification/20260918-115126-1871189/`. The summary's individual log
paths identify the original clean-copy run under `/tmp`; the copied logs sit
beside the summary in the working tree. `git diff --check`, shell syntax, and
workflow YAML/trigger/pin-shape checks also passed.

## Ninety-day observations

The same deterministic established-settlement fixture was run before and after
the meal/navigation fixes. It starts with two farms, logging and quarry
production, a granary and extra housing, then orders funded houses on days 20
and 50. No balance constants were changed or resources injected during this
economy phase. Separate recovery fixtures intentionally add supplies to test
unfunded sites and create new storage to release stranded cargo.

| Seed | Days with urgent hunger, before → after | Final urgently hungry, before → after | Meals, before → after |
| --- | ---: | ---: | ---: |
| 20260911 | 75 → 4 | 17 → 0 | 4,125 → 5,319 |
| 1776 | 81 → 3 | 19 → 0 | 3,598 → 5,286 |
| 42 | 81 → 2 | 36 → 0 | 3,173 → 5,302 |

All three post-fix settlements reached population 42, completed both funded
houses, and had no stranded immigrants or inventory/reservation failures.
Unfunded construction resumed after materials arrived on every seed. Full-store
carriers ate while retaining 12 timber, then delivered after a stockpile was
built; the recovery fixtures conserved 662 timber including building materials.
Before/final-after logs are `artifacts/long_run.log` and
`artifacts/verification/20260918-115126-1871189/long_run.log`; each contains
JSON `METRIC` records. The final run includes the delivery-preservation fix.

These are established-settlement tests, not evidence that bootstrap costs are
balanced. Storage was saturated on 82–87 of 90 days, occasional meals still ran
late, and starting tools ran out around day 43 without a smithing chain.
Those are useful targets for later balance work.

## Export geometry contract

The validator now decodes vertex and index buffers, validates chunk/buffer/view
extents, offsets and strides, checks finite values and index ranges, compares
accessor bounds to the bytes, and measures rendered vertices and triangles.
Degenerate/duplicate triangles and inconsistent two-face winding fail.

The spec explicitly declares an `assembled_surfaces` policy. Boundaries and
coincident/shared-index junctions are allowed for the existing assembled art;
tightening each allowance rejects violating assets. Unsupported compressed,
sparse, morphed and skinned encodings fail explicitly. Corruption fixtures cover
these rules and malformed JSON structures.

All 28 assets pass. The three existing footprint/origin warnings remain.
Self-intersections, watertight volume and visual silhouette quality are not
established by these checks.
