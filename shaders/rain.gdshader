// Raindrop streaks: a MultiMesh of quads with no transforms. Each instance hashes its own place in a
// box of rain around the camera that wraps as the camera moves, so the drops stay put in the world
// and every one of them is in view, at whatever height the camera is. A drop below the map's rain
// floor (a roof, the ground it would already have hit) is not drawn, which is what keeps rain out of
// the rooms under a roof. GoldSrc did the same per drop, tracing up for sky (WEATHER.CPP); the floor
// is that trace baked once per column at conversion (GoldSrcBSP::bake_rain_floor).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

// The drops as seen: their colour in the light on them (the sky's, darkened at night and lit by
// lightning), already in the renderer's output space. WeatherSystem works it out once a frame.
uniform vec3 color = vec3(0.75, 0.8, 0.9);
uniform float opacity = 0.4;
// Lightning lights the drops against a world it lights just as much; they stand out by thickening.
uniform float flash = 0.0;
uniform vec3 box = vec3(36.0, 24.0, 36.0);
uniform vec3 velocity = vec3(0.0, -9.0, 0.0);
uniform float streak_length = 0.4;
uniform float width = 0.006;
uniform bool has_floor = false;
#include "res://shaders/rain_floor.gdshaderinc"
// Drawn over the rain haze (rain_haze.gdshader), which would haze a drop by the distance to the wall
// behind it; this hazes it by its own.
uniform float haze_density = 0.0;

varying float fade;

vec4 hash4(uint n) {
	uvec4 v = uvec4(n) * uvec4(1597334677u, 3812015801u, 2798796415u, 1979697957u);
	v = (v.yzwx ^ (v >> 15u)) * uvec4(2246822519u, 3266489917u, 668265263u, 374761393u);
	v ^= v >> 13u;
	return vec4(v) / 4294967295.0;
}

void vertex() {
	vec4 h = hash4(uint(INSTANCE_ID) + 1u);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 vel = velocity * mix(0.85, 1.15, h.w);
	vec3 p = h.xyz * box + vel * TIME;
	p = cam + mod(p - cam + box * 0.5, box) - box * 0.5;

	vec3 rel = p - cam;
	float dist = length(rel);
	// Faded out toward the faces of the box, where drops wrap, and right at the lens.
	fade = smoothstep(box.x * 0.5, box.x * 0.3, length(rel.xz))
		* smoothstep(box.y * 0.5, box.y * 0.35, abs(rel.y))
		* smoothstep(0.2, 1.0, dist)
		* exp(-haze_density * dist);
	if (fade > 0.0 && has_floor) {
		vec2 uv = rain_floor_uv(p);
		if (!rain_floor_covers(uv) || p.y - streak_length * 0.5 < textureLod(rain_floor, uv, 0.0).r) {
			fade = 0.0;
		}
	}
	if (fade <= 0.0) {
		VERTEX = vec3(0.0);  // nothing to see: a zero-area quad, which draws no pixels at all
	} else {
		// A streak narrower than a pixel shimmers; widen it to one and thin its alpha to match.
		float pixel = dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
		float w = max(width, pixel);
		fade *= width / w;

		vec3 axis = normalize(vel);
		vec3 side = normalize(cross(axis, rel + vec3(1e-4)));
		vec3 world = p + side * VERTEX.x * w + axis * VERTEX.y * streak_length;
		VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	}
}

void fragment() {
	// Brightest toward the head, tapering off to the tail and soft across.
	float along = UV.y;
	float profile = smoothstep(0.0, 0.25, along) * smoothstep(1.0, 0.6, along);
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	ALBEDO = color;
	ALPHA = min(opacity * (1.0 + flash) * fade * profile * mix(0.5, 1.0, across), 1.0);
}
