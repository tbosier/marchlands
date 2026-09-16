"""LOD and collision generation.

Two strategies, chosen per category in assets/specs/style.yaml:

  * "detail"   — rebuild the mesh with its finer detail tiers removed. This is
                 what buildings and props use. Collapse decimation on sparse
                 hard-surface geometry destroys it (wall panels vanish and the
                 timber frame survives as a cage of floating sticks), so the
                 simplification has to be authored, not numeric.
  * "decimate" — Blender's Decimate modifier at the ratios in the spec. Right
                 for foliage, which is dense and organic and has no silhouette
                 that a collapse can ruin.

Collision meshes are convex-ish simplified hulls derived from the source
geometry, which is what the game's placement and picking systems actually
need — not the full silhouette.
"""

from __future__ import annotations

import bpy
import bmesh
from mathutils import Vector

from . import mesh as M
from .style import lod_detail_tier, lod_ratios, lod_strategy, style


def make_lod(source: bpy.types.Object, level: int,
             collection: bpy.types.Collection | None = None,
             asset_id: str | None = None,
             builder: M.MeshBuilder | None = None,
             category: str = "") -> bpy.types.Object:
    """Build `lod{level}` from `source`, however the category asks for.

    `builder` is the MeshBuilder `source` was made from; it is what the
    "detail" strategy needs, since dropping a tier means rebuilding the mesh
    rather than editing one.
    """
    stem = asset_id or source.name.rsplit("_lod", 1)[0]
    name = f"{stem}_lod{level}"

    if builder is not None and lod_strategy(category) == "detail":
        reduced = _reduced_to_tier(builder, lod_detail_tier(level))
        obj = reduced.to_object(collection, name=name)
        M.cleanup(obj)
        M.shade_auto_smooth(obj, style()["geometry"]["shade_auto_smooth_angle_deg"])
        obj.matrix_world = source.matrix_world.copy()
        return obj

    ratio = lod_ratios()[f"lod{level}"]

    mesh = source.data.copy()
    mesh.name = name
    obj = bpy.data.objects.new(name, mesh)
    (collection or bpy.context.scene.collection).objects.link(obj)
    obj.matrix_world = source.matrix_world.copy()

    if ratio < 0.999:
        mod = obj.modifiers.new("Decimate", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
        _apply_modifiers(obj)
    return obj


def _reduced_to_tier(builder: M.MeshBuilder, tier: int) -> M.MeshBuilder:
    """`builder` with detail above `tier` removed — never down to nothing.

    A prop can be made entirely of tier-2 parts (a barrel is nothing but
    barrel), and an empty mesh is not a level of detail. Climb back out until
    something survives.
    """
    highest = max(builder.detail_tiers() or {0})
    for candidate in range(tier, highest + 1):
        reduced = builder.filtered(candidate)
        if reduced.faces:
            return reduced
    return builder


def _apply_modifiers(obj: bpy.types.Object) -> None:
    """Evaluate the modifier stack into real mesh data, without bpy.ops."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    new_mesh = bpy.data.meshes.new_from_object(evaluated)
    old = obj.data
    obj.data = new_mesh
    obj.modifiers.clear()
    if old.users == 0:
        bpy.data.meshes.remove(old)


def make_collision(source: bpy.types.Object, asset_id: str,
                   category: str,
                   collection: bpy.types.Collection | None = None
                   ) -> bpy.types.Object:
    """A simplified collision shell.

    Buildings get a slab matching their occupied volume (cheap and exactly what
    the placement grid wants); everything else gets a convex hull of the source
    geometry.
    """
    name = f"{asset_id}_collision"

    if category == "building":
        bb_min, bb_max = _bounds(source)
        size = bb_max - bb_min
        centre = (bb_max + bb_min) * 0.5
        mb = M.MeshBuilder(name)
        v, f = M.box(size.x, size.y, size.z,
                     center=(centre.x, centre.y, bb_min.z))
        mb.add(v, f, "stone_grey")
        obj = mb.to_object(collection, name=name)
    else:
        mesh = bpy.data.meshes.new(name)
        obj = bpy.data.objects.new(name, mesh)
        (collection or bpy.context.scene.collection).objects.link(obj)
        bm = bmesh.new()
        bm.from_mesh(source.data)
        hull = bmesh.ops.convex_hull(bm, input=bm.verts[:])
        bmesh.ops.delete(
            bm,
            geom=hull["geom_unused"] + hull["geom_interior"],
            context="VERTS",
        )
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        bm.to_mesh(mesh)
        bm.free()
        if source.data.materials:
            mesh.materials.append(source.data.materials[0])

    obj.display_type = "WIRE"
    return obj


def _bounds(obj: bpy.types.Object):
    verts = [Vector(v.co) for v in obj.data.vertices]
    if not verts:
        return Vector((0, 0, 0)), Vector((0, 0, 0))
    xs = [v.x for v in verts]
    ys = [v.y for v in verts]
    zs = [v.z for v in verts]
    return (Vector((min(xs), min(ys), min(zs))),
            Vector((max(xs), max(ys), max(zs))))
