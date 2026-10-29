extends "res://src/tests/test_base.gd"
## The listen-server host's view is a prediction of its body puppet, not a body. Spawning must
## not put it back in the "damageable" group, or group walks like ww_roc2's death cloud would
## kill the host's view even though the puppet that actually captured the key is invincible.

const PlayerScript = preload("res://src/player.gd")
const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")


func _make_player(team: int) -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	p.team = team
	_root().add_child(p)
	return p


## Mirrors main._register_host_player: the view hands its body over to the puppet.
func _make_host_view(team: int) -> Node:
	var p := _make_player(team)
	p.collision_layer = 0
	p.has_body_puppet = true
	p.set_damageable(false)
	return p


func test_host_view_leaves_damageable_group() -> void:
	var view := _make_host_view(1)
	assert_false(view.is_in_group("damageable"), "host view drops out of the group")
	view.free()


func test_spawn_does_not_re_add_host_view() -> void:
	var view := _make_host_view(1)
	view._enable_after_spawn()
	assert_false(view.is_in_group("damageable"), "respawn leaves the host view out")
	view.set_damageable(true)
	assert_false(view.is_in_group("damageable"), "nothing can opt the host view back in")
	view.free()


func test_puppet_still_rejoins_on_spawn() -> void:
	var puppet := _make_player(1)
	puppet.set_damageable(false)
	puppet._enable_after_spawn()
	assert_true(puppet.is_in_group("damageable"), "an ordinary body is damageable again on spawn")
	puppet.free()


func test_death_cloud_ignores_host_view() -> void:
	# ww_roc2 gaswarnr: health -5000 applied to everyone in the goal's environment.
	# The capturing puppet is invincible; the host's view must not be a target at all.
	var puppet := _make_player(1)
	puppet.invincible_until = Time.get_ticks_msec() / 1000.0 + 11.0
	var view := _make_host_view(1)
	var g: Node3D = TFGoalBaseScript.new()
	_root().add_child(g)
	g.goal_effects = TFGoalBaseScript.GE_SAME_ENVIRONMENT
	g.req_team = 0
	g.heal_amount = -5000
	g._apply_player_effects(puppet)
	assert_false(puppet.is_dead, "invincible capturer survives the death cloud")
	assert_false(view.is_dead, "the host's view is not a death-cloud target")
	assert_eq(view.health, 100.0, "the host's view takes no damage")
	g.free()
	puppet.free()
	view.free()
