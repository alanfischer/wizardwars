extends "res://src/tests/test_base.gd"
## A scripted mover's position is the PARITY of the toggles it is sent, so it must not lose
## one. ww_monoliths' cap-point covers (func_door indicatorN) get a toggle from each of two
## multi_managers in the same frame when a point is retaken the instant its lockout expires;
## CBaseDoor::Use would drop the second and leave the cover raised over a cappable point for
## the rest of the map.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## Untyped on purpose: an AnimatableBody3D only becomes a mover once the script is attached.
func _mover(script, keys := {}):
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([
		Vector3.ZERO, Vector3(2, 2, 2), Vector3(2, 0, 0),
		Vector3.ZERO, Vector3(0, 2, 2), Vector3(0, 0, 2),
	]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {"angles": "0 0 0", "speed": "500"}
	e.merge(keys, true)
	body.set_meta("entity", e)
	body.set_script(script)
	_root().add_child(body)
	_spawned.append(body)
	return body


## A ww_monoliths cap-point cover: spawnflags 33 = start open + no auto return, driven only
## by its targetname, so nothing can work it by hand.
func _cover(keys := {}):
	var e := {
		"classname": "func_door", "targetname": "indicator2",
		"spawnflags": "33", "wait": "-6", "lip": "-6",
	}
	e.merge(keys, true)
	return _mover(FuncDoor, e)


func test_two_toggles_in_one_frame_cancel() -> void:
	var d = _cover()
	assert_eq(d.state, FuncDoorBase.State.AT_BOTTOM, "the cover starts stowed")

	d.trigger(null, TriggerSystem.Type.TOGGLE)
	d.trigger(null, TriggerSystem.Type.TOGGLE)
	await _tick(60)
	assert_eq(d.state, FuncDoorBase.State.AT_BOTTOM,
		"the second toggle is held until the move settles, then undoes the first")


func test_a_toggle_mid_move_still_lands() -> void:
	var d = _cover()
	d.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(d.state, FuncDoorBase.State.GOING_UP, "moving")

	d.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_true(d._pending_flip, "a toggle arriving mid-move is remembered, not dropped")
	await _tick(60)
	assert_eq(d.state, FuncDoorBase.State.AT_BOTTOM, "and applied on settle")


func test_toggles_stay_balanced_over_many_cycles() -> void:
	var d = _cover()
	for _i in 6:
		d.trigger(null, TriggerSystem.Type.TOGGLE)
		d.trigger(null, TriggerSystem.Type.TOGGLE)
		await _tick(60)
	assert_eq(d.state, FuncDoorBase.State.AT_BOTTOM, "parity holds however often it happens")


func test_a_player_door_still_ignores_a_mid_move_toggle() -> void:
	# CBaseDoor::Use drops a use that lands mid-move, which is what keeps a player leaning on
	# a door from making it stutter. Only movers nothing can reach by hand get the queue.
	var d = _mover(FuncDoor, {
		"classname": "func_door", "spawnflags": "32", "wait": "-1", "lip": "0",
	})
	d.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(d.state, FuncDoorBase.State.GOING_UP, "moving")

	d.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_false(d._pending_flip, "a touch-activated door has no parity to keep")
	await _tick(60)
	assert_eq(d.state, FuncDoorBase.State.AT_TOP, "so the extra toggle is dropped, as in GoldSrc")
