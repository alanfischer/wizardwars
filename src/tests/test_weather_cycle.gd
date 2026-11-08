extends "res://src/tests/test_base.gd"
## Dynamic weather and dynamic wind on the `rain` and wind vars. The showers themselves are OvercastCycle's, tested there.


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
	_calm(cycle)


func test_the_wind_rises_falls_and_turns_on_its_own() -> void:
	var cycle := WeatherCycle.new(99)
	_root().add_child(cycle)
	ServerVars.set_from_string("dynamic_wind", "on")
	cycle._process(0.1)
	assert_gt(float(ServerVars.get_value("wind")), 0.0, "the wind blows straight away, with no showers")
	var dirs := {}
	var speeds := {}
	var hardest := 0.0
	for i in 6000:  # ten minutes
		cycle._process(0.1)
		dirs[ServerVars.get_value("wind_dir")] = true
		speeds[ServerVars.get_value("wind")] = true
		hardest = maxf(hardest, float(ServerVars.get_value("wind")))
	assert_gt(dirs.size(), 3, "it turns as it goes")
	assert_gt(speeds.size(), 3, "and rises and falls")
	assert_lt(hardest, OvercastCycle.BREEZE.y + 0.1, "a breeze at most, out of the showers")
	assert_true(bool(ServerVars.get_value("dynamic_wind")), "its own writes leave it on")
	_calm(cycle)


func test_wind_set_by_hand_takes_over_until_handed_back() -> void:
	var cycle := WeatherCycle.new(99)
	_root().add_child(cycle)
	ServerVars.set_from_string("dynamic_wind", "on")
	cycle._process(0.1)
	ServerVars.set_from_string("wind", "8")
	assert_false(bool(ServerVars.get_value("dynamic_wind")), "wind set by hand turns it off")
	for i in 100:
		cycle._process(0.1)
	assert_eq(float(ServerVars.get_value("wind")), 8.0, "and the hand-set wind stays")
	ServerVars.set_from_string("dynamic_wind", "on")
	cycle._process(0.1)
	assert_lt(float(ServerVars.get_value("wind")), OvercastCycle.BREEZE.y + 0.1, "handed back, it blows its own way")
	_calm(cycle)


func test_showers_blow_harder_and_leave_the_breeze_when_they_stop() -> void:
	var cycle := WeatherCycle.new(99)
	_root().add_child(cycle)
	ServerVars.set_from_string("dynamic_wind", "on")
	ServerVars.set_from_string("dynamic_weather", "on")
	var harder := 0.0  # most a shower's wind has blown over the breeze it would have been
	for i in 36000:  # an hour of showers
		cycle._process(0.1)
		var breeze := cycle._cycle.breeze_at(cycle._t).length()
		harder = maxf(harder, float(ServerVars.get_value("wind")) - breeze)
	assert_gt(harder, 0.5, "a shower blows harder than the breeze (by %.1f m/s)" % harder)
	ServerVars.set_from_string("dynamic_weather", "off")
	assert_true(bool(ServerVars.get_value("dynamic_wind")), "the wind carries on without them")
	for i in 10:
		cycle._process(0.1)
	assert_lt(float(ServerVars.get_value("wind")), OvercastCycle.BREEZE.y + 0.1, "as a breeze")
	_calm(cycle)


## Back to the defaults the other suites expect.
func _calm(cycle: WeatherCycle) -> void:
	cycle.free()
	ServerVars.set_from_string("dynamic_weather", "off")
	ServerVars.set_from_string("dynamic_wind", "on")
	ServerVars.set_from_string("rain", "0")
	ServerVars.set_from_string("wind", "0")
	ServerVars.set_from_string("wind_dir", "0")
