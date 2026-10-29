extends "res://src/tests/test_base.gd"
## Which server→client sends are reliable, and who gets them, follows the 1.2.9 C++: every user
## message (gmsg*, MSG_ONE/MSG_ALL) was reliable; temp entities (SVC_TEMPENTITY on MSG_BROADCAST,
## MSG_PVS, MSG_PAS) and clientdata were not. How a player looks to others was entity state.


class StubVM:
	var registered: Array[AABB] = []
	var unregistered: Array[int] = []
	var visible_to := {}  # observer handle -> bool

	func register_entity(aabb: AABB) -> int:
		registered.append(aabb)
		return 7

	func unregister_entity(handle: int) -> void:
		unregistered.append(handle)

	func is_entity_visible_to_observer(_h: int, obs: int) -> bool:
		return visible_to.get(obs, false)


class StatusSink extends Node:
	var calls: Array = []

	func _on_status_visual(peer_id: int, status_type: int, active: bool) -> void:
		calls.append([peer_id, status_type, active])


func _transfer_mode(script: Script, method: String) -> int:
	var cfg: Dictionary = script.get_rpc_config()
	assert_true(cfg.has(method), "%s is no longer an @rpc; this test needs a new target" % method)
	return int(cfg.get(method, {}).get("transfer_mode", -1))


func test_temp_entities_and_clientdata_are_unreliable() -> void:
	var nm: Script = NetworkManager.get_script()
	for method in ["sync_gib_burst", "sync_player_help_call", "sync_view_punch", "sync_entity_event"]:
		assert_eq(_transfer_mode(nm, method), MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, method)
	assert_eq(_transfer_mode(load("res://src/systems/decal_system.gd"), "place_rpc"),
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, "decals were TE_DECAL / TE_GUNSHOTDECAL")


func test_user_messages_stay_reliable() -> void:
	var nm: Script = NetworkManager.get_script()
	for method in ["sync_screen_shake", "sync_screen_fade", "sync_player_damage", "sync_player_death",
			"sync_player_invis", "sync_player_status"]:
		assert_eq(_transfer_mode(nm, method), MultiplayerPeer.TRANSFER_MODE_RELIABLE, method)


func test_pvs_send_reaches_only_peers_that_see_the_box() -> void:
	var vs = load("res://src/systems/visibility_system.gd").new()
	var stub := StubVM.new()
	vs._vm = stub
	vs._peer_observers = {2: 20, 3: 30}
	stub.visible_to = {20: true, 30: false}
	var box := AABB(Vector3(1, 2, 3), Vector3(2, 2, 2))
	var got: PackedInt32Array = vs.peers_seeing(box, PackedInt32Array([2, 3, 4]))
	assert_eq(Array(got), [2, 4], "the seeing peer, and the one with no observer yet (fail open)")
	assert_eq(stub.registered, [box], "asked about the whole box")
	assert_eq(stub.unregistered, [7], "the probe is released")
	vs.free()


func test_pvs_send_pads_a_point() -> void:
	var vs = load("res://src/systems/visibility_system.gd").new()
	var stub := StubVM.new()
	vs._vm = stub
	vs.peers_seeing(AABB(Vector3(1, 2, 3), Vector3.ZERO), PackedInt32Array())
	assert_true(stub.registered[0].has_volume(), "a bare point is grown into a box, like an entity")
	vs.free()


func test_shake_picks_like_util_screenshake() -> void:
	var origin := Vector3.ZERO
	assert_true(NetworkManager.shakes(Vector3(5, 0, 0), true, origin, 10.0), "inside the radius")
	assert_false(NetworkManager.shakes(Vector3(10, 0, 0), true, origin, 10.0), "at the radius is out")
	assert_false(NetworkManager.shakes(Vector3(1, 0, 0), false, origin, 10.0), "not on the ground")
	assert_true(NetworkManager.shakes(Vector3(500, 0, 0), true, origin, 0.0), "radius 0 is everyone")


func test_render_flags_drive_invisibility_and_status_sprites() -> void:
	var p: RemotePlayer = load("res://src/remote_player.tscn").instantiate()
	var net_sync := p.get_node(^"NetSync")
	p.remove_child(net_sync)
	net_sync.free()
	p.peer_id = 5
	_root().add_child(p)
	_spawned.append(p)
	var sink := StatusSink.new()
	_keep(sink)
	var prev_handler: Node = NetworkManager._sync_handler
	NetworkManager.register_sync_handler(sink)

	var burning := NetworkManager.PLAYER_FLAG_BURNING
	p.apply_render_flags(NetworkManager.PLAYER_FLAG_INVISIBLE | burning)
	assert_true(p.is_invisible, "invisible from the flag")
	assert_eq(sink.calls, [[5, GameConsts.StatusType.BURNING, true]], "the burning sprite went up")

	sink.calls.clear()
	p.apply_render_flags(NetworkManager.PLAYER_FLAG_INVISIBLE | burning | NetworkManager.PLAYER_FLAG_CROUCHED)
	assert_eq(sink.calls, [], "an unrelated bit changes nothing")

	p.apply_render_flags(0)
	assert_false(p.is_invisible, "visible again")
	assert_eq(sink.calls, [[5, GameConsts.StatusType.BURNING, false]], "and the sprite came down")

	NetworkManager.unregister_sync_handler(sink)
	NetworkManager._sync_handler = prev_handler


func test_every_status_sprite_has_a_flag() -> void:
	assert_eq(NetworkManager.PLAYER_STATUS_FLAGS.keys().size(), StatusSystem.STATUS_SPRITES.keys().size(),
		"a status with a sprite but no snapshot bit would never show on anyone else")
	for st in StatusSystem.STATUS_SPRITES:
		assert_true(NetworkManager.PLAYER_STATUS_FLAGS.has(st), "status %d has a flag" % st)


func test_a_thornplant_level_is_state() -> void:
	var plant: Thornplant = load("res://src/monsters/thornplant.gd").new()
	assert_true(plant.net_sync_properties().has(":level"),
		"the original swapped the model on the entity; a late viewer must see the grown plant")
	plant.setup({"level": 0}, false)
	_root().add_child(plant)
	_spawned.append(plant)
	var before: Node3D = plant._model
	plant.level = 2
	assert_eq(plant._stats, Thornplant.LEVELS[2], "a client takes the grown stats from the snapshot")
	if before != null:
		assert_ne(plant._model, before, "and rebuilds the model in place")


func test_a_death_rides_the_unreliable_event() -> void:
	var src := FileAccess.get_file_as_string("res://src/behaviors/entity_behavior.gd")
	var body := src.split("func die_at(")[1].split("\nfunc ")[0]
	assert_true(body.contains("publish_event("), "temp entities and sounds were never reliable")
	assert_false(body.contains("publish(state)"), "not the reliable, parked push")


## A sound reaches every peer through SoundSystem's broadcast, as GoldSrc sounds reached the PAS.
## Played from an entity event instead, it would go silent for a client that never had the entity.
func test_event_handlers_leave_sound_to_the_broadcast() -> void:
	for f in ["skeleton", "dragon", "wombat", "thornplant", "giant_plant", "lightning_cloud", "sheep", "spirit_wiz"]:
		var src := FileAccess.get_file_as_string("res://src/monsters/%s.gd" % f)
		for handler in ["func _apply_sync_state(", "func _death_effect(", "func _show_zap(", "func _play_attack_visual("]:
			if not src.contains(handler):
				continue
			var body := src.split(handler)[1].split("\nfunc ")[0]
			assert_false(body.contains("SoundSystem.play_3d"), "%s %s plays no sound of its own" % [f, handler])
