// Wizard Wars' half of the map's shaders. goldsrc-godot builds plain GoldSrc ones and includes this
// (GoldSrcBSP.shader_hook, set by MapConverter) with GOLDSRC_HOOK_WORLD, _LIQUID or _SKY defined;
// the calls and their arguments are listed at with_shader_hook in goldsrc_bsp.cpp. Night, lightning
// and rain are ours, so they live here. Resolved when a shader compiles, at load: a change here
// needs no map reconvert, but a change to a signature has to match the extension's calls.

#ifdef GOLDSRC_HOOK_WORLD
// NightMode: a linear-light multiplier on the sky's share of each luxel — night, a fade on a sun
// that shares style 0 with the lights, and lightning on top.
uniform vec3 sky_light = vec3(1.0);

// WeatherSystem: how wet the world is (0 dry, 1 soaked) and how far flat ground has pooled into
// puddles; where rain reaches, as the map's rain floor (MapConverter, GoldSrcBSP.bake_rain_floor),
// whose max-X/min-Z corner sits at rain_floor_origin; and the linear sky colour wet surfaces reflect.
uniform float wetness = 0.0;
uniform float puddles = 0.0;
uniform float puddle_scale = 1.0;  // how readily this surface pools: earth does, planks drain
uniform sampler2D rain_floor : filter_nearest;
uniform vec3 rain_floor_origin;
uniform vec2 rain_floor_size = vec2(1.0);
uniform vec3 rain_sky = vec3(0.0);

vec3 goldsrc_lightmap(vec3 lm, float sun_share) {
	// Lightmaps hold pow(light, 0.55), so the share is scaled before that curve, not after.
	return lm * pow(max(mix(vec3(1.0), sky_light, sun_share), vec3(0.0)), vec3(0.55));
}

// 1 where rain reaches world point p, 0 under cover. The floor's cells are 16 units across, so
// the four around p are blended: a roof's shadow on the ground is not drawn as a staircase.
float rain_reaches(vec3 p) {
	vec2 uv = vec2((rain_floor_origin.x - p.x) / rain_floor_size.x, (p.z - rain_floor_origin.z) / rain_floor_size.y);
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
		return 0.0;
	}
	ivec2 res = textureSize(rain_floor, 0);
	vec2 texel = uv * vec2(res) - 0.5;
	ivec2 cell = ivec2(floor(texel));
	vec2 f = fract(texel);
	vec4 reach;
	for (int i = 0; i < 4; i++) {
		ivec2 c = clamp(cell + ivec2(i % 2, i / 2), ivec2(0), res - 1);
		// Fully wet at the height rain stops, drying over the quarter metre below it.
		reach[i] = clamp((p.y - texelFetch(rain_floor, c, 0).r) * 4.0 + 1.0, 0.0, 1.0);
	}
	return mix(mix(reach.x, reach.y, f.x), mix(reach.z, reach.w, f.x), f.y);
}

float rain_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float rain_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(rain_hash(i), rain_hash(i + vec2(1.0, 0.0)), f.x),
		mix(rain_hash(i + vec2(0.0, 1.0)), rain_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Wet is darker, and reflects the sky: a damp surface at grazing angles only (water's Fresnel,
// F0 0.02), a puddle as a mirror-flat layer of water over a darker floor. A ceiling stays dry; a
// wall asks about the air half a metre out from it, and takes less.
void goldsrc_surface(inout vec3 lit_srgb, inout vec3 albedo, vec3 world_pos, vec3 world_normal,
		vec3 normal_view, vec3 view) {
	if (wetness <= 0.0 || world_normal.y < -0.3) {
		return;
	}
	float reach = world_normal.y > 0.3 ? rain_reaches(world_pos + world_normal * 0.02)
		: rain_reaches(world_pos + world_normal * 0.5) * 0.6;
	float wet = wetness * reach;
	if (wet <= 0.0) {
		return;
	}
	float pool = 0.0;
	if (world_normal.y > 0.95) {
		float n = rain_noise(world_pos.xz * 0.55) * 0.7 + rain_noise(world_pos.xz * 2.3) * 0.3;
		float edge = mix(1.05, 0.55, puddles * puddle_scale);
		pool = smoothstep(edge, edge + 0.05, n) * reach;
	}
	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(normal_view, view), 0.0, 1.0), 5.0);
	vec3 sky = mix(rain_sky * 12.92, 1.055 * pow(max(rain_sky, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055,
		step(0.0031308, rain_sky));
	// A puddle shows the floor under it darker and the sky over it brighter than its Fresnel alone
	// would: the sky it reflects is far brighter than anything the lightmaps put on the ground.
	float dark = mix(1.0, 0.6, wet) * mix(1.0, 0.6, pool);
	float mirror = mix(wet * 0.5 * fresnel, max(fresnel * 2.0, 0.1), pool);
	lit_srgb = min(lit_srgb * dark + sky * mirror, vec3(1.0));
	albedo *= dark;
}
#endif

#ifdef GOLDSRC_HOOK_LIQUID
// NightMode. Liquid is fullbright, so it has no lightmap share to turn down: this dims it whole.
uniform vec3 sky_light = vec3(1.0);

vec3 goldsrc_liquid(vec3 albedo, int liquid_type) {
	return liquid_type == 2 ? albedo : albedo * pow(max(sky_light, vec3(0.0)), vec3(0.55));  // lava keeps its glow
}
#endif

#ifdef GOLDSRC_HOOK_SKY
// Lightning (Skybox.set_flash): the sky lit from within, brightest toward flash_dir (world space).
// Black is no flash.
uniform vec3 flash_color = vec3(0.0);
uniform vec3 flash_dir = vec3(0.0, 1.0, 0.0);

vec3 goldsrc_sky(vec3 col, vec3 eye_dir) {
	// Clouds have something to light and open sky only a glow, so it multiplies and then adds.
	float toward = max(dot(eye_dir, normalize(flash_dir)), 0.0);
	col *= vec3(1.0) + flash_color * (1.0 + 3.0 * pow(toward, 3.0));
	return col + flash_color * (0.3 + 0.9 * pow(toward, 4.0));
}
#endif
