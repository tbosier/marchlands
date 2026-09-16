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


def _visual_nodes(info: dict, asset_id: str, category: str) -> list[str]:
    """The mesh nodes that are the asset, as opposed to its collision shell."""
    out = []
    for name in info["mesh_nodes"]:
        if name.endswith("_collision"):
            continue
        out.append(name)
    return out


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

    # ---- file exists -----------------------------------------------------
    if not rep.check(os.path.exists(glb_path), "glb exported"):
        return rep
    gltf = read_glb(glb_path)
    info = summarise(gltf)

    # Bounds below are read straight off each mesh node's position accessor,
    # which is only the whole story while no node carries a transform. The
    # pipeline always bakes transforms into the vertices and writes identity
    # nodes, so assert that rather than composing parent chains: without this,
    # a scale of 100 on the root node would sail through every size check
    # here while the game rendered a building a hundred times too big.
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
              "every node transform is identity (bounds are measured from "
              "vertices)" if not moved else
              f"node transforms must be identity — {'; '.join(moved[:3])}")

    # ---- dimensions ------------------------------------------------------
    # Measured from the exported file, not from the manifest. The manifest is
    # written by the same generator that produced the mesh, so validating it
    # against itself proved only that the generator is self-consistent — an
    # export scaled a hundredfold sailed through.
    visual_nodes = _visual_nodes(info, asset_id, category)
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

    fw, fd = manifest["footprint_m"]
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
    glb_materials = set(m for m in info["materials"] if m)
    declared = set(manifest["materials"])
    # Subset, not equality: the exported file also carries the collision
    # shell's material, which is not part of the asset's art budget.
    missing = sorted(declared - glb_materials)
    rep.check(not missing,
              "every declared material is present in the glb"
              if not missing else
              f"manifest declares materials the glb does not contain: {missing}")
    unknown = sorted((declared | glb_materials) - set(library))
    rep.check(not unknown, f"all materials in shared library "
                           f"(unknown: {unknown})" if unknown
                           else "all materials in shared library")
    cap = spec["materials"]["max_per_asset"]
    # Counted over the visual meshes in the file. Counting the manifest's list
    # let an asset ship with an extra material the generator forgot to declare.
    visual_materials = set()
    for name in visual_nodes:
        visual_materials.update(info["node_materials"].get(name, []))
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

    # And the mesh in the file has to match what the manifest claims about it.
    glb_main = 0
    for node_name, node_tris in info["mesh_nodes"].items():
        if node_name.endswith("_lod0") or (category == "character"
                                           and not node_name.endswith("_collision")):
            glb_main += node_tris
    rep.check(glb_main > 0, "glb contains visual geometry")
    rep.check(abs(glb_main - main) <= max(2, main * 0.02),
              f"glb triangle count {glb_main} matches manifest {main}")

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

    # ---- collision -------------------------------------------------------
    if category in spec["collision"]["required_for"]:
        rep.check(manifest["has_collision"], "collision mesh present")
        expect = spec["collision"]["naming"].format(asset_id=asset_id)
        rep.check(expect in info["node_names"],
                  f"collision node named {expect}")

    # ---- attachments -----------------------------------------------------
    known = set(spec["attachments"]["known"])
    for name in manifest["attachments"]:
        rep.check(name in known, f"attachment '{name}' is a known type")
        rep.check(name in info["node_names"],
                  f"attachment '{name}' exported to glb")
    if category == "building":
        rep.check("att_entrance" in manifest["attachments"],
                  "building declares att_entrance")

    # ---- characters ------------------------------------------------------
    if category == "character":
        required = {"torso", "head", "arm_l", "arm_r", "leg_l", "leg_r"}
        have = {p.rsplit("_", 1)[-1] if p.startswith(asset_id) else p
                for p in manifest["parts"]}
        parts = {p[len(asset_id) + 1:] for p in manifest["parts"]}
        rep.check(required <= parts,
                  f"all animation pivots present (missing: "
                  f"{sorted(required - parts)})")

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
    return 0


if __name__ == "__main__":
    sys.exit(main())
