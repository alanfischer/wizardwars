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
global uniform float cloud_volumetric; // 1 when the sky ray-marches its clouds (High quality)
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

// Metres from `origin` along unit `dir` to the shell `height` over the map, on the curve the
// cloud shell's planet gives it.
float cloud_distance_to(vec3 origin, vec3 dir, float height) {
	float r = CLOUD_EARTH * CLOUD_HEIGHT;
	float h = max(height - origin.y, 1.0);
	float b = r * dir.y;
	return -b + sqrt(b * b + 2.0 * r * h + h * h);
}

// Metres from `origin` along unit `dir` to the cloud shell.
float cloud_distance(vec3 origin, vec3 dir) {
	return cloud_distance_to(origin, dir, CLOUD_HEIGHT);
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

// The volumetric clouds' weather map: how much cloud stands over noise point cp, 0 to 1. Smooth
// and broad, as the 3D noise carves the clouds themselves out of it.
float cloud_weather(vec2 cp, float field) {
	float n = cloud_tex(cp * 0.45) + field;
	float edge = mix(0.75, 0.25, cloud_cover);
	return smoothstep(edge - 0.15, edge + 0.25, n);
}

// The fields term of cloud_density, for a ray that samples it once.
float cloud_field(vec2 cp) {
	return (cloud_tex(cp * CLOUD_FIELD_SCALE + vec2(2.1, 8.7) - cloud_wind() * 0.6) - 0.5)
		* CLOUD_FIELDS * cloud_fair();
}

// Volumetric clouds (High quality, Skybox.set_volumetric): a slab CLOUD_THICK deep over the
// shell, carved from 3D noise — perlin-worley in r, finer worley in g (Skybox.cloud_volume).
global uniform sampler3D cloud_volume : filter_linear, repeat_enable;
const float CLOUD_THICK = 60.0;
const float VOLUME_TILE = 360.0;   // metres one tile of cloud_volume spans
const float DETAIL_TILE = 70.0;
const int LIGHT_STEPS = 4;
const float EXTINCTION = 0.3;      // per metre at full density

// How far up the slab p is, 0 at its base and 1 at its top, on the curve cloud_distance_to puts
// the shells on: a planet centred `planet.xyz`, under the viewer, whose surface is at the
// viewer's height `planet.w`. Measured flat, a distant cloud would sink out of the slab.
float cloud_height_frac(vec3 p, vec4 planet) {
	return (length(p - planet.xyz) - CLOUD_EARTH * CLOUD_HEIGHT + planet.w - CLOUD_HEIGHT) / CLOUD_THICK;
}

// Cloud density at world point p, 0 to 1. `weather` is cloud_weather where p's column meets
// the shell; `detail` erodes the edges and is skipped for the light march.
float cloud_volume_density(vec3 p, vec4 planet, float weather, bool detail) {
	float hf = cloud_height_frac(p, planet);
	// Flat bases, domed tops that rise with the weather: big clouds tower, thin ones stay low.
	// A storm flattens them into one deck.
	float fair = cloud_fair();
	float top = mix(mix(0.3, 1.0, weather), 0.8, 1.0 - fair);
	float rise = clamp(hf / top, 0.0, 1.0);
	float cov = weather * smoothstep(0.0, 0.08, hf) * (1.0 - rise * rise * mix(1.0, 0.3, 1.0 - fair));
	if (cov <= 0.0) {
		return 0.0;
	}
	vec3 wind = vec3(cloud_wind().x, 0.0, cloud_wind().y) * (CLOUD_HEIGHT / cloud_scale);
	float s = texture(cloud_volume, (p + wind) / VOLUME_TILE).r;
	float d = clamp((s - (1.0 - cov)) / max(cov, 1e-3), 0.0, 1.0) * cov;
	if (detail && d > 0.0) {
		float e = texture(cloud_volume, (p + wind * 1.3) / DETAIL_TILE).g;
		// Wispy at the base, billowed higher up.
		e = mix(1.0 - e, e, clamp(hf * 4.0, 0.0, 1.0));
		d = clamp((d - e * 0.35) / (1.0 - e * 0.35), 0.0, 1.0);
	}
	return d;
}

// The multiplier on the sky's share of the light at world point p: 1 in sun, less under cloud.
float cloud_sunlight(vec3 p) {
	if (cloud_shadow <= 0.0) {
		return 1.0;
	}
	vec2 cp = cloud_layer(p, cloud_sun_dir, cloud_distance(p, cloud_sun_dir)) + cloud_wind();
	if (cloud_volumetric > 0.5) {
		// One sample a third of the way up the slab, through the sun's slant of it.
		vec3 q = p + cloud_sun_dir * cloud_distance_to(p, cloud_sun_dir, CLOUD_HEIGHT + CLOUD_THICK * 0.35);
		vec4 planet = vec4(p.x, p.y - CLOUD_EARTH * CLOUD_HEIGHT, p.z, p.y);
		float d = cloud_volume_density(q, planet, cloud_weather(cp, cloud_field(cp)), false);
		float depth = d * CLOUD_THICK * 0.5 / max(cloud_sun_dir.y, 0.2) * EXTINCTION;
		return 1.0 - cloud_shadow * (1.0 - exp(-depth));
	}
	return 1.0 - cloud_shadow * cloud_coverage(cloud_density(cp), cloud_cover);
}
#endif
