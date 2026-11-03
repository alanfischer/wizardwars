#ifndef CLOUDS_GDSHADERINC
#define CLOUDS_GDSHADERINC
// The procedural sky's cloud layer, in the world: a shell CLOUD_HEIGHT over the map. The sky
// (sky_procedural) traces the view ray to it and the ground (goldsrc_hook) traces toward the sun,
// so the cloud in front of the sun is the one whose shadow you are standing in.

// Tiling fbm (Skybox.cloud_noise); one tile spans CLOUD_TILE noise units.
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable, hint_default_black;
uniform float cloud_scale : hint_range(0.2, 12.0) = 2.2;   // noise units per CLOUD_HEIGHT
uniform float cloud_speed : hint_range(0.0, 0.2) = 0.008;  // noise units per second
uniform float cloud_softness : hint_range(0.01, 0.6) = 0.22;
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

// Noise coordinates of where the ray meets the shell, wind included.
vec2 cloud_coord(vec3 origin, vec3 dir, float dist) {
	return (origin.xz + dir.xz * dist) * (cloud_scale / CLOUD_HEIGHT) + cloud_wind();
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

// How much of the sky a cloud of density `n` covers, 0 to 1. `amount` drives coverage, not
// opacity: at 0 the threshold sits above anything the noise returns, so no cloud at all.
float cloud_coverage(float n, float amount) {
	float edge = mix(0.95, 0.22, amount);
	return smoothstep(edge - cloud_softness * 0.6, edge + cloud_softness * 1.2, n);
}

#ifdef CLOUD_SHADOWS
// For anything the sun lights (map, models): NightMode.set_clouds / LightGrid.set_clouds.
// cloud_shadow is how much of the sky's share a cloud takes away, 0 for none; cloud_cover is the
// sky's coverage, storm included.
uniform float cloud_shadow = 0.0;
uniform float cloud_cover = 0.0;
uniform vec3 cloud_sun_dir = vec3(0.0, 1.0, 0.0);

// The sky's share of the light multiplier at world point p: 1 in sun, less under cloud.
float cloud_sunlight(vec3 p) {
	if (cloud_shadow <= 0.0) {
		return 1.0;
	}
	vec3 sun = normalize(cloud_sun_dir);
	vec2 cp = cloud_coord(p, sun, cloud_distance(p, sun));
	return 1.0 - cloud_shadow * cloud_coverage(cloud_density(cp), cloud_cover);
}
#endif
#endif
