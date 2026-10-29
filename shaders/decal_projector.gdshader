shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, cull_disabled;

/**
 * Decal Projector Shader
 * Projects a texture onto geometry inside the box volume using the depth buffer.
 * Works on all three renderers, unlike Godot's native Decal node.
 */

uniform sampler2D decal_tex : source_color, hint_default_transparent;
uniform sampler2D depth_tex : hint_depth_texture;
uniform vec4 modulate : source_color = vec4(1.0);
// Depth-buffer NDC z is 0..1 on Vulkan/Metal but -1..1 on OpenGL; the remap for the
// live backend comes from DecalSystem.depth_remap().
uniform vec2 depth_remap = vec2(1.0, 0.0);

varying mat4 inv_model_matrix;

void vertex() {
	inv_model_matrix = inverse(MODEL_MATRIX);
}

void fragment() {
	// Get depth at current pixel
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	
	// Convert to world position
	float ndc_z = depth * depth_remap.x + depth_remap.y;
	vec4 upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, ndc_z, 1.0);
	vec3 view_pos = upos.xyz / upos.w;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;
	
	// Convert to local space of the box
	vec3 local_pos = (inv_model_matrix * vec4(world_pos, 1.0)).xyz;
	
	// Check if world position is inside the unit box (-0.5 to 0.5)
	if (abs(local_pos.x) > 0.5 || abs(local_pos.y) > 0.5 || abs(local_pos.z) > 0.5) {
		discard;
	}
	
	// Project along Y axis (top-down in local space)
	// Map local XZ (-0.5..0.5) to UV (0.0..1.0)
	vec2 uv = vec2(local_pos.x + 0.5, local_pos.z + 0.5);
	
	vec4 color = texture(decal_tex, uv);
	color *= modulate;
	
	ALBEDO = color.rgb;
	ALPHA = color.a;
	
	// Edge fade to prevent harsh clipping at volume boundaries
	float fade_x = smoothstep(0.5, 0.45, abs(local_pos.x));
	float fade_y = smoothstep(0.5, 0.4, abs(local_pos.y));
	float fade_z = smoothstep(0.5, 0.45, abs(local_pos.z));
	ALPHA *= fade_x * fade_y * fade_z;
}
