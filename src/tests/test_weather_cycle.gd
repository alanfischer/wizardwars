extends "res://src/tests/test_base.gd"
## Dynamic weather on the `rain` var. The showers themselves are OvercastCycle's, tested there.


func test_rain_set_by_hand_takes_over() -> void:
	var cycle := WeatherCycle.new(99)
	_root().add_child(cycle)
	ServerVars.set_from_string("dynamic_weather", "on")
	for i in 6000:  # into the first shower, the cycle writing its own rain as it goes
		cycle._process(0.1)
		if float(ServerVars.get_value("rain")) > 0.0:
			break
	assert_true(bool(ServerVars.get_value("dynamic_weather")), "its own writes leave it on")
	assert_true(float(ServerVars.get_value("rain")) > 0.0, "it is raining by now")
	ServerVars.set_from_string("rain", "0.35")
	assert_false(bool(ServerVars.get_value("dynamic_weather")), "rain set by hand turns it off")
	assert_almost_eq(float(ServerVars.get_value("rain")), 0.35, 1e-6, "and the hand-set rain stays")
	ServerVars.set_from_string("rain", "0")
	cycle.free()
