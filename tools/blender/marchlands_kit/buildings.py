"""Procedural generators for every building in the first-playable asset list.

Each generator returns an `Asset`: one merged mesh, the attachment points the
game reads (entrance, cart bay, worksite, smoke, stock slots) and the footprint
the placement system validates against.

All buildings face -Y. Origin is the horizontal footprint centre at ground level.
"""

from __future__ import annotations

import math
import random

from . import kit as K
from . import mesh as M


class Asset:
    def __init__(self, asset_id: str, category: str, builder: M.MeshBuilder,
                 footprint: tuple[float, float]):
        self.asset_id = asset_id
        self.category = category
        self.builder = builder
        self.footprint = footprint
        self.attachments: dict[str, tuple[float, float, float]] = {}

    def attach(self, name: str, position) -> "Asset":
        self.attachments[name] = tuple(position)
        return self

    def center_footprint(self) -> "Asset":
        """Fit placement bounds to the whole asset, including stairs and shafts.

        Recenter before the exporter derives LODs, moving attachment hooks by
        the same horizontal offset so they remain on their authored features.
        Keep all heights unchanged and round footprint dimensions outwards to
        the next decimetre so placement never understates the occupied space.
        """
        low = [min(v[axis] for v in self.builder.verts) for axis in (0, 1)]
        high = [max(v[axis] for v in self.builder.verts) for axis in (0, 1)]
        cx, cy = [(lo + hi) * 0.5 for lo, hi in zip(low, high)]
        self.builder.verts = [(x - cx, y - cy, z)
                              for x, y, z in self.builder.verts]
        self.attachments = {name: (x - cx, y - cy, z)
                            for name, (x, y, z) in self.attachments.items()}
        self.footprint = tuple(math.ceil((hi - lo - 1e-9) * 10) / 10
                               for lo, hi in zip(low, high))
        return self


# --------------------------------------------------------------------------
# Keep
# --------------------------------------------------------------------------

def keep_tier1() -> Asset:
    """The player's seat: a stone donjon with a forebuilding and a great tower.

    Earlier passes produced a correctly-shaped castle that still read as a
    blank grey mass, because every surface was one material in one plane. The
    fix is not more volume but more *edges*: a second darker stone for quoins,
    plinth and string courses; pilaster strips giving each elevation a
    vertical rhythm; corbels carrying the parapet proud of the wall; a timber
    hoarding; dormers breaking the roofline. Almost all of it is flat detail
    pressed against the wall, so the silhouette stays clean and the triangle
    count stays inside the building budget.
    """
    mb = M.MeshBuilder("keep_tier1")
    w, d = 14.0, 11.0
    hall_h = 8.4
    base = 1.35

    # --- plinth: a battered base with a chamfered offset ------------------
    v, f = M.box(w + 1.6, d + 1.6, base, center=(0, 0, -0.3),
                 taper=(w + 0.5) / (w + 1.6))
    mb.add(v, f, "stone_dark")
    K.string_course(mb, w + 0.5, d + 0.5, base - 0.32, material="stone_dark",
                    thickness=0.36, proud=0.16)

    # --- main block -------------------------------------------------------
    K.wall_box(mb, w, d, hall_h, material="stone_grey", center=(0, 0, base))
    K.quoins(mb, w, d, hall_h, center=(0, 0, base), block=0.66)
    K.string_course(mb, w, d, hall_h * 0.46, center=(0, 0, base),
                    thickness=0.3, proud=0.18)

    # Pilaster strips: three to a long face, two to a short one.
    for t in (-0.3, 0.0, 0.3):
        for sy, facing in ((-1, "-y"), (1, "+y")):
            K.buttress_pilaster(mb, center=(w * t, sy * d * 0.5, base),
                                height=hall_h - 0.5, width=0.85, proud=0.3,
                                facing=facing)
    for t in (-0.26, 0.26):
        for sx, facing in ((-1, "-x"), (1, "+x")):
            K.buttress_pilaster(mb, center=(sx * w * 0.5, d * t, base),
                                height=hall_h - 0.5, width=0.85, proud=0.3,
                                facing=facing)

    # --- openings ---------------------------------------------------------
    for x in (2.4, 4.9):
        K.cross_loop(mb, center=(x, -d * 0.5, base + 2.2), facing="-y")
        K.window(mb, center=(x, -d * 0.5 - 0.04, base + 5.2), width=0.62,
                 height=1.5, facing="-y")
    for x in (-5.0, -2.2, 1.4, 4.6):
        K.cross_loop(mb, center=(x, d * 0.5, base + 4.4), facing="+y")
    for y in (-2.4, 2.4):
        K.cross_loop(mb, center=(-w * 0.5, y, base + 3.6), facing="-x")

    # --- parapet on corbels ----------------------------------------------
    top = base + hall_h
    K.machicolation(mb, w, d, top - 0.35, corbel=0.28, spacing=0.92)
    K.wall_walk(mb, w + 0.5, d + 0.5, top + 0.3, center=(0, 0, 0),
                thickness=1.0)
    K.crenellation(mb, w + 1.0, d + 1.0, top + 0.3, center=(0, 0, 0),
                   merlon=0.6, height=0.95, thickness=0.45)

    # --- corner turrets ---------------------------------------------------
    for sx in (-1, 1):
        for sy in (-1, 1):
            tx = sx * (w * 0.5 - 0.35)
            ty = sy * (d * 0.5 - 0.35)
            v, f = M.cylinder(1.3, hall_h + 2.6, segments=9,
                              center=(tx, ty, base * 0.4))
            mb.add(v, f, "stone_grey", smooth=True)
            v, f = M.cylinder(1.5, 0.3, segments=9,
                              center=(tx, ty, base * 0.4 + hall_h + 2.6))
            mb.add(v, f, "stone_dark", smooth=True)
            v, f = M.cone(1.62, 2.1, segments=9,
                          center=(tx, ty, base * 0.4 + hall_h + 2.9))
            mb.add(v, f, "roof_slate", smooth=True)
            K.cross_loop(mb, center=(tx + sx * 1.1, ty, base + 4.0),
                         facing="+x" if sx > 0 else "-x", height=1.1)

    # --- great tower ------------------------------------------------------
    tw, th = 5.6, 15.5
    tx, ty = w * 0.5 - tw * 0.5 + 0.8, d * 0.5 - tw * 0.5 + 0.8
    K.wall_box(mb, tw, tw, th, material="stone_grey", center=(tx, ty, base))
    K.quoins(mb, tw, tw, th, center=(tx, ty, base), block=0.6)
    for frac in (0.34, 0.66):
        K.string_course(mb, tw, tw, th * frac, center=(tx, ty, base),
                        thickness=0.28, proud=0.16)
    for level in (5.0, 9.0, 12.4):
        K.cross_loop(mb, center=(tx - tw * 0.5, ty, base + level), facing="-x")
        K.cross_loop(mb, center=(tx, ty - tw * 0.5, base + level), facing="-y")
    K.machicolation(mb, tw, tw, base + th - 0.35, center=(tx, ty, 0),
                    corbel=0.26, spacing=0.85)
    K.wall_walk(mb, tw + 0.5, tw + 0.5, base + th + 0.3, center=(tx, ty, 0),
                thickness=0.9)
    K.crenellation(mb, tw + 1.0, tw + 1.0, base + th + 0.3, center=(tx, ty, 0),
                   merlon=0.55, height=0.9, thickness=0.42)

    # Banner: the one note of colour, and it marks the seat.
    pole_z = base + th + 1.2
    mb.add(*M.box(0.12, 0.12, 3.6, center=(tx, ty, pole_z)), "timber_dark")
    mb.add(*M.box(0.05, 1.6, 2.0,
                  center=(tx, ty + 0.84, pole_z + 1.3)), "brick_red")

    # --- forebuilding: the stair block guarding the door ------------------
    gw, gd = 6.0, 4.2
    gh = hall_h - 0.6
    gy = -d * 0.5 - gd * 0.5 + 0.4
    K.wall_box(mb, gw, gd, gh, material="stone_grey", center=(-2.2, gy, base))
    K.quoins(mb, gw, gd, gh, center=(-2.2, gy, base), block=0.58)
    K.string_course(mb, gw, gd, gh * 0.5, center=(-2.2, gy, base),
                    thickness=0.26, proud=0.16)
    K.machicolation(mb, gw, gd, base + gh - 0.3, center=(-2.2, gy, 0),
                    corbel=0.24, spacing=0.8)
    K.wall_walk(mb, gw + 0.4, gd + 0.4, base + gh + 0.3, center=(-2.2, gy, 0),
                thickness=0.8)
    K.crenellation(mb, gw + 0.8, gd + 0.8, base + gh + 0.3,
                   center=(-2.2, gy, 0), merlon=0.5, height=0.8,
                   thickness=0.4)
    for sx in (-1, 1):
        gx = -2.2 + sx * (gw * 0.5 + 0.15)
        v, f = M.cylinder(1.0, gh + 2.0, segments=8, center=(gx, gy, base * 0.5))
        mb.add(v, f, "stone_grey", smooth=True)
        v, f = M.cone(1.25, 1.7, segments=8,
                      center=(gx, gy, base * 0.5 + gh + 2.0))
        mb.add(v, f, "roof_slate", smooth=True)
        K.cross_loop(mb, center=(gx, gy - 0.95, base + 3.2), facing="-y",
                     height=1.1)

    # Gate: recessed arch, portcullis, and the stair up to it.
    gate_y = gy - gd * 0.5
    mb.add(*M.box(3.0, 0.4, 4.0, center=(-2.2, gate_y - 0.1, base)),
           "stone_dark")
    K.stairs(mb, 3.6, base + 0.2, 2.4, steps=6,
             center=(-2.2, gate_y - 1.4, 0), material="stone_dark")
    K.door(mb, center=(-2.2, gate_y - 0.16, base), width=2.0, height=3.1,
           facing="-y", material="timber_dark", depth=0.18)
    with mb.detail(2):
        for i in range(5):
            mb.add(*M.box(0.07, 0.1, 3.1,
                          center=(-2.2 - 0.8 + i * 0.4, gate_y - 0.3, base)),
                   "iron_dark")
        for j in range(3):
            mb.add(*M.box(1.9, 0.1, 0.07,
                          center=(-2.2, gate_y - 0.3, base + 0.6 + j * 0.9)),
                   "iron_dark")

    # --- timber hoarding on the exposed flank ----------------------------
    K.hoarding(mb, 6.4, hall_h - 0.4, d * 0.5, center=(2.6, 0, base),
               depth=1.15, height=1.7, facing="+y")

    # --- hall roof, with dormers ------------------------------------------
    roof_h = K.roof_gable(mb, w - 3.4, d - 3.4, top + 0.3, pitch=0.5,
                          center=(-2.0, -0.6, 0), material="roof_slate",
                          wall_material="stone_grey", overhang=0.25)
    for t in (-0.9, 0.9):
        K.dormer(mb, center=(-2.0 + t * 1.6, -0.6 - (d - 3.4) * 0.28,
                             top + 0.3 + roof_h * 0.34),
                 width=0.9, height=0.75, depth=0.8)

    smoke = K.chimney(mb, center=(-w * 0.5 + 2.0, 2.2, top + 0.3),
                      height=3.0, width=1.0, material="stone_dark")

    a = Asset("keep_tier1", "building", mb, (w + 1.6, d + gd + 2.0))
    a.attach("att_entrance", (-2.2, gate_y - 4.0, 0.0))
    a.attach("att_cart_bay", (4.0, -d * 0.5 - 2.8, 0.0))
    a.attach("att_worksite", (-2.2, gate_y - 3.0, 0.0))
    # The keep holds more than any other store in the game, and a full one has
    # to look full: four slots along the yard wall beside the cart bay.
    for i, sx in enumerate((3.0, 5.0, 3.0, 5.0)):
        a.attach("att_stock_%d" % i,
                 (sx, -d * 0.5 - 1.1 - (i // 2) * 1.5, 0.0))
    a.attach("att_smoke", smoke)
    a.attach("att_flag", (tx, ty, pole_z + 3.0))
    return a.center_footprint()


# --------------------------------------------------------------------------
# Houses
# --------------------------------------------------------------------------

def house_hovel() -> Asset:
    """A one-room hovel: the first home a settler is given.

    Low walls on a rough stone course, a thatch that comes down almost to head
    height, one door, one small window and a stub of a smoke stack. No porch,
    no fence, no second storey — the cottage (`house_small_02`) is what a
    household earns by upgrading, so the difference has to read from across
    the settlement.
    """
    mb = M.MeshBuilder("house_hovel")
    w, d, h = 4.2, 4.6, 2.2
    rng = random.Random(5)

    K.foundation(mb, w, d, 0.2, material="stone_dark")
    K.stone_socle(mb, w + 0.18, d + 0.18, 0.5, center=(0, 0, 0.05),
                  material="stone_dark")
    K.wall_box(mb, w, d, h, material="plaster_warm", center=(0, 0, 0.1))
    K.timber_frame(mb, w, d, h, center=(0, 0, 0.1), posts=3, beam=0.14)

    K.door(mb, center=(-0.8, -d * 0.5 - 0.05, 0.1), width=0.85, height=1.75)
    K.window(mb, center=(0.9, -d * 0.5 - 0.04, 1.15), width=0.55, height=0.55,
             shutters=True)

    roof_h = K.roof_thatch(mb, w, d, h + 0.1, pitch=0.6, overhang=0.34)
    ridge = h + 0.1 + roof_h
    smoke = K.chimney(mb, center=(w * 0.5 - 0.8, 1.0, h + 0.1), height=1.2,
                      width=0.5, material="stone_dark", min_top=ridge + 0.35)

    # A few logs by the wall is all the life a hovel has room for.
    K.log_stack(mb, center=(w * 0.5 + 0.55, 0.9, 0.0), rows=2, cols=2,
                log_r=0.11, length=1.1, rng=rng)

    a = Asset("house_hovel", "building", mb, (w + 1.4, d + 1.6))
    a.attach("att_entrance", (-0.8, -d * 0.5 - 1.3, 0.0))
    a.attach("att_smoke", smoke)
    return a


def house_small_02() -> Asset:
    """Town house: jettied upper storey, tiled roof, dormer, street frontage."""
    mb = M.MeshBuilder("house_small_02")
    w, d, h = 5.6, 6.4, 5.1
    jetty = 0.34
    rng = random.Random(9)

    K.foundation(mb, w, d, 0.3, material="stone_dark")
    K.stone_socle(mb, w + 0.12, d + 0.12, 0.55, center=(0, 0, 0.1),
                  material="stone_dark")
    K.wall_box(mb, w, d, h, material="plaster_warm", center=(0, 0, 0.1),
               jetty=jetty)
    K.timber_frame(mb, w, d, h * 0.55, center=(0, 0, 0.1), posts=3, beam=0.16)
    K.timber_frame(mb, w + jetty * 2, d + jetty * 2, h * 0.45,
                   center=(0, 0, 0.1 + h * 0.55), posts=4, beam=0.16,
                   mid_rail=False)
    K.jetty_brackets(mb, w, d, h * 0.55, jetty, center=(0, 0, 0.1))

    # Herringbone infill panels on the upper storey front.
    with mb.detail(2):
        for i in range(4):
            x = -(w * 0.5) + (w / 4.0) * (i + 0.5)
            for j, ang in ((0, 0.6), (1, -0.6)):
                tf = M.xform(location=(x, -(d * 0.5 + jetty) - 0.03,
                                       0.1 + h * 0.62 + j * 0.46),
                             rotation_y=ang)
                mb.add(*M.box(0.62, 0.07, 0.09, center=(0, 0, 0)),
                       "timber_dark", transform=tf)

    K.door(mb, center=(-1.2, -d * 0.5 - 0.05, 0.1), width=0.92, height=2.05)
    mb.add(*M.box(1.5, 0.5, 0.14, center=(-1.2, -d * 0.5 - 0.3, 2.25)),
           "timber_dark")
    K.window(mb, center=(1.2, -d * 0.5 - 0.04, 1.2), width=0.85, height=0.9)
    K.window_row(mb, 2, 2.1,
                 center=(0, -(d * 0.5 + jetty) - 0.04, h * 0.66),
                 width=0.72, height=0.92)
    K.window(mb, center=(-(w * 0.5 + jetty) - 0.04, 0.4, h * 0.66), width=0.72,
             height=0.92, facing="-x")

    top = h + 0.1
    roof_h = K.roof_gable(mb, w + jetty * 2, d + jetty * 2, top, pitch=0.62,
                          material="roof_tile_red", overhang=0.42,
                          ridge_along_x=False)
    K.roof_ridge_beam(mb, d + jetty * 2 + 0.8, top + roof_h, along_x=False)
    smoke = K.chimney(mb, center=(-w * 0.5 + 0.55, 1.5, top), height=2.6,
                      width=0.62, material="brick_red",
                      min_top=top + roof_h + 0.9)

    K.barrel_shape(mb, center=(w * 0.5 + 0.8, -1.4, 0.0), radius=0.3,
                   height=0.78, hoop_material="timber_dark")

    a = Asset("house_small_02", "building", mb, (w + 1.6, d + 1.6))
    a.attach("att_entrance", (-1.2, -d * 0.5 - 1.8, 0.0))
    a.attach("att_smoke", smoke)
    return a


# --------------------------------------------------------------------------
# Logistics
# --------------------------------------------------------------------------

def stockpile() -> Asset:
    """Open-air goods yard: a timber deck, a lean-to, and visible stock slots."""
    mb = M.MeshBuilder("stockpile")
    w, d = 8.0, 8.0

    # Plank deck.
    planks = 10
    for i in range(planks):
        y = -d * 0.5 + d * (i + 0.5) / planks
        v, f = M.box(w, d / planks * 0.92, 0.18, center=(0, y, 0))
        mb.add(v, f, "timber_light")
    for sx in (-1, 1):
        for sy in (-1, 1):
            v, f = M.box(0.35, 0.35, 0.2,
                         center=(sx * (w * 0.5 - 0.3), sy * (d * 0.5 - 0.3), -0.02))
            mb.add(v, f, "stone_grey")

    # Lean-to along the back edge keeps sacks dry.
    shelter_w = w - 1.2
    for sx in (-1, 1):
        K.post(mb, center=(sx * (shelter_w * 0.5 - 0.2), d * 0.5 - 0.5, 0.18),
               height=2.6)
        K.post(mb, center=(sx * (shelter_w * 0.5 - 0.2), d * 0.5 - 2.6, 0.18),
               height=2.2)
    v = [
        (-shelter_w * 0.5 - 0.3, d * 0.5 - 2.9, 2.38),
        (shelter_w * 0.5 + 0.3, d * 0.5 - 2.9, 2.38),
        (shelter_w * 0.5 + 0.3, d * 0.5 - 0.1, 2.86),
        (-shelter_w * 0.5 - 0.3, d * 0.5 - 0.1, 2.86),
        (-shelter_w * 0.5 - 0.3, d * 0.5 - 2.9, 2.28),
        (shelter_w * 0.5 + 0.3, d * 0.5 - 2.9, 2.28),
        (shelter_w * 0.5 + 0.3, d * 0.5 - 0.1, 2.76),
        (-shelter_w * 0.5 - 0.3, d * 0.5 - 0.1, 2.76),
    ]
    f = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2),
         (2, 6, 7, 3), (3, 7, 4, 0)]
    mb.add(v, f, "roof_tile_red")

    # Low rails on three sides; the front is left open for carts.
    K.fence_run(mb, (-w * 0.5, -d * 0.5, 0.18), (-w * 0.5, d * 0.5, 0.18),
                height=0.8, post_spacing=2.0)
    K.fence_run(mb, (w * 0.5, -d * 0.5, 0.18), (w * 0.5, d * 0.5, 0.18),
                height=0.8, post_spacing=2.0)

    a = Asset("stockpile", "building", mb, (w, d))
    a.attach("att_entrance", (0.0, -d * 0.5 - 1.4, 0.0))
    a.attach("att_cart_bay", (2.4, -d * 0.5 - 1.8, 0.0))
    a.attach("att_stock_0", (-2.2, -1.6, 0.18))
    a.attach("att_stock_1", (0.6, -1.6, 0.18))
    a.attach("att_stock_2", (-2.2, 1.6, 0.18))
    a.attach("att_stock_3", (0.6, 1.6, 0.18))
    return a


def granary() -> Asset:
    """Raised timber granary on staddle stones, with a hoist over the door."""
    mb = M.MeshBuilder("granary")
    w, d = 6.4, 8.4
    lift = 1.0
    h = 4.2

    for sx in (-1, 0, 1):
        for sy in (-1, 0, 1):
            x, y = sx * (w * 0.5 - 0.7), sy * (d * 0.5 - 0.7)
            # Only the corner staddles read from outside; the six under the
            # floor are hidden by the building they hold up.
            tier = 0 if (sx and sy) else 1
            v, f = M.cylinder(0.28, lift * 0.72, segments=8, center=(x, y, 0))
            mb.add(v, f, "stone_grey", smooth=True, detail=tier)
            v, f = M.cylinder(0.48, 0.2, segments=8,
                              center=(x, y, lift * 0.72), top_radius=0.42)
            mb.add(v, f, "stone_grey", smooth=True, detail=tier)

    v, f = M.box(w + 0.3, d + 0.3, 0.22, center=(0, 0, lift - 0.1))
    mb.add(v, f, "timber_dark")
    K.wall_box(mb, w, d, h, material="timber_light", center=(0, 0, lift + 0.12))
    K.timber_frame(mb, w, d, h, center=(0, 0, lift + 0.12), posts=4,
                   beam=0.15, material="timber_dark")

    # Ventilation slits high on both flanks.
    with mb.detail(2):
        for sy in (-1, 1):
            for x in (-1.8, 0.0, 1.8):
                v, f = M.box(0.9, 0.1, 0.22,
                             center=(x, sy * (d * 0.5 + 0.03), lift + h - 0.9))
                mb.add(v, f, "iron_dark")

    K.door(mb, center=(0, -d * 0.5 - 0.05, lift + 0.12), width=1.5,
           height=2.2, material="timber_dark")
    K.stairs(mb, 1.8, lift + 0.12, 1.5, steps=4,
             center=(0, -d * 0.5 - 0.75, 0), material="timber_light")

    top = lift + 0.12 + h
    roof_h = K.roof_gable(mb, w, d, top, pitch=0.52, material="roof_tile_red",
                          wall_material="timber_light", overhang=0.45,
                          ridge_along_x=False)
    K.roof_ridge_beam(mb, d + 1.0, top + roof_h, along_x=False)

    # Hoist beam projecting over the loading door.
    with mb.detail(1):
        v, f = M.box(0.18, 2.0, 0.18,
                     center=(0, -d * 0.5 - 0.6, top + roof_h * 0.55))
        mb.add(v, f, "timber_dark")
    with mb.detail(2):
        v, f = M.box(0.06, 0.06, 0.9,
                     center=(0, -d * 0.5 - 1.3, top + roof_h * 0.55 - 0.9))
        mb.add(v, f, "iron_dark")

    a = Asset("granary", "building", mb, (w, d))
    a.attach("att_entrance", (0.0, -d * 0.5 - 2.2, 0.0))
    a.attach("att_cart_bay", (2.0, -d * 0.5 - 2.4, 0.0))
    # Sacks stacked under the hoist, so a full granary looks full.
    a.attach("att_stock_0", (-1.7, -d * 0.5 - 1.5, 0.0))
    a.attach("att_stock_1", (1.7, -d * 0.5 - 1.5, 0.0))
    return a.center_footprint()


# --------------------------------------------------------------------------
# Production
# --------------------------------------------------------------------------

def logging_camp() -> Asset:
    """Open-sided woodcutters' shelter with a saw pit and stacked timber."""
    mb = M.MeshBuilder("logging_camp")
    w, d = 8.0, 7.0

    # Trodden earth pad.
    v, f = M.box(w, d, 0.1, center=(0, 0, -0.05))
    mb.add(v, f, "soil_dark")

    # Shelter: back wall + shed roof on posts, open to the front.
    sw, sd, sh = 5.4, 3.6, 2.7
    K.wall_box(mb, sw, 0.28, sh, material="timber_light",
               center=(-0.8, d * 0.5 - 0.3, 0.05))
    K.wall_box(mb, 0.28, sd, sh, material="timber_light",
               center=(-0.8 - sw * 0.5, d * 0.5 - 0.3 - sd * 0.5, 0.05))
    for sx in (-1, 1):
        K.post(mb, center=(-0.8 + sx * (sw * 0.5 - 0.15),
                           d * 0.5 - sd - 0.2, 0.05), height=sh - 0.55)
    K.roof_shed(mb, sw + 0.5, sd + 0.5, sh - 0.55, sh,
                center=(-0.8, d * 0.5 - 0.3 - sd * 0.5, 0.05),
                material="thatch", overhang=0.3)

    # Sawhorse with a log on it.
    for sy in (-1, 1):
        for sx in (-1, 1):
            tf = M.xform(location=(1.2 + sx * 0.55, -1.4 + sy * 0.7, 0.0),
                         rotation_y=math.radians(14) * sx)
            v, f = M.box(0.1, 0.1, 0.85, center=(0, 0, 0))
            mb.add(v, f, "timber_dark", transform=tf)
    v, f = M.cylinder(0.22, 2.2, segments=8, center=(0, 0, -1.1))
    mb.add(v, f, "timber_light",
           transform=M.xform(location=(1.2, -1.4, 0.95), rotation_y=math.pi / 2),
           smooth=True)

    # Chopping block with an axe buried in it.
    v, f = M.cylinder(0.42, 0.65, segments=9, center=(-2.6, -1.8, 0.0))
    mb.add(v, f, "timber_light", smooth=True)
    tf = M.xform(location=(-2.6, -1.8, 0.62), rotation_y=math.radians(28))
    v, f = M.box(0.05, 0.05, 0.85, center=(0, 0, 0))
    mb.add(v, f, "timber_dark", transform=tf)
    v, f = M.box(0.07, 0.24, 0.26, center=(0, 0, 0.8))
    mb.add(v, f, "iron_dark", transform=tf)

    rng = random.Random(19)
    K.log_stack(mb, center=(-0.8, d * 0.5 - 1.4, 0.05), rows=3, cols=4,
                log_r=0.16, length=4.4, rng=rng)
    K.log_stack(mb, center=(3.0, 1.4, 0.0), rows=2, cols=3, log_r=0.15,
                length=2.6, rng=rng)

    a = Asset("logging_camp", "building", mb, (w, d))
    a.attach("att_entrance", (0.0, -d * 0.5 - 1.2, 0.0))
    a.attach("att_worksite", (1.2, -2.6, 0.0))
    a.attach("att_cart_bay", (3.0, -d * 0.5 - 1.2, 0.0))
    a.attach("att_stock_0", (3.0, 1.4, 0.0))
    return a


def quarry() -> Asset:
    """A cut stone face, a timber derrick, and a yard of dressed blocks."""
    mb = M.MeshBuilder("quarry")
    w, d = 10.0, 9.0
    rng = random.Random(41)

    v, f = M.box(w, d, 0.1, center=(0, 0, -0.05))
    mb.add(v, f, "soil_dark")

    # Stepped rock face along the back.
    for i, (hz, inset) in enumerate([(2.6, 0.0), (1.7, 1.1), (0.9, 2.1)]):
        v, f = M.box(w - i * 1.2, 1.3, hz,
                     center=(0, d * 0.5 - 0.7 - inset, 0.0), taper=0.97)
        mb.add(v, f, "stone_grey")
    with mb.detail(2):
        # Dressed blocks lying in the yard. Two things were wrong with this.
        #
        # The block was authored at (x, y) and then handed a *bare* rotation,
        # which swings it around the world origin rather than around itself:
        # three of the seven ended up inside the rock face and the rest were
        # flung out to the front lip of the pad. Every other scatter in the kit
        # — stone_node_01, iron_node_01, stone_pile, the mine — authors at the
        # origin and passes the position through the transform, and so does
        # this one now.
        #
        # And the band the blocks are drawn in ran from y 0.18 to 2.88, while
        # the lowest step of the rock face begins at y 1.05. Merely fixing the
        # rotation would therefore have buried six of the seven instead of
        # three. The yard is the ground *in front* of the face, so that is
        # where they go.
        for i in range(7):
            x = rng.uniform(-w * 0.45, w * 0.45)
            y = rng.uniform(-d * 0.34, d * 0.06)
            s = rng.uniform(0.35, 0.8)
            taper = rng.uniform(0.5, 0.85)
            angle = rng.uniform(0, math.pi)
            v, f = M.box(s, s * 0.9, s * 0.7, center=(0, 0, 0.0), taper=taper)
            mb.add(v, f, "stone_grey",
                   transform=M.xform(location=(x, y, 0.0), rotation_z=angle))

    # Derrick crane. The mast and jib are the quarry's landmark; the tackle
    # hanging off them is not.
    base = (-2.4, -1.2, 0.0)
    K.post(mb, center=base, height=4.2, thickness=0.28)
    for a_deg in (30, 150, 270):
        a_rad = math.radians(a_deg)
        tf = M.xform(location=(base[0] + math.cos(a_rad) * 0.9,
                               base[1] + math.sin(a_rad) * 0.9, 0.0),
                     rotation_z=a_rad + math.pi, rotation_y=math.radians(-22))
        v, f = M.box(0.14, 0.14, 4.2, center=(0, 0, 0))
        mb.add(v, f, "timber_dark", transform=tf, detail=1)
    tf = M.xform(location=(base[0], base[1], base[2] + 3.9),
                 rotation_y=math.radians(64))
    v, f = M.box(0.16, 0.16, 3.6, center=(0, 0, 0))
    mb.add(v, f, "timber_dark", transform=tf)
    with mb.detail(2):
        v, f = M.box(0.05, 0.05, 1.5, center=(0.7, -1.2, 2.0))
        mb.add(v, f, "iron_dark")
        v, f = M.box(0.55, 0.55, 0.45, center=(0.7, -1.2, 1.55))
        mb.add(v, f, "stone_grey")

    # Dressed blocks stacked in the yard.
    with mb.detail(1):
        for i, (bx, by, n) in enumerate([(2.9, -2.2, 3), (4.0, 0.4, 2)]):
            for j in range(n):
                v, f = M.box(1.1, 0.85, 0.55, center=(bx, by, j * 0.55))
                mb.add(v, f, "stone_grey")

    # Tool shed.
    K.wall_box(mb, 2.4, 2.0, 2.0, material="timber_light",
               center=(-w * 0.5 + 1.6, -d * 0.5 + 1.4, 0.0))
    K.roof_shed(mb, 2.6, 2.2, 2.0, 2.45,
                center=(-w * 0.5 + 1.6, -d * 0.5 + 1.4, 0.0),
                material="roof_slate")

    a = Asset("quarry", "building", mb, (w, d))
    a.attach("att_entrance", (0.0, -d * 0.5 - 1.2, 0.0))
    a.attach("att_worksite", (0.4, 1.6, 0.0))
    a.attach("att_cart_bay", (3.4, -d * 0.5 - 1.2, 0.0))
    a.attach("att_stock_0", (2.9, -2.2, 0.0))
    return a


def farmhouse() -> Asset:
    """Farmstead: dwelling with an attached byre and a fenced yard."""
    mb = M.MeshBuilder("farmhouse")
    w, d = 10.0, 7.5
    h = 2.9

    K.foundation(mb, 6.2, d, 0.3, center=(-1.6, 0, 0))
    K.stone_socle(mb, 6.4, d + 0.2, 0.6, center=(-1.6, 0, 0.08))
    K.wall_box(mb, 6.2, d, h, material="plaster_warm", center=(-1.6, 0, 0.1))
    K.timber_frame(mb, 6.2, d, h, center=(-1.6, 0, 0.1), posts=3)
    K.door(mb, center=(-2.6, -d * 0.5 - 0.05, 0.1), width=0.95, height=1.95)
    K.window(mb, center=(-0.4, -d * 0.5 - 0.04, 1.35), width=0.75, height=0.8,
             shutters=True)
    roof_h = K.roof_thatch(mb, 6.2, d, h + 0.1, pitch=0.52, overhang=0.36,
                           center=(-1.6, 0, 0))
    smoke = K.chimney(mb, center=(-4.0, 1.2, h + 0.1), height=2.2, width=0.62,
                      material="stone_grey",
                      min_top=h + 0.1 + roof_h + 0.7)

    # Byre: lower, open-fronted, tucked against the house.
    bw, bd, bh = 4.2, 5.0, 2.2
    bx, by = 3.5, 0.6
    K.wall_box(mb, bw, 0.25, bh, material="timber_light",
               center=(bx, by + bd * 0.5, 0.05))
    for sx in (-1, 1):
        K.wall_box(mb, 0.25, bd, bh, material="timber_light",
                   center=(bx + sx * bw * 0.5, by, 0.05))
    for sx in (-1, 1):
        K.post(mb, center=(bx + sx * (bw * 0.5 - 0.3), by - bd * 0.5 + 0.2, 0.05),
               height=bh - 0.3)
    K.roof_shed(mb, bw + 0.6, bd + 0.6, bh - 0.55, bh + 0.02,
                center=(bx, by, 0.05), material="thatch", overhang=0.35)

    K.fence_run(mb, (-w * 0.5 + 0.5, -d * 0.5 - 2.0, 0),
                (w * 0.5, -d * 0.5 - 2.0, 0), height=0.95)
    K.fence_run(mb, (w * 0.5, -d * 0.5 - 2.0, 0), (w * 0.5, by - bd * 0.5, 0),
                height=0.95)

    rng = random.Random(23)
    K.barrel_shape(mb, center=(-4.6, -d * 0.5 - 0.9, 0.0),
                   hoop_material="timber_dark")
    K.log_stack(mb, center=(1.2, d * 0.5 - 1.0, 0.0), rows=2, cols=3,
                log_r=0.12, length=1.4, rng=rng)

    a = Asset("farmhouse", "building", mb, (w, d + 2.0))
    a.attach("att_entrance", (-2.6, -d * 0.5 - 1.5, 0.0))
    a.attach("att_worksite", (3.5, -d * 0.5 - 0.6, 0.0))
    a.attach("att_cart_bay", (1.0, -d * 0.5 - 2.6, 0.0))
    a.attach("att_smoke", smoke)
    # The harvest, stacked in the yard between the house and the byre.
    a.attach("att_stock_0", (0.9, -d * 0.5 - 0.9, 0.0))
    a.attach("att_stock_1", (2.2, -d * 0.5 - 0.9, 0.0))
    a.attach("att_smoke", smoke)
    return a


def mine() -> Asset:
    """An adit driven into an ore outcrop: headframe, spoil heap, ore carts."""
    mb = M.MeshBuilder("mine")
    w, d = 8.5, 8.0
    rng = random.Random(71)

    v, f = M.box(w, d, 0.1, center=(0, 0, -0.05))
    mb.add(v, f, "soil_dark")

    # The cut face and the timbered adit mouth.
    v, f = M.box(w - 1.0, 1.6, 3.2, center=(0, d * 0.5 - 0.8, 0.0), taper=0.94)
    mb.add(v, f, "stone_dark")
    for sx in (-1, 1):
        K.post(mb, center=(sx * 1.1, d * 0.5 - 1.6, 0.0), height=2.3,
               thickness=0.26, detail=1)
    mb.add(*M.box(2.9, 0.3, 0.32, center=(0, d * 0.5 - 1.6, 2.3)),
           "timber_dark", detail=1)
    mb.add(*M.box(2.2, 0.6, 2.2, center=(0, d * 0.5 - 1.0, 0.0)), "soil_dark")

    # Headframe over the shaft. The legs and deck carry the silhouette; the
    # winding gear is detail that stops reading well before it stops costing.
    for sx in (-1, 1):
        for sy in (-1, 1):
            tf = M.xform(location=(sx * 1.0, sy * 1.0 - 1.4, 0.0),
                         rotation_z=math.atan2(sy, sx),
                         rotation_y=math.radians(9))
            mb.add(*M.box(0.18, 0.18, 4.2, center=(0, 0, 0)),
                   "timber_dark", transform=tf)
    mb.add(*M.box(2.4, 2.4, 0.22, center=(0, -1.4, 4.1)), "timber_dark")
    with mb.detail(2):
        mb.add(*M.cylinder(0.42, 0.5, segments=9, center=(0, -1.4, 4.3)),
               "iron_dark", smooth=True)
        mb.add(*M.box(0.07, 0.07, 2.4, center=(0, -1.4, 1.6)), "iron_dark")

    # Spoil, ore and a shelter.
    with mb.detail(1):
        for i in range(7):
            a = rng.uniform(0, math.tau)
            dist = rng.uniform(0.4, 2.4)
            sz = rng.uniform(0.3, 0.7)
            mb.add(*M.box(sz, sz, sz * 0.7,
                          center=(-2.6 + math.cos(a) * dist,
                                  1.4 + math.sin(a) * dist, 0.0), taper=0.6),
                   "stone_dark")
    with mb.detail(2):
        for i in range(4):
            mb.add(*M.box(0.4, 0.34, 0.26,
                          center=(2.6 + (i % 2) * 0.5, -1.0 - (i // 2) * 0.45,
                                  (i // 2) * 0.26)), "brick_red")
    K.wall_box(mb, 2.4, 2.0, 2.0, material="timber_light",
               center=(-w * 0.5 + 1.5, -d * 0.5 + 1.3, 0.0))
    K.roof_shed(mb, 2.6, 2.2, 2.0, 2.45,
                center=(-w * 0.5 + 1.5, -d * 0.5 + 1.3, 0.0),
                material="roof_slate")

    a = Asset("mine", "building", mb, (w, d))
    a.attach("att_entrance", (0.0, -d * 0.5 - 1.2, 0.0))
    a.attach("att_worksite", (0.0, d * 0.5 - 2.4, 0.0))
    a.attach("att_cart_bay", (3.0, -d * 0.5 - 1.2, 0.0))
    a.attach("att_stock_0", (2.8, -1.2, 0.0))
    return a


def blacksmith() -> Asset:
    """A forge: stone furnace, chimney, covered work area, visible wood pile.

    This is the asset specification worked in section 5.1 of the design
    document, built to the letter — stone furnace, chimney, timber frame,
    covered exterior work area, visible wood pile.
    """
    mb = M.MeshBuilder("blacksmith")
    w, d, h = 8.0, 9.5, 3.2
    rng = random.Random(83)

    K.foundation(mb, w, d, 0.3, material="stone_dark")
    K.stone_socle(mb, w + 0.2, d + 0.2, 0.7, center=(0, 0, 0.08),
                  material="stone_dark")
    K.wall_box(mb, w, d, h, material="plaster_warm", center=(0, 0, 0.1))
    K.timber_frame(mb, w, d, h, center=(0, 0, 0.1), posts=4, beam=0.18)

    K.door(mb, center=(-1.8, -d * 0.5 - 0.05, 0.1), width=1.1, height=2.1)
    K.window(mb, center=(1.6, -d * 0.5 - 0.04, 1.5), width=0.9, height=0.9,
             shutters=True)

    roof_h = K.roof_gable(mb, w, d, h + 0.1, pitch=0.5,
                          material="roof_tile_red", overhang=0.45)

    # Stone furnace against the gable wall, with its chimney.
    fx = w * 0.5 - 1.5
    mb.add(*M.box(2.2, 2.2, 2.0, center=(fx, d * 0.5 - 1.6, 0.1), taper=0.85),
           "stone_dark")
    mb.add(*M.box(1.0, 1.0, 0.7, center=(fx, d * 0.5 - 2.4, 0.3)), "iron_dark")
    smoke = K.chimney(mb, center=(fx, d * 0.5 - 1.6, 2.1), height=3.0,
                      width=0.95, material="stone_dark",
                      min_top=h + 0.1 + roof_h + 0.9)

    # Covered exterior work area, open to the front.
    K.awning(mb, 4.6, 2.6, 2.7, center=(0.6, -d * 0.5, 0.1), drop=0.5,
             material="roof_tile_red", facing="-y")
    # Anvil on its block, and a quench trough.
    mb.add(*M.cylinder(0.42, 0.6, segments=9, center=(0.2, -d * 0.5 - 1.3, 0.0)),
           "timber_light", smooth=True)
    mb.add(*M.box(0.7, 0.32, 0.3, center=(0.2, -d * 0.5 - 1.3, 0.6), taper=0.7),
           "iron_dark")
    K.barrel_shape(mb, center=(1.9, -d * 0.5 - 1.4, 0.0), radius=0.32,
                   height=0.8, hoop_material="iron_dark")

    K.log_stack(mb, center=(-w * 0.5 - 1.0, 1.0, 0.0), rows=3, cols=4,
                log_r=0.14, length=2.2, rng=rng)

    a = Asset("blacksmith", "building", mb, (w + 2.4, d + 3.0))
    a.attach("att_entrance", (-1.8, -d * 0.5 - 2.6, 0.0))
    a.attach("att_worksite", (0.2, -d * 0.5 - 2.0, 0.0))
    a.attach("att_cart_bay", (3.2, -d * 0.5 - 2.4, 0.0))
    a.attach("att_smoke", smoke)
    a.attach("att_stock_0", (-3.4, -2.6, 0.0))
    return a


def granary_large() -> Asset:
    """Grain warehouse: the granary grown up (design doc 6.4).

    Upgrades are meant to preserve the visible history of a settlement, so this
    is recognisably the same building — staddle stones, timber walls, tiled
    gable, hoist over the loading door — carrying another storey, a second
    hoist, and a loading stage wide enough for carts.
    """
    mb = M.MeshBuilder("granary_large")
    w, d = 8.6, 12.0
    lift = 1.15
    h = 6.6

    for sx in (-1, 0, 1):
        for sy in (-1.0, -0.34, 0.34, 1.0):
            x, y = sx * (w * 0.5 - 0.7), sy * (d * 0.5 - 0.7)
            tier = 0 if (sx and abs(sy) > 0.9) else 1
            v, f = M.cylinder(0.3, lift * 0.72, segments=8, center=(x, y, 0))
            mb.add(v, f, "stone_grey", smooth=True, detail=tier)
            v, f = M.cylinder(0.52, 0.22, segments=8,
                              center=(x, y, lift * 0.72), top_radius=0.46)
            mb.add(v, f, "stone_grey", smooth=True, detail=tier)

    v, f = M.box(w + 0.36, d + 0.36, 0.26, center=(0, 0, lift - 0.12))
    mb.add(v, f, "timber_dark")
    K.wall_box(mb, w, d, h, material="timber_light", center=(0, 0, lift + 0.14))
    K.timber_frame(mb, w, d, h * 0.52, center=(0, 0, lift + 0.14), posts=5,
                   beam=0.17, material="timber_dark")
    K.timber_frame(mb, w, d, h * 0.48, center=(0, 0, lift + 0.14 + h * 0.52),
                   posts=5, beam=0.17, material="timber_dark", mid_rail=False)
    K.string_course(mb, w, d, lift + 0.14 + h * 0.52, material="timber_dark",
                    thickness=0.22, proud=0.12)

    # Ventilation slits on both flanks, at both storeys.
    with mb.detail(2):
        for sy in (-1, 1):
            for z in (lift + h * 0.34, lift + h - 0.9):
                for x in (-2.4, 0.0, 2.4):
                    v, f = M.box(0.95, 0.1, 0.24,
                                 center=(x, sy * (d * 0.5 + 0.03), z))
                    mb.add(v, f, "iron_dark")

    K.door(mb, center=(0, -d * 0.5 - 0.05, lift + 0.14), width=1.8,
           height=2.4, material="timber_dark")
    # Loading stage: a cart backs onto it rather than to bare ground.
    mb.add(*M.box(4.4, 2.4, 0.22, center=(0, -d * 0.5 - 1.3, lift - 0.12)),
           "timber_light")
    with mb.detail(1):
        for sx in (-1, 1):
            K.post(mb, center=(sx * 1.9, -d * 0.5 - 2.3, 0.0), height=lift,
                   thickness=0.22, material="timber_dark")
    K.stairs(mb, 2.0, lift + 0.1, 1.6, steps=5,
             center=(2.9, -d * 0.5 - 1.4, 0), material="timber_light")

    top = lift + 0.14 + h
    roof_h = K.roof_gable(mb, w, d, top, pitch=0.54, material="roof_tile_red",
                          wall_material="timber_light", overhang=0.5,
                          ridge_along_x=False)
    K.roof_ridge_beam(mb, d + 1.1, top + roof_h, along_x=False)
    for t in (-0.26, 0.26):
        # This roof's ridge runs along -y, so the slope is in x: at 0.52 of the
        # half-width the tiles sit at 0.48 of the roof's height.
        K.dormer(mb, center=(t * w, -d * 0.16, top + roof_h * 0.48),
                 width=1.0, height=0.9, depth=0.9,
                 roof_material="roof_tile_red", wall_material="timber_light")

    # Twin hoists over the loading door.
    with mb.detail(1):
        for sx in (-1, 1):
            v, f = M.box(0.2, 2.2, 0.2,
                         center=(sx * 1.2, -d * 0.5 - 0.7, top + roof_h * 0.5))
            mb.add(v, f, "timber_dark")
    with mb.detail(2):
        for sx in (-1, 1):
            v, f = M.box(0.07, 0.07, 1.1,
                         center=(sx * 1.2, -d * 0.5 - 1.5,
                                 top + roof_h * 0.5 - 1.1))
            mb.add(v, f, "iron_dark")

    a = Asset("granary_large", "building", mb, (w + 1.2, d + 4.0))
    a.attach("att_entrance", (0.0, -d * 0.5 - 3.4, 0.0))
    a.attach("att_cart_bay", (2.6, -d * 0.5 - 3.4, 0.0))
    for i, (sx, sy) in enumerate(((-2.5, -0.6), (2.5, -0.6),
                                  (-2.5, 1.0), (2.5, 1.0))):
        a.attach("att_stock_%d" % i, (sx, -d * 0.5 - sy - 1.4, 0.0))
    return a


def forge() -> Asset:
    """Industrial forge: the blacksmith grown up (design doc 6.4).

    Same bones as the smithy — plastered frame, tiled gable, stone furnace
    against the far wall, covered work area at the front — with a second
    furnace, a taller double stack, a charcoal store and a trip hammer shed
    driven off the yard. It should read at a glance as the building that used
    to be the blacksmith.
    """
    mb = M.MeshBuilder("forge")
    w, d, h = 11.0, 12.0, 4.2
    rng = random.Random(97)

    K.foundation(mb, w, d, 0.34, material="stone_dark")
    K.stone_socle(mb, w + 0.24, d + 0.24, 1.0, center=(0, 0, 0.08),
                  material="stone_dark")
    K.wall_box(mb, w, d, h, material="plaster_warm", center=(0, 0, 0.1))
    K.timber_frame(mb, w, d, h, center=(0, 0, 0.1), posts=5, beam=0.2)
    K.quoins(mb, w, d, h, center=(0, 0, 0.1), block=0.5,
             material="stone_dark")

    K.door(mb, center=(-2.6, -d * 0.5 - 0.05, 0.1), width=1.3, height=2.3)
    K.window_row(mb, 2, 2.6, center=(1.6, -d * 0.5 - 0.04, 1.9),
                 width=0.9, height=1.0)
    K.window(mb, center=(-w * 0.5 - 0.04, 1.4, 1.9), width=0.9, height=1.0,
             facing="-x")

    roof_h = K.roof_gable(mb, w, d, h + 0.1, pitch=0.52,
                          material="roof_tile_red", overhang=0.5)
    for t in (-0.22, 0.22):
        # Seated on the slope: at 0.56 of the half-depth the tiles are at 0.44
        # of the roof's height, and a dormer placed lower than that is buried
        # in them rather than breaking through.
        K.dormer(mb, center=(w * t, -(d * 0.28), h + 0.1 + roof_h * 0.44),
                 width=1.1, height=0.95, depth=0.95,
                 roof_material="roof_tile_red", wall_material="plaster_warm")

    # Two stone furnaces against the back wall, under one double stack.
    smoke = None
    for i, fx in enumerate((-w * 0.5 + 2.2, w * 0.5 - 2.2)):
        mb.add(*M.box(2.6, 2.4, 2.4, center=(fx, d * 0.5 - 1.7, 0.1),
                      taper=0.86), "stone_dark")
        with mb.detail(2):
            mb.add(*M.box(1.2, 1.1, 0.8, center=(fx, d * 0.5 - 2.6, 0.35)),
                   "iron_dark")
        stack = K.chimney(mb, center=(fx, d * 0.5 - 1.7, 2.5), height=3.6,
                          width=1.1, material="stone_dark",
                          min_top=h + 0.1 + roof_h + 1.4)
        if i == 0:
            smoke = stack

    # Covered work area across the whole frontage.
    K.awning(mb, 7.6, 3.0, 3.1, center=(0.4, -d * 0.5, 0.1), drop=0.6,
             material="roof_tile_red", facing="-y")
    with mb.detail(1):
        for sx in (-1, 0, 1):
            K.post(mb, center=(0.4 + sx * 3.2, -d * 0.5 - 2.8, 0.0),
                   height=2.55, thickness=0.24, material="timber_dark")

    # Anvils, quench troughs and the trip hammer shed.
    with mb.detail(2):
        for ax in (-1.4, 1.8):
            mb.add(*M.cylinder(0.46, 0.66, segments=9,
                               center=(ax, -d * 0.5 - 1.5, 0.0)),
                   "timber_light", smooth=True)
            mb.add(*M.box(0.78, 0.34, 0.32,
                          center=(ax, -d * 0.5 - 1.5, 0.66), taper=0.7),
                   "iron_dark")
        K.barrel_shape(mb, center=(3.4, -d * 0.5 - 1.6, 0.0), radius=0.34,
                       height=0.86, hoop_material="iron_dark")

    K.wall_box(mb, 3.0, 2.6, 2.4, material="timber_light",
               center=(-w * 0.5 - 2.4, 2.0, 0.0))
    K.roof_shed(mb, 3.2, 2.8, 2.4, 3.0, center=(-w * 0.5 - 2.4, 2.0, 0.0),
                material="roof_tile_red")
    K.log_stack(mb, center=(-w * 0.5 - 2.4, -1.6, 0.0), rows=4, cols=4,
                log_r=0.15, length=2.4, rng=rng)

    a = Asset("forge", "building", mb, (w + 5.2, d + 4.0))
    a.attach("att_entrance", (-2.6, -d * 0.5 - 3.6, 0.0))
    a.attach("att_worksite", (0.4, -d * 0.5 - 2.2, 0.0))
    a.attach("att_cart_bay", (4.2, -d * 0.5 - 3.4, 0.0))
    a.attach("att_smoke", smoke)
    a.attach("att_stock_0", (4.4, -1.4, 0.0))
    a.attach("att_stock_1", (4.4, 1.2, 0.0))
    return a


BUILDINGS = {
    "mine": mine,
    "blacksmith": blacksmith,
    "keep_tier1": keep_tier1,
    "house_hovel": house_hovel,
    "house_small_02": house_small_02,
    "stockpile": stockpile,
    "logging_camp": logging_camp,
    "quarry": quarry,
    "farmhouse": farmhouse,
    "granary": granary,
    "granary_large": granary_large,
    "forge": forge,
}
