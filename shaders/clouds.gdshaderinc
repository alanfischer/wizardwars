#ifndef CLOUDS_GDSHADERINC
#define CLOUDS_GDSHADERINC
// The procedural sky's cloud layer, in the world: a shell CLOUD_HEIGHT over the map. The sky
// (sky_procedural) traces the view ray to it and the map and models (goldsrc_hook,
// mdl_ambient_cube) trace toward the sun, so the cloud in front of the sun is the one whose
// shadow you are standing in. Global uniforms (project.godot), set by Skybox: one sky at a time.

// Tiling fbm (Skybox.cloud_noise); one tile spans CLOUD_TILE noise units.
global uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
global uniform float cloud_scale;     // noise units per CLOUD_HEIGHT
global uniform float cloud_speed;     // noise units per second
global uniform float cloud_softness;
global uniform float cloud_cover;     // how much of the sky is cloud, storm included
global uniform float cloud_shadow;    // how much of the sky's share a cloud takes off; 0 for none
global uniform vec3 cloud_sun_dir;    // unit, toward the sun
const float CLOUD_TILE = 12.0;
const float CLOUD_HEIGHT = 100.0;  // metres over the map's origin
// The shell curves like a planet this many times its height across, so it meets the horizon at a
// finite distance instead of smearing out to infinity like a flat plane.
const float CLOUD_EARTH = 12.0;

float cloud_tex(vec2 p) {
	return texture(cloud_noise, p / CLOUD_TILE).r;
}

// Metres from `origin` along unit `dir` to the cloud shell.
float cloud_distance(vec3 origin, vec3 dir) {
	float r = CLOUD_EARTH * CLOUD_HEIGHT;
	float h = max(CLOUD_HEIGHT - origin.y, 1.0);
	float b = r * dir.y;
	return -b + sqrt(b * b + 2.0 * r * h + h * h);
}

// cloud_distance looking at the horizon.
float cloud_horizon(vec3 origin) {
	return cloud_distance(origin, vec3(1.0, 0.0, 0.0));
}

vec2 cloud_wind() {
	return TIME * cloud_speed * vec2(1.0, 0.35);
}

// Noise coordinates of where the ray meets the shell, before the wind moves the pattern.
vec2 cloud_layer(vec3 origin, vec3 dir, float dist) {
	return (origin.xz + dir.xz * dist) * (cloud_scale / CLOUD_HEIGHT);
}

// Cloud density at `cp`, which comes back moved to where the shape was sampled (billows are the
// pattern pushed around by a coarser copy of itself; fine detail eats into the edges).
float cloud_density(inout vec2 cp) {
	vec2 wind = cloud_wind();
	vec2 warp = vec2(cloud_tex(cp * 0.5 + vec2(0.31, 0.17) - wind * 0.4),
		cloud_tex(cp * 0.5 + vec2(5.71, 2.53) + wind * 0.3)) - 0.5;
	cp += warp * 0.6;
	return cloud_tex(cp) + (cloud_tex(cp * 3.1 + vec2(7.3, 2.9)) - 0.5) * 0.18;
}

// The density a cloud starts at. `amount` drives coverage, not opacity: at 0 the threshold sits
// above anything the noise returns, so no cloud at all.
float cloud_edge(float amount) {
	return mix(0.95, 0.22, amount);
}

// How much of the sky a cloud of density `n` covers, 0 to 1.
float cloud_coverage(float n, float amount) {
	float edge = cloud_edge(amount);
	return smoothstep(edge - cloud_softness * 0.6, edge + cloud_softness * 1.2, n);
}

// The multiplier on the sky's share of the light at world point p: 1 in sun, less under cloud.
float cloud_sunlight(vec3 p) {
	if (cloud_shadow <= 0.0) {
		return 1.0;
	}
	vec2 cp = cloud_layer(p, cloud_sun_dir, cloud_distance(p, cloud_sun_dir)) + cloud_wind();
	return 1.0 - cloud_shadow * cloud_coverage(cloud_density(cp), cloud_cover);
}
#endif
