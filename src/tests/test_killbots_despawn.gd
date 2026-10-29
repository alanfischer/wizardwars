extends "res://src/tests/test_base.gd"
## /killbots freed every bot puppet but left it in the player registry: dropping a peer's state
## clears the per-peer dictionaries only, and a bot raises neither peer_disconnected nor a host-side
## `despawned`. The next physics tick then walked the registry and called has_server_movement() on a
## freed object — which a release export does not validate, so it jumped through reused memory and
## took the dedicated server down with a SIGSEGV.
##
## Uses BotSystem/NetworkManager autoloads, so it runs via the scene runner, not `-s`.

# A light stand-in for a bot puppet: NetworkManager.despawn_player reads the registry untyped,
# so this passes where get_player()'s declared Player return would not.
class StubBot:
	extends Node
	var peer_id := 0
	var cleaned := false

	func cleanup_for_class_change() -> void:
		cleaned = true


var _saved_bots: Array
var _saved_brains: Array
var _saved_roster: Dictionary
var _saved_roster_table: Dictionary


func _setup_test(_test_name: String) -> void:
	super._setup_test(_test_name)
	_saved_bots = BotSystem._bots.duplicate()
	_saved_brains = BotSystem._brains.duplicate()
	_saved_roster = BotSystem._roster.duplicate()
	_saved_roster_table = NetworkManager.swap_roster()
	BotSystem._bots.clear()
	BotSystem._brains.clear()
	BotSystem._roster.clear()


func _teardown_test() -> void:
	BotSystem._bots.assign(_saved_bots)
	BotSystem._brains.assign(_saved_brains)
	BotSystem._roster.assign(_saved_roster)
	NetworkManager.swap_roster(_saved_roster_table)
	super._teardown_test()


func _add_bot(id: int) -> StubBot:
	var bot := StubBot.new()
	bot.peer_id = id
	_root().add_child(bot)
	_keep(bot)
	BotSystem._bots.append(bot)
	NetworkManager.register_player(id, bot)
	return bot


func test_killbots_drops_every_bot_from_the_player_table() -> void:
	for id in [-1, -2, -3]:
		_add_bot(id)
	assert_eq(NetworkManager.player_count(), 3, "precondition: the bots are in the player registry")
	var n := BotSystem.remove_all_bots()
	assert_eq(n, 3, "all three are reported removed")
	assert_eq(NetworkManager.player_count(), 0,
		"and none is left behind — a leftover entry is a freed puppet the next tick calls into")


func test_killbots_tears_down_each_bots_owned_entities() -> void:
	var bot := _add_bot(-1)
	BotSystem.remove_all_bots()
	assert_true(bot.cleaned,
		"plants and sentries still go down with the bot, as on a real disconnect")


func test_killbots_leaves_no_freed_puppet_reachable() -> void:
	var bot := _add_bot(-1)
	BotSystem.remove_all_bots()
	await _tick(2)  # queue_free lands at the end of the frame
	assert_false(is_instance_valid(bot), "the puppet is actually freed")
	var registry := NetworkManager.player_table()
	for id in registry:
		assert_true(is_instance_valid(registry[id]),
			"nothing freed is still reachable from the player registry")


func test_killbots_is_idempotent() -> void:
	_add_bot(-1)
	BotSystem.remove_all_bots()
	assert_eq(BotSystem.remove_all_bots(), 0, "a second sweep finds nothing and does not throw")
