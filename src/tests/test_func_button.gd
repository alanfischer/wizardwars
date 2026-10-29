extends "res://src/tests/test_base.gd"
## func_button spawnflags (GoldSrc CBaseButton) are NOT the door's: bit 1 is SF_BUTTON_DONTMOVE
## (reading it as the door's START_OPEN slid plaques a full brush-width sideways), bit 256 is
## TOUCH_ONLY, the inverse of the door's USE_ONLY. Its lip default is not the door's either —
## CBaseButton::Spawn sets it to 4, so a button never quite buries itself.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

var _fired: Array[String] = []


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## _fired collects the targets each mover triggered; it has to start empty per test.
func _setup_test(_test_name: String) -> void:
	_fired.clear()


## A button whose brush spans (0,0,0)..(2,2,2). Mirrors the map path: the script
## goes onto the BSP's AnimatableBody3D (main.gd set_script), not a fresh node.
func _button(keys := {}) -> FuncButton:
	# Untyped on purpose: an AnimatableBody3D only becomes a FuncButton once the
	# script is attached, which the static analyser can't see.
	var body = AnimatableBody3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([
		Vector3.ZERO, Vector3(2, 2, 2), Vector3(2, 0, 0),
		Vector3.ZERO, Vector3(0, 2, 2), Vector3(0, 0, 2),
	]))
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var e := {"classname": "func_button", "angles": "0 0 0"}
	e.merge(keys, true)  # overwrite: some tests override a default key
	body.set_meta("entity", e)
	body.set_script(FuncButton)
	_root().add_child(body)
	_spawned.append(body)
	return body


func _target_probe(probe_name: String) -> void:
	_target_probe_into(_fired, probe_name)


func test_dontmove_button_fires_where_it_stands() -> void:
	_target_probe("biglightmm")
	var b: FuncButton = _button({"spawnflags": "1", "target": "biglightmm", "speed": "5"})
	var home := b.position
	b.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(_fired, ["biglightmm"], "SF_BUTTON_DONTMOVE still fires its target")
	assert_vec3_almost_eq(b.position, home, 0.0001, "and the brush does not travel")


## The test brush is 2 Godot units (80 GoldSrc units) along every axis, so the
## 4-unit lip is a visible 0.1 of it.
func test_plain_button_travels_its_own_width_less_the_lip() -> void:
	var b: FuncButton = _button({"speed": "5"})
	assert_almost_eq(b.position2.length(), 2.0 - 4.0 * GameConsts.SCALE_FACTOR, 0.001,
		"without the flag the button slides the brush extent along movedir, minus the lip")


func test_lip_key_overrides_the_default() -> void:
	var b: FuncButton = _button({"speed": "5", "lip": "24"})
	assert_almost_eq(b.position2.length(), 2.0 - 24.0 * GameConsts.SCALE_FACTOR, 0.001,
		"an explicit lip key wins over the 4-unit default")


func test_button_is_use_only_by_default() -> void:
	var b: FuncButton = _button({"spawnflags": "1"})
	assert_eq(b.get_node_or_null("TouchArea"), null,
		"a button without SF_BUTTON_TOUCH_ONLY is +use/damage only — walking into it does nothing")


func test_touch_only_flag_makes_it_touchable() -> void:
	var b: FuncButton = _button({"spawnflags": "256"})
	assert_ne(b.get_node_or_null("TouchArea"), null, "SF_BUTTON_TOUCH_ONLY adds the touch area")


func test_health_key_lets_a_shot_press_it() -> void:
	_target_probe("biglightmm")
	var b: FuncButton = _button({"spawnflags": "1", "health": "1", "target": "biglightmm"})
	b.take_damage(10.0, GameConsts.DamageType.PHYSICAL, null)
	await (Engine.get_main_loop() as SceneTree).process_frame  # deferred activate lands
	assert_eq(_fired, ["biglightmm"], "any damage presses a button with a health key")


func test_button_without_health_ignores_damage() -> void:
	_target_probe("biglightmm")
	var b: FuncButton = _button({"spawnflags": "1", "target": "biglightmm"})
	b.take_damage(10.0, GameConsts.DamageType.PHYSICAL, null)
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_eq(_fired, [], "no health key → shooting it does nothing")
