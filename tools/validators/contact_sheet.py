#!/usr/bin/env python3
"""Stack every asset preview into one reviewable contact sheet.

    python3 tools/validators/contact_sheet.py [out.png] [asset_id ...]

This is the image the asset review loop looks at when judging the whole set
for style consistency, rather than one asset at a time.
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PREVIEW_DIR = os.path.join(REPO_ROOT, "assets", "previews")

ROW_W = 1200
LABEL_W = 150


def build(out_path: str, wanted: list[str]) -> str:
    # Underscore-prefixed files are this script's own output. Scanning them
    # back in stitched the previous contact sheet into the new one as its first
    # row — and since that row is itself a sheet, each run nested one more
    # generation and the image grew towards 75,000 px tall. The committed
    # design/screenshots/asset_sheet.png is 42% one such unreadable inner copy.
    names = sorted(
        f[:-4] for f in os.listdir(PREVIEW_DIR)
        if f.endswith(".png") and not f.startswith("_")
        and (not wanted or f[:-4] in wanted)
    )
    if not names:
        raise SystemExit("no previews found; render them first")

    rows = []
    for name in names:
        img = Image.open(os.path.join(PREVIEW_DIR, f"{name}.png")).convert("RGB")
        h = max(1, round(img.height * ROW_W / img.width))
        rows.append((name, img.resize((ROW_W, h), Image.LANCZOS)))

    total_h = sum(r.height for _, r in rows)
    sheet = Image.new("RGB", (LABEL_W + ROW_W, total_h), (24, 24, 26))
    draw = ImageDraw.Draw(sheet)

    y = 0
    for name, img in rows:
        sheet.paste(img, (LABEL_W, y))
        draw.text((10, y + img.height // 2 - 6), name, fill=(235, 230, 220))
        draw.line([(0, y), (LABEL_W + ROW_W, y)], fill=(70, 70, 74))
        y += img.height

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    sheet.save(out_path)
    return out_path


if __name__ == "__main__":
    args = sys.argv[1:]
    out = args[0] if args and args[0].endswith(".png") else \
        os.path.join(PREVIEW_DIR, "_all_assets.png")
    ids = [a for a in args if not a.endswith(".png")]
    print(build(out, ids))
