// High-quality replacement for the sky-brush shader in goldsrc_bsp.cpp.
//
// It stands in for that shader rather than beside it: the render modes and the eye-direction
// reconstruction are copied verbatim, so a sky brush draws in the same pass, at the same depth,
// with the same sampler still bound. Only the right-hand side of ALBEDO changes — a 256x256
// cubemap fetch becomes a gradient, a sun, clouds and stars evaluated from the same direction.
//
// Everything is authored in whatever space the cubemap was: colours arrive as source_color and
// get exactly the treatment a source_color sampler would, so the RD renderers convert them and
// gl_compatibility does not, matching the world shaders' "multiply in gamma, convert once" rule.
// See goldsrc_bsp.cpp's lightstyle shaders for the twin of that argument.
//
// No cubemap sampling happens unless cubemap_blend is raised, but the sampler stays declared under
// its original name so Skybox can keep filling it and dial back to the shipped art per sky.
shader_type spatial;
render_mode unshaded, shadows_disabled, ambient_light_disabled, depth_draw_never;

uniform samplerCube sky_cubemap : source_color, hint_default_black;
// 0 = fully procedural, 1 = the shipped 256px art. The escape hatch for a sky the procedural
// model has no vocabulary for.
uniform float cubemap_blend : hint_range(0.0, 1.0) = 0.0;

uniform vec3 zenith_color : source_color = vec3(0.25, 0.42, 0.70);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.70, 0.82);
uniform vec3 ground_color : source_color = vec3(0.18, 0.17, 0.16);
// How fast zenith wins over horizon. Low = a broad hazy band, high = colour only at the top.
uniform float horizon_falloff : hint_range(0.2, 4.0) = 1.1;

// Direction TO the sun, world space. Skybox derives it from the map's own light_environment.
uniform vec3 sun_dir = vec3(0.0, 0.6, -0.8);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.82);
uniform float sun_size : hint_range(0.002, 0.5) = 0.035;   // angular radius, radians
uniform float sun_energy : hint_range(0.0, 8.0) = 2.2;
uniform float sun_glow_exp : hint_range(1.0, 512.0) = 48.0;
uniform float sun_glow_energy : hint_range(0.0, 3.0) = 0.5;

uniform float cloud_amount : hint_range(0.0, 1.0) = 0.45;
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow_color : source_color = vec3(0.42, 0.45, 0.52);
uniform float cloud_scale : hint_range(0.2, 12.0) = 2.2;
uniform float cloud_speed : hint_range(0.0, 0.2) = 0.008;
uniform float cloud_softness : hint_range(0.01, 0.6) = 0.22;

uniform float star_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 star_color : source_color = vec3(1.0, 1.0, 1.0);


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 5; i++) {
		sum += amp * vnoise(p);
		p *= 2.03;   // not 2.0: an exact doubling lines the octaves' lattices up into a grid
		amp *= 0.5;
	}
	return sum;
}


void fragment() {
	// Identical to the stock sky shader: VIEW points fragment->camera in view space, so negate
	// and rotate to get the world direction the player is looking along.
	vec3 eye_dir = normalize((INV_VIEW_MATRIX * vec4(-VIEW, 0.0)).xyz);
	vec3 sun = normalize(sun_dir);
	float up = eye_dir.y;

	// Gradient. Above and below the horizon are the same expression mirrored, so the seam at
	// y=0 is exactly horizon_color from both sides and never shows.
	vec3 above = mix(horizon_color, zenith_color, pow(clamp(up, 0.0, 1.0), horizon_falloff));
	vec3 below = mix(horizon_color, ground_color, pow(clamp(-up, 0.0, 1.0), horizon_falloff));
	vec3 col = mix(below, above, step(0.0, up));

	// Stars before clouds and sun, so both occlude them.
	if (star_amount > 0.0) {
		vec3 sp = eye_dir * 320.0;
		vec3 cell = floor(sp);
		float h = hash13(cell);
		// star_amount is a density, but the useful range is tiny — one cell in a few hundred.
		float lit = step(1.0 - star_amount * 0.035, h);
		float d = length(fract(sp) - 0.5);
		float twinkle = 0.65 + 0.35 * sin(TIME * 1.7 + h * 217.0);
		col += star_color * smoothstep(0.42, 0.0, d) * lit * twinkle;
	}

	// Clouds live on a plane overhead, projected along the view ray. The +0.12 keeps the
	// division finite at the horizon and is what stretches the cells into the distance there.
	if (cloud_amount > 0.0) {
		vec2 cp = eye_dir.xz / (max(up, 0.0) + 0.12);
		cp = cp * cloud_scale + TIME * cloud_speed * vec2(1.0, 0.35);
		float n = fbm(cp);
		// cloud_amount drives coverage, not opacity: at 0 the threshold sits above anything fbm
		// returns, so no cloud is drawn at all rather than a transparent one.
		float edge = mix(1.05, 0.28, cloud_amount);
		float cover = smoothstep(edge - cloud_softness, edge + cloud_softness, n);
		cover *= smoothstep(0.0, 0.10, up);   // fade into the horizon haze, never below it
		// Lit side toward the sun. Cheap stand-in for scattering through the cloud body, but it
		// is the cue that reads as depth, so it earns the fbm sample it costs.
		float toward = clamp(dot(eye_dir, sun) * 0.5 + 0.5, 0.0, 1.0);
		vec3 lit = mix(cloud_shadow_color, cloud_color, toward * toward);
		col = mix(col, lit, cover);
	}

	// Sun last: it burns through cloud, which is what selling a bright sky depends on.
	float sd = dot(eye_dir, sun);
	float disc = smoothstep(cos(sun_size * 2.5), cos(sun_size), sd);
	col += sun_color * disc * sun_energy;
	col += sun_color * pow(max(sd, 0.0), sun_glow_exp) * sun_glow_energy;

	if (cubemap_blend > 0.0) {
		vec3 art = texture(sky_cubemap, vec3(-eye_dir.x, eye_dir.y, eye_dir.z)).rgb;
		col = mix(col, art, cubemap_blend);
	}
	ALBEDO = col;
}
