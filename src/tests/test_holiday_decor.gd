extends "res://src/tests/test_base.gd"
## Holiday props face outward, and the same map and seed dress the same walls.


func _outward_share(build: Callable) -> float:
	var g := HolidayProps.Geo.new()
	build.call(g)
	var normals := g.normals()
	var centre := Vector3.ZERO
	for v in g.verts:
		centre += v
	centre /= g.verts.size()
	var out := 0
	for i in g.verts.size():
		if normals[i].dot(g.verts[i] - centre) > 0.0:
			out += 1
	return float(out) / g.verts.size()


func test_round_props_face_out() -> void:
	var rng := RandomNumberGenerator.new()
	for k in 5:
		rng.seed = k
		assert_gt(_outward_share(func(g: HolidayProps.Geo) -> void:
			HolidayProps.pumpkin(g, Transform3D.IDENTITY, rng, 0.3)), 0.85, "pumpkin %d" % k)
		assert_gt(_outward_share(func(g: HolidayProps.Geo) -> void:
			HolidayProps._sphere(g, Transform3D.IDENTITY, 0.05, Color.RED)), 0.99, "sphere %d" % k)
		var box := HolidayProps.Geo.new()
		HolidayProps._present(box, Transform3D.IDENTITY, rng, 0.4)
		var normals := box.normals()
		var centre := Vector3.ZERO
		for i in 20:  # the five paper faces come first; the ribbon and bow follow
			centre += box.verts[i] / 20.0
		for i in 20:
			assert_gt(normals[i].dot(box.verts[i] - centre), 0.0, "present %d paper vertex %d faces out" % [k, i])


func test_props_stand_on_the_floor() -> void:
	var rng := RandomNumberGenerator.new()
	for k in 10:
		rng.seed = k
		for build: Callable in [
				func(g: HolidayProps.Geo) -> void: HolidayProps.pumpkin(g, Transform3D.IDENTITY, rng, 0.3),
				func(g: HolidayProps.Geo) -> void: HolidayProps.gourd(g, Transform3D.IDENTITY, rng, 0.12),
				func(g: HolidayProps.Geo) -> void: HolidayProps.cornucopia(g, Transform3D.IDENTITY, rng, 1.0),
				func(g: HolidayProps.Geo) -> void: HolidayProps.tree(g, Transform3D.IDENTITY, rng, 1.8),
				func(g: HolidayProps.Geo) -> void: HolidayProps.present(g, Transform3D.IDENTITY, rng, 0.3),
				func(g: HolidayProps.Geo) -> void: HolidayProps.snowman(g, Transform3D.IDENTITY, rng, 0.26)]:
			var g := HolidayProps.Geo.new()
			build.call(g)
			var low := INF
			for v in g.verts:
				low = minf(low, v.y)
			assert_almost_eq(low, 0.0, 0.03, "seed %d rests on y=0" % k)


## A room's floor with one wall: groups go against the wall, and only there.
func test_groups_line_the_wall_and_repeat() -> void:
	_floor_at(Vector3(0, -0.5, 0), Vector3(40, 1, 40))
	_wall_at(Vector3(0, 1.5, -3.0), Vector3(40, 3, 0.5))
	await _settle()
	var points := PackedVector3Array()
	for x in range(-18, 19, 2):
		for z in range(-2, 3):
			points.append(Vector3(x, 0, z))
	var space := (_root() as Window).get_world_3d().direct_space_state
	for holiday: String in HolidayDecor.HOLIDAYS:
		var first := HolidayDecor.place(space, points, 7, holiday)
		var second := HolidayDecor.place(space, points, 7, holiday)
		assert_gt(first.size(), 2, "%s: several groups along a 40 m wall" % holiday)
		assert_eq(first.size(), second.size(), "%s: same seed, same groups" % holiday)
		for i in mini(first.size(), second.size()):
			var a := first[i].mesh.get_aabb()
			assert_vec3_almost_eq(a.position, second[i].mesh.get_aabb().position, 1e-5, "%s group %d" % [holiday, i])
			assert_lt(a.position.z, -2.4, "%s group %d sits against the wall" % [holiday, i])
			assert_gt(a.position.y, -0.05, "%s group %d is not sunk in the floor" % [holiday, i])
			assert_lt(a.end.y, 2.95, "%s group %d fits under the wall's top" % [holiday, i])
		for mi in first + second:
			mi.free()


func test_no_wall_no_groups() -> void:
	_floor_at(Vector3(0, -0.5, 0), Vector3(40, 1, 40))
	await _settle()
	var space := (_root() as Window).get_world_3d().direct_space_state
	var groups := HolidayDecor.place(space, PackedVector3Array([Vector3(0, 0, 0), Vector3(8, 0, 8)]), 1, "christmas")
	assert_eq(groups.size(), 0, "open floor is left bare")
