extends "res://src/tests/test_base.gd"
## Force blast's kick to the caster rides their input (CMF_FORCEBLAST) so prediction and server
## apply it on the same tick: the flag goes out once per cast, the kick is honoured once, a flag
## arriving again within the cooldown is ignored on both sides alike, and a cast that missed its
## input is dropped rather than sent later.

const InputCommand = preload("res://addons/pmove/input_command.gd")
const Movement = preload("res://addons/pmove/movement.gd")
const KICK := Vector3(ForceBlastWeapon.SELF_BOOST, 0.0, 0.0)


func _cmd(seq: int, flags: int = 0) -> RefCounted:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.custom_flags = flags
	return cmd


## The kick for this input, moving along +x at 5 m/s going into the tick.
func _boost(w: ForceBlastWeapon, cmd, velocity := Vector3(5.0, 0.0, 0.0)) -> Vector3:
	var mods := Movement.MovementModifiers.new()
	var state := Movement.MovementState.new()
	state.velocity = velocity
	w.contribute_modifiers(mods, cmd, state)
	return mods.velocity_add


func test_a_cast_flags_the_next_input_once() -> void:
	var w := ForceBlastWeapon.new()
	w._boost_pending = true
	w._boost_cast_ms = Time.get_ticks_msec()
	var a := _cmd(1)
	w.contribute_input_flags(a)
	assert_true(a.custom_flags & GameConsts.CMF_FORCEBLAST != 0, "the next input carries the kick")
	var b := _cmd(2)
	w.contribute_input_flags(b)
	assert_eq(b.custom_flags & GameConsts.CMF_FORCEBLAST, 0, "and only that one")


func test_a_stale_cast_is_dropped() -> void:
	var w := ForceBlastWeapon.new()
	w._boost_pending = true
	w._boost_cast_ms = Time.get_ticks_msec() - ForceBlastWeapon.BOOST_PENDING_MS - 50
	var cmd := _cmd(1)
	w.contribute_input_flags(cmd)
	assert_eq(cmd.custom_flags & GameConsts.CMF_FORCEBLAST, 0, "too late to belong to that cast")


func test_the_kick_is_honoured_once_per_cooldown() -> void:
	var w := ForceBlastWeapon.new()
	assert_eq(_boost(w, _cmd(500)), Vector3.ZERO, "no flag, no kick")
	assert_eq(_boost(w, _cmd(501, GameConsts.CMF_FORCEBLAST)), KICK, "a flagged input kicks along travel")
	assert_eq(_boost(w, _cmd(540, GameConsts.CMF_FORCEBLAST)), Vector3.ZERO, "again within the cooldown: ignored")
	assert_eq(_boost(w, _cmd(501 + ForceBlastWeapon.BOOST_MIN_TICKS, GameConsts.CMF_FORCEBLAST)),
			KICK, "after it, the next cast kicks")


func test_no_kick_when_standing_still() -> void:
	var w := ForceBlastWeapon.new()
	assert_eq(_boost(w, _cmd(1, GameConsts.CMF_FORCEBLAST), Vector3.ZERO), Vector3.ZERO,
			"no direction of travel, nothing to kick along")


func test_the_guard_agrees_on_both_sides() -> void:
	# Client prediction and the server each run contribute_modifiers once per input on their own
	# weapon instance; fed the same inputs they must make the same calls.
	var client := ForceBlastWeapon.new()
	var server := ForceBlastWeapon.new()
	for seq in [10, 30, 95, 120, 200]:
		var cmd := _cmd(seq, GameConsts.CMF_FORCEBLAST)
		assert_eq(_boost(client, cmd), _boost(server, cmd), "same decision at seq %d" % seq)
