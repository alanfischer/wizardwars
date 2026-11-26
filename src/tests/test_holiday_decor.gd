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


func _built(kind: String, size: float, seed_value: int) -> HolidayProps.Geo:
	var g := HolidayProps.Geo.new()
	HolidayProps.build(g, Transform3D.IDENTITY, kind, size, seed_value)
	return g


func test_round_props_face_out() -> void:
	assert_gt(_outward_share(func(g: HolidayProps.Geo) -> void:
		HolidayProps._sphere(g, Transform3D.IDENTITY, 0.05, Color.RED)), 0.99, "sphere")
	var rng := RandomNumberGenerator.new()
	for k in 5:
		assert_gt(_outward_share(func(g: HolidayProps.Geo) -> void:
			HolidayProps.build(g, Transform3D.IDENTITY, "pumpkin", 0.3, k)), 0.85, "pumpkin %d" % k)
		rng.seed = k
		var box := HolidayProps.Geo.new()
		HolidayProps._present(box, Transform3D.IDENTITY, rng, 0.4)
		var normals := box.normals()
		var centre := Vector3.ZERO
		for i in 20:  # the five paper faces come first; the ribbon and bow follow
			centre += box.verts[i] / 20.0
		for i in 20:
			assert_gt(normals[i].dot(box.verts[i] - centre), 0.0, "present %d paper vertex %d faces out" % [k, i])


func test_props_stand_on_the_floor() -> void:
	for k in 10:
		for kind: Array in [["pumpkin", 0.3], ["gourd", 0.12], ["cornucopia", 1.0], ["tree", 1.8],
				["present", 0.3], ["snowman", 0.26]]:
			assert_almost_eq(_built(kind[0], kind[1], k).lowest(), 0.0, 0.03, "%s %d rests on y=0" % [kind[0], k])


func _setup_test(_test_name: String) -> void:
	HolidayGroup.meshes = true  # the suite runs headless, where groups would otherwise draw nothing


func _teardown_test() -> void:
	HolidayGroup.meshes = DisplayServer.get_name() != "headless"
	super()


## A floor with one wall along it, settled: [space, floor points in front of the wall].
func _walled() -> Array:
	_floor_at(Vector3(0, -0.5, 0), Vector3(40, 1, 40))
	_wall_at(Vector3(0, 1.5, -3.0), Vector3(40, 3, 0.5))
	await _settle()
	var points := PackedVector3Array()
	for x in range(-18, 19, 2):
		for z in range(-2, 0):
			points.append(Vector3(x, 0, z))
	return [(_root() as Window).get_world_3d().direct_space_state, points]


func _group(data: Dictionary, is_host: bool) -> HolidayGroup:
	var group := HolidayGroup.new()
	group.setup(data, is_host)
	_root().add_child(group)
	_keep(group)
	return group


## A room's floor with one wall: groups go against the wall, and only there.
func test_groups_line_the_wall_and_repeat() -> void:
	var walled: Array = await _walled()
	var space: PhysicsDirectSpaceState3D = walled[0]
	var points: PackedVector3Array = walled[1]
	for holiday: String in HolidayDecor.HOLIDAYS:
		var first := HolidayDecor.place(space, points, 7, holiday)
		var second := HolidayDecor.place(space, points, 7, holiday)
		assert_gt(first.size(), 2, "%s: several groups along a 40 m wall" % holiday)
		assert_eq(first.size(), second.size(), "%s: same seed, same groups" % holiday)
		for i in mini(first.size(), second.size()):
			assert_eq(first[i]["props"], second[i]["props"], "%s group %d: same props" % [holiday, i])
			var group := _group(first[i], false)
			var a := group.global_transform * group._mesh.get_aabb()
			assert_almost_eq((first[i]["position"] as Vector3).z, -2.75, 0.01, "%s group %d stands at the wall" % [holiday, i])
			assert_lt(a.position.z, -2.2, "%s group %d sits against the wall" % [holiday, i])
			assert_gt(a.position.y, -0.05, "%s group %d is not sunk in the floor" % [holiday, i])
			assert_lt(a.end.y, 2.95, "%s group %d fits under the wall's top" % [holiday, i])


func test_no_wall_no_groups() -> void:
	_floor_at(Vector3(0, -0.5, 0), Vector3(40, 1, 40))
	await _settle()
	var space := (_root() as Window).get_world_3d().direct_space_state
	var groups := HolidayDecor.place(space, PackedVector3Array([Vector3(0, 0, 0), Vector3(8, 0, 8)]), 1, "christmas")
	assert_eq(groups.size(), 0, "open floor is left bare")


## The first group along a wall, stood up as the server would.
func _hosted() -> HolidayGroup:
	var walled: Array = await _walled()
	var placed := HolidayDecor.place(walled[0], walled[1], 3, "christmas")
	var group := _group(placed[0], true)
	await _settle()
	return group


func test_a_blow_pops_a_prop_and_it_comes_back() -> void:
	var was := HolidayGroup.respawn_after
	HolidayGroup.respawn_after = Vector2(0.1, 0.1)
	var group: HolidayGroup = await _hosted()
	var prop: HolidayProp = group._hits[0]
	assert_true(prop.is_in_group(&"unhunted"), "nothing aims at a prop")
	assert_eq(prop.team, GameConsts.Team.NONE, "and it is on nobody's side")
	Combat.damage_chain(prop._body, 5.0, GameConsts.DamageType.PHYSICAL)
	assert_true(group.is_popped(0), "a blow pops it")
	assert_false(prop.is_in_group(&"damageable"), "gone from every search while popped")
	assert_eq(prop._body.collision_layer, 0, "and from every trace")
	assert_false(group.is_popped(1), "and only it")
	await _tree().create_timer(0.3).timeout
	assert_false(group.is_popped(0), "back after a while")
	assert_true(prop.is_in_group(&"damageable"), "and hittable again")
	HolidayGroup.respawn_after = was


func test_a_shot_a_blast_and_a_swing_reach_props() -> void:
	var group: HolidayGroup = await _hosted()
	var centre := SpatialQuery.collision_center(group._hits[0])
	var from := centre + Vector3(0, 0, 4)
	var ray := Combat.hitscan(group, from, (centre - from).normalized(), 10.0)
	assert_true(Combat.apply_hitscan_damage(ray, 10.0, GameConsts.DamageType.PHYSICAL, null), "a hitscan finds one")
	var last := group._hits.size() - 1
	var space := group.get_world_3d().direct_space_state
	Combat.apply_aoe_damage(space, SpatialQuery.collision_center(group._hits[last]) + Vector3(0, 0, 0.6), 50.0, 1.0)
	assert_true(group.is_popped(last), "a blast pops what it reaches")
	var swung := group._hits[1] if last > 1 else group._hits[0]
	var at := SpatialQuery.collision_center(swung) + Vector3(0, 0, 1.0)
	var swing := Combat.raycast_world(group, at, Vector3(0, 0, -1), 1.5, RID(), GameConsts.MASK_MELEE)
	assert_false(swing.result.is_empty(), "a swing's trace meets one")
	var walk := Combat.raycast_world(group, at, Vector3(0, 0, -1), 1.5, RID(), GameConsts.MASK_WORLD_AND_CLIP)
	assert_true(walk.result.is_empty() or not (Combat.find_damageable(walk.result.collider) is HolidayProp),
			"and nothing that moves collides with one")


## What rides the snapshot is the popped mask with the time it last changed: a client that
## learns of an old pop (joining, or coming back into view) hides it without a burst.
func test_a_client_follows_the_state() -> void:
	var walled: Array = await _walled()
	var replica := _group(HolidayDecor.place(walled[0], walled[1], 3, "christmas")[0], false)
	assert_eq(replica._hits.size(), 0, "a client holds nothing to hit")
	replica.state = Vector2i(0b101, 1)
	assert_true(replica.is_popped(0) and not replica.is_popped(1) and replica.is_popped(2), "it hides what the server popped")
