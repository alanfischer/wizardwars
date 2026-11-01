#ifndef COLOR_SPACE_GDSHADERINC
#define COLOR_SPACE_GDSHADERINC
// The sRGB curve both ways. The RD renderers shade in linear and encode on output; gl_compatibility
// does neither, so a shader that has to land in one space on both converts with these.

vec3 gs_to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

vec3 gs_to_linear(vec3 c) {
	return mix(c / 12.92, pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}
#endif
