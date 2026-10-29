extends "res://src/tests/test_base.gd"
## Bot auto-balance must honour per-team player caps. ww_hunt's team 1 is one slot wide and
## civilian-only, so it is permanently the smallest team — the balancer kept stacking bots on
## it and the class restriction made every one of them an Archmage.
##
## References the GoalSystem / SpawnSystem / NetworkManager autoloads, so it must run via the
## scene runner, not `-s`.

const Team := GameConsts.Team

# Stand-in for a puppet: GoalSystem._counted_team reads these two fields.
class FakePlayer:
	extends Node
	var team: int = 0
	var class_change_pending_team: int = -1

# Stand-in for info_player_teamspawn: SpawnSystem reads team_no/goal_no/group_no.
class FakeSpawn:
	extends Node3D
	var team_no: int = 0
	var goal_no: int = 0
	var group_no: int = 0


var _saved_cache: Dictionary
var _saved_spawns: Array[Node3D]
var _saved_limits: Array[int]
var _saved_team_count: int


func _setup_test(_test_name: String) -> void:
	_saved_cache = NetworkManager.swap_roster()
	_saved_spawns = SpawnSystem._spawns.duplicate()
	_saved_limits = GoalSystem.team_max_players.duplicate()
	_saved_team_count = GoalSystem.team_count
	SpawnSystem._spawns.clear()
	GoalSystem.team_max_players = [0, 0, 0, 0]
	GoalSystem.team_count = 2
	_spawned.clear()


func _teardown_test() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	NetworkManager.swap_roster(_saved_cache)
	SpawnSystem._spawns = _saved_spawns
	GoalSystem.team_max_players = _saved_limits
	GoalSystem.team_count = _saved_team_count


func _add_spawn(team: int) -> void:
	var s := FakeSpawn.new()
	s.team_no = team
	_spawned.append(s)
	SpawnSystem._spawns.append(s)


func _add_player(peer: int, team: int) -> void:
	var p := FakePlayer.new()
	p.team = team
	_spawned.append(p)
	NetworkManager.register_player(peer, p)


func test_balance_picks_smallest_team() -> void:
	_add_spawn(Team.BLUE)
	_add_spawn(Team.RED)
	_add_player(1, Team.BLUE)
	assert_eq(BotSystem._auto_balance_team(), Team.RED, "empty team wins")


func test_balance_skips_full_team() -> void:
	# ww_hunt's shape: team 1 caps at one player and already has them.
	_add_spawn(Team.BLUE)
	_add_spawn(Team.RED)
	GoalSystem.team_max_players[Team.BLUE - 1] = 1
	_add_player(1, Team.BLUE)
	assert_eq(BotSystem._auto_balance_team(), Team.RED, "capped team skipped")


func test_balance_prefers_bigger_team_when_small_one_is_capped() -> void:
	# The capped team stays the smallest forever; balance must still walk past it.
	_add_spawn(Team.BLUE)
	_add_spawn(Team.RED)
	GoalSystem.team_max_players[Team.BLUE - 1] = 1
	_add_player(1, Team.BLUE)
	_add_player(2, Team.RED)
	_add_player(3, Team.RED)
	assert_eq(BotSystem._auto_balance_team(), Team.RED, "full-but-smallest team not picked")
