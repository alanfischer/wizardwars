extends "res://src/tests/test_base.gd"
## MoverNetPublisher.publish() must emit a zero-velocity snapshot when a mover stops
## abruptly, so the client interp buffer holds at the true rest position instead
## of extrapolating past it and freezing there (the golem-cockpit rider-jitter bug).
##
## Scene-run only (needs the NetworkManager autoload): res://src/tests/run_tests.tscn.


# publish() reads the host entity's global_position, so both nodes must be in the tree. The
# publisher is added by hand (no setup()) — this exercises the publish funnel, not the synchronizer.
func _make_mover() -> MoverNetPublisher:
	var e := Node3D.new()
	_root().add_child(e)
	e.position = Vector3.ZERO
	var pub := MoverNetPublisher.new()
	pub.name = MoverNetPublisher.NODE_NAME
	e.add_child(pub)
	pub.publish()
	return pub


## publish()'s dt is real wall-clock time, not a nominal tick length, so a synchronous
## test needs actual elapsed time between publishes; busy-wait since _run_method can't await a timer.
static func _wait_real_usec(usec: int) -> void:
	var start := Time.get_ticks_usec()
	while Time.get_ticks_usec() - start < usec:
		pass


func test_moving_publishes_nonzero_velocity() -> void:
	var pub := _make_mover()
	_wait_real_usec(30000)  # long enough that 1 unit of travel stays under ENTITY_PUBLISH_TELEPORT_SPEED
	pub.get_parent().position = Vector3(1, 0, 0)
	pub.publish()
	assert_ne(pub.mover_net_vel, Vector3.ZERO, "a mover that moved this tick ships its velocity")
	pub.get_parent().queue_free()


func test_abrupt_stop_zeroes_published_velocity() -> void:
	var pub := _make_mover()
	_wait_real_usec(30000)  # long enough that 1 unit of travel stays under ENTITY_PUBLISH_TELEPORT_SPEED
	pub.get_parent().position = Vector3(1, 0, 0)
	pub.publish()                          # moving → velocity published
	assert_ne(pub.mover_net_vel, Vector3.ZERO, "precondition: moving")
	pub.publish()                          # same position → abrupt stop
	assert_eq(pub.mover_net_vel, Vector3.ZERO, "stop snapshot zeroes the velocity")
	assert_eq(pub.mover_net_angvel, Vector3.ZERO, "stop snapshot zeroes the angular velocity")
	assert_eq(pub.mover_net_pos, Vector3(1, 0, 0), "stop snapshot holds the real rest position")
	pub.get_parent().queue_free()


func test_externally_driven_mover_does_not_publish() -> void:
	# golem_interp=on hands limb transforms to the golem body: the mover stops streaming.
	var pub := _make_mover()
	pub.set_externally_driven(true)
	pub.get_parent().position = Vector3(3, 0, 0)
	var frozen := pub.mover_net_pos
	pub.publish()
	assert_eq(pub.mover_net_pos, frozen, "an externally-driven mover keeps its shadow frozen (no stream)")
	pub.get_parent().queue_free()


func test_idle_does_not_republish_after_stop() -> void:
	var pub := _make_mover()
	pub.get_parent().position = Vector3(1, 0, 0)
	pub.publish()                          # moving
	pub.publish()                          # stop snapshot (velocity now zero)
	var sentinel := 999999999
	pub.mover_net_stamp = sentinel
	pub.publish()                          # still idle → must not touch the shadow
	assert_eq(pub.mover_net_stamp, sentinel, "an already-idle mover ships nothing")
	pub.get_parent().queue_free()


# The stop snapshot exists to kill this overshoot: with only the moving sample, the buffer
# coasts vel*extrap_max past the stop and freezes; the zero-velocity sample pins it to rest.
func test_zero_velocity_sample_holds_buffer_at_rest() -> void:
	var rest := Vector3(5, 0, 0)

	var overshooting := InterpolationBuffer.new()
	overshooting.extrap_max = 0.25
	overshooting.push(1.0, Vector3(4, 0, 0), Vector3.ZERO, Vector3(10, 0, 0))
	overshooting.push(1.1, rest, Vector3.ZERO, Vector3(10, 0, 0))  # last sample still carries velocity
	var bad := overshooting.sample(1.1 + 0.25)
	assert_gt((bad.position - rest).length(), 0.5, "without the fix the buffer coasts past rest")

	var pinned := InterpolationBuffer.new()
	pinned.extrap_max = 0.25
	pinned.push(1.0, Vector3(4, 0, 0), Vector3.ZERO, Vector3(10, 0, 0))
	pinned.push(1.1, rest, Vector3.ZERO, Vector3(10, 0, 0))
	pinned.push(1.2, rest, Vector3.ZERO, Vector3.ZERO)  # the zero-velocity stop snapshot
	var good := pinned.sample(1.2 + 0.5)
	assert_true(good.holding, "dry past the window → static hold")
	assert_vec3_almost_eq(good.position, rest, 0.001, "held exactly at rest, no overshoot")
