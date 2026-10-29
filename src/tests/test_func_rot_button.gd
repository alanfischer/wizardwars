extends "res://src/tests/test_base.gd"
## func_rot_button (GoldSrc CRotButton) carries the button spawnflags (1 = NOTSOLID,
## 256 = TOUCH_ONLY) alongside the door's rotate-axis bits (64 = Z, 128 = X).
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

var _fired: Array[String] = []


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## _fired collects the targets each mover triggered; it has to start empty per test.
func _setup_test(_test_name: String) -> void:
	_fired.clear()


## Mirrors the map path: the script goes onto the BSP's AnimatableBody3D
## (main.gd set_script), not a fresh node.
func _rot_button(keys := {}) -> FuncRotButton:
	# Untyped on purpose: an AnimatableBody3D only becomes a FuncRotButton once
	# the script is attached, which the static analyser can't see.
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([
		Vector3.ZERO, Vector3(2, 2, 2), Vector3(2, 0, 0),
		Vector3.ZERO, Vector3(0, 2, 2), Vector3(0, 0, 2),
	]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {"classname": "func_rot_button", "angles": "0 0 0"}
	e.merge(keys, true)
	body.set_meta("entity", e)
	body.set_script(FuncRotButton)
	_root().add_child(body)
	_spawned.append(body)
	return body


func _await_state(b: FuncRotButton, want: int, max_frames := 120) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for _i in max_frames:
		if b.state == want:
			return
		await tree.physics_frame


func _target_probe(probe_name: String) -> void:
	_target_probe_into(_fired, probe_name)


func test_spins_around_the_flagged_axis() -> void:
	var b: FuncRotButton = _rot_button({"spawnflags": "64", "distance": "360"})
	assert_almost_eq(rad_to_deg(b.angle2.length()), 360.0, 0.001,
		"distance is the full sweep in degrees")
	assert_vec3_almost_eq(b.angle2.normalized(), Vector3(-1, 0, 0), 0.0001,
		"bit 64 is the door's rotate-Z, which is Godot's -X")


func test_defaults_to_a_ninety_degree_yaw_sweep() -> void:
	var b: FuncRotButton = _rot_button({})
	assert_vec3_almost_eq(b.angle2, Vector3(0, deg_to_rad(90.0), 0), 0.0001,
		"no rotate bit and no distance key = 90 degrees around Y")


func test_fires_target_at_the_top_then_returns() -> void:
	_target_probe("bridge1")
	var b: FuncRotButton = _rot_button({
		"spawnflags": "64", "distance": "90", "speed": "900",
		"wait": "0", "target": "bridge1",
	})
	b.trigger(null, TriggerSystem.Type.TOGGLE)
	await _await_state(b, FuncRotButton.State.AT_TOP)
	assert_eq(_fired, ["bridge1"], "reaching the top fires the target")
	# No SF_NO_AUTO_RETURN on the button — it always comes back on its own.
	await _await_state(b, FuncRotButton.State.AT_BOTTOM)
	assert_eq(b.state, FuncRotButton.State.AT_BOTTOM, "and it auto-returns after wait")
	assert_vec3_almost_eq(b.rotation, Vector3.ZERO, 0.0001, "back to the unpressed angle")


func test_is_use_only_by_default() -> void:
	var b: FuncRotButton = _rot_button({"spawnflags": "64"})
	assert_eq(b.get_node_or_null("TouchArea"), null,
		"without SF_BUTTON_TOUCH_ONLY the button is +use/damage only")


func test_touch_only_flag_makes_it_touchable() -> void:
	var b: FuncRotButton = _rot_button({"spawnflags": "256"})
	assert_ne(b.get_node_or_null("TouchArea"), null, "SF_BUTTON_TOUCH_ONLY adds the touch area")


func test_notsolid_flag_clears_collision() -> void:
	var solid: FuncRotButton = _rot_button({"spawnflags": "64"})
	assert_ne(solid.collision_layer, 0, "a rot button is SOLID_BSP by default")
	var ghost: FuncRotButton = _rot_button({"spawnflags": "1"})
	assert_eq(ghost.collision_layer, 0, "SF_ROTBUTTON_NOTSOLID makes it walk-through")


func test_health_key_lets_a_shot_press_it() -> void:
	_target_probe("gitter3")
	var b: FuncRotButton = _rot_button({"health": "1", "target": "gitter3", "speed": "900"})
	b.take_damage(10.0, GameConsts.DamageType.PHYSICAL, null)
	await (Engine.get_main_loop() as SceneTree).process_frame  # deferred activate lands
	await _await_state(b, FuncRotButton.State.AT_TOP)
	assert_eq(_fired, ["gitter3"], "any damage presses a button with a health key")


func test_without_health_it_ignores_damage() -> void:
	_target_probe("gitter3")
	var b: FuncRotButton = _rot_button({"target": "gitter3"})
	b.take_damage(10.0, GameConsts.DamageType.PHYSICAL, null)
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_eq(_fired, [], "no health key → shooting it does nothing")
