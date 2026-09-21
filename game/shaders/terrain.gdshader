shader_type spatial;
render_mode cull_back, diffuse_lambert;

// Marchlands terrain.
//
// The ground is painted procedurally from height, slope and — crucially — the
// wear field the simulation writes into. As citizens travel, R rises in the
// wear texture and the grass here turns to worn earth, then to a compacted
// track, then to a metalled road. Nothing about the road is authored: this
// shader is simply reading the world's memory of where people walked.
//
//   wear.r : accumulated traffic, perceptually shaped  (0..1)
//   wear.b : player-commissioned road level / 5
// Fertility has a separate static world map shared by all detail levels.
//
// Three things this shader has to do that the first version did not.
//
// The ground is most of every frame, so it cannot be one colour. It now
// carries a slow macro variation — a landscape's worth of drier knolls and
// richer hollows — under the finer grain, which is what stops 768 m of
// meadow reading as billiard cloth.
//
// A road is the game's signature and has to read as one. Beaten ground does
// not simply change colour: grass at the edge is crushed and dark before the
// soil shows through, the middle is scuffed pale where feet fall, and a road
// somebody paid for is cambered and drained. Those three cues are what make a
// route look worn rather than painted, and they are all here.
//
// And the seasons have to reach the ground. The sun and the sky grade with
// the calendar; if the grass does not, autumn is just a colder photograph of
// summer.

uniform sampler2D wear_map : filter_linear, repeat_disable;
uniform sampler2D fertility_map : filter_linear, repeat_disable;
uniform float world_size = 768.0;
uniform vec2 wear_origin = vec2(0.0);
uniform float wear_size = 0.0;

uniform vec3 color_grass : source_color = vec3(0.36, 0.46, 0.25);
uniform vec3 color_grass_dry : source_color = vec3(0.52, 0.54, 0.31);
uniform vec3 color_soil : source_color = vec3(0.36, 0.28, 0.19);
uniform vec3 color_rock : source_color = vec3(0.45, 0.44, 0.42);
uniform vec3 color_sand : source_color = vec3(0.68, 0.62, 0.46);
uniform vec3 color_path : source_color = vec3(0.46, 0.39, 0.28);
uniform vec3 color_track : source_color = vec3(0.40, 0.34, 0.25);
uniform vec3 color_improved : source_color = vec3(0.55, 0.51, 0.41);
uniform vec3 color_paved : source_color = vec3(0.44, 0.43, 0.42);
uniform vec3 color_marsh : source_color = vec3(0.26, 0.31, 0.22);

uniform float sea_level = 2.2;
uniform float rock_height = 26.0;

// Season. Driven from World._apply_season; the defaults are high spring so the
// shader still looks right if it is ever loaded without a game around it.
uniform vec3 season_tint = vec3(1.0, 1.0, 1.0);
uniform float season_dry : hint_range(0.0, 1.0) = 0.15;
uniform float season_frost : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_world;
varying float v_height;
// The world-space normal, carried across from the vertex stage.
//
// This has to be a varying. In a Godot spatial shader NORMAL is *view space*
// in the fragment function, so reading NORMAL.y there asks "how much does this
// face point towards the top of the screen", not "how much does it point at
// the sky" — and the answer changes every time the player rotates or tilts the
// camera. The terrain was classifying its own slope that way, which meant rock
// appeared and disappeared on unchanged ground as the camera moved. Everything
// that wants to know which way is up now reads this instead.
varying vec3 v_normal;

// Cheap value noise. Used to break up every boundary so nothing in the
// landscape reads as a straight grid edge.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Three octaves rather than four. The fourth cost a quarter of this function
// for a wavelength of about a metre and a third, which is finer than the
// road-edge and meadow detail the result is actually used for — and the
// budget it frees pays for the macro variation and the scuff layer below,
// which do far more work per instruction.
float fbm(vec2 p) {
	float v = vnoise(p) * 0.5;
	p *= 2.03;
	v += vnoise(p) * 0.25;
	p *= 2.03;
	v += vnoise(p) * 0.125;
	return v * 1.143;      // renormalised to ~0..1
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_height = v_world.y;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = (v_world.xz - wear_origin) / (wear_size > 0.0 ? wear_size : world_size);
	vec4 field = texture(wear_map, uv);
	float fertility = texture(fertility_map, v_world.xz / world_size).r;

	vec3 n = normalize(v_normal);
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);

	// Distance from the eye, used to fade the fine grain out before it starts
	// to sparkle. VERTEX is view space in the fragment stage, so its length is
	// the camera distance.
	float view_dist = length(VERTEX);
	float near = 1.0 - smoothstep(60.0, 170.0, view_dist);

	float grain = fbm(v_world.xz * 0.09);
	float coarse = vnoise(v_world.xz * 0.021);
	// The slowest layer: whole hillsides drier or greener than their
	// neighbours, on a scale of a couple of hundred metres.
	float macro = vnoise(v_world.xz * 0.0055);

	// --- base ground ------------------------------------------------------
	// Dryness is part landscape and part calendar. A summer meadow is mostly
	// straw with green in the hollows; a spring one is the reverse.
	//
	// The season sets the *centre* of the range and the noise swings either
	// side of it, rather than the season being added on top of the noise. The
	// difference matters: added on top, autumn's offset drove roughly two
	// thirds of the map hard against the clamp, so the season that ought to be
	// the richest in the year came out as one flat sheet of straw with no
	// landscape left in it at all.
	float variation = (coarse - 0.5) * 0.62 + (macro - 0.5) * 0.42;
	float dryness = clamp(0.18 + season_dry * 0.62 + variation, 0.0, 1.0);
	vec3 albedo = mix(color_grass, color_grass_dry, dryness);

	// Fertile lowland reads greener and richer; this is where farms belong.
	albedo = mix(albedo, color_grass * 0.88 + vec3(0.01, 0.05, 0.0),
			clamp(fertility * 1.1, 0.0, 1.0) * 0.55);

	// Slow value variation. Nothing about the hue, only the light on it —
	// which is what a landscape actually does, and what a single flat green
	// never will.
	albedo *= 0.90 + macro * 0.20 + (coarse - 0.5) * 0.07;

	// Ground facing the sky picks up more of it and is fractionally cooler
	// and lighter; a bank leaning away is warmer and deeper. It is a cheap
	// stand-in for sky occlusion and bounce, and it is most of what makes
	// rolling ground read as rolling.
	float facing = clamp(n.y, 0.0, 1.0);
	albedo *= mix(vec3(1.04, 1.00, 0.94), vec3(0.97, 1.00, 1.05),
			smoothstep(0.55, 1.0, facing));
	albedo *= mix(0.82, 1.0, smoothstep(0.0, 0.45, facing));

	// Season. The *tint* is for living ground only, so it goes on before rock,
	// sand and road, none of which change colour with the year. Frost, further
	// down, is applied after them on purpose: rime settles on a bare crag and a
	// cold beach as readily as on grass.
	albedo *= season_tint;

	// --- marsh, shore and rock --------------------------------------------
	// Wet ground in the hollows just above the waterline: darker, bluer and
	// flatter than meadow. The heightmap knows where the marsh is; the shader
	// only has height and fertility, and between them they land in the same
	// places closely enough to be worth having.
	float wet_band = (1.0 - smoothstep(sea_level + 0.4, sea_level + 5.0,
			v_height - grain * 1.6))
			* smoothstep(sea_level - 1.0, sea_level + 0.6, v_height);
	albedo = mix(albedo, color_marsh * (0.9 + grain * 0.25),
			wet_band * clamp(fertility * 0.8 + 0.35, 0.0, 1.0) * 0.8);

	// Rock takes over on steep faces and high ground.
	float rocky = smoothstep(0.30, 0.58, slope + grain * 0.12 - 0.04);
	rocky = max(rocky, smoothstep(rock_height - 4.0, rock_height + 6.0,
			v_height + grain * 3.0));
	// Rock is not one grey: strata read as bands of value, which is most of
	// what makes low-poly cliffs look like cliffs.
	float strata = vnoise(vec2(v_world.x * 0.06, v_height * 0.55));
	albedo = mix(albedo, color_rock * (0.74 + grain * 0.28 + strata * 0.22),
			rocky);

	// Shoreline sand, darkening as it goes under.
	float shore = 1.0 - smoothstep(sea_level - 0.2, sea_level + 1.5,
			v_height - grain * 0.5);
	float wet_sand = 1.0 - smoothstep(sea_level - 0.6, sea_level + 0.35,
			v_height);
	vec3 sand = color_sand * mix(1.0, 0.62, wet_sand);
	albedo = mix(albedo, sand, shore * 0.85);

	// Frost. Winter lays it on what faces the sky and on what stands highest,
	// which leaves the sheltered hollows green and the ridges pale — the
	// shape of the land drawn in tone.
	float frost = season_frost
			* smoothstep(0.55, 0.95, facing)
			* (0.45 + 0.55 * smoothstep(4.0, 22.0, v_height))
			* (0.55 + 0.45 * grain);
	// A pale cold grey, not white: this is rime on the ridges, not snowfall.
	// Every other colour in this shader is linear, and a literal near 0.8 here
	// would land around 90% in sRGB and read as a January blizzard.
	albedo = mix(albedo, mix(albedo, vec3(0.55, 0.58, 0.63), 0.62),
			clamp(frost, 0.0, 1.0));

	// --- the road the world remembers -------------------------------------
	// field.r is the surface level normalised to 0..1, so the five stages sit
	// at exactly 0.2 / 0.4 / 0.6 / 0.8 / 1.0. The value is perturbed by noise
	// so the edge of a trail is ragged and organic rather than a clean texel
	// boundary, and the bands overlap slightly so no stage shows a hard rim.
	float w = field.r + (grain - 0.5) * 0.045;

	float worn     = smoothstep(0.06, 0.21, w);   // grass beaten down
	float path     = smoothstep(0.25, 0.41, w);   // bare earth footpath
	float track    = smoothstep(0.45, 0.61, w);   // rutted cart track
	float improved = smoothstep(0.65, 0.81, w);   // drained, compacted
	float paved    = smoothstep(0.85, 0.97, w);   // metalled

	// The verge. Before grass gives way to soil it is trodden flat, bruised
	// and darker than the meadow around it, and it stays that way in a band
	// either side of everything from a footpath to a highway. That dark
	// margin is what gives a route an edge instead of an airbrushed fade —
	// and it is the single change that makes a forming path visible from the
	// strategic camera, which is the whole point of the mechanic.
	float verge = worn * (1.0 - path * 0.85);
	albedo *= mix(1.0, 0.70, verge);

	albedo = mix(albedo, mix(albedo, color_soil, 0.55), worn);
	albedo = mix(albedo, color_path * (0.92 + grain * 0.16), path);
	albedo = mix(albedo, color_track * (0.94 + grain * 0.12), track);
	albedo = mix(albedo, color_improved * (0.96 + grain * 0.09), improved);
	albedo = mix(albedo, color_paved * (0.97 + grain * 0.06), paved);

	// Scuff. Where feet actually fall the surface is polished paler than the
	// soil either side of it, at a finer scale than the path's own edge.
	//
	// Skipped outright past the fade distance rather than multiplied by a zero
	// weight, which would still pay for the noise. The branch is on camera
	// distance, so whole tiles of the screen take the same side of it and it
	// costs nothing in divergence.
	if (near > 0.004 && path > 0.004) {
		float scuff = (vnoise(v_world.xz * 0.55) - 0.5) * 0.30 * near;
		albedo *= 1.0 + scuff * path;
	}

	// A commissioned road is cambered: brighter and drier along its crown,
	// with the water-shedding fall away to either side reading darker. So
	// deliberate infrastructure looks built rather than merely trodden.
	float built = field.b * improved;
	float crown = smoothstep(0.70, 0.94, w);
	albedo = mix(albedo, albedo * 1.14, built * crown * 0.8);
	albedo = mix(albedo, albedo * 0.84, built * (1.0 - crown) * improved * 0.6);

	ALBEDO = albedo;

	// Surfaces are not all equally matt. Compacted and metalled road takes a
	// low sheen, wet sand at the waterline takes rather more, and meadow takes
	// none — which is what lets the eye tell a road from a repaint of the
	// grass when the sun is low.
	float hard = max(improved, paved);
	ROUGHNESS = mix(0.96, 0.66, max(hard, wet_sand * shore));
	SPECULAR = mix(0.03, 0.22, max(hard * 0.7, wet_sand * shore));

	// A little contact darkening in the verge and on rock, so the ground has
	// somewhere to sit rather than floating at one brightness. Kept light,
	// because the verge already takes thirty per cent out of the albedo above
	// and the two compound.
	AO = clamp(1.0 - verge * 0.20 - rocky * 0.10, 0.0, 1.0);
	AO_LIGHT_AFFECT = 0.35;
}
