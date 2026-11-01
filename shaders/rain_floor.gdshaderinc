#ifndef RAIN_FLOOR_GDSHADERINC
#define RAIN_FLOOR_GDSHADERINC
// The map's rain floor (MapConverter, GoldSrcBSP.bake_rain_floor): per column, the height rain
// stops at, in a texture whose max-X/min-Z corner sits at rain_floor_origin. Set by WeatherSystem.
uniform sampler2D rain_floor : filter_nearest;
uniform vec3 rain_floor_origin;
uniform vec2 rain_floor_size = vec2(1.0);

// Where world point p falls on the rain floor.
vec2 rain_floor_uv(vec3 p) {
	return vec2((rain_floor_origin.x - p.x) / rain_floor_size.x, (p.z - rain_floor_origin.z) / rain_floor_size.y);
}

// Off the map no rain falls.
bool rain_floor_covers(vec2 uv) {
	return uv.x >= 0.0 && uv.y >= 0.0 && uv.x < 1.0 && uv.y < 1.0;
}
#endif
