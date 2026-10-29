extends "res://src/tests/test_base.gd"
## /bind, and specifically its splitting: a key name can be two words ("Wheel Up") and so can a
## control ("Team Chat"), so neither the first space nor the last one is reliably the seam.
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


func test_a_one_word_key_and_control() -> void:
	ClientCommandSystem.dispatch("/bind g satchel")
	assert_eq(KeyBindings.display_for("satchel"), "G", "/bind did not move the satchel key")
	KeyBindings.reset_all()


## The bug this file exists for: splitting at the last space read "Mouse 4 Team" as the key.
func test_both_halves_can_be_two_words() -> void:
	ClientCommandSystem.dispatch("/bind Mouse 4 Team Chat")
	assert_eq(KeyBindings.display_for("chat_team"), "Mouse 4",
		"a two-word key and a two-word control were split in the wrong place")
	ClientCommandSystem.dispatch("/bind kp 1 Strafe Left")
	assert_eq(KeyBindings.display_for("move_left"), "Kp 1",
		"a two-word key ahead of a two-word control did not land")
	KeyBindings.reset_all()


## The control can be named the way the menu shows it or the way the file stores it.
func test_a_control_answers_to_its_label_or_its_action() -> void:
	ClientCommandSystem.dispatch("/bind h Call For Help")
	assert_eq(KeyBindings.display_for("callhelp"), "H", "the menu label was not accepted")
	ClientCommandSystem.dispatch("/bind j callhelp")
	assert_eq(KeyBindings.display_for("callhelp"), "J", "the action name was not accepted")
	KeyBindings.reset_all()


## A command that cannot be read has to leave the bindings alone rather than half-apply.
func test_nonsense_changes_nothing() -> void:
	var before := KeyBindings.display_for("jump")
	for line in ["/bind zzz jump", "/bind q nosuchcontrol", "/bind j", "/bind escape jump"]:
		ClientCommandSystem.dispatch(line)
		assert_eq(KeyBindings.display_for("jump"), before, "'%s' should have been refused" % line)


func test_unbind_takes_the_key_away() -> void:
	ClientCommandSystem.dispatch("/unbind Team Chat")
	assert_eq(KeyBindings.display_for("chat_team"), KeyBindings.UNBOUND,
		"/unbind left the control on its key")
	ClientCommandSystem.dispatch("/resetbinds")
	assert_eq(KeyBindings.display_for("chat_team"), "U", "/resetbinds did not put it back")
