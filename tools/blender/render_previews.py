"""Render standardised turntable previews for generated assets.

    blender -b -P tools/blender/render_previews.py -- [asset_id ...]

Each asset is rebuilt, framed automatically against a neutral backdrop and
rendered from N evenly spaced angles, then stitched into one contact sheet at
assets/previews/<asset_id>.png. This is the image a human or reviewing agent
looks at in the asset review loop (design doc 5.3).
"""

from __future__ import annotations

import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from marchlands_kit import exporter, materials, registry  # noqa: E402
from marchlands_kit.style import REPO_ROOT, style, hex_to_linear  # noqa: E402

PREVIEW_DIR = os.path.join(REPO_ROOT, "assets", "previews")


def argv_after_dashes():
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    return []


def scene_bounds(objects):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    found = False
    for obj in objects:
        if obj.type != "MESH":
            continue
        for corner in obj.bound_box:
            p = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
            found = True
    if not found:
        return Vector((-1, -1, 0)), Vector((1, 1, 1))
    return lo, hi


def setup_world():
    spec = style()["preview"]
    bg = hex_to_linear(spec["background"])

    world = bpy.data.worlds.new("preview_world")
    world.use_nodes = True
    bg_node = world.node_tree.nodes["Background"]
    bg_node.inputs["Color"].default_value = (*bg, 1.0)
    bg_node.inputs["Strength"].default_value = 1.1
    bpy.context.scene.world = world

    # Warm key + cool fill, matching the game's lighting direction.
    key = bpy.data.lights.new("key", type="SUN")
    key.energy = 3.2
    key.angle = math.radians(6)
    key.color = (1.0, 0.95, 0.86)
    key_obj = bpy.data.objects.new("key", key)
    key_obj.rotation_euler = (math.radians(52), 0, math.radians(41))
    bpy.context.scene.collection.objects.link(key_obj)

    fill = bpy.data.lights.new("fill", type="SUN")
    fill.energy = 1.0
    fill.color = (0.78, 0.85, 1.0)
    fill_obj = bpy.data.objects.new("fill", fill)
    fill_obj.rotation_euler = (math.radians(64), 0, math.radians(-135))
    bpy.context.scene.collection.objects.link(fill_obj)


def setup_ground(lo: Vector, hi: Vector):
    """A large neutral disc so assets cast a grounding shadow.

    Held at a middle value deliberately. A near-white card flatters
    nothing: it swallows plaster and thatch and turns stone into a
    cut-out, which is the opposite of what a review sheet is for.
    """
    radius = max(hi.x - lo.x, hi.y - lo.y) * 4.0 + 6.0
    mesh = bpy.data.meshes.new("ground")
    verts, faces = [], []
    n = 32
    for i in range(n):
        a = math.tau * i / n
        verts.append((math.cos(a) * radius, math.sin(a) * radius, lo.z - 0.002))
    faces.append(tuple(range(n)))
    mesh.from_pydata(verts, [], faces)
    obj = bpy.data.objects.new("ground", mesh)
    mat = bpy.data.materials.new("preview_ground")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (0.40, 0.385, 0.345, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.95
    mesh.materials.append(mat)
    bpy.context.scene.collection.objects.link(obj)


def setup_camera(lo: Vector, hi: Vector, angle: float, res: int,
                 fit_deg: float = 19.0, elev_deg: float = 26.0):
    centre = (lo + hi) * 0.5
    radius = max((hi - lo).length * 0.62, 0.8)
    dist = radius / math.tan(math.radians(fit_deg))

    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)

    elev = math.radians(elev_deg)
    cam.location = (
        centre.x + math.cos(angle) * math.cos(elev) * dist,
        centre.y + math.sin(angle) * math.cos(elev) * dist,
        centre.z + math.sin(elev) * dist,
    )
    direction = centre - Vector(cam.location)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = cam
    return cam


def configure_render(res: int):
    scene = bpy.context.scene
    # The EEVEE identifier changed across 4.x/5.x; pick whichever this build has.
    engines = scene.render.bl_rna.properties["engine"].enum_items.keys()
    for candidate in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        if candidate in engines:
            scene.render.engine = candidate
            break
    scene.render.resolution_x = res
    scene.render.resolution_y = res
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    eevee = scene.eevee
    if hasattr(eevee, "taa_render_samples"):
        eevee.taa_render_samples = 24
    if hasattr(eevee, "use_shadows"):
        eevee.use_shadows = True
    scene.view_settings.view_transform = "AgX"
    looks = scene.view_settings.bl_rna.properties["look"].enum_items.keys()
    for candidate in ("AgX - Medium Contrast", "AgX - Base Contrast",
                      "AgX - Medium High Contrast", "None"):
        if candidate in looks:
            scene.view_settings.look = candidate
            break


def render_asset(asset_id: str, factory, frames: int, res: int) -> str:
    exporter.reset_scene()
    materials.build_all()

    asset = factory()
    exporter.build_asset_objects(asset, make_lods=False, make_collision=False)

    # Object locations set via .location do not reach matrix_world until the
    # depsgraph runs; without this the camera frames character parts at the
    # origin instead of where they actually sit.
    bpy.context.view_layer.update()

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    lo, hi = scene_bounds(meshes)

    setup_world()
    setup_ground(lo, hi)
    configure_render(res)

    os.makedirs(PREVIEW_DIR, exist_ok=True)
    tmp_dir = os.path.join(PREVIEW_DIR, ".frames")
    os.makedirs(tmp_dir, exist_ok=True)

    paths = []
    for i in range(frames):
        angle = -math.pi * 0.5 + math.tau * i / frames + math.radians(28)
        cam = setup_camera(lo, hi, angle, res)
        path = os.path.join(tmp_dir, f"{asset_id}_{i}.png")
        bpy.context.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        paths.append(path)
        bpy.data.objects.remove(cam, do_unlink=True)

    out = os.path.join(PREVIEW_DIR, f"{asset_id}.png")
    contact_sheet(paths, out, res, asset_id)
    for p in paths:
        os.remove(p)
    return out


def contact_sheet(paths, out_path: str, res: int, label: str):
    """Stitch frames side by side using Blender's own image API."""
    cols = len(paths)
    sheet = bpy.data.images.new("sheet", width=res * cols, height=res)
    buf = [0.0] * (res * cols * res * 4)

    for c, path in enumerate(paths):
        img = bpy.data.images.load(path)
        px = list(img.pixels)
        for y in range(res):
            src = y * res * 4
            dst = (y * res * cols + c * res) * 4
            buf[dst:dst + res * 4] = px[src:src + res * 4]
        bpy.data.images.remove(img)

    sheet.pixels = buf
    sheet.filepath_raw = out_path
    sheet.file_format = "PNG"
    sheet.save()
    bpy.data.images.remove(sheet)


def main() -> int:
    wanted = argv_after_dashes()
    all_assets = registry()
    targets = ({k: all_assets[k] for k in wanted if k in all_assets}
               if wanted else all_assets)
    if not targets:
        print(f"No matching assets. Known: {sorted(all_assets)}")
        return 2

    spec = style()["preview"]
    frames = int(spec["turntable_frames"])
    res = int(spec["resolution"][0])

    print(f"\n=== rendering {len(targets)} preview(s) "
          f"@ {res}px x {frames} frames ===\n")
    for asset_id, factory in targets.items():
        out = render_asset(asset_id, factory, frames, res)
        print(f"  {asset_id:<22} -> {os.path.relpath(out, REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
