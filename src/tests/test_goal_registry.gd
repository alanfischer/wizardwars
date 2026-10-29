extends "res://src/tests/test_base.gd"
## GoalSystem's goal_no registry and what it does with duplicates maps ship: ww_checkmate
## gives both king dropoffs goal_no 10, ww_monoliths has two goals on 702. TFC's Findgoal()
## walks the edict list and returns the first match, so the first registration must win here too.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")


func _make_goal() -> Node:
	var g: Node3D = TFGoalBaseScript.new()
	_root().add_child(g)
	_spawned.append(g)
	return g


func _despawn_all() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			GoalSystem.unregister(n)
			n.free()
	_spawned.clear()


func test_the_first_registration_of_a_goal_no_wins() -> void:
	var first := _make_goal()
	var second := _make_goal()
	GoalSystem.register(first, 10, 0)
	GoalSystem.register(second, 10, 0)
	assert_eq(GoalSystem.get_goal(10), first,
		"a duplicate goal_no resolves to the first one spawned, as TFC's Findgoal does")


func test_a_duplicate_still_joins_the_full_goal_list() -> void:
	var first := _make_goal()
	var second := _make_goal()
	GoalSystem.register(first, 10, 0)
	GoalSystem.register(second, 10, 0)
	var all := GoalSystem.get_all_goals()
	assert_true(first in all, "both goals still exist and still run")
	assert_true(second in all, "both goals still exist and still run")


func test_groups_keep_every_member() -> void:
	var a := _make_goal()
	var b := _make_goal()
	GoalSystem.register(a, 0, 5)
	GoalSystem.register(b, 0, 5)
	assert_eq(GoalSystem.get_group(5).size(), 2, "group_no is a list, not a single slot")


func test_unregister_frees_the_goal_no_for_a_later_map() -> void:
	var g := _make_goal()
	GoalSystem.register(g, 10, 0)
	GoalSystem.unregister(g)
	assert_eq(GoalSystem.get_goal(10), null, "the slot is released with the goal")
