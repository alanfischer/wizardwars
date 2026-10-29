extends "res://src/tests/test_base.gd"
## Which info_tfdetect keys declare a team. Worldcraft writes every FGD key out at its 0 default,
## so key *presence* means nothing — reading it as a declaration gave ww_wstland4 four teams when
## only two are playable. Only number_of_teams and a non-empty teamN_name declare; everything
## else comes from spawns, which is what keeps ww_chasm's dragonrider teams.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const InfoTFDetectScript = preload("res://src/entities/info_tfdetect.gd")


## ww_wstland4's actual info_tfdetect, verbatim from the BSP entity lump: a stock
## 2-team CTF map whose every team-indexed key sits at the FGD default of 0.
const WSTLAND4 := {
	"classname": "info_tfdetect",
	"team4_allies": "0", "team3_allies": "0", "team2_allies": "0", "team1_allies": "0",
	"hook_out": "0",
	"display_item_status4": "0", "display_item_status3": "0",
	"display_item_status2": "2", "display_item_status1": "1",
	"maxammo_detpack": "0", "maxammo_medikit": "0",
	"ammo_detpack": "0", "ammo_medikit": "0",
	"maxammo_cells": "0", "maxammo_rockets": "0", "maxammo_nails": "0", "maxammo_shells": "0",
	"ammo_cells": "0", "ammo_rockets": "0", "ammo_nails": "0", "ammo_shells": "0",
	"impulse": "128",
}


func _teardown_test() -> void:
	_cleanup()


## Build a detect entity the way main.gd does — keys ride in as node meta.
func _detect(keys: Dictionary) -> Node:
	var d := InfoTFDetectScript.new()
	d.set_meta("entity", keys)
	_root().add_child(d)
	_spawned.append(d)
	return d


func _reset(spawn_teams: int) -> void:
	GoalSystem.reset()
	SpawnSystem.global_teams = spawn_teams


func _cleanup() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()
	GoalSystem.reset()
	SpawnSystem.global_teams = 0


## The bug: 12 FGD-default zeros read as declarations for all four teams.
func test_fgd_default_zeros_declare_nothing() -> void:
	_reset(0b0011)  # 8 spawns each for teams 1 and 2
	_detect(WSTLAND4)
	assert_eq(GoalSystem._declared_teams, 0, "no key in wstland4's detect declares a team")
	assert_eq(GoalSystem.get_team_count(), 2, "wstland4 is a 2-team map")


## ww_countryside / ww_matrox block the Spy on all four team slots. That is a setting,
## not a roster — both maps have only team 1 and team 2 spawns.
func test_class_restrictions_declare_nothing() -> void:
	_reset(0b0011)
	_detect({
		"classname": "info_wwdetect",
		"team2_max": "15", "team1_max": "15",
		"class_team4": "256", "class_team3": "256",
		"class_team2": "256", "class_team1": "256", "class_team0": "256",
	})
	assert_eq(GoalSystem.get_team_count(), 2, "class restrictions do not add teams")
	assert_eq(GoalSystem.class_restrictions, [256, 256, 256, 256], "but they are still applied")


## Lives and max-players are per-team settings on the same footing.
func test_lives_and_max_players_declare_nothing() -> void:
	_reset(0b0011)
	_detect({
		"classname": "info_tfdetect",
		"ammo_shells": "5", "ammo_nails": "5", "ammo_rockets": "5", "ammo_cells": "5",
		"ammo_medikit": "8", "ammo_detpack": "8",
		"maxammo_medikit": "8", "maxammo_detpack": "8",
	})
	assert_eq(GoalSystem.get_team_count(), 2, "lives/max-players do not add teams")
	assert_eq(GoalSystem.team_max_players, [8, 8, 8, 8], "but they are still applied")


## ww_memnate names three teams and fields three teams' spawns.
func test_team_name_declares_a_team() -> void:
	_reset(0b0111)
	_detect({
		"classname": "info_tfdetect",
		"team3_name": "Yellow Defense", "team2_name": "Red Offense", "team1_name": "Blue Offense",
	})
	assert_eq(GoalSystem._declared_teams, 0b0111, "each named team is declared")
	assert_eq(GoalSystem.get_team_count(), 3, "memnate is a 3-team map")
	assert_eq(GoalSystem.team_names[2], "Yellow Defense", "name applied")


## An empty name is the FGD default for a string key — same trap as the zeros.
func test_empty_team_name_declares_nothing() -> void:
	_reset(0b0011)
	_detect({
		"classname": "info_tfdetect",
		"team1_name": "Blue Wizards", "team2_name": "Red Wizards",
		"team3_name": "", "team4_name": "",
	})
	assert_eq(GoalSystem._declared_teams, 0b0011, "only the two named teams count")
	assert_eq(GoalSystem.get_team_count(), 2, "blank names do not add teams")


func test_number_of_teams_wins_outright() -> void:
	_reset(0b1111)
	_detect({"classname": "info_tfdetect", "number_of_teams": "2"})
	assert_eq(GoalSystem.get_team_count(), 2, "explicit count beats four spawn teams")


## ww_december really does field four teams, and says so only through its spawns.
func test_spawns_still_drive_the_count() -> void:
	_reset(0b1111)
	_detect({"classname": "info_tfdetect"})
	assert_eq(GoalSystem.get_team_count(), 4, "four spawn teams, four teams")


func test_count_floors_at_two() -> void:
	_reset(0)
	_detect({"classname": "info_tfdetect"})
	assert_eq(GoalSystem.get_team_count(), 2, "a map with no signal still has two sides")


## ww_chasm really is a 4-team map: teams 3/4 (dragonriders) say so only through
## info_dragonrider_spawn, not the detect entity — its info_wwdetect carries only
## class_N_M / teamN_allies / teamN_max / teamN_min, none of which declare a team.
func test_chasm_dragonrider_spawns_carry_teams_three_and_four() -> void:
	_reset(0b1111)  # teamspawns for 1 and 2, dragonrider spawns for 3 and 4
	_detect({
		"classname": "info_wwdetect",
		"team1_allies": "3", "team2_allies": "4", "team3_allies": "1", "team4_allies": "2",
		"team3_max": "1", "team4_max": "1", "team3_min": "10", "team4_min": "10",
		"class_1_1": "31", "class_2_1": "31", "class_3_1": "31", "class_4_1": "31",
	})
	assert_eq(GoalSystem._declared_teams, 0, "nothing in chasm's detect declares a team")
	assert_eq(GoalSystem.get_team_count(), 4, "chasm fields four teams")


## The other half of chasm's setup: 1 with 3, 2 with 4.
func test_chasm_alliances_pair_riders_with_their_base_team() -> void:
	_reset(0b1111)
	_detect({
		"classname": "info_wwdetect",
		"team1_allies": "3", "team2_allies": "4", "team3_allies": "1", "team4_allies": "2",
	})
	assert_true(Teams.teams_friendly(1, 3), "team 1 allied with its dragonriders")
	assert_true(Teams.teams_friendly(3, 1), "and back again")
	assert_true(Teams.teams_friendly(2, 4), "team 2 allied with its dragonriders")
	assert_false(Teams.teams_friendly(1, 2), "the base teams stay enemies")
	assert_false(Teams.teams_friendly(1, 4), "as do a team and the enemy's riders")


## ww_feudal configures dragon teams 3/4 the same way but places no spawn points for
## them, so they are unjoinable and must stay off the roster — which is why teamN_max
## can't be promoted to a declaration.
func test_feudal_dragon_teams_without_spawns_stay_off_the_roster() -> void:
	_reset(0b0011)
	_detect({
		"classname": "info_wwdetect",
		"team3_allies": "4", "team4_allies": "3",
		"team3_max": "1", "team4_max": "1",
		"conclave_team1": "16", "conclave_team2": "16",
	})
	assert_eq(GoalSystem.get_team_count(), 2, "no spawns for 3/4, so feudal is a 2-team map")


## What the scoreboard reads: allied teams are one side and get one score line, so chasm's
## four teams show as two.
func test_chasm_scoreboard_shows_two_sides() -> void:
	_reset(0b1111)
	_detect({
		"classname": "info_wwdetect",
		"team1_allies": "3", "team2_allies": "4", "team3_allies": "1", "team4_allies": "2",
	})
	assert_eq(GoalSystem.get_team_groups(), [[1, 3], [2, 4]], "riders ride with their base team")
	GoalSystem.add_score(1, 6)
	GoalSystem.add_score(2, 4)
	assert_eq(GoalSystem.get_group_score([1, 3]), 6, "blue's side")
	assert_eq(GoalSystem.get_group_score([2, 4]), 4, "red's side")


func test_unallied_map_keeps_a_line_per_team() -> void:
	_reset(0b0011)
	_detect({"classname": "info_tfdetect"})
	assert_eq(GoalSystem.get_team_groups(), [[1], [2]], "no alliances, no grouping")


## ww_hunt/ww_castle/ww_volcano ally 1 with 2 and hand both teams 50 for the same event, so a
## side's score is its best member — summing would show 100 for a 50-point capture.
func test_mirrored_award_is_not_doubled() -> void:
	_reset(0b0011)
	_detect({"classname": "info_tfdetect", "team1_allies": "2", "team2_allies": "1"})
	assert_eq(GoalSystem.get_team_groups(), [[1, 2]], "one side")
	GoalSystem.add_score(1, 50)
	GoalSystem.add_score(2, 50)
	assert_eq(GoalSystem.get_group_score([1, 2]), 50, "one escape, one 50")


## A map that names the link one way only still means one side, and an ally's ally joins it.
func test_alliances_are_mutual_and_transitive() -> void:
	_reset(0b0111)
	_detect({"classname": "info_tfdetect", "team1_allies": "2", "team2_allies": "3"})
	assert_eq(GoalSystem.get_team_groups(), [[1, 2, 3]], "one chain, one side")
