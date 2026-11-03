// High-quality replacement for the sky-brush shader in goldsrc_bsp.cpp.
//
// It stands in for that shader rather than beside it: the render modes and the eye-direction
// reconstruction are copied verbatim, so a sky brush draws in the same pass, at the same depth,
// with the same sampler still bound. Only the right-hand side of ALBEDO changes — a 256x256
// cubemap fetch becomes a gradient, a sun, clouds and stars evaluated from the same direction.
//
// Everything is authored in whatever space the cubemap was: colours arrive as source_color and
// get exactly the treatment a source_color sampler would, so the RD renderers convert them and
// gl_compatibility does not, matching the world shaders' "multiply in gamma, convert once" rule.
// See goldsrc_bsp.cpp's lightstyle shaders for the twin of that argument.
//
// No cubemap sampling happens unless cubemap_blend is raised, but the sampler stays declared under
// its original name so Skybox can keep filling it and dial back to the shipped art per sky.
shader_type spatial;
render_mode unshaded, shadows_disabled, ambient_light_disabled, depth_draw_never;

uniform samplerCube sky_cubemap : source_color, hint_default_black;
// 0 = fully procedural, 1 = the shipped 256px art. The escape hatch for a sky the procedural
// model has no vocabulary for.
uniform float cubemap_blend : hint_range(0.0, 1.0) = 0.0;

uniform vec3 zenith_color : source_color = vec3(0.25, 0.42, 0.70);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.70, 0.82);
uniform vec3 ground_color : source_color = vec3(0.18, 0.17, 0.16);
// How fast zenith wins over horizon. Low = a broad hazy band, high = colour only at the top.
uniform float horizon_falloff : hint_range(0.2, 4.0) = 1.1;

// Direction TO the sun, world space. Skybox derives it from the map's own light_environment.
uniform vec3 sun_dir = vec3(0.0, 0.6, -0.8);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.82);
uniform float sun_size : hint_range(0.002, 0.5) = 0.012;   // angular radius, radians
uniform float sun_energy : hint_range(0.0, 8.0) = 2.2;
uniform float sun_glow_exp : hint_range(1.0, 2048.0) = 320.0;
uniform float sun_glow_energy : hint_range(0.0, 3.0) = 0.35;
// The wide whitish brightening the air puts around the sun, and along the horizon below it.
uniform float sun_halo_energy : hint_range(0.0, 2.0) = 0.25;
uniform float sun_halo_exp : hint_range(1.0, 64.0) = 6.0;

uniform float cloud_amount : hint_range(0.0, 1.0) = 0.45;
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
// A thin, streaky layer high over the main one, drifting faster.
uniform float cirrus_amount : hint_range(0.0, 1.0) = 0.5;

uniform float star_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 star_color : source_color = vec3(1.0, 1.0, 1.0);

// Rain: 0 is the sky as measured from its art, 1 a full storm — the deck closes over, its clouds
// go dark and heavy, the sky behind them greys, and sun, moon and stars are lost. Everything
// is relative to the sky's own colours, so a storm at night stays a night sky.
uniform float storm : hint_range(0.0, 1.0) = 0.0;
const vec3 LUMA = vec3(0.299, 0.587, 0.114);

// Lightning: flash_color/flash_dir and goldsrc_sky(), the same flash the stock sky draws.
#define GOLDSRC_HOOK_SKY
#include "res://shaders/goldsrc_hook.gdshaderinc"
#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/clouds.gdshaderinc"

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}



void fragment() {
	// Identical to the stock sky shader: VIEW points fragment->camera in view space, so negate
	// and rotate to get the world direction the player is looking along.
	vec3 eye_dir = normalize((INV_VIEW_MATRIX * vec4(-VIEW, 0.0)).xyz);
	vec3 sun = normalize(sun_dir);
	float up = eye_dir.y;

	// Gradient. Above and below the horizon are the same expression mirrored, so the seam at
	// y=0 is exactly horizon_color from both sides and never shows.
	vec3 above = mix(horizon_color, zenith_color, pow(clamp(up, 0.0, 1.0), horizon_falloff));
	vec3 below = mix(horizon_color, ground_color, pow(clamp(-up, 0.0, 1.0), horizon_falloff));
	vec3 col = mix(below, above, step(0.0, up));
	// What a storm cloud is measured against: the sky it covers, not the cloud colour the art
	// suggested, which on a moonlit sky is pale and would light the deck up at night.
	float sky_lum = dot(col, LUMA);
	col = mix(col, vec3(sky_lum) * 0.55, storm);

	// Stars before clouds and sun, so both occlude them.
	if (star_amount > 0.0) {
		vec3 sp = eye_dir * 320.0;
		vec3 cell = floor(sp);
		float h = hash13(cell);
		// star_amount is a density, but the useful range is tiny — one cell in a few hundred.
		float lit = step(1.0 - star_amount * 0.035, h);
		float d = length(fract(sp) - 0.5);
		float twinkle = 0.65 + 0.35 * sin(TIME * 1.7 + h * 217.0);
		col += star_color * smoothstep(0.42, 0.0, d) * lit * twinkle * (1.0 - storm);
	}

	// Clouds live on a shell over the map (clouds.gdshaderinc), traced from the camera.
	float amount = cloud_cover;   // Skybox: cloud_amount, closing over with the storm
	float storm_cover = 0.0;   // where storm cloud sits, for the lightning below to light it
	float storm_body = 0.0;
	float sun_hidden = 0.0;
	if (amount > 0.0) {
		vec3 cam = CAMERA_POSITION_WORLD;
		float dist = cloud_distance(cam, eye_dir);
		vec2 wind = cloud_wind();
		vec2 layer = cloud_layer(cam, eye_dir, dist);
		vec2 cp = layer + wind;
		float toward = clamp(dot(eye_dir, sun) * 0.5 + 0.5, 0.0, 1.0);
		// The sky lights the shadowed side, so it takes the sky's colour rather than a grey.
		vec3 ambient = mix(zenith_color, horizon_color, 0.5);
		vec3 shadow_col = mix(vec3(dot(ambient, LUMA)), ambient, 0.6) * 0.9;
		vec3 lit_col = cloud_color * mix(vec3(1.0), sun_color, 0.5);
		float far = smoothstep(1.5 * CLOUD_HEIGHT, cloud_horizon(cam), dist);

		if (cirrus_amount > 0.0 && cloud_amount > 0.0) {
			vec2 hp = layer * 0.6;
			float c = cloud_tex(vec2(hp.x * 0.25, hp.y) + wind * 2.5 + vec2(3.7, 1.3));
			float ci = smoothstep(0.55, 0.85, c) * cirrus_amount * 0.45 * (1.0 - storm) * (1.0 - far);
			col = mix(col, mix(ambient, lit_col, 0.7), ci * smoothstep(0.0, 0.15, up));
		}

		float n = cloud_density(cp);
		float edge = cloud_edge(amount);
		float cover = cloud_coverage(n, amount);
		cover *= smoothstep(-0.02, 0.12, up) * (1.0 - 0.5 * far);
		// Self-shadowing: more cloud between here and the sun means this side faces away from it.
		float toward_sun = cloud_tex(cp + normalize(sun.xz + vec2(1e-4)) * 0.35);
		float shade = clamp(0.7 + (n - toward_sun) * 8.0, 0.0, 1.0);
		shade *= 1.0 - 0.4 * smoothstep(edge, edge + 0.25, n);   // thick cores are darker
		vec3 lit = mix(shadow_col, lit_col, shade * mix(0.6, 1.0, toward));
		// Storm cloud: grey, darker than the sky it closes over, and mottled by the same noise
		// that shaped it so a full deck still has bodies to it rather than one flat lid.
		storm_body = clamp(0.55 + 0.7 * n, 0.4, 1.3);
		vec3 heavy = vec3(sky_lum) * mix(0.6, 1.1, toward * toward) * storm_body * mix(0.8, 1.0, shade);
		lit = mix(lit, heavy, storm);
		// Thin cloud near the sun glows at its edges: light scattered forward through it.
		float rim = cover * (1.0 - cover) * 4.0;
		lit += sun_color * pow(max(dot(eye_dir, sun), 0.0), 24.0) * rim * 0.5 * (1.0 - storm);
		// Distant cloud sinks into the horizon haze.
		lit = mix(lit, col, far * 0.5);
		storm_cover = cover * storm;
		col = mix(col, lit, cover);
		sun_hidden = cover;
	}

	// Sun last. Thin cloud dims it and thick cloud hides the disc; the glow leaks through.
	float sd = dot(eye_dir, sun);
	float disc = smoothstep(cos(sun_size * 1.4), cos(sun_size), sd);
	float sun_through = 1.0 - 0.95 * storm;
	col += sun_color * disc * sun_energy * sun_through * (1.0 - smoothstep(0.15, 0.75, sun_hidden));
	col += sun_color * pow(max(sd, 0.0), sun_glow_exp) * sun_glow_energy * sun_through * (1.0 - 0.6 * sun_hidden);
	// The halo is the air between us and the cloud, so it sits over cloud and sky alike.
	vec2 flat_eye = normalize(eye_dir.xz + vec2(1e-5));
	vec2 flat_sun = normalize(sun.xz + vec2(1e-5));
	float horizon_band = pow(1.0 - abs(up), 8.0) * pow(max(dot(flat_eye, flat_sun), 0.0), 3.0);
	vec3 halo_color = mix(sun_color, vec3(1.0), 0.4);
	col += halo_color * sun_halo_energy * sun_through
		* (pow(max(sd, 0.0), sun_halo_exp) + 0.35 * horizon_band);

	if (cubemap_blend > 0.0) {
		vec3 art = texture(sky_cubemap, vec3(-eye_dir.x, eye_dir.y, eye_dir.z)).rgb;
		art = mix(art, vec3(dot(art, LUMA)) * 0.5, storm);
		col = mix(col, art, cubemap_blend);
	}
	// Lightning, plus the storm deck lit from inside: dark cloud has nothing for the flash's
	// multiply to lift, so its shape is added outright.
	col = goldsrc_sky(col, eye_dir);
	if (flash_color != vec3(0.0)) {
		float toward = max(dot(eye_dir, normalize(flash_dir)), 0.0);
		col += flash_color * storm_cover * storm_body * (0.25 + 0.9 * pow(toward, 2.0));
	}
	// A step of dither, so the wide smooth gradients do not band in 8 bits.
	col += (hash12(FRAGCOORD.xy) - 0.5) / 255.0;
	ALBEDO = col;
}
