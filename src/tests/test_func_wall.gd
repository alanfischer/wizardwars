extends "res://src/tests/test_base.gd"
## CFuncWall::Use flips pev->frame (subject to ShouldToggle), which draws the wall's +a..+j
## alternate textures.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


func _wall() -> FuncWall:
	var body = AnimatableBody3D.new()
	body.set_meta("entity", {"classname": "func_wall", "targetname": "wall"})
	body.add_child(MeshInstance3D.new())
	body.set_script(FuncWall)
	_root().add_child(body)
	_spawned.append(body)
	return body


func _frame(w: FuncWall) -> Variant:
	return (w.get_child(0) as MeshInstance3D).get_instance_shader_parameter(&"entity_frame")


func test_use_toggles_the_alternate_textures() -> void:
	var w := _wall()
	TriggerSystem.fire("wall")
	assert_eq(_frame(w), 1.0, "a toggle switches to the alternates")
	TriggerSystem.fire("wall")
	assert_eq(_frame(w), 0.0, "and back")


func test_on_and_off_only_move_one_way() -> void:
	var w := _wall()
	TriggerSystem.fire("wall", null, TriggerSystem.Type.OFF)
	assert_eq(w._texture_frame, 0, "OFF on a wall already at frame 0 does nothing")
	TriggerSystem.fire("wall", null, TriggerSystem.Type.ON)
	TriggerSystem.fire("wall", null, TriggerSystem.Type.ON)
	assert_eq(w._texture_frame, 1, "ON twice still leaves frame 1")
	assert_eq(w._get_sync_state().get("frame"), 1, "and the frame goes to clients")
