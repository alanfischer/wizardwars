extends "res://src/tests/test_base.gd"
## The +use capability gate (GoldSrc FCAP_IMPULSE_USE): +use used to resolve its target as "the
## first ancestor with a trigger() method", so it fired goals/breakables/trains through world
## brushwork. Only entities whose ObjectCaps() advertise FCAP_IMPULSE_USE are +usable — being
## *targetable* by a trigger is a separate capability.

## The reported bug, stated directly: a breakable has to be destroyed, not used.
func test_breakable_is_not_player_usable() -> void:
	var b := FuncBreakable.new()
	assert_false(b.is_player_usable(), "a func_breakable ignores +use")
	assert_true(b.has_method("trigger"), "even though it is triggerable")
	assert_false(GoldSrcEntity.is_player_usable(b), "and the shared +use test agrees")
	b.free()


func test_world_geometry_is_not_player_usable() -> void:
	# The +use ray mostly hits plain brushwork, which declares no cap at all.
	var n := Node3D.new()
	assert_false(GoldSrcEntity.is_player_usable(n), "plain geometry is not usable")
	assert_false(GoldSrcEntity.is_player_usable(null), "and a missed ray is not either")
	n.free()


## CBaseDoor::ObjectCaps — only SF_USE_ONLY (256) doors answer +use.
func test_door_needs_use_only_flag() -> void:
	var plain := FuncDoor.new()
	plain.spawn_flags = 0
	assert_false(plain.is_player_usable(), "a touch-opened door ignores +use")
	plain.free()

	var use_only := FuncDoor.new()
	use_only.spawn_flags = FuncDoorBase.SF_USE_ONLY
	assert_true(use_only.is_player_usable(), "a use-only door opens on +use")
	use_only.free()


## CBaseButton::ObjectCaps — a button with a "health" key is shot, not pressed.
func test_button_is_usable_unless_shootable() -> void:
	for maker in [func(): return FuncButton.new(), func(): return FuncRotButton.new()]:
		var pressable = maker.call()
		pressable._shootable = false
		assert_true(pressable.is_player_usable(), "a plain button is pressed with +use")
		pressable.free()

		var shootable = maker.call()
		shootable._shootable = true
		assert_false(shootable.is_player_usable(), "a button with health is shot instead")
		shootable.free()


## FuncPlat extends FuncDoorBase for the movement code, but spawnflag 256 is not
## SF_USE_ONLY on a plat and CFuncPlat has no FCAP_IMPULSE_USE.
func test_plat_does_not_inherit_the_door_rule() -> void:
	for p in [FuncPlat.new(), FuncPlatRot.new()]:
		p.spawn_flags = FuncDoorBase.SF_USE_ONLY
		assert_false(p.is_player_usable(), "plats ride on touch/trigger, never +use")
		p.free()


## Players drive the golem through the cockpit brushes; +use on the body itself
## must not reach CGolem::Use and teleport it home mid-fight.
func test_golem_controls_usable_body_is_not() -> void:
	var controls := FuncGolemControls.new()
	assert_true(controls.is_player_usable(), "cockpit controls are +usable")
	controls.free()

	var body := FuncGolemBody.new()
	assert_false(body.is_player_usable(), "the golem body is not")
	body.free()


func test_tracktrain_is_usable() -> void:
	var t := FuncTrackTrain.new()
	assert_true(t.is_player_usable(), "riders start/stop a tracktrain with +use")
	t.free()


## The other half of the same defect: a breakable reached through the trigger
## path (multi_manager and friends default to TOGGLE) must shatter, not vanish.
func test_triggering_a_breakable_destroys_it() -> void:
	var b := SpyBreakable.new()
	b._material = 1  # wood
	b._game_visible = true
	b.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_true(b.broke, "a TOGGLE destroys a visible breakable")
	assert_true(b.visible_calls.is_empty(), "it does not silently hide instead")
	b.free()


## Records routing without the autoload-heavy _ready/GibEffect side effects.
class SpyBreakable:
	extends FuncBreakable
	var broke := false
	var visible_calls: Array = []
	func _break() -> void:
		broke = true
	func set_entity_visible(on: bool) -> void:
		visible_calls.append(on)
	func _sync_notify() -> void:
		pass
