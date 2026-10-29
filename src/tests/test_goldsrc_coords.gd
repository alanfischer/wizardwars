extends "res://src/tests/test_base.gd"
## GoldSrcEntity.to_goldsrc() must be the exact inverse of EntityBase.parse_vector3(): it backs the
## F3 position readout, so an axis swap or sign flip sends you to the wrong corner with no way to tell.
##
## Scene-run only (needs the GoldSrcEntity autoload): res://src/tests/run_tests.tscn.


func _parse(origin: String) -> Vector3:
	var e := EntityBase.new()
	var v := e.parse_vector3(origin)
	e.free()
	return v


func test_round_trips_real_map_coordinates() -> void:
	# ww_shrinkspell's three jump pads and a spawn point, straight out of the .bsp.
	for origin in ["460 -1364 -1016", "1356 -508 -1016", "1412 -1452 -1015", "236 -1036 -638"]:
		var world := _parse(origin)
		var back := GoldSrcEntity.to_goldsrc(world)
		var want := Vector3(
			float(origin.split(" ")[0]), float(origin.split(" ")[1]), float(origin.split(" ")[2]))
		assert_vec3_almost_eq(back, want, 0.01, "round trip of '%s'" % origin)


func test_axes_are_not_transposed() -> void:
	# One unit along each GoldSrc axis in turn, so a swap can't hide behind symmetry.
	assert_vec3_almost_eq(GoldSrcEntity.to_goldsrc(_parse("100 0 0")), Vector3(100, 0, 0), 0.01,
		"GoldSrc +x survives the trip")
	assert_vec3_almost_eq(GoldSrcEntity.to_goldsrc(_parse("0 100 0")), Vector3(0, 100, 0), 0.01,
		"GoldSrc +y survives the trip")
	assert_vec3_almost_eq(GoldSrcEntity.to_goldsrc(_parse("0 0 100")), Vector3(0, 0, 100), 0.01,
		"GoldSrc +z survives the trip")


func test_goldsrc_z_is_godot_height() -> void:
	# The readout's usefulness rests on this: "up" in the map file is the Y column here.
	var world := _parse("0 0 512")
	assert_gt(world.y, 0.0, "GoldSrc +z maps to Godot +y (height)")
	assert_almost_eq(GoldSrcEntity.to_goldsrc(world).z, 512.0, 0.01, "and comes back as z")
