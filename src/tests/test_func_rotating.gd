extends "res://src/tests/test_base.gd"
## func_rotating: which axis the spawnflags actually name, and the fanfriction ramp. Two
## easy-to-get-backwards GoldSrc details: flag 1 (SF_BRUSH_ROTATE_INSTANT) means spin from spawn,
## and the axis flags name an angles component, not a world axis — "X Axis" is pitch, default yaw.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


func _rotator(keys := {}) -> FuncRotating:
	# Untyped on purpose: the script only makes it a FuncRotating at runtime.
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([Vector3.ZERO, Vector3(2, 2, 2), Vector3(0, 2, 0)]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {"classname": "func_rotating", "speed": "75"}
	e.merge(keys, true)  # overwrite: some tests override a default key
	body.set_meta("entity", e)
	body.set_script(FuncRotating)
	_root().add_child(body)
	_spawned.append(body)
	return body


func _spin_frames(n := 4) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for i in n:
		await tree.physics_frame


func test_instant_flag_spins_from_spawn() -> void:
	var r: FuncRotating = _rotator({"spawnflags": "65"})  # instant + not solid
	await _spin_frames()
	assert_gt(r.rotation.length(), 0.0, "SF_BRUSH_ROTATE_INSTANT starts the brush rotating")


func test_unflagged_rotator_waits_to_be_triggered() -> void:
	var r: FuncRotating = _rotator({"spawnflags": "72", "targetname": "biglight"})
	await _spin_frames()
	assert_almost_eq(r.rotation.length(), 0.0, 0.0001, "no instant flag → idle at spawn")
	r.trigger(null, TriggerSystem.Type.TOGGLE)
	await _spin_frames()
	assert_gt(absf(r.rotation.z), 0.0, "and the trigger spins it")


func test_axis_flags_name_angle_components_not_world_axes() -> void:
	# Godot axes: HL yaw → +Y (up), HL pitch → +Z, HL roll → -X.
	var yaw: FuncRotating = _rotator({"spawnflags": "1"})  # no axis flag: ceiling fan
	var pitch: FuncRotating = _rotator({"spawnflags": "9"})  # "X Axis"
	var roll: FuncRotating = _rotator({"spawnflags": "5"})  # "Z Axis"
	assert_vec3_almost_eq(yaw._axis, Vector3(0, 1, 0), 0.0001,
		"the unflagged default is yaw — a fan spinning about the up axis")
	assert_vec3_almost_eq(pitch._axis, Vector3(0, 0, 1), 0.0001,
		"'X Axis' is pitch: a wall disc turns in the plane of the wall, not out of it")
	assert_vec3_almost_eq(roll._axis, Vector3(-1, 0, 0), 0.0001, "'Z Axis' is roll")


func test_reverse_flag_flips_the_direction() -> void:
	var fwd: FuncRotating = _rotator({"spawnflags": "9"})
	var rev: FuncRotating = _rotator({"spawnflags": "11"})  # + SF_BRUSH_ROTATE_BACKWARDS
	assert_vec3_almost_eq(rev._axis, -fwd._axis, 0.0001, "backwards mirrors the axis")


func test_switched_off_rotator_coasts_to_a_stop() -> void:
	# fanfriction 20 (the map default) sheds 20% of max speed per 0.1s think, so
	# a stopped rotator takes ~0.5s to wind down rather than freezing on the spot.
	var r: FuncRotating = _rotator({"spawnflags": "65", "fanfriction": "20"})
	await _spin_frames()
	r.trigger(null, TriggerSystem.Type.TOGGLE)
	var at_stop_command := r.rotation
	await _spin_frames(3)
	assert_gt((r.rotation - at_stop_command).length(), 0.0, "it keeps turning while winding down")
	assert_gt(r._speed, 0.0, "still under way")
	await _spin_frames(40)
	var halted := r.rotation
	assert_almost_eq(r._speed, 0.0, 0.0001, "the ramp reaches zero")
	await _spin_frames()
	assert_vec3_almost_eq(r.rotation, halted, 0.0001, "and it stays where it stopped")


func test_accdcc_fan_winds_up_instead_of_snapping_to_speed() -> void:
	var plain: FuncRotating = _rotator({"spawnflags": "1"})
	var fan: FuncRotating = _rotator({"spawnflags": "17"})  # + SF_BRUSH_ACCDCC
	assert_almost_eq(plain._speed, plain._max_speed, 0.0001, "a plain rotator is at speed at once")
	assert_almost_eq(fan._speed, 0.0, 0.0001, "an acc/dcc fan starts from a standstill")
	await _spin_frames(40)
	assert_almost_eq(fan._speed, fan._max_speed, 0.0001, "and ramps up to full speed")


func test_not_solid_flag_clears_collision() -> void:
	var r: FuncRotating = _rotator({"spawnflags": "65"})
	assert_eq(r._anim_body.collision_layer, 0, "SF_ROTATING_NOT_SOLID clears the brush's layer")
