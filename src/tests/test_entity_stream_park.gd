extends "res://src/tests/test_base.gd"
## A client stops drawing a spawner-managed dynamic entity once its snapshot stream dies
## mid-motion, and puts it back at the authority's current transform when it resumes — otherwise
## a corpse whose stream died mid-fall stayed floating on the client after the host rested it.
##
## Scene-run only (needs the NetworkManager autoload): res://src/tests/run_tests.tscn.


## A client-side replica: target node plus the NetInterp shadow-prop carrier the dynamic-entity
## spawner attaches. CLIENT authority so the bridge registers for interpolation, not publishing.
func _make_replica() -> NetInterpBridge:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	var target := Node3D.new()
	var bridge := NetInterpBridge.new()
	bridge.name = "NetInterp"
	target.add_child(bridge)
	_root().add_child(target)
	return bridge


func _teardown(bridge: NetInterpBridge) -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	bridge.get_parent().queue_free()


func test_stream_dying_mid_motion_parks_the_entity() -> void:
	var bridge := _make_replica()
	bridge.net_pos = Vector3(0, 5, 0)
	bridge.net_vel = Vector3(0, -8, 0)  # last we heard, it was still falling
	bridge._on_synced()
	bridge.park_if_stream_died()
	assert_false(bridge.get_parent().visible, "an entity we lost track of mid-motion is not drawn")
	_teardown(bridge)


func test_a_resting_entity_is_never_parked() -> void:
	var bridge := _make_replica()
	bridge.net_pos = Vector3(0, 5, 0)
	bridge.net_vel = Vector3.ZERO  # the publisher's explicit stop sample
	bridge._on_synced()
	bridge.park_if_stream_died()
	assert_true(bridge.get_parent().visible,
		"a quiet stream after a stop sample means the held position is still the true one")
	_teardown(bridge)


func test_resumed_stream_reveals_at_the_authority_transform() -> void:
	var bridge := _make_replica()
	bridge.net_pos = Vector3(0, 5, 0)
	bridge.net_vel = Vector3(0, -8, 0)
	bridge._on_synced()
	bridge.park_if_stream_died()
	assert_false(bridge.get_parent().visible, "precondition: parked")
	# The authority kept simulating while we were deaf; its next sample is where the entity really is.
	bridge.net_pos = Vector3(0, 0, 0)
	bridge.net_vel = Vector3.ZERO
	bridge.net_stamp += 1000
	bridge._on_synced()
	assert_true(bridge.get_parent().visible, "a resumed stream puts the entity back")
	assert_vec3_almost_eq(bridge.get_parent().global_position, Vector3(0, 0, 0), 0.001,
		"the reveal frame renders where the entity is now, not where we lost it")
	_teardown(bridge)


func test_parking_drops_the_stale_interp_history() -> void:
	var bridge := _make_replica()
	bridge.net_pos = Vector3(0, 5, 0)
	bridge.net_vel = Vector3(0, -8, 0)
	bridge._on_synced()
	var id := int(bridge.get_parent().get_instance_id())
	var buf: InterpolationBuffer = NetworkManager._entity_buffers.get(id)
	assert_true(buf != null and buf.has_data(), "precondition: the sample is buffered")
	bridge.park_if_stream_died()
	assert_false(buf.has_data(),
		"a resumed stream must snap, not lerp from a sample that is now seconds old")
	_teardown(bridge)
