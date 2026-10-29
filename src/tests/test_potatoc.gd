extends "res://src/tests/test_base.gd"
## Tests for the PotatoC interpreter (potatoc.gd) — "firing" map scripts — and the
## GivePoints scoring path it drives via GoalSystem.add_player_points.
## Each test gets a fresh interpreter and clean global state.

const PotatoCEntityScript = preload("res://src/entities/potatoc_entity.gd")

var _interp: PotatoC
var _fired: Array = []      # captured function calls: {name, a1, a2}
var _score_peer := 7        # peer the GivePoints handler awards to


# Stand-in for a player node used by the entity handlers under test.
class FakePlayer extends Node:
	var peer_id := 0
	var element := 0
	var plants := PlantBehavior.new()


## Stands in for a Thornplant: remove_all() only asks it to destroy itself.
class FakePlant extends Node3D:
	func destroy_plant() -> void:
		pass


func _setup_test(_test_name: String) -> void:
	_interp = PotatoC.new()
	_interp.function_handler = _handler
	_fired = []
	# Reset shared/static state so tests don't bleed into each other.
	PotatoC.global_vars.clear()
	GoalSystem.player_kills.clear()
	GoalSystem.player_deaths.clear()


# Function handler that mimics potatoc_entity dispatch: records every call and,
# for GivePoints(amount), awards points to _score_peer (folds into frags).
func _handler(app, local_vars) -> int:
	var a1: String = _interp.get_string_arg(app.app1, local_vars)
	var a2: String = _interp.get_string_arg(app.app2, local_vars)
	_fired.append({"name": app.str_val, "a1": a1, "a2": a2})
	if app.str_val == "GivePoints":
		GoalSystem.add_player_points(_score_peer, int(a1))
	return 0


func _fire(code: String) -> void:
	_interp.parse_code(code)
	_interp.execute()


func test_fire_invokes_handler() -> void:
	_fire("Trigger('door');")
	assert_eq(_fired.size(), 1, "one call fired")
	assert_eq(_fired[0]["name"], "Trigger", "function name dispatched")


func test_fire_passes_string_arg() -> void:
	_fire("Say('hello');")
	assert_eq(_fired[0]["a1"], "hello", "string literal arg passed through")


func test_fire_evaluates_numeric_arg() -> void:
	# Arg is an expression — interpreter must evaluate it before the handler sees it.
	_fire("F(2+3);")
	assert_eq(_fired[0]["a1"], "5", "numeric expression arg evaluated to 5")


func test_fire_two_args() -> void:
	_fire("GiveTeamPoints(2,30);")
	assert_eq(_fired[0]["a1"], "2", "first arg")
	assert_eq(_fired[0]["a2"], "30", "second arg")


func test_multiple_statements_fire_in_order() -> void:
	_fire("A('x');B('y');")
	assert_eq(_fired.size(), 2, "both statements fired")
	assert_eq(_fired[0]["name"], "A", "first in order")
	assert_eq(_fired[1]["name"], "B", "second in order")


func test_if_true_fires_body() -> void:
	_fire("if(1)[Fire('yes')]")
	assert_eq(_fired.size(), 1, "true condition runs body")
	assert_eq(_fired[0]["a1"], "yes", "body executed")


func test_if_false_skips_body() -> void:
	_fire("if(0)[Fire('no')]")
	assert_eq(_fired.size(), 0, "false condition skips body")


func test_while_repeats_body() -> void:
	# Loop three times, firing Tick() each iteration.
	PotatoC.global_vars["i"] = 0
	_fire("while(i<3)[Tick();i=i+1]")
	assert_eq(_fired.size(), 3, "while body fired once per iteration")
	assert_eq(PotatoC.global_vars["i"], 3, "loop counter advanced to bound")


func test_assign_and_arithmetic() -> void:
	# clean() converts '=' to ':'; assignment stores into the global.
	PotatoC.global_vars["score"] = 0
	_fire("score=3+4;")
	assert_eq(PotatoC.global_vars["score"], 7, "assignment evaluated arithmetic into global")


# A comparison must bind tighter than && / ||: `a<b&&c` used to group as `a < (b && c)`.
func test_comparison_binds_tighter_than_and() -> void:
	# Both cases below separate the two groupings, in opposite directions.
	# (5<9) && 1 is true, while the old 5 < (9&&1) = 5 < 1 is false.
	PotatoC.global_vars["a"] = 5
	_fire("if(a<9&&1)[Fire('t')]")
	assert_eq(_fired.size(), 1, "(5<9) && 1 holds")
	_fired.clear()
	# (-5<9) && 0 is false, while the old -5 < (9&&0) = -5 < 0 is true.
	PotatoC.global_vars["a"] = -5
	_fire("if(a<9&&0)[Fire('f')]")
	assert_eq(_fired.size(), 0, "(-5<9) && 0 does not hold")


func test_negative_literal_on_the_right_of_a_comparison() -> void:
	PotatoC.global_vars["x"] = -64
	_fire("if(x<-400)[Fire('deep')]")
	assert_eq(_fired.size(), 0, "-64 is not < -400")
	_fired.clear()
	PotatoC.global_vars["x"] = -900
	_fire("if(x<-400)[Fire('deep')]")
	assert_eq(_fired.size(), 1, "-900 is < -400")


func test_comparison_binds_looser_than_arithmetic() -> void:
	# `a+b<c` must group as `(a+b) < c`, not `a + (b<c)`.
	PotatoC.global_vars["a"] = 2
	PotatoC.global_vars["b"] = 3
	_fire("if(a+b<4)[Fire('lt')]")
	assert_eq(_fired.size(), 0, "(2+3) < 4 is false — not 2 + (3<4) = 3, which is truthy")


func test_equality_chain_across_and() -> void:
	# ww_chasm's control-point guards look like this. They worked before and must
	# keep working: && still splits ahead of == and !=.
	PotatoC.global_vars["temp"] = 1
	PotatoC.global_vars["point1"] = 1
	PotatoC.global_vars["point2"] = 0
	_fire("if(temp==1&&point2!=1&&point1==1)[Fire('cap')]")
	assert_eq(_fired.size(), 1, "all three clauses hold")
	_fired.clear()
	PotatoC.global_vars["point1"] = 2
	_fire("if(temp==1&&point2!=1&&point1==1)[Fire('cap')]")
	assert_eq(_fired.size(), 0, "the last clause fails, so the chain fails")


func test_golem_spawncheck_gate() -> void:
	# ww_golem's spawn-group check, verbatim: the golem's start position is nowhere near
	# either base, so neither team's forward spawns may open.
	PotatoC.global_vars["x"] = -64
	PotatoC.global_vars["y"] = -2576
	_fire("if(x<-400&&y>-1200)[Fire('blue')]if(x>400&&y>-1200)[Fire('red')]")
	assert_eq(_fired.size(), 0, "a golem at its start position opens no forward spawns")
	_fired.clear()
	# Pushed deep into the -x base and north past the gate: blue's group opens.
	PotatoC.global_vars["x"] = -1100
	PotatoC.global_vars["y"] = 200
	_fire("if(x<-400&&y>-1200)[Fire('blue')]if(x>400&&y>-1200)[Fire('red')]")
	assert_eq(_fired.size(), 1, "one side's gate opened")
	assert_eq(_fired[0]["a1"], "blue", "and it is the -x side's")


func test_fire_givepoints_awards_player() -> void:
	assert_eq(GoalSystem.get_kills(_score_peer), 0, "starts at zero")
	_fire("GivePoints(2);")
	assert_eq(GoalSystem.get_kills(_score_peer), 2, "GivePoints(2) folds 2 into the player's frags")


func test_givepoints_accumulates() -> void:
	_fire("GivePoints(2);")
	_fire("GivePoints(10);")
	assert_eq(GoalSystem.get_kills(_score_peer), 12, "successive awards accumulate")


func test_add_player_points_ignores_zero() -> void:
	GoalSystem.add_player_points(_score_peer, 0)
	assert_false(GoalSystem.player_kills.has(_score_peer), "zero points is a no-op (no entry created)")


func test_add_player_points_ignores_invalid_peer() -> void:
	# A non-player activator resolves to peer_id 0 — must not score or crash.
	GoalSystem.add_player_points(0, 5)
	assert_eq(GoalSystem.get_kills(0), 0, "invalid peer awarded nothing")


func test_add_player_points_scores_bots() -> void:
	# Bots use negative synthetic peer ids and DO earn objective points (like record_kill).
	GoalSystem.add_player_points(-3, 5)
	assert_eq(GoalSystem.get_kills(-3), 5, "bot (negative peer id) awarded points")


func test_node_peer_id_reads_player_id() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	var player := FakePlayer.new()
	player.peer_id = 5
	assert_eq(pe.node_peer_id(player), 5, "player node resolves to its peer_id")
	player.free()
	pe.free()


func test_node_peer_id_non_player_is_zero() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	var plain := Node.new()  # no peer_id field
	assert_eq(pe.node_peer_id(plain), 0, "non-player node resolves to 0")
	plain.free()
	pe.free()


func test_node_peer_id_null_is_zero() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	assert_eq(pe.node_peer_id(null), 0, "null activator resolves to 0")
	pe.free()


func test_max_players_returns_server_cap() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	assert_eq(pe._fn_max_players("", ""), NetworkManager.MAX_CLIENTS,
		"MaxPlayers returns the real server cap, not a guessed constant")
	pe.free()


func test_ap_class_returns_user_element() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	var player := FakePlayer.new()
	player.element = 3
	pe._user = player
	assert_eq(pe._fn_ap_class("", ""), 3, "APClass returns the activator's element")
	player.free()
	pe.free()


func test_ap_class_no_user_returns_zero() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	pe._user = null
	assert_eq(pe._fn_ap_class("", ""), 0, "APClass with no activator returns 0")
	pe.free()


func test_remove_plants_clears_each_player() -> void:
	var pe: PotatoCEntity = PotatoCEntityScript.new()
	var player := FakePlayer.new()
	NetworkManager.register_player(999, player)
	player.plants.initialize(player)
	var plant := FakePlant.new()
	player.plants.thornplant = plant
	pe._fn_remove_plants("", "")
	assert_false(player.plants.has_thornplant, "RemovePlants clears each cached player's plants")
	NetworkManager.unregister_player(999)
	plant.free()
	player.free()
	pe.free()
