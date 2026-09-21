"""Scene assembly, UV generation, GLB export and the per-asset manifest.

One asset = one .glb containing:
    <asset_id>            root empty
      <asset_id>_lod0     visual mesh
      <asset_id>_lod1     (buildings + vegetation)
      <asset_id>_lod2     (buildings + vegetation)
      att_*               attachment empties the game reads by name

The manifest written alongside it records everything the validators and the
game's asset registry need, so neither has to open a .blend.
"""

from __future__ import annotations

import json
import os

import bpy

from . import lod as LOD
from . import mesh as M
from .style import REPO_ROOT, style, triangle_budget


def reset_scene() -> None:
    """A clean, deterministic scene. Cheaper and safer than bpy.ops.wm.read."""
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in list(bpy.data.meshes):
        bpy.data.meshes.remove(mesh)
    for mat in list(bpy.data.materials):
        bpy.data.materials.remove(mat)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0


def smart_uv(obj: bpy.types.Object, angle_limit: float = 1.15,
             island_margin: float = 0.02) -> None:
    """Cube-projection UVs.

    Marchlands materials are flat colours, so UVs exist only to keep the assets
    well-formed for any later texturing work. A deterministic box projection
    beats bpy.ops.uv.smart_project here: no operator context, no view layer
    dependency, and it never hangs in background mode.
    """
    mesh = obj.data
    if not mesh.uv_layers:
        mesh.uv_layers.new(name="UVMap")
    uv_layer = mesh.uv_layers.active.data

    bb = [v.co for v in mesh.vertices]
    if not bb:
        return
    scale = max(
        max(v.x for v in bb) - min(v.x for v in bb),
        max(v.y for v in bb) - min(v.y for v in bb),
        max(v.z for v in bb) - min(v.z for v in bb),
        1e-4,
    )

    for poly in mesh.polygons:
        n = poly.normal
        ax, ay, az = abs(n.x), abs(n.y), abs(n.z)
        for li in poly.loop_indices:
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            if az >= ax and az >= ay:
                u, v = co.x, co.y
            elif ax >= ay:
                u, v = co.y, co.z
            else:
                u, v = co.x, co.z
            uv_layer[li].uv = ((u / scale) % 1.0, (v / scale) % 1.0)


def _empty(name: str, location, parent: bpy.types.Object | None = None,
           collection: bpy.types.Collection | None = None):
    obj = bpy.data.objects.new(name, None)
    obj.empty_display_type = "PLAIN_AXES"
    obj.empty_display_size = 0.25
    obj.location = location
    (collection or bpy.context.scene.collection).objects.link(obj)
    if parent is not None:
        obj.parent = parent
    return obj


def build_asset_objects(asset, make_lods: bool = True):
    """Turn an Asset description into a parented Blender object hierarchy."""
    scene_coll = bpy.context.scene.collection
    root = bpy.data.objects.new(asset.asset_id, None)
    root.empty_display_type = "ARROWS"
    scene_coll.objects.link(root)

    created = {"root": root, "lods": [], "parts": []}

    if getattr(asset, "parts", None):
        # Characters: keep the pivot hierarchy instead of merging.
        for name, (builder, origin) in asset.parts.items():
            obj = builder.to_object(scene_coll, name=f"{asset.asset_id}_{name}")
            M.cleanup(obj)
            M.shade_auto_smooth(obj, style()["geometry"]["shade_auto_smooth_angle_deg"])
            smart_uv(obj)
            obj.location = origin
            obj.parent = root
            created["parts"].append(obj)
        lod0 = None
    else:
        lod0 = asset.builder.to_object(scene_coll, name=f"{asset.asset_id}_lod0")
        M.cleanup(lod0)
        M.shade_auto_smooth(lod0, style()["geometry"]["shade_auto_smooth_angle_deg"])
        LOD._apply_modifiers(lod0)
        smart_uv(lod0)
        lod0.parent = root
        created["lods"].append(lod0)

        if make_lods:
            for level in (1, 2):
                obj = LOD.make_lod(lod0, level, scene_coll,
                                   asset_id=asset.asset_id,
                                   builder=asset.builder,
                                   category=asset.category)
                smart_uv(obj)
                obj.parent = root
                created["lods"].append(obj)

    for name, pos in asset.attachments.items():
        _empty(name, pos, parent=root)

    return created


def export_glb(asset, out_path: str) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        use_selection=False,
        export_apply=True,
        export_yup=True,
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_materials="EXPORT",
        export_texcoords=True,
        export_normals=True,
        export_tangents=False,
        export_animations=False,
    )


def manifest_for(asset, created: dict) -> dict:
    def tri(obj):
        return M.triangle_count(obj) if obj else 0

    lods = created["lods"]
    parts = created["parts"]
    bb_min, bb_max = asset.builder.bounds()

    return {
        "asset_id": asset.asset_id,
        "category": asset.category,
        "footprint_m": [round(asset.footprint[0], 3),
                        round(asset.footprint[1], 3)],
        "bounds_min": [round(c, 4) for c in bb_min],
        "bounds_max": [round(c, 4) for c in bb_max],
        "height_m": round(bb_max.z - bb_min.z, 3),
        "materials": asset.builder.material_names(),
        "triangles": {
            **{f"lod{i}": tri(o) for i, o in enumerate(lods)},
            **({"parts": sum(tri(o) for o in parts)} if parts else {}),
        },
        "triangle_budget": triangle_budget(asset.category, asset.asset_id),
        "parts": [o.name for o in parts],
        "attachments": {k: [round(c, 4) for c in v]
                        for k, v in asset.attachments.items()},
    }


def write_manifest(manifest: dict, out_dir: str) -> str:
    path = os.path.join(out_dir, f"{manifest['asset_id']}.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    return path


def output_dir(category: str) -> str:
    folder = {
        "building": "buildings",
        "prop": "props",
        "vegetation": "vegetation",
        "resource_node": "vegetation",
        "character": "characters",
    }[category]
    return os.path.join(REPO_ROOT, "assets", "generated", folder)
