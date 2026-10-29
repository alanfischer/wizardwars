extends "res://src/tests/test_base.gd"
## TF goal invincibility (invincible_finished) — the ww_roc2 death-cloud fix.
## On roc2 the key dropoff grants the capturer 11s of invulnerability so the
## 10s-delayed gas goal (health -5000, applied to every player) spares them.

const PlayerScript = preload("res://src/player.gd")
const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")


## Goal with a deterministic environment check: anything below y=0 is "in water".
class WaterStubGoal:
	extends TFGoalBase

	func _is_point_in_water(pos: Vector3) -> bool:
		return pos.y < 0.0


func _make_player(team: int) -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	p.team = team
	_root().add_child(p)
	p.add_to_group("damageable")
	return p


func _make_goal() -> Node:
	var g: Node3D = TFGoalBaseScript.new()
	_root().add_child(g)
	return g


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func test_take_damage_blocked_while_invincible() -> void:
	var p := _make_player(1)
	p.invincible_until = _now() + 10.0
	p.take_damage(5000.0)
	assert_eq(p.health, 100.0, "invincible player takes no damage")
	assert_false(p.is_dead, "invincible player survives")
	p.free()


func test_take_damage_applies_after_invincibility_expires() -> void:
	var p := _make_player(1)
	p.invincible_until = _now() - 1.0
	p.take_damage(30.0)
	assert_eq(p.health, 70.0, "expired invincibility no longer blocks damage")
	p.free()


func test_parse_reads_invincible_finished() -> void:
	var g := _make_goal()
	g._parse_tf_properties({"invincible_finished": "11", "goal_effects": "1"})
	assert_eq(g.invincible_time, 11.0, "invincible_finished parsed")
	g.free()


func test_ap_goal_grants_invincibility_to_activator_only() -> void:
	# ww_roc2 dropoff: g_e=1 (AP), health 100, invincible_finished 11
	var capturer := _make_player(1)
	var teammate := _make_player(1)
	var g := _make_goal()
	g.goal_effects = TFGoalBaseScript.GE_AP
	g.heal_amount = 100
	g.invincible_time = 11.0
	g._apply_player_effects(capturer)
	assert_gt(capturer.invincible_until, _now() + 10.0, "capturer granted ~11s invincibility")
	assert_eq(teammate.invincible_until, 0.0, "teammate not granted invincibility")
	g.free()
	capturer.free()
	teammate.free()


func test_death_cloud_spares_invincible_capturer() -> void:
	# ww_roc2 gaswarnr: g_e=32, team_no=0, health -5000 → kills every player;
	# the capturer survives only via the dropoff's invincibility.
	var capturer := _make_player(1)
	var teammate := _make_player(1)
	var enemy := _make_player(2)
	capturer.invincible_until = _now() + 11.0
	var g := _make_goal()
	g.goal_effects = TFGoalBaseScript.GE_SAME_ENVIRONMENT
	g.req_team = 0
	g.heal_amount = -5000
	g._apply_player_effects(capturer)
	assert_false(capturer.is_dead, "invincible capturer survives the death cloud")
	assert_true(teammate.is_dead, "teammate dies to the death cloud")
	assert_true(enemy.is_dead, "enemy dies to the death cloud")
	g.free()
	capturer.free()
	teammate.free()
	enemy.free()


func _make_water_goal(goal_y: float) -> Node:
	var g: Node3D = WaterStubGoal.new()
	_root().add_child(g)
	g.global_position = Vector3(0, goal_y, 0)
	g.goal_effects = TFGoalBaseScript.GE_SAME_ENVIRONMENT
	g.req_team = 0
	g.heal_amount = -5000
	return g


func test_death_cloud_spares_players_underwater() -> void:
	# TFGE_SAME_ENVIRONMENT: an in-air gas goal must not affect players in water.
	var swimmer := _make_player(1)
	var walker := _make_player(2)
	swimmer.global_position = Vector3(0, -2.0, 0)  # below y=0 → "in water"
	walker.global_position = Vector3(0, 2.0, 0)
	var g := _make_water_goal(2.0)  # goal in air
	g._apply_player_effects(null)
	assert_false(swimmer.is_dead, "underwater player spared by in-air death cloud")
	assert_true(walker.is_dead, "in-air player dies to in-air death cloud")
	g.free()
	swimmer.free()
	walker.free()


func test_underwater_goal_only_affects_underwater_players() -> void:
	var swimmer := _make_player(1)
	var walker := _make_player(2)
	swimmer.global_position = Vector3(0, -2.0, 0)
	walker.global_position = Vector3(0, 2.0, 0)
	var g := _make_water_goal(-2.0)  # goal underwater
	g._apply_player_effects(null)
	assert_true(swimmer.is_dead, "underwater player affected by underwater goal")
	assert_false(walker.is_dead, "in-air player spared by underwater goal")
	g.free()
	swimmer.free()
	walker.free()


func test_goal_awards_frags_to_activator() -> void:
	# ww_leyline node captures: g_e=1, frags=1 → personal score for the capturer
	var p := _make_player(1)
	p.peer_id = 4242
	var g := _make_goal()
	g.goal_effects = TFGoalBaseScript.GE_AP
	g.frags_amount = 2
	g._apply_player_effects(p)
	assert_eq(GoalSystem.get_kills(4242), 2, "frags folded into the activator's score")
	GoalSystem.player_kills.erase(4242)
	g.free()
	p.free()


func test_parse_reads_speak_and_frags() -> void:
	var g := _make_goal()
	g._parse_tf_properties({
		"speak": "ambience/siren",
		"AP_speak": "you have the enemy key",
		"team_speak": "your team has the key",
		"frags": "1",
	})
	assert_eq(g.spk_all, "ambience/siren", "speak parsed")
	assert_eq(g.spk_ap, "you have the enemy key", "AP_speak parsed")
	assert_eq(g.spk_team, "your team has the key", "team_speak parsed")
	assert_eq(g.frags_amount, 1, "frags parsed")
	g.free()


func test_player_display_name_lookup() -> void:
	var p := _make_player(1)
	p.peer_id = 555
	NetworkManager.set_player_name(555, "Zork")
	assert_eq(TFGoalBaseScript._player_display_name(p), "Zork", "name from NetworkManager registry")
	assert_eq("%s escaped home!".replace("%s", TFGoalBaseScript._player_display_name(p)),
		"Zork escaped home!", "%s substitution")
	NetworkManager.drop_peer_state(555)
	p.free()
