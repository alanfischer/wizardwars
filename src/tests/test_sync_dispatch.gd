extends "res://src/tests/test_base.gd"
## NetworkManager._dispatch_to_scene's routing. Every "the server told the client something" event
## arrives by NAME through that one function, so where it looks matters: the sync handlers live on
## the node the scene registered (main.gd's ClientSync child), while the join/spawn handlers are
## still main's own methods. Both have to keep working, including on a scene (a tool or probe
## harness) that registers no handler at all.


class SyncChild extends Node:
	var got: Array = []

	func _on_sync_probe(value: int) -> void:
		got.append(value)


class FakeScene extends Node:
	var got: Array = []

	## Stands in for a handler main still owns, dispatched by the same path.
	func _on_assign_spawn(pos: Vector3, yaw: float, team: int, element: int) -> void:
		got.append([pos, yaw, team, element])

	## A sync handler the scene also happens to answer for — the registered node must win.
	func _on_sync_probe(value: int) -> void:
		got.append(["scene", value])


var _saved_scene: Node
var _scene: FakeScene
var _child: SyncChild


func _setup_test(_test_name: String) -> void:
	_saved_scene = _tree().current_scene
	_scene = _keep(FakeScene.new())
	_child = SyncChild.new()
	_scene.add_child(_child)
	_root().add_child(_scene)
	_tree().current_scene = _scene
	NetworkManager.register_sync_handler(_child)


func _teardown_test() -> void:
	_tree().current_scene = _saved_scene
	super._teardown_test()  # frees _scene, whose child's tree_exiting unregisters it


func test_sync_handlers_go_to_the_registered_handler() -> void:
	NetworkManager._dispatch_to_scene(&"_on_sync_probe", [7])
	assert_eq(_child.got, [7], "the handler answered")
	assert_eq(_scene.got, [], "and the scene was not called as well")


func test_handlers_the_scene_still_owns_reach_the_scene() -> void:
	NetworkManager._dispatch_to_scene(&"_on_assign_spawn", [Vector3.ONE, 1.5, 2, 3])
	assert_eq(_child.got, [], "not the handler's method")
	assert_eq(_scene.got.size(), 1, "the scene answered")
	assert_eq(_scene.got[0][2], 2, "with its arguments intact")


func test_a_scene_that_registers_nothing_still_gets_sync_events() -> void:
	# Tools and probe harnesses stand up their own scene; no handler must fall back rather than
	# swallow the event.
	NetworkManager.unregister_sync_handler(_child)
	NetworkManager._dispatch_to_scene(&"_on_sync_probe", [9])
	assert_eq(_child.got, [], "nothing is registered")
	assert_eq(_scene.got, [["scene", 9]], "so the scene handled it")


func test_a_handler_leaving_the_tree_stops_receiving() -> void:
	_child.get_parent().remove_child(_child)
	NetworkManager._dispatch_to_scene(&"_on_sync_probe", [3])
	assert_eq(_child.got, [], "the departed handler is forgotten")
	assert_eq(_scene.got, [["scene", 3]], "and the scene takes over")
	_child.free()


func test_an_unknown_method_is_dropped_quietly() -> void:
	NetworkManager._dispatch_to_scene(&"_on_sync_nothing_implements_this", [1, 2])
	assert_eq(_child.got, [], "nothing on the handler")
	assert_eq(_scene.got, [], "nothing on the scene")
