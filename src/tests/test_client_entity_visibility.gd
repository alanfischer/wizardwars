extends "res://src/tests/test_base.gd"
## Map entities on a client start ABSENT and materialize when the stream reports them in PVS.
## Regression: _register_for_sync ran before the map/spawnflag intent was written to `visible`,
## so entering PVS could never re-light it — 160 of ww_2fort's env_sprites shipped invisible.


## Mirrors the real subclass ordering: register first, express intent second, seed third.
## Only WRITES `visible` when starting off, like env_sprite — a fake that always writes
## papers over the bug (verified: it'd pass either way).
class FakeMapEntity:
	extends EntityBase
	var starts_off := false
	func _ready() -> void:
		super()
		_register_for_sync()
		if starts_off:
			visible = false  # a targetname'd, non-START_ON sprite
		_seed_game_visible()


func _spawn_as_client(starts_off: bool) -> FakeMapEntity:
	NetworkManager.test_authority = NetworkManager.TestAuthority.CLIENT
	NetworkManager.transport.relevance_events = true
	var e := FakeMapEntity.new()
	e.starts_off = starts_off
	e.set_meta("entity", {"classname": "test_entity"})
	_root().add_child(e)
	await (Engine.get_main_loop() as SceneTree).process_frame  # deferred PVS hide lands
	return e


func _cleanup(e: Node) -> void:
	NetworkManager.test_authority = NetworkManager.TestAuthority.REAL
	NetworkManager.transport.relevance_events = false
	NetworkManager.reset_entities()
	e.queue_free()


func test_client_entity_keeps_visible_intent() -> void:
	var e: FakeMapEntity = await _spawn_as_client(false)
	assert_true(e._game_visible,
		"a client entity seeds its own visibility intent, not the PVS gate")
	_cleanup(e)


func test_client_entity_keeps_hidden_intent() -> void:
	# The other direction: a start-off entity must NOT be revived by the reordering.
	var e: FakeMapEntity = await _spawn_as_client(true)
	assert_false(e._game_visible, "a start-off entity stays off")
	_cleanup(e)


func test_client_entity_starts_absent() -> void:
	# ...and PVS presence still applies, or the join-time hide-everything burst comes back.
	var e: FakeMapEntity = await _spawn_as_client(false)
	assert_false(e._present, "a client map entity starts absent until the stream reports it")
	assert_false(e.visible, "so it renders nothing until it enters PVS")
	_cleanup(e)
