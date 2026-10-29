extends "res://src/tests/test_base.gd"
## A node bound for client-side interpolation opts out of Godot's physics interpolation, since
## interp_entities() already writes its transform every frame; the authority keeps it on.
##
## Scene-run only (needs the NetworkManager autoload): res://src/tests/run_tests.tscn.


func _make_node() -> Node3D:
	var node := Node3D.new()
	_root().add_child(node)
	return node


func _cleanup(node: Node3D, id: int) -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	NetworkManager.unregister_interp_node(id)
	node.queue_free()


func test_client_replica_opts_out() -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	var node := _make_node()
	NetworkManager.register_interp_node(9701, node)
	assert_eq(node.physics_interpolation_mode, Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"a client replica is positioned by interpolation, not physics")
	_cleanup(node, 9701)


func test_authority_keeps_physics_interpolation() -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.AUTHORITY
	var node := _make_node()
	NetworkManager.register_interp_node(9702, node)
	assert_eq(node.physics_interpolation_mode, Node.PHYSICS_INTERPOLATION_MODE_INHERIT,
		"the authority's copy moves on the physics tick and wants the engine's smoothing")
	_cleanup(node, 9702)


## Map movers (doors, plats, golem limbs) reach interp_entities through register_synced_entity
## rather than a NetInterpBridge, so the opt-out has to live under both doors.
func test_mover_registration_opts_out() -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	var node := _make_node()
	var id := NetworkManager.register_synced_entity(node)
	assert_eq(node.physics_interpolation_mode, Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"a client's mover copy is written by interp_entities every frame")
	_cleanup(node, id)


## The mode propagates to the subtree, which is how the pieces interp_entities never touches
## directly (a corpse's model, a mover's AnimatableBody3D) come along.
func test_opt_out_covers_the_subtree() -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	var node := _make_node()
	var child := Node3D.new()
	node.add_child(child)
	NetworkManager.register_interp_node(9703, node)
	assert_false(child.is_physics_interpolated(),
		"a child inherits the opt-out from the node interp_entities drives")
	_cleanup(node, 9703)
