"""Trees, crops and resource nodes.

Trees are built from a tapered trunk, a few branches and overlapping canopy
shells. Keeping the canopy as faceted low-poly hulls (rather than cards) means
they read correctly from the elevated camera at any angle and need no alpha.
"""

from __future__ import annotations

import math
import random

from . import kit as K
from . import mesh as M
from .buildings import Asset

# One field tile. The game tiles these on its 4 m simulation grid.
FIELD_SIZE = 4.0
FIELD_ROWS = 6


def _canopy_blob(mb: M.MeshBuilder, center, radius: float, squash: float,
                 material: str, rng: random.Random, segments: int = 7,
                 rings: int = 3):
    """A faceted ellipsoid with jittered vertices — reads as clumped foliage."""
    cx, cy, cz = center
    verts = []
    verts.append((cx, cy, cz + radius * squash))
    for r in range(1, rings + 1):
        phi = math.pi * r / (rings + 1)
        rr = math.sin(phi) * radius
        zz = math.cos(phi) * radius * squash
        for s in range(segments):
            a = 2.0 * math.pi * s / segments + r * 0.4
            j = rng.uniform(0.86, 1.14)
            verts.append((cx + math.cos(a) * rr * j,
                          cy + math.sin(a) * rr * j,
                          cz + zz * rng.uniform(0.92, 1.08)))
    verts.append((cx, cy, cz - radius * squash))
    bottom = len(verts) - 1

    faces = []
    for s in range(segments):
        faces.append((0, 1 + (s + 1) % segments, 1 + s))
    for r in range(rings - 1):
        base_a = 1 + r * segments
        base_b = 1 + (r + 1) * segments
        for s in range(segments):
            s2 = (s + 1) % segments
            faces.append((base_a + s, base_a + s2, base_b + s2, base_b + s))
    last = 1 + (rings - 1) * segments
    for s in range(segments):
        faces.append((last + s, last + (s + 1) % segments, bottom))
    mb.add(verts, faces, material, smooth=True)


def _trunk(mb: M.MeshBuilder, height: float, base_r: float, top_r: float,
           lean: float, rng: random.Random, segments: int = 7,
           sections: int = 3):
    """A gently leaning, tapering trunk built from stacked rings."""
    z = 0.0
    x = y = 0.0
    ang = rng.uniform(0, math.tau)
    dx, dy = math.cos(ang) * lean, math.sin(ang) * lean
    prev_r = base_r
    for i in range(sections):
        t0 = i / sections
        t1 = (i + 1) / sections
        h = height * (t1 - t0)
        r0 = base_r + (top_r - base_r) * t0
        r1 = base_r + (top_r - base_r) * t1
        v, f = M.cylinder(r0, h, segments=segments, center=(0, 0, 0),
                          top_radius=r1, capped=(i == 0 or i == sections - 1))
        tf = M.xform(location=(x + dx * t0 * height, y + dy * t0 * height,
                               height * t0))
        mb.add(v, f, "timber_dark", transform=tf, smooth=True)
    return (dx * height, dy * height)


def _root_flare(mb: M.MeshBuilder, base_r: float, rng: random.Random) -> None:
    """A short, wider ring at the foot of the trunk.

    A tapered cylinder meeting the ground at a hard right angle reads as a
    dowel pushed into the soil. A flared collar and three buttresses cost
    fifty triangles out of a twelve-hundred budget, and are the difference
    between a post and a tree.
    """
    v, f = M.cylinder(base_r * 1.55, base_r * 1.7, segments=7,
                      center=(0, 0, 0), top_radius=base_r * 1.02,
                      capped=False)
    mb.add(v, f, "timber_dark", smooth=True)
    for i in range(3):
        a = math.tau * i / 3 + rng.uniform(-0.4, 0.4)
        v, f = M.box(base_r * 1.5, base_r * 0.8, base_r * 1.3,
                     center=(base_r * 0.75, 0, base_r * 0.55), taper=0.25)
        mb.add(v, f, "timber_dark", transform=M.xform(rotation_z=a))


def _tree(asset_id: str, seed: int, height: float, canopy_material: str,
          shade_material: str, style: str) -> Asset:
    """One tree.

    The canopy is built from two materials, not one. Every lobe the sun would
    reach from above is the bright leaf colour; the mass they sit on is the
    shade colour, and it shows through the gaps between them and along the
    underside of the crown. From the play camera that is what separates one
    lobe from the next — a canopy painted in a single flat green has no
    internal edges at all, which is exactly why the old trees read as green
    lollipops from forty metres up.
    """
    rng = random.Random(seed)
    mb = M.MeshBuilder(asset_id)

    if style == "conifer":
        base_r = height * 0.042
        tip = _trunk(mb, height * 0.95, base_r, base_r * 0.25, height * 0.004,
                     rng, segments=6, sections=2)
        _root_flare(mb, base_r, rng)
        layers = 6
        for i in range(layers):
            t = i / (layers - 1)
            z = height * (0.17 + 0.71 * t)
            # The skirts do not simply shrink from the ground up. The lowest
            # tier is drawn in shorter than the one above it, so the widest
            # point of the tree sits a fifth of the way up rather than at the
            # very bottom — which is what keeps the profile from being a plain
            # triangle.
            spread = 1.0 - 0.80 * t
            if i == 0:
                spread *= 0.82
            r = height * 0.30 * spread * rng.uniform(0.90, 1.08)
            h = height * (0.26 - 0.05 * t)
            centre = (tip[0] * (z / height), tip[1] * (z / height), z)
            v, f = M.cone(r, h, segments=8, center=(0, 0, 0))
            # Each tier is rotated off the one below so the facets never line
            # up into a smooth revolved surface.
            tf = M.xform(location=centre,
                         rotation_z=rng.uniform(0, math.tau),
                         rotation_x=rng.uniform(-0.05, 0.05))
            # The bottom half of the tree lies in its own shade; the top
            # three tiers catch the sky.
            mat = canopy_material if t > 0.55 else shade_material
            mb.add(v, f, mat, transform=tf, smooth=False)
            # A thin bright cap on the shaded tiers, bar the lowest, which
            # nothing reaches: the light that does get down the tree lands on
            # the upper face of each skirt.
            if t <= 0.55 and i > 0:
                v, f = M.cone(r * 0.62, h * 0.55, segments=8, center=(0, 0, 0))
                mb.add(v, f, canopy_material,
                       transform=M.xform(location=(centre[0], centre[1],
                                                   centre[2] + h * 0.30),
                                         rotation_z=rng.uniform(0, math.tau)),
                       smooth=False)
        crown_r = height * 0.30
    else:
        base_r = height * 0.058
        # A shorter clear trunk than before. The old proportion put the whole
        # canopy above half the tree's height on a bare pole; a broadleaf
        # carries its mass lower and wider than that, and the silhouette is
        # far better for it.
        clear = height * 0.42
        tip = _trunk(mb, clear, base_r, base_r * 0.40,
                     height * 0.014, rng, segments=7, sections=3)
        _root_flare(mb, base_r, rng)
        cz = clear
        # Branches lifting into the canopy, at varied angles.
        for i in range(4):
            a = math.tau * i / 4 + rng.uniform(-0.5, 0.5)
            tf = M.xform(location=(tip[0], tip[1], cz - height * 0.05),
                         rotation_z=a,
                         rotation_y=math.radians(rng.uniform(24, 52)))
            v, f = M.cylinder(base_r * 0.34, height * 0.26, segments=5,
                              center=(0, 0, 0), top_radius=base_r * 0.15)
            mb.add(v, f, "timber_dark", transform=tf, smooth=True)

        main_r = height * 0.33
        # The inner mass, in shade. It is deliberately the largest single
        # volume: the bright lobes are laid on it like tiles on a roof.
        _canopy_blob(mb, (tip[0], tip[1], cz + main_r * 0.60), main_r, 0.86,
                     shade_material, rng, segments=9, rings=3)

        # Bright lobes on the upper outside, at markedly different heights and
        # sizes. Identical lobes evenly spaced is what made the old crown read
        # as one sphere; the variation is the whole point.
        lobes = 5
        for i in range(lobes):
            a = math.tau * i / lobes + rng.uniform(-0.38, 0.38)
            d = main_r * rng.uniform(0.52, 0.82)
            r = main_r * rng.uniform(0.44, 0.68)
            lift = main_r * rng.uniform(0.55, 1.05)
            _canopy_blob(
                mb,
                (tip[0] + math.cos(a) * d, tip[1] + math.sin(a) * d, cz + lift),
                r, 0.80, canopy_material, rng, segments=7, rings=2)
        # One low outrigger, deliberately off-centre. A perfectly radial crown
        # looks grown in a laboratory; one limb reaching further than the rest
        # is what makes a tree look like it grew towards the light.
        a = rng.uniform(0, math.tau)
        _canopy_blob(
            mb,
            (tip[0] + math.cos(a) * main_r * 1.02,
             tip[1] + math.sin(a) * main_r * 1.02,
             cz + main_r * 0.28),
            main_r * 0.50, 0.74, canopy_material, rng, segments=7, rings=2)
        crown_r = main_r * 1.55

    a = Asset(asset_id, "vegetation", mb, (crown_r * 2, crown_r * 2))
    a.attach("att_worksite", (crown_r * 0.9, -crown_r * 0.9, 0.0))
    return a


def oak_tree_01() -> Asset:
    return _tree("oak_tree_01", 101, 9.2, "foliage_green", "foliage_deep",
                 "broadleaf")


def oak_tree_02() -> Asset:
    return _tree("oak_tree_02", 202, 7.4, "foliage_autumn",
                 "foliage_autumn_deep", "broadleaf")


def pine_tree_01() -> Asset:
    return _tree("pine_tree_01", 303, 11.5, "foliage_green", "foliage_deep",
                 "conifer")


def stone_node_01() -> Asset:
    """A weathered granite outcrop the quarry is placed against."""
    rng = random.Random(77)
    mb = M.MeshBuilder("stone_node_01")
    for i in range(6):
        a = math.tau * i / 6 + rng.uniform(-0.3, 0.3)
        d = rng.uniform(0.0, 1.5)
        s = rng.uniform(0.9, 2.2)
        v, f = M.box(s, s * rng.uniform(0.75, 1.1), s * rng.uniform(0.55, 0.95),
                     center=(0, 0, 0), taper=rng.uniform(0.45, 0.8))
        tf = M.xform(location=(math.cos(a) * d, math.sin(a) * d, -0.15),
                     rotation_z=rng.uniform(0, math.pi),
                     rotation_x=rng.uniform(-0.12, 0.12))
        mb.add(v, f, "stone_grey", transform=tf)
    for i in range(5):
        a = rng.uniform(0, math.tau)
        d = rng.uniform(1.6, 2.6)
        s = rng.uniform(0.25, 0.55)
        v, f = M.box(s, s, s * 0.7, center=(0, 0, 0), taper=0.6)
        mb.add(v, f, "stone_grey",
               transform=M.xform(location=(math.cos(a) * d, math.sin(a) * d, -0.05),
                                 rotation_z=rng.uniform(0, math.pi)))
    a = Asset("stone_node_01", "resource_node", mb, (5.0, 5.0))
    a.attach("att_worksite", (0.0, -2.4, 0.0))
    return a


def iron_node_01() -> Asset:
    """Ore-bearing rock: dark stone shot through with rusty iron seams."""
    rng = random.Random(88)
    mb = M.MeshBuilder("iron_node_01")
    for i in range(5):
        a = math.tau * i / 5 + rng.uniform(-0.25, 0.25)
        d = rng.uniform(0.0, 1.2)
        s = rng.uniform(1.0, 2.0)
        v, f = M.box(s, s * rng.uniform(0.8, 1.1), s * rng.uniform(0.7, 1.2),
                     center=(0, 0, 0), taper=rng.uniform(0.4, 0.7))
        mb.add(v, f, "stone_grey",
               transform=M.xform(location=(math.cos(a) * d, math.sin(a) * d, -0.2),
                                 rotation_z=rng.uniform(0, math.pi),
                                 rotation_x=rng.uniform(-0.15, 0.15)))
    for i in range(7):
        a = rng.uniform(0, math.tau)
        d = rng.uniform(0.2, 1.7)
        v, f = M.box(rng.uniform(0.3, 0.7), rng.uniform(0.2, 0.4),
                     rng.uniform(0.15, 0.35), center=(0, 0, 0), taper=0.7)
        mb.add(v, f, "brick_red",
               transform=M.xform(
                   location=(math.cos(a) * d, math.sin(a) * d,
                             rng.uniform(0.3, 1.5)),
                   rotation_z=rng.uniform(0, math.pi),
                   rotation_y=rng.uniform(-0.4, 0.4)))
    a = Asset("iron_node_01", "resource_node", mb, (4.2, 4.2))
    a.attach("att_worksite", (0.0, -2.0, 0.0))
    return a


def field_plot() -> Asset:
    """One 4x4 m tile of ploughed earth.

    Split from the crop deliberately. The field used to be a single mesh
    squashed flat on Y while the crop was young, which flattened the soil with
    it and read as a brown smear. Soil is always full height; only the grain
    above it grows.
    """
    rng = random.Random(61)
    mb = M.MeshBuilder("field_plot")
    size = FIELD_SIZE

    v, f = M.box(size + 0.04, size + 0.04, 0.10, center=(0, 0, -0.05))
    mb.add(v, f, "soil_dark")

    # Ploughed ridges, running along X so tiled plots line up into one field.
    for r in range(FIELD_ROWS):
        y = -size * 0.5 + size * (r + 0.5) / FIELD_ROWS
        h = rng.uniform(0.10, 0.15)
        v, f = M.box(size * 0.98, size / FIELD_ROWS * 0.62, h,
                     center=(0, y, 0.04), taper=0.72)
        mb.add(v, f, "soil_dark")

    a = Asset("field_plot", "vegetation", mb, (size, size))
    return a


def wheat_crop() -> Asset:
    """The standing grain for one field tile, sitting in the furrows.

    Drawn as clumps rather than individual stalks: at the distance this is
    actually seen, a clump reads better than a stalk and costs a fifth as
    much geometry.
    """
    rng = random.Random(55)
    mb = M.MeshBuilder("wheat_crop")
    size = FIELD_SIZE
    clumps = 6

    for r in range(FIELD_ROWS):
        y = -size * 0.5 + size * (r + 0.5) / FIELD_ROWS
        for c in range(clumps):
            x = -size * 0.5 + size * (c + 0.5) / clumps
            x += rng.uniform(-0.09, 0.09)
            h = rng.uniform(0.78, 0.98)
            tf = M.xform(location=(x, y + rng.uniform(-0.05, 0.05), 0.0),
                         rotation_z=rng.uniform(-0.25, 0.25),
                         rotation_x=rng.uniform(-0.07, 0.07))
            v, f = M.box(size / clumps * 0.94, size / FIELD_ROWS * 0.56,
                         h * 0.66, center=(0, 0, 0), taper=0.80)
            mb.add(v, f, "foliage_green", transform=tf)
            v, f = M.box(size / clumps * 0.86, size / FIELD_ROWS * 0.50,
                         h * 0.40, center=(0, 0, h * 0.62), taper=0.55)
            mb.add(v, f, "grain_gold", transform=tf)

    a = Asset("wheat_crop", "vegetation", mb, (size, size))
    return a


VEGETATION = {
    "field_plot": field_plot,
    "oak_tree_01": oak_tree_01,
    "oak_tree_02": oak_tree_02,
    "pine_tree_01": pine_tree_01,
    "wheat_crop": wheat_crop,
}

RESOURCE_NODES = {
    "stone_node_01": stone_node_01,
    "iron_node_01": iron_node_01,
}
