extends "res://src/tests/test_base.gd"
## `rain` and `night` both take values past 1: rain draws more drops and night keeps darkening.
## Everything else has to stop at a downpour and at black.
##
## Scene-run only (needs the ServerVars autoload): res://src/tests/run_tests.tscn.


func test_lightning_stops_at_a_downpour() -> void:
	var weather := WeatherSystem.new()
	for rain in ["1", "2", "6"]:
		ServerVars.set_from_string("rain", rain)
		var intensity := weather.rain_intensity()
		assert_almost_eq(WeatherSystem._heaviness(intensity), 1.0, 1e-6, "rain %s is a downpour" % rain)
		for i in 20:
			var gap := weather._strike_gap(intensity)
			assert_true(gap >= WeatherSystem.STRIKE_GAP_HEAVY.x and gap <= WeatherSystem.STRIKE_GAP_HEAVY.y,
				"rain %s waits a downpour's gap between strikes (got %.1f)" % [rain, gap])
	ServerVars.set_from_string("rain", "0")
	weather.free()


func test_night_past_full_stays_lit_by_something() -> void:
	var weather := WeatherSystem.new()
	for night in ["1", "1.5", "4"]:
		ServerVars.set_from_string("night", night)
		var n := NightMode.night_light()
		assert_true(n.x >= 0.0 and n.y >= 0.0 and n.z >= 0.0, "night %s never goes below black" % night)
		var sky := weather._sky_light()
		assert_false(is_nan(sky.r) or is_nan(sky.g) or is_nan(sky.b), "night %s lights the rain with a number" % night)
	ServerVars.set_from_string("night", "0")
	weather.free()
