extends "res://src/tests/test_base.gd"
## The noon sun: where the map compiled it, lifted only off the horizon.

var _saved: Dictionary


func _setup_test(test_name: String) -> void:
	super._setup_test(test_name)
	_saved = MapSun._info


func _teardown_test() -> void:
	MapSun._info = _saved
	super._teardown_test()


func _elevation_deg(dir: Vector3) -> float:
	return rad_to_deg(asin(dir.normalized().y))


func _compiled(pitch_deg: float) -> Vector3:
	var p := deg_to_rad(pitch_deg)
	return Vector3(cos(p), sin(p), 0.0)


func test_a_compiled_sun_high_enough_is_kept() -> void:
	for pitch in [10.0, 30.0, 75.0]:
		MapSun._info = {"dir": _compiled(pitch)}
		assert_almost_eq(_elevation_deg(MapSun.noon_dir()), pitch, 1e-3, "pitch %s" % pitch)


func test_a_flat_sun_climbs_only_a_little_and_keeps_its_bearing() -> void:
	MapSun._info = {"dir": _compiled(0.0)}
	var noon := MapSun.noon_dir()
	assert_almost_eq(_elevation_deg(noon), 10.0, 1e-3, "lifted to the floor")
	assert_almost_eq(noon.z, 0.0, 1e-6, "on the compiled bearing")
	assert_gt(noon.x, 0.0, "facing the same way")
