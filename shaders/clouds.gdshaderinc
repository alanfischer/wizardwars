#ifndef CLOUDS_GDSHADERINC
#define CLOUDS_GDSHADERINC
// The procedural sky's cloud layer, in the world: a shell CLOUD_HEIGHT over the map. The sky
// (sky_procedural) traces the view ray to it and the map and models (goldsrc_hook,
// mdl_ambient_cube) trace toward the sun, so the cloud in front of the sun is the one whose
// shadow you are standing in. Global uniforms (project.godot), set by Skybox: one sky at a time.

// Tiling noise (Skybox.cloud_noise): perlin fbm in r, worley fbm in g (distance: 0 at a cell's
// centre). One tile spans CLOUD_TILE noise units.
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
const float CLOUD_BILLOW = 0.5;
// Clouds gather into fields with clear sky between: a slow, broad swing in density that drifts
// against the wind, so clouds grow and thin out rather than only sliding past. Fades out as a
// storm closes the sky over.
const float CLOUD_FIELDS = 0.32;
const float CLOUD_FIELD_SCALE = 0.13;

float cloud_tex(vec2 p) {
	return texture(cloud_noise, p / CLOUD_TILE).r;
}

// 1 for fair-weather cumulus, 0 once a storm has closed the sky into one flat deck.
float cloud_fair() {
	return 1.0 - smoothstep(0.7, 0.95, cloud_cover);
}

// Perlin swelling into round billows: worley cells push the outline out into lobes, so a cloud's
// edge is cauliflower rather than smoke.
float cloud_shape(vec2 p) {
	vec2 t = texture(cloud_noise, p / CLOUD_TILE).rg;
	return t.r + (0.5 - t.g) * CLOUD_BILLOW * mix(0.3, 1.0, cloud_fair());
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
	cp += warp * 0.35;
	float field = cloud_tex(cp * CLOUD_FIELD_SCALE + vec2(2.1, 8.7) - wind * 0.6) - 0.5;
	float fair = cloud_fair();
	return cloud_shape(cp) + (0.5 - texture(cloud_noise, (cp * 3.1 + vec2(7.3, 2.9)) / CLOUD_TILE).g)
		* mix(0.08, 0.2, fair) + field * CLOUD_FIELDS * fair;
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
