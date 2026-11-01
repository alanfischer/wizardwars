// Heavy rain hides the distance, but only through air that rain is falling in: a fullscreen pass
// marches each pixel's view ray through the map's rain floor (GoldSrcBSP::bake_rain_floor) and
// hazes it by how many metres of that ray were under open sky. From inside, walls are clear and
// the field past the doorway is not; outside in a downpour the far end of the map is lost.
//
// Past the drops' box (WeatherSystem.DROP_BOX) the same pass draws the far rain: columns of falling
// streaks on a grid fixed in the world, found by stepping the view ray through its cells. Being in
// the world, they slide past as you move; each is drawn only in front of the scene and in air rain
// falls through, so walls hide it and roofs keep it out just as they do the drops.
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
// DecalSystem.depth_remap(): OpenGL's NDC z is -1..1, Vulkan/Metal's 0..1.
uniform vec2 depth_remap = vec2(1.0, 0.0);
#include "res://shaders/rain_floor.gdshaderinc"
uniform float rain_top;     // where rain falls from; none above it
uniform float density = 0.0;  // per metre of rain-filled air
// Rain comes through in curtains: the density swings by gust_amount either way over a noise that
// drifts with the weather (gust_offset, in noise cells, advanced by WeatherSystem).
uniform sampler3D gust_noise : repeat_enable, filter_linear;
uniform vec3 gust_offset = vec3(0.0);
uniform float gust_amount = 0.0;
uniform vec3 haze_color = vec3(0.4, 0.43, 0.48);
uniform vec3 streak_color = vec3(0.0);  // as the drops', lit
uniform float streak_opacity = 0.0;
uniform float presence = 1.0;  // the share of streak slots holding a drop
uniform float fall_speed = 9.0;
uniform float streak_length = 0.4;
uniform float streak_width = 0.006;
uniform float flash = 0.0;
// Colours are linear. The RD renderers encode on output; gl_compatibility writes ALBEDO as it is,
// so there it is encoded here (EntityRender.renderer_is_linear).
uniform bool linear_output = true;
#include "res://shaders/color_space.gdshaderinc"

const float GUST_CELL = 80.0;  // metres to the noise texture's width, as WeatherSystem.GUST_CELL
const int STEPS = 16;
const float MAX_DIST = 160.0;
// Far rain, by horizontal distance (m): fading in where the drop box fades out, and out again at
// FAR_END. One column of drops per CELL metres of grid, each a streak per SLOT streak lengths of
// height; MAX_CELLS covers the diagonal of FAR_NEAR..FAR_END.
const float FAR_NEAR = 12.0;
const float FAR_END = 50.0;
const float CELL = 0.9;
const int MAX_CELLS = 96;
const float SLOT = 5.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

bool raining_at(vec3 p) {
	vec2 uv = rain_floor_uv(p);
	return p.y < rain_top && rain_floor_covers(uv) && p.y > textureLod(rain_floor, uv, 0.0).r;
}

// pcg3d. The inputs are whole numbers in the thousands, which a float hash smears together.
vec3 hash3(float a, float b, float c) {
	uvec3 v = uvec3(ivec3(int(a), int(b), int(c))) * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return vec3(v) / 4294967295.0;
}

// The streak, if any, in the column of grid cell `cell` (whose drops sit at xz `column`) where a
// ray passes `miss` metres from it at height `y`. `footprint` is a pixel's width there (m); a
// streak thinner than that is spread over it, fainter.
float column_streak(vec2 cell, float y, float miss, float footprint) {
	float w = max(streak_width, footprint);
	if (miss >= w) {
		return 0.0;
	}
	vec3 hc = hash3(cell.x, cell.y, 1.0);
	float slot = streak_length * SLOT;
	float yy = y + fall_speed * mix(0.85, 1.15, hc.x) * TIME + hc.y * slot;
	float k = floor(yy / slot);
	if (hash3(cell.x, cell.y, k).x > presence) {
		return 0.0;
	}
	float along = fract(yy / slot) * SLOT;  // 0 at the head, 1 at the tail
	float profile = smoothstep(0.0, 0.25, along) * smoothstep(1.0, 0.6, along);
	return profile * (streak_width / w) * (1.0 - miss / w);
}

void fragment() {
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth * depth_remap.x + depth_remap.y, 1.0);
	vec3 view_pos = upos.xyz / upos.w;
	float dist = min(length(view_pos), MAX_DIST);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 dir = normalize((INV_VIEW_MATRIX * vec4(view_pos, 0.0)).xyz);
	float step_len = dist / float(STEPS);
	// Per-pixel offset into the steps, so a wall edge across a step boundary does not band.
	float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	float rainy = 0.0;
	for (int i = 0; i < STEPS; i++) {
		vec3 p = cam + dir * (float(i) + jitter) * step_len;
		if (raining_at(p)) {
			float gust = textureLod(gust_noise, p / GUST_CELL + gust_offset, 0.0).r;
			rainy += step_len * (1.0 + gust_amount * (gust * 2.0 - 1.0));
		}
	}
	float haze = 1.0 - exp(-density * rainy);

	float streak = 0.0;
	vec2 o = cam.xz;
	vec2 d = dir.xz;
	float flat_len = length(d);
	// A ray through no rain-filled air has no far rain on it either.
	if (streak_opacity > 0.0 && rainy > 0.0 && flat_len > 0.001) {
		float pixel = 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
		float t0 = FAR_NEAR / flat_len;
		float t1 = min(FAR_END / flat_len, dist);
		// Grid walk (Amanatides-Woo) over the cells the ray's ground track crosses from t0 to t1.
		vec2 q = (o + d * t0) / CELL;
		vec2 cell = floor(q);
		vec2 step_dir = sign(d);
		vec2 safe_d = vec2(abs(d.x) > 1e-6 ? d.x : 1e-6, abs(d.y) > 1e-6 ? d.y : 1e-6);
		vec2 t_delta = abs(CELL / safe_d);
		vec2 t_next = t0 + (cell + max(step_dir, vec2(0.0)) - q) * CELL / safe_d;
		float t = t0;
		float dd = dot(d, d);
		for (int i = 0; i < MAX_CELLS && t < t1; i++) {
			vec2 jitter = hash3(cell.x, cell.y, 0.0).xy;
			vec2 column = (cell + mix(vec2(0.15), vec2(0.85), jitter)) * CELL;
			float tc = clamp(dot(column - o, d) / dd, t0, t1);
			float miss = length(o + d * tc - column);
			float a = column_streak(cell, cam.y + dir.y * tc, miss, tc * pixel);
			if (a > 0.0 && raining_at(cam + dir * tc)) {
				float flat_dist = tc * flat_len;
				streak += a * exp(-density * tc)
					* smoothstep(FAR_NEAR, FAR_NEAR + 4.0, flat_dist) * smoothstep(FAR_END, FAR_END - 10.0, flat_dist);
			}
			if (t_next.x < t_next.y) {
				t = t_next.x;
				t_next.x += t_delta.x;
				cell.x += step_dir.x;
			} else {
				t = t_next.y;
				t_next.y += t_delta.y;
				cell.y += step_dir.y;
			}
		}
		streak = min(streak * streak_opacity * (1.0 + flash), 1.0);
	}
	// The streaks over the haze behind them.
	float alpha = streak + (1.0 - streak) * haze;
	vec3 color = (streak_color * streak + haze_color * (1.0 - streak) * haze) / max(alpha, 1e-4);
	ALBEDO = linear_output ? color : gs_to_srgb(color);
	ALPHA = alpha;
	// gl_compatibility also blends in gamma space, where a light haze covers a darker scene less
	// than the RD renderers' linear blend does. Matching it exactly needs the scene's colour; this
	// is exact over a mid-grey scene (^1/1.37) and over black (^1/1.92), and splits the difference.
	if (!linear_output) {
		ALPHA = pow(ALPHA, 1.0 / 1.6);
	}
}
