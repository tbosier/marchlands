shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D visibility_map : repeat_disable, filter_linear;
uniform float world_size = 768.0;
uniform float sea_level = 2.2;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float depth = textureLod(scene_depth, SCREEN_UV, 0.0).r;
	// Reverse-Z's zero is the sky. Ground, mountains and water are located
	// from their own depth; a horizontal fog plane would cut through hills.
	float opacity = 0.0;
	if (depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
		#endif
		vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view /= view.w;
		vec3 position = (INV_VIEW_MATRIX * view).xyz;
		// Transparent water does not populate the opaque depth buffer. Where
		// it covers a seabed, locate the water along the same camera ray. This
		// also works for orthographic cameras and steep shores.
		if (position.y < sea_level) {
			vec4 near_view = INV_PROJECTION_MATRIX * vec4(ndc.xy, 1.0, 1.0);
			near_view /= near_view.w;
			vec3 origin = (INV_VIEW_MATRIX * near_view).xyz;
			if (origin.y > sea_level) {
				position = mix(origin, position,
					(sea_level - origin.y) / (position.y - origin.y));
			}
		}
		vec2 uv = position.xz / world_size;
		vec2 known = texture(visibility_map, uv).rg;
		if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
			known = vec2(0.0);
		}
		float explored = smoothstep(0.05, 0.95, known.r);
		float visible = smoothstep(0.05, 0.95, known.g);
		opacity = mix(1.0, 0.58, explored) * (1.0 - visible);
	}
	ALBEDO = vec3(0.025, 0.034, 0.045);
	ALPHA = opacity;
}
