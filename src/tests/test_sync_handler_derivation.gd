extends "res://src/tests/test_base.gd"
## send_to_owner/broadcast_and_dispatch derive the client-side handler from the RPC name
## (sync_player_damage -> _on_sync_player_damage) instead of taking both as arguments.
##
## Every send site used to name both. The pair was two StringNames with no static checking behind
## it, so a typo in either was a silent no-op — damage that never landed, a status icon that never
## cleared, and nothing in the log. These pin the rule that replaced it, and the two deliberate
## exceptions that have to keep working: the reliable/unreliable "drain" pairs, which are one event
## on two channels and so share a handler via a forwarder.
##
## Scope: the NAME, not the routing. Where _dispatch_to_scene looks for a handler — the registered
## node, the scene, or nothing at all — and what it does with a name nobody answers is
## test_sync_dispatch.gd's job.


## Stands in for client_sync.gd: records which handler name the dispatcher actually reached.
class Spy extends Node:
	var calls: Array[String] = []
	var args_seen: Array = []
	func _on_sync_player_damage(amount: float, type: int = 0) -> void:
		calls.append("_on_sync_player_damage"); args_seen = [amount, type]
	func _on_sync_player_frost(duration: float) -> void:
		calls.append("_on_sync_player_frost"); args_seen = [duration]
	func _on_sync_fire_warning() -> void:
		calls.append("_on_sync_fire_warning"); args_seen = []
	func _on_sync_mana(new_mana: float, new_satchels: int) -> void:
		calls.append("_on_sync_mana"); args_seen = [new_mana, new_satchels]
	func _on_sync_mana_drain(new_mana: float, new_satchels: int) -> void:
		calls.append("_on_sync_mana_drain"); _on_sync_mana(new_mana, new_satchels)
	func _on_sync_bear_morph(peer_id: int, is_bear: bool, hp: float, max_hp: float) -> void:
		calls.append("_on_sync_bear_morph"); args_seen = [peer_id, is_bear, hp, max_hp]


var _spy: Spy


func _setup_test(_name: String) -> void:
	_spy = Spy.new()
	_root().add_child(_keep(_spy))
	NetworkManager.register_sync_handler(_spy)


func _teardown_test() -> void:
	NetworkManager.unregister_sync_handler(_spy)
	super()


## Offline there is no peer, so send_to_owner takes its local-dispatch branch — which is also the
## branch the listen host uses for its own player, and the one that has to agree with the RPC stub.
func test_send_to_owner_derives_the_handler() -> void:
	NetworkManager.send_to_owner(1, &"sync_player_damage", [25.0, 3])
	assert_eq(_spy.calls, ["_on_sync_player_damage"] as Array[String], "derived _on_ + rpc name")
	assert_eq(_spy.args_seen, [25.0, 3], "and forwarded the args unchanged")


func test_broadcast_and_dispatch_derives_the_handler() -> void:
	NetworkManager.broadcast_and_dispatch(&"sync_bear_morph", [7, true, 90.0, 120.0])
	assert_eq(_spy.calls, ["_on_sync_bear_morph"] as Array[String], "derived _on_ + rpc name")
	assert_eq(_spy.args_seen, [7, true, 90.0, 120.0], "and forwarded the args unchanged")


## An RPC that carries no arguments still has to resolve; `args` defaults to [].
func test_derivation_works_with_no_args() -> void:
	NetworkManager.send_to_owner(1, &"sync_fire_warning")
	assert_eq(_spy.calls, ["_on_sync_fire_warning"] as Array[String], "no-arg RPC resolved")


## The deliberate exception: sync_mana and sync_mana_drain are one event on two channels. Each gets
## its own derived handler so the rule holds with no override argument, and the drain forwarder is
## the single place that says they mean the same thing.
func test_drain_variants_resolve_to_their_own_handlers() -> void:
	NetworkManager.send_to_owner(1, &"sync_mana", [50.0, 2])
	assert_eq(_spy.calls, ["_on_sync_mana"] as Array[String], "reliable channel")
	_spy.calls.clear()
	NetworkManager.send_to_owner(1, &"sync_mana_drain", [49.0, 2])
	assert_eq(_spy.calls, ["_on_sync_mana_drain", "_on_sync_mana"] as Array[String],
			"drain resolves to its own handler, which forwards to the shared one")
	assert_eq(_spy.args_seen, [49.0, 2], "and the shared handler still gets the values")

