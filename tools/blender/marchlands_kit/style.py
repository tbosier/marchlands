"""Loads and exposes the Marchlands machine-readable style specification.

Everything the generators and validators need to agree on lives in
assets/specs/style.yaml and assets/specs/materials/materials.yaml. This module
is the single point where those files are parsed, so the pipeline can never
drift from the spec.

Deliberately uses a tiny hand-rolled YAML reader: Blender's bundled Python has
no PyYAML, and the spec files are a restricted subset (mappings, lists of
scalars, lists of mappings, comments).
"""

from __future__ import annotations

import os
import re

REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..")
)
SPEC_DIR = os.path.join(REPO_ROOT, "assets", "specs")


# --------------------------------------------------------------------------
# Minimal YAML subset parser
# --------------------------------------------------------------------------

def _coerce(raw: str):
    raw = raw.strip()
    if raw == "" or raw == "~" or raw == "null":
        return None
    if len(raw) >= 2 and raw[0] in "\"'" and raw[-1] == raw[0]:
        return raw[1:-1]
    low = raw.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if raw.startswith("[") and raw.endswith("]"):
        inner = raw[1:-1].strip()
        if not inner:
            return []
        return [_coerce(part) for part in inner.split(",")]
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    if re.fullmatch(r"-?\d*\.\d+(e-?\d+)?", raw, re.IGNORECASE):
        return float(raw)
    return raw


def _strip_comment(line: str) -> str:
    out = []
    quote = None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def parse_yaml(text: str):
    """Parse the restricted YAML subset used by Marchlands spec files."""
    lines = []
    for raw in text.splitlines():
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append((indent, stripped.strip()))

    def block(start: int, indent: int):
        """Return (value, next_index) for the block at the given indent."""
        items = []
        mapping = {}
        i = start
        while i < len(lines):
            ind, content = lines[i]
            if ind < indent:
                break
            if ind > indent:
                # Defensive: malformed file, skip deeper stray lines.
                i += 1
                continue

            if content.startswith("- "):
                entry = content[2:].strip()
                if ":" in entry and not entry.startswith(("\"", "'")):
                    key, _, rest = entry.partition(":")
                    sub = {key.strip(): _coerce(rest)}
                    i += 1
                    if i < len(lines) and lines[i][0] > indent:
                        nested, i = block(i, lines[i][0])
                        if isinstance(nested, dict):
                            sub.update(nested)
                    items.append(sub)
                else:
                    items.append(_coerce(entry))
                    i += 1
                continue

            key, _, rest = content.partition(":")
            key = key.strip()
            rest = rest.strip()
            if rest:
                mapping[key] = _coerce(rest)
                i += 1
            else:
                i += 1
                if i < len(lines) and lines[i][0] > indent:
                    value, i = block(i, lines[i][0])
                    mapping[key] = value
                else:
                    mapping[key] = None
        return (items if items else mapping), i

    value, _ = block(0, lines[0][0] if lines else 0)
    return value


def load_yaml(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return parse_yaml(handle.read())


# --------------------------------------------------------------------------
# Spec access
# --------------------------------------------------------------------------

_STYLE = None
_MATERIALS = None


def style() -> dict:
    global _STYLE
    if _STYLE is None:
        _STYLE = load_yaml(os.path.join(SPEC_DIR, "style.yaml"))
    return _STYLE


def material_library() -> dict:
    global _MATERIALS
    if _MATERIALS is None:
        data = load_yaml(os.path.join(SPEC_DIR, "materials", "materials.yaml"))
        _MATERIALS = data["materials"]
    return _MATERIALS


def triangle_budget(category: str, asset_id: str = "") -> int:
    budgets = style()["triangle_budget"]
    overrides = budgets.get("overrides") or {}
    if asset_id and asset_id in overrides:
        return int(overrides[asset_id])
    return int(budgets[category])


def lod_ratios() -> dict:
    return style()["lod"]["ratios"]


def lod_strategy(category: str) -> str:
    """"detail" (drop detail tiers) or "decimate" (collapse triangles)."""
    table = style()["lod"].get("strategy") or {}
    return str(table.get(category, "decimate"))


def lod_detail_tier(level: int) -> int:
    """Highest detail tier kept at `level` under the "detail" strategy."""
    return int(style()["lod"]["detail_tiers"][f"lod{level}"])


def max_materials_per_asset() -> int:
    return int(style()["materials"]["max_per_asset"])


def hex_to_linear(hex_color: str):
    """sRGB hex -> linear RGB tuple, matching Blender's colour management."""
    hex_color = hex_color.lstrip("#")
    srgb = [int(hex_color[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    out = []
    for c in srgb:
        if c <= 0.04045:
            out.append(c / 12.92)
        else:
            out.append(((c + 0.055) / 1.055) ** 2.4)
    return tuple(out)
