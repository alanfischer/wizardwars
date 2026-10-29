extends "res://src/tests/test_base.gd"
## ModelRig: the clip clock six creatures now drive off, and the sleeping it exists to make legal.
##
## The clock is the interesting half. Asking an AnimationPlayer what it is doing is what used to
## be written out six times, and it is also what stops a rig from ever being allowed to sleep — a
## sleeping mixer reports its clip as playing forever. So every question here is answered off
## `age`, which the tests advance by hand: no physics frames, no wall clock.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const LOOP_LEN := 2.0
const ONCE_LEN := 0.5


## Two clips with the loop flags an MDL importer would have set from STUDIO_LOOPING.
func _rig_with(policy := ModelRig.Loop.MODEL, looping := PackedStringArray()) -> ModelRig:
	var host := Node3D.new()
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	var lib := AnimationLibrary.new()
	lib.add_animation(&"loop", _anim(LOOP_LEN, Animation.LOOP_LINEAR))
	lib.add_animation(&"once", _anim(ONCE_LEN, Animation.LOOP_NONE))
	ap.add_animation_library(&"", lib)
	host.add_child(ap)
	_root().add_child(host)
	_keep(host)
	var rig := ModelRig.new()
	rig.initialize(host, ap, policy, looping)
	return rig


func _anim(length: float, loop_mode: int) -> Animation:
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = loop_mode
	return anim


## Everything the rig publishes to clients, empties included: current_animation_changed is the
## signal EntityBehavior forwards onto NetInterp:net_anim, so this is the wire as a client sees it.
class _PublishLog:
	extends RefCounted
	var names: Array[String] = []

	func watch(ap: AnimationPlayer) -> void:
		ap.current_animation_changed.connect(_on_changed)

	func _on_changed(clip: String) -> void:
		names.append(clip)

	func last() -> String:
		return names[-1] if not names.is_empty() else "<nothing published>"

	func restarts(clip: String) -> int:
		return names.count(clip)


func test_a_one_shot_finishes_and_a_loop_goes_round() -> void:
	var rig := _rig_with()
	rig.play("once")
	assert_false(rig.clip_cycled(), "it has only just started")
	assert_false(rig.clip_over(), "so it is certainly not finished")

	rig.tick(ONCE_LEN)
	assert_true(rig.clip_cycled(), "it has run its length")
	assert_true(rig.clip_over(), "and being a one-shot, that is the end of it")

	rig.play("loop")
	rig.tick(LOOP_LEN)
	assert_true(rig.clip_cycled(), "the loop has come round")
	assert_false(rig.clip_over(), "but a loop is never over — it is about to play again")


## The guard that keeps a throw or a bite from being cut short by the walk clip behind it.
func test_a_running_one_shot_is_left_alone_until_it_ends() -> void:
	var rig := _rig_with()
	rig.play("once")
	rig.tick(ONCE_LEN * 0.5)
	rig.anim_player.seek(ONCE_LEN * 0.5, true)

	rig.play("once")
	assert_almost_eq(rig.anim_player.current_animation_position, ONCE_LEN * 0.5, 0.001,
		"asking for the clip it is already halfway through leaves the playhead where it was")

	rig.tick(ONCE_LEN)
	rig.play("once")
	assert_almost_eq(rig.anim_player.current_animation_position, 0.0, 0.001,
		"once it has finished, asking again plays it afresh")


## A loop asked for again is re-timed but never restarted: restarting would put a stop/start on
## the wire every cycle, for every creature, to show the same clip.
func test_a_loop_is_re_timed_rather_than_restarted() -> void:
	var rig := _rig_with()
	var published := _PublishLog.new()
	published.watch(rig.anim_player)

	rig.play("loop")
	assert_eq(published.restarts("loop"), 1, "it started")
	rig.tick(LOOP_LEN)
	assert_true(rig.clip_cycled(), "and came round")

	rig.play("loop")
	assert_eq(published.restarts("loop"), 1, "asking for it again does not restart the mixer")
	assert_false(rig.clip_cycled(), "but the clock is re-stamped, so the next cycle can be caught")
	assert_almost_eq(rig.clip_ends, rig.age + LOOP_LEN, 0.001, "one whole cycle from now")


func test_restart_forces_one() -> void:
	var rig := _rig_with()
	rig.play("once")
	rig.anim_player.seek(ONCE_LEN * 0.5, true)

	rig.play("once", true)
	assert_almost_eq(rig.anim_player.current_animation_position, 0.0, 0.001,
		"a bite that lands faster than its clip runs has to start over")


## An AnimationPlayer emits current_animation_changed only when the NAME changes, so the
## stop()-then-play() a change needs publishes "" and then nothing when the clip is the same one
## — and a client entering PVS after that is handed an empty clip name and stands in its rest
## pose. A skeleton re-rolling the same idle used to leave exactly that behind.
func test_replaying_one_clip_never_publishes_an_empty_name() -> void:
	var rig := _rig_with()
	var published := _PublishLog.new()
	published.watch(rig.anim_player)

	rig.play("once")
	rig.tick(ONCE_LEN)
	rig.play("once")          # the same idle drawn twice in a row
	assert_eq(published.last(), "once", "a client arriving now is told what it is playing")

	rig.play("once", true)    # ...and a forced restart is no different
	assert_eq(published.last(), "once", "still named")

	rig.play("loop")
	assert_eq(published.last(), "loop", "a real change still reaches clients")
	assert_eq(published.restarts("loop"), 1, "once, not twice")


func test_an_unknown_clip_is_ignored() -> void:
	var rig := _rig_with()
	rig.play("once")
	rig.play("swim")
	assert_eq(rig.clip, "once", "a clip the model does not have leaves the rig where it was")


## What LISTED is for: an AI that waits for a clip to end would be stranded forever in an idle
## the model happens to have marked as looping (raisedead.mdl's idle1, giantplant.mdl's three).
func test_listed_overrides_the_models_own_loop_flags() -> void:
	var rig := _rig_with(ModelRig.Loop.LISTED, PackedStringArray(["once"]))
	rig.play("loop")
	rig.tick(LOOP_LEN)
	assert_true(rig.clip_over(), "a clip left off the list is a one-shot whatever the model said")

	rig.play("once")
	rig.tick(ONCE_LEN)
	assert_false(rig.clip_over(), "and one on it loops, again whatever the model said")


func test_model_policy_leaves_the_models_flags_alone() -> void:
	var rig := _rig_with()
	rig.play("loop")
	assert_eq(rig.anim_player.get_animation("loop").loop_mode, Animation.LOOP_LINEAR,
		"the MDL's own STUDIO_LOOPING flag still stands")
	rig.play("once")
	assert_eq(rig.anim_player.get_animation("once").loop_mode, Animation.LOOP_NONE, "and so does its absence")


## The suite is headless, which is the dedicated-server case: the rig is put to sleep and there is
## nothing to ever wake it, so no notifier is built to ask.
func test_a_headless_rig_sleeps_and_is_never_woken() -> void:
	var rig := _rig_with()
	var host := rig.anim_player.get_parent()
	var children_before := host.get_child_count()

	rig.sleep_offscreen(AABB(Vector3.ZERO, Vector3.ONE))

	assert_false(rig.anim_player.active, "asleep")
	assert_eq(host.get_child_count(), children_before, "and no notifier watching for a screen")

	rig.wake()
	assert_true(rig.anim_player.active, "it can still be woken by hand — the tests do it")


## A sleeping rig still reports every clip the AI chooses, which is the whole reason clients of a
## creature that sleeps its rig see it animate at all.
func test_a_sleeping_rig_still_tells_clients_what_it_is_playing() -> void:
	var rig := _rig_with()
	var published := _PublishLog.new()
	published.watch(rig.anim_player)
	rig.sleep()

	rig.play("once")
	assert_eq(rig.anim_player.current_animation, "once", "the name is set even though nothing advances")
	assert_eq(published.last(), "once", "and the change was published")


func test_it_carries_a_static_hitbox_for_the_bones_it_replaces() -> void:
	var rig := _rig_with()
	var host := rig.anim_player.get_parent()
	var area := rig.add_hitbox(Vector3(1.0, 2.0, 3.0), Vector3(0.0, 1.0, 0.0),
		GameConsts.HITBOX_GROUP_HEAD)

	assert_eq(area.get_parent(), host, "it hangs off the body, not off a bone — that is the point")
	assert_eq(area.collision_layer, GameConsts.MASK_HITBOX, "on the layer hitscan reads")
	assert_eq(area.collision_mask, 0, "and it looks for nothing itself")
	assert_false(area.monitoring, "queryable only, the way the MDL builds its own")
	assert_eq(int(area.get_meta("hitbox_group")), GameConsts.HITBOX_GROUP_HEAD, "carrying its group")
	assert_eq(area.position, Vector3(0.0, 1.0, 0.0), "where it was put")
