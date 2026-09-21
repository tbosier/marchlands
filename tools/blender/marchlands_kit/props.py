"""Small props: the clutter that makes a settlement look inhabited.

These are the objects the simulation places organically around player-built
structures (design doc 2.2), plus the carried/haulable goods.
"""

from __future__ import annotations

import math
import random

from . import kit as K
from . import mesh as M
from .buildings import Asset


def log_pile() -> Asset:
    # The logs are tier 2 dressing when they sit beside a cottage, but here
    # they *are* the asset, so they are declared silhouette. Without this the
    # reduced levels kept the two retaining stakes and nothing between them —
    # and a citizen carrying timber is drawn at lod1.
    mb = M.MeshBuilder("log_pile")
    rng = random.Random(5)
    K.log_stack(mb, center=(0, 0, 0), rows=3, cols=4, log_r=0.16,
                length=2.4, rng=rng, detail=0)
    for sx in (-1, 1):
        K.post(mb, center=(sx * 1.25, 0.0, 0.0), height=1.1, thickness=0.1,
               detail=1)
    a = Asset("log_pile", "prop", mb, (2.6, 1.4))
    return a


def stone_pile() -> Asset:
    mb = M.MeshBuilder("stone_pile")
    rng = random.Random(15)
    for i in range(9):
        a = math.tau * i / 9
        d = rng.uniform(0.0, 0.55)
        s = rng.uniform(0.3, 0.55)
        v, f = M.box(s, s * rng.uniform(0.8, 1.1), s * 0.7, center=(0, 0, 0),
                     taper=rng.uniform(0.5, 0.85))
        mb.add(v, f, "stone_grey",
               transform=M.xform(
                   location=(math.cos(a) * d, math.sin(a) * d,
                             rng.uniform(0.0, 0.28)),
                   rotation_z=rng.uniform(0, math.pi)))
    return Asset("stone_pile", "prop", mb, (1.6, 1.6))


def grain_sack() -> Asset:
    mb = M.MeshBuilder("grain_sack")
    v, f = M.cylinder(0.24, 0.62, segments=8, center=(0, 0, 0),
                      top_radius=0.17)
    mb.add(v, f, "fabric_muted", smooth=True)
    v, f = M.box(0.2, 0.14, 0.12, center=(0, 0, 0.6), taper=0.5)
    mb.add(v, f, "fabric_muted")
    v, f = M.cylinder(0.19, 0.05, segments=8, center=(0, 0, 0.56))
    mb.add(v, f, "timber_dark", smooth=True)
    return Asset("grain_sack", "prop", mb, (0.5, 0.5))


def barrel() -> Asset:
    mb = M.MeshBuilder("barrel")
    K.barrel_shape(mb, center=(0, 0, 0), radius=0.34, height=0.86)
    return Asset("barrel", "prop", mb, (0.7, 0.7))


def crate() -> Asset:
    mb = M.MeshBuilder("crate")
    s = 0.68
    v, f = M.box(s, s, s, center=(0, 0, 0))
    mb.add(v, f, "timber_light")
    r = 0.055
    for sz in (r, s - r):
        for sy in (-1, 1):
            v, f = M.box(s + 0.02, r * 1.2, r * 1.6,
                         center=(0, sy * (s * 0.5), sz))
            mb.add(v, f, "timber_dark")
        for sx in (-1, 1):
            v, f = M.box(r * 1.2, s + 0.02, r * 1.6,
                         center=(sx * (s * 0.5), 0, sz))
            mb.add(v, f, "timber_dark")
    for sx in (-1, 1):
        for sy in (-1, 1):
            v, f = M.box(r * 1.4, r * 1.4, s + 0.02,
                         center=(sx * s * 0.5, sy * s * 0.5, 0))
            mb.add(v, f, "timber_dark")
    return Asset("crate", "prop", mb, (0.8, 0.8))


def fence() -> Asset:
    """A single 3 m fence segment; the game chains these along boundaries."""
    mb = M.MeshBuilder("fence")
    K.fence_run(mb, (-1.5, 0, 0), (1.5, 0, 0), height=1.05, post_spacing=1.5)
    return Asset("fence", "prop", mb, (3.0, 0.2))


def wood_cart() -> Asset:
    """Two-wheeled hand cart. Shafts point -Y so a citizen can pull it."""
    mb = M.MeshBuilder("wood_cart")
    bed_w, bed_l, bed_h = 1.25, 1.95, 0.42
    axle_z = 0.44

    # Bed floor and sides.
    v, f = M.box(bed_w, bed_l, 0.1, center=(0, 0, axle_z + 0.12))
    mb.add(v, f, "timber_light")
    for sx in (-1, 1):
        v, f = M.box(0.07, bed_l, bed_h,
                     center=(sx * (bed_w * 0.5 - 0.035), 0, axle_z + 0.22))
        mb.add(v, f, "timber_light")
    v, f = M.box(bed_w, 0.07, bed_h, center=(0, bed_l * 0.5 - 0.035, axle_z + 0.22))
    mb.add(v, f, "timber_light")
    for lz in (axle_z + 0.24, axle_z + 0.5):
        for sx in (-1, 1):
            v, f = M.box(0.05, bed_l + 0.04, 0.06,
                         center=(sx * (bed_w * 0.5 + 0.02), 0, lz))
            mb.add(v, f, "timber_dark")

    # Chassis, axle, wheels.
    for sx in (-1, 1):
        v, f = M.box(0.1, bed_l + 0.2, 0.12, center=(sx * 0.42, 0, axle_z))
        mb.add(v, f, "timber_dark")
    v, f = M.box(bed_w + 0.3, 0.11, 0.11, center=(0, -0.1, axle_z - 0.02))
    mb.add(v, f, "iron_dark")
    for sx in (-1, 1):
        K.cart_wheel(mb, center=(sx * (bed_w * 0.5 + 0.12), -0.16, axle_z - 0.02),
                     radius=0.44, width=0.1, spokes=6)

    # Shafts for the hauler.
    for sx in (-1, 1):
        tf = M.xform(location=(sx * 0.4, -bed_l * 0.5 - 0.5, axle_z + 0.02),
                     rotation_x=math.radians(-8))
        v, f = M.box(0.08, 1.5, 0.08, center=(0, 0, 0))
        mb.add(v, f, "timber_dark", transform=tf)
    v, f = M.box(0.95, 0.07, 0.07, center=(0, -bed_l * 0.5 - 1.2, axle_z + 0.12))
    mb.add(v, f, "timber_dark")

    a = Asset("wood_cart", "prop", mb, (1.6, 3.4))
    a.attach("att_worksite", (0.0, -bed_l * 0.5 - 1.35, 0.0))
    a.attach("att_stock_0", (0.0, 0.0, axle_z + 0.22))
    return a.center_footprint()


PROPS = {
    "log_pile": log_pile,
    "stone_pile": stone_pile,
    "grain_sack": grain_sack,
    "barrel": barrel,
    "crate": crate,
    "fence": fence,
    "wood_cart": wood_cart,
}
