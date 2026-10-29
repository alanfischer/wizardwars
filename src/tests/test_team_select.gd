extends "res://src/tests/test_base.gd"
## Team-occupancy counting that backs team-join limits (GoalSystem). A class/team change reserves
## the destination team's slot for the whole respawn delay even though `team` only flips on
## respawn, so the count must follow `class_change_pending_team` while a change is in flight
## (the ww_hunt "2 players on a 1-slot team" bug).
##
## References the GoalSystem / NetworkManager autoloads, so it must run via the scene runner, not `-s`.

const Team := GameConsts.Team
const PlayerScript = preload("res://src/player.gd")
const ServerRequests = preload("res://src/systems/server_requests.gd")

# Stand-in for a remote puppet: has `team` and the `class_change_pending_team` field
# that GoalSystem._counted_team reads.
class FakeRemote:
	extends Node
	var team: int = 0
	var class_change_pending_team: int = -1

# Stand-in for a roster node with no pending field at all — exercises the `.get() == null`
# fallback in _counted_team.
class FakeNoPending:
	extends Node
	var team: int = 0


# Catches the refusal. The message itself is main's job now (main._on_reject_team_join), so
# what the transport owes a rejected joiner is this dispatch, with the team and the reason on it.
class RejectSpy:
	extends Node
	var got: Array = []
	func _on_reject_team_join(team: int, reason: String) -> void:
		got.append([team, reason])


var _saved_cache: Dictionary
var _saved_peers: Dictionary
var _saved_limits: Array[int]


func _setup_test(_test_name: String) -> void:
	# Snapshot the autoload state we mutate, run on a clean slate, then restore.
	_saved_cache = NetworkManager.swap_roster()
	_saved_limits = GoalSystem.team_max_players.duplicate()
	_saved_peers = NetworkManager.swap_peer_table()
	GoalSystem.team_max_players = [0, 0, 0, 0]
	_spawned.clear()


func _teardown_test() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	NetworkManager.swap_roster(_saved_cache)
	NetworkManager.swap_peer_table(_saved_peers)
	GoalSystem.team_max_players = _saved_limits


## Registered as the sync handler, which _dispatch_to_scene prefers over current_scene — so the
## test runner's own scene is left alone.
func _reject_spy() -> RejectSpy:
	var spy := _keep(RejectSpy.new()) as RejectSpy
	_root().add_child(spy)
	NetworkManager.register_sync_handler(spy)
	return spy


func _add_remote(peer: int, team: int, pending := -1) -> void:
	var p := FakeRemote.new()
	p.team = team
	p.class_change_pending_team = pending
	_spawned.append(p)
	NetworkManager.register_player(peer, p)


## A real Player, which ServerRequests.join_team needs: get_player() is typed `-> Player` and
## hands back null for a FakeRemote, skipping the very lines these tests drive.
func _add_player(peer: int) -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	_root().add_child(p)
	_spawned.append(p)
	NetworkManager.register_player(peer, p)
	return p


func _add_no_pending(peer: int, team: int) -> void:
	var p := FakeNoPending.new()
	p.team = team
	_spawned.append(p)
	NetworkManager.register_player(peer, p)


func _set_limit(team: int, limit: int) -> void:
	GoalSystem.team_max_players[team - 1] = limit


func test_counts_players_by_team() -> void:
	_add_remote(1, Team.BLUE)
	_add_remote(2, Team.BLUE)
	_add_remote(3, Team.RED)
	assert_eq(GoalSystem.get_team_player_count(Team.BLUE), 2, "two on blue")
	assert_eq(GoalSystem.get_team_player_count(Team.RED), 1, "one on red")


func test_pending_joiner_counts_toward_destination() -> void:
	# On Red but mid-change to Blue: counts as Blue while the change is in flight.
	_add_remote(1, Team.RED, Team.BLUE)
	assert_eq(GoalSystem.get_team_player_count(Team.BLUE), 1, "pending counts toward blue")


func test_pending_joiner_leaves_origin_team() -> void:
	_add_remote(1, Team.RED, Team.BLUE)
	assert_eq(GoalSystem.get_team_player_count(Team.RED), 0, "no longer counted on red")


func test_a_node_without_pending_counts_by_team() -> void:
	# A node lacking class_change_pending_team must fall back to plain `team`.
	_add_no_pending(1, Team.RED)
	assert_eq(GoalSystem.get_team_player_count(Team.RED), 1, "counts by plain team")
	assert_eq(GoalSystem.get_team_player_count(Team.BLUE), 0)


## A client only has puppet bodies for peers inside its own PVS, so counting bodies alone showed a
## spectator sitting at the team menu "0/1" for a team the host was already about to refuse them
## from. The roster is PVS-independent and must back the count.
func test_counts_roster_peers_without_a_local_body() -> void:
	NetworkManager.set_player_team(1, Team.BLUE)  # host, out of our PVS: no puppet here
	assert_eq(GoalSystem.get_team_player_count(Team.BLUE), 1, "bodiless peer still occupies a slot")


func test_live_body_wins_over_roster() -> void:
	# The roster only updates on a completed join; the body carries the pending change.
	NetworkManager.set_player_team(1, Team.RED)
	_add_remote(1, Team.RED, Team.BLUE)
	assert_eq(GoalSystem.get_team_player_count(Team.BLUE), 1, "pending change beats the roster")
	assert_eq(GoalSystem.get_team_player_count(Team.RED), 0, "…and vacates the old team")


func test_team_full_at_limit() -> void:
	_set_limit(Team.BLUE, 1)
	_add_remote(1, Team.BLUE)
	assert_true(GoalSystem.is_team_full(Team.BLUE), "blue at limit 1")


func test_team_full_blocks_when_pending_joiner_fills_slot() -> void:
	# Regression for the ww_hunt "2 on blue" bug: a player mid-change to Blue reserves
	# Blue's only slot, so is_team_full must reject a second joiner during the delay.
	_set_limit(Team.BLUE, 1)
	_add_remote(1, Team.RED, Team.BLUE)  # reserving Blue's slot
	assert_true(GoalSystem.is_team_full(Team.BLUE), "blue full via pending joiner")


func test_team_not_full_below_limit() -> void:
	_set_limit(Team.BLUE, 2)
	_add_remote(1, Team.BLUE)
	assert_false(GoalSystem.is_team_full(Team.BLUE), "1/2 is not full")


func test_team_unlimited_when_limit_zero() -> void:
	_set_limit(Team.BLUE, 0)
	_add_remote(1, Team.BLUE)
	_add_remote(2, Team.BLUE)
	assert_false(GoalSystem.is_team_full(Team.BLUE), "limit 0 = unlimited")


## Spawns toggle off on control maps. A join the host can't place must commit nothing: the old
## code set `team` first and only then looked for a spawn, so a failed join left the peer
## recorded on a team, streaming and rendering a body that never spawned, with the client stuck
## in the spectator cam and no reply telling it to try again.
##
## Uses a real Player, not FakeRemote — get_player() is typed `-> Player` and hands back null for
## anything else, which would skip the very line under test.
func test_join_without_a_spawn_commits_nothing() -> void:
	var p := _add_player(7)
	# No map is loaded in the test suite, so SpawnSystem has no spawn for any team.
	assert_true(SpawnSystem.get_spawn_for_team(Team.BLUE) == null, "precondition: no spawns")

	ServerRequests.join_team(7, Team.BLUE, GameConsts.Element.FIRE)

	assert_eq(p.team, Team.NONE, "a join that can't spawn leaves the player teamless")
	assert_eq(NetworkManager.get_player_team(7), Team.NONE, "…and out of the roster")


## Map change: the new map re-spawns everyone as a teamless spectator who must re-pick, so the
## PVS-independent roster has to reset with it. It didn't, and the scoreboard — which falls back to
## the roster for any peer without a live body (the reload window, bodiless bots) — kept showing
## players on the team they held on the PREVIOUS map, before they had joined anything.
func test_map_change_clears_team_roster() -> void:
	NetworkManager.set_player_name(7, "Wizard")
	NetworkManager.set_player_team(7, Team.BLUE)

	NetworkManager.clear_players()  # what main._unload_map calls on a map change

	assert_eq(NetworkManager.get_player_team(7), Team.NONE, "map change leaves nobody on a team")
	assert_true(NetworkManager.has_player_name(7), "…but identity survives the change")


## Every refusal in ServerRequests.join_team answers the asker — a bare return left them a
## spectator with the class menu already dismissed and nothing on screen. Offline, send_to_owner
## takes its local branch, which is the same path the listen host's own rejection takes.
func test_a_refused_join_tells_the_asker_why() -> void:
	var spy := _reject_spy()
	_add_player(7)
	assert_true(SpawnSystem.get_spawn_for_team(Team.BLUE) == null, "precondition: no spawns")

	ServerRequests.join_team(7, Team.BLUE, GameConsts.Element.FIRE)

	assert_eq(spy.got.size(), 1, "the refusal was answered, not swallowed")
	assert_eq(spy.got[0][0], Team.BLUE, "with the team that was asked for")
	assert_eq(spy.got[0][1], "has no spawn point", "and the reason, which the HUD prints")


## The reason is the asker's only explanation, so the branch that fires has to be the true one.
## No map is loaded here, so every join is also spawnless — a full team must still read "is full".
func test_a_full_team_is_refused_as_full_not_as_spawnless() -> void:
	var spy := _reject_spy()
	_set_limit(Team.BLUE, 1)
	_add_remote(1, Team.BLUE)  # takes the only slot
	_add_player(7)

	ServerRequests.join_team(7, Team.BLUE, GameConsts.Element.FIRE)

	assert_eq(spy.got.size(), 1, "a full team answers the asker")
	assert_eq(spy.got[0][1], "is full", "with the reason that actually stopped the join")
