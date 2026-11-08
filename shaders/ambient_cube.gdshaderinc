#ifndef AMBIENT_CUBE_GDSHADERINC
#define AMBIENT_CUBE_GDSHADERINC
// The map's light for something it was never baked onto (a model, a drift of snow): the ambient
// cube grid LightGrid bakes from the lightmaps, sampled by world position and blended by facing.
// LightGrid binds the textures (apply_textures_to_node, bind).

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

// The sky's share of each grid cell's light, and a linear multiplier on that share: night, and
// a lightstyle on the map's light_environment (ww_chasm's dusk). See NightMode; the world's
// lightmap shader does the same with lm_sun.
uniform sampler3D acube_sun : filter_linear, hint_default_black;
uniform vec3 sky_light = vec3(1.0);
// Shadows of the procedural sky's clouds, the same ones the map takes.
#include "res://addons/overcast/shaders/clouds.gdshaderinc"

// The light at world_pos on a surface facing world_normal, in the lightmaps' gamma space.
vec3 ambient_cube(vec3 world_pos, vec3 world_normal) {
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
	float sun_share = texture(acube_sun, uvw).r;
	vec3 sky = sun_share > 0.0 ? sky_light * cloud_sunlight(world_pos) : sky_light;
	ambient *= pow(max(mix(vec3(1.0), sky, sun_share), vec3(0.0)), vec3(0.55));
	return max(ambient, vec3(0.05));
}
#endif
