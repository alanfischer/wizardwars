extends "res://src/tests/test_base.gd"
## `rain` takes values past 1, where it only draws more drops; `time` is hours round the clock.
## (Overcast tests the weather itself.)
##
## Scene-run only (needs the ServerVars autoload): res://src/tests/run_tests.tscn.


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
