"""Exercise real GLB bytes, including corruptions plausible after a bad export.

Run: python3 -m unittest discover -s tools/tests -p 'test_asset_geometry.py'
No Blender or third-party Python packages are needed.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "validators"))

from glb_inspect import read_glb, summarise  # noqa: E402
from validate_assets import check_spec_consistency, style, validate  # noqa: E402


def fixture(points=None, triangles=None, *, interleaved=False):
    points = points or [(0, 0, 0), (1, 0, 0), (0, 1, 1)]
    triangles = [0, 1, 2] if triangles is None else triangles
    raw = bytearray()
    for p in points:
        raw.extend(struct.pack("<3f", *p))
        if interleaved:
            raw.extend(struct.pack("<3f", 0, 0, 1))
    position_bytes = len(raw)
    raw.extend(struct.pack("<" + "H" * len(triangles), *triangles))
    bounds = {name: [op(p[i] for p in points) for i in range(3)]
              for name, op in (("min", min), ("max", max))}
    position = {"bufferView": 0, "componentType": 5126, "count": len(points),
                "type": "VEC3", **bounds}
    indices = {"bufferView": 1, "componentType": 5123,
               "count": len(triangles), "type": "SCALAR"}
    doc = {
        "asset": {"version": "2.0"}, "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "test_asset", "children": [1, 2, 3]}]
                 + [{"name": f"test_asset_lod{i}", "mesh": 0} for i in range(3)],
        "buffers": [{"byteLength": len(raw)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": position_bytes},
                        {"buffer": 0, "byteOffset": position_bytes,
                         "byteLength": len(triangles) * 2}],
        "accessors": [position, indices],
        "materials": [{"name": "timber_dark"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1,
                                     "material": 0}]}],
    }
    if interleaved:
        doc["bufferViews"][0]["byteStride"] = 24
        doc["accessors"].append({"bufferView": 0, "byteOffset": 12,
                                 "componentType": 5126, "count": len(points),
                                 "type": "VEC3"})
        doc["meshes"][0]["primitives"][0]["attributes"]["NORMAL"] = 2
    return doc, raw


def glb_bytes(doc, raw):
    encoded = json.dumps(doc, allow_nan=False).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4)
    binary = bytes(raw) + b"\0" * (-len(raw) % 4)
    return (struct.pack("<III", 0x46546C67, 2, 28 + len(encoded) + len(binary))
            + struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


def manifest(doc):
    acc = doc["accessors"][0]
    lo, hi = acc["min"], acc["max"]
    return {
        "asset_id": "test_asset", "category": "prop", "footprint_m": [2, 2],
        "bounds_min": [lo[0], -hi[2], lo[1]],
        "bounds_max": [hi[0], -lo[2], hi[1]],
        "height_m": hi[1] - lo[1], "materials": ["timber_dark"],
        "triangles": {f"lod{i}": sum(doc["accessors"][p["indices"]]["count"] // 3
                                      for p in doc["meshes"][0]["primitives"])
                      for i in range(3)},
        "triangle_budget": style()["triangle_budget"]["prop"],
        "attachments": {}, "parts": [],
    }


class AssetGeometryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "props"
        self.directory.mkdir()
        self.path = self.directory / "test_asset.glb"

    def inspect(self, doc, raw):
        self.path.write_bytes(glb_bytes(doc, raw))
        return summarise(read_glb(str(self.path)))

    def reject(self, doc, raw, message):
        with self.assertRaisesRegex(ValueError, message):
            self.inspect(doc, raw)

    def report(self, doc, raw, *, spec=None, data=None):
        self.path.write_bytes(glb_bytes(doc, raw))
        target = self.path.with_suffix(".json")
        target.write_text(json.dumps(manifest(doc) if data is None else data))
        return validate(str(target), style() if spec is None else spec, {})

    def test_valid_mesh_measures_rendered_vertices(self):
        info = self.inspect(*fixture())
        self.assertEqual(info["mesh_nodes"]["test_asset_lod0"], 1)
        self.assertEqual(info["node_bounds"]["test_asset_lod0"],
                         ([0, -1, 0], [1, 0, 1]))
        self.assertEqual(info["topology"][0]["boundary_edges"], 3)
        self.assertFalse(self.report(*fixture()).failed)

    def test_interleaved_attributes_and_accessor_offsets(self):
        info = self.inspect(*fixture(interleaved=True))
        self.assertEqual(info["node_bounds"]["test_asset_lod0"],
                         ([0, -1, 0], [1, 0, 1]))

    def test_nonindexed_triangles(self):
        doc, raw = fixture()
        del doc["meshes"][0]["primitives"][0]["indices"]
        self.assertEqual(self.inspect(doc, raw)["total_triangles"], 1)

    def test_glb_header_and_chunk_lengths(self):
        binary = glb_bytes(*fixture())
        for broken, reason in (
                (binary[:9], "truncated GLB header"),
                (binary[:-1], "GLB length"),
                (binary + b"more", "GLB length")):
            with self.subTest(reason=reason):
                self.path.write_bytes(broken)
                with self.assertRaisesRegex(ValueError, reason):
                    read_glb(str(self.path))
        broken = bytearray(binary[:-4])
        struct.pack_into("<I", broken, 8, len(broken))
        self.path.write_bytes(broken)
        with self.assertRaisesRegex(ValueError, "truncated GLB chunk"):
            read_glb(str(self.path))

    def test_duplicate_binary_chunk_is_rejected(self):
        binary = bytearray(glb_bytes(*fixture()))
        binary.extend(struct.pack("<II", 4, 0x004E4942) + b"\0" * 4)
        struct.pack_into("<I", binary, 8, len(binary))
        self.path.write_bytes(binary)
        with self.assertRaisesRegex(ValueError, "duplicate or misplaced BIN"):
            read_glb(str(self.path))

    def test_accessor_count_cannot_read_past_its_view(self):
        doc, raw = fixture()
        doc["accessors"][0]["count"] += 1
        self.reject(doc, raw, "elements exceed their bufferView")

    def test_offsets_and_strides_are_checked(self):
        cases = [("byteOffset", -4, "integer >= 0"),
                 ("byteOffset", 2, "unaligned"),
                 ("byteOffset", 12, "exceed")]
        for key, value, reason in cases:
            with self.subTest(value=value):
                doc, raw = fixture()
                doc["accessors"][0][key] = value
                self.reject(doc, raw, reason)
        doc, raw = fixture()
        doc["bufferViews"][0]["byteStride"] = 4
        self.reject(doc, raw, "stride cannot contain an element")
        doc["bufferViews"][0]["byteStride"] = 13
        self.reject(doc, raw, "invalid byteStride")

    def test_buffer_extents_and_external_buffers_are_checked(self):
        doc, raw = fixture()
        doc["buffers"][0]["byteLength"] += 100
        self.reject(doc, raw, "actual BIN bytes")
        doc, raw = fixture()
        doc["bufferViews"][0]["byteLength"] += 100
        self.reject(doc, raw, "exceeds the embedded buffer")
        doc, raw = fixture()
        doc["buffers"][0]["uri"] = "other.bin"
        self.reject(doc, raw, "one embedded buffer")

    def test_bounds_metadata_is_compared_to_actual_bytes(self):
        doc, raw = fixture()
        doc["accessors"][0]["max"][0] = 5.0
        self.reject(doc, raw, "declared max disagrees")
        doc, raw = fixture()
        struct.pack_into("<f", raw, 12, 5.0)
        self.reject(doc, raw, "declared max disagrees")

    def test_manifest_cannot_hide_vertex_changes_with_corrected_metadata(self):
        doc, raw = fixture()
        original = manifest(doc)
        struct.pack_into("<f", raw, 12, 5.0)
        doc["accessors"][0]["max"][0] = 5.0
        report = self.report(doc, raw, data=original)
        self.assertTrue(report.failed)
        self.assertIn("bounds match the manifest", report.render(True))

    def test_unused_vertices_do_not_inflate_rendered_bounds(self):
        doc, raw = fixture(points=[(0, 0, 0), (1, 0, 0), (0, 1, 1), (20, 20, 20)])
        info = self.inspect(doc, raw)
        self.assertEqual(info["node_bounds"]["test_asset_lod0"],
                         ([0, -1, 0], [1, 0, 1]))
        self.assertTrue(self.report(doc, raw).failed)

    def test_nonfinite_vertex_and_normal_values(self):
        for offset in (0, 12):
            with self.subTest(offset=offset):
                doc, raw = fixture(interleaved=True)
                struct.pack_into("<f", raw, offset, float("nan"))
                self.reject(doc, raw, "nonfinite value")

    def test_attribute_counts_must_agree(self):
        doc, raw = fixture(interleaved=True)
        doc["accessors"][2]["count"] = 2
        self.reject(doc, raw, "NORMAL count differs")

    def test_indices_must_be_in_range_and_make_complete_triangles(self):
        self.reject(*fixture(triangles=[0, 1, 99]), "outside POSITION")
        self.reject(*fixture(triangles=[0, 1, 2, 0]), "not divisible by three")
        doc, raw = fixture()
        doc["accessors"][1]["normalized"] = True
        self.reject(doc, raw, "unsigned integer scalars")

    def test_primitive_restart_indices_are_not_geometry(self):
        self.reject(*fixture(triangles=[0, 1, 65535]), "primitive-restart index")

    def test_index_accessors_cannot_be_interleaved(self):
        doc, raw = fixture()
        # Give the strided values enough bytes, so it is the index-specific
        # format rule that rejects this, not an unrelated extent check.
        pos_end = doc["bufferViews"][1]["byteOffset"]
        raw[pos_end:] = struct.pack("<H2xH2xH2x", 0, 1, 2)
        doc["buffers"][0]["byteLength"] = len(raw)
        doc["bufferViews"][1]["byteLength"] = 12
        doc["bufferViews"][1]["byteStride"] = 4
        self.reject(doc, raw, "tightly packed without byteStride")

    def test_degenerate_and_duplicate_faces_fail(self):
        self.reject(*fixture(triangles=[0, 1, 1]), "degenerate triangle")
        self.reject(*fixture(points=[(0, 0, 0), (1, 1, 1), (2, 2, 2)]),
                    "degenerate triangle")
        self.reject(*fixture(triangles=[0, 1, 2, 2, 1, 0]), "duplicate triangle")

    def test_winding_is_checked_across_exported_seams(self):
        points = [(0, 0, 0), (1, 0, 0), (0, 1, 1),
                  (0, 0, 0), (1, 0, 0), (0, -1, 1)]
        self.reject(*fixture(points=points, triangles=[0, 1, 2, 3, 4, 5]),
                    "inconsistent winding")
        self.assertEqual(self.inspect(*fixture(points=points,
                                              triangles=[0, 1, 2, 4, 3, 5]))
                         ["total_triangles"], 2)

    def test_junction_policy_counts_across_shared_accessor_primitives(self):
        points = [(0, 0, 0), (1, 0, 0), (0, 1, 1), (0, 1, -1), (0, 2, 0)]
        doc, raw = fixture(points=points, triangles=[0, 1, 2, 1, 0, 3, 0, 1, 4])
        # Three material primitives share an underlying POSITION buffer, with
        # one using an alias accessor over the same bytes. Count the shared
        # edge once, regardless of primitive/accessor partitioning.
        original_indices = doc["accessors"][1]
        original_indices["count"] = 3
        doc["accessors"].extend([dict(original_indices, byteOffset=6),
                                 dict(original_indices, byteOffset=12),
                                 copy.deepcopy(doc["accessors"][0])])
        doc["meshes"][0]["primitives"] = [
            {"attributes": {"POSITION": 4 if i == 2 else 0}, "indices": i + 1,
             "material": 0} for i in range(3)]
        topo = self.inspect(doc, raw)["topology"][0]
        self.assertEqual(topo["indexed_junction_edges"], 1)
        self.assertEqual(topo["junction_edges"], 1)
        self.assertFalse(self.report(doc, raw).failed)
        for key in ("indexed_junction_edges_allowed", "coincident_junction_edges_allowed"):
            with self.subTest(policy=key):
                spec = copy.deepcopy(style())
                spec["geometry"][key] = False
                self.assertTrue(self.report(doc, raw, spec=spec).failed)

    def test_separate_vertex_buffers_are_not_shared_indexed_edges(self):
        points = [(0, 0, 0), (1, 0, 0), (0, 1, 1),
                  (1, 0, 0), (0, 0, 0), (0, 1, -1),
                  (0, 0, 0), (1, 0, 0), (0, 2, 0)]
        doc, raw = fixture(points=points, triangles=list(range(9)))
        topo = self.inspect(doc, raw)["topology"][0]
        self.assertEqual(topo["indexed_junction_edges"], 0)
        self.assertEqual(topo["junction_edges"], 1)

    def test_boundary_policy_can_be_tightened(self):
        spec = copy.deepcopy(style())
        spec["geometry"]["boundary_edges_allowed"] = False
        report = self.report(*fixture(), spec=spec)
        self.assertTrue(report.failed)
        self.assertIn("boundary edges (allowed: False)", report.render(True))

    def test_unsupported_encodings_fail_explicitly(self):
        doc, raw = fixture()
        doc["accessors"][0]["sparse"] = {}
        self.reject(doc, raw, "sparse encoding is not supported")
        doc, raw = fixture()
        doc["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        self.reject(doc, raw, "required glTF extensions")

    def test_nonfinite_transforms_and_invalid_references_fail(self):
        doc, raw = fixture()
        doc["nodes"][1]["translation"] = [0, 0]
        self.reject(doc, raw, "3 finite numbers")
        doc, raw = fixture()
        doc["nodes"][1]["mesh"] = -1
        self.reject(doc, raw, "integer >= 0")
        doc, raw = fixture()
        doc["nodes"][1]["children"] = [0]
        self.reject(doc, raw, "scene root also has a parent")

    def test_corrupt_assets_return_a_failed_report(self):
        doc, raw = fixture(triangles=[0, 1, 99])
        report = self.report(doc, raw)
        self.assertTrue(report.failed)
        self.assertIn("outside POSITION", report.render(True))

    def test_malformed_json_structures_return_reports_without_tracebacks(self):
        for key, value in (("nodes", [None]), ("meshes", [None]),
                           ("accessors", [None]), ("bufferViews", [None]),
                           ("buffers", []), ("asset", [])):
            with self.subTest(key=key):
                doc, raw = fixture()
                data = manifest(doc)
                doc[key] = value
                report = self.report(doc, raw, data=data)
                self.assertTrue(report.failed)
                self.assertIn("invalid manifest or GLB", report.render(True))

    def test_geometry_policy_must_be_explicit(self):
        spec = copy.deepcopy(style())
        self.assertFalse(check_spec_consistency(spec).failed)
        spec["geometry"]["topology"] = "watertight"
        self.assertTrue(check_spec_consistency(spec).failed)


if __name__ == "__main__":
    unittest.main()
