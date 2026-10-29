extends "res://src/tests/test_base.gd"
## A goal's `wait` is its reset timer, and GoldSrc reads a negative one as "never reactivates".
## Treating -1 as "reset one second ago" fired the timer immediately, handing a `wait -1` pickup
## back with an empty-looking stand (ww_december's flag pickups).


func _make_goal(keys: Dictionary) -> InfoTFGoal:
	var g := InfoTFGoal.new()
	var ent := {"classname": "info_tfgoal", "g_a": "1", "g_e": "1"}
	ent.merge(keys, true)
	g.set_meta("entity", ent)
	_root().add_child(g)
	return g


func _cleanup(nodes: Array) -> void:
	for n in nodes:
		n.queue_free()
	NetworkManager.reset_entities()


func test_negative_wait_never_resets() -> void:
	var g := _make_goal({"goal_no": "91", "wait": "-1"})
	g.goal_activate(null)
	assert_eq(g.goal_state, TFGoalBase.GoalState.ACTIVE, "activation takes")
	assert_eq(g._inactivate_time, 0.0, "wait -1 leaves the reset timer unarmed")
	await _tick(3)
	assert_eq(g.goal_state, TFGoalBase.GoalState.ACTIVE, "and it never resets itself")
	_cleanup([g])


func test_reset_timer_does_not_resurrect_a_removed_goal() -> void:
	# The ww_december shape: a pickup that removes its own group, model and all.
	var pickup := _make_goal({"goal_no": "95", "group_no": "90", "rv_gr": "90", "wait": "-1"})
	var model := _make_goal({"goal_no": "90", "group_no": "90"})
	await _tick(1)
	pickup.goal_activate(null)
	await _tick(3)
	assert_eq(model.goal_state, TFGoalBase.GoalState.REMOVED, "the flag model is removed")
	assert_false(model._game_visible, "so it stops rendering")
	assert_eq(pickup.goal_state, TFGoalBase.GoalState.REMOVED,
		"and the pickup goes with it — an empty stand must not still hand out the flag")
	_cleanup([pickup, model])


func test_positive_wait_still_resets() -> void:
	# The ordinary case (resupply backpacks, capture zones) keeps its timed reset.
	var g := _make_goal({"goal_no": "92", "wait": "0"})
	g.goal_activate(null)
	assert_gt(g._inactivate_time, 0.0, "a non-negative wait arms the timer")
	await _tick(3)
	assert_eq(g.goal_state, TFGoalBase.GoalState.INACTIVE, "and the goal resets")
	assert_true(g._game_visible, "and shows itself again")
	_cleanup([g])
