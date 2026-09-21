"""LOD generation.

Two strategies, chosen per category in assets/specs/style.yaml:

  * "detail"   — rebuild the mesh with its finer detail tiers removed. This is
                 what buildings and props use. Collapse decimation on sparse
                 hard-surface geometry destroys it (wall panels vanish and the
                 timber frame survives as a cage of floating sticks), so the
                 simplification has to be authored, not numeric.
  * "decimate" — Blender's Decimate modifier at the ratios in the spec. Right
                 for foliage, which is dense and organic and has no silhouette
                 that a collapse can ruin.
"""

from __future__ import annotations

import bpy
import bmesh

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
        _strip_duplicate_faces(obj)
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


def _strip_duplicate_faces(obj: bpy.types.Object) -> None:
    """Drop faces that repeat a face already kept, vertex for vertex.

    Collapse decimation regularly folds two source faces onto the same three
    vertices and leaves both in the mesh. Nothing renders the second one — the
    glTF exporter writes each distinct triangle once — so the only thing the
    duplicates ever reached was the manifest, which counted them and therefore
    claimed more triangles for a reduced LOD than the exported file contains.
    The wheat crop declared 144 triangles at lod2 and shipped 72.
    """
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    seen = set()
    doomed = []
    for face in bm.faces:
        key = frozenset(v.index for v in face.verts)
        if key in seen:
            doomed.append(face)
        else:
            seen.add(key)
    if doomed:
        bmesh.ops.delete(bm, geom=doomed, context="FACES_ONLY")
        bm.to_mesh(obj.data)
        obj.data.update()
    bm.free()
