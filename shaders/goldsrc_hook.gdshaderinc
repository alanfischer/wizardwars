// Wizard Wars' half of the map's shaders. goldsrc-godot builds plain GoldSrc ones and includes this
// (GoldSrcBSP.shader_hook, set by MapConverter) with GOLDSRC_HOOK_WORLD, _LIQUID or _SKY defined;
// the calls and their arguments are listed at with_shader_hook in goldsrc_bsp.cpp. Night, lightning
// and rain are ours, so they live here. Resolved when a shader compiles, at load: a change here
// needs no map reconvert, but a change to a signature has to match the extension's calls.

#ifdef GOLDSRC_HOOK_WORLD
// NightMode: a linear-light multiplier on the sky's share of each luxel — night, a fade on a sun
// that shares style 0 with the lights, and lightning on top.
uniform vec3 sky_light = vec3(1.0);

// WeatherSystem (overcast-godot): wet ground and where rain reaches, lying snow, and the clouds'
// shadows on open ground — the same clouds the sky draws.
#include "res://addons/overcast/shaders/wet.gdshaderinc"
#include "res://addons/overcast/shaders/snow.gdshaderinc"
#include "res://addons/overcast/shaders/clouds.gdshaderinc"

vec3 goldsrc_lightmap(vec3 lm, float sun_share, vec3 world_pos) {
	vec3 sky = sky_light;
	if (sun_share > 0.0) {
		sky *= cloud_sunlight(world_pos);
	}
	if (sky == vec3(1.0)) {
		return lm;  // the sun as compiled
	}
	// Lightmaps hold pow(light, 0.55), so the share is scaled before that curve, not after.
	return lm * pow(max(mix(vec3(1.0), sky, sun_share), vec3(0.0)), vec3(0.55));
}

void goldsrc_surface(inout vec3 lit_srgb, inout vec3 albedo, vec3 light, vec3 world_pos,
		vec3 world_normal, vec3 normal_view, vec3 view) {
	overcast_wet(lit_srgb, albedo, light, world_pos, world_normal, normal_view, view);
	overcast_snow(lit_srgb, albedo, light, world_pos, world_normal, normal_view, view);
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
