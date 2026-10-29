extends "res://src/tests/test_base.gd"
## The mana bar becomes the dragon's flame meter while riding: mana is unspendable
## up there, so the slot shows the resource the rider actually burns.

const DragonScript = preload("res://src/monsters/dragon.gd")


func test_mana_mode_is_default() -> void:
	var hud := _make_hud()
	hud.update_mana(60.0, 100.0)
	assert_eq(hud._mana.label.text, "Mana: 60", "bar starts in mana mode")
	assert_ne(hud._mana.fill.color, HUD.FLAME_COLOR, "mana fill, not the dragon's")
	# update_flame is inert until the mode is on, so a stray flame sync can't
	# repaint a dismounted player's mana bar.
	hud.update_flame(10, 50)
	assert_eq(hud._mana.label.text, "Mana: 60", "flame update ignored in mana mode")
	hud.queue_free()


func test_flame_mode_shows_flame() -> void:
	var hud := _make_hud()
	hud.set_flame_mode(true)
	hud.update_flame(25, 50)
	assert_eq(hud._mana.label.text, "FIRE: 25", "label reads flame charges")
	assert_eq(hud._mana.fill.color, HUD.FLAME_COLOR, "flame fill color")
	assert_almost_eq(hud._mana.fill.anchor_right, 0.5, 0.001, "bar half full at 25/50")
	hud.queue_free()


func test_mana_updates_ignored_while_mounted() -> void:
	var hud := _make_hud()
	hud.set_flame_mode(true)
	hud.update_flame(30, 50)
	hud.update_mana(90.0, 100.0)  # server mana sync arriving mid-flight
	assert_eq(hud._mana.label.text, "FIRE: 30", "mana sync doesn't steal the bar")
	hud.queue_free()


func test_dismount_restores_mana() -> void:
	var hud := _make_hud()
	hud.set_flame_mode(true)
	hud.update_flame(5, 50)
	hud.set_flame_mode(false)
	hud.update_mana(42.0, 100.0)
	assert_eq(hud._mana.label.text, "Mana: 42", "bar returns to mana after dismount")
	assert_eq(hud._mana.fill.color, hud._mana.base_color, "mana fill color restored")
	hud.queue_free()


func test_flame_clamped_to_range() -> void:
	var dragon: Dragon = DragonScript.new()
	dragon.flame = Dragon.MAX_FLAME + 10
	assert_eq(dragon.flame, Dragon.MAX_FLAME, "flame can't exceed the max")
	dragon.flame = -5
	assert_eq(dragon.flame, 0, "flame can't go negative")
	dragon.free()


func test_flame_sync_without_rider_is_safe() -> void:
	var dragon: Dragon = DragonScript.new()
	dragon.flame = 3  # setter pushes to the rider — there isn't one
	dragon.sync_flame_to_rider()
	assert_eq(dragon.flame, 3, "unridden dragon still tracks its own flame")
	dragon.free()
