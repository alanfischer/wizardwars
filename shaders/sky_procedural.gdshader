// Dynamic weather's sky (overcast-godot's sky.gdshaderinc), drawn on the BSP sky brushes in place
// of the sky-brush shader in goldsrc_bsp.cpp.
//
// It stands in for that shader rather than beside it: the render modes and the eye-direction
// reconstruction are copied verbatim, so a sky brush draws in the same pass and at the same
// depth. Only the right-hand side of ALBEDO changes — a 256x256 cubemap fetch becomes the
// procedural sky evaluated from the same direction.
//
// Its colours are measured off the cubemap (SkyPreset) and arrive as source_color, so the RD
// renderers convert them and gl_compatibility does not, matching the world shaders' "multiply in
// gamma, convert once" rule.
shader_type spatial;
render_mode unshaded, shadows_disabled, ambient_light_disabled, depth_draw_never;

#include "res://addons/overcast/shaders/sky.gdshaderinc"

void fragment() {
	// Identical to the stock sky shader: VIEW points fragment->camera in view space, so negate
	// and rotate to get the world direction the player is looking along.
	vec3 eye_dir = normalize((INV_VIEW_MATRIX * vec4(-VIEW, 0.0)).xyz);
	float storm_cover;
	float storm_body;
	vec3 col = overcast_sky(eye_dir, CAMERA_POSITION_WORLD, FRAGCOORD.xy, true, storm_cover, storm_body);
	col = overcast_sky_flash(col, eye_dir, storm_cover, storm_body);
	ALBEDO = overcast_dither(col, FRAGCOORD.xy);
}
