extends "res://src/tests/test_base.gd"
## trigger_multiple is touch-driven, not an entry event (CBaseTrigger::MultiTouch): firing only
## on Area3D.body_entered gave a standing player exactly one touch — ww_chasm's cap points ignore
## the touch while disarmed, so standing on the point did nothing until you walked out and back in.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const TriggerMultipleScript = preload("res://src/entities/trigger_multiple.gd")
const PlayerScript = preload("res://src/player.gd")


class CountingTarget extends Node:
	var fires := 0

	func trigger(_activator: Node, _type) -> void:
		fires += 1


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


func _track(n: Node) -> Node:
	_spawned.append(n)
	return n


## A brush trigger as the importer builds one: the entity node with a "Volume" Area3D
## child carrying the brush shape. 4 units on a side, centred on the origin.
func _trigger(keys := {}) -> Node3D:
	var e := {"classname": "trigger_multiple", "target": "cap"}
	e.merge(keys, true)
	var t: Node3D = TriggerMultipleScript.new()
	var area := Area3D.new()
	area.name = "Volume"
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 4)
	col.shape = box
	area.add_child(col)
	t.add_child(area)
	t.set_meta("entity", e)
	_root().add_child(t)
	return _track(t) as Node3D


## A player parked inside the trigger. Needs its own shape and player layer — the
## scene-built one comes from player.tscn, which a unit test has no use for.
func _player_inside(team := 1) -> CharacterBody3D:
	var p: CharacterBody3D = PlayerScript.new()
	p.team = team
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	col.shape = sphere
	p.add_child(col)
	p.collision_layer = GameConsts.MASK_PLAYER
	_root().add_child(p)
	p.global_position = Vector3.ZERO
	return _track(p) as CharacterBody3D


func _target() -> CountingTarget:
	var c := CountingTarget.new()
	_root().add_child(c)
	TriggerSystem.register("cap", c)
	return _track(c) as CountingTarget


## CTriggerMultiple::Spawn: an absent (or zero) wait is 0.2, never "fire once".
func test_absent_wait_takes_the_engine_default() -> void:
	var t := _trigger()
	assert_eq(t._wait_time, TriggerMultiple.DEFAULT_WAIT, "unset wait becomes 0.2s")
	var explicit := _trigger({"wait": "2"})
	assert_eq(explicit._wait_time, 2.0, "an explicit wait is left alone")


## The regression: ww_chasm's cap points, where the first touch is spent while the
## point is still disarmed and nothing fires again until the player re-enters.
func test_standing_in_the_volume_keeps_firing() -> void:
	var target := _target()
	var t := _trigger()
	t._wait_time = 0.05  # keep the test to a few frames; the rate itself is tested below
	_player_inside()
	await _tick(2)
	var on_entry := target.fires
	assert_gt(on_entry, 0, "the entry touch still fires")
	await _tick(20)
	assert_gt(target.fires, on_entry, "standing still keeps touching — no re-entry needed")


## ActivateMultiTrigger's nextthink gate: re-firing is rate-limited by wait, so a
## touch-driven trigger doesn't fire 60 times a second.
func test_wait_limits_the_refire_rate() -> void:
	var target := _target()
	var t := _trigger({"wait": "10"})
	_player_inside()
	await _tick(20)
	assert_eq(target.fires, 1, "a 10s wait fires once and then holds")
	assert_gt(t._last_trigger_time, 0.0, "the fire stamped the cooldown")


## The team filter is a property of the touch, not of the entry: a player on the wrong
## team standing in the volume must never fire it, however long they wait.
func test_wrong_team_never_fires_while_standing() -> void:
	var target := _target()
	var t := _trigger({"team_no": "2"})
	t._wait_time = 0.05
	_player_inside(1)
	await _tick(20)
	assert_eq(target.fires, 0, "team_no 2 ignores a team 1 player parked inside")


## trigger_once keeps its one shot: the poll must not resurrect a spent trigger.
func test_trigger_once_still_fires_only_once() -> void:
	var target := _target()
	var t := _trigger({"classname": "trigger_once"})
	t._wait_time = 0.05
	_player_inside()
	await _tick(20)
	assert_eq(target.fires, 1, "trigger_once latches after its first fire")
