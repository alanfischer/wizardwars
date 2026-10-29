extends "res://src/tests/test_base.gd"
## Escape over a match opens the options panel on top of the game, and Escape or Resume puts it
## away. What is worth pinning: Escape does nothing on the main menu, it opens and closes the
## panel, closing gives the mouse back in the state it was in, and the join rows are set aside.
##
## Scene-run only (LobbyUI reaches for the XRManager and ServerBrowser autoloads).

const LobbyUIScript = preload("res://src/systems/lobby_ui.gd")


func _run_tests() -> void:
	var saved_mouse := Input.mouse_mode
	await super()
	Input.mouse_mode = saved_mouse
	LobbyUI.pause_open = false


func _escape() -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	return event


## A lobby that has been handed a running match, the way main.gd hands it one.
func _in_match() -> CanvasLayer:
	var lobby: CanvasLayer = _keep(LobbyUIScript.new())
	_root().add_child(lobby)
	lobby.hide_menu()
	return lobby


func test_escape_does_nothing_on_the_main_menu() -> void:
	var lobby: CanvasLayer = _keep(LobbyUIScript.new())
	_root().add_child(lobby)
	lobby.show_menu()
	lobby._input(_escape())
	assert_false(LobbyUI.pause_open, "Escape opened the pause panel with no match running")


func test_escape_opens_the_panel_over_a_match() -> void:
	var lobby := _in_match()
	lobby._input(_escape())
	assert_true(LobbyUI.pause_open, "Escape did not open the pause panel")
	assert_true(lobby.visible, "the panel did not show")
	assert_true(lobby._pause_row.visible, "the Resume button did not show")
	assert_false(lobby._lobby_only[0].visible, "the join rows stayed up over a match")


## Compared against the mouse mode read before the panel opened, not a fixed one: headless does not
## honour a captured mouse, so a test that set one would be asserting the display server.
func test_escape_again_closes_it_and_gives_the_mouse_back() -> void:
	var lobby := _in_match()
	var before := Input.mouse_mode
	lobby._input(_escape())
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE, "the mouse was not freed with the panel up")
	lobby._input(_escape())
	assert_false(LobbyUI.pause_open, "Escape did not close the pause panel")
	assert_false(lobby.visible, "the panel stayed up after closing")
	assert_eq(Input.mouse_mode, before, "closing did not restore the mouse mode from before")


func test_resume_closes_the_panel_and_drops_the_controls_popup() -> void:
	var lobby := _in_match()
	lobby._input(_escape())
	lobby._show_controls_popup()
	lobby._close_pause()
	assert_false(LobbyUI.pause_open, "Resume left the panel open")
	assert_true(lobby._controls_overlay == null, "Resume left the controls popup behind")
