extends "res://src/tests/test_base.gd"
## VisibilitySystem.is_entity_visible_to_peer routing logic (stubbing out _vm). Key case:
## test_uses_aabb_not_point catches the beanstalk bug — a tall entity whose origin sits in a
## PVS-visible leaf but whose mesh occupies only non-visible leaves; a point query would send it,
## the AABB query correctly culls it.

const VS := preload("res://src/systems/visibility_system.gd")


## Fake VisibilityManager — records which query path was taken.
class StubVM:
	var last_call := ""   # "entity" or "point" or ""
	var entity_result := true
	var position_result := true

	func get_observer_leaf(_h: int) -> int: return 0
	func is_entity_visible_to_observer(_entity_h: int, _obs: int) -> bool:
		last_call = "entity"
		return entity_result
	func is_position_visible_to_observer(_pos: Vector3, _obs: int) -> bool:
		last_call = "point"
		return position_result


func _make_vs() -> Variant:
	return VS.new()


func _entry(handle: int) -> VS.EntityEntry:
	var entry := VS.EntityEntry.new()
	entry.handle = handle
	entry.local_aabb_computed = true
	return entry


## When no BSP is loaded (_vm == null) every entity must be sent.
func test_no_vm_always_sends() -> void:
	var vs = _make_vs()
	vs._vm = null
	vs._peer_observers[1] = 0
	vs._entities[42] = _entry(5)
	assert_true(vs.is_entity_visible_to_peer(42, 1), "no vm → always send")


## Peer with no registered observer (e.g. not yet positioned) → always send.
func test_no_peer_observer_always_sends() -> void:
	var vs = _make_vs()
	vs._vm = StubVM.new()
	vs._entities[42] = _entry(5)
	assert_true(vs.is_entity_visible_to_peer(42, 99), "unknown peer → always send")


## Entity not registered in _entities (e.g. spawned before BSP loaded) → always send.
func test_untracked_entity_always_sends() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	vs._vm = stub
	vs._peer_observers[1] = 0
	assert_true(vs.is_entity_visible_to_peer(42, 1), "untracked entity → always send")
	assert_eq(stub.last_call, "", "must not query vm for untracked entity")


## handle == -1 means VisibilityManager rejected the AABB registration → always send.
func test_handle_minus_one_always_sends() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._entities[42] = _entry(-1)
	assert_true(vs.is_entity_visible_to_peer(42, 1), "handle -1 → always send")
	assert_eq(stub.last_call, "", "must not query vm for handle -1")


## Core regression test for the beanstalk bug: AABB says not visible, point would say visible.
func test_uses_aabb_not_point() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = false   # AABB: culled
	stub.position_result = true  # point: would send (old wrong behaviour)
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._entities[42] = _entry(7)
	var result: bool = vs.is_entity_visible_to_peer(42, 1)
	assert_eq(stub.last_call, "entity", "must call is_entity_visible_to_observer (AABB)")
	assert_false(result, "must return AABB result (culled), not point result")


func test_respects_vm_visible_result() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = true
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._entities[42] = _entry(7)
	assert_true(vs.is_entity_visible_to_peer(42, 1), "AABB visible → send")


func test_respects_vm_culled_result() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = false
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._entities[42] = _entry(7)
	assert_false(vs.is_entity_visible_to_peer(42, 1), "AABB culled → don't send")


# Players use a separate registry (_player_entries) so the client cull pass never touches
# them, but the host's send filter shares the same fail-open contract.

func test_player_no_vm_always_sends() -> void:
	var vs = _make_vs()
	vs._vm = null
	vs._peer_observers[1] = 0
	vs._player_entries[2] = _entry(5)
	assert_true(vs.is_player_visible_to_peer(2, 1), "no vm → always send player")


## A peer always receives its own player state, even if PVS would cull it.
func test_player_self_always_sends() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = false  # would cull if queried
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._player_entries[1] = _entry(7)
	assert_true(vs.is_player_visible_to_peer(1, 1), "self → always send")
	assert_eq(stub.last_call, "", "self must short-circuit before querying vm")


## Observer with no registered position yet → send.
func test_player_unknown_observer_always_sends() -> void:
	var vs = _make_vs()
	vs._vm = StubVM.new()
	vs._player_entries[2] = _entry(5)
	assert_true(vs.is_player_visible_to_peer(2, 99), "unknown observer → always send player")


## Target player not registered (e.g. joined before BSP loaded) → send.
func test_player_untracked_always_sends() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	vs._vm = stub
	vs._peer_observers[1] = 0
	assert_true(vs.is_player_visible_to_peer(2, 1), "untracked player → always send")
	assert_eq(stub.last_call, "", "must not query vm for untracked player")


func test_player_respects_vm_visible_result() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = true
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._player_entries[2] = _entry(7)
	assert_true(vs.is_player_visible_to_peer(2, 1), "AABB visible → send player")
	assert_eq(stub.last_call, "entity", "must use AABB query")


func test_player_respects_vm_culled_result() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = false
	vs._vm = stub
	vs._peer_observers[1] = 0
	vs._player_entries[2] = _entry(7)
	assert_false(vs.is_player_visible_to_peer(2, 1), "AABB culled → don't send player")


## Host has no local view yet (dedicated / pre-spawn) → never cull locally.
func test_player_local_no_local_pos_always_visible() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = false  # would cull if queried
	vs._vm = stub
	vs._local_position_valid = false
	vs._player_entries[2] = _entry(7)
	assert_true(vs.is_player_locally_visible(2), "no local view → fail open (visible)")
	assert_eq(stub.last_call, "", "must not query vm without a local view")


## Local AABB visible → host renders the puppet.
func test_player_local_respects_vm_visible_result() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = true
	vs._vm = stub
	vs._local_position_valid = true
	vs._player_entries[2] = _entry(7)
	assert_true(vs.is_player_locally_visible(2), "local AABB visible → render")
	assert_eq(stub.last_call, "entity", "must use AABB query against local observer")


## Local AABB culled → host hides the puppet.
func test_player_local_respects_vm_culled_result() -> void:
	var vs = _make_vs()
	var stub := StubVM.new()
	stub.entity_result = false
	vs._vm = stub
	vs._local_position_valid = true
	vs._player_entries[2] = _entry(7)
	assert_false(vs.is_player_locally_visible(2), "local AABB culled → hide")
