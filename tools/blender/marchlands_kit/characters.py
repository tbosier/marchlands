"""Citizen base meshes.

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

Proportions are slightly stylised (larger head, simplified hands) so a citizen
stays readable when the camera is pulled back over a whole town.
"""

from __future__ import annotations

import math

from . import mesh as M
from .buildings import Asset

# Reference height from assets/specs/style.yaml.
HEIGHT = 1.75

HIP_Z = HEIGHT * 0.50
SHOULDER_Z = HEIGHT * 0.82
NECK_Z = HEIGHT * 0.86


class CharacterAsset(Asset):
    """An Asset whose geometry is split across several named pivot parts."""

    def __init__(self, asset_id: str, parts: dict, footprint):
        # `builder` stays a merged copy so validation and LOD still work.
        merged = M.MeshBuilder(asset_id)
        for name, (builder, origin) in parts.items():
            merged.merge(builder, transform=M.xform(location=origin))
        super().__init__(asset_id, "character", merged, footprint)
        self.parts = parts


def _limb(name: str, length: float, top_w: float, bottom_w: float,
          material: str, boot: str | None = None, boot_h: float = 0.0):
    """A limb hanging downward from a pivot at the local origin.

    Both segments are authored from the bottom up, because M.box scales its
    *top* face: the size passed in is the width at the low end of the box and
    `taper` is what has happened to it by the high end. A limb hangs downward,
    so the low end is the knee or the ankle and the high end is the hip or the
    knee — which is the reverse of how a limb is usually described, and the
    reverse of how this used to be written. The old code passed `bottom_w` as
    the taper of a box whose top is the *knee*, so every citizen's leg pinched
    in at the knee and flared back out at the boot. Characters are the declared
    scale reference for the whole library, so it is worth being exact.
    """
    mb = M.MeshBuilder(name)
    seg = length * 0.52
    # The joint in the middle. Both segments meet here at the same width, so
    # there is no step where the thigh becomes the calf.
    knee_w = top_w * 0.80
    # Thigh / upper arm: widest at the pivot, narrowing to the joint below it.
    v, f = M.box(knee_w, knee_w * 0.92, seg, center=(0, 0, -seg),
                 taper=top_w / max(knee_w, 1e-5))
    mb.add(v, f, material)
    # Calf / forearm: narrowest at the ankle or wrist, widening up to the joint.
    v, f = M.box(bottom_w, bottom_w * 0.93, length - seg,
                 center=(0, 0, -length), taper=knee_w / max(bottom_w, 1e-5))
    mb.add(v, f, material)
    if boot:
        v, f = M.box(bottom_w * 1.25, bottom_w * 2.0, boot_h,
                     center=(0, -bottom_w * 0.35, -length - boot_h))
        mb.add(v, f, boot)
    return mb


def _citizen(asset_id: str, skin: str, tunic: str, trouser: str,
             hat: bool, shoulder_w: float, hip_w: float) -> CharacterAsset:
    parts: dict = {}

    # --- torso (pivot at hips) ---
    torso = M.MeshBuilder("torso")
    torso_h = SHOULDER_Z - HIP_Z + 0.06
    v, f = M.box(hip_w, hip_w * 0.62, torso_h * 0.45, center=(0, 0, 0),
                 taper=1.06)
    torso.add(v, f, trouser)
    v, f = M.box(hip_w * 1.06, hip_w * 0.66, torso_h * 0.6,
                 center=(0, 0, torso_h * 0.44),
                 taper=shoulder_w / (hip_w * 1.06))
    torso.add(v, f, tunic)
    # Belt.
    v, f = M.box(hip_w * 1.1, hip_w * 0.7, 0.045, center=(0, 0, torso_h * 0.4))
    torso.add(v, f, "timber_dark")
    # Collar.
    v, f = M.box(shoulder_w * 0.55, hip_w * 0.5, 0.05,
                 center=(0, 0, torso_h * 1.02))
    torso.add(v, f, fabric_or(tunic))
    parts["torso"] = (torso, (0.0, 0.0, HIP_Z))

    # --- head (pivot at neck) ---
    head = M.MeshBuilder("head")
    hh = 0.215
    v, f = M.box(0.078, 0.07, 0.055, center=(0, 0, 0))
    head.add(v, f, skin)
    v, f = M.box(0.165, 0.155, hh, center=(0, 0, 0.05), taper=0.9)
    head.add(v, f, skin)
    # Hair / cap.
    if hat:
        v, f = M.box(0.19, 0.185, 0.065, center=(0, 0, 0.05 + hh - 0.02),
                     taper=0.8)
        head.add(v, f, "fabric_muted")
        v, f = M.box(0.21, 0.21, 0.02, center=(0, 0, 0.05 + hh - 0.035))
        head.add(v, f, "fabric_muted")
    else:
        v, f = M.box(0.175, 0.17, 0.075, center=(0, 0, 0.05 + hh - 0.055),
                     taper=0.88)
        head.add(v, f, "timber_dark")
    parts["head"] = (head, (0.0, 0.0, NECK_Z))

    # --- arms (pivot at shoulder) ---
    arm_len = 0.62
    for side, sx in (("arm_l", -1), ("arm_r", 1)):
        arm = _limb(side, arm_len, 0.088, 0.062, tunic)
        # Hand.
        v, f = M.box(0.075, 0.07, 0.085, center=(0, 0, -arm_len - 0.085))
        arm.add(v, f, skin)
        parts[side] = (arm, (sx * shoulder_w * 0.5, 0.0, SHOULDER_Z))

    # --- legs (pivot at hip) ---
    leg_len = HIP_Z - 0.075
    for side, sx in (("leg_l", -1), ("leg_r", 1)):
        leg = _limb(side, leg_len, 0.105, 0.075, trouser,
                    boot="timber_dark", boot_h=0.075)
        parts[side] = (leg, (sx * hip_w * 0.26, 0.0, HIP_Z))

    return CharacterAsset(asset_id, parts, (0.5, 0.4))


def fabric_or(material: str) -> str:
    return "fabric_muted" if material != "fabric_muted" else "timber_light"


def citizen_male_base() -> CharacterAsset:
    return _citizen("citizen_male_base", "skin_light", "fabric_muted",
                    "timber_dark", hat=True, shoulder_w=0.42, hip_w=0.34)


def citizen_female_base() -> CharacterAsset:
    return _citizen("citizen_female_base", "skin_mid", "brick_red",
                    "timber_dark", hat=False, shoulder_w=0.37, hip_w=0.32)


CHARACTERS = {
    "citizen_male_base": citizen_male_base,
    "citizen_female_base": citizen_female_base,
}
