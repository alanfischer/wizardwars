shader_type spatial;
render_mode unshaded, depth_draw_never, shadows_disabled, cull_back;

// Detail pass for BSP world surfaces — GoldSrc's own gl_detailtextures trick, rebuilt as a
// next_pass so the loader's lightstyle material is never touched. Multiplied over the base at a
// much finer UV rate, it puts grain back into 128px wall textures that otherwise go to mush the
// moment you stand near them.
//
// The multiply is an alpha blend toward black, not blend_mul, because that mode is not the identity
// it looks like: the RD renderers halve its source colour (a pass writing 1.0 darkens a surface by
// half), and under gl_compatibility with glow on it wrecks the frame outright — a 153 surface came
// back 36. Mixing toward black by 1-k IS a multiply by k, and it behaves the same on every
// renderer. What it cannot do is multiply by more than 1: mixing toward white lifts a dark pixel by
// the same amount it lifts a bright one, which turns shadowed stone into white speckle. So the
// grain only darkens, and the wall's mean drops by half the strength — the price of the one
// blend mode that is not broken. A two-sided version has to live inside the lightstyle shader in
// goldsrc_bsp.cpp, where the multiply happens before anything is blended.
//
// The noise is generated rather than sampled: a detail tile would be one more asset to ship,
// import and keep in the pck for a pattern nobody is meant to consciously see. Fully procedural
// also means the per-class knobs below are just uniforms on one shared shader.

// Detail repeats per base-texture tile, and it has to be a big number. The count is in UV, so the
// pattern magnifies with the wall as you walk up to it — the one moment it is meant to help. At 14
// the grain was 23cm across and close range just showed bigger blur; at 120 it is under 3cm and
// reads as surface. The octave LOD below is what makes a frequency this high safe at range.
uniform float detail_scale = 120.0;
uniform float detail_strength = 0.35; // deepest the grain darkens, as a fraction: 0.35 = -35%
uniform float detail_aniso = 1.0;     // < 1 stretches the grain along V — wood, brushed surfaces
uniform float fade_start = 8.0;       // metres; full strength closer than this
uniform float fade_end = 35.0;        // metres; gone entirely beyond it
// The blend happens in whatever space the renderer composites in — sRGB under gl_compatibility,
// linear under the RD renderers — and a brightness ratio is not the same number in both. Set per
// load, like every other lightmap material (EntityRender.renderer_is_linear).
uniform bool linear_output = false;

// Ratio of gamma values -> ratio of linear ones. The exact exponent runs 1.8 to 2.3 across the
// sRGB curve; one number in the middle keeps the two renderers within a few percent of each other,
// which is all a grain needs.
const float GAMMA_RATIO_EXP = 2.1;

// Averaging three octaves pulls the result hard toward its own mean: the raw fbm below has a
// standard deviation of 0.13, not the 0.5 its 0..1 range suggests. Left uncorrected, a strength
// of 0.35 produced a four percent brightness swing — measurably there and completely invisible.
// This maps roughly the 99th percentile of the distribution onto full strength, so the uniform
// above means what it says and the clamp only catches genuine outliers.
const float DETAIL_GAIN = 3.4;

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

// One octave, faded out as its features approach the size of a pixel. A procedural pattern gets no
// mip chain, so without this the fine octaves alias into flat grey at middle distance and the wall
// quietly reverts to looking exactly as it did before — which is the other half of why none of
// this was visible. Renormalising by the surviving weight means detail goes coarse with distance
// rather than fading out, and the distance fade below is what actually ends it.
float octave(vec2 p, float w, inout float wsum) {
	float texels_per_pixel = max(fwidth(p.x), fwidth(p.y));
	float lod = 1.0 - smoothstep(0.4, 1.0, texels_per_pixel);
	wsum += w * lod;
	return vnoise(p) * w * lod;
}

float fbm(vec2 p) {
	float n = 0.0;
	float wsum = 0.0;
	n += octave(p, 0.5, wsum);
	n += octave(p * 2.03, 0.3, wsum);
	n += octave(p * 4.01, 0.2, wsum);
	return wsum > 0.001 ? n / wsum : 0.5;
}

void fragment() {
	vec2 duv = UV * detail_scale * vec2(1.0, detail_aniso);
	// Noise mapped onto a multiplier of 1-strength .. 1: the peaks leave the wall exactly as the
	// lightstyle pass drew it and the troughs are the grain.
	float g = clamp((fbm(duv) - 0.5) * DETAIL_GAIN, -1.0, 1.0) * 0.5 + 0.5;
	// Past a few metres a 128px tile's detail is below a pixel, and drawing it anyway is just
	// shimmer. Fade to exactly 1.0, the multiplier that changes nothing.
	float fade = 1.0 - smoothstep(fade_start, fade_end, length(VERTEX));
	float k = mix(1.0, mix(1.0 - detail_strength, 1.0, g), fade);

	// k is a ratio of gamma values, which is the space the strengths were tuned in.
	ALBEDO = vec3(0.0);
	ALPHA = 1.0 - (linear_output ? pow(k, GAMMA_RATIO_EXP) : k);
}
