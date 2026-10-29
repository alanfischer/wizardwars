extends "res://src/tests/test_base.gd"
## The [input] section of settings.cfg: both preferences survive a round trip, and a sensitivity
## that would leave the game unplayable is refused rather than stored.
##
## These write the real settings.cfg — there is one path and it is a const — so whatever the section
## held is read first and put back at the end.

const InputSettings = preload("res://src/systems/input_settings.gd")

var _saved_invert: bool
var _saved_sensitivity: float


func _run_tests() -> void:
	_saved_invert = InputSettings.load_invert_mouse()
	_saved_sensitivity = InputSettings.load_sensitivity()
	await super()
	InputSettings.save_invert_mouse(_saved_invert)
	InputSettings.save_sensitivity(_saved_sensitivity)


func test_invert_round_trips() -> void:
	InputSettings.save_invert_mouse(true)
	assert_true(InputSettings.load_invert_mouse(), "invert did not survive a save")
	InputSettings.save_invert_mouse(false)
	assert_false(InputSettings.load_invert_mouse(), "invert did not come back off again")


func test_sensitivity_round_trips() -> void:
	InputSettings.save_sensitivity(1.75)
	assert_almost_eq(InputSettings.load_sensitivity(), 1.75, 0.001,
		"sensitivity did not survive a save")


## Both ends matter, and for the same reason: the only way back from a value that makes the mouse
## unusable is editing the file, which is exactly what someone who typed it there was avoiding.
func test_sensitivity_is_clamped_to_a_usable_range() -> void:
	InputSettings.save_sensitivity(0.0)
	assert_eq(InputSettings.load_sensitivity(), InputSettings.SENSITIVITY_MIN,
		"a zero sensitivity would freeze the view outright")
	InputSettings.save_sensitivity(500.0)
	assert_eq(InputSettings.load_sensitivity(), InputSettings.SENSITIVITY_MAX,
		"an enormous sensitivity would leave the game unplayable")
