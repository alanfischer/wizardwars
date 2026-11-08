shader_type spatial;
render_mode unshaded;
// Overcast's drifted snow (drift.gdshaderinc gives it its shape) lit as the models are, by the
// ambient cube grid baked from the lightmaps, so it meets the snow on the ground the lightmaps
// light. Overcast's own drift shader takes the scene's lights, which a GoldSrc map has none of.
#include "res://shaders/color_space.gdshaderinc"
#include "res://shaders/ambient_cube.gdshaderinc"
#include "res://addons/overcast/shaders/drift.gdshaderinc"

// See mdl_ambient_cube.gdshaderinc: the lit colour is worked out in gamma space either way.
uniform bool linear_output = false;

varying float thick;
varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	thick = overcast_drift(VERTEX, NORMAL, UV, CUSTOM0, UV2.x);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	if (thick < OVERCAST_DRIFT_THIN) {
		discard;
	}
	// Doubled as the world's lightmaps are (GoldSrcBSP.overbright), so it meets the ground's snow,
	// which takes the lightmap's light; the models take less on purpose.
	vec3 lit = min(overcast_snow_albedo(world_pos) * ambient_cube(world_pos, world_normal) * 2.0, vec3(1.0));
	ALBEDO = linear_output ? gs_to_linear(lit) : lit;
}
