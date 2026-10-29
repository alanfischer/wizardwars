extends "res://src/tests/test_base.gd"
## The lobby's Controls panel, which is where mouse feel and every key binding now live. It is
## built entirely in code and torn down with the modal, so the things worth pinning are that it
## builds at all, that the mouse settings reach settings.cfg, and that closing it leaves nothing
## behind — an armed capture that outlived the panel would swallow the first key of the match.
##
## Scene-run only (LobbyUI reaches for the XRManager and NetworkManager autoloads).

const InputSettings = preload("res://src/systems/input_settings.gd")
const KeyBindings = preload("res://src/systems/key_bindings.gd")
const LobbyUIScript = preload("res://src/systems/lobby_ui.gd")

var _saved_sensitivity: float
var _saved_invert: bool


func _run_tests() -> void:
	_saved_sensitivity = InputSettings.load_sensitivity()
	_saved_invert = InputSettings.load_invert_mouse()
	await super()
	InputSettings.save_sensitivity(_saved_sensitivity)
	InputSettings.save_invert_mouse(_saved_invert)
	KeyBindings.reset_all()


## A lobby with its Controls panel already open.
func _open_lobby() -> CanvasLayer:
	var lobby: CanvasLayer = _keep(LobbyUIScript.new())
	_root().add_child(lobby)
	lobby._show_controls_popup()
	return lobby


func test_the_panel_offers_the_mouse_and_every_key() -> void:
	var lobby := _open_lobby()
	assert_true(lobby._sensitivity_slider != null, "the panel has no sensitivity slider")
	assert_true(lobby._invert_check != null, "the panel has no invert tick")
	assert_eq(lobby._bind_buttons.size(), KeyBindings.actions().size(),
		"the panel is missing a row for some bindable control")
	for action in KeyBindings.actions():
		assert_eq(lobby._bind_buttons[action].text, KeyBindings.display_for(action),
			"the row for '%s' does not show its key" % action)


func test_the_mouse_settings_write_through() -> void:
	var lobby := _open_lobby()
	lobby._sensitivity_slider.value = 2.5
	assert_almost_eq(InputSettings.load_sensitivity(), 2.5, 0.001,
		"moving the slider did not save the sensitivity")
	assert_eq(lobby._sensitivity_value.text, "2.50x", "the readout did not follow the slider")
	lobby._invert_check.button_pressed = true
	assert_true(InputSettings.load_invert_mouse(), "ticking invert did not save it")


## The panel is where a capture is armed, but the flag lives on the lobby and _input() runs whether
## or not a CanvasLayer is visible — so closing has to disarm as well as free.
func test_closing_disarms_a_capture_in_progress() -> void:
	var lobby := _open_lobby()
	lobby._begin_capture("jump")
	assert_eq(lobby._capture_action, "jump", "clicking a row did not arm a capture")
	assert_eq(lobby._bind_buttons["jump"].text, "Press a key...", "the row does not say it is waiting")
	lobby.hide_menu()
	assert_eq(lobby._capture_action, "", "the capture outlived the panel")
	assert_false(is_instance_valid(lobby._controls_overlay), "the panel was not freed")
	assert_true(lobby._sensitivity_slider == null, "the panel's controls were left dangling")


func test_a_captured_key_lands_on_the_control() -> void:
	var lobby := _open_lobby()
	lobby._begin_capture("jump")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_KP_5
	event.pressed = true
	lobby._finish_capture(event)
	assert_eq(KeyBindings.display_for("jump"), "Kp 5", "the captured key did not land")
	assert_eq(lobby._bind_buttons["jump"].text, "Kp 5", "the row still shows the old key")
	assert_eq(lobby._capture_action, "", "the capture stayed armed after a key arrived")


## Escape is how you get out of a capture, so it must cancel rather than bind.
func test_escape_cancels_a_capture() -> void:
	var lobby := _open_lobby()
	var before: String = lobby._bind_buttons["jump"].text
	lobby._begin_capture("jump")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	lobby._finish_capture(event)
	assert_eq(lobby._bind_buttons["jump"].text, before, "Escape changed the binding")
	assert_eq(lobby._capture_action, "", "Escape left the capture armed")
