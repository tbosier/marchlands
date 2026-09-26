"""Citizen meshes.

Characters are the one asset type exported as a small node hierarchy rather
than a single merged mesh: the game animates them procedurally by rotating the
named limb nodes, which avoids an armature/skinning pipeline entirely while
still giving readable walk, carry and work motion.

Node layout (all pivots at the joint, all children of the asset root):

    torso   -- pivot at the hips
    head    -- pivot at the neck
    arm_l   -- pivot at the shoulder
    arm_r   -- pivot at the shoulder
    leg_l   -- pivot at the hip
    leg_r   -- pivot at the hip

Forms are faceted solids of revolution — tapered eight- and ten-sided limbs
and bodies, an ellipsoid head — rather than boxes: a box figure reads as a
robot at any distance, and a ten-sided tunic reads as cloth. Proportions are a
little sturdier than life (see HIP_Z) so a citizen stays readable when the
camera is pulled back over a whole town, within the style's grounded rule.

Six bodies, so a crowd is not one person repeated: three men (a capped
labourer, a bareheaded bearded man, a hooded one) and three women (a
headscarf, hair up in a bun with an apron, a long braid). `Citizen` picks one
from the draw it already makes, and tints the cloth of each.
"""

from __future__ import annotations

import math

from . import mesh as M
from .buildings import Asset

# Reference height from assets/specs/style.yaml.
HEIGHT = 1.75

HIP_Z = HEIGHT * 0.457
SHOULDER_Z = HEIGHT * 0.80
NECK_Z = HEIGHT * 0.823

# Which way a person faces. Buildings put their front at -Y, which the Y-up
# export turns into +Z in Godot; but a citizen *walks* towards its local -Z
# (`Citizen.face_towards`), so a person's face, toes and anything else that
# has a front are authored towards +Y here.
FRONT = 1.0

SEG = 10        # sides on a body or skirt
LIMB_SEG = 8    # sides on an arm or a leg


class CharacterAsset(Asset):
    """An Asset whose geometry is split across several named pivot parts."""

    def __init__(self, asset_id: str, parts: dict, footprint):
        # `builder` stays a merged copy so validation and LOD still work.
        merged = M.MeshBuilder(asset_id)
        for name, (builder, origin) in parts.items():
            merged.merge(builder, transform=M.xform(location=origin))
        super().__init__(asset_id, "character", merged, footprint)
        self.parts = parts


# --------------------------------------------------------------------------
# Shapes
# --------------------------------------------------------------------------

def _ellipsoid(mb: M.MeshBuilder, rx: float, ry: float, rz: float, center,
               material: str, segments: int = 10, rings: int = 6,
               smooth: bool = True, lower: float = 1.0):
    """A faceted ellipsoid. `lower` < 1 trims the bottom cap off (a skull
    that sits on a neck has no chin underneath it to model)."""
    cx, cy, cz = center
    verts = [(cx, cy, cz + rz)]
    for r in range(1, rings):
        phi = math.pi * r / rings
        if math.cos(phi) < -lower:
            break
        z = cz + rz * math.cos(phi)
        s = math.sin(phi)
        for i in range(segments):
            a = 2.0 * math.pi * i / segments
            verts.append((cx + rx * s * math.cos(a), cy + ry * s * math.sin(a), z))
    last_ring = (len(verts) - 1) // segments
    bottom = len(verts)
    bottom_z = verts[-1][2] if lower < 1.0 else cz - rz
    verts.append((cx, cy, bottom_z))
    faces = []
    for i in range(segments):
        faces.append((0, 1 + i, 1 + (i + 1) % segments))
    for r in range(last_ring - 1):
        a0 = 1 + r * segments
        b0 = 1 + (r + 1) * segments
        for i in range(segments):
            j = (i + 1) % segments
            faces.append((a0 + i, b0 + i, b0 + j, a0 + j))
    base = 1 + (last_ring - 1) * segments
    for i in range(segments):
        faces.append((base + (i + 1) % segments, base + i, bottom))
    mb.add(verts, faces, material, smooth=smooth)


def _frustum(mb: M.MeshBuilder, r_bottom: float, r_top: float, z0: float,
             height: float, material: str, depth: float = 1.0,
             segments: int = SEG, offset=(0.0, 0.0), smooth: bool = False):
    """A tapered solid of revolution from z0 up by `height`; `depth` squashes
    it front to back, since people are not round."""
    v, f = M.cylinder(r_bottom, height, segments=segments, center=(0, 0, 0),
                      top_radius=r_top)
    mb.add(v, f, material, smooth=smooth,
           transform=M.xform(location=(offset[0], offset[1], z0),
                             scale=(1.0, depth, 1.0)))


def _limb(name: str, length: float, top_r: float, bottom_r: float,
          upper: str, lower: str | None = None) -> M.MeshBuilder:
    """An arm or a leg hanging from a pivot at the local origin: an upper and
    a lower segment meeting at the knee or elbow at the same width."""
    mb = M.MeshBuilder(name)
    seg = length * 0.5
    joint = (top_r + bottom_r) * 0.5
    _frustum(mb, joint, top_r, -seg, seg, upper, depth=0.92, segments=LIMB_SEG)
    _frustum(mb, bottom_r, joint, -length, length - seg, lower or upper,
             depth=0.92, segments=LIMB_SEG)
    return mb


# --------------------------------------------------------------------------
# A person
# --------------------------------------------------------------------------

def _citizen(asset_id: str, *, skin: str, cloth: str, legwear: str,
             hair: str, shoulder_w: float, hip_w: float, dress: bool,
             headwear: str = "", beard: bool = False, apron: str = "",
             hairdo: str = "short") -> CharacterAsset:
    parts: dict = {}
    depth = 0.72
    hip_r = hip_w * 0.5
    shoulder_r = shoulder_w * 0.5

    # --- torso (pivot at hips) ---
    torso = M.MeshBuilder("torso")
    torso_h = SHOULDER_Z - HIP_Z
    # Hips to waist, then a chest that broadens to the shoulders and rounds
    # over them rather than stopping at a flat lid.
    _frustum(torso, hip_r, hip_r * 0.94, -0.02, 0.16, cloth, depth)
    _frustum(torso, hip_r * 0.94, shoulder_r, 0.14, torso_h - 0.18, cloth, depth)
    _frustum(torso, shoulder_r, shoulder_r * 0.55, torso_h - 0.04, 0.08,
             cloth, depth)
    # The skirt of the tunic, or of a dress to the ankle. Legs swing inside it.
    skirt_h = (HIP_Z - 0.10) if dress else 0.30
    skirt_r = hip_r * (1.5 if dress else 1.2)
    _frustum(torso, skirt_r, hip_r * 1.02, 0.10 - skirt_h, skirt_h, cloth,
             depth * (1.12 if dress else 1.02))
    # Hem: a slightly darker band makes the skirt's edge read.
    _frustum(torso, skirt_r * 1.02, skirt_r * 0.98, 0.10 - skirt_h, 0.035,
             legwear, depth * (1.14 if dress else 1.04))
    # Belt and buckle.
    _frustum(torso, hip_r * 1.05, hip_r * 1.05, 0.07, 0.045, "timber_dark", depth * 1.04)
    v, f = M.box(0.04, 0.012, 0.035, center=(0, FRONT * (hip_r * depth * 1.05 + 0.004), 0.075))
    torso.add(v, f, "iron_dark")
    if apron:
        # A work apron over the front of the skirt.
        v, f = M.box(hip_w * 0.85, 0.012, skirt_h * 0.8,
                     center=(0, FRONT * (hip_r * depth * 1.08 + 0.01), 0.1 - skirt_h * 0.82),
                     taper=0.82)
        torso.add(v, f, apron)
    # Neckline, in the skin colour, so the collar opens rather than seals.
    _frustum(torso, shoulder_r * 0.42, shoulder_r * 0.36, torso_h + 0.03, 0.03,
             skin, 0.8, segments=8)
    parts["torso"] = (torso, (0.0, 0.0, HIP_Z))

    # --- head (pivot at neck) ---
    head = M.MeshBuilder("head")
    _frustum(head, 0.05, 0.046, -0.02, 0.09, skin, 0.95, segments=8)       # neck
    hc = 0.165                                                             # head centre
    rx, ry, rz = 0.1, 0.108, 0.125
    _ellipsoid(head, rx, ry, rz, (0, 0, hc), skin)
    # Jaw: the head narrows towards the chin.
    _ellipsoid(head, rx * 0.82, ry * 0.8, rz * 0.5, (0, FRONT * 0.018, hc - 0.07), skin,
               segments=8, rings=4)
    face = FRONT * ry
    # Nose.
    v, f = M.box(0.028, 0.03, 0.05, center=(0, face + FRONT * 0.012, hc - 0.03), taper=0.7)
    head.add(v, f, skin)
    # Eyes: two small dark marks are what make a head a face.
    for sx in (-1, 1):
        v, f = M.box(0.02, 0.008, 0.016, center=(sx * 0.038, face - FRONT * 0.012, hc + 0.012))
        head.add(v, f, "iron_dark")
    # Ears.
    for sx in (-1, 1):
        v, f = M.box(0.018, 0.035, 0.05, center=(sx * rx * 0.98, 0.0, hc - 0.01))
        head.add(v, f, skin)
    # Hair: a cap of it over the crown and down the back.
    if headwear != "hood":
        _ellipsoid(head, rx * 1.06, ry * 1.05, rz * 0.8, (0, -FRONT * 0.012, hc + 0.035),
                   hair, lower=0.25)
    if hairdo == "bun":
        _ellipsoid(head, 0.05, 0.05, 0.045, (0, -FRONT * (ry + 0.02), hc + 0.07), hair,
                   segments=8, rings=4)
    elif hairdo == "braid":
        for k in range(4):
            _ellipsoid(head, 0.03, 0.03, 0.04,
                       (0, -FRONT * (ry + 0.005), hc - 0.06 - k * 0.07), hair,
                       segments=6, rings=4)
    if beard:
        _ellipsoid(head, rx * 0.78, ry * 0.5, rz * 0.42, (0, FRONT * (ry * 0.62), hc - 0.085),
                   hair, segments=8, rings=4)
    top = hc + rz
    if headwear == "cap":
        # A soft felt cap with a brim.
        _frustum(head, rx * 1.1, rx * 0.8, top - 0.06, 0.08, "fabric_muted", ry / rx)
        _frustum(head, rx * 1.45, rx * 1.4, top - 0.055, 0.016, "fabric_muted", ry / rx,
                 offset=(0, FRONT * 0.012))
    elif headwear == "scarf":
        # A headscarf over the crown, knotted at the nape.
        _ellipsoid(head, rx * 1.12, ry * 1.12, rz * 0.9, (0, -FRONT * 0.008, hc + 0.03),
                   "fabric_muted", lower=0.2)
        _ellipsoid(head, 0.04, 0.03, 0.05, (0, -FRONT * (ry + 0.025), hc - 0.05),
                   "fabric_muted", segments=6, rings=4)
    elif headwear == "hood":
        # A hood that frames the face and falls to the shoulders.
        _ellipsoid(head, rx * 1.28, ry * 1.25, rz * 1.12, (0, -FRONT * 0.02, hc + 0.015),
                   "fabric_muted", lower=0.45)
        _frustum(head, 0.19, 0.12, -0.05, 0.11, "fabric_muted", 0.85)
    parts["head"] = (head, (0.0, 0.0, NECK_Z))

    # --- arms (pivot at shoulder) ---
    arm_len = 0.56
    for side, sx in (("arm_l", -1), ("arm_r", 1)):
        arm = _limb(side, arm_len, 0.062, 0.046, cloth)
        # Shoulder: a cap that sinks into the body, so the arm grows out of
        # the torso instead of hanging beside it like a doll's.
        _ellipsoid(arm, 0.08, 0.075, 0.08, (-sx * 0.012, 0, -0.005), cloth, segments=8, rings=5)
        # Cuff.
        _frustum(arm, 0.05, 0.05, -arm_len + 0.02, 0.03, legwear, 0.92, segments=LIMB_SEG)
        # Hand.
        _ellipsoid(arm, 0.042, 0.036, 0.058, (0, FRONT * 0.004, -arm_len - 0.045), skin,
                   segments=8, rings=4)
        # Hung from inside the shoulder line and below its top: pivots set out
        # at the shoulder's full width left the sleeve standing clear of the
        # body with its top above the shoulder, like a shoulder pad.
        parts[side] = (arm, (sx * (shoulder_w * 0.5 - 0.01), 0.0, SHOULDER_Z - 0.09))

    # --- legs (pivot at hip) ---
    boot_h = 0.11
    leg_len = HIP_Z - boot_h
    for side, sx in (("leg_l", -1), ("leg_r", 1)):
        leg = _limb(side, leg_len, 0.078, 0.055, legwear)
        # Boot: a shaft up the ankle and a foot that points forward.
        _frustum(leg, 0.058, 0.06, -leg_len - boot_h + 0.03, boot_h, "timber_dark", 0.95,
                 segments=LIMB_SEG)
        v, f = M.box(0.1, 0.19, 0.06, center=(0, FRONT * 0.045, -leg_len - boot_h), taper=0.85)
        leg.add(v, f, "timber_dark")
        parts[side] = (leg, (sx * hip_w * 0.27, 0.0, HIP_Z))

    return CharacterAsset(asset_id, parts, (0.6, 0.5))


def citizen_male_base() -> CharacterAsset:
    return _citizen("citizen_male_base", skin="skin_light", cloth="fabric_muted",
                    legwear="timber_dark", hair="timber_dark", shoulder_w=0.46,
                    hip_w=0.36, dress=False, headwear="cap")


def citizen_male_02() -> CharacterAsset:
    return _citizen("citizen_male_02", skin="skin_mid", cloth="brick_red",
                    legwear="timber_dark", hair="grain_gold", shoulder_w=0.47,
                    hip_w=0.37, dress=False, beard=True)


def citizen_male_03() -> CharacterAsset:
    return _citizen("citizen_male_03", skin="skin_light", cloth="timber_light",
                    legwear="timber_dark", hair="timber_dark", shoulder_w=0.45,
                    hip_w=0.36, dress=False, headwear="hood")


def citizen_female_base() -> CharacterAsset:
    return _citizen("citizen_female_base", skin="skin_mid", cloth="brick_red",
                    legwear="timber_dark", hair="timber_dark", shoulder_w=0.40,
                    hip_w=0.34, dress=True, headwear="scarf")


def citizen_female_02() -> CharacterAsset:
    return _citizen("citizen_female_02", skin="skin_light", cloth="fabric_muted",
                    legwear="timber_dark", hair="timber_dark", shoulder_w=0.39,
                    hip_w=0.34, dress=True, apron="timber_light", hairdo="bun")


def citizen_female_03() -> CharacterAsset:
    return _citizen("citizen_female_03", skin="skin_light", cloth="timber_light",
                    legwear="timber_dark", hair="grain_gold", shoulder_w=0.40,
                    hip_w=0.35, dress=True, hairdo="braid")


CHARACTERS = {
    "citizen_male_base": citizen_male_base,
    "citizen_male_02": citizen_male_02,
    "citizen_male_03": citizen_male_03,
    "citizen_female_base": citizen_female_base,
    "citizen_female_02": citizen_female_02,
    "citizen_female_03": citizen_female_03,
}
