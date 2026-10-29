extends "res://src/tests/test_base.gd"
## VisibilitySystem._physics_process visual culling (the AUTHORITY-side entity cull): a remote
## client does NOT run this local PVS query, only the authority does, where
## node.visible = pvs_vis AND game_visible. These tests run offline so is_authority() is true.

const VS := preload("res://src/systems/visibility_system.gd")


class StubVM:
	var entity_vis := true
	var leafset_vis := true
	var observer_leaf_result := 0  # -1 triggers the early-return guard

	func get_observer_leaf(_h: int) -> int: return observer_leaf_result
	func is_entity_visible_to_observer(_h: int, _obs: int) -> bool: return entity_vis
	func is_leaf_set_visible_to_observer(_h: int, _obs: int) -> bool: return leafset_vis
	func update_entity_aabb(_h: int, _aabb: AABB) -> void: pass


func _entry(node: Node3D, handle: int, game_vis: bool = true) -> VS.EntityEntry:
	var entry := VS.EntityEntry.new()
	entry.handle = handle
	entry.node = node
	entry.local_aabb = AABB()
	entry.local_aabb_computed = true
	entry.last_xform = Transform3D()
	entry.game_visible = game_vis
	return entry


func _leaf_entry(node: Node3D, handle: int) -> VS.LeafEntry:
	var entry := VS.LeafEntry.new()
	entry.handle = handle
	entry.node = node
	return entry


func _make_vs(stub: StubVM) -> Variant:
	var vs = VS.new()
	vs._vm = stub
	vs._local_observer = 0
	vs._local_position_valid = true
	return vs


func test_pvs_visible_shows_node() -> void:
	var stub := StubVM.new()
	stub.entity_vis = true
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = false
	vs._entities[1] = _entry(node, 7, true)
	vs._physics_process(0.0)
	assert_true(node.visible, "PVS visible + game_visible → node shown")
	node.free(); vs.free()


func test_pvs_culled_hides_node() -> void:
	var stub := StubVM.new()
	stub.entity_vis = false
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = true
	vs._entities[1] = _entry(node, 7, true)
	vs._physics_process(0.0)
	assert_false(node.visible, "PVS culled → node hidden")
	node.free(); vs.free()


func test_game_invisible_hides_even_when_pvs_visible() -> void:
	var stub := StubVM.new()
	stub.entity_vis = true
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = true
	vs._entities[1] = _entry(node, 7, false)  # game_visible = false
	vs._physics_process(0.0)
	assert_false(node.visible, "game_visible=false → hidden even when PVS says visible")
	node.free(); vs.free()


func test_pvs_visible_and_game_invisible_hides() -> void:
	var stub := StubVM.new()
	stub.entity_vis = false
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = true
	vs._entities[1] = _entry(node, 7, false)
	vs._physics_process(0.0)
	assert_false(node.visible, "PVS culled + game_invisible → hidden")
	node.free(); vs.free()


## handle == -1 means no AABB registration; pvs_vis defaults to true so the
## result is game_visible alone.
func test_handle_minus_one_defaults_to_game_visible() -> void:
	var stub := StubVM.new()
	stub.entity_vis = false  # would cull if queried
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = false
	vs._entities[1] = _entry(node, -1, true)
	vs._physics_process(0.0)
	assert_true(node.visible, "handle -1 → pvs_vis=true, node follows game_visible")
	node.free(); vs.free()


## When the local observer is in void (leaf == -1), _physics_process returns
## early and leaves node.visible unchanged.
func test_observer_in_void_skips_update() -> void:
	var stub := StubVM.new()
	stub.entity_vis = false
	stub.observer_leaf_result = -1
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = true
	vs._entities[1] = _entry(node, 7, true)
	vs._physics_process(0.0)
	assert_true(node.visible, "observer in void (leaf=-1) → early return, node unchanged")
	node.free(); vs.free()


func test_leaf_set_culled_hides_node() -> void:
	var stub := StubVM.new()
	stub.leafset_vis = false
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = true
	vs._leaf_sets[1] = _leaf_entry(node, 3)
	vs._physics_process(0.0)
	assert_false(node.visible, "leaf-set not visible → node hidden")
	node.free(); vs.free()


func test_leaf_set_visible_shows_node() -> void:
	var stub := StubVM.new()
	stub.leafset_vis = true
	var vs = _make_vs(stub)
	var node := Node3D.new()
	node.visible = false
	vs._leaf_sets[1] = _leaf_entry(node, 3)
	vs._physics_process(0.0)
	assert_true(node.visible, "leaf-set visible → node shown")
	node.free(); vs.free()
