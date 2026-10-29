extends "res://src/tests/test_base.gd"
## Pins goal_result (g_r) against TFCGOAL_RESULT_* in tfcentities.h: an invented bit 8 flag used
## to strip the activating player from cascaded ops, and GR_DESTROY_PLANTS (64) was missing
## entirely, so ww_monoliths/ww_osaka's plant-clearing goals did nothing.

const TFGoalBaseScript = preload("res://src/entities/tf_goal_base.gd")


## Values straight out of tfcentities.h — these are the only six that exist.
func test_flag_values_match_the_original() -> void:
	assert_eq(TFGoalBaseScript.GR_REMOVE_IMMEDIATELY, 1, "TFCGOAL_RESULT_SINGLE")
	assert_eq(TFGoalBaseScript.GR_ENDGAME, 4, "TFCGOAL_RESULT_ENDGAME")
	assert_eq(TFGoalBaseScript.GR_RESET_SPY, 16, "TFCGOAL_RESULT_RESETSPY")
	assert_eq(TFGoalBaseScript.GR_FORCE_RESPAWN_NO_DIE, 32, "TFCGOAL_RESULT_RESPAWN")
	assert_eq(TFGoalBaseScript.GR_DESTROY_PLANTS, 64, "TFCGOAL_RESULT_DESTROYPLANTS")
	assert_eq(TFGoalBaseScript.GR_ITEM_GLOWS, 512, "TFCGOAL_RESULT_ITEMGLOWS")


## Every flag the codebase defines, so the checks below can sweep them.
func _all_flags() -> Dictionary:
	return {
		"GR_REMOVE_IMMEDIATELY": TFGoalBaseScript.GR_REMOVE_IMMEDIATELY,
		"GR_ENDGAME": TFGoalBaseScript.GR_ENDGAME,
		"GR_RESET_SPY": TFGoalBaseScript.GR_RESET_SPY,
		"GR_FORCE_RESPAWN_NO_DIE": TFGoalBaseScript.GR_FORCE_RESPAWN_NO_DIE,
		"GR_DESTROY_PLANTS": TFGoalBaseScript.GR_DESTROY_PLANTS,
		"GR_ITEM_GLOWS": TFGoalBaseScript.GR_ITEM_GLOWS,
	}


func test_no_invented_bit_8() -> void:
	# Guards the regression directly: nothing may claim bit 8 again.
	for flag_name in _all_flags():
		assert_true(_all_flags()[flag_name] != 8, "%s must not be bit 8" % flag_name)


## Bit 2 is on 321 goals across the shipped maps and 4096 on four in ww_december.
## Neither is defined in the original, so neither may collide with a real flag.
func test_undefined_bits_are_inert() -> void:
	var flags := _all_flags()
	for bit in [2, 8, 4096]:
		for flag_name in flags:
			assert_true(flags[flag_name] & bit == 0,
				"undefined bit %d must not overlap %s" % [bit, flag_name])


func test_destroy_plants_clears_every_player() -> void:
	var players := _seed_players()
	var goal := SpyGoal.new()
	goal.goal_results = TFGoalBaseScript.GR_DESTROY_PLANTS
	goal.process_effects(null)
	for p in players:
		assert_false(p.plants.has_thornplant, "%s had its plants cleared" % p.name)
	_clear_players(players)


func test_other_results_leave_plants_alone() -> void:
	var players := _seed_players()
	var goal := SpyGoal.new()
	goal.goal_results = TFGoalBaseScript.GR_REMOVE_IMMEDIATELY
	goal.process_effects(null)
	for p in players:
		assert_true(p.plants.has_thornplant, "a goal without bit 64 spares the plants")
	_clear_players(players)


func _seed_players() -> Array:
	var made := []
	for i in range(3):
		var p := FakePlayer.new()
		p.name = "FakePlayer%d" % i
		p.plants.initialize(p)
		p.plants.thornplant = FakePlant.new()
		NetworkManager.register_player(100 + i, p)
		made.append(p)
	return made


func _clear_players(players: Array) -> void:
	for i in range(players.size()):
		NetworkManager.unregister_player(100 + i)
	for p in players:
		if is_instance_valid(p.plants.thornplant):
			p.plants.thornplant.free()
		p.free()


class FakePlayer:
	extends Node
	var plants := PlantBehavior.new()


## Stands in for a Thornplant: remove_all() only asks it to destroy itself.
class FakePlant:
	extends Node3D
	func destroy_plant() -> void:
		pass


## Skips scoring/messaging/sound, which need the full autoload set; the plant
## sweep is the part under test.
class SpyGoal:
	extends TFGoalBaseScript
	func _apply_player_effects(_ap: Node) -> void:
		pass
	func _show_goal_messages(_player: Node) -> void:
		pass
