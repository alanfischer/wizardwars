// Wizard Wars' half of the map's shaders. goldsrc-godot builds plain GoldSrc ones and includes this
// (GoldSrcBSP.shader_hook, set by MapConverter) with GOLDSRC_HOOK_WORLD, _LIQUID or _SKY defined;
// the calls and their arguments are listed at with_shader_hook in goldsrc_bsp.cpp. Night, lightning
// and rain are ours, so they live here. Resolved when a shader compiles, at load: a change here
// needs no map reconvert, but a change to a signature has to match the extension's calls.

#ifdef GOLDSRC_HOOK_WORLD
// NightMode: a linear-light multiplier on the sky's share of each luxel — night, a fade on a sun
// that shares style 0 with the lights, and lightning on top.
uniform vec3 sky_light = vec3(1.0);
// MapSun: 1 when a real-time sun with shadows lights the map, so the lightmap's direct-sun share
// comes out and light() puts it back where the sun now is; sun_light is its brightness on a
// surface facing it, linear lightmap units, colour and time of day in it.
uniform float sun_unbaked = 0.0;
uniform vec3 sun_light = vec3(0.0);

// WeatherSystem (overcast-godot): wet ground and where rain reaches, lying snow, and the clouds'
// shadows on open ground — the same clouds the sky draws.
#include "res://addons/overcast/shaders/wet.gdshaderinc"
#include "res://addons/overcast/shaders/snow.gdshaderinc"
#include "res://addons/overcast/shaders/clouds.gdshaderinc"
#include "res://addons/overcast/shaders/color_space.gdshaderinc"

#define GOLDSRC_LIGHT

// The world shader has its own gs_to_linear, declared after this file.
vec3 hook_to_linear(vec3 c) {
	return mix(c / 12.92, pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

// share: the sky's share of the luxel in x, the sun's direct share in y.
vec3 goldsrc_lightmap(vec3 lm, vec2 share, vec3 world_pos) {
	vec3 sky = sky_light;
	// The clouds shade the sun: the baked one here, a real-time one in light().
	if (share.x > 0.0 && sun_unbaked <= 0.0) {
		sky *= cloud_sunlight(world_pos);
	}
	float direct = share.y * sun_unbaked;
	if (sky == vec3(1.0) && direct <= 0.0) {
		return lm;  // the sun as compiled
	}
	// Lightmaps hold pow(light, 0.55), so the share is scaled before that curve, not after.
	vec3 f = vec3(1.0 - share.x) + (share.x - direct) * sky;
	return lm * pow(max(f, vec3(0.0)), vec3(0.55));
}

// The real-time sun added to the lightmap where it would have been baked, under the same 0.55
// curve and clamp, so a sunlit wall comes out as it was compiled. Other lights shade as Godot's
// own Lambert.
void goldsrc_light(inout vec3 diffuse, vec3 light_dir, vec3 light_color, float attenuation,
		bool directional, vec3 normal, vec3 albedo, vec3 light, vec3 lit_srgb, vec3 world_pos,
		float overbright) {
	float ndl = max(dot(normal, light_dir), 0.0);
	if (!directional) {
		diffuse += light_color * attenuation * ndl / PI;
		return;
	}
	if (sun_unbaked <= 0.0 || ndl <= 0.0) {
		return;
	}
	vec3 sun = sun_light * ndl * attenuation * cloud_sunlight(world_pos);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 base_srgb = albedo;
#else
	vec3 base_srgb = overcast_to_srgb(albedo);
#endif
	vec3 rest = pow(max(light / overbright, vec3(0.0)), vec3(1.0 / 0.55));
	vec3 lit = overbright * pow(rest + sun, vec3(0.55));
	vec3 delta = min(base_srgb * lit, vec3(1.0)) - min(base_srgb * light, vec3(1.0));
	vec3 out_lit = min(lit_srgb + delta, vec3(1.0));
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 added = out_lit - lit_srgb;
#else
	vec3 added = hook_to_linear(out_lit) - hook_to_linear(lit_srgb);
#endif
	diffuse += added / max(albedo, vec3(1e-3));
}

void goldsrc_surface(inout vec3 lit_srgb, inout vec3 albedo, vec3 light, float sun_share,
		vec3 world_pos, vec3 world_normal, vec3 normal_view, vec3 view) {
	overcast_wet(lit_srgb, albedo, light, world_pos, world_normal, normal_view, view);
	overcast_snow(lit_srgb, albedo, light, sun_share, world_pos, world_normal, normal_view, view);
}
#endif

#ifdef GOLDSRC_HOOK_LIQUID
// NightMode. Liquid is fullbright, so it has no lightmap share to turn down: this dims it whole.
uniform vec3 sky_light = vec3(1.0);

vec3 goldsrc_liquid(vec3 albedo, int liquid_type) {
	if (liquid_type == 2 || sky_light == vec3(1.0)) {
		return albedo;  // lava keeps its glow
	}
	return albedo * pow(max(sky_light, vec3(0.0)), vec3(0.55));
}
#endif

#ifdef GOLDSRC_HOOK_SKY
// Lightning (Skybox.set_flash) on the stock cubemap sky, the same flash the procedural one takes.
#include "res://addons/overcast/shaders/flash.gdshaderinc"

vec3 goldsrc_sky(vec3 col, vec3 eye_dir) {
	return overcast_flash(col, eye_dir);
}
#endif
