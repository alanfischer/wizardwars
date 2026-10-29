extends "res://src/tests/test_base.gd"
## A triggered env_sprite/env_beam/env_model must update its *synced* _game_visible, not just the
## local `visible` flag, or the effect hides on the host while _get_sync_state() keeps reporting
## stale state to clients.


func test_flame_off_updates_game_visible() -> void:
	var s := EnvSprite.new()
	s.set_meta("entity", {
		"classname": "env_sprite", "targetname": "house3flame",
		"model": "sprites/fire.spr", "spawnflags": "1", "scale": ".5",
		"rendermode": "5", "renderamt": "255", "framerate": "10.0",
	})
	_root().add_child(s)
	s.trigger(null, TriggerSystem.Type.OFF)
	assert_false(s.visible, "flame node hidden on host")
	assert_false(s._game_visible, "flame _game_visible false (so sync tells clients OFF)")
	# The value clients actually receive:
	var state: Dictionary = s._get_sync_state()
	assert_eq(state.get("visible"), false, "sync state reports visible=false to clients")
	s.queue_free()


func test_smoke_off_updates_game_visible() -> void:
	var b := EnvBeam.new()
	b.set_meta("entity", {
		"classname": "env_beam", "targetname": "house3smoke",
		"texture": "sprites/smoke.spr", "spawnflags": "257",
		"LightningStart": "house3smoke1", "LightningEnd": "house3smoke2",
		"BoltWidth": "80", "NoiseAmplitude": "10", "rendercolor": "200 200 200",
		"renderamt": "100", "TextureScroll": "35", "StrikeTime": "1", "Radius": "256",
	})
	_root().add_child(b)
	b.trigger(null, TriggerSystem.Type.OFF)
	assert_false(b._game_visible, "smoke _game_visible false")
	var state: Dictionary = b._get_sync_state()
	assert_eq(state.get("visible"), false, "sync state reports visible=false to clients")
	b.queue_free()


func test_model_off_updates_game_visible() -> void:
	var m := EnvModel.new()
	# No "model" key: _ready skips model loading (irrelevant here) and the trigger
	# path — the actual fix — is still exercised.
	m.set_meta("entity", {
		"classname": "env_model", "targetname": "some_model", "spawnflags": "1",
	})
	_root().add_child(m)
	m.trigger(null, TriggerSystem.Type.OFF)
	assert_false(m._game_visible, "model _game_visible false")
	var state: Dictionary = m._get_sync_state()
	assert_eq(state.get("visible"), false, "sync state reports visible=false to clients")
	m.queue_free()
