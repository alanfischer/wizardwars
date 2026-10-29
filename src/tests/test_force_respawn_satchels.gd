extends "res://src/tests/test_base.gd"
## A goal-driven force respawn bins the respawned player's live satchels. Some goals (e.g.
## ww_monoliths' round win) end via TFGoalBase rather than PotatoC's RespawnPlayer(), so nothing
## called destroy_all_dynamic_entities() and a thrown satchel could survive the reset.

const PlayerScript = preload("res://src/player.gd")
const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")


func _make_player(team: int) -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	p.team = team
	_root().add_child(p)
	p.add_to_group("damageable")
	_spawned.append(p)
	return p


## A satchel already out in the world. setup() needs spawn/network data, so the
## test wires the two things removal looks at: the projectile group and owner.
func _make_satchel(owner_node: Node) -> Satchel:
	var s := Satchel.new()
	s.owner_node = owner_node
	s._entity.initialize(s)
	_root().add_child(s)
	s.add_to_group("projectile")
	_spawned.append(s)
	return s


func _make_goal(effects: int, results: int) -> Node:
	var g: Node3D = TFGoalBaseScript.new()
	g.goal_effects = effects
	g.goal_results = results
	_root().add_child(g)
	_spawned.append(g)
	return g


func test_remove_live_satchels_only_takes_its_owners() -> void:
	var mine := _make_player(1)
	var theirs := _make_player(2)
	var a := _make_satchel(mine)
	var b := _make_satchel(theirs)

	mine.satchel_pack.remove_live()
	assert_true(a.is_queued_for_deletion(), "the player's own satchel is binned")
	assert_false(b.is_queued_for_deletion(), "someone else's is left alone")


func test_remove_live_satchels_clears_a_primed_fuse() -> void:
	var p := _make_player(1)
	p.satchel_pack.fuse_remaining = 2.5
	p.satchel_pack.remove_live()
	assert_eq(p.satchel_pack.fuse_remaining, -1.0, "a primed-but-unthrown satchel is defused too")


func test_a_round_win_clears_every_players_satchels() -> void:
	var winner := _make_player(1)
	var loser := _make_player(2)
	var a := _make_satchel(winner)
	var b := _make_satchel(loser)
	# ww_monoliths' red_wins: goal_effects 9 (AP + everyone else), result 112.
	var goal = _make_goal(TFGoalBase.GE_AP | TFGoalBase.GE_NONAP, 112)

	goal._apply_force_respawn(winner)
	assert_true(a.is_queued_for_deletion(), "the activating player's satchel goes")
	assert_true(b.is_queued_for_deletion(), "and so does everyone else's")


func test_a_force_respawn_leaves_unaffected_players_alone() -> void:
	var ap := _make_player(1)
	var other := _make_player(2)
	var a := _make_satchel(ap)
	var b := _make_satchel(other)
	# ww_chasm's respawn goal: goal_effects 1, the activating player only.
	var goal = _make_goal(TFGoalBase.GE_AP, 32)

	goal._apply_force_respawn(ap)
	assert_true(a.is_queued_for_deletion(), "the respawned player's satchel goes")
	assert_false(b.is_queued_for_deletion(), "a bystander keeps theirs")
