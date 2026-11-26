shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, shadows_disabled;
// A soft dark disc on the floor under each holiday prop, gone with it when it pops: the same
// per-instance bit as holiday_decor.gdshader, the prop's index in UV2.y.

instance uniform int popped = 0;
const float DARKNESS = 0.5;

void vertex() {
	if (((popped >> int(round(UV2.y))) & 1) != 0) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	float d = length(UV * 2.0 - 1.0);
	ALBEDO = vec3(0.0);
	ALPHA = (1.0 - smoothstep(0.35, 1.0, d)) * DARKNESS;
}
