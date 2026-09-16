"""Generate Marchlands assets with Blender.

    blender -b -P tools/blender/generate_assets.py -- [asset_id ...]

With no asset ids, every asset in the registry is generated. Each asset is
built in a fresh scene, exported to assets/generated/<category>/<id>.glb and
described by a sibling <id>.json manifest.
"""

from __future__ import annotations

import os
import sys
import time
import traceback

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from marchlands_kit import exporter, materials, registry  # noqa: E402
from marchlands_kit.style import REPO_ROOT  # noqa: E402


def argv_after_dashes():
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    return []


def generate(asset_id: str, factory) -> dict:
    exporter.reset_scene()
    materials.build_all()

    asset = factory()
    created = exporter.build_asset_objects(asset)
    manifest = exporter.manifest_for(asset, created)

    out_dir = exporter.output_dir(asset.category)
    glb_path = os.path.join(out_dir, f"{asset_id}.glb")
    exporter.export_glb(asset, glb_path)
    exporter.write_manifest(manifest, out_dir)

    manifest["glb"] = os.path.relpath(glb_path, REPO_ROOT)
    manifest["glb_bytes"] = os.path.getsize(glb_path)
    return manifest


def main() -> int:
    wanted = argv_after_dashes()
    all_assets = registry()
    if wanted:
        missing = [a for a in wanted if a not in all_assets]
        if missing:
            print(f"UNKNOWN ASSETS: {missing}")
            print(f"Known: {sorted(all_assets)}")
            return 2
        targets = {k: all_assets[k] for k in wanted}
    else:
        targets = all_assets

    print(f"\n=== Marchlands asset generation: {len(targets)} asset(s) ===\n")
    failures = []
    for asset_id, factory in targets.items():
        started = time.time()
        try:
            manifest = generate(asset_id, factory)
        except Exception:
            failures.append(asset_id)
            print(f"  FAIL  {asset_id}")
            traceback.print_exc()
            continue
        tris = manifest["triangles"]
        main_tris = tris.get("lod0", tris.get("parts", 0))
        print(
            f"  OK    {asset_id:<22} "
            f"tris={main_tris:<6} "
            f"mats={len(manifest['materials'])} "
            f"h={manifest['height_m']:.2f}m "
            f"{manifest['glb_bytes'] / 1024:.0f}KB "
            f"({time.time() - started:.1f}s)"
        )

    print(f"\n=== done: {len(targets) - len(failures)} ok, "
          f"{len(failures)} failed ===")
    if failures:
        print(f"failed: {failures}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
