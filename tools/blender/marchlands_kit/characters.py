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

Proportions are sturdier than life (see HIP_Z) so a citizen stays readable
when the camera is pulled back over a whole town.
"""

from __future__ import annotations

import math

from . import mesh as M
from .buildings import Asset

# Reference height from assets/specs/style.yaml.
HEIGHT = 1.75

# Proportions for a camera that sits tens of metres up. A realistic figure —
# hips at half the height, 10 cm limbs, a 21 cm head — read from there as a
# stick insect: two pencil legs under a matchbox. These stay within the style's
# "grounded, no cartoon exaggeration" rule and are simply sturdier: the hips a
# little lower, thicker limbs, a head large enough to carry a face and a cap,
# and clothes with a shape — a tunic that flares over the thighs, a dress to
# the ankle — so the silhouette says "person" at a glance.
HIP_Z = HEIGHT * 0.457
SHOULDER_Z = HEIGHT * 0.80
NECK_Z = HEIGHT * 0.823

# Which way a person faces. Buildings put their front at -Y, which the Y-up
# export turns into +Z in Godot; but a citizen *walks* towards its local -Z
# (`Citizen.face_towards`), so a person's face, toes and anything else that
# has a front are authored towards +Y here. Authored at -Y, as the boots were
# for as long as this file has existed, they faced backwards.
FRONT = 1.0


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
                     center=(0, FRONT * bottom_w * 0.35, -length - boot_h))
        mb.add(v, f, boot)
    return mb


def _citizen(asset_id: str, skin: str, tunic: str, trouser: str,
             hat: bool, shoulder_w: float, hip_w: float,
             dress: bool = False) -> CharacterAsset:
    parts: dict = {}
    depth = hip_w * 0.72

    # --- torso (pivot at hips) ---
    torso = M.MeshBuilder("torso")
    torso_h = SHOULDER_Z - HIP_Z
    # Body of the tunic, hips to shoulders, broadening upward.
    v, f = M.box(hip_w, depth, torso_h, center=(0, 0, 0),
                 taper=shoulder_w / hip_w)
    torso.add(v, f, tunic)
    # The skirt of the tunic — or, for a dress, the whole skirt to the ankle —
    # hung from the belt and flaring out. Legs swing inside it; only the lower
    # leg and the boots show below a tunic, only the feet below a dress.
    skirt_h = (HIP_Z - 0.12) if dress else 0.30
    skirt_bottom_w = hip_w * (1.55 if dress else 1.22)
    v, f = M.box(skirt_bottom_w, depth * (1.35 if dress else 1.15), skirt_h,
                 center=(0, 0, 0.10 - skirt_h),
                 taper=(hip_w * 1.04) / skirt_bottom_w)
    torso.add(v, f, tunic)
    # Belt, where the skirt meets the body.
    v, f = M.box(hip_w * 1.07, depth * 1.08, 0.05, center=(0, 0, 0.07))
    torso.add(v, f, "timber_dark")
    # Collar: a darker band that separates the head from the body.
    v, f = M.box(shoulder_w * 0.5, depth * 0.8, 0.045,
                 center=(0, 0, torso_h - 0.01))
    torso.add(v, f, fabric_or(tunic))
    parts["torso"] = (torso, (0.0, 0.0, HIP_Z))

    # --- head (pivot at neck) ---
    head = M.MeshBuilder("head")
    hw, hd, hh = 0.21, 0.20, 0.25
    v, f = M.box(0.09, 0.085, 0.06, center=(0, 0, 0))          # neck
    head.add(v, f, skin)
    v, f = M.box(hw, hd, hh, center=(0, 0, 0.04), taper=0.86)  # head
    head.add(v, f, skin)
    # A nose, so a face has a front: which way somebody is looking reads
    # from across the square.
    v, f = M.box(0.035, 0.035, 0.05, center=(0, FRONT * (hd * 0.5 + 0.012), 0.04 + hh * 0.38))
    head.add(v, f, skin)
    top = 0.04 + hh
    if dress:
        # Headscarf over the crown and down the back of the neck.
        v, f = M.box(hw * 1.08, hd * 1.1, 0.10, center=(0, -FRONT * 0.01, top - 0.075),
                     taper=0.78)
        head.add(v, f, "fabric_muted")
        v, f = M.box(hw * 0.9, 0.05, hh * 0.75, center=(0, -FRONT * (hd * 0.5 + 0.01), 0.02))
        head.add(v, f, "fabric_muted")
    elif hat:
        # A soft cap with a brim.
        v, f = M.box(hw * 1.02, hd * 1.02, 0.08, center=(0, 0, top - 0.03),
                     taper=0.82)
        head.add(v, f, "fabric_muted")
        v, f = M.box(hw * 1.28, hd * 1.28, 0.022, center=(0, FRONT * 0.01, top - 0.04))
        head.add(v, f, "fabric_muted")
    else:
        v, f = M.box(hw * 1.04, hd * 1.04, 0.07, center=(0, -FRONT * 0.005, top - 0.05),
                     taper=0.86)
        head.add(v, f, "timber_dark")
    parts["head"] = (head, (0.0, 0.0, NECK_Z))

    # --- arms (pivot at shoulder) ---
    arm_len = 0.56
    for side, sx in (("arm_l", -1), ("arm_r", 1)):
        arm = _limb(side, arm_len, 0.12, 0.095, tunic)
        # Hand.
        v, f = M.box(0.095, 0.085, 0.10, center=(0, 0, -arm_len - 0.10))
        arm.add(v, f, skin)
        parts[side] = (arm, (sx * (shoulder_w * 0.5 + 0.035), 0.0, SHOULDER_Z - 0.03))

    # --- legs (pivot at hip) ---
    leg_len = HIP_Z - 0.075
    for side, sx in (("leg_l", -1), ("leg_r", 1)):
        leg = _limb(side, leg_len, 0.15, 0.11, trouser,
                    boot="timber_dark", boot_h=0.075)
        parts[side] = (leg, (sx * hip_w * 0.27, 0.0, HIP_Z))

    return CharacterAsset(asset_id, parts, (0.6, 0.5))


def fabric_or(material: str) -> str:
    return "fabric_muted" if material != "fabric_muted" else "timber_light"


def citizen_male_base() -> CharacterAsset:
    return _citizen("citizen_male_base", "skin_light", "fabric_muted",
                    "timber_dark", hat=True, shoulder_w=0.46, hip_w=0.36)


def citizen_female_base() -> CharacterAsset:
    return _citizen("citizen_female_base", "skin_mid", "brick_red",
                    "timber_dark", hat=False, shoulder_w=0.40, hip_w=0.34,
                    dress=True)


CHARACTERS = {
    "citizen_male_base": citizen_male_base,
    "citizen_female_base": citizen_female_base,
}
