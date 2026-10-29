extends "res://src/tests/test_base.gd"
## The change-epoch contract that NetworkManager.push_pvs_visibility skips work on: the send
## filter re-evaluates a (sync, peer) pair only when that row/column epoch has moved, so an epoch
## that fails to move on a real change is a stuck-visibility bug. Pins both directions: epoch
## MOVES when an input changes, HOLDS STILL when nothing does.

const VS := preload("res://src/systems/visibility_system.gd")


## Fake VisibilityManager. The leaf it reports is settable, so a test can move an observer
## across a leaf boundary without a real BSP.
class StubVM:
	var leaf := 7
	var next_handle := 0
	var aabb_updates := 0

	func get_observer_leaf(_h: int) -> int: return leaf
	func add_observer(_id: int, _pos: Vector3) -> int:
		next_handle += 1
		return next_handle
	func update_observer_position(_h: int, _pos: Vector3) -> void: pass
	func register_entity(_aabb: AABB) -> int:
		next_handle += 1
		return next_handle
	func update_entity_aabb(_h: int, _aabb: AABB) -> void: aabb_updates += 1
	func unregister_entity(_h: int) -> void: pass
	func is_entity_visible_to_observer(_h: int, _obs: int) -> bool: return true


func _make_vs() -> Variant:
	var vs = VS.new()
	vs._vm = StubVM.new()
	return vs


## The column skip depends on this: a peer standing still (or walking within one leaf) must not
## churn its epoch, or every push re-sweeps every entity for it and nothing is saved.
func test_peer_epoch_holds_while_leaf_unchanged() -> void:
	var vs = _make_vs()
	vs.set_peer_position(5, Vector3.ZERO)
	var first: int = vs.peer_epoch(5)
	vs.set_peer_position(5, Vector3(0.3, 0, 0.3))
	vs.set_peer_position(5, Vector3(0.6, 0, 0.6))
	assert_eq(vs.peer_epoch(5), first, "peer epoch churned without a leaf change")
	vs.free()


func test_peer_epoch_moves_on_leaf_change() -> void:
	var vs = _make_vs()
	vs.set_peer_position(5, Vector3.ZERO)
	var before: int = vs.peer_epoch(5)
	vs._vm.leaf = 99  # observer crossed into another leaf
	vs.set_peer_position(5, Vector3(50, 0, 50))
	assert_true(vs.peer_epoch(5) != before, "peer epoch did not move when the observer changed leaf")
	vs.free()


## The row skip depends on this: an entity whose registered leaf set moved must advertise it, or
## it stays gated on where it used to be.
func test_entity_epoch_moves_when_entity_moves() -> void:
	var vs = _make_vs()
	var node := Node3D.new()
	_root().add_child(node)
	vs.track_node(42, node)
	vs._physics_process(0.016)  # settle the lazy AABB / handle registration
	var before: int = vs.entity_epoch(42)
	node.global_position = Vector3(25, 0, 25)
	vs._physics_process(0.016)
	assert_true(vs.entity_epoch(42) != before, "entity epoch did not move when the entity moved")
	node.queue_free()
	vs.free()


func test_entity_epoch_holds_while_entity_still() -> void:
	var vs = _make_vs()
	var node := Node3D.new()
	_root().add_child(node)
	vs.track_node(43, node)
	for i in 4:
		vs._physics_process(0.016)  # let the AABB settle and the handle register
	var settled: int = vs.entity_epoch(43)
	for i in 3:
		vs._physics_process(0.016)
	assert_eq(vs.entity_epoch(43), settled, "entity epoch churned while the entity sat still")
	node.queue_free()
	vs.free()


## Untracking flips the answer to "always send", and the entry is dropped so ids can be recycled.
func test_untracked_entity_epoch_resets() -> void:
	var vs = _make_vs()
	var node := Node3D.new()
	_root().add_child(node)
	vs.track_node(44, node)
	vs._physics_process(0.016)
	assert_true(vs.entity_epoch(44) != 0, "tracking should have bumped the epoch off zero")
	vs.untrack_node(44)
	assert_eq(vs.entity_epoch(44), 0, "untracked entity kept an epoch entry")
	node.queue_free()
	vs.free()


## RemotePlayer._net_visible_to gates on is_dead and team as well as PVS, so its row epoch has to
## represent them. This is the case a signal-based invalidation would most easily miss: a player
## dies on one of several paths and their corpse keeps streaming to everyone.
func test_player_row_epoch_encodes_dead_and_team() -> void:
	var p = preload("res://src/remote_player.gd").new()
	p.peer_id = 11
	p.team = GameConsts.Team.BLUE
	p.is_dead = false
	var alive: int = p._net_pvs_epoch()

	p.is_dead = true
	assert_true(p._net_pvs_epoch() != alive, "row epoch did not move when the player died")

	p.is_dead = false
	assert_eq(p._net_pvs_epoch(), alive, "row epoch did not return to its live value")

	p.team = GameConsts.Team.NONE
	assert_true(p._net_pvs_epoch() != alive, "row epoch did not move when the player left their team")
	p.free()


## The reload window: a peer between maps has no scene to receive a spawn, and the send filter never
## re-offers one, because this pair's answer does not change again. Withholding until the peer says
## it has loaded is what turns the delivery into a false -> true flip the filter does act on.
## Regression: a puppet streamed into that window left one player permanently invisible to another
## for the rest of the map, while every bot — which re-announces on each respawn — showed up fine.
func test_player_row_withheld_until_peer_map_ready() -> void:
	var p = preload("res://src/remote_player.gd").new()
	p.peer_id = 11
	p.team = GameConsts.Team.BLUE
	p.is_dead = false
	NetworkManager._map_ready_peers.erase(12)
	assert_false(p._net_visible_to(12), "streamed to a peer that is still loading the map")
	NetworkManager._map_ready_peers[12] = true
	assert_true(p._net_visible_to(12), "still withheld after the peer reported its map ready")
	NetworkManager._map_ready_peers.erase(12)
	p.free()


## And the flip has to be visible to the column pass, or the row is re-evaluated only when the
## player happens to move leaf — which is the same stuck-visibility bug with extra steps.
func test_peer_epoch_moves_when_a_peer_reports_map_ready() -> void:
	NetworkManager._map_ready_peers.erase(12)
	var before: int = NetworkManager._peer_pvs_epoch(12)
	NetworkManager._map_ready_peers[12] = true
	assert_true(NetworkManager._peer_pvs_epoch(12) != before,
		"column epoch did not move when the peer finished loading the map")
	NetworkManager._map_ready_peers.erase(12)
