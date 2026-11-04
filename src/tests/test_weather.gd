extends "res://src/tests/test_base.gd"
## `rain` and `night` both take values past 1: rain draws more drops and night keeps darkening.
## Everything else has to stop at a downpour and at black. (Overcast tests the weather itself.)
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


func test_night_past_full_stays_lit_by_something() -> void:
	for night in ["1", "1.5", "4"]:
		ServerVars.set_from_string("night", night)
		var n := NightMode.night_light()
		assert_true(n.x >= 0.0 and n.y >= 0.0 and n.z >= 0.0, "night %s never goes below black" % night)
		var sky := WeatherSystem.sky_light_now()
		assert_false(is_nan(sky.r) or is_nan(sky.g) or is_nan(sky.b), "night %s lights the rain with a number" % night)
	ServerVars.set_from_string("night", "0")


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
	var weather := WeatherSystem.new()
	weather._take_rain_floor(map_root)
	for q in [Vector3(3.5, 0, -0.5), Vector3(-0.5, 0, 1.5), Vector3(1.2, 0, 0.7)]:
		# goldsrc-godot's own lookup (rain_floor.gdshaderinc before Overcast).
		var u: float = (origin.x - q.x) / size.x
		var v: float = (q.z - origin.z) / size.y
		var want := img.get_pixel(int(u * 5), int(v * 3)).r
		assert_eq(weather.floor_at(q), want, "column at %s" % q)
	weather.free()
	map_root.free()
