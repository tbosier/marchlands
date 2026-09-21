"""Render-target samplers are engine-bound; ordinary textures need a setter."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "validators"))
from check_shaders import declared_uniforms


class ShaderUniformTests(unittest.TestCase):
    def test_engine_texture_hints_do_not_require_game_bindings(self):
        uniforms = declared_uniforms("""
            uniform sampler2D depth : hint_depth_texture, filter_nearest;
            uniform sampler2D screen : hint_screen_texture;
            uniform sampler2D normal : hint_normal_roughness_texture;
            uniform sampler2D visibility : filter_linear;
            uniform float size = 768.0;
            // uniform sampler2D ignored : hint_depth_texture;
        """)
        self.assertEqual(uniforms, {"visibility": False, "size": True})

    def test_misspelled_hint_does_not_suppress_missing_binding(self):
        self.assertEqual(declared_uniforms(
            "uniform sampler2D depth : hint_depth_texture_typo;"), {"depth": False})
