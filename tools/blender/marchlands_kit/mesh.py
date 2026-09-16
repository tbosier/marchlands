"""Low-level mesh construction helpers.

Everything in Marchlands is built from explicit vertex/face lists rather than
Blender operators. That keeps generation deterministic, fast in background
mode, and free of the hidden state that bpy.ops carries around.

A `Part` is a bag of geometry with one material per face group. Parts are
combined into a `MeshBuilder`, which finally becomes a Blender mesh object.
"""

from __future__ import annotations

import contextlib
import math

import bpy
import bmesh
from mathutils import Matrix, Vector

from . import materials


class MeshBuilder:
    """Accumulates vertices/faces with per-face material slots.

    Every face also carries a **detail tier**, which is how Marchlands builds
    its LODs. These assets are already low-poly hard-surface geometry; running
    a collapse decimator over a 1400-triangle half-timbered cottage does not
    simplify it, it dissolves the wall panels and leaves a cage of spikes. So
    instead of removing triangles from everything, a LOD removes *things*:

        tier 0  silhouette — walls, roofs, socles, chimneys. Always present.
        tier 1  readable at a distance — frames, doors, windows, dormers.
        tier 2  eye-level dressing — studs, shutters, fences, log piles.

    lod0 keeps every tier, lod1 keeps 0-1, lod2 keeps tier 0 alone. Each kit
    helper declares its own tier, so building code rarely has to think about
    it; `with mb.detail(2): ...` demotes a whole block when a caller knows
    better.
    """

    def __init__(self, name: str):
        self.name = name
        self.verts: list[tuple[float, float, float]] = []
        self.faces: list[tuple[int, ...]] = []
        self.face_materials: list[str] = []
        self.smooth_faces: list[bool] = []
        self.face_detail: list[int] = []
        self._detail_floor = 0

    # -- construction ----------------------------------------------------

    @contextlib.contextmanager
    def detail(self, tier: int):
        """Demote everything added inside this block to at least `tier`.

        Nested scopes take the maximum, so wrapping a block never accidentally
        promotes a detail that a helper deliberately marked as fine dressing.
        """
        previous = self._detail_floor
        self._detail_floor = max(previous, int(tier))
        try:
            yield self
        finally:
            self._detail_floor = previous

    def add(self, verts, faces, material: str, smooth: bool = False,
            transform: Matrix | None = None, detail: int = 0):
        base = len(self.verts)
        tier = max(self._detail_floor, int(detail))
        if transform is None:
            self.verts.extend(tuple(v) for v in verts)
        else:
            for v in verts:
                self.verts.append(tuple(transform @ Vector(v)))
        for f in faces:
            self.faces.append(tuple(base + i for i in f))
            self.face_materials.append(material)
            self.smooth_faces.append(smooth)
            self.face_detail.append(tier)
        return self

    def merge(self, other: "MeshBuilder", transform: Matrix | None = None):
        base = len(self.verts)
        if transform is None:
            self.verts.extend(other.verts)
        else:
            for v in other.verts:
                self.verts.append(tuple(transform @ Vector(v)))
        for f, m, s, dt in zip(other.faces, other.face_materials,
                               other.smooth_faces, other.face_detail):
            self.faces.append(tuple(base + i for i in f))
            self.face_materials.append(m)
            self.smooth_faces.append(s)
            self.face_detail.append(max(self._detail_floor, dt))
        return self

    def filtered(self, max_detail: int) -> "MeshBuilder":
        """A copy holding only faces at or below `max_detail`, without the
        vertices that nothing references any more."""
        out = MeshBuilder(f"{self.name}_d{max_detail}")
        remap: dict[int, int] = {}
        for face, mat, smooth, tier in zip(self.faces, self.face_materials,
                                           self.smooth_faces,
                                           self.face_detail):
            if tier > max_detail:
                continue
            new_face = []
            for index in face:
                mapped = remap.get(index)
                if mapped is None:
                    mapped = len(out.verts)
                    remap[index] = mapped
                    out.verts.append(self.verts[index])
                new_face.append(mapped)
            out.faces.append(tuple(new_face))
            out.face_materials.append(mat)
            out.smooth_faces.append(smooth)
            out.face_detail.append(tier)
        return out

    def detail_tiers(self) -> set[int]:
        return set(self.face_detail)

    # -- queries ---------------------------------------------------------

    def bounds(self):
        if not self.verts:
            return (Vector((0, 0, 0)), Vector((0, 0, 0)))
        xs = [v[0] for v in self.verts]
        ys = [v[1] for v in self.verts]
        zs = [v[2] for v in self.verts]
        return (Vector((min(xs), min(ys), min(zs))),
                Vector((max(xs), max(ys), max(zs))))

    def material_names(self):
        seen = []
        for m in self.face_materials:
            if m not in seen:
                seen.append(m)
        return seen

    # -- output ----------------------------------------------------------

    def to_object(self, collection: bpy.types.Collection | None = None,
                  name: str | None = None) -> bpy.types.Object:
        name = name or self.name
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata(self.verts, [], self.faces)
        mesh.validate(verbose=False)

        slots = self.material_names()
        for mat_name in slots:
            mesh.materials.append(materials.get(mat_name))
        index_of = {n: i for i, n in enumerate(slots)}
        for poly, mat_name, smooth in zip(mesh.polygons, self.face_materials,
                                          self.smooth_faces):
            poly.material_index = index_of[mat_name]
            poly.use_smooth = smooth

        obj = bpy.data.objects.new(name, mesh)
        (collection or bpy.context.scene.collection).objects.link(obj)
        return obj


# --------------------------------------------------------------------------
# Primitive generators (all return (verts, faces))
# --------------------------------------------------------------------------

def box(size_x: float, size_y: float, size_z: float,
        center=(0.0, 0.0, 0.0), taper: float = 1.0):
    """Axis-aligned box. `taper` scales the top face (1.0 = plain box)."""
    hx, hy = size_x * 0.5, size_y * 0.5
    tx, ty = hx * taper, hy * taper
    cx, cy, cz = center
    z0, z1 = cz, cz + size_z
    v = [
        (cx - hx, cy - hy, z0), (cx + hx, cy - hy, z0),
        (cx + hx, cy + hy, z0), (cx - hx, cy + hy, z0),
        (cx - tx, cy - ty, z1), (cx + tx, cy - ty, z1),
        (cx + tx, cy + ty, z1), (cx - tx, cy + ty, z1),
    ]
    f = [
        (0, 3, 2, 1),  # bottom
        (4, 5, 6, 7),  # top
        (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7),
    ]
    return v, f


def gable_roof(width: float, depth: float, height: float,
               overhang: float = 0.0, center=(0.0, 0.0, 0.0),
               ridge_along_x: bool = True):
    """Classic two-slope roof. Returns the roof shell only (no gable walls)."""
    cx, cy, cz = center
    hw = width * 0.5 + overhang
    hd = depth * 0.5 + overhang
    if ridge_along_x:
        v = [
            (cx - hw, cy - hd, cz), (cx + hw, cy - hd, cz),
            (cx + hw, cy + hd, cz), (cx - hw, cy + hd, cz),
            (cx - hw, cy, cz + height), (cx + hw, cy, cz + height),
        ]
        f = [(0, 1, 5, 4), (2, 3, 4, 5), (0, 4, 3), (1, 2, 5)]
    else:
        v = [
            (cx - hw, cy - hd, cz), (cx + hw, cy - hd, cz),
            (cx + hw, cy + hd, cz), (cx - hw, cy + hd, cz),
            (cx, cy - hd, cz + height), (cx, cy + hd, cz + height),
        ]
        f = [(0, 4, 5, 3), (1, 2, 5, 4), (0, 1, 4), (2, 3, 5)]
    return v, f


def gable_wall(width: float, height: float, peak: float,
               center=(0.0, 0.0, 0.0), axis: str = "y"):
    """The triangular wall piece that fills the end of a gable roof."""
    cx, cy, cz = center
    hw = width * 0.5
    if height <= 1e-4:
        # Pure triangle: skipping the degenerate quad keeps the mesh valid.
        if axis == "y":
            v = [(cx - hw, cy, cz), (cx + hw, cy, cz), (cx, cy, cz + peak)]
        else:
            v = [(cx, cy - hw, cz), (cx, cy + hw, cz), (cx, cy, cz + peak)]
        return v, [(0, 1, 2)]

    if axis == "y":  # wall lies in the XZ plane
        v = [(cx - hw, cy, cz), (cx + hw, cy, cz),
             (cx + hw, cy, cz + height), (cx, cy, cz + height + peak),
             (cx - hw, cy, cz + height)]
    else:            # wall lies in the YZ plane
        v = [(cx, cy - hw, cz), (cx, cy + hw, cz),
             (cx, cy + hw, cz + height), (cx, cy, cz + height + peak),
             (cx, cy - hw, cz + height)]
    f = [(0, 1, 2, 4), (2, 3, 4)]
    return v, f


def cylinder(radius: float, height: float, segments: int = 8,
             center=(0.0, 0.0, 0.0), top_radius: float | None = None,
             capped: bool = True):
    top_radius = radius if top_radius is None else top_radius
    cx, cy, cz = center
    v, f = [], []
    for i in range(segments):
        a = 2.0 * math.pi * i / segments
        v.append((cx + math.cos(a) * radius, cy + math.sin(a) * radius, cz))
    for i in range(segments):
        a = 2.0 * math.pi * i / segments
        v.append((cx + math.cos(a) * top_radius,
                  cy + math.sin(a) * top_radius, cz + height))
    for i in range(segments):
        j = (i + 1) % segments
        f.append((i, j, segments + j, segments + i))
    if capped:
        if top_radius > 1e-5:
            f.append(tuple(range(segments, segments * 2)))
        f.append(tuple(reversed(range(segments))))
    return v, f


def cone(radius: float, height: float, segments: int = 8,
         center=(0.0, 0.0, 0.0)):
    cx, cy, cz = center
    v = []
    for i in range(segments):
        a = 2.0 * math.pi * i / segments
        v.append((cx + math.cos(a) * radius, cy + math.sin(a) * radius, cz))
    apex = len(v)
    v.append((cx, cy, cz + height))
    f = [(i, (i + 1) % segments, apex) for i in range(segments)]
    f.append(tuple(reversed(range(segments))))
    return v, f


def prism(points_2d, height: float, z: float = 0.0):
    """Extrude a convex/simple 2D polygon (CCW) into a solid."""
    n = len(points_2d)
    v = [(p[0], p[1], z) for p in points_2d]
    v += [(p[0], p[1], z + height) for p in points_2d]
    f = [tuple(reversed(range(n))), tuple(range(n, 2 * n))]
    for i in range(n):
        j = (i + 1) % n
        f.append((i, j, n + j, n + i))
    return v, f


def quad(p0, p1, p2, p3):
    return [p0, p1, p2, p3], [(0, 1, 2, 3)]


# --------------------------------------------------------------------------
# Transform helpers
# --------------------------------------------------------------------------

def xform(location=(0, 0, 0), rotation_z: float = 0.0,
          rotation_y: float = 0.0, rotation_x: float = 0.0,
          scale=(1, 1, 1)) -> Matrix:
    m = Matrix.Translation(Vector(location))
    if rotation_z:
        m = m @ Matrix.Rotation(rotation_z, 4, "Z")
    if rotation_y:
        m = m @ Matrix.Rotation(rotation_y, 4, "Y")
    if rotation_x:
        m = m @ Matrix.Rotation(rotation_x, 4, "X")
    if scale != (1, 1, 1):
        m = m @ Matrix.Diagonal(Vector(scale).to_4d())
    return m


# --------------------------------------------------------------------------
# Post-processing
# --------------------------------------------------------------------------

def cleanup(obj: bpy.types.Object, merge_distance: float = 0.0005,
            triangulate: bool = True, recalc_normals: bool = True):
    """Weld duplicates, fix winding, triangulate. Keeps topology manifold."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=merge_distance)
    if recalc_normals:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if triangulate:
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def shade_auto_smooth(obj: bpy.types.Object, angle_deg: float = 35.0):
    """Angle-based smooth shading.

    Blender's own implementation moved from a mesh flag (<=4.0) to a modifier
    (4.1-5.1) to a geometry-nodes asset (5.2), so this marks sharp edges
    directly instead: every face is smooth, and any edge whose two face normals
    exceed the threshold is flagged sharp. Version-independent, and the
    resulting normals export cleanly to glTF.
    """
    threshold = math.cos(math.radians(angle_deg))
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    for face in bm.faces:
        face.smooth = True
    for edge in bm.edges:
        if len(edge.link_faces) != 2:
            edge.smooth = False
            continue
        n0, n1 = edge.link_faces[0].normal, edge.link_faces[1].normal
        edge.smooth = n0.dot(n1) >= threshold
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def triangle_count(obj: bpy.types.Object) -> int:
    total = 0
    for poly in obj.data.polygons:
        total += max(1, len(poly.vertices) - 2)
    return total
