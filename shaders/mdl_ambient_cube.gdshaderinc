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

vec3 gs_to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

vec3 gs_to_linear(vec3 c) {
	return mix(c / 12.92, pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}


#ifdef MDL_FADE
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
#endif

// Ambient cube: 6 volumetric textures sampled by world position
uniform sampler3D acube_pos_x : filter_linear;
uniform sampler3D acube_neg_x : filter_linear;
uniform sampler3D acube_pos_y : filter_linear;
uniform sampler3D acube_neg_y : filter_linear;
uniform sampler3D acube_pos_z : filter_linear;
uniform sampler3D acube_neg_z : filter_linear;

// Grid transform: world_pos -> UVW
uniform vec3 grid_origin;  // world-space origin (max X corner due to GS flip)
uniform vec3 grid_size = vec3(1.0);  // world-space extent (cell_size * dims), default avoids div-by-zero

// Rim light: how far in from the silhouette the lift reaches, and what fraction of the local
// ambient it is worth there. Deliberately restrained — this is separation from the background,
// not an outline.
const float RIM_POWER = 3.0;
const float RIM_STRENGTH = 0.5;

// Global brightness multiplier for lightstyle animation (e.g. ww_chasm)
uniform float lightstyle_brightness = 1.0;

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

	// Compute UVW from world position.
	// 3D texture axes: u=GS_X, v=GS_Y, w=GS_Z
	// Godot→GS mapping: GS_X=flipped Godot X, GS_Y=Godot Z, GS_Z=Godot Y
	vec3 uvw = vec3(
		(grid_origin.x - world_pos.x) / grid_size.x,  // u: GS X (flipped Godot X)
		(world_pos.z - grid_origin.z) / grid_size.z,   // v: GS Y (Godot Z)
		(world_pos.y - grid_origin.y) / grid_size.y    // w: GS Z (Godot Y)
	);

	// Blend 6 directional ambient colors by world-space normal.
	// Valve ambient-cube weighting: squared normal components sum to exactly 1
	// (nx^2+ny^2+nz^2 == 1 for a unit normal), so the blend is a true weighted
	// average bounded by the cube faces. Linear |n| weights sum to the L1 norm
	// (1.0 to 1.73) and over-brighten diagonal-facing surfaces by up to 73%.
	vec3 wn = normalize(world_normal);
	vec3 wn2 = wn * wn;
	vec3 ambient = wn2.x * (wn.x >= 0.0 ? texture(acube_pos_x, uvw).rgb : texture(acube_neg_x, uvw).rgb)
	             + wn2.y * (wn.y >= 0.0 ? texture(acube_pos_y, uvw).rgb : texture(acube_neg_y, uvw).rgb)
	             + wn2.z * (wn.z >= 0.0 ? texture(acube_pos_z, uvw).rgb : texture(acube_neg_z, uvw).rgb);
	ambient = max(ambient * lightstyle_brightness, vec3(0.05));
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
