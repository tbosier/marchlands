#!/usr/bin/env python3
"""Generate the Marchlands wordmark.

    python3 tools/branding/make_logo.py [out_dir]

Everything else in this repository is generated from a spec rather than drawn
by hand, and the logo is no exception. It is also the one image that has to
say what the game is in a second and a half, so it says the only thing that
matters: the road is not drawn, it is worn. The track fades in from nothing on
the left — scattered footfalls, then a trodden line, then a road wide enough
to cart stone along — and arrives at the keep that pulled the traffic.

Colours are read from the game's own material library and terrain palette, so
the logo cannot drift away from the thing it advertises.
"""

from __future__ import annotations

import math
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "blender"))

from marchlands_kit import style  # noqa: E402

W, H = 1280, 440
HORIZON = 250.0

# --- palette ----------------------------------------------------------------
LIB = style.material_library()


def mat(name: str) -> str:
    return LIB[name]["base_color"]


def mix(a: str, b: str, t: float) -> str:
    """Blend two #rrggbb colours."""
    av = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    bv = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02x%02x%02x" % tuple(
        int(round(av[i] + (bv[i] - av[i]) * t)) for i in range(3))


SKY_TOP = "#12171f"
SKY_LOW = "#1d2422"
DUSK = "#8a6a3e"
GRASS = "#4a6636"          # Config.COLOR_GRASS
GRASS_DEEP = mat("foliage_deep")
SOIL = mat("soil_dark")
TRACK = "#665742"          # Config.COLOR_TRACK
IMPROVED = "#a39678"       # Config.COLOR_IMPROVED
STONE = mat("stone_grey")
STONE_DARK = mat("stone_dark")
ROOF = mat("roof_tile_red")
THATCH = mat("thatch")
TIMBER = mat("timber_dark")
INK = "#e4d8bd"
INK_DIM = "#9d9887"


# --- the road ---------------------------------------------------------------
# One cubic from the bottom-left corner to the foot of the keep. Everything
# that reads as "a route forming" is hung off this single curve.
P0, P1, P2, P3 = (-30.0, 452.0), (300.0, 430.0), (520.0, 322.0), (884.0, 309.0)


def bez(t: float) -> tuple[float, float]:
    u = 1.0 - t
    x = (u ** 3 * P0[0] + 3 * u * u * t * P1[0]
         + 3 * u * t * t * P2[0] + t ** 3 * P3[0])
    y = (u ** 3 * P0[1] + 3 * u * u * t * P1[1]
         + 3 * u * t * t * P2[1] + t ** 3 * P3[1])
    return x, y


def bez_normal(t: float) -> tuple[float, float]:
    a, b = bez(max(0.0, t - 0.004)), bez(min(1.0, t + 0.004))
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = math.hypot(dx, dy) or 1.0
    return -dy / n, dx / n


ROAD_D = ("M %.1f %.1f C %.1f %.1f %.1f %.1f %.1f %.1f"
          % (P0[0], P0[1], P1[0], P1[1], P2[0], P2[1], P3[0], P3[1]))


def ground_facets(rng: random.Random) -> list[str]:
    """A low-poly ground plane, faceted the way the game's terrain is."""
    out, cols, rows = [], 13, 5
    pts = {}
    for r in range(rows + 1):
        fr = r / rows
        y = HORIZON + (H + 40 - HORIZON) * (fr ** 1.7)
        for c in range(cols + 1):
            jitter = 0.0 if r == 0 else rng.uniform(-9.0, 9.0) * fr
            pts[(r, c)] = (-40 + (W + 80) * c / cols + jitter,
                           y + rng.uniform(-5.0, 5.0) * fr)
    for r in range(rows):
        for c in range(cols):
            a, b = pts[(r, c)], pts[(r, c + 1)]
            d, e = pts[(r + 1, c)], pts[(r + 1, c + 1)]
            near = (r + 1) / rows
            for tri in ((a, b, d), (b, e, d)):
                # Distance darkens toward the horizon; a little noise keeps it
                # from reading as a gradient.
                base = mix(mix(GRASS_DEEP, GRASS, 0.25 + 0.75 * near),
                           SKY_LOW, (1.0 - near) * 0.55)
                col = mix(base, "#000000", rng.uniform(0.0, 0.22))
                if rng.random() < 0.18:
                    col = mix(col, THATCH, rng.uniform(0.04, 0.13))
                out.append(
                    '<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" '
                    'fill="%s"/>' % (tri[0][0], tri[0][1], tri[1][0],
                                     tri[1][1], tri[2][0], tri[2][1], col))
    return out


def hills(rng: random.Random) -> list[str]:
    """Distant relief. A ruled horizon reads as a graphic device; a couple of
    soft humps read as country, which is what the game is about."""
    out = []
    for band, (lift, shade, wob) in enumerate(
            ((34.0, 0.74, 0.9), (18.0, 0.52, 1.7))):
        pts = ["-40,%.1f" % (HORIZON + 6)]
        x = -40.0
        phase = rng.uniform(0.0, math.tau)
        while x <= W + 40:
            y = HORIZON + 4 - lift * (
                0.5 + 0.5 * math.sin(phase + x / (150.0 * wob))) \
                - rng.uniform(0.0, 3.0)
            pts.append("%.1f,%.1f" % (x, y))
            x += 24.0
        pts.append("%.1f,%.1f" % (W + 40, HORIZON + 6))
        out.append('<polygon points="%s" fill="%s"/>'
                   % (" ".join(pts), mix(GRASS_DEEP, SKY_LOW, shade)))
    return out


def trees(rng: random.Random) -> list[str]:
    out = []
    for _ in range(26):
        t = rng.random()
        y = HORIZON + (H - HORIZON) * (t ** 2.2) * 0.62
        x = rng.uniform(-20, W + 20)
        # Keep the road clear: a wood that grew over the route would be a odd
        # thing for this logo to show.
        near_road = any(abs(x - bez(s / 40.0)[0]) < 86
                        and abs(y - bez(s / 40.0)[1]) < 54 for s in range(41))
        if near_road or 760 < x < 1010 and y < 330:
            continue
        depth = (y - HORIZON) / (H - HORIZON)
        s = 7 + 30 * depth
        col = mix(GRASS_DEEP, SKY_LOW, (1 - depth) * 0.5)
        out.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" '
                   'fill="%s"/>' % (x, y - s * 1.9, x - s * 0.62, y,
                                    x + s * 0.62, y, col))
        out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" '
                   'fill="%s"/>' % (x - s * 0.07, y - s * 0.15, s * 0.14,
                                    s * 0.3, mix(TIMBER, SKY_LOW, 0.35)))
    return out


def keep() -> list[str]:
    """The seat of the march: a tower, a hall, and a pennant."""
    x, y = 884.0, 309.0        # where the road arrives
    o = []
    o.append('<ellipse cx="%.1f" cy="%.1f" rx="132" ry="21" fill="%s" '
             'opacity="0.55"/>' % (x, y + 5, mix(GRASS, "#000000", 0.42)))
    # hall
    o.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f %.1f,%.1f" '
             'fill="%s"/>' % (x + 8, y, x + 8, y - 58, x + 96, y - 58,
                              x + 96, y, mix(STONE, "#000000", 0.18)))
    o.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s"/>'
             % (x + 2, y - 56, x + 52, y - 92, x + 102, y - 56, ROOF))
    # tower
    o.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f %.1f,%.1f" '
             'fill="%s"/>' % (x - 62, y, x - 62, y - 126, x - 4, y - 126,
                              x - 4, y, STONE))
    o.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f %.1f,%.1f" '
             'fill="%s"/>' % (x - 24, y, x - 24, y - 126, x - 4, y - 126,
                              x - 4, y, STONE_DARK))
    for i in range(4):          # crenellations
        cx = x - 62 + i * 15.5
        o.append('<rect x="%.1f" y="%.1f" width="9" height="13" fill="%s"/>'
                 % (cx, y - 139, mix(STONE, "#ffffff", 0.06)))
    o.append('<rect x="%.1f" y="%.1f" width="3" height="42" fill="%s"/>'
             % (x - 35, y - 181, STONE_DARK))
    o.append('<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s"/>'
             % (x - 32, y - 181, x - 32, y - 160, x - 6, y - 171, ROOF))
    # windows, warm against the dusk
    for wx, wy in ((x - 50, y - 96), (x - 50, y - 60), (x + 26, y - 40),
                   (x + 58, y - 40)):
        o.append('<rect x="%.1f" y="%.1f" width="7" height="11" fill="%s" '
                 'opacity="0.85"/>' % (wx, wy, THATCH))
    return o


def build() -> str:
    rng = random.Random(1746)
    s: list[str] = []
    s.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
             'viewBox="0 0 %d %d" role="img" '
             'aria-label="Marchlands">' % (W, H, W, H))
    s.append("<defs>")
    s.append('<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">'
             '<stop offset="0" stop-color="%s"/>'
             '<stop offset="1" stop-color="%s"/></linearGradient>'
             % (SKY_TOP, SKY_LOW))
    s.append('<radialGradient id="dusk" cx="0.70" cy="0.58" r="0.42">'
             '<stop offset="0" stop-color="%s" stop-opacity="0.50"/>'
             '<stop offset="1" stop-color="%s" stop-opacity="0"/>'
             "</radialGradient>" % (DUSK, DUSK))
    # The road's own gradient is the whole idea: nothing on the left, a worn
    # road on the right.
    s.append('<linearGradient id="wear" x1="0.06" y1="0" x2="0.68" y2="0">'
             '<stop offset="0" stop-color="%s" stop-opacity="0"/>'
             '<stop offset="0.42" stop-color="%s" stop-opacity="0.55"/>'
             '<stop offset="1" stop-color="%s" stop-opacity="1"/>'
             "</linearGradient>" % (SOIL, TRACK, IMPROVED))
    s.append('<linearGradient id="verge" x1="0.06" y1="0" x2="0.62" y2="0">'
             '<stop offset="0" stop-color="%s" stop-opacity="0"/>'
             '<stop offset="1" stop-color="%s" stop-opacity="0.85"/>'
             "</linearGradient>" % (SOIL, mix(SOIL, "#000000", 0.35)))
    s.append("</defs>")

    s.append('<rect width="%d" height="%d" fill="url(#sky)"/>' % (W, H))
    s.append('<rect width="%d" height="%d" fill="url(#dusk)"/>' % (W, H))
    s.extend(hills(rng))
    s.extend(ground_facets(rng))
    s.extend(trees(rng))

    # Verge first, then the tread over it — the same order the terrain shader
    # composites them in.
    s.append('<path d="%s" fill="none" stroke="url(#verge)" stroke-width="46" '
             'stroke-linecap="round" opacity="0.7"/>' % ROAD_D)
    s.append('<path d="%s" fill="none" stroke="url(#wear)" stroke-width="27" '
             'stroke-linecap="round"/>' % ROAD_D)

    # Footfalls, where there is not yet a road at all.
    for i in range(34):
        t = 0.02 + 0.30 * (i / 33.0)
        px, py = bez(t)
        nx, ny = bez_normal(t)
        off = rng.uniform(-11, 11)
        a = 0.06 + 0.42 * (i / 33.0)
        s.append('<ellipse cx="%.1f" cy="%.1f" rx="4.6" ry="2.5" fill="%s" '
                 'opacity="%.2f" transform="rotate(%.1f %.1f %.1f)"/>'
                 % (px + nx * off, py + ny * off, SOIL, a,
                    math.degrees(math.atan2(ny, nx)) + 90,
                    px + nx * off, py + ny * off))

    s.extend(keep())

    # Wordmark.
    fam = "Noto Serif, Liberation Serif, Georgia, serif"
    s.append('<text x="86" y="150" font-family="%s" font-size="97" '
             'font-weight="600" letter-spacing="7" fill="%s">MARCHLANDS</text>'
             % (fam, INK))
    s.append('<rect x="90" y="176" width="150" height="2" fill="%s" '
             'opacity="0.8"/>' % THATCH)
    s.append('<text x="90" y="215" font-family="%s" font-size="25" '
             'letter-spacing="1.2" fill="%s">Nobody draws the roads.</text>'
             % (fam, INK_DIM))
    s.append("</svg>")
    return "\n".join(s)


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        REPO, "design", "branding")
    os.makedirs(out_dir, exist_ok=True)
    svg_path = os.path.join(out_dir, "logo.svg")
    with open(svg_path, "w", encoding="utf-8") as fh:
        fh.write(build() + "\n")
    print("  logo -> %s" % os.path.relpath(svg_path, REPO))

    png_path = os.path.join(out_dir, "logo.png")
    try:
        subprocess.run(["rsvg-convert", "-w", str(W * 2), "-o", png_path,
                        svg_path], check=True)
        print("  logo -> %s" % os.path.relpath(png_path, REPO))
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        print("  (no PNG: %s)" % exc)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
