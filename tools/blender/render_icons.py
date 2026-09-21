"""Render a build-bar icon for each placeable building.

    blender -b -P tools/blender/render_icons.py -- [asset_id ...]

The build bar used to be text only, which made every button look the same and
told the player nothing about what they were about to place. These are the same
assets the game uses, lit the same way and shot from the same three-quarter
angle the play camera sits at, rendered small with a transparent background.

Output: assets/icons/<asset_id>.png
"""

from __future__ import annotations

import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from marchlands_kit import exporter, materials, registry  # noqa: E402
from marchlands_kit.style import REPO_ROOT  # noqa: E402
import render_previews as prev  # noqa: E402

ICON_DIR = os.path.join(REPO_ROOT, "assets", "icons")
ICON_SIZE = 256

## The buildings the build bar offers, in the order BuildingDefs.buildable()
## returns them: every definition whose `buildable` flag is true, which at the
## time of writing is everything except the keep, the forge and the grain
## warehouse (the last two are reached by upgrading, not by placing).
##
## This list was short by two — `mine` and `blacksmith` were missing, though
## icons for both existed, having been rendered by hand. That is worse than it
## sounds: re-running this script after a palette or lighting change would
## refresh six icons and leave those two sitting beside them in the old look.
BUILD_BAR = [
    "house_small_01",
    "stockpile",
    "logging_camp",
    "quarry",
    "farmhouse",
    "mine",
    "blacksmith",
    "granary",
]


def argv_after_dashes():
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    return []


def configure_icon_render() -> None:
    scene = bpy.context.scene
    engines = scene.render.bl_rna.properties["engine"].enum_items.keys()
    for candidate in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        if candidate in engines:
            scene.render.engine = candidate
            break
    scene.render.resolution_x = ICON_SIZE
    scene.render.resolution_y = ICON_SIZE
    scene.render.resolution_percentage = 100
    # Transparent, so the icon sits on the button rather than in a box.
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    if hasattr(scene.eevee, "taa_render_samples"):
        scene.eevee.taa_render_samples = 32
    scene.view_settings.view_transform = "AgX"
    looks = scene.view_settings.bl_rna.properties["look"].enum_items.keys()
    for candidate in ("AgX - Medium Contrast", "AgX - Base Contrast", "None"):
        if candidate in looks:
            scene.view_settings.look = candidate
            break


def _brighten_for_icon() -> None:
    """Icons sit on a dark toolbar, so they are lit harder than a preview.

    Without this the buildings render as brown silhouettes that are
    indistinguishable from one another at button size.
    """
    for obj in bpy.context.scene.objects:
        if obj.type != "LIGHT":
            continue
        if obj.name == "key":
            obj.data.energy = 5.0
        elif obj.name == "fill":
            obj.data.energy = 2.6
    world = bpy.context.scene.world
    if world and world.node_tree:
        bg = world.node_tree.nodes.get("Background")
        if bg:
            bg.inputs["Color"].default_value = (0.55, 0.58, 0.62, 1.0)
            bg.inputs["Strength"].default_value = 1.5


def render_icon(asset_id: str, factory) -> str:
    exporter.reset_scene()
    materials.build_all()

    asset = factory()
    exporter.build_asset_objects(asset, make_lods=False)
    bpy.context.view_layer.update()

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    lo, hi = prev.scene_bounds(meshes)

    prev.setup_world()
    _brighten_for_icon()
    configure_icon_render()
    # No ground plane: a shadow catcher would show up as a grey smear once the
    # background is transparent.

    # Much tighter and slightly steeper than the preview turntable. An icon is
    # read at about forty pixels, so empty margin is the enemy: filling the
    # frame is worth more than a flattering composition.
    prev.setup_camera(lo, hi, -math.pi * 0.5 + math.radians(38), ICON_SIZE,
                      fit_deg=27.0, elev_deg=30.0)

    os.makedirs(ICON_DIR, exist_ok=True)
    path = os.path.join(ICON_DIR, "%s.png" % asset_id)
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def main() -> int:
    wanted = argv_after_dashes()
    all_assets = registry()
    targets = wanted if wanted else BUILD_BAR

    missing = [a for a in targets if a not in all_assets]
    if missing:
        print("UNKNOWN ASSETS: %s" % missing)
        return 2

    print("\n=== rendering %d icon(s) @ %dpx ===\n" % (len(targets), ICON_SIZE))
    for asset_id in targets:
        path = render_icon(asset_id, all_assets[asset_id])
        print("  %-22s -> %s" % (asset_id, os.path.relpath(path, REPO_ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
