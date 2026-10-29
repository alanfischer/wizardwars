extends "res://src/tests/test_base.gd"
## func_tracktrain (GoldSrc CFuncTrackTrain): runs a path_track route continuously (not
## corner-to-corner like func_train), turning to face its travel direction and taking a new
## speed from each node it passes.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

var _fired: Array[String] = []


## _fired collects the targets each mover triggered; it has to start empty per test.
func _setup_test(_test_name: String) -> void:
	_fired.clear()


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


func _track(track_name: String, pos: Vector3, keys := {}) -> NamedMarker:
	var m := NamedMarker.new()
	var e := {"classname": "path_track", "targetname": track_name}
	e.merge(keys)
	m.set_meta("entity", e)
	_root().add_child(m)
	m.global_position = pos
	_spawned.append(m)
	return m


## The "origin" key stands in for an ORIGIN brush, so the train rides its own pivot
## (what CFuncTrackTrain does) rather than the brush-centre fallback.
func _train(keys := {}) -> FuncTrackTrain:
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([Vector3.ZERO, Vector3(2, 1, 2), Vector3(0, 1, 0)]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {
		"classname": "func_tracktrain", "origin": "0 0 0",
		"target": "t1", "speed": "400", "wheels": "25",
	}
	e.merge(keys, true)
	body.set_meta("entity", e)
	body.set_script(FuncTrackTrain)
	_root().add_child(body)
	_spawned.append(body)
	await (Engine.get_main_loop() as SceneTree).process_frame  # deferred _activate lands
	return body


class _Probe:
	extends Node
	var _suite
	var _probe_name: String

	func _init(suite, probe_name: String) -> void:
		_suite = suite
		_probe_name = probe_name

	func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
		_suite._fired.append(_probe_name)


func _probe(probe_name: String) -> void:
	var p := _Probe.new(self, probe_name)
	_root().add_child(p)
	_spawned.append(p)
	TriggerSystem.register(probe_name, p)


func test_closed_route_loops_back_to_the_start() -> void:
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 10), {"target": "t3"})
	_track("t3", Vector3(10, 0, 10), {"target": "t1"})
	var t: FuncTrackTrain = await _train()
	assert_true(t._looping, "a route that rejoins itself is a loop")
	assert_eq(t._points.size(), 4, "the ring is closed by repeating the join node")
	assert_vec3_almost_eq(t._points[3], t._points[0], 0.001, "and it closes on the first node")


func test_dead_end_route_does_not_loop() -> void:
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 10))
	var t: FuncTrackTrain = await _train()
	assert_false(t._looping, "a route that just stops is not a loop")
	assert_eq(t._points.size(), 2, "two nodes, one segment")


func test_it_starts_on_the_first_node_and_travels() -> void:
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 20), {"target": "t1"})
	var t: FuncTrackTrain = await _train({"speed": "400"})  # 10 m/s
	# _train() eats a physics tick or two waiting on the deferred _activate, so an exact
	# origin flaked ~1/N runs (z=0.1667 = 10 m/s / 60 Hz). Allow that race's slack — still
	# two orders of magnitude short of the next path_track at z=20.
	var slack := 2.0 * 400.0 * GameConsts.SCALE_FACTOR / Engine.physics_ticks_per_second
	assert_lt(t.position.distance_to(Vector3.ZERO), slack,
		"starts on its first path_track (%.3f m from it)" % t.position.distance_to(Vector3.ZERO))
	var tree := Engine.get_main_loop() as SceneTree
	for i in 12:
		await tree.physics_frame
	assert_gt(t.position.z, 0.5, "and moves along the route (z %.2f)" % t.position.z)
	assert_lt(t.position.z, 20.0, "without overshooting the segment")


func test_node_speed_is_picked_up_on_arrival() -> void:
	# ww_shrinkspell's route accelerates the train from 100 through 250 this way.
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 1), {"target": "t3", "speed": "800"})
	_track("t3", Vector3(0, 0, 40))
	var t: FuncTrackTrain = await _train({"speed": "400"})
	assert_almost_eq(t.move_speed, 400.0 * GameConsts.SCALE_FACTOR, 0.001, "starts at its own speed")
	var tree := Engine.get_main_loop() as SceneTree
	for i in 20:
		await tree.physics_frame
	assert_almost_eq(t.move_speed, 800.0 * GameConsts.SCALE_FACTOR, 0.001,
		"passing t2 hands it that node's speed")


func test_passing_a_node_fires_its_message() -> void:
	_probe("arrived")
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 1), {"target": "t3", "message": "arrived"})
	_track("t3", Vector3(0, 0, 40))
	var t: FuncTrackTrain = await _train({"speed": "400"})
	var tree := Engine.get_main_loop() as SceneTree
	for i in 20:
		await tree.physics_frame
	assert_eq(_fired, ["arrived"], "the node's message target fires as the train passes")


func test_it_turns_to_face_its_direction_of_travel() -> void:
	# Two legs at right angles: the yaw must differ between them.
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 30), {"target": "t3"})
	_track("t3", Vector3(30, 0, 30))
	var t: FuncTrackTrain = await _train({"speed": "400"})
	var first_leg_yaw := t.rotation.y
	var tree := Engine.get_main_loop() as SceneTree
	for i in 200:  # past the corner
		await tree.physics_frame
	assert_gt(absf(angle_difference(first_leg_yaw, t.rotation.y)), 1.0,
		"yaw swings roughly a right angle when the route turns")


func test_a_stopped_train_holds_position() -> void:
	_track("t1", Vector3.ZERO, {"target": "t2"})
	_track("t2", Vector3(0, 0, 20), {"target": "t1"})
	var t: FuncTrackTrain = await _train({"speed": "400"})
	t.trigger(null, TriggerSystem.Type.OFF)
	var held := t.position
	var tree := Engine.get_main_loop() as SceneTree
	for i in 10:
		await tree.physics_frame
	assert_vec3_almost_eq(t.position, held, 0.001, "switched off, it stays put")
	t.trigger(null, TriggerSystem.Type.ON)
	for i in 10:
		await tree.physics_frame
	assert_gt(t.position.distance_to(held), 0.5, "and rolls again when switched back on")
