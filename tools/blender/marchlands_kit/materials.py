"""The shared Marchlands material library, built from the spec.

Assets may only use names listed in assets/specs/materials/materials.yaml.
Requesting anything else raises immediately, which is how the pipeline
enforces a small, consistent palette across every generated asset.
"""

from __future__ import annotations

import bpy

from .style import material_library, hex_to_linear

_cache: dict[str, bpy.types.Material] = {}


def get(name: str) -> bpy.types.Material:
    if name in _cache and name in bpy.data.materials:
        return _cache[name]

    library = material_library()
    if name not in library:
        raise KeyError(
            f"'{name}' is not in the Marchlands material library. "
            f"Allowed: {sorted(library)}"
        )

    existing = bpy.data.materials.get(name)
    if existing is not None:
        _cache[name] = existing
        return existing

    spec = library[name]
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    rgb = hex_to_linear(spec["base_color"])
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = float(spec["roughness"])
    bsdf.inputs["Metallic"].default_value = float(spec["metallic"])
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.35

    # Viewport colour keeps solid-shaded previews readable.
    mat.diffuse_color = (*rgb, 1.0)
    mat.roughness = float(spec["roughness"])
    mat.metallic = float(spec["metallic"])

    _cache[name] = mat
    return mat


def build_all() -> None:
    for name in material_library():
        get(name)
