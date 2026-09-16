"""The modular component kit every Marchlands building is assembled from.

Design doc section 5.2 asks for walls/ roofs/ doors/ windows/ chimneys/
supports/ awnings/ stairs/ foundations/ props as reusable pieces so an agent
can assemble buildings procedurally while keeping one art style. Each function
here writes into a MeshBuilder so a whole building ends up as a single mesh
with a handful of material slots.

Conventions (see assets/specs/style.yaml):
  * +Z is up, -Y is the building's front.
  * A component's `center` argument is its footprint centre at its base.
"""

from __future__ import annotations

import functools
import math
import random

from mathutils import Matrix, Vector

from . import mesh as M


# --------------------------------------------------------------------------
# LOD detail tiers
# --------------------------------------------------------------------------

def _tier(level: int):
    """Declare which LOD detail tier everything a kit helper adds belongs to.

    Tier 0 is silhouette (walls, roofs, chimneys), tier 1 is what still reads
    from across the settlement (frames, doors, windows), tier 2 is eye-level
    dressing (studs, shutters, fences, firewood). MeshBuilder.filtered() then
    builds each LOD by dropping whole tiers, which is the only simplification
    that survives on geometry this sparse — see MeshBuilder's docstring.

    The tier a helper declares is its default *in the role it usually plays*.
    A caller whose asset uses the piece differently overrides it with
    `detail=`: firewood stacked beside a cottage is dressing, but the log pile
    prop is nothing but firewood, so there it is tier 0. An enclosing
    `mb.detail()` scope still wins where it is higher, so wrapping a block can
    demote a component but never promote one.
    """
    def decorate(fn):
        @functools.wraps(fn)
        def wrapper(mb, *args, **kwargs):
            with mb.detail(kwargs.pop("detail", level)):
                return fn(mb, *args, **kwargs)
        return wrapper
    return decorate


# --------------------------------------------------------------------------
# Foundations
# --------------------------------------------------------------------------


@_tier(0)
def foundation(mb: M.MeshBuilder, width: float, depth: float,
               height: float = 0.35, material: str = "stone_grey",
               center=(0.0, 0.0, 0.0), inset: float = -0.12):
    """A stone plinth. Slightly larger than the walls so it reads as a base."""
    cx, cy, cz = center
    v, f = M.box(width - inset * 2, depth - inset * 2, height,
                 center=(cx, cy, cz - height * 0.35))
    mb.add(v, f, material)
    return height * 0.65


@_tier(0)
def stone_socle(mb: M.MeshBuilder, width: float, depth: float, height: float,
                material: str = "stone_grey", center=(0.0, 0.0, 0.0)):
    """A band of rough stonework at the bottom of a timber-framed wall."""
    cx, cy, cz = center
    v, f = M.box(width, depth, height, center=(cx, cy, cz))
    mb.add(v, f, material)


# --------------------------------------------------------------------------
# Walls
# --------------------------------------------------------------------------


@_tier(0)
def wall_box(mb: M.MeshBuilder, width: float, depth: float, height: float,
             material: str = "plaster_warm", center=(0.0, 0.0, 0.0),
             jetty: float = 0.0):
    """The main wall volume. `jetty` flares the upper storey outward."""
    cx, cy, cz = center
    if jetty <= 0.0:
        v, f = M.box(width, depth, height, center=(cx, cy, cz))
        mb.add(v, f, material)
    else:
        lower = height * 0.55
        v, f = M.box(width, depth, lower, center=(cx, cy, cz))
        mb.add(v, f, material)
        v, f = M.box(width + jetty * 2, depth + jetty * 2, height - lower,
                     center=(cx, cy, cz + lower))
        mb.add(v, f, material)


@_tier(1)
def timber_frame(mb: M.MeshBuilder, width: float, depth: float, height: float,
                 center=(0.0, 0.0, 0.0), material: str = "timber_dark",
                 beam: float = 0.18, posts: int = 3, braces: bool = True,
                 mid_rail: bool = True, jetty: float = 0.0):
    """Exposed half-timbering applied to the four faces of a wall box.

    Beams are shallow slabs pushed just proud of the plaster so the silhouette
    stays clean while the surface reads as a timber frame at play distance.
    """
    cx, cy, cz = center
    out = beam * 0.35

    def face(axis: str, sign: int, span: float, offset: float):
        # Corner posts + intermediate posts.
        for i in range(posts):
            t = -span * 0.5 + span * (i / max(1, posts - 1))
            if axis == "x":
                loc = (cx + t, cy + sign * (offset + out), cz)
                v, f = M.box(beam, beam, height, center=loc)
            else:
                loc = (cx + sign * (offset + out), cy + t, cz)
                v, f = M.box(beam, beam, height, center=loc)
            mb.add(v, f, material)

        # Sill, mid rail, wall plate.
        levels = [0.0, height - beam]
        if mid_rail:
            levels.insert(1, height * 0.5 - beam * 0.5)
        for lz in levels:
            if axis == "x":
                loc = (cx, cy + sign * (offset + out), cz + lz)
                v, f = M.box(span + beam, beam, beam, center=loc)
            else:
                loc = (cx + sign * (offset + out), cy, cz + lz)
                v, f = M.box(beam, span + beam, beam, center=loc)
            mb.add(v, f, material)

        if braces:
            bh = height * 0.42
            for s in (-1, 1):
                t = s * span * 0.30
                ang = math.radians(38) * -s
                if axis == "x":
                    tf = M.xform(location=(cx + t, cy + sign * (offset + out),
                                           cz + beam),
                                 rotation_y=ang)
                else:
                    tf = M.xform(location=(cx + sign * (offset + out), cy + t,
                                           cz + beam),
                                 rotation_x=-ang)
                v, f = M.box(beam * 0.8, beam * 0.8, bh,
                             center=(0, 0, 0))
                mb.add(v, f, material, transform=tf)

    ww = width + jetty * 2
    dd = depth + jetty * 2
    face("x", -1, ww * 0.92, dd * 0.5)
    face("x", 1, ww * 0.92, dd * 0.5)
    face("y", -1, dd * 0.92, ww * 0.5)
    face("y", 1, dd * 0.92, ww * 0.5)


@_tier(1)
def jetty_brackets(mb: M.MeshBuilder, width: float, depth: float, z: float,
                   jetty: float, center=(0.0, 0.0, 0.0),
                   material: str = "timber_dark"):
    """Diagonal corner brackets supporting an overhanging upper storey."""
    cx, cy, cz = center
    for sx in (-1, 1):
        for sy in (-1, 1):
            tf = M.xform(
                location=(cx + sx * width * 0.42, cy + sy * depth * 0.42,
                          cz + z - 0.55),
                rotation_z=math.atan2(sy, sx),
            )
            v, f = M.box(0.16, 0.16, 0.7, center=(0, 0, 0))
            mb.add(v, f, material, transform=tf @ Matrix.Rotation(
                math.radians(28), 4, "Y"))


# --------------------------------------------------------------------------
# Roofs
# --------------------------------------------------------------------------


@_tier(0)
def roof_gable(mb: M.MeshBuilder, width: float, depth: float,
               wall_height: float, pitch: float = 0.55,
               center=(0.0, 0.0, 0.0), material: str = "roof_tile_red",
               wall_material: str = "plaster_warm",
               overhang: float = 0.35, ridge_along_x: bool = True,
               thickness: float = 0.12):
    """Two-slope roof plus the triangular gable walls that close it."""
    cx, cy, cz = center
    span = depth if ridge_along_x else width
    height = span * pitch

    v, f = M.gable_roof(width, depth, height, overhang=overhang,
                        center=(cx, cy, cz + wall_height),
                        ridge_along_x=ridge_along_x)
    mb.add(v, f, material)

    # A thin under-shell gives the roof visible thickness at the eaves.
    v, f = M.gable_roof(width, depth, height * 0.97,
                        overhang=overhang - thickness,
                        center=(cx, cy, cz + wall_height - thickness),
                        ridge_along_x=ridge_along_x)
    mb.add(v, f, "timber_dark")

    # The gable walls close the ends the roof slopes *away* from: with the
    # ridge along X the roof falls in Y, so the open triangles are the X faces.
    if ridge_along_x:
        for sx in (-1, 1):
            v, f = M.gable_wall(depth, 0.001, height,
                                center=(cx + sx * width * 0.5, cy,
                                        cz + wall_height),
                                axis="x")
            mb.add(v, f, wall_material)
    else:
        for sy in (-1, 1):
            v, f = M.gable_wall(width, 0.001, height,
                                center=(cx, cy + sy * depth * 0.5,
                                        cz + wall_height),
                                axis="y")
            mb.add(v, f, wall_material)
    return height


@_tier(0)
def roof_hip(mb: M.MeshBuilder, width: float, depth: float, wall_height: float,
             pitch: float = 0.5, center=(0.0, 0.0, 0.0),
             material: str = "roof_slate", overhang: float = 0.3,
             ridge_fraction: float = 0.35):
    """Four-slope roof with a short ridge. Used for grander structures."""
    cx, cy, cz = center
    hw = width * 0.5 + overhang
    hd = depth * 0.5 + overhang
    h = min(width, depth) * pitch
    rx = width * ridge_fraction * 0.5
    z0 = cz + wall_height
    v = [
        (cx - hw, cy - hd, z0), (cx + hw, cy - hd, z0),
        (cx + hw, cy + hd, z0), (cx - hw, cy + hd, z0),
        (cx - rx, cy, z0 + h), (cx + rx, cy, z0 + h),
    ]
    f = [(0, 1, 5, 4), (2, 3, 4, 5), (0, 4, 3), (1, 2, 5)]
    mb.add(v, f, material)
    return h


@_tier(0)
def roof_shed(mb: M.MeshBuilder, width: float, depth: float, low: float,
              high: float, center=(0.0, 0.0, 0.0),
              material: str = "roof_tile_red", overhang: float = 0.25):
    """Single-slope roof for lean-tos, sheds and work shelters."""
    cx, cy, cz = center
    hw = width * 0.5 + overhang
    hd = depth * 0.5 + overhang
    v = [
        (cx - hw, cy - hd, cz + low), (cx + hw, cy - hd, cz + low),
        (cx + hw, cy + hd, cz + high), (cx - hw, cy + hd, cz + high),
        (cx - hw, cy - hd, cz + low - 0.1), (cx + hw, cy - hd, cz + low - 0.1),
        (cx + hw, cy + hd, cz + high - 0.1), (cx - hw, cy + hd, cz + high - 0.1),
    ]
    f = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2),
         (2, 6, 7, 3), (3, 7, 4, 0)]
    mb.add(v, f, material)


@_tier(0)
def roof_thatch(mb: M.MeshBuilder, width: float, depth: float,
                wall_height: float, center=(0.0, 0.0, 0.0),
                pitch: float = 0.55, overhang: float = 0.38):
    """Thick, heavy thatch: a steep gable with a chunky eave and ridge cap."""
    cx, cy, cz = center
    h = depth * pitch
    base = cz + wall_height

    v, f = M.gable_roof(width, depth, h, overhang=overhang, center=(cx, cy, base))
    mb.add(v, f, "thatch")

    # Chunky eave roll: thatch is a thick material and needs visible depth.
    for sy in (-1, 1):
        v, f = M.box(width + overhang * 2, 0.34, 0.30,
                     center=(cx, cy + sy * (depth * 0.5 + overhang - 0.13),
                             base - 0.16))
        mb.add(v, f, "thatch")
    for sx in (-1, 1):
        v, f = M.gable_wall(depth + overhang * 2, 0.001, h * 0.99,
                            center=(cx + sx * (width * 0.5 + overhang), cy, base),
                            axis="x")
        mb.add(v, f, "thatch")

    # Ridge cap: a slightly darker band along the apex.
    v, f = M.box(width + overhang * 2 - 0.1, 0.42, 0.2,
                 center=(cx, cy, base + h - 0.13), taper=0.75)
    mb.add(v, f, "thatch")
    for i in range(4):
        t = -0.36 + 0.24 * i
        v, f = M.box(0.06, 0.62, 0.1,
                     center=(cx + (width * 0.5 - 0.4) * (i - 1.5) / 1.5,
                             cy, base + h - 0.06))
        mb.add(v, f, "timber_light")
    return h


@_tier(1)
def roof_ridge_beam(mb: M.MeshBuilder, length: float, z: float,
                    center=(0.0, 0.0, 0.0), material: str = "timber_dark",
                    along_x: bool = True):
    cx, cy, cz = center
    if along_x:
        v, f = M.box(length, 0.14, 0.12, center=(cx, cy, cz + z))
    else:
        v, f = M.box(0.14, length, 0.12, center=(cx, cy, cz + z))
    mb.add(v, f, material)


# --------------------------------------------------------------------------
# Openings
# --------------------------------------------------------------------------


@_tier(1)
def door(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), width: float = 0.95,
         height: float = 1.95, facing: str = "-y",
         material: str = "timber_dark", frame_material: str = "timber_dark",
         depth: float = 0.1):
    """A door panel pressed into a wall face, with a surrounding frame."""
    cx, cy, cz = center
    fw = 0.12
    if facing in ("-y", "+y"):
        v, f = M.box(width, depth, height, center=(cx, cy, cz))
        mb.add(v, f, material)
        v, f = M.box(width + fw * 2, depth * 0.6, fw, center=(cx, cy, cz + height))
        mb.add(v, f, frame_material)
        for sx in (-1, 1):
            v, f = M.box(fw, depth * 0.6, height,
                         center=(cx + sx * (width * 0.5 + fw * 0.5), cy, cz))
            mb.add(v, f, frame_material)
    else:
        v, f = M.box(depth, width, height, center=(cx, cy, cz))
        mb.add(v, f, material)
        v, f = M.box(depth * 0.6, width + fw * 2, fw, center=(cx, cy, cz + height))
        mb.add(v, f, frame_material)
        for sy in (-1, 1):
            v, f = M.box(depth * 0.6, fw, height,
                         center=(cx, cy + sy * (width * 0.5 + fw * 0.5), cz))
            mb.add(v, f, frame_material)


@_tier(1)
def window(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), width: float = 0.7,
           height: float = 0.8, facing: str = "-y", depth: float = 0.08,
           shutters: bool = False, mullion: bool = True):
    cx, cy, cz = center
    fw = 0.09
    glass_d = depth * 0.5
    if facing in ("-y", "+y"):
        v, f = M.box(width, glass_d, height, center=(cx, cy, cz))
        mb.add(v, f, "glass")
        for sx in (-1, 1):
            v, f = M.box(fw, depth, height + fw * 2,
                         center=(cx + sx * (width * 0.5 + fw * 0.5), cy, cz - fw))
            mb.add(v, f, "timber_dark")
        for sz in (0.0, 1.0):
            v, f = M.box(width + fw * 2, depth, fw,
                         center=(cx, cy, cz - fw + sz * (height + fw)))
            mb.add(v, f, "timber_dark")
        if mullion:
            v, f = M.box(0.05, depth, height, center=(cx, cy, cz))
            mb.add(v, f, "timber_dark")
        if shutters:
            for sx in (-1, 1):
                v, f = M.box(width * 0.5, 0.05, height,
                             center=(cx + sx * (width * 0.75 + fw), cy - depth * 0.6, cz))
                mb.add(v, f, "timber_light")
    else:
        v, f = M.box(glass_d, width, height, center=(cx, cy, cz))
        mb.add(v, f, "glass")
        for sy in (-1, 1):
            v, f = M.box(depth, fw, height + fw * 2,
                         center=(cx, cy + sy * (width * 0.5 + fw * 0.5), cz - fw))
            mb.add(v, f, "timber_dark")
        for sz in (0.0, 1.0):
            v, f = M.box(depth, width + fw * 2, fw,
                         center=(cx, cy, cz - fw + sz * (height + fw)))
            mb.add(v, f, "timber_dark")
        if mullion:
            v, f = M.box(depth, 0.05, height, center=(cx, cy, cz))
            mb.add(v, f, "timber_dark")


@_tier(1)
def window_row(mb: M.MeshBuilder, count: int, spacing: float,
               center=(0.0, 0.0, 0.0), facing: str = "-y", **kwargs):
    cx, cy, cz = center
    start = -(count - 1) * spacing * 0.5
    for i in range(count):
        t = start + i * spacing
        if facing in ("-y", "+y"):
            window(mb, center=(cx + t, cy, cz), facing=facing, **kwargs)
        else:
            window(mb, center=(cx, cy + t, cz), facing=facing, **kwargs)


@_tier(1)
def arrow_slit(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), facing: str = "-y",
               height: float = 1.0):
    cx, cy, cz = center
    if facing in ("-y", "+y"):
        v, f = M.box(0.14, 0.12, height, center=(cx, cy, cz))
    else:
        v, f = M.box(0.12, 0.14, height, center=(cx, cy, cz))
    mb.add(v, f, "iron_dark")


# --------------------------------------------------------------------------
# Chimneys, supports, awnings, stairs
# --------------------------------------------------------------------------


@_tier(0)
def chimney(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), height: float = 2.4,
            width: float = 0.7, material: str = "brick_red",
            cap: bool = True, min_top: float | None = None,
            cap_material: str = "stone_dark"):
    """A chimney rising from `center`.

    `min_top` is the absolute Z the stack must clear — pass the roof ridge and
    the chimney will always read against the sky rather than vanishing into
    the thatch. Returns the smoke emitter position.
    """
    cx, cy, cz = center
    if min_top is not None:
        height = max(height, min_top - cz)
    v, f = M.box(width, width, height, center=(cx, cy, cz), taper=0.85)
    mb.add(v, f, material)
    if cap:
        v, f = M.box(width * 1.25, width * 1.25, 0.16,
                     center=(cx, cy, cz + height))
        mb.add(v, f, cap_material)
        v, f = M.box(width * 0.55, width * 0.55, 0.1,
                     center=(cx, cy, cz + height - 0.06))
        mb.add(v, f, material)
    return (cx, cy, cz + height + 0.25)


@_tier(0)
def post(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), height: float = 2.4,
         thickness: float = 0.18, material: str = "timber_dark"):
    cx, cy, cz = center
    v, f = M.box(thickness, thickness, height, center=(cx, cy, cz))
    mb.add(v, f, material)


@_tier(0)
def awning(mb: M.MeshBuilder, width: float, depth: float, z: float,
           center=(0.0, 0.0, 0.0), drop: float = 0.45,
           material: str = "roof_tile_red", posts: bool = True,
           facing: str = "-y"):
    """A covered exterior work area: a shed roof on two posts."""
    cx, cy, cz = center
    sign = -1 if facing == "-y" else 1
    y0 = cy
    y1 = cy + sign * depth
    v = [
        (cx - width * 0.5, y0, cz + z), (cx + width * 0.5, y0, cz + z),
        (cx + width * 0.5, y1, cz + z - drop),
        (cx - width * 0.5, y1, cz + z - drop),
        (cx - width * 0.5, y0, cz + z - 0.09),
        (cx + width * 0.5, y0, cz + z - 0.09),
        (cx + width * 0.5, y1, cz + z - drop - 0.09),
        (cx - width * 0.5, y1, cz + z - drop - 0.09),
    ]
    f = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2),
         (2, 6, 7, 3), (3, 7, 4, 0)]
    mb.add(v, f, material)
    if posts:
        for sx in (-1, 1):
            post(mb, center=(cx + sx * (width * 0.5 - 0.22), y1 - sign * 0.2, cz),
                 height=z - drop - 0.09)


@_tier(0)
def stairs(mb: M.MeshBuilder, width: float, rise: float, run: float,
           steps: int = 5, center=(0.0, 0.0, 0.0),
           material: str = "stone_grey", facing: str = "-y"):
    cx, cy, cz = center
    sign = -1 if facing == "-y" else 1
    step_h = rise / steps
    step_d = run / steps
    for i in range(steps):
        v, f = M.box(width, step_d * (steps - i), step_h * (i + 1),
                     center=(cx, cy + sign * (run * 0.5 - step_d * i * 0.5), cz))
        mb.add(v, f, material)


@_tier(0)
def buttress(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), height: float = 3.0,
             width: float = 0.8, depth: float = 0.7,
             material: str = "stone_grey"):
    cx, cy, cz = center
    v, f = M.box(width, depth, height * 0.7, center=(cx, cy, cz), taper=0.8)
    mb.add(v, f, material)
    v, f = M.box(width * 0.8, depth * 0.8, height * 0.3,
                 center=(cx, cy, cz + height * 0.7), taper=0.4)
    mb.add(v, f, material)


@_tier(0)
def crenellation(mb: M.MeshBuilder, width: float, depth: float, z: float,
                 center=(0.0, 0.0, 0.0), merlon: float = 0.55,
                 height: float = 0.7, thickness: float = 0.35,
                 material: str = "stone_grey"):
    """Battlements around a rectangular wall top."""
    cx, cy, cz = center

    def run(length: float, along_x: bool, offset: float):
        n = max(2, int(length / (merlon * 2)))
        step = length / n
        for i in range(n):
            t = -length * 0.5 + step * (i + 0.5)
            if along_x:
                loc = (cx + t, cy + offset, cz + z)
                v, f = M.box(step * 0.55, thickness, height, center=loc)
            else:
                loc = (cx + offset, cy + t, cz + z)
                v, f = M.box(thickness, step * 0.55, height, center=loc)
            mb.add(v, f, material)

    run(width, True, -depth * 0.5 + thickness * 0.5)
    run(width, True, depth * 0.5 - thickness * 0.5)
    run(depth - thickness * 2, False, -width * 0.5 + thickness * 0.5)
    run(depth - thickness * 2, False, width * 0.5 - thickness * 0.5)


@_tier(0)
def wall_walk(mb: M.MeshBuilder, width: float, depth: float, z: float,
              center=(0.0, 0.0, 0.0), thickness: float = 0.9,
              material: str = "stone_grey"):
    """The flat parapet walkway a crenellation sits on."""
    cx, cy, cz = center
    v, f = M.box(width + thickness * 0.6, depth + thickness * 0.6, 0.28,
                 center=(cx, cy, cz + z - 0.28))
    mb.add(v, f, material)


# --------------------------------------------------------------------------
# Small organic detail — the "life around the buildings" (design 2.2)
# --------------------------------------------------------------------------


@_tier(2)
def log_stack(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), rows: int = 3,
              cols: int = 4, log_r: float = 0.14, length: float = 1.6,
              rng: random.Random | None = None):
    """Horizontal logs stacked in a pyramid, lying along the X axis."""
    rng = rng or random.Random(11)
    cx, cy, cz = center
    for r in range(rows):
        n = max(1, cols - r)
        for c in range(n):
            y = cy + (c - (n - 1) * 0.5) * log_r * 2.05
            z = cz + log_r + r * log_r * 1.75
            v, f = M.cylinder(log_r * rng.uniform(0.9, 1.05), length,
                              segments=7, center=(0, 0, -length * 0.5))
            tf = M.xform(location=(cx, y, z), rotation_y=math.pi / 2)
            mb.add(v, f, "timber_light", transform=tf, smooth=False)


@_tier(2)
def fence_run(mb: M.MeshBuilder, start, end, height: float = 1.0,
              post_spacing: float = 1.6, material: str = "timber_light"):
    sx, sy, sz = start
    ex, ey, ez = end
    dx, dy = ex - sx, ey - sy
    length = math.hypot(dx, dy)
    if length < 1e-4:
        return
    ang = math.atan2(dy, dx)
    n = max(1, int(round(length / post_spacing)))
    for i in range(n + 1):
        t = i / n
        post(mb, center=(sx + dx * t, sy + dy * t, sz), height=height,
             thickness=0.1, material=material)
    for lz in (height * 0.4, height * 0.78):
        tf = M.xform(location=(sx + dx * 0.5, sy + dy * 0.5, sz + lz),
                     rotation_z=ang)
        v, f = M.box(length, 0.06, 0.09, center=(0, 0, 0))
        mb.add(v, f, material, transform=tf)


@_tier(2)
def barrel_shape(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0),
                 radius: float = 0.32, height: float = 0.8,
                 hoop_material: str = "iron_dark"):
    cx, cy, cz = center
    v, f = M.cylinder(radius * 0.86, height * 0.25, segments=10,
                      center=(cx, cy, cz))
    mb.add(v, f, "timber_light", smooth=True)
    v, f = M.cylinder(radius, height * 0.5, segments=10,
                      center=(cx, cy, cz + height * 0.25))
    mb.add(v, f, "timber_light", smooth=True)
    v, f = M.cylinder(radius * 0.86, height * 0.25, segments=10,
                      center=(cx, cy, cz + height * 0.75), top_radius=radius * 0.8)
    mb.add(v, f, "timber_light", smooth=True)
    for hz in (height * 0.28, height * 0.72):
        v, f = M.cylinder(radius * 1.02, 0.06, segments=10,
                          center=(cx, cy, cz + hz))
        mb.add(v, f, hoop_material, smooth=True)


@_tier(2)
def cart_wheel(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), radius: float = 0.42,
               width: float = 0.1, spokes: int = 6):
    """A wheel standing in the XZ plane (axle along Y)."""
    cx, cy, cz = center
    tf = M.xform(location=(cx, cy + width * 0.5, cz), rotation_x=math.pi / 2)
    v, f = M.cylinder(radius, width, segments=12, center=(0, 0, 0), capped=False)
    mb.add(v, f, "timber_dark", transform=tf, smooth=True)
    v, f = M.cylinder(radius * 0.88, width * 0.6, segments=12,
                      center=(0, 0, width * 0.2), capped=False)
    mb.add(v, f, "timber_light", transform=tf, smooth=True)
    for i in range(spokes):
        a = math.pi * i / spokes
        stf = tf @ M.xform(rotation_z=a)
        v, f = M.box(radius * 1.7, 0.06, width * 0.5, center=(0, 0, 0))
        mb.add(v, f, "timber_light", transform=stf)
    v, f = M.cylinder(0.1, width * 1.4, segments=8, center=(0, 0, -width * 0.2))
    mb.add(v, f, "iron_dark", transform=tf, smooth=True)


# --------------------------------------------------------------------------
# Stone architecture
#
# The pieces that stop a stone building reading as one undifferentiated slab.
# All of them work by breaking the wall plane: a corner that steps, a course
# that casts a shadow line, an opening with real depth.
# --------------------------------------------------------------------------


@_tier(1)
def quoins(mb: M.MeshBuilder, width: float, depth: float, height: float,
           center=(0.0, 0.0, 0.0), material: str = "stone_dark",
           block: float = 0.62, courses: int = 0, proud: float = 0.07):
    """Alternating dressed corner stones up all four corners.

    The cheapest way to make a wall look built rather than extruded: the eye
    reads the stepped corner as masonry even at a distance where no individual
    stone is legible.
    """
    cx, cy, cz = center
    courses = courses or max(3, int(height / (block * 1.35)))
    step = height / courses
    for sx in (-1, 1):
        for sy in (-1, 1):
            for i in range(courses):
                if i % 2 == 1:
                    continue
                long_x = (i // 2) % 2 == 0
                bx = block * (1.5 if long_x else 0.85)
                by = block * (0.85 if long_x else 1.5)
                mb.add(*M.box(
                    bx, by, step * 0.92,
                    center=(cx + sx * (width * 0.5 - bx * 0.5 + proud),
                            cy + sy * (depth * 0.5 - by * 0.5 + proud),
                            cz + i * step)), material)


@_tier(1)
def string_course(mb: M.MeshBuilder, width: float, depth: float, z: float,
                  center=(0.0, 0.0, 0.0), material: str = "stone_dark",
                  thickness: float = 0.3, proud: float = 0.2):
    """A moulded band right round a building, splitting the wall by storey."""
    cx, cy, cz = center
    for sy in (-1, 1):
        mb.add(*M.box(width + proud * 2, thickness, thickness * 0.85,
                      center=(cx, cy + sy * depth * 0.5, cz + z)), material)
    for sx in (-1, 1):
        mb.add(*M.box(thickness, depth + proud * 2, thickness * 0.85,
                      center=(cx + sx * width * 0.5, cy, cz + z)), material)


@_tier(1)
def machicolation(mb: M.MeshBuilder, width: float, depth: float, z: float,
                  center=(0.0, 0.0, 0.0), material: str = "stone_dark",
                  corbel: float = 0.26, spacing: float = 0.95):
    """The row of corbels that carries a parapet out past the wall face.

    This is the detail that reads as "castle" from furthest away, because it
    puts a broken line of shadow right under the battlements.
    """
    cx, cy, cz = center

    def run(length: float, along_x: bool, offset: float):
        n = max(2, int(length / spacing))
        step = length / n
        for i in range(n):
            t = -length * 0.5 + step * (i + 0.5)
            if along_x:
                loc = (cx + t, cy + offset, cz + z)
                size = (corbel, corbel * 1.6, corbel * 1.5)
            else:
                loc = (cx + offset, cy + t, cz + z)
                size = (corbel * 1.6, corbel, corbel * 1.5)
            mb.add(*M.box(size[0], size[1], size[2], center=loc,
                          taper=1.5), material)

    run(width, True, -depth * 0.5)
    run(width, True, depth * 0.5)
    run(depth, False, -width * 0.5)
    run(depth, False, width * 0.5)


@_tier(2)
def cross_loop(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), facing: str = "-y",
               height: float = 1.4, material: str = "stone_dark"):
    """A cross-shaped arrow loop set in a recessed panel."""
    cx, cy, cz = center
    out = 0.07
    if facing in ("-y", "+y"):
        sign = -1.0 if facing == "-y" else 1.0
        mb.add(*M.box(0.5, 0.1, height + 0.5,
                      center=(cx, cy + sign * out, cz)), material)
        mb.add(*M.box(0.11, 0.14, height,
                      center=(cx, cy + sign * out * 1.6, cz + 0.22)),
               "iron_dark")
        mb.add(*M.box(0.52, 0.14, 0.11,
                      center=(cx, cy + sign * out * 1.6, cz + height * 0.62)),
               "iron_dark")
    else:
        sign = -1.0 if facing == "-x" else 1.0
        mb.add(*M.box(0.1, 0.5, height + 0.5,
                      center=(cx + sign * out, cy, cz)), material)
        mb.add(*M.box(0.14, 0.11, height,
                      center=(cx + sign * out * 1.6, cy, cz + 0.22)),
               "iron_dark")
        mb.add(*M.box(0.14, 0.52, 0.11,
                      center=(cx + sign * out * 1.6, cy, cz + height * 0.62)),
               "iron_dark")


@_tier(1)
def hoarding(mb: M.MeshBuilder, width: float, z: float, y: float,
             center=(0.0, 0.0, 0.0), depth: float = 1.1, height: float = 1.6,
             facing: str = "-y"):
    """A timber fighting gallery hung off the wall head.

    Wartime carpentry bolted onto stone. It reads immediately as a castle that
    is garrisoned rather than a decorative one, and it breaks the roofline.
    """
    cx, cy, cz = center
    sign = -1.0 if facing == "-y" else 1.0
    far = cy + y + sign * depth

    mb.add(*M.box(width, depth, 0.16,
                  center=(cx, cy + y + sign * depth * 0.5, cz + z)),
           "timber_dark")
    mb.add(*M.box(width, 0.14, height,
                  center=(cx, far, cz + z + 0.16)), "timber_dark")
    for i in range(4):
        t = (i - 1.5) * width * 0.24
        mb.add(*M.box(0.16, 0.16, height,
                      center=(cx + t, far, cz + z + 0.16)), "timber_dark")
    # Shed roof over the gallery.
    v = [
        (cx - width * 0.5, cy + y, cz + z + height + 0.7),
        (cx + width * 0.5, cy + y, cz + z + height + 0.7),
        (cx + width * 0.5, far + sign * 0.25, cz + z + height + 0.1),
        (cx - width * 0.5, far + sign * 0.25, cz + z + height + 0.1),
    ]
    mb.add(v, [(0, 1, 2, 3)], "roof_slate")
    for i in range(3):
        t = (i - 1) * width * 0.33
        mb.add(*M.box(0.12, 0.12, height,
                      center=(cx + t, cy + y + sign * 0.1, cz + z + 0.16)),
               "timber_dark")


@_tier(1)
def dormer(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0), width: float = 1.0,
           height: float = 0.9, depth: float = 0.9,
           roof_material: str = "roof_slate",
           wall_material: str = "stone_grey"):
    """A small gabled window standing out of a roof slope."""
    cx, cy, cz = center
    mb.add(*M.box(width, depth, height, center=(cx, cy, cz)), wall_material)
    v, f = M.gable_roof(width + 0.24, depth + 0.16, width * 0.42,
                        overhang=0.06, center=(cx, cy, cz + height),
                        ridge_along_x=False)
    mb.add(v, f, roof_material)
    mb.add(*M.box(width * 0.5, 0.06, height * 0.55,
                  center=(cx, cy - depth * 0.5, cz + height * 0.3)), "glass")


@_tier(0)
def buttress_pilaster(mb: M.MeshBuilder, center=(0.0, 0.0, 0.0),
                      height: float = 6.0, width: float = 0.8,
                      proud: float = 0.35, material: str = "stone_grey",
                      facing: str = "-y"):
    """A flat pilaster strip: a buttress that barely leaves the wall, used to
    give a long elevation a vertical rhythm."""
    cx, cy, cz = center
    if facing in ("-y", "+y"):
        sign = -1.0 if facing == "-y" else 1.0
        mb.add(*M.box(width, proud, height,
                      center=(cx, cy + sign * proud * 0.5, cz)), material)
        mb.add(*M.box(width + 0.18, proud + 0.14, 0.22,
                      center=(cx, cy + sign * proud * 0.5, cz + height)),
               "stone_dark")
    else:
        sign = -1.0 if facing == "-x" else 1.0
        mb.add(*M.box(proud, width, height,
                      center=(cx + sign * proud * 0.5, cy, cz)), material)
        mb.add(*M.box(proud + 0.14, width + 0.18, 0.22,
                      center=(cx + sign * proud * 0.5, cy, cz + height)),
               "stone_dark")
