// Dynamic weather's sky (overcast-godot's sky.gdshaderinc), drawn on the BSP sky brushes in place
// of the sky-brush shader in goldsrc_bsp.cpp.
//
// It stands in for that shader rather than beside it: the render modes and the eye-direction
// reconstruction are copied verbatim, so a sky brush draws in the same pass, at the same depth,
// with the same sampler still bound. Only the right-hand side of ALBEDO changes — a 256x256
// cubemap fetch becomes the procedural sky evaluated from the same direction.
//
// Its colours are measured off the cubemap (SkyPreset) and arrive as source_color, so the RD
// renderers convert them and gl_compatibility does not, matching the world shaders' "multiply in
// gamma, convert once" rule.
shader_type spatial;
render_mode unshaded, shadows_disabled, ambient_light_disabled, depth_draw_never;

uniform samplerCube sky_cubemap : source_color, hint_default_black;
// 0 = fully procedural, 1 = the shipped 256px art. The escape hatch for a sky the procedural
// model has no vocabulary for.
uniform float cubemap_blend : hint_range(0.0, 1.0) = 0.0;

#include "res://addons/overcast/shaders/sky.gdshaderinc"

void fragment() {
	// Identical to the stock sky shader: VIEW points fragment->camera in view space, so negate
	// and rotate to get the world direction the player is looking along.
	vec3 eye_dir = normalize((INV_VIEW_MATRIX * vec4(-VIEW, 0.0)).xyz);
	float storm_cover;
	float storm_body;
	vec3 col = overcast_sky(eye_dir, CAMERA_POSITION_WORLD, FRAGCOORD.xy, true, storm_cover, storm_body);
	if (cubemap_blend > 0.0) {
		vec3 art = texture(sky_cubemap, vec3(-eye_dir.x, eye_dir.y, eye_dir.z)).rgb;
		art = mix(art, vec3(dot(art, OVERCAST_LUMA)) * 0.5, storm);
		col = mix(col, art, cubemap_blend);
	}
	col = overcast_sky_flash(col, eye_dir, storm_cover, storm_body);
	ALBEDO = overcast_dither(col, FRAGCOORD.xy);
}
