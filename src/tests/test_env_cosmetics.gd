extends "res://src/tests/test_base.gd"
## Cosmetic env_* entities previously freed as unrecognized: env_glow (211 across 6 maps),
## env_shooter, env_shake, env_sound. Covers key parsing/state; pixels and audio are a human
## check — headless has no renderer/output device, so particle/tween work is skipped here.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	SoundSystem.set_room_type(0, null)


func _spawn(script: GDScript, keys: Dictionary) -> Node3D:
	var n: Node3D = script.new()
	n.set_meta("entity", keys)
	_root().add_child(n)
	_spawned.append(n)
	return n


func test_glow_is_tinted_by_rendercolor() -> void:
	var g := _spawn(EnvGlow, {
		"classname": "env_glow", "model": "sprites/glow01.spr",
		"rendermode": "3", "renderamt": "192", "rendercolor": "255 255 128", "scale": "1",
	})
	var sprite := g.get_node_or_null(^"Sprite") as Sprite3D
	assert_ne(sprite, null, "the glow sprite loaded")
	assert_almost_eq(sprite.modulate.r, 1.0, 0.01, "red from rendercolor")
	assert_almost_eq(sprite.modulate.b, 128.0 / 255.0, 0.01, "blue from rendercolor")
	assert_almost_eq(sprite.modulate.a, 192.0 / 255.0, 0.01,
		"and env_sprite's renderamt alpha survives the tint")


func test_zero_rendercolor_stays_white() -> void:
	var g := _spawn(EnvGlow, {
		"classname": "env_glow", "model": "sprites/glow01.spr",
		"rendermode": "3", "renderamt": "255", "rendercolor": "0 0 0",
	})
	var sprite := g.get_node_or_null(^"Sprite") as Sprite3D
	assert_ne(sprite, null, "the glow sprite loaded")
	# Engine-literal: all-zero rendercolor is unset, not black — 17 glows rely on it.
	assert_almost_eq(sprite.modulate.r, 1.0, 0.001, "unset rendercolor draws white, not black")
	assert_almost_eq(sprite.modulate.g, 1.0, 0.001, "unset rendercolor draws white, not black")
	assert_almost_eq(sprite.modulate.b, 1.0, 0.001, "unset rendercolor draws white, not black")


func test_shake_converts_radius_to_metres() -> void:
	var s := _spawn(EnvShake, {
		"classname": "env_shake", "targetname": "blue_boom",
		"amplitude": "16", "radius": "100", "duration": "2", "frequency": "12",
	})
	assert_almost_eq(s._radius, 100.0 * GameConsts.SCALE_FACTOR, 0.001,
		"radius converts from GoldSrc units to metres")
	assert_almost_eq(s._amplitude, 16.0, 0.001,
		"amplitude stays in GoldSrc units — the client scales it to a frustum offset")


func test_global_shake_flag_drops_the_radius() -> void:
	var s := _spawn(EnvShake, {
		"classname": "env_shake", "targetname": "detshake", "spawnflags": "1",
		"amplitude": "8", "radius": "500", "duration": "1.5", "frequency": "2",
	})
	assert_eq(s._radius, 0.0, "SF_GLOBAL_SHAKE means radius 0 downstream — everyone shakes")


func test_shake_without_amplitude_never_broadcasts() -> void:
	# Guarded before the network call, so this is safe to trigger offline.
	var s := _spawn(EnvShake, {"classname": "env_shake", "duration": "2"})
	s.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_eq(s._amplitude, 0.0, "no amplitude key, nothing to send")


func test_shooter_aims_along_its_angles() -> void:
	var s := _spawn(EnvShooter, {
		"classname": "env_shooter", "targetname": "rt4", "angles": "-90 0 0",
		"shootmodel": "sprites/glow02.spr", "m_iGibs": "2", "delay": "1.8",
		"m_flGibLife": ".1", "m_flVelocity": "400", "m_flVariance": "6",
		"rendermode": "5", "rendercolor": "0 0 255", "renderamt": "255", "spawnflags": "1",
	})
	# GoldSrc pitch -90 is straight up; every shipped shooter is a fountain.
	assert_vec3_almost_eq(s._shoot_direction(), Vector3.UP, 0.001,
		"pitch -90 shoots straight up")


func test_shooter_reads_its_burst_keys() -> void:
	var s := _spawn(EnvShooter, {
		"classname": "env_shooter", "targetname": "rt1", "angles": "-90 0 0",
		"shootmodel": "sprites/glow02.spr", "m_iGibs": "2", "delay": "1.8",
		"spawnflags": "1",
	})
	assert_eq(s._gibs, 2, "m_iGibs is the burst size")
	assert_almost_eq(s._delay, 1.8, 0.001, "delay is the gap between gibs")
	assert_true(s._repeatable, "spawnflag 1 lets the button fire it again")


func test_world_bus_exists_and_starts_dry() -> void:
	var idx := AudioServer.get_bus_index(SoundSystem.WORLD_BUS)
	assert_ne(idx, -1, "world sounds have their own bus to reverb")
	var reverb := AudioServer.get_bus_effect(idx, 0) as AudioEffectReverb
	assert_ne(reverb, null, "with a reverb on it")
	assert_eq(reverb.wet, 0.0, "sitting dry until an env_sound claims the listener")


func test_roomtype_selects_its_family() -> void:
	# 6 = tunnel medium (family base 5, middle of small/medium/large).
	SoundSystem.set_room_type(6, null)
	var reverb := AudioServer.get_bus_effect(
		AudioServer.get_bus_index(SoundSystem.WORLD_BUS), 0) as AudioEffectReverb
	assert_almost_eq(reverb.room_size, 0.5, 0.001, "tunnel medium room size")
	assert_almost_eq(reverb.damping, 0.3, 0.001, "tunnel damping")
	assert_gt(reverb.wet, 0.0, "and it is audibly wet")


func test_roomtype_zero_goes_dry() -> void:
	SoundSystem.set_room_type(23, null)
	SoundSystem.set_room_type(0, null)
	var reverb := AudioServer.get_bus_effect(
		AudioServer.get_bus_index(SoundSystem.WORLD_BUS), 0) as AudioEffectReverb
	assert_eq(reverb.wet, 0.0, "roomtype 0 is no reverb at all")


func test_release_by_a_stale_owner_is_ignored() -> void:
	var a := _spawn(EnvSound, {"classname": "env_sound", "roomtype": "23", "radius": "100"})
	var b := _spawn(EnvSound, {"classname": "env_sound", "roomtype": "14", "radius": "100"})
	SoundSystem.set_room_type(23, a)
	SoundSystem.set_room_type(14, b)  # walked from the cavern into the water
	SoundSystem.release_room_type(a)  # the cavern only now notices we left
	var reverb := AudioServer.get_bus_effect(
		AudioServer.get_bus_index(SoundSystem.WORLD_BUS), 0) as AudioEffectReverb
	assert_gt(reverb.wet, 0.0, "the newer claim survives the older one's release")
	SoundSystem.release_room_type(b)
	assert_eq(reverb.wet, 0.0, "and releasing the current owner does go dry")
