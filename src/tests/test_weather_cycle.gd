extends "res://src/tests/test_base.gd"
## Dynamic weather: showers of a few minutes with dry spells between, never a jump in the rain.


func test_showers_come_and_go() -> void:
	var cycle := WeatherCycle.new(1234)
	var dt := 0.25
	var showers: Array[float] = []
	var dry_spells: Array[float] = []
	var run := 0.0
	var wet := false
	var last := 0.0
	var worst_step := 0.0
	var lo := INF
	var hi := -INF
	var t := 0.0
	while t < 3.0 * 3600.0:
		t += dt
		var r := cycle.rain_at(t)
		lo = minf(lo, r)
		hi = maxf(hi, r)
		if (r > 0.0) != wet:
			(showers if wet else dry_spells).append(run)
			wet = r > 0.0
			run = 0.0
		run += dt
		worst_step = maxf(worst_step, absf(r - last))
		last = r
	assert_true(lo == 0.0 and hi <= WeatherCycle.PEAK.y and hi > 0.3, "rain spans dry to heavy (%.2f..%.2f)" % [lo, hi])
	assert_true(showers.size() >= 10, "it rains on and off (%d showers in 3 h)" % showers.size())
	for s in showers:
		assert_true(s >= WeatherCycle.SHOWER.x - 1.0 and s <= WeatherCycle.SHOWER.y + 1.0,
			"a shower lasts a few minutes (%.0f s)" % s)
	for d in dry_spells.slice(1):
		assert_true(d >= WeatherCycle.DRY.x - 1.0, "dry for a while between showers (%.0f s)" % d)
	assert_true(worst_step < 0.02, "the rain never jumps (worst %.4f per %.2f s)" % [worst_step, dt])
	cycle.free()
