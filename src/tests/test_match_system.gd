extends "res://src/tests/test_base.gd"
## Match flow: what ends a map, who won, and what loads next.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const PlayerScript = preload("res://src/player.gd")

const CYCLE_PATH := "user://test_mapcycle.txt"


func _teardown_test() -> void:
	_cleanup()


func _limits(timelimit: int, scorelimit: int, fraglimit := 0) -> void:
	ServerVars.set_from_string("timelimit", str(timelimit))
	ServerVars.set_from_string("scorelimit", str(scorelimit))
	ServerVars.set_from_string("fraglimit", str(fraglimit))


## A cycle file of our own, so the assertions don't move when maps/mapcycle.txt is edited.
func _write_cycle(lines: Array) -> void:
	var f := FileAccess.open(CYCLE_PATH, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	MatchSystem.load_cycle(CYCLE_PATH)


## Two shipped maps, whichever they are — the cycle drops names that aren't installed, so a test
## about ordering has to be built out of maps this checkout actually has.
func _installed(count: int) -> Array:
	return MapConverter.list_maps().slice(0, count)


func _player() -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	p.team = 1
	_root().add_child(p)
	p.set_damageable(true)
	_spawned.append(p)
	return p


func _cleanup() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()
	MatchSystem.reset()
	MatchSystem.set_next_map("")
	GoalSystem.reset()
	NetworkManager.swap_peer_table()
	_limits(20, 0, 0)
	if FileAccess.file_exists(CYCLE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CYCLE_PATH))
	MatchSystem.load_cycle()


# --- What ends a match ----------------------------------------------------

## The one hook: every scoring path in the game lands in GoalSystem.add_score.
func test_the_score_limit_ends_the_match() -> void:
	_limits(0, 3)
	var maps := _installed(2)
	_write_cycle(maps)
	MatchSystem.begin_map(maps[0])
	GoalSystem.add_score(1, 2)
	assert_false(MatchSystem.is_intermission(), "two points of three is still a match")
	GoalSystem.add_score(1, 1)
	assert_true(MatchSystem.is_intermission(), "the third ends it")
	assert_eq(MatchSystem.winner_team, 1, "the team that reached the limit won")
	assert_eq(MatchSystem.end_reason, "score", "and it says why")


## A goal still ticking over after the whistle must not move the final board.
func test_scoring_stops_once_the_match_is_over() -> void:
	_limits(0, 2)
	MatchSystem.begin_map(_installed(1)[0])
	GoalSystem.add_score(1, 2)
	GoalSystem.add_score(2, 5)
	assert_eq(GoalSystem.get_score(2), 0, "the losing team can't score during the intermission")
	assert_eq(MatchSystem.winner_team, 1, "and the winner doesn't change")


## The clock is checked on the tick, against absolute server time — so a test can move the
## deadline instead of waiting out a 20-minute match.
func test_the_clock_ends_the_match() -> void:
	_limits(20, 0)
	MatchSystem.begin_map(_installed(1)[0])
	assert_gt(MatchSystem.time_left(), 1190.0, "20 minutes on the clock")
	MatchSystem._physics_process(0.0)
	assert_false(MatchSystem.is_intermission(), "nothing happens while there's time left")
	MatchSystem.match_end_ms = Time.get_ticks_msec() - 1
	MatchSystem._physics_process(0.0)
	assert_true(MatchSystem.is_intermission(), "the tick ends it when the deadline passes")
	assert_eq(MatchSystem.end_reason, "time", "on time, not score")


func test_no_time_limit_means_no_clock() -> void:
	_limits(0, 0)
	MatchSystem.begin_map(_installed(1)[0])
	assert_eq(MatchSystem.match_end_ms, 0, "nothing to count down to")
	assert_eq(MatchSystem.time_left(), -1.0, "and nothing to report")
	MatchSystem._physics_process(0.0)
	assert_false(MatchSystem.is_intermission(), "a match without limits runs forever")


## Changing the limit mid-match restarts the clock rather than ending a match retroactively.
func test_raising_the_limit_mid_match_restarts_the_clock() -> void:
	_limits(20, 0)
	MatchSystem.begin_map(_installed(1)[0])
	MatchSystem.match_end_ms = Time.get_ticks_msec() + 1000
	_limits(30, 0)
	assert_gt(MatchSystem.time_left(), 1790.0, "the new limit runs from now")
	assert_false(MatchSystem.is_intermission(), "and nothing ended on the way past")


func test_a_level_score_is_a_draw() -> void:
	_limits(20, 0)
	MatchSystem.begin_map(_installed(1)[0])
	GoalSystem.add_score(1, 4)
	GoalSystem.add_score(2, 4)
	MatchSystem.end_match("time")
	assert_true(MatchSystem.is_intermission(), "time's up either way")
	assert_eq(MatchSystem.winner_team, 0, "nobody leads outright")
	assert_true("Draw" in MatchSystem.result_text(), "and the banner says so")


func test_the_banner_names_the_winner_and_what_is_next() -> void:
	var maps := _installed(2)
	_write_cycle(maps)
	_limits(0, 1)
	GoalSystem.team_names = ["Blue", "Red", "", ""]
	MatchSystem.begin_map(maps[0])
	GoalSystem.add_score(2, 1)
	var text := MatchSystem.result_text()
	assert_true("Red wins!" in text, "the team's own name, not a number: %s" % text)
	assert_true(maps[1] in text, "and where everyone is going next: %s" % text)


# --- What the intermission stops -------------------------------------------

func test_nobody_can_be_shot_off_the_final_scoreboard() -> void:
	_limits(0, 1)
	MatchSystem.begin_map(_installed(1)[0])
	var p := _player()
	p.health = 100.0
	p.take_damage(10.0)
	assert_eq(p.health, 90.0, "damage lands during the match")
	GoalSystem.add_score(1, 1)
	p.take_damage(10.0)
	assert_eq(p.health, 90.0, "and stops once the match is over")


# --- The rotation ----------------------------------------------------------

func test_the_cycle_reads_a_file_and_skips_what_is_not_installed() -> void:
	var maps := _installed(2)
	_write_cycle([
		"# a comment line",
		"",
		maps[0] + "   # trailing comment",
		"ww_not_a_real_map",
		maps[1],
		maps[0],  # duplicate
	])
	assert_eq(MatchSystem.cycle(), maps, "comments, blanks, dupes and missing maps all dropped")


func test_the_cycle_wraps() -> void:
	var maps := _installed(3)
	_write_cycle(maps)
	MatchSystem.begin_map(maps[0])
	assert_eq(MatchSystem.peek_next_map(), maps[1], "the next line")
	MatchSystem.begin_map(maps[2])
	assert_eq(MatchSystem.peek_next_map(), maps[0], "and round to the top from the bottom")


## An admin's /map is a detour, not a new starting point: the rotation picks up where it was.
func test_a_map_outside_the_cycle_leaves_the_rotation_alone() -> void:
	var maps := _installed(3)
	_write_cycle([maps[0], maps[1]])
	MatchSystem.begin_map(maps[0])
	MatchSystem.begin_map(maps[2])  # not in the cycle
	assert_eq(MatchSystem.peek_next_map(), maps[1], "still the entry after the one we were on")


func test_nextmap_overrides_the_rotation() -> void:
	var maps := _installed(3)
	_write_cycle([maps[0], maps[1]])
	MatchSystem.begin_map(maps[0])
	assert_true(MatchSystem.set_next_map(maps[2]), "a map that exists is accepted")
	assert_eq(MatchSystem.peek_next_map(), maps[2], "and takes precedence")
	assert_false(MatchSystem.set_next_map("ww_not_a_real_map"), "one that doesn't is refused")
	assert_eq(MatchSystem.peek_next_map(), maps[2], "leaving the override standing")
	MatchSystem.set_next_map("")
	assert_eq(MatchSystem.peek_next_map(), maps[1], "and clearing hands the turn back")


func test_an_unreadable_cycle_falls_back_to_the_installed_maps() -> void:
	MatchSystem.load_cycle("user://no_such_mapcycle.txt")
	assert_eq(MatchSystem.cycle(), MapConverter.list_maps(), "everything installed, alphabetically")
	assert_false(MatchSystem.cycle().is_empty(), "which is never nothing")


# --- What carries across a map change --------------------------------------

## main hands this back to BotSystem on the new map — a rotation that dropped it would leave a
## bot server empty from the second map on.
func test_the_bot_roster_survives_as_the_arguments_that_rebuild_it() -> void:
	BotSystem._roster = {
		-1: {name = "Bot1", element = GameConsts.Element.FIRE, team = 1, pos = Vector3.ZERO, yaw = 0.0},
		-2: {name = "Bot2", element = GameConsts.Element.ICE, team = 2, pos = Vector3.ZERO, yaw = 0.0},
	}
	var snapshot := BotSystem.roster_snapshot()
	assert_eq(snapshot.size(), 2, "both bots")
	assert_eq(snapshot[0]["element"], GameConsts.Element.FIRE, "keeping their class")
	assert_eq(snapshot[1]["team"], 2, "and their team")
	BotSystem._roster.clear()
	assert_true(BotSystem.roster_snapshot().is_empty(), "and nothing lingers once they're gone")


# --- The frag limit --------------------------------------------------------

## A deathmatch map has no teams to win, so the frag limit ends on the player and names them.
func test_the_frag_limit_ends_the_match_on_a_player() -> void:
	_limits(0, 0, 3)
	NetworkManager.set_player_name(7, "Merlin")
	MatchSystem.begin_map(_installed(1)[0])
	for i in 2:
		GoalSystem.record_kill(7, 8)
	assert_false(MatchSystem.is_intermission(), "two frags of three is still a match")
	GoalSystem.record_kill(7, 8)
	assert_true(MatchSystem.is_intermission(), "the third ends it")
	assert_eq(MatchSystem.end_reason, "frags", "and says why")
	assert_eq(MatchSystem.winner_name, "Merlin", "the player, not a team")
	assert_true("Merlin wins!" in MatchSystem.result_text(), "which is what the banner reads")


## Objective points share the scoreboard column with frags, so they count the same.
func test_objective_points_count_toward_the_frag_limit() -> void:
	_limits(0, 0, 5)
	NetworkManager.set_player_name(7, "Merlin")
	MatchSystem.begin_map(_installed(1)[0])
	GoalSystem.record_kill(7, 8)
	GoalSystem.add_player_points(7, 4)
	assert_true(MatchSystem.is_intermission(), "one frag plus four points is five")


func test_a_suicide_is_not_a_frag() -> void:
	_limits(0, 0, 1)
	MatchSystem.begin_map(_installed(1)[0])
	GoalSystem.record_kill(7, 7)
	GoalSystem.record_kill(0, 8)  # the world (a fall, lava)
	assert_false(MatchSystem.is_intermission(), "neither counts toward the limit")


# --- The intermission vote -------------------------------------------------

func _four_map_intermission() -> Array:
	var maps := _installed(4)
	_write_cycle(maps)
	MatchSystem.begin_map(maps[0])
	MatchSystem.end_match("time")
	return maps


func test_the_intermission_offers_the_next_maps_in_the_rotation() -> void:
	var maps := _four_map_intermission()
	assert_eq(MatchSystem.vote_candidates.size(), MatchSystem.VOTE_CANDIDATES, "three to choose from")
	assert_eq(Array(MatchSystem.vote_candidates), maps.slice(1, 4), "the maps that come next")
	assert_false(maps[0] in Array(MatchSystem.vote_candidates), "never the one just played")
	assert_eq(MatchSystem.next_map, maps[1], "and the rotation's own pick leads until anyone votes")


func test_a_vote_moves_the_leader() -> void:
	var maps := _four_map_intermission()
	assert_eq(MatchSystem.cast_vote(2, 3), maps[3], "the ballot answers with what was picked")
	assert_eq(MatchSystem.next_map, maps[3], "one vote is enough to lead")
	assert_eq(Array(MatchSystem.vote_tallies()), [0, 0, 1], "counted against the right option")
	MatchSystem.cast_vote(3, 2)
	MatchSystem.cast_vote(4, 2)
	assert_eq(MatchSystem.next_map, maps[2], "two beats one")


## One vote each: voting again moves your vote instead of stacking another.
func test_a_second_vote_replaces_the_first() -> void:
	var maps := _four_map_intermission()
	MatchSystem.cast_vote(2, 3)
	MatchSystem.cast_vote(2, 2)
	assert_eq(Array(MatchSystem.vote_tallies()), [0, 1, 0], "one voter, one vote")
	assert_eq(MatchSystem.next_map, maps[2], "and the leader follows it")


## A tie goes to the earliest option — which is the map the rotation was going to play anyway, so
## an intermission nobody agrees in changes nothing.
func test_a_tie_leaves_the_rotation_in_charge() -> void:
	var maps := _four_map_intermission()
	MatchSystem.cast_vote(2, 2)
	MatchSystem.cast_vote(3, 3)
	MatchSystem.cast_vote(4, 1)
	assert_eq(Array(MatchSystem.vote_tallies()), [1, 1, 1], "level")
	assert_eq(MatchSystem.next_map, maps[1], "so the first option holds")


func test_a_vote_off_the_ballot_is_refused() -> void:
	var maps := _four_map_intermission()
	assert_eq(MatchSystem.cast_vote(2, 0), "", "there is no option zero")
	assert_eq(MatchSystem.cast_vote(2, 4), "", "nor a fourth")
	assert_eq(MatchSystem.next_map, maps[1], "and neither moved the leader")


func test_there_is_nothing_to_vote_on_mid_match() -> void:
	_write_cycle(_installed(4))
	MatchSystem.begin_map(_installed(1)[0])
	assert_true(MatchSystem.vote_candidates.is_empty(), "no ballot while the match is on")
	assert_eq(MatchSystem.cast_vote(2, 1), "", "and no vote to cast")


## A vote with one answer is just a delay.
func test_a_one_map_rotation_holds_no_vote() -> void:
	var maps := _installed(1)
	_write_cycle(maps)
	MatchSystem.begin_map(maps[0])
	MatchSystem.end_match("time")
	assert_true(MatchSystem.vote_candidates.is_empty(), "nothing to choose between")


## The map just played is never a candidate, so two maps leave exactly one answer.
func test_a_two_map_rotation_holds_no_vote() -> void:
	var maps := _installed(2)
	_write_cycle(maps)
	MatchSystem.begin_map(maps[0])
	MatchSystem.end_match("time")
	assert_true(MatchSystem.vote_candidates.is_empty(), "nothing to choose between")
	assert_eq(MatchSystem.next_map, maps[1], "the rotation picks it without asking")


func test_an_admin_naming_the_map_takes_the_ballot_down() -> void:
	var maps := _four_map_intermission()
	MatchSystem.cast_vote(2, 3)
	MatchSystem.set_next_map(maps[0])
	assert_true(MatchSystem.vote_candidates.is_empty(), "the vote is over")
	assert_eq(MatchSystem.next_map, maps[0], "the admin's map wins")
	MatchSystem.set_next_map("")
	assert_eq(MatchSystem.vote_candidates.size(), 3, "standing down puts it back to the room")
	assert_eq(MatchSystem.next_map, maps[1], "with the votes cleared, back to the rotation's pick")


func test_a_voter_who_leaves_takes_their_vote_with_them() -> void:
	var maps := _four_map_intermission()
	MatchSystem.cast_vote(2, 3)
	MatchSystem.cast_vote(3, 2)
	MatchSystem.cast_vote(4, 2)
	assert_eq(MatchSystem.next_map, maps[2], "two votes lead")
	MatchSystem._on_peer_disconnected(3)
	MatchSystem._on_peer_disconnected(4)
	assert_eq(Array(MatchSystem.vote_tallies()), [0, 0, 1], "both votes gone")
	assert_eq(MatchSystem.next_map, maps[3], "leaving the one voter still here in charge")


func test_the_ballot_is_cleared_by_the_next_map() -> void:
	var maps := _four_map_intermission()
	MatchSystem.cast_vote(2, 2)
	MatchSystem.begin_map(maps[2])
	assert_true(MatchSystem.vote_candidates.is_empty(), "a new match, no ballot")
	assert_eq(Array(MatchSystem.vote_tallies()), [], "and no votes carried into it")
