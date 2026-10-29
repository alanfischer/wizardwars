extends "res://src/tests/test_base.gd"
## A point goal is touchable only if it has a model (CTFCGoal::PlaceGoal). ww_2fort's "your grail
## has returned" goals have none and float over the flag stands; once touchable, standing at your
## own stand set them off every frame, so a carrier heard their grail "return" over and over.


func _make_goal(keys: Dictionary) -> InfoTFGoal:
	var g := InfoTFGoal.new()
	var ent := {"classname": "info_tfgoal", "g_a": "1", "g_e": "1"}
	ent.merge(keys, true)
	g.set_meta("entity", ent)
	_root().add_child(g)
	return g


func _toucher() -> CharacterBody3D:
	var body := CharacterBody3D.new()
	_root().add_child(body)
	return body


func _cleanup(nodes: Array) -> void:
	for n in nodes:
		n.queue_free()
	NetworkManager.reset_entities()


func test_goal_without_model_ignores_touch() -> void:
	var g := _make_goal({"goal_no": "93", "wait": "-1"})  # -1 holds a wrongful activation in view
	var body := _toucher()
	g._on_body_entered(body)
	await _tick(2)
	assert_eq(g.goal_state, TFGoalBase.GoalState.INACTIVE, "walking into it does nothing")
	g.goal_activate(null)
	assert_eq(g.goal_state, TFGoalBase.GoalState.ACTIVE, "it still fires when something activates it")
	_cleanup([g, body])


func test_goal_with_model_takes_touch() -> void:
	var g := _make_goal({"goal_no": "94", "mdl": "models/backpack.mdl", "wait": "-1"})
	var body := _toucher()
	g._on_body_entered(body)
	await _tick(2)
	assert_eq(g.goal_state, TFGoalBase.GoalState.ACTIVE, "a resupply backpack still gets picked up")
	_cleanup([g, body])
