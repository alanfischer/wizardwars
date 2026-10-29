extends "res://src/tests/test_base.gd"
## The controls card names keys, so it has to be reading the live bindings rather than the ones
## the game shipped with — the player who has just rebound everything is the one reading it.

const IntroGuide = preload("res://src/systems/intro_guide.gd")
const KeyBindings = preload("res://src/systems/key_bindings.gd")


func _run_tests() -> void:
	await super()
	KeyBindings.reset_all()


func test_every_placeholder_is_filled() -> void:
	var text := IntroGuide.body(false)
	assert_false(text.contains("{"), "the card went out with an unfilled placeholder:\n%s" % text)
	assert_true(text.contains("W A S D"), "the default move keys are not in the card")


func test_the_card_follows_a_rebind() -> void:
	KeyBindings.set_binding("satchel", KeyBindings.name_to_event("G"))
	var text := IntroGuide.body(false)
	assert_true(text.contains("Hold G to light the fuse"),
		"the card still names the old satchel key")
	KeyBindings.reset("satchel")
	assert_true(IntroGuide.body(false).contains("Hold F to light the fuse"),
		"the card did not follow the reset back")
