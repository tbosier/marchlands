"""Marchlands procedural asset kit (Blender).

Import order matters: `style` has no bpy dependency and is safe to import from
plain CPython (the validators do exactly that).
"""

from . import style  # noqa: F401

__all__ = [
    "style",
    "materials",
    "mesh",
    "kit",
    "buildings",
    "vegetation",
    "props",
    "characters",
    "lod",
    "exporter",
    "registry",
]


def registry():
    """All generators, keyed by asset_id. Imported lazily (needs bpy)."""
    from .buildings import BUILDINGS
    from .vegetation import VEGETATION, RESOURCE_NODES
    from .props import PROPS
    from .characters import CHARACTERS

    out = {}
    out.update(BUILDINGS)
    out.update(VEGETATION)
    out.update(RESOURCE_NODES)
    out.update(PROPS)
    out.update(CHARACTERS)
    return out
