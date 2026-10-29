extends "res://src/tests/test_base.gd"
## /kick can name a bot, which has no connection to close — BotSystem.remove_bot takes that one
## puppet out instead. The bookkeeping is what this pins: _bots and _brains are parallel arrays
## read per tick, so removing from one and not the other would drive the wrong brain, and a
## roster entry left behind would resurrect the bot at the next map change.
##
## References the BotSystem / NetworkManager autoloads, so it must run via the scene runner.

# Stand-in for a bot puppet. Freed through NetworkManager.despawn_player, or by BotSystem itself
# when the registry never held it. Light on purpose: despawn_player reads the registry untyped,
# so this works where get_player()'s declared Player return would not.
class FakeBot:
	extends Node
	var peer_id := 0
	var cleaned := false

	func cleanup_for_class_change() -> void:
		cleaned = true


var _saved_bots: Array
var _saved_brains: Array
var _saved_roster: Dictionary
var _saved_peers: Dictionary
var _saved_roster_table: Dictionary


func _setup_test(_test_name: String) -> void:
	_saved_bots = BotSystem._bots
	_saved_brains = BotSystem._brains
	_saved_roster = BotSystem._roster
	_saved_peers = NetworkManager.swap_peer_table()
	BotSystem._bots = []
	BotSystem._brains = []
	BotSystem._roster = {}
	_saved_roster_table = NetworkManager.swap_roster()


func _teardown_test() -> void:
	for bot in BotSystem._bots:
		if is_instance_valid(bot):
			bot.free()
	BotSystem._bots = _saved_bots
	BotSystem._brains = _saved_brains
	BotSystem._roster = _saved_roster
	NetworkManager.swap_peer_table(_saved_peers)
	NetworkManager.swap_roster(_saved_roster_table)


## A bot as add_bot leaves it: in _bots with a brain beside it, in the roster, on the name
## table, and in the player registry.
func _add_fake_bot(id: int, bot_name: String) -> FakeBot:
	var bot := FakeBot.new()
	bot.peer_id = id
	bot.name = "Bot_%d" % (-id)
	var brain := Node.new()
	brain.name = "BotBrain"
	bot.add_child(brain)
	BotSystem._bots.append(bot)
	BotSystem._brains.append(brain)
	BotSystem._roster[id] = {name = bot_name, element = 4, team = 1, skill = -1.0}
	NetworkManager.set_player_name(id, bot_name)
	NetworkManager.register_player(id, bot)
	return bot


func _bot_ids() -> Array:
	var out := []
	for bot in BotSystem._bots:
		out.append(bot.peer_id)
	return out


func test_removes_the_named_bot_and_leaves_the_others() -> void:
	_add_fake_bot(-1, "BOT fire")
	var victim := _add_fake_bot(-2, "BOT ice")
	_add_fake_bot(-3, "BOT wind")

	assert_true(BotSystem.remove_bot(-2), "the bot was there to remove")
	assert_eq(_bot_ids(), [-1, -3], "only the named bot left")
	assert_eq(BotSystem._brains.size(), 2, "its brain went with it, keeping the arrays parallel")
	assert_eq(BotSystem._brains[1].get_parent().peer_id, -3, "and the brains still line up with the bots")
	assert_false(BotSystem._roster.has(-2), "no roster entry to respawn it at the next map change")
	assert_false(NetworkManager.has_player_name(-2), "and it is off the scoreboard")
	assert_false(NetworkManager.has_player(-2), "and out of the player registry")

	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_false(is_instance_valid(victim), "the puppet is freed, not orphaned")


func test_an_unknown_id_removes_nothing() -> void:
	_add_fake_bot(-1, "BOT fire")
	assert_false(BotSystem.remove_bot(-9), "no such bot")
	assert_eq(_bot_ids(), [-1], "and nobody else was taken instead")
	assert_true(NetworkManager.has_player(-1), "and the bot that is there kept its slot")


## A bot the registry never held still has to be freed here, or /kick leaks the puppet.
func test_an_unregistered_bot_is_freed_anyway() -> void:
	var orphan := _add_fake_bot(-1, "BOT fire")
	NetworkManager.unregister_player(-1)

	assert_true(BotSystem.remove_bot(-1), "removed")
	assert_true(orphan.cleaned, "torn down by BotSystem instead")
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_false(is_instance_valid(orphan), "and freed")


## remove_all_bots shares remove_bot's teardown; this is the half /killbots runs.
func test_killbots_still_empties_everything() -> void:
	_add_fake_bot(-1, "BOT fire")
	_add_fake_bot(-2, "BOT ice")

	assert_eq(BotSystem.remove_all_bots(), 2, "both counted")
	assert_eq(BotSystem._bots, [], "no bots")
	assert_eq(BotSystem._brains, [], "no brains")
	assert_eq(BotSystem._roster, {}, "no roster")
	assert_eq(NetworkManager.player_count(), 0, "both out of the player registry")
	assert_false(NetworkManager.has_player_name(-1), "both off the scoreboard")
	assert_false(NetworkManager.has_player_name(-2), "")
