#!/usr/bin/env python3
"""Read a .glb without any dependencies and report its node/mesh structure.

Used by the asset validator and handy for debugging the export pipeline.
"""

from __future__ import annotations

import json
import math
import struct
import sys
from collections import Counter


def _integer(value, label: str, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


def _item(items: list, index, label: str):
    index = _integer(index, label)
    if index >= len(items):
        raise ValueError(f"{label} {index} is out of range")
    return items[index]


def _vector(value, size: int, label: str):
    if (not isinstance(value, list) or len(value) != size
            or any(type(v) not in (int, float) or not math.isfinite(v)
                   for v in value)):
        raise ValueError(f"{label} must contain {size} finite numbers")
    return value


def read_glb(path: str) -> dict:
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < 12:
        raise ValueError(f"{path}: truncated GLB header")
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"{path}: not a GLB file")
    if version != 2:
        raise ValueError(f"{path}: unsupported glTF version {version}")
    if length != len(data):
        raise ValueError(f"{path}: GLB length says {length}, file has {len(data)} bytes")

    offset = 12
    gltf = None
    binary = None
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError(f"{path}: truncated chunk header")
        chunk_len, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        if chunk_len % 4 or offset + chunk_len > len(data):
            raise ValueError(f"{path}: unaligned or truncated GLB chunk")
        if chunk_type == 0x4E4F534A:      # JSON
            if gltf is not None or offset != 20:
                raise ValueError(f"{path}: JSON must be the first and only JSON chunk")
            gltf = json.loads(data[offset:offset + chunk_len].decode("utf-8"))
        elif chunk_type == 0x004E4942:    # BIN
            if gltf is None or binary is not None:
                raise ValueError(f"{path}: duplicate or misplaced BIN chunk")
            binary = data[offset:offset + chunk_len]
        else:
            raise ValueError(f"{path}: unsupported GLB chunk {chunk_type:#x}")
        offset += chunk_len
    if not isinstance(gltf, dict) or binary is None:
        raise ValueError(f"{path}: expected a JSON object and embedded BIN chunk")
    gltf["_binary"] = binary
    gltf["_bin_bytes"] = len(binary)
    gltf["_file_bytes"] = len(data)
    return gltf


class Accessors:
    """Decode the uncompressed scalar/vector accessors our exporter writes.

    Offsets and strides are checked against the view, declared buffer and actual
    bytes before unpacking. Unsupported encodings fail explicitly rather than
    letting an accessor's advertised bounds stand in for its vertex data.
    """

    COMPONENTS = {5120: "b", 5121: "B", 5122: "h", 5123: "H",
                  5125: "I", 5126: "f"}
    WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}

    def __init__(self, gltf: dict):
        self.gltf = gltf
        self.binary = gltf["_binary"]
        self.cache = {}
        self.locations = {}
        if gltf.get("asset", {}).get("version") != "2.0":
            raise ValueError("asset.version must be glTF 2.0")
        buffers = gltf.get("buffers", [])
        if len(buffers) != 1 or "uri" in buffers[0]:
            raise ValueError("assets must use one embedded buffer with no URI")
        length = _integer(buffers[0].get("byteLength"), "buffer.byteLength", 1)
        if not length <= len(self.binary) <= length + 3:
            raise ValueError("embedded buffer length does not match actual BIN bytes")
        if gltf.get("extensionsRequired"):
            raise ValueError("required glTF extensions are not supported by this validator")
        for i, view in enumerate(gltf.get("bufferViews", [])):
            if type(view.get("buffer")) is not int or view["buffer"] != 0:
                raise ValueError(f"bufferView {i} must reference embedded buffer 0")
            offset = _integer(view.get("byteOffset", 0), f"bufferView {i} offset")
            size = _integer(view.get("byteLength"), f"bufferView {i} length", 1)
            if offset + size > length:
                raise ValueError(f"bufferView {i} exceeds the embedded buffer")
            if "byteStride" in view:
                stride = _integer(view["byteStride"], f"bufferView {i} stride", 4)
                if stride > 252 or stride % 4:
                    raise ValueError(f"bufferView {i} has invalid byteStride")

    def metadata(self, index):
        return _item(self.gltf.get("accessors", []), index, "accessor")

    def read(self, index) -> list[tuple]:
        acc = self.metadata(index)
        if index in self.cache:
            return self.cache[index]
        label = f"accessor {index}"
        if "sparse" in acc:
            raise ValueError(f"{label}: sparse encoding is not supported")
        component = acc.get("componentType")
        kind = acc.get("type")
        if component not in self.COMPONENTS or kind not in self.WIDTHS:
            raise ValueError(f"{label}: unsupported component or accessor type")
        view = _item(self.gltf.get("bufferViews", []), acc.get("bufferView"),
                     f"{label} bufferView")
        width = self.WIDTHS[kind]
        fmt = "<" + self.COMPONENTS[component] * width
        element_size = struct.calcsize(fmt)
        component_size = element_size // width
        count = _integer(acc.get("count"), f"{label} count", 1)
        offset = _integer(acc.get("byteOffset", 0), f"{label} offset")
        start = view.get("byteOffset", 0) + offset
        stride = view.get("byteStride", element_size)
        if offset % component_size or start % component_size:
            raise ValueError(f"{label}: unaligned component offset")
        if stride < element_size or stride % component_size:
            raise ValueError(f"{label}: stride cannot contain an element")
        if offset + (count - 1) * stride + element_size > view["byteLength"]:
            raise ValueError(f"{label}: elements exceed their bufferView")
        normalized = acc.get("normalized", False)
        if type(normalized) is not bool or (normalized and component in (5125, 5126)):
            raise ValueError(f"{label}: invalid normalized component type")
        values = [struct.unpack_from(fmt, self.binary, start + i * stride)
                  for i in range(count)]
        if any(not math.isfinite(v) for row in values for v in row):
            raise ValueError(f"{label}: binary data contains a nonfinite value")
        for field, operation in (("min", min), ("max", max)):
            if field not in acc:
                continue
            declared = _vector(acc[field], width, f"{label}.{field}")
            actual = [operation(row[axis] for row in values) for axis in range(width)]
            if any(not math.isclose(a, b, rel_tol=1e-6, abs_tol=1e-7)
                   for a, b in zip(actual, declared)):
                raise ValueError(f"{label}: declared {field} disagrees with decoded bytes")
        self.locations[index] = [start + i * stride for i in range(count)]
        if normalized:
            limits = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}
            values = [tuple(max(-1.0, v / limits[component]) for v in row)
                      for row in values]
        self.cache[index] = values
        return values


def _mesh_geometry(mesh: dict, decoder: Accessors, mesh_index: int) -> dict:
    """Measure rendered triangles and check assembled-surface integrity.

    Export seams duplicate vertices for normals, UVs and materials. Indexed
    edges therefore use the position's buffer address, so material primitives
    sharing one accessor still share edges. Geometric edges merge exact equal
    positions for diagnostics and winding checks, without requiring joined
    kit pieces to form one watertight solid.
    """
    positions = []
    faces = set()
    indexed_edges = Counter()
    geometric_edges = Counter()
    directed_edges = Counter()
    triangles = 0
    for pi, primitive in enumerate(mesh.get("primitives", [])):
        label = f"mesh {mesh_index} primitive {pi}"
        if primitive.get("mode", 4) != 4:
            raise ValueError(f"{label}: only triangle primitives are supported")
        if primitive.get("targets") or primitive.get("extensions"):
            raise ValueError(f"{label}: morph targets or compressed extensions are unsupported")
        attributes = primitive.get("attributes", {})
        if "POSITION" not in attributes:
            raise ValueError(f"{label}: missing POSITION accessor")
        position_index = attributes["POSITION"]
        meta = decoder.metadata(position_index)
        if (meta.get("type") != "VEC3" or meta.get("componentType") != 5126
                or meta.get("normalized", False)):
            raise ValueError(f"{label}: POSITION must be unnormalized float32 VEC3")
        points = decoder.read(position_index)
        if "min" not in meta or "max" not in meta:
            raise ValueError(f"{label}: POSITION must declare bounds checked against bytes")
        for semantic, index in attributes.items():
            if len(decoder.read(index)) != len(points):
                raise ValueError(f"{label}: {semantic} count differs from POSITION")
            attr = decoder.metadata(index)
            view = decoder.gltf["bufferViews"][attr["bufferView"]]
            if attr.get("byteOffset", 0) % 4 or (
                    view.get("byteStride", struct.calcsize("<" + decoder.COMPONENTS[
                        attr["componentType"]] * decoder.WIDTHS[attr["type"]])) % 4):
                raise ValueError(f"{label}: {semantic} elements must be aligned to four bytes")
            if semantic in ("NORMAL", "TANGENT") and (
                    attr.get("type") != ("VEC3" if semantic == "NORMAL" else "VEC4")
                    or attr.get("componentType") != 5126):
                raise ValueError(f"{label}: invalid {semantic} accessor type")
        if "indices" in primitive:
            index_meta = decoder.metadata(primitive["indices"])
            if (index_meta.get("type") != "SCALAR"
                    or index_meta.get("componentType") not in (5121, 5123, 5125)
                    or index_meta.get("normalized", False)):
                raise ValueError(f"{label}: indices must be unsigned integer scalars")
            if "byteStride" in decoder.gltf["bufferViews"][index_meta["bufferView"]]:
                raise ValueError(f"{label}: indices must be tightly packed without byteStride")
            indices = [row[0] for row in decoder.read(primitive["indices"])]
            # glTF excludes the value some graphics APIs treat as a restart.
            sentinel = {5121: 255, 5123: 65535, 5125: 4294967295}[index_meta["componentType"]]
            if sentinel in indices:
                raise ValueError(f"{label}: forbidden primitive-restart index")
        else:
            indices = list(range(len(points)))
        if len(indices) % 3:
            raise ValueError(f"{label}: triangle index/vertex count is not divisible by three")
        if any(index >= len(points) for index in indices):
            raise ValueError(f"{label}: triangle index is outside POSITION array")
        locations = decoder.locations[position_index]
        for start in range(0, len(indices), 3):
            ids = indices[start:start + 3]
            a, b, c = [points[index] for index in ids]
            ab = [b[i] - a[i] for i in range(3)]
            ac = [c[i] - a[i] for i in range(3)]
            cross = (ab[1] * ac[2] - ab[2] * ac[1],
                     ab[2] * ac[0] - ab[0] * ac[2],
                     ab[0] * ac[1] - ab[1] * ac[0])
            edge_sq = max(sum(v * v for v in ab), sum(v * v for v in ac))
            if sum(v * v for v in cross) <= edge_sq * edge_sq * 1e-20:
                raise ValueError(f"{label}: degenerate triangle {start // 3}")
            face = tuple(sorted((a, b, c)))
            if face in faces:
                raise ValueError(f"{label}: duplicate triangle {start // 3}")
            faces.add(face)
            for u, v in ((0, 1), (1, 2), (2, 0)):
                p, q = points[ids[u]], points[ids[v]]
                indexed_edges[tuple(sorted((locations[ids[u]], locations[ids[v]])))] += 1
                geometric_edges[tuple(sorted((p, q)))] += 1
                directed_edges[(p, q)] += 1
            positions.extend((a, b, c))
            triangles += 1
    for (a, b), count in geometric_edges.items():
        if count == 2 and (directed_edges[(a, b)] == 2 or directed_edges[(b, a)] == 2):
            raise ValueError(f"mesh {mesh_index}: inconsistent winding across a two-face edge")
    return {
        "triangles": triangles,
        "positions": positions,
        "boundary_edges": sum(n == 1 for n in geometric_edges.values()),
        "junction_edges": sum(n > 2 for n in geometric_edges.values()),
        "indexed_junction_edges": sum(n > 2 for n in indexed_edges.values()),
    }


def summarise(gltf: dict) -> dict:
    nodes = gltf.get("nodes", [])
    meshes = gltf.get("meshes", [])
    decoder = Accessors(gltf)
    # Also inspect unused accessors: invalid or nonfinite data should not hide
    # in an export merely because no current primitive references it.
    for index in range(len(gltf.get("accessors", []))):
        decoder.read(index)
    geometry = [_mesh_geometry(mesh, decoder, i) for i, mesh in enumerate(meshes)]

    material_names = [m.get("name", "") for m in gltf.get("materials", [])]

    def mesh_materials(mesh):
        """The material names a mesh actually draws with."""
        used = set()
        for prim in mesh.get("primitives", []):
            index = prim.get("material")
            if index is not None:
                used.add(_item(material_names, index, "primitive material"))
        return sorted(used)

    def mesh_bounds(measured, node):
        """Axis-aligned bounds in Blender's Z-up frame, in metres.

        Measure vertices actually referenced by triangles, not accessor
        metadata or unused vertices. The export is Y-up, so the axes map back:
        glTF (x, y, z) is Blender (x, -z, y). The node's own translation and
        scale are applied, which is what makes a mis-scaled export visible
        here rather than only in the generator's manifest.
        """
        lo = [float("inf")] * 3
        hi = [float("-inf")] * 3
        for point in measured["positions"]:
            for axis in range(3):
                lo[axis] = min(lo[axis], point[axis])
                hi[axis] = max(hi[axis], point[axis])
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
    for i, node in enumerate(nodes):
        for key, width in (("translation", 3), ("scale", 3),
                           ("rotation", 4), ("matrix", 16)):
            if key in node:
                _vector(node[key], width, f"node {i}.{key}")
        if "skin" in node:
            raise ValueError(f"node {i}: skinned geometry is unsupported")

    # Which nodes the file actually puts in its scene, and who parents whom.
    # A glTF node that no scene reaches is still in `nodes`, so a validator
    # that only looks things up by name can be shown a node the renderer will
    # never see. A node's translation is also only its own: a parent carrying
    # one moves the child's geometry without appearing in the child's entry.
    scenes = gltf.get("scenes", [])
    scene = _item(scenes, gltf.get("scene", 0), "scene")
    scene_roots = [_item(node_names, i, "scene root")
                   for i in scene.get("nodes", [])]
    parent_of = {}
    for node in nodes:
        for child in node.get("children", []):
            name = _item(node_names, child, "child node")
            if name in parent_of:
                raise ValueError(f"node {name!r} has multiple parent references")
            parent_of[name] = node.get("name", "")
    if any(name in parent_of for name in scene_roots):
        raise ValueError("a scene root also has a parent")

    # The triangle counts below divide an index count by three, which is only
    # a triangle count while the primitive is drawn as one. Mode 4 is
    # TRIANGLES; a strip or a fan of the same index count draws a different
    # number of them.
    primitive_modes = sorted({prim.get("mode", 4)
                              for mesh in meshes
                              for prim in mesh.get("primitives", [])})

    mesh_nodes = {}
    node_materials = {}
    node_bounds = {}
    empties = {}
    for node in nodes:
        name = node.get("name", "")
        if "mesh" in node:
            mesh = _item(meshes, node["mesh"], "node mesh")
            measured = geometry[node["mesh"]]
            mesh_nodes[name] = measured["triangles"]
            node_materials[name] = mesh_materials(mesh)
            bounds = mesh_bounds(measured, node)
            if bounds is not None:
                node_bounds[name] = bounds
        else:
            t = node.get("translation", [0.0, 0.0, 0.0])
            empties[name] = [round(v, 4) for v in t]

    return {
        "node_count": len(nodes),
        "node_names": node_names,
        "scene_roots": scene_roots,
        "parent_of": parent_of,
        "primitive_modes": primitive_modes,
        "mesh_nodes": mesh_nodes,
        "node_materials": node_materials,
        "node_bounds": node_bounds,
        "empties": empties,
        "materials": material_names,
        "total_triangles": sum(m["triangles"] for m in geometry),
        "topology": [{key: value for key, value in m.items() if key != "positions"}
                     for m in geometry],
        "file_bytes": gltf["_file_bytes"],
    }


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        try:
            info = summarise(read_glb(arg))
        except (OSError, ValueError, KeyError, TypeError, IndexError, AttributeError,
                OverflowError, RecursionError, struct.error) as exc:
            sys.exit(f"{arg}: invalid asset: {exc}")
        print(f"\n=== {arg}")
        print(json.dumps(info, indent=2))
