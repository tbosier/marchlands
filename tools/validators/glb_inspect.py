#!/usr/bin/env python3
"""Read a .glb without any dependencies and report its node/mesh structure.

Used by the asset validator and handy for debugging the export pipeline.
"""

from __future__ import annotations

import json
import struct
import sys


def read_glb(path: str) -> dict:
    with open(path, "rb") as handle:
        data = handle.read()
    magic, version, _length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"{path}: not a GLB file")
    if version != 2:
        raise ValueError(f"{path}: unsupported glTF version {version}")

    offset = 12
    gltf = None
    bin_len = 0
    while offset < len(data):
        chunk_len, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        if chunk_type == 0x4E4F534A:      # JSON
            gltf = json.loads(data[offset:offset + chunk_len].decode("utf-8"))
        elif chunk_type == 0x004E4942:    # BIN
            bin_len = chunk_len
        offset += chunk_len
        offset += (4 - offset % 4) % 4 if offset % 4 else 0
    if gltf is None:
        raise ValueError(f"{path}: no JSON chunk")
    gltf["_bin_bytes"] = bin_len
    gltf["_file_bytes"] = len(data)
    return gltf


def summarise(gltf: dict) -> dict:
    nodes = gltf.get("nodes", [])
    meshes = gltf.get("meshes", [])
    accessors = gltf.get("accessors", [])

    def mesh_tris(mesh):
        total = 0
        for prim in mesh.get("primitives", []):
            if "indices" in prim:
                total += accessors[prim["indices"]]["count"] // 3
            else:
                pos = prim["attributes"].get("POSITION")
                if pos is not None:
                    total += accessors[pos]["count"] // 3
        return total

    material_names = [m.get("name", "") for m in gltf.get("materials", [])]

    def mesh_materials(mesh):
        """The material names a mesh actually draws with."""
        used = set()
        for prim in mesh.get("primitives", []):
            index = prim.get("material")
            if index is not None and 0 <= index < len(material_names):
                used.add(material_names[index])
        return sorted(used)

    def mesh_bounds(mesh, node):
        """Axis-aligned bounds in Blender's Z-up frame, in metres.

        POSITION accessors carry their own min/max, so the vertex data never
        has to be decoded. The export is Y-up, so the axes are mapped back:
        glTF (x, y, z) is Blender (x, -z, y). The node's own translation and
        scale are applied, which is what makes a mis-scaled export visible
        here rather than only in the generator's manifest.
        """
        lo = [float("inf")] * 3
        hi = [float("-inf")] * 3
        for prim in mesh.get("primitives", []):
            pos = prim.get("attributes", {}).get("POSITION")
            if pos is None:
                continue
            acc = accessors[pos]
            if "min" not in acc or "max" not in acc:
                continue
            for corner in (acc["min"], acc["max"]):
                for axis in range(3):
                    lo[axis] = min(lo[axis], corner[axis])
                    hi[axis] = max(hi[axis], corner[axis])
        if lo[0] == float("inf"):
            return None
        scale = node.get("scale", [1.0, 1.0, 1.0])
        offset = node.get("translation", [0.0, 0.0, 0.0])
        out_lo, out_hi = [], []
        for axis in range(3):
            a = lo[axis] * scale[axis] + offset[axis]
            b = hi[axis] * scale[axis] + offset[axis]
            out_lo.append(min(a, b))
            out_hi.append(max(a, b))
        # glTF Y-up -> Blender Z-up.
        return (
            [out_lo[0], -out_hi[2], out_lo[1]],
            [out_hi[0], -out_lo[2], out_hi[1]],
        )

    node_names = [n.get("name", "") for n in nodes]
    mesh_nodes = {}
    node_materials = {}
    node_bounds = {}
    empties = {}
    for node in nodes:
        name = node.get("name", "")
        if "mesh" in node:
            mesh = meshes[node["mesh"]]
            mesh_nodes[name] = mesh_tris(mesh)
            node_materials[name] = mesh_materials(mesh)
            bounds = mesh_bounds(mesh, node)
            if bounds is not None:
                node_bounds[name] = bounds
        else:
            t = node.get("translation", [0.0, 0.0, 0.0])
            empties[name] = [round(v, 4) for v in t]

    return {
        "node_count": len(nodes),
        "node_names": node_names,
        "mesh_nodes": mesh_nodes,
        "node_materials": node_materials,
        "node_bounds": node_bounds,
        "empties": empties,
        "materials": material_names,
        "total_triangles": sum(mesh_tris(m) for m in meshes),
        "file_bytes": gltf["_file_bytes"],
    }


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        info = summarise(read_glb(arg))
        print(f"\n=== {arg}")
        print(json.dumps(info, indent=2))
