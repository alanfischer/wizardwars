extends "res://src/tests/test_base.gd"
## `rain` takes values past 1, where it only draws more drops; `time` is hours round the clock.
## (Overcast tests the weather itself.)
##
## Scene-run only (needs the ServerVars autoload): res://src/tests/run_tests.tscn.

const Movement = preload("res://addons/pmove/movement.gd")


## A floor 4 m by 2 m from (-2, -1): the west half roofed at 3 m, the east half open to 0.
func _roofed_weather() -> WeatherSystem:
	var img := Image.create_empty(4, 2, false, Image.FORMAT_RF)
	for y in 2:
		for x in 4:
			img.set_pixel(x, y, Color(3.0 if x < 2 else 0.0, 0, 0))
	var weather := WeatherSystem.new()
	weather.rain_floor = OvercastRainFloor.create(img, Vector3(-2, 0, -1), Vector2(4, 2), 10.0)
	return weather


func test_the_rain_var_reaches_overcast_unchanged() -> void:
	var weather := WeatherSystem.new()
	for rain in ["0.3", "1", "6"]:
		ServerVars.set_from_string("rain", rain)
		assert_almost_eq(weather.rain_amount(), float(rain), 1e-6, "rain %s" % rain)
	ServerVars.set_from_string("rain", "0")
	assert_eq(weather.rain_amount(), 0.0, "dry with no var and no map weather")
	weather._current_type = 1
	weather._current_intensity = 9
	assert_almost_eq(weather.rain_amount(), 1.0, 1e-6, "the map's heaviest rain is a downpour")
	weather._current_intensity = 1
	assert_gt(weather.rain_amount(), 0.0, "and its lightest still rains")
	weather.free()


func test_dynamic_weather_leaves_the_maps_weather_unused() -> void:
	var weather := WeatherSystem.new()
	weather._current_type = 1
	weather._current_intensity = 9
	ServerVars.set_from_string("dynamic_weather", "on")
	ServerVars.set_from_string("rain", "0")
	assert_eq(weather.rain_amount(), 0.0, "a dry spell is dry whatever the map asked for")
	ServerVars.set_from_string("rain", "0.2")
	assert_almost_eq(weather.rain_amount(), 0.2, 1e-6, "and a shower is the cycle's")
	ServerVars.set_from_string("dynamic_weather", "off")
	ServerVars.set_from_string("rain", "0")
	assert_almost_eq(weather.rain_amount(), 1.0, 1e-6, "off again, the map's weather is back")
	weather.free()


func test_the_wind_vars_blow_overcast_wind() -> void:
	var weather := WeatherSystem.new()
	ServerVars.set_from_string("wind", "4")
	ServerVars.set_from_string("wind_dir", "90")
	weather._apply_wind()
	assert_vec3_almost_eq(weather.wind, Vector3(4.0, 0.0, 0.0), 1e-5, "4 m/s toward +X")
	ServerVars.set_from_string("wind", "0")
	ServerVars.set_from_string("wind_dir", "0")
	weather._apply_wind()
	assert_eq(weather.wind, Vector3.ZERO, "calm")
	weather.free()


func test_every_hour_lights_the_rain_with_a_number() -> void:
	for t in ["0", "6", "12", "18", "18:30", "23.75"]:
		ServerVars.set_from_string("time", NightMode.parse(t))
		var n := NightMode.night_light()
		assert_true(n.x >= 0.0 and n.y >= 0.0 and n.z >= 0.0, "%s never goes below black" % t)
		var sky := WeatherSystem.sky_light_now()
		assert_false(is_nan(sky.r) or is_nan(sky.g) or is_nan(sky.b), "%s lights the rain with a number" % t)
	ServerVars.set_from_string("time", "12")


func test_time_reads_as_hours_names_and_clock_times() -> void:
	assert_eq(NightMode.parse("18:30"), "18.5", "h:mm")
	assert_eq(NightMode.parse("dusk"), "18.0", "a name")
	assert_eq(NightMode.parse("6"), "6.0", "plain hours")
	assert_eq(NightMode.parse("25"), "", "past the clock")
	assert_eq(NightMode.parse("12:75"), "", "not a minute")
	assert_eq(NightMode.format(18.5), "18:30", "and back")
	ServerVars.set_from_string("time", "12")
	assert_eq(NightMode.night_light(), Vector3.ONE, "noon is the map as lit")
	ServerVars.set_from_string("time", "0")
	assert_almost_eq(NightMode.amount(), 1.0, 1e-6, "midnight is full night")
	ServerVars.set_from_string("time", "12")


## The extension bakes its rain floor from the max-X corner and Overcast reads from the min-X one:
## the conversion must land every column where the extension put it.
func test_the_maps_rain_floor_lands_where_the_extension_baked_it() -> void:
	var img := Image.create_empty(5, 3, false, Image.FORMAT_RF)
	for y in 3:
		for x in 5:
			img.set_pixel(x, y, Color(x * 10 + y, 0, 0))
	var origin := Vector3(4.0, 0.0, -1.0)
	var size := Vector2(5.0, 3.0)
	var map_root := Node3D.new()
	map_root.set_meta("rain_floor", {"image": img, "origin": origin, "size": size, "top": 9.0})
	var under := Image.create_empty(5, 3, false, Image.FORMAT_RGF)
	for y in 3:
		for x in 5:
			under.set_pixel(x, y, Color(x * 10 + y - 1, x * 10 + y - 3, 0))
	map_root.get_meta("rain_floor")["under"] = under
	var weather := WeatherSystem.new()
	weather._take_rain_floor(map_root)
	for q in [Vector3(3.5, 0, -0.5), Vector3(-0.5, 0, 1.5), Vector3(1.2, 0, 0.7)]:
		# goldsrc-godot's own lookup (rain_floor.gdshaderinc before Overcast).
		var u: float = (origin.x - q.x) / size.x
		var v: float = (q.z - origin.z) / size.y
		var want := img.get_pixel(int(u * 5), int(v * 3)).r
		assert_eq(weather.floor_at(q), want, "column at %s" % q)
		# The air under cover is flipped with it: Overcast reads it by the same column.
		var f: OvercastRainFloor = weather.rain_floor
		var cell := Vector2i(int((q.x - f.origin.x) / f.size.x * 5), int((q.z - f.origin.z) / f.size.y * 3))
		assert_eq(f.under.get_pixel(cell.x, cell.y).r, want - 1.0, "air under the column at %s" % q)
	weather.free()
	map_root.free()


## Rain wets the map only where it has a rain floor, and each surface pools as its texture would.
func test_the_maps_surfaces_pool_by_their_material() -> void:
	var wet := Shader.new()
	wet.code = 'shader_type spatial;\n#include "res://addons/overcast/shaders/wet.gdshaderinc"\nvoid fragment() {}'
	var map_root := Node3D.new()
	var mats := {}
	for tex in ["out_wd", "grass1"]:
		var mi := MeshInstance3D.new()
		mi.name = tex
		mi.mesh = BoxMesh.new()
		var mat := ShaderMaterial.new()
		mat.shader = wet
		mi.mesh.surface_set_material(0, mat)
		map_root.add_child(mi)
		mats[tex] = mat
	var weather := WeatherSystem.new()
	weather.wet_ground = false
	weather._take_rain_floor(map_root)
	assert_false(weather.wet_ground, "a map with no rain floor stays dry")
	var img := Image.create_empty(2, 2, false, Image.FORMAT_RF)
	map_root.set_meta("rain_floor", {"image": img, "origin": Vector3(2, 0, 0), "size": Vector2(2, 2), "top": 9.0})
	weather._take_rain_floor(map_root)
	assert_true(weather.wet_ground, "one with a floor gets wet")
	assert_eq(mats["out_wd"].get_shader_parameter("puddle_scale"), 0.0, "wood drains")
	assert_eq(mats["grass1"].get_shader_parameter("puddle_scale"),
		WeatherSystem.PUDDLE_BY_CLASS.get(WorldMaterials.classify("grass1"), WeatherSystem.PUDDLE_DEFAULT),
		"and the rest pool as their class does")
	weather.free()
	map_root.free()


func test_the_server_sends_the_grounds_wetness_in_steps() -> void:
	var weather := _roofed_weather()
	weather.wetness = 0.51
	weather._share_wetness()
	assert_eq(weather.ground_wetness, 0.5, "to the nearest step")
	assert_eq(weather.wet_at(Vector3(1, 0, 0)), 0.5, "out in the rain the ground is that wet")
	assert_eq(weather.wet_at(Vector3(-1, 0, 0)), 0.0, "under the roof it is dry")
	weather.free()


func test_a_client_takes_the_servers_wetness_only_when_far_from_it() -> void:
	var weather := _roofed_weather()
	weather.wetness = 0.2
	weather.set_ground_wetness(0.5)
	assert_eq(weather.wetness, 0.5, "a client that joined into rain is set to the server's ground")
	weather.wetness = 0.49
	weather.set_ground_wetness(0.5)
	assert_eq(weather.wetness, 0.49, "one close to it soaks on smoothly")
	assert_eq(weather.wet_at(Vector3(1, 0, 0)), 0.5, "while footing goes by the server's")
	weather.free()


func test_soaked_ground_is_slick_and_stacks_with_frost() -> void:
	var weather := _roofed_weather()
	weather.set_ground_wetness(1.0)
	var was: WeatherSystem = Game.weather_system
	Game.weather_system = weather
	var body := Node3D.new()
	var ctx := PlayerMovementContext.new(body, null, null)
	var state := Movement.MovementState.new()
	var slick := float(ServerVars.get_value("wet_friction", 1.0))
	assert_lt(slick, 1.0, "soaked ground is slicker than dry")
	assert_gt(slick, 0.5, "but only a little")
	state.position = Vector3(1, 0, 0)
	var mods := Movement.MovementModifiers.new()
	mods.friction_scale = 0.15
	ctx._slick_when_wet(mods, state)
	assert_almost_eq(mods.friction_scale, 0.15 * slick, 1e-6, "out in the rain, on top of frost")
	state.position = Vector3(-1, 0, 0)
	mods = Movement.MovementModifiers.new()
	ctx._slick_when_wet(mods, state)
	assert_eq(mods.friction_scale, 1.0, "under the roof the footing is dry")
	Game.weather_system = was
	body.free()
	weather.free()


func test_the_snow_var_is_the_share_of_the_fall_that_is_snow() -> void:
	var weather := WeatherSystem.new()
	ServerVars.set_from_string("rain", "0.6")
	ServerVars.set_from_string("snow", "1")
	weather._apply_rain()
	assert_almost_eq(weather.rain, 0.6, 1e-6, "how much falls is still the rain var")
	assert_almost_eq(weather.snowfall(), 0.6, 1e-6, "and all of it is snow")
	assert_eq(weather.rainfall(), 0.0, "none of it rain")
	ServerVars.set_from_string("snow", "0")
	ServerVars.set_from_string("rain", "0")
	weather.free()


## The commands reply to their sender, which asks the peer who it is: offline here, as a lone host.
func _offline_host() -> MultiplayerPeer:
	var was := CommandSystem.multiplayer.multiplayer_peer
	CommandSystem.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	return was


func test_snow_with_nothing_falling_starts_a_fall() -> void:
	var was := _offline_host()
	var me: int = CommandSystem.multiplayer.get_unique_id()
	ServerVars.set_from_string("rain", "0")
	CommandSystem._cmd_snow(me, "1")
	assert_eq(float(ServerVars.get_value("snow")), 1.0, "all of it snow")
	assert_eq(float(ServerVars.get_value("rain")), CommandSystem.SNOW_START, "and some of it falls")
	CommandSystem._cmd_snow(me, "0.5 0.2")
	assert_eq(float(ServerVars.get_value("snow")), 0.5, "sleet")
	assert_almost_eq(float(ServerVars.get_value("rain")), 0.2, 1e-6, "as much as was asked for")
	CommandSystem._cmd_snow(me, "1")
	assert_almost_eq(float(ServerVars.get_value("rain")), 0.2, 1e-6, "what is falling keeps falling")
	CommandSystem._cmd_snow(me, "2")
	assert_eq(float(ServerVars.get_value("snow")), 1.0, "a share past 1 is refused")
	ServerVars.set_from_string("snow", "0")
	ServerVars.set_from_string("rain", "0")
	CommandSystem.multiplayer.multiplayer_peer = was


func test_snow_leaves_dynamic_weather_running() -> void:
	ServerVars.set_from_string("rain", "0")
	ServerVars.set_from_string("dynamic_weather", "on")
	var was := _offline_host()
	CommandSystem._cmd_snow(CommandSystem.multiplayer.get_unique_id(), "1")
	CommandSystem.multiplayer.multiplayer_peer = was
	assert_eq(float(ServerVars.get_value("rain")), 0.0, "a dry spell is left to the showers")
	assert_eq(bool(ServerVars.get_value("dynamic_weather")), true, "which then come as snow")
	ServerVars.set_from_string("dynamic_weather", "off")
	ServerVars.set_from_string("snow", "0")


## The map's world shaders take Overcast's wet ground and lying snow through the hook.
func test_the_world_hook_compiles_with_wet_ground_and_snow() -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
#define GOLDSRC_HOOK_WORLD
#include "res://shaders/goldsrc_hook.gdshaderinc"
varying vec3 world_pos;
void vertex() { world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec3 lit = goldsrc_lightmap(vec3(0.5), 1.0, world_pos);
	vec3 albedo = vec3(0.5);
	goldsrc_surface(lit, albedo, world_pos, vec3(0.0, 1.0, 0.0), NORMAL, VIEW);
	ALBEDO = albedo + lit;
}
"""
	var declared := {}
	for u in shader.get_shader_uniform_list():
		declared[u["name"]] = true
	assert_true(declared.has("puddle_scale"), "the hook wets the ground")
	assert_true(declared.has("snow_scale"), "and lays snow on it")
