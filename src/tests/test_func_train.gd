extends "res://src/tests/test_base.gd"
## func_train path following (GoldSrc CFuncTrain): the brush is centred on each path_corner
## (`corner->origin - (mins+maxs)*0.5`), so a train off its node origin (no ORIGIN brush) lands
## half a brush away if the pivot is skipped. The corner chain also carries leg speed, wait,
## teleport/retrigger flags, and the pass-through "message" target.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

var _fired: Array[String] = []


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## _fired collects the targets each mover triggered; it has to start empty per test.
func _setup_test(_test_name: String) -> void:
	_fired.clear()


## A path_corner at `pos`. `keys` adds entity keys (target, wait, speed, spawnflags, message).
func _corner(corner_name: String, pos: Vector3, keys := {}) -> NamedMarker:
	var m := NamedMarker.new()
	var e := {"classname": "path_corner", "targetname": corner_name}
	e.merge(keys)
	m.set_meta("entity", e)
	_root().add_child(m)
	m.global_position = pos
	_spawned.append(m)
	return m


## A train whose brush spans (0,0,0)..(2,2,2) in local space, so its pivot is (1,1,1) —
## the offset the GoldSrc centring rule has to cancel out. Mirrors the map path: the
## script goes onto the BSP's AnimatableBody3D (main.gd set_script), not a fresh node.
func _train(keys := {}) -> FuncTrain:
	# Untyped on purpose: an AnimatableBody3D only becomes a FuncTrain once the script
	# is attached, which the static analyser can't see (and won't let us cast through).
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([Vector3.ZERO, Vector3(2, 2, 2), Vector3(0, 2, 0)]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {"classname": "func_train"}
	e.merge(keys)
	body.set_meta("entity", e)
	body.set_script(FuncTrain)
	_root().add_child(body)
	_spawned.append(body)
	await (Engine.get_main_loop() as SceneTree).process_frame  # deferred _activate lands
	return body


func _target_probe(probe_name: String) -> void:
	_target_probe_into(_fired, probe_name)


func test_first_corner_centres_the_brush() -> void:
	_corner("c1", Vector3(10, 5, -3), {"target": "c2"})
	_corner("c2", Vector3(10, 5, 0))
	var t: FuncTrain = await _train({"target": "c1", "targetname": "tr", "speed": "100"})
	# Parked (named train, untriggered) on its first corner: brush centre on the corner,
	# so the node sits a pivot back from it.
	assert_vec3_almost_eq(t.position, Vector3(10, 5, -3) - Vector3(1, 1, 1), 0.001,
		"the brush centre, not the node origin, lands on the first path_corner")


func test_named_train_starts_on_a_single_trigger() -> void:
	_corner("c1", Vector3.ZERO, {"target": "c2"})
	_corner("c2", Vector3(0, 0, 8))
	var t: FuncTrain = await _train({"target": "c1", "targetname": "tr", "speed": "100"})
	assert_eq(t.state, FuncTrain.State.AT_BOTTOM, "a named train parks until triggered")
	t.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(t.state, FuncTrain.State.GOING_UP, "one trigger sets it rolling")
	t.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(t.state, FuncTrain.State.AT_BOTTOM, "the next trigger stops it")


func test_untargeted_train_runs_from_map_load() -> void:
	_corner("c1", Vector3.ZERO, {"target": "c2"})
	_corner("c2", Vector3(0, 0, 8))
	var t: FuncTrain = await _train({"target": "c1", "speed": "100"})
	assert_eq(t.state, FuncTrain.State.GOING_UP, "no targetname → starts itself")


func test_leg_speed_comes_from_the_corner_left_behind() -> void:
	_corner("c1", Vector3.ZERO, {"target": "c2", "speed": "400"})
	_corner("c2", Vector3(0, 0, 8), {"speed": "50"})
	var t: FuncTrain = await _train({"target": "c1", "speed": "100"})
	assert_almost_eq(t.move_speed, 400.0 * GameConsts.SCALE_FACTOR, 0.001,
		"the leg runs at the speed of the corner it departs, not the one it enters")


func test_teleport_corner_snaps_without_travelling() -> void:
	_corner("c1", Vector3.ZERO, {"target": "c2"})
	_corner("c2", Vector3(0, 0, 8), {"spawnflags": "2", "wait": "5"})
	var t: FuncTrain = await _train({"target": "c1", "speed": "1"})
	# speed 1 (0.025 m/s) would take minutes to slide 8m — a teleport corner is instant.
	assert_vec3_almost_eq(t.position, Vector3(0, 0, 8) - Vector3(1, 1, 1), 0.001,
		"a SF_CORNER_TELEPORT corner jumps the train there")
	assert_eq(t.state, FuncTrain.State.AT_BOTTOM, "and it is parked, not sliding")


func test_retrigger_corner_parks_the_train() -> void:
	_corner("c1", Vector3.ZERO, {"target": "c2"})
	_corner("c2", Vector3(0, 0, 8), {"target": "c3", "spawnflags": "3"})  # teleport + wait
	_corner("c3", Vector3(0, 0, 16))
	var t: FuncTrain = await _train({"target": "c1", "speed": "100"})
	assert_true((t.spawn_flags & FuncTrain.SF_TRAIN_WAIT_RETRIGGER) != 0,
		"a SF_CORNER_WAIT_RETRIGGER corner leaves the train waiting for a trigger")
	assert_vec3_almost_eq(t.position, Vector3(0, 0, 8) - Vector3(1, 1, 1), 0.001,
		"parked on that corner, not the one past it")
	t.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(t.state, FuncTrain.State.GOING_UP, "and it resumes when triggered")


func test_corner_message_fires_on_arrival() -> void:
	_target_probe("screenflash")
	_corner("c1", Vector3.ZERO, {"target": "c2"})
	_corner("c2", Vector3(0, 0, 8), {"spawnflags": "2", "message": "screenflash", "wait": "5"})
	var t: FuncTrain = await _train({"target": "c1", "speed": "100"})
	assert_eq(t.state, FuncTrain.State.AT_BOTTOM, "precondition: arrived")
	assert_eq(_fired, ["screenflash"], "the corner's message target fires when the train arrives")


func test_jump_pad_bounces_out_and_back_on_one_trigger() -> void:
	# ww_shrinkspell's launch pads: two corners pointing at each other, the home one
	# flagged wait-for-retrigger. One trigger (via multi_manager) must run BOTH legs —
	# out and back — and re-park, not strand the pad at the far corner.
	_target_probe("bounced")
	_corner("home", Vector3.ZERO, {"target": "away", "spawnflags": "1"})
	_corner("away", Vector3(0, 0.3, 0), {"target": "home", "message": "bounced"})
	var t: FuncTrain = await _train({"target": "home", "targetname": "pad", "speed": "500"})
	t.trigger(null, TriggerSystem.Type.TOGGLE)
	var tree := Engine.get_main_loop() as SceneTree
	for i in 10:
		await tree.physics_frame
	assert_eq(_fired, ["bounced"], "the pad reached the far corner (its message fired)")
	assert_vec3_almost_eq(t.position, Vector3.ZERO - Vector3(1, 1, 1), 0.001,
		"and came back to the home corner")
	assert_true((t.spawn_flags & FuncTrain.SF_TRAIN_WAIT_RETRIGGER) != 0,
		"parked there, ready for the next player to trip the trigger")


func test_passable_train_is_not_solid() -> void:
	_corner("c1", Vector3.ZERO, {"target": "c2"})
	_corner("c2", Vector3(0, 0, 8))
	var t: FuncTrain = await _train({"target": "c1", "spawnflags": "8"})
	assert_eq(t._anim_body.collision_layer, 0, "SF_TRAIN_PASSABLE clears the brush's collision layer")
