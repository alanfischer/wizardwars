extends "res://src/tests/test_base.gd"
## OwnerState: a client's own movement state, replicated to it alone through the snapshot. The
## synchronizer it builds, the flag packing on the way in, the decode on the way out, and the
## path identity a reconnect relies on.
##
## Scene-run only (NetworkManager is an autoload).

const PEER := 9001


class Handler extends Node:
	var got: Array = []

	func _on_owner_state(seq: int, pos: Vector3, vel: Vector3, crouched: bool, on_floor: bool,
			jumping: bool, jump_held: bool) -> void:
		got.append([seq, pos, vel, crouched, on_floor, jumping, jump_held])


var _handler: Handler


func _setup_test(_test_name: String) -> void:
	_handler = _keep(Handler.new())
	_root().add_child(_handler)
	NetworkManager.register_sync_handler(_handler)


func _teardown_test() -> void:
	NetworkManager._free_owner_state(PEER)
	NetworkManager.net_input_queue_depth = 0
	super._teardown_test()


## Out of the tree: offline, an in-tree sync's visibility change reaches the stock replication
## interface, which has never heard of PEER and says so.
func test_the_sync_is_hidden_until_shown_to_its_owner() -> void:
	var node: OwnerState = _keep(OwnerState.create(PEER))
	assert_eq(String(node.name), "OwnerState_%d" % PEER, "named by its peer, the same on both ends")
	assert_false(node.sync.public_visibility, "not public")
	assert_false(node.sync.get_visibility_for(PEER), "hidden from its owner until the map is loaded")
	node.show_to_owner(PEER)
	assert_true(node.sync.get_visibility_for(PEER), "shown to its owner")
	assert_false(node.sync.get_visibility_for(PEER + 1), "and to nobody else")


func test_the_sync_replicates_the_spec_with_its_hints() -> void:
	var node := NetworkManager._add_owner_state(PEER)
	var props: Array = node.sync.replication_config.get_properties().map(func(p): return String(p))
	assert_eq(props, OwnerState.SPEC.keys(), "every declared slot, in order")
	assert_eq(node.sync.get_meta("gn_quant"), {}, "no lossy tags")
	assert_eq(node.sync.get_meta("gn_grid"), {"pos": GameConsts.SCALE_FACTOR / 128.0,
			"vel": GameConsts.SCALE_FACTOR / 8.0}, "position and velocity on clientdata_t's grids")
	assert_eq(float(node.sync.get_meta("gn_priority")), OwnerState.PRIORITY, "first into a full packet")
	assert_eq(node.sync.get_meta("gn_push").size(), OwnerState.SPEC.size(), "every slot is pushed")


func test_write_packs_the_flags() -> void:
	var node := NetworkManager._add_owner_state(PEER)
	node.write(42, Vector3(1, 2, 3), Vector3(4, 5, 6), true, false, true, false, 3)
	assert_eq(node.seq, 42)
	assert_eq(node.pos, Vector3(1, 2, 3))
	assert_eq(node.vel, Vector3(4, 5, 6))
	assert_eq(node.flags, OwnerState.FLAG_CROUCHED | OwnerState.FLAG_JUMPING)
	assert_eq(node.queue_depth, 3)


func test_a_synced_state_reaches_the_reconcile_handler() -> void:
	var node := NetworkManager._add_owner_state(PEER)
	node.write(7, Vector3(1, 0, 0), Vector3(0, 0, 2), false, true, false, true, 5)
	NetworkManager._on_owner_state_synced(node)
	assert_eq(_handler.got, [[7, Vector3(1, 0, 0), Vector3(0, 0, 2), false, true, false, true]],
			"decoded flags in the handler's order")
	assert_eq(NetworkManager.net_input_queue_depth, 5, "queue depth for the net graph")


func test_no_reconcile_before_the_first_processed_command() -> void:
	var node := NetworkManager._add_owner_state(PEER)
	node.write(-1, Vector3.ZERO, Vector3.ZERO, false, false, false, false, 2)
	NetworkManager._on_owner_state_synced(node)
	assert_eq(_handler.got, [], "seq -1 has nothing to reconcile against")
	assert_eq(NetworkManager.net_input_queue_depth, 2, "but the queue depth still lands")


func test_a_reconnect_gets_the_same_path() -> void:
	var first := NetworkManager._add_owner_state(PEER)
	var path := first.get_path()
	NetworkManager._erase_peer_state(PEER)
	assert_false(first.is_inside_tree(), "out of the tree at once, not at queue_free")
	var second := NetworkManager._add_owner_state(PEER)
	assert_eq(second.get_path(), path, "the path is the replication identity")


func test_publish_writes_only_a_known_peer() -> void:
	var node := NetworkManager._add_owner_state(PEER)
	NetworkManager.publish_owner_state(PEER + 1, 9, Vector3.ONE, Vector3.ONE, true, true, true, true, 1)
	assert_eq(node.seq, -1, "another peer's state isn't written here")
	NetworkManager.publish_owner_state(PEER, 9, Vector3.ONE, Vector3.ONE, true, true, true, true, 1)
	assert_eq(node.seq, 9)
