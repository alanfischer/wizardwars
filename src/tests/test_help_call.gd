extends "res://src/tests/test_base.gd"
## Calling for help (Z) is WW's medic call: the server picks the sprite and the voice line so
## every peer draws the same thing, and it owns the cooldown so the key can't be leaned on.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const PlayerScript = preload("res://src/player.gd")


func _make_player() -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	_root().add_child(p)
	return p


func test_call_returns_sprite_and_voice() -> void:
	var p := _make_player()
	var fx: Array = p.call_for_help()
	assert_eq(fx.size(), 2, "a call answers with a sprite and a sound")
	assert_eq(fx[0], Player.HELP_SPRITE, "the healthy call shows the arrow")
	assert_true(fx[1] in Player.HELP_SOUNDS, "and shouts one of the health lines")
	p.free()


func test_cooldown_refuses_the_second_call() -> void:
	var p := _make_player()
	assert_false(p.call_for_help().is_empty(), "first call goes through")
	assert_true(p.call_for_help().is_empty(), "a second call inside the cooldown is dropped")
	p._next_help_call = 0.0
	assert_false(p.call_for_help().is_empty(), "and it's allowed again once the cooldown lapses")
	p.free()


## Only the voice line changes. The sprite stays the arrow so the call reads as a call — poison
## already draws its own icon beside it, and swapping would show that icon twice.
func test_poisoned_caller_retches_but_still_points() -> void:
	var p := _make_player()
	StatusSystem.apply_status(p, GameConsts.StatusType.POISON)
	var fx: Array = p.call_for_help()
	assert_eq(fx[0], Player.HELP_SPRITE, "poison does not swap the arrow out")
	assert_true(fx[1] in Player.HELP_POISON_SOUNDS, "but the shout becomes a retch")
	StatusSystem.clear_all(p)
	p.free()


func test_dead_and_bear_cannot_call() -> void:
	var dead := _make_player()
	dead.is_dead = true
	assert_true(dead.call_for_help().is_empty(), "a corpse doesn't call for help")
	dead.free()

	var bear := _make_player()
	bear.is_bear = true
	assert_true(bear.call_for_help().is_empty(), "nor does a bear, which has no voice for it")
	bear.free()


## The paths are string constants the server hands to every client, so a typo would only show
## as a silent missing sprite or sound in a live match.
func test_every_asset_the_call_names_exists() -> void:
	var sprite := AssetLoader.load_sprite_node(Player.HELP_SPRITE)
	assert_ne(sprite, null, "%s loads" % Player.HELP_SPRITE)
	if sprite:
		assert_ne(sprite.texture, null, "%s has a texture" % Player.HELP_SPRITE)
		sprite.free()
	for sound_path in Player.HELP_SOUNDS + Player.HELP_POISON_SOUNDS:
		assert_ne(AssetLoader.load_sound(sound_path), null, "%s loads" % sound_path)
