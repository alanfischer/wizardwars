// Everything both MDL model shaders share. mdl_ambient_cube.gdshader includes this as-is;
// mdl_ambient_cube_fade.gdshader defines MDL_FADE first and gets the alpha uniform with it;
// holiday_decor.gdshader defines MDL_HOLIDAY and is coloured by its vertices instead.
//
// They stay two shaders rather than one because writing ALPHA at all — even a constant 1.0 —
// puts a spatial shader in the transparent pass and costs it the depth prepass. Every model in
// the game would pay for the handful that fade. The split is a rendering constraint; the code
// being in two places was not, which is what this file fixes.

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform float overbright = 2.0;
// GoldSrc composited texture x light on 8-bit gamma values. The RD renderers shade in
// linear space and encode on output, gl_compatibility shades in sRGB and does not, so the
// same expression lands in a different space on each. Multiply in gamma space either way
// and convert once at the end. See goldsrc_bsp.cpp's lightstyle shaders for the world twin.
uniform bool linear_output = false;

#include "res://shaders/color_space.gdshaderinc"


#ifdef MDL_HOLIDAY
// Gamma multipliers averaging 0.8 (tools/holiday_art.py), so DETAIL_GAIN keeps the vertex colour;
// no source_color, so both renderers read the gamma numbers as stored. The layer rides in UV2.x.
uniform sampler2DArray detail : filter_linear_mipmap, repeat_enable;
const float DETAIL_GAIN = 1.25;
// One bit per prop in this mesh (its index rides in UV2.y): set, the prop is gone (popped).
instance uniform int popped = 0;
#endif

#ifdef MDL_FADE
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
#endif

// The map's light, by position and facing (the ambient cube grid).
#include "res://shaders/ambient_cube.gdshaderinc"

// Rim light: how far in from the silhouette the lift reaches, and what fraction of the local
// ambient it is worth there. Deliberately restrained — this is separation from the background,
// not an outline.
const float RIM_POWER = 3.0;
const float RIM_STRENGTH = 0.5;

// GoldSrc drew kRenderFxGlowShell as a second copy of the model, scaled up and flat-shaded.
// A second skinned pass per glowing player is the wrong trade here — gl_compatibility charges
// by the surface — so the shell folds into this pass instead: the same silhouette weighting
// the rim light uses, in the caller's colour, over a floor that tints the faces too. Off
// entirely at strength 0, which is every model that never asks.
uniform vec3 glow_color = vec3(0.0);
uniform float glow_strength = 0.0;
const float GLOW_POWER = 2.0;   // lower than RIM_POWER: a shell is meant to be seen
const float GLOW_FLOOR = 0.35;  // what the faces get, against the silhouette's full strength

varying vec3 world_normal;
varying vec3 world_pos;
// For light(): the surface as lit before any real-time light, gamma.
varying vec3 lit_in;
varying vec3 base_in;

void vertex() {
#ifdef MDL_HOLIDAY
	if (((popped >> int(round(UV2.y))) & 1) != 0) {
		VERTEX = vec3(0.0);  // every triangle of the prop collapses to a point
	}
#endif
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
#ifdef MDL_HOLIDAY
	// Gamma, as a texel is after the sampler decodes it on the linear renderers.
	vec4 texel = texture(detail, vec3(UV, round(UV2.x)));
	// Alpha under 1 paints the layer's own colour on (a pattern); vertex alpha under 1 glows.
	vec3 tinted = mix(texel.rgb, min(COLOR.rgb * texel.rgb * DETAIL_GAIN, vec3(1.0)), texel.a);
	float self_lit = 1.0 - COLOR.a;
	vec4 albedo = vec4(linear_output ? gs_to_linear(tinted) : tinted, 1.0);
#else
	vec4 albedo = texture(albedo_texture, UV);
#endif
	ALBEDO = albedo.rgb * overbright;

	vec3 ambient = ambient_cube(world_pos, world_normal);
	// 1.5x compensates for GoldSrc half-intensity lightmaps without fully doubling.
	vec3 base_srgb = linear_output ? gs_to_srgb(albedo.rgb) : albedo.rgb;
	vec3 lit_srgb = base_srgb * ambient * 1.5;
	// The ambient cube shades by normal alone, so a model facing away from every bright cube face
	// is one flat tone and its silhouette dissolves into whatever stands behind it. Lifting the
	// grazing angles puts an edge back on it. Tinted by the light already on the surface rather
	// than by white, so a wizard in a dark corner gains no outline they have no light for.
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), RIM_POWER);
	lit_srgb = min(lit_srgb + ambient * rim * RIM_STRENGTH, vec3(1.0));
	if (glow_strength > 0.0) {
		float shell = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), GLOW_POWER);
		lit_srgb = min(lit_srgb + glow_color * glow_strength * mix(GLOW_FLOOR, 1.0, shell), vec3(1.0));
	}
#ifdef MDL_HOLIDAY
	lit_srgb = mix(lit_srgb, min(base_srgb * 1.3, vec3(1.0)), self_lit);
#endif
	EMISSION = linear_output ? gs_to_linear(lit_srgb) : lit_srgb;
	lit_in = lit_srgb;
	base_in = base_srgb;
	// Set ALBEDO for light() to use — real-time lights add on top of ambient cube
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
#ifdef MDL_FADE
	ALPHA = alpha;
#endif
}

void light() {
	if (LIGHT_IS_DIRECTIONAL && sun_unbaked > 0.0) {
		// MapSun's sun, added to the ambient cube where the grid baked it, in the same gamma terms.
		float ndl = max(dot(NORMAL, LIGHT), 0.0);
		vec3 sun = sun_model * ndl * ATTENUATION * cloud_sunlight(world_pos);
		vec3 lit = min(lit_in + base_in * sun * 1.5, vec3(1.0));
		vec3 added = linear_output ? gs_to_linear(lit) - gs_to_linear(lit_in) : lit - lit_in;
		DIFFUSE_LIGHT += added / max(ALBEDO, vec3(1e-3));
	} else {
		// OmniLight3D / SpotLight3D (crystal lights, etc.), and a portrait's own light.
		//
		// Half-lambert, the falloff GoldSrc and Source both shaded models with: the wrap carries
		// light around past the terminator instead of cutting it dead there, which is what keeps a
		// model readable when one point light is all the room has. Squared so the lit side does not
		// go milky.
		float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * ndl * ndl;
	}
}
