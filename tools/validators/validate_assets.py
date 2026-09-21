#!/usr/bin/env python3
"""Validate every generated asset against assets/specs/style.yaml.

    python3 tools/validators/validate_assets.py [asset_id ...]

Runs on plain CPython (no Blender) by reading the exported .glb plus the
manifest the generator writes. Emits the PASS/WARN/FAIL report described in
design doc 5.3 and exits non-zero if anything fails.
"""

from __future__ import annotations

import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "blender"))
sys.path.insert(0, HERE)

from marchlands_kit.style import style, material_library  # noqa: E402
from glb_inspect import read_glb, summarise  # noqa: E402

GENERATED = os.path.join(REPO_ROOT, "assets", "generated")


class Report:
    def __init__(self, asset_id: str):
        self.asset_id = asset_id
        self.lines: list[tuple[str, str]] = []

    def check(self, ok: bool, message: str, warn_only: bool = False):
        if ok:
            self.lines.append(("PASS", message))
        else:
            self.lines.append(("WARN" if warn_only else "FAIL", message))
        return ok

    def warn(self, message: str):
        self.lines.append(("WARN", message))

    @property
    def failed(self) -> bool:
        return any(level == "FAIL" for level, _ in self.lines)

    @property
    def warned(self) -> bool:
        return any(level == "WARN" for level, _ in self.lines)

    def render(self, verbose: bool) -> str:
        head = f"{self.asset_id}"
        body = []
        for level, message in self.lines:
            if verbose or level != "PASS":
                body.append(f"    {level}: {message}")
        status = "FAIL" if self.failed else ("WARN" if self.warned else "OK")
        return f"  [{status:>4}] {head}\n" + "\n".join(body) if body else \
            f"  [{status:>4}] {head}"


def check_spec_consistency(spec: dict) -> Report:
    """The spec's own internal agreement, checked once per run.

    `style.yaml` publishes a material library and `materials.yaml` defines one.
    Nothing read the first — the generators go to `materials.yaml` — so the two
    were free to drift, and the published art direction could quietly stop
    describing the materials the assets are actually built from.
    """
    rep = Report("<spec>")
    declared = sorted(spec.get("materials", {}).get("library", []))
    defined = sorted(material_library().keys())
    rep.check(declared == defined,
              f"style.yaml's material library matches materials.yaml "
              f"({len(declared)} declared, {len(defined)} defined)")
    geometry = spec.get("geometry", {})
    rep.check(geometry.get("topology") == "assembled_surfaces",
              "geometry.topology selects the supported assembled_surfaces policy")
    rep.check(geometry.get("ngons_allowed") is False,
              "the exported geometry policy requires triangle primitives")
    for key in ("boundary_edges_allowed", "coincident_junction_edges_allowed",
                "indexed_junction_edges_allowed"):
        rep.check(type(geometry.get(key)) is bool,
                  f"geometry.{key} declares whether assembled seams are allowed")
    missing = sorted(set(defined) - set(declared))
    extra = sorted(set(declared) - set(defined))
    if missing or extra:
        rep.warn(f"only in materials.yaml: {missing}; "
                 f"only in style.yaml: {extra}")
    return rep


def find_manifests(wanted: list[str]) -> list[str]:
    out = []
    for root, dirs, files in os.walk(GENERATED):
        # Sorted, or the report order — and which of a colliding pair of
        # silhouettes gets named as the twin — changes from machine to machine.
        dirs.sort()
        for name in sorted(files):
            if not name.endswith(".json"):
                continue
            asset_id = name[:-5]
            if wanted and asset_id not in wanted:
                continue
            out.append(os.path.join(root, name))
    return sorted(out)


def _visual_nodes(info: dict) -> list[str]:
    """Every mesh node in the file; all of them are geometry the game draws."""
    return list(info["mesh_nodes"])


# The folder each category is written to, and therefore the folder the game's
# registry will look in — `AssetRegistry.FOLDERS` keyed by the manifest's own
# `category`. Kept here rather than imported because the generator's copy
# lives in a Blender-only module.
CATEGORY_FOLDER = {
    "building": "buildings",
    "prop": "props",
    "vegetation": "vegetation",
    "resource_node": "vegetation",
    "character": "characters",
}


def _nonfinite(value, path: str = "") -> list[str]:
    """Every path in a manifest holding a NaN or an infinity.

    JSON has no NaN, but Python's decoder accepts the `NaN` and `Infinity`
    literals, and a NaN silently defeats every comparison made against it:
    `max(abs(a - b) ...)` over a NaN returns the finite value it was compared
    with, so an attachment with one NaN coordinate passed both position checks
    while being nowhere at all.
    """
    if isinstance(value, dict):
        return [p for k, v in value.items()
                for p in _nonfinite(v, f"{path}.{k}" if path else str(k))]
    if isinstance(value, list):
        return [p for i, v in enumerate(value)
                for p in _nonfinite(v, f"{path}[{i}]")]
    if isinstance(value, float) and (value != value or value in (
            float("inf"), float("-inf"))):
        return [path or "<root>"]
    return []


def _combined_bounds(info: dict, names: list[str]):
    """Bounds of lod0 where there is one, else of everything visual.

    Characters export as a hierarchy of limb parts rather than a single mesh,
    so there is no one node to measure; every other asset has a lod0 that is
    the whole silhouette.
    """
    bounds = info["node_bounds"]
    preferred = [n for n in names if n.endswith("_lod0")]
    chosen = preferred or names
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    found = False
    for name in chosen:
        if name not in bounds:
            continue
        found = True
        node_lo, node_hi = bounds[name]
        for axis in range(3):
            lo[axis] = min(lo[axis], node_lo[axis])
            hi[axis] = max(hi[axis], node_hi[axis])
    if not found:
        return None, None
    return lo, hi


def validate(manifest_path: str, spec: dict, silhouettes: dict) -> Report:
    try:
        return _validate(manifest_path, spec, silhouettes)
    except (OSError, ValueError, KeyError, TypeError, IndexError,
            AttributeError, OverflowError, RecursionError, struct.error) as exc:
        # A corrupt asset is a failed validation, not a traceback that prevents
        # the remaining assets from being checked.
        rep = Report(os.path.basename(manifest_path)[:-5])
        rep.check(False, f"invalid manifest or GLB: {exc}")
        return rep


def _validate(manifest_path: str, spec: dict, silhouettes: dict) -> Report:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)

    asset_id = manifest["asset_id"]
    category = manifest["category"]
    rep = Report(asset_id)
    glb_path = manifest_path[:-5] + ".glb"

    # ---- naming ----------------------------------------------------------
    pattern = spec["naming"]["asset_id_pattern"]
    rep.check(re.match(pattern, asset_id) is not None,
              f"asset_id matches {pattern}")
    # The id is the key to everything else: the game's registry stores
    # manifests under it and builds `<folder>/<asset_id>.glb` from it, and
    # every node lookup below is `f"{asset_id}_lod0"` and its siblings. An id
    # that disagrees with the file it was written beside makes those lookups
    # measure a node that is not there — which reads as "no geometry" rather
    # than as a mismatch, and for a character (no LOD nodes to miss) passed
    # outright while the game fell back to a placeholder box.
    stem = os.path.basename(manifest_path)[:-5]
    rep.check(asset_id == stem,
              f"manifest asset_id '{asset_id}' matches its file name '{stem}'")

    # `category` is the other half of that key: the registry turns it into the
    # folder it loads the .glb from, and the checks below branch on it, so a
    # manifest that names a category it was not written into both skips its own
    # category's rules and sends the game looking down the wrong path.
    folder = os.path.basename(os.path.dirname(manifest_path))
    if not rep.check(CATEGORY_FOLDER.get(category) == folder,
                     f"category '{category}' is a known category written to "
                     f"the folder it lives in ('{folder}')"):
        return rep

    # Nothing below can mean anything about a number that is not one. Checked
    # over the whole document rather than field by field, because a NaN is a
    # generator accident rather than a typo — it arrives wherever the accident
    # was, not where anyone thought to look.
    unreal = _nonfinite(manifest)
    rep.check(not unreal,
              "every number in the manifest is finite" if not unreal else
              f"manifest holds non-finite numbers at: {unreal[:4]}")

    # ---- file exists -----------------------------------------------------
    if not rep.check(os.path.exists(glb_path), "glb exported"):
        return rep
    gltf = read_glb(glb_path)
    info = summarise(gltf)

    rep.check(True, "decoded binary accessors have valid extents, finite values "
              "and bounds matching their metadata")
    rep.check(True, "decoded triangles have valid indices, nonzero area, unique "
              "faces and consistent two-face-edge winding")
    geometry = spec["geometry"]
    for measured, policy, description in (
            ("boundary_edges", "boundary_edges_allowed", "boundary edges"),
            ("junction_edges", "coincident_junction_edges_allowed", "coincident junction edges"),
            ("indexed_junction_edges", "indexed_junction_edges_allowed", "shared indexed junction edges")):
        count = sum(t[measured] for t in info["topology"])
        rep.check(not count or geometry.get(policy) is True,
                  f"assembled geometry has {count} {description} "
                  f"(allowed: {geometry.get(policy)})")

    # Bounds below come from decoded vertices and each mesh node's translation.
    # The pipeline bakes rotation and scale into vertices; assert that contract
    # rather than silently ignoring transformed or nested geometry.
    moved = []
    for node in gltf.get("nodes", []):
        name = node.get("name", "?")
        if node.get("matrix") is not None:
            moved.append(f"{name}: matrix")
        scale = node.get("scale")
        if scale is not None and [round(v, 6) for v in scale] != [1.0, 1.0, 1.0]:
            moved.append(f"{name}: scale {scale}")
        rot = node.get("rotation")
        if rot is not None and [round(v, 6) for v in rot] != [0.0, 0.0, 0.0, 1.0]:
            moved.append(f"{name}: rotation {rot}")
    rep.check(not moved,
              "every node has unit scale and no rotation" if not moved else
              f"node scale/rotation must be identity — {'; '.join(moved[:3])}")

    # ---- structure -------------------------------------------------------
    # Everything below finds nodes by name in a dictionary keyed by name, and
    # a glTF file is under no obligation to make that meaningful. It may hold
    # nodes no scene reaches, two nodes with the same name (the later one wins
    # in that dictionary), or a parent whose translation moves a child the
    # child's own entry knows nothing about. The exporter produces exactly one
    # shape — one scene, one root empty named for the asset, every mesh and
    # every attachment a direct child of it — so assert that shape and the
    # lookups afterwards mean what they say.
    names = info["node_names"]
    dupes = sorted({n for n in names if names.count(n) > 1})
    rep.check(not dupes,
              "node names are unique" if not dupes else
              f"duplicate node names hide one another: {dupes}")
    rep.check(info["scene_roots"] == [asset_id],
              f"the scene has one root node named {asset_id} "
              f"(found {info['scene_roots']})")
    stray = sorted(n for n in names
                   if n != asset_id and info["parent_of"].get(n) != asset_id)
    rep.check(not stray,
              "every node is a direct child of the root" if not stray else
              f"nodes not parented directly to {asset_id}: {stray[:4]} — "
              f"a parent's transform would move geometry unmeasured, and an "
              f"unreachable node is never drawn at all")
    root_t = info["empties"].get(asset_id)
    rep.check(root_t == [0.0, 0.0, 0.0],
              f"the root node sits at the origin (translation {root_t})")
    rep.check(info["primitive_modes"] in ([], [4]),
              f"every primitive is drawn as triangles (modes "
              f"{info['primitive_modes']}) — a strip or fan of the same index "
              f"count is a different number of triangles")

    # ---- dimensions ------------------------------------------------------
    # Measured from the exported file, not from the manifest. The manifest is
    # written by the same generator that produced the mesh, so validating it
    # against itself proved only that the generator is self-consistent — an
    # export scaled a hundredfold sailed through.
    visual_nodes = _visual_nodes(info)
    glb_lo, glb_hi = _combined_bounds(info, visual_nodes)
    if glb_lo is None:
        rep.check(False, "glb carries position bounds for its visual meshes")
        return rep
    lo, hi = glb_lo, glb_hi
    size = [hi[i] - lo[i] for i in range(3)]

    declared_lo = manifest["bounds_min"]
    declared_hi = manifest["bounds_max"]
    drift = max(abs(lo[i] - declared_lo[i]) for i in range(3))
    drift = max(drift, max(abs(hi[i] - declared_hi[i]) for i in range(3)))
    rep.check(drift <= 0.02,
              f"glb bounds match the manifest (worst axis differs by "
              f"{drift:.3f} m)")
    rep.check(all(s > 0.05 for s in size),
              f"dimensions valid ({size[0]:.2f} x {size[1]:.2f} x "
              f"{size[2]:.2f} m)")

    ref_h = spec["scale"]["reference_human_height_m"]
    if category == "character":
        rep.check(abs(size[2] - ref_h) < 0.18,
                  f"character height {size[2]:.2f} m ~= {ref_h} m")
    else:
        rep.check(size[2] < 40.0, f"height {size[2]:.2f} m within sane range")

    # `height_m` is the field `AssetRegistry.height()` hands the game, and it
    # was the one dimension the validator measured and then never compared:
    # the bounds check above covers `bounds_min`/`bounds_max`, which nothing
    # in the game reads. 5 mm, which is ten times the most the manifest's
    # three-decimal rounding can contribute and far more than float32 storage
    # can; the worst disagreement in the current set is 0.0005 m. Wider than
    # that stops being rounding and starts being a different number — at the
    # 20 mm this first used, the field plot could declare itself 8% taller
    # than it is.
    declared_h = float(manifest["height_m"])
    height_drift = abs(size[2] - declared_h)
    rep.check(height_drift <= 0.005,
              f"glb height {size[2]:.3f} m matches manifest height_m "
              f"{declared_h:.3f} m (differs by {height_drift:.3f} m)")

    fw, fd = manifest["footprint_m"]
    # A footprint is metres of ground, so it has to be some. Zero passed the
    # ratio checks below for every category but building, because a zero
    # divisor was mapped to a ratio of 0.0 and a non-building's band is only a
    # warning — and the game sizes a placement grid and a pick box from it.
    if not rep.check(fw > 0 and fd > 0,
                     f"footprint_m is positive ({fw} x {fd} m)"):
        return rep
    # Two-sided, because `footprint_m` is the number the placement grid, the
    # nav footprint and the click box are all built from. The old check was an
    # upper bound at 2.6x and warn-only, so an *over*-declared footprint was
    # never caught at all and an under-declared one did not fail the build:
    # declaring the blacksmith as 1 x 1 m passed, and in game gave a 10.5 m
    # building a 1 m pick box that buildings could be placed on top of.
    #
    # The fail band is wide enough to clear every asset in the set today; the
    # warn band is where the set actually sits, so drift gets noticed.
    rx = size[0] / fw if fw > 0 else 0.0
    ry = size[1] / fd if fd > 0 else 0.0
    if category == "building":
        rep.check(0.75 <= rx <= 1.45 and 0.75 <= ry <= 1.45,
                  f"geometry matches declared footprint {fw} x {fd} m "
                  f"(x {rx:.2f}x, y {ry:.2f}x)")
        rep.check(0.85 <= rx <= 1.25 and 0.85 <= ry <= 1.25,
                  f"footprint is a close fit (x {rx:.2f}x, y {ry:.2f}x)",
                  warn_only=True)
    else:
        # Crowns overhang their trunk, a fence is a line, and a character's
        # footprint is a nominal standing box — none of these are load-bearing
        # the way a building's is, so only gross nonsense is worth reporting.
        rep.check(0.3 <= rx <= 2.0 and 0.3 <= ry <= 2.0,
                  f"geometry is the order of the declared footprint "
                  f"{fw} x {fd} m (x {rx:.2f}x, y {ry:.2f}x)",
                  warn_only=True)

    # ---- origin ----------------------------------------------------------
    # `spec["origin"]["tolerance_m"]` is 0.02 m, which nothing in the set meets
    # and which was read into a variable that was never used — so the check
    # that actually ran was a warn-only one with several metres of slack. These
    # two are expressed as a fraction of the asset's own footprint, which is
    # what "near the centre" has to mean for assets spanning 0.5 m to 17 m.
    if category in ("building", "resource_node", "prop", "vegetation"):
        # Foundations may sink slightly below zero; anything more is a mistake.
        rep.check(lo[2] > -0.85,
                  f"origin at foundation level (min z = {lo[2]:.3f} m)")
        centre_x = (lo[0] + hi[0]) * 0.5
        centre_y = (lo[1] + hi[1]) * 0.5
        off_x = abs(centre_x) / fw if fw > 0 else 0.0
        off_y = abs(centre_y) / fd if fd > 0 else 0.0
        rep.check(off_x <= 0.35 and off_y <= 0.35,
                  f"origin at the footprint centre "
                  f"(offset {centre_x:.2f}, {centre_y:.2f} m)")
        rep.check(off_x <= 0.12 and off_y <= 0.12,
                  f"origin is well centred "
                  f"(offset {centre_x:.2f}, {centre_y:.2f} m = "
                  f"{off_x:.0%}, {off_y:.0%} of footprint)",
                  warn_only=True)

    # ---- materials -------------------------------------------------------
    # Checked against the exported glTF, not only the manifest. The manifest is
    # written by the same generator that produced the mesh, so trusting it for
    # this meant the validator was marking the generator's own homework.
    library = material_library()
    declared = set(manifest["materials"])
    # Counted over the meshes in the file, from the materials they draw with.
    # Counting the manifest's list let an asset ship with an extra material
    # the generator forgot to declare.
    visual_materials = set()
    for name in visual_nodes:
        visual_materials.update(info["node_materials"].get(name, []))
    # Equality, both directions. A subset check in either direction is half a
    # check: `declared <= drawn` let a manifest declare no materials at all,
    # and the reverse let the file draw with one the manifest never mentions
    # — and the manifest's list is what the review sheet and the style audit
    # read.
    rep.check(declared == visual_materials,
              "the manifest's materials are exactly the ones the meshes draw "
              "with" if declared == visual_materials else
              f"materials disagree — only in the manifest: "
              f"{sorted(declared - visual_materials)}; only in the glb: "
              f"{sorted(visual_materials - declared)}")
    unknown = sorted((declared | visual_materials) - set(library))
    rep.check(not unknown, f"all materials in shared library "
                           f"(unknown: {unknown})" if unknown
                           else "all materials in shared library")
    cap = spec["materials"]["max_per_asset"]
    rep.check(len(visual_materials) <= cap,
              f"material count {len(visual_materials)} <= {cap} "
              f"({', '.join(sorted(visual_materials))})")

    # ---- triangle budget -------------------------------------------------
    # The budget comes from the live spec, not from the copy baked into the
    # manifest at generation time: tightening style.yaml has to be able to fail
    # assets that were generated under the old limit.
    budget = spec["triangle_budget"][category]
    overrides = spec["triangle_budget"].get("overrides") or {}
    if asset_id in overrides:
        budget = int(overrides[asset_id])
    tris = manifest["triangles"]
    main = tris.get("lod0", tris.get("parts", 0))
    rep.check(main <= budget, f"triangle budget {main} <= {budget}")
    # The manifest keeps its own copy of the budget it was generated under.
    # Nothing reads it, which is exactly why it could drift from the spec
    # without anyone noticing; a copy that disagrees with the live figure
    # means the asset was built under a different rule than the one in force.
    rep.check(int(manifest["triangle_budget"]) == budget,
              f"manifest records the budget it was built under "
              f"({manifest['triangle_budget']}, spec says {budget})")

    # And the mesh in the file has to match what the manifest claims about it.
    glb_main = 0
    for node_name, node_tris in info["mesh_nodes"].items():
        if node_name.endswith("_lod0") or category == "character":
            glb_main += node_tris
    rep.check(glb_main > 0, "glb contains visual geometry")
    # Exact for a character, whose limb parts are the only geometry in the
    # file and are welded and triangulated rather than decimated: a 2% band
    # let a citizen declare 232 triangles and ship 228.
    slack = 0 if category == "character" else max(2, main * 0.02)
    rep.check(abs(glb_main - main) <= slack,
              f"glb triangle count {glb_main} matches manifest {main}")

    # The manifest and the file have to list the same meshes, both ways round.
    # Checking only that what the manifest declares is present let the file
    # carry geometry nobody declared — a stale export still holding a mesh the
    # generator no longer produces validated clean — and let the manifest
    # declare a level that does not exist, since a missing node reads as zero
    # triangles and a declared zero matches it.
    declared_levels = sorted(k for k in tris if k != "parts")
    expected_meshes = {f"{asset_id}_{lvl}" for lvl in declared_levels}
    expected_meshes |= set(manifest["parts"])
    found_meshes = set(info["mesh_nodes"])
    rep.check(found_meshes == expected_meshes,
              "the glb's meshes are exactly the ones the manifest declares"
              if found_meshes == expected_meshes else
              f"manifest and glb disagree on which meshes exist — only in the "
              f"manifest: {sorted(expected_meshes - found_meshes)}; only in "
              f"the glb: {sorted(found_meshes - expected_meshes)}")

    # Every level's declared count against the geometry that level's own node
    # carries, not just lod0's. Ordering the manifest against itself — lod2 <=
    # lod1 <= lod0, below — proves only that the generator wrote three
    # decreasing numbers: a lod2 node pointing at the lod0 mesh passed while
    # the manifest claimed 194 triangles.
    #
    # Driven by what the manifest declares rather than by the LOD spec, so a
    # category left off `lod.required_for` that ships a chain anyway still has
    # its counts measured. Resource nodes were exactly that, and their reduced
    # levels went unchecked; they are on the list now, but the measurement no
    # longer depends on being on it.
    #
    # Exact, with no tolerance. Both sides count the same thing: the manifest
    # sums `len(poly.vertices) - 2` over the mesh the level was built from,
    # the file counts its own index accessors, and every asset in the set
    # agrees to the triangle. A tolerance here would only hide the one failure
    # mode worth catching, which is a level whose mesh is not the mesh the
    # manifest was written from.
    for level, declared_tris in sorted(tris.items()):
        if level == "parts":
            continue
        measured = info["mesh_nodes"].get(f"{asset_id}_{level}", 0)
        rep.check(measured == declared_tris,
                  f"{level} carries {measured} triangles, manifest says "
                  f"{declared_tris}")

    # ---- LODs ------------------------------------------------------------
    if category in spec["lod"]["required_for"]:
        ratios = spec["lod"]["ratios"]
        # Presence is a fact about the file. Reading it from the manifest meant
        # an export missing both reduced meshes still passed.
        have = []
        for level in ("lod0", "lod1", "lod2"):
            node = f"{asset_id}_{level}"
            if info["mesh_nodes"].get(node, 0) > 0 and level in tris:
                have.append(level)
        rep.check(len(have) == 3,
                  f"all LOD levels present in the glb ({have})")
        if len(have) == 3:
            rep.check(tris["lod1"] <= tris["lod0"],
                      f"lod1 ({tris['lod1']}) not heavier than lod0 "
                      f"({tris['lod0']})")
            rep.check(tris["lod2"] <= tris["lod1"],
                      f"lod2 ({tris['lod2']}) not heavier than lod1 "
                      f"({tris['lod1']})")
            strategy = (spec["lod"].get("strategy") or {}).get(
                category, "decimate")
            if strategy == "detail":
                # Detail-tier LODs are authored, not numeric, so the ratios do
                # not apply. What does matter is that the tiers were actually
                # declared: an asset whose distant level is no lighter than its
                # near one is paying for three meshes and getting one.
                # A barrel is a barrel at any distance. Below this there is
                # nothing worth shedding, and warning about it only trains
                # people to ignore the report.
                worth_reducing = tris["lod0"] >= 200
                if worth_reducing and tris["lod2"] >= tris["lod0"]:
                    rep.warn(f"lod2 {tris['lod2']} no lighter than lod0 "
                             f"{tris['lod0']} — nothing is tagged above detail "
                             f"tier 0, so the LOD chain does no work")
                # The other way round is worse than doing nothing: a first
                # reduction this severe means a tier holds something the asset
                # cannot be recognised without. The log-pile prop lost its logs
                # and kept its two retaining stakes exactly this way, and every
                # citizen carrying timber was drawn holding them.
                floor = tris["lod0"] * 0.25
                rep.check(tris["lod1"] >= floor,
                          f"lod1 keeps {tris['lod1']} of {tris['lod0']} "
                          f"triangles (at least {floor:.0f} expected; below "
                          f"that a detail tier is holding the asset itself)")
            else:
                target = tris["lod0"] * ratios["lod1"]
                if tris["lod1"] > target * 2.2:
                    rep.warn(f"lod1 {tris['lod1']} far above target "
                             f"{target:.0f} (hard-edged geometry resists "
                             f"decimation)")

    # ---- attachments -----------------------------------------------------
    # These are positions, not just names. The game walks citizens to
    # att_entrance, parks carts at att_cart_bay, stands workers at
    # att_worksite and hangs visible goods off att_stock_*, all read from the
    # manifest — so an attachment whose manifest coordinate is not where the
    # exported empty actually sits sends people to a place the asset is not.
    # Checking only that the name existed let a coordinate of [10000, 10000,
    # 10000] through.
    known = set(spec["attachments"]["known"])
    # Both directions, for the same reason as the meshes: the game reads the
    # manifest, so a point the exporter placed and the manifest forgot is a
    # point the game will never walk to — `AssetRegistry.attachment()` returns
    # Vector3.ZERO for a name it does not hold, which puts the citizen at the
    # middle of the building rather than at its door.
    file_atts = set(info["empties"]) - {asset_id}
    declared_atts = set(manifest["attachments"])
    rep.check(file_atts == declared_atts,
              "the glb's attachment points are exactly the ones the manifest "
              "declares" if file_atts == declared_atts else
              f"manifest and glb disagree on attachments — only in the "
              f"manifest: {sorted(declared_atts - file_atts)}; only in the "
              f"glb: {sorted(file_atts - declared_atts)}")
    # The exporter writes Z-up Blender metres to the manifest and exports the
    # scene Y-up, so glTF (x, y, z) is Blender (x, -z, y). The empties are
    # parented to a root at the origin with an identity transform — asserted
    # above — so a node's translation is its position in the asset's space.
    # 1 mm of slack: the manifest's four-decimal rounding can contribute
    # 0.05 mm, this module's own rounding of the node translation another
    # 0.05 mm, and float32 storage a thousandth of that at these magnitudes.
    # The worst disagreement in the current set is 0.0000 m.
    for name, pos in manifest["attachments"].items():
        rep.check(name in known, f"attachment '{name}' is a known type")
        if not rep.check(name in info["node_names"],
                         f"attachment '{name}' exported to glb"):
            continue
        node_t = info["empties"].get(name)
        if node_t is None:
            rep.check(False, f"attachment '{name}' is a mesh node, not an "
                             f"empty, so it carries no position")
            continue
        expected = [pos[0], pos[2], -pos[1]]
        off = max(abs(expected[i] - node_t[i]) for i in range(3))
        rep.check(off <= 0.001,
                  f"attachment '{name}' sits where the manifest says "
                  f"({pos[0]:.2f}, {pos[1]:.2f}, {pos[2]:.2f} m, "
                  f"worst axis off by {off:.4f} m)")
        # ...and somewhere near the asset. A doorstep or a cart bay stands
        # just clear of the wall; nothing legitimate is a whole building's
        # width away, and a coordinate that has gone wrong is usually wrong by
        # orders of magnitude rather than by centimetres.
        reach = max(2.0, 0.5 * max(fw, fd))
        outside = max(max(lo[i] - pos[i], pos[i] - hi[i], 0.0)
                      for i in range(3))
        rep.check(outside <= reach,
                  f"attachment '{name}' lies within {reach:.1f} m of the "
                  f"asset's own bounds (furthest axis {outside:.2f} m outside)")
    if category == "building":
        rep.check("att_entrance" in manifest["attachments"],
                  "building declares att_entrance")

    # ---- characters ------------------------------------------------------
    if category == "character":
        required = {"torso", "head", "arm_l", "arm_r", "leg_l", "leg_r"}
        parts = {p[len(asset_id) + 1:] for p in manifest["parts"]}
        rep.check(required <= parts,
                  f"all animation pivots present (missing: "
                  f"{sorted(required - parts)})")
        # ...and present in the file, not merely named in the manifest.
        # citizen.gd caches the pivots by matching the *exported* node names,
        # so a limb the manifest lists and the glb does not carry is a limb
        # the walk cycle silently never animates.
        absent = sorted(p for p in manifest["parts"]
                        if p not in info["mesh_nodes"])
        rep.check(not absent,
                  "every declared part is a mesh node in the glb"
                  if not absent else
                  f"manifest names parts the glb does not contain: {absent}")

    # ---- silhouette distinctiveness (design doc 5.3) ---------------------
    if category == "building":
        sig = (round(size[0], 1), round(size[1], 1), round(size[2], 1))
        twin = silhouettes.get(sig)
        if twin:
            rep.warn(f"silhouette very similar to {twin} "
                     f"(same {sig[0]}x{sig[1]}x{sig[2]} m bounds)")
        else:
            silhouettes[sig] = asset_id

    # ---- preview ---------------------------------------------------------
    preview = os.path.join(REPO_ROOT, "assets", "previews", f"{asset_id}.png")
    rep.check(os.path.exists(preview), "turntable preview rendered",
              warn_only=True)

    return rep


def main() -> int:
    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "-v" in sys.argv or "--verbose" in sys.argv

    spec = style()
    manifests = find_manifests(wanted)
    if not manifests:
        print("No generated assets found. Run the generator first.")
        return 2

    # Naming an asset that does not exist used to validate whatever else was
    # asked for and exit zero, so a typo in a CI invocation reported a clean
    # run over a subset nobody meant to check.
    found = {os.path.basename(p)[:-5] for p in manifests}
    unknown = sorted(set(wanted) - found)
    if unknown:
        print(f"No such asset(s): {', '.join(unknown)}")
        return 2

    print(f"\n=== Marchlands asset validation: {len(manifests)} asset(s) ===\n")
    silhouettes: dict = {}
    reports = [check_spec_consistency(spec)]
    reports += [validate(p, spec, silhouettes) for p in manifests]
    for rep in reports:
        print(rep.render(verbose))

    failed = [r.asset_id for r in reports if r.failed]
    warned = [r.asset_id for r in reports if r.warned and not r.failed]
    # The spec report is not an asset, so it is not counted as one.
    print(f"\n=== {len(manifests) - len(failed)} passed, {len(failed)} failed, "
          f"{len(warned)} with warnings ===")
    if failed:
        print(f"failed: {failed}")
        return 1
    # An asset is validated because its manifest was found, so an export whose
    # manifest is missing — a generator that wrote the .glb and died before the
    # .json, a manifest deleted by hand — is not a failure here, it is an
    # absence, and absences do not appear in a report of what was checked. Only
    # on a full run: a filtered one is meant to look at a subset.
    if not wanted:
        described = {os.path.splitext(p)[0] for p in manifests}
        orphans = sorted(
            os.path.relpath(os.path.join(root, name), REPO_ROOT)
            for root, _dirs, files in os.walk(GENERATED)
            for name in files
            if name.endswith(".glb")
            and os.path.join(root, name[:-4]) not in described)
        if orphans:
            print(f"\nexported with no manifest, so never validated: "
                  f"{orphans}")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
