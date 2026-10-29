extends "res://src/tests/test_base.gd"
## The newcomer's controls card rides the same panel as the map description, with the
## description queued behind it — one card at a time, one key to move past each.

const IntroGuide = preload("res://src/systems/intro_guide.gd")

var _handoffs := 0


## _handoffs counts the map-description hand-offs one card made.
func _setup_test(_test_name: String) -> void:
	_handoffs = 0


func _count_handoff() -> void:
	_handoffs += 1


## Let the fade-out tween finish so the queued callback actually lands. Not the base _settle:
## this one waits on a tween and a process frame, and physics never enters it.
func _settle_motd(hud: HUD) -> void:
	if hud._motd_tween and hud._motd_tween.is_running():
		await hud._motd_tween.finished
	await (Engine.get_main_loop() as SceneTree).process_frame


func test_the_card_hands_off_to_the_map_description() -> void:
	var hud := _make_hud()
	hud.show_intro(IntroGuide.body(false), _count_handoff)
	assert_true(hud._motd_visible, "the card is up")
	assert_eq(hud._motd_title.text, IntroGuide.TITLE, "titled as the welcome card")
	assert_eq(_handoffs, 0, "the description waits behind it")
	hud.hide_map_info()
	await _settle_motd(hud)
	assert_eq(_handoffs, 1, "dismissing the card shows the description")
	assert_false(hud._motd_visible, "and the panel is gone")
	hud.queue_free()


func test_a_second_dismiss_does_not_hand_off_twice() -> void:
	var hud := _make_hud()
	hud.show_intro(IntroGuide.body(false), _count_handoff)
	hud.hide_map_info()
	hud.hide_map_info()  # a second key while the card fades
	await _settle_motd(hud)
	assert_eq(_handoffs, 1, "the description is shown once")
	hud.queue_free()


func test_the_hold_running_out_hands_off_as_well() -> void:
	var hud := _make_hud()
	# Same panel, a hold short enough to age out inside the test.
	hud.show_map_info("Card", "body", null, Vector2(-1, -1), 0.05, _count_handoff)
	await _settle_motd(hud)
	assert_eq(_handoffs, 1, "a player who reads nothing still gets the description")
	hud.queue_free()


func test_a_plain_description_leaves_nothing_queued() -> void:
	var hud := _make_hud()
	hud.show_intro(IntroGuide.body(false), _count_handoff)
	hud.hide_map_info()
	await _settle_motd(hud)
	hud.show_map_info("ww_2fort", "a map")
	hud.hide_map_info()
	await _settle_motd(hud)
	assert_eq(_handoffs, 1, "the spent callback doesn't fire again on the next panel")
	hud.queue_free()


func test_the_card_reads_for_the_controls_in_hand() -> void:
	var keyboard := IntroGuide.body(false)
	var vr := IntroGuide.body(true)
	assert_true(keyboard.contains("W A S D"), "the keyboard card names the movement keys")
	assert_true(keyboard.contains("Hold F"), "and how to throw a satchel")
	assert_true(vr.contains("Trigger"), "the VR card talks about the controllers instead")
	assert_ne(vr, keyboard, "the two are not the same card")


func test_the_tick_clears_once_it_has_been_read() -> void:
	var original := IntroGuide.should_show()
	IntroGuide.set_show(true)
	assert_true(IntroGuide.should_show(), "the lobby can turn the card back on")
	IntroGuide.set_show(false)
	assert_false(IntroGuide.should_show(), "and showing it clears the tick")
	IntroGuide.set_show(original)
