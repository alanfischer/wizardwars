// Everything both MDL model shaders share. mdl_ambient_cube.gdshader includes this as-is;
// mdl_ambient_cube_fade.gdshader defines MDL_FADE first and gets the alpha uniform with it.
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

void vertex() {
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 albedo = texture(albedo_texture, UV);
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
	EMISSION = linear_output ? gs_to_linear(lit_srgb) : lit_srgb;
	// Set ALBEDO for light() to use — real-time lights add on top of ambient cube
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
#ifdef MDL_FADE
	ALPHA = alpha;
#endif
}

void light() {
	// Receive contributions from OmniLight3D / SpotLight3D (crystal lights, etc.)
	//
	// Half-lambert, the falloff GoldSrc and Source both shaded models with: the wrap carries light
	// around past the terminator instead of cutting it dead there, which is what keeps a model
	// readable when one point light is all the room has. Squared so the lit side does not go milky.
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * ndl * ndl;
}
