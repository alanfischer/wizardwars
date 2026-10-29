extends "res://src/tests/test_base.gd"
## State routinely arrives before its entity (unordered create/RPC streams) and
## one-shot states never repeat, so it's parked and applied when the id registers.


## Stand-in for a state-sync entity (Dragon, thornplant, …).
class FakeEntity:
	extends Node
	var applied: Array[Dictionary] = []
	func _apply_sync_state(state: Dictionary) -> void:
		applied.append(state)


func _idle() -> void:
	await (Engine.get_main_loop() as SceneTree).process_frame


func _register(id: int, node: Node) -> void:
	_root().add_child(node)
	NetworkManager.register_dyn_state_entity(id, node)


func _cleanup(id: int, node: Node) -> void:
	NetworkManager.unregister_dyn_state_entity(id)
	node.queue_free()


func test_state_before_entity_is_applied_on_register() -> void:
	# Arrives first, names an id nobody has yet.
	NetworkManager._apply_entity_state_local(7001, {"is_ridden": true})
	var ent := FakeEntity.new()
	_register(7001, ent)
	await _idle()
	assert_eq(ent.applied.size(), 1, "parked state applied once the entity registers")
	assert_eq(ent.applied[0].get("is_ridden"), true, "the ridden flag survived the wait")
	_cleanup(7001, ent)


func test_newer_value_supersedes_parked_one() -> void:
	NetworkManager._apply_entity_state_local(7002, {"is_ridden": true, "anim": "fly"})
	NetworkManager._apply_entity_state_local(7002, {"is_ridden": false})
	var ent := FakeEntity.new()
	_register(7002, ent)
	await _idle()
	assert_eq(ent.applied.size(), 1, "parked states merge into one apply")
	assert_eq(ent.applied[0].get("is_ridden"), false, "newer value wins")
	assert_eq(ent.applied[0].get("anim"), "fly", "keys only the older state carried are kept")
	_cleanup(7002, ent)


func test_state_for_live_entity_applies_immediately() -> void:
	var ent := FakeEntity.new()
	_register(7003, ent)
	NetworkManager._apply_entity_state_local(7003, {"is_ridden": true})
	assert_eq(ent.applied.size(), 1, "a registered entity still applies inline, no deferral")
	_cleanup(7003, ent)


func test_reset_entities_drops_parked_state() -> void:
	# Map change: parked state for ids that never showed up must not leak into the next map.
	NetworkManager._apply_entity_state_local(7004, {"is_ridden": true})
	NetworkManager.reset_entities()
	assert_false(NetworkManager._pending_entity_state.has(7004), "map reset clears parked state")


func test_parked_state_is_bounded() -> void:
	# State is broadcast unfiltered, so entities that never enter this client's PVS
	# park entries nothing will ever drain — they must not accumulate all map.
	NetworkManager.reset_entities()
	var cap: int = NetworkManager.MAX_PENDING_ENTITY_STATE
	for i in cap * 2:
		NetworkManager._apply_entity_state_local(8000 + i, {"anim": "idle"})
	assert_eq(NetworkManager._pending_entity_state.size(), cap, "parked state stays at the cap")
	assert_true(NetworkManager._pending_entity_state.has(8000 + cap * 2 - 1), "newest is kept")
	assert_false(NetworkManager._pending_entity_state.has(8000), "oldest is evicted")
	NetworkManager.reset_entities()
