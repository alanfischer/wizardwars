extends "res://src/tests/test_base.gd"
## GoalMessages.translate is the one door every map's goal text goes through. Tokens get their
## TOKENS entry, unknown tokens get a humanised fallback, and literal English (a goal's `message`
## key is often plain text) passes through — but the Flag→Grail rename applies to all three, so a
## literal "You have the flag!" never reaches the HUD still saying flag.

const GoalMessages = preload("res://src/entities/goal_messages.gd")


func test_literal_text_gets_the_grail_rename() -> void:
	assert_eq(GoalMessages.translate("You have the flag!"), "You have the grail!")
	assert_eq(GoalMessages.translate("You have the ENEMY flag!\\nTake it back to base!\\n"),
		"You have the ENEMY grail!\nTake it back to base!\n")


func test_literal_text_without_flag_is_untouched() -> void:
	assert_eq(GoalMessages.translate("Welcome to ww_hiddenforest"), "Welcome to ww_hiddenforest")


func test_known_token_returns_its_table_entry() -> void:
	assert_eq(GoalMessages.translate("#2fort_flag_carried"), "Your grail is being carried!")


func test_unknown_token_is_humanised_and_renamed() -> void:
	assert_eq(GoalMessages.translate("#ww_some_flag_thing"), "Grail Thing")


func test_game_text_style_token_is_translated_not_raw() -> void:
	assert_eq(GoalMessages.translate("#cz_restock"), "Supplies restocked!")
	assert_false(GoalMessages.translate("#cz_restock").begins_with("#"), "no raw token leaks")
