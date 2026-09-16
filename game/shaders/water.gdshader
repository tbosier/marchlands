shader_type spatial;
render_mode cull_disabled, diffuse_lambert, blend_mix;

// Marchlands water.
//
// One plane at sea level covering the whole map and beyond, so the lakes and
// the sea at the world's edge are the same surface. It replaces a flat
// translucent blue quad, which gave the lake a hard rim, a single dead tone
// and no indication that it was liquid at all.
//
// Everything here is analytic: no depth buffer read, no render target, no
// texture. That is deliberate. The game runs on the Compatibility renderer,
// and rather than depend on what a transparent surface may or may not be able
// to sample there, the shape of the water is worked out from world position
// and view angle alone — four value-noise lookups per pixel, on a mesh of
// nine vertices.

uniform vec3 color_body : source_color = vec3(0.07, 0.17, 0.25);
uniform vec3 color_surface : source_color = vec3(0.22, 0.42, 0.44);
uniform vec3 color_foam : source_color = vec3(0.78, 0.84, 0.82);
uniform float wave_scale = 0.11;
uniform float wave_speed = 0.09;
/// Looking straight down you see into the water; at a grazing angle it turns
/// to sky and closes up. The pair of alphas is that difference.
uniform float alpha_down : hint_range(0.0, 1.0) = 0.66;
uniform float alpha_glancing : hint_range(0.0, 1.0) = 0.94;

varying vec3 v_world;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz * wave_scale;
	float t = TIME * wave_speed;

	// Two noise fields drifting against each other at different rates and
	// scales, so the surface never settles into a repeating pattern. Their
	// weighted sum is the height, which drives the colour and the foam.
	float a = vnoise(p + vec2(t, t * 0.6));
	float b = vnoise(p * 1.9 - vec2(t * 0.7, t * 1.3));
	float h = a * 0.65 + b * 0.35;

	// The slope is a finite difference of the *first* field only — two more
	// taps rather than four, and at this scale the second field contributes
	// nothing to the normal the eye could name.
	float dx = vnoise(p + vec2(0.35 + t, t * 0.6)) - a;
	float dz = vnoise(p + vec2(t, 0.35 + t * 0.6)) - a;
	// NORMAL is view space in the fragment stage, so the world-space slope has
	// to be carried across before it is added.
	vec3 ripple = (VIEW_MATRIX * vec4(dx, 0.0, dz, 0.0)).xyz;
	vec3 n = normalize(NORMAL + ripple * 2.2);
	NORMAL = n;

	// Grazing angles reflect the sky and read pale; looking straight down you
	// see into the water, which reads dark. That difference alone is most of
	// what tells the eye a surface is liquid.
	float facing = clamp(dot(n, normalize(VIEW)), 0.0, 1.0);
	float glance = pow(1.0 - facing, 2.4);

	vec3 col = mix(color_body, color_surface, clamp(h * 0.7 + glance, 0.0, 1.0));

	// A thread of foam on the crests, brighter where the surface turns over.
	float crest = smoothstep(0.66, 0.88, h);
	col = mix(col, color_foam, crest * 0.16);

	ALBEDO = col;
	ALPHA = mix(alpha_down, alpha_glancing, glance);
	ROUGHNESS = mix(0.06, 0.22, h);
	SPECULAR = 0.65;
	METALLIC = 0.0;
}
