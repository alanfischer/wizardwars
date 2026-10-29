extends "res://src/tests/test_base.gd"
## The [binds] section of settings.cfg: a rebound control reaches the InputMap, a default one is
## not written down at all, and a key already spoken for changes hands rather than being refused.
##
## These write the real settings.cfg — there is one path and it is a const — so whatever the
## section held is read first and put back at the end.

const KeyBindings = preload("res://src/systems/key_bindings.gd")

var _saved: Dictionary = {}


func _run_tests() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(KeyBindings.SETTINGS_PATH) == OK and cfg.has_section(KeyBindings.SECTION):
		for key in cfg.get_section_keys(KeyBindings.SECTION):
			_saved[key] = cfg.get_value(KeyBindings.SECTION, key)
	await super()
	KeyBindings.reset_all()
	if not _saved.is_empty():
		var out := ConfigFile.new()
		out.load(KeyBindings.SETTINGS_PATH)
		for key in _saved:
			out.set_value(KeyBindings.SECTION, key, _saved[key])
		out.save(KeyBindings.SETTINGS_PATH)


## A typo in GROUPS would give the menu a row that binds nothing and silently does not work, and
## the action names are strings spread over four files.
func test_every_listed_control_is_a_real_action() -> void:
	var actions := KeyBindings.actions()
	assert_true(actions.size() > 20, "the bindable list looks truncated: %d entries" % actions.size())
	for action in actions:
		assert_true(InputMap.has_action(action),
			"'%s' is offered in the menu but is not an input action" % action)


func test_key_names_round_trip() -> void:
	for name in ["W", "Space", "Tab", "Slash", "1", "F1", "Kp 1"]:
		var event := KeyBindings.name_to_event(name)
		assert_true(event != null, "'%s' did not parse as a key" % name)
		assert_eq(KeyBindings.event_to_name(event), name,
			"'%s' did not survive the trip through an event" % name)


## The file is meant to be edited by hand, and "wheelup" is what a person types.
func test_mouse_names_round_trip_and_ignore_spacing() -> void:
	var event := KeyBindings.name_to_event("Wheel Up")
	assert_true(event is InputEventMouseButton, "'Wheel Up' did not parse as a mouse button")
	assert_eq(KeyBindings.event_to_name(event), "Wheel Up", "the wheel lost its name")
	for spelling in ["wheelup", "WHEEL UP", " Wheel  Up "]:
		var alt := KeyBindings.name_to_event(spelling)
		assert_true(alt != null and KeyBindings.event_to_name(alt) == "Wheel Up",
			"'%s' should name the same button" % spelling)


func test_unknown_names_parse_as_nothing() -> void:
	for name in ["", "   ", "Mouse 9", "not a key"]:
		assert_true(KeyBindings.name_to_event(name) == null, "'%s' should not parse" % name)


func test_rebinding_reaches_the_input_map() -> void:
	KeyBindings.set_binding("jump", KeyBindings.name_to_event("Kp 1"))
	assert_eq(KeyBindings.names_for("jump"), PackedStringArray(["Kp 1"]),
		"the new key is not what the action reports")
	var pressed := InputEventKey.new()
	pressed.physical_keycode = KEY_KP_1
	pressed.pressed = true
	assert_true(pressed.is_action_pressed("jump"), "the rebound key does not fire the action")
	var old := InputEventKey.new()
	old.physical_keycode = KEY_SPACE
	old.pressed = true
	assert_false(old.is_action_pressed("jump"), "the old key still fires the action")
	KeyBindings.reset("jump")
	assert_true(old.is_action_pressed("jump"), "reset did not put the default key back")


## Only overrides are stored, so a change to what the game ships with still reaches a player who
## never touched that control — and a player who sets a key back by hand stops overriding it.
func test_a_default_binding_is_not_written_down() -> void:
	KeyBindings.set_binding("jump", KeyBindings.name_to_event("Kp 1"))
	assert_true(KeyBindings.is_overridden("jump"), "a rebind should be stored")
	KeyBindings.set_binding("jump", KeyBindings.name_to_event("Space"))
	assert_false(KeyBindings.is_overridden("jump"),
		"binding a control back to its default should drop the override, not store it")


## An unbind has to be stored, or it would come back as the default on the next run.
func test_unbinding_survives_as_a_stored_value() -> void:
	KeyBindings.clear_binding("callhelp")
	assert_eq(KeyBindings.names_for("callhelp"), PackedStringArray(),
		"the control still has a key after being unbound")
	assert_true(KeyBindings.is_overridden("callhelp"), "the unbind was not written down")
	assert_eq(KeyBindings.display_for("callhelp"), KeyBindings.UNBOUND,
		"an unbound control should say so")
	KeyBindings.reset("callhelp")
	assert_eq(KeyBindings.names_for("callhelp"), PackedStringArray(["Z"]), "reset lost the default")


## A menu that can only refuse a taken key leaves no way to swap two controls around.
func test_a_taken_key_changes_hands() -> void:
	var stolen := KeyBindings.set_binding("callhelp", KeyBindings.name_to_event("Y"))
	assert_true(stolen.has("chat"), "taking Y off Chat was not reported: %s" % [stolen])
	assert_eq(KeyBindings.names_for("chat"), PackedStringArray(),
		"Chat kept a key it had just lost")
	assert_eq(KeyBindings.names_for("callhelp"), PackedStringArray(["Y"]), "the key did not land")
	KeyBindings.reset_all()
	assert_eq(KeyBindings.names_for("chat"), PackedStringArray(["Y"]), "reset did not undo the steal")


## Escape closes the menu, cancels a capture and frees the mouse. Bound to Jump it would leave the
## player no way back to the screen that did it.
func test_escape_cannot_be_bound() -> void:
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	assert_false(KeyBindings.is_bindable(escape), "Escape should not be bindable")
	var space := InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	assert_true(KeyBindings.is_bindable(space), "an ordinary key should be bindable")
	var motion := InputEventMouseMotion.new()
	assert_false(KeyBindings.is_bindable(motion), "mouse motion is not a key")
