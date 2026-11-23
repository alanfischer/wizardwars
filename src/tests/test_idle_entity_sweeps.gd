extends "res://src/tests/test_base.gd"
## Per-tick work that only an entity doing something should cost: a mover's kinematic velocity is
## polled only while its transform changes, and a freed synced entity leaves the registry when it
## exits the tree rather than through a sweep of every entity each net tick.
##
## Scene-run only (needs the NetworkManager autoload): res://src/tests/run_tests.tscn.

const EntityBaseScript = preload("res://src/entities/entity_base.gd")


func _make_mover() -> Node3D:
	var b := AnimatableBody3D.new()
	b.sync_to_physics = false
	b.set_script(EntityBaseScript)
	_root().add_child(b)
	return b


func _polled(b: Node3D) -> bool:
	return _tree().physics_frame.is_connected(b._sync_kinematic_velocity)


func _velocity(b: Node3D) -> Vector3:
	return PhysicsServer3D.body_get_state((b as AnimatableBody3D).get_rid(),
			PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)


func test_still_mover_is_not_polled() -> void:
	var b := _make_mover()
	await _tick(2)
	assert_false(_polled(b), "a mover that never moved costs nothing per tick")
	b.queue_free()


## Moves its parent from _physics_process each tick, as a real mover does.
class Driver extends Node:
	var step := Vector3.ZERO

	func _physics_process(_delta: float) -> void:
		(get_parent() as Node3D).position += step


func test_moving_mover_publishes_velocity_then_sleeps() -> void:
	var b := _make_mover()
	var driver := Driver.new()
	b.add_child(driver)
	await _tick(1)
	driver.step = Vector3(0.05, 0.0, 0.0)
	await _tick(3)
	assert_true(_polled(b), "a moving mover is polled")
	assert_gt(_velocity(b).x, 0.0, "and publishes the velocity its motion implies")
	driver.step = Vector3.ZERO
	await _tick(3)
	assert_eq(_velocity(b), Vector3.ZERO, "a stop zeroes the published velocity")
	assert_false(_polled(b), "and the still mover goes back to sleep")
	driver.step = Vector3(0.05, 0.0, 0.0)
	await _tick(3)
	assert_gt(_velocity(b).x, 0.0, "the next move wakes it again")
	b.queue_free()


func test_freed_synced_entity_leaves_the_registry() -> void:
	var n := Node3D.new()
	_root().add_child(n)
	var id := NetworkManager.register_synced_entity(n)
	assert_true(NetworkManager._synced_entities.has(id), "precondition: registered")
	n.queue_free()
	await _tick(2)
	assert_false(NetworkManager._synced_entities.has(id), "a freed entity is dropped")


func test_reparented_synced_entity_stays() -> void:
	var a := Node3D.new()
	var b := Node3D.new()
	_root().add_child(a)
	_root().add_child(b)
	var n := Node3D.new()
	a.add_child(n)
	var id := NetworkManager.register_synced_entity(n)
	n.reparent(b)
	await _tick(2)
	assert_true(NetworkManager._synced_entities.has(id), "leaving the tree to move is not leaving the game")
	a.queue_free()
	b.queue_free()
	await _tick(2)
	assert_false(NetworkManager._synced_entities.has(id), "freed along with its new parent, it is dropped")
