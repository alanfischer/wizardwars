extends "res://src/tests/test_base.gd"
## CMultiManager::ManagerUse clears its Use until the last target has fired, so a manager
## without the thread flag ignores a trigger that lands mid-sequence. ww_monoliths' `victory`
## toggles the spawn gates at 0 and starts the 20 s re-open timer; running it twice would
## close the gates and immediately reopen them.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


class Counter extends Node:
	var hits := 0

	func trigger(_activator: Node, _type: TriggerSystem.Type) -> void:
		hits += 1


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


func _counter(targetname: String) -> Counter:
	var c := Counter.new()
	_root().add_child(c)
	_keep(c)
	TriggerSystem.register(targetname, c)
	return c


func _manager(keys: Dictionary):
	var mm := Node3D.new()
	var e := {"classname": "multi_manager", "targetname": "mm"}
	e.merge(keys, true)
	mm.set_meta("entity", e)
	mm.set_script(MultiManager)
	_root().add_child(mm)
	_keep(mm)
	return mm


func _wait(sec: float) -> void:
	await _tree().create_timer(sec).timeout


func test_retrigger_mid_sequence_is_ignored() -> void:
	var now := _counter("now")
	var later := _counter("later")
	var mm = _manager({"now": "0", "later": "0.2"})
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	await _wait(0.4)
	assert_eq(now.hits, 1, "the second trigger landed while running and fired nothing")
	assert_eq(later.hits, 1, "only one delayed fire was scheduled")


func test_usable_again_once_the_last_target_fires() -> void:
	var later := _counter("later")
	var mm = _manager({"later": "0.1"})
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	await _wait(0.3)
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	await _wait(0.3)
	assert_eq(later.hits, 2, "a finished sequence accepts the next trigger")


func test_immediate_only_manager_never_stays_busy() -> void:
	var now := _counter("now")
	var mm = _manager({"now": "0"})
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(now.hits, 2, "nothing is left pending, so each trigger runs")


func test_thread_flag_runs_every_trigger() -> void:
	var later := _counter("later")
	var mm = _manager({"spawnflags": "1", "later": "0.2"})
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	await _wait(0.4)
	assert_eq(later.hits, 2, "a threaded manager clones per trigger")


func test_a_target_retriggering_the_manager_on_its_last_fire_is_ignored() -> void:
	var later := _counter("later")
	var mm = _manager({"later": "0.1", "mm": "0.1"})
	TriggerSystem.register("mm", mm)
	mm.trigger(null, TriggerSystem.Type.TOGGLE)
	await _wait(0.5)
	assert_eq(later.hits, 1, "Use is restored only after the last batch has fired")
