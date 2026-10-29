extends "res://src/tests/test_base.gd"
## env_laser (GoldSrc CLaser) rides env_beam's rendering, but starts at its OWN origin and ends
## at the entity named by LaserTarget, and spells beam width "width" not "BoltWidth".
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _teardown_test() -> void:
	_despawn_all()
	TriggerSystem.reset()


## A laser with ww_shrinkspell's real key set. `keys` overrides/adds.
func _laser(keys := {}) -> EnvLaser:
	var e := {
		"classname": "env_laser", "targetname": "screen1", "LaserTarget": "ct",
		"texture": "sprites/laserbeam.spr", "width": "10", "damage": "100",
		"NoiseAmplitude": "100", "TextureScroll": "70",
		"rendercolor": "221 164 255", "renderamt": "100",
	}
	e.merge(keys, true)
	var l := EnvLaser.new()
	l.set_meta("entity", e)
	_root().add_child(l)
	_spawned.append(l)
	return l


func _endpoint(marker_name: String, pos: Vector3) -> NamedMarker:
	var m := NamedMarker.new()
	m.set_meta("entity", {"classname": "info_target", "targetname": marker_name})
	_root().add_child(m)
	m.global_position = pos
	_spawned.append(m)
	return m


func test_starts_at_itself_and_ends_at_laser_target() -> void:
	_endpoint("ct", Vector3(27.4, 14.4, -27.4))
	var l := _laser()
	l.global_position = Vector3(37.4, 8.5, -24.7)
	l._resolve_endpoints()
	assert_eq(l._start_node, l, "the laser is its own start point")
	assert_true(l._end_node != null, "LaserTarget resolved to the endpoint marker")
	assert_vec3_almost_eq(l._end_node.global_position, Vector3(27.4, 14.4, -27.4), 0.001,
		"and it is the marker we named")


func test_width_key_maps_onto_the_beam_width() -> void:
	# GoldSrc beam widths are 0.1-unit steps; env_beam halves them for BeamSystem.
	var l := _laser({"width": "10"})
	assert_almost_eq(l._width, 10.0 * 0.1 * GameConsts.SCALE_FACTOR * 0.5, 0.0001,
		"width 10 becomes a 1-unit-wide beam, not env_beam's default 20")


func test_damage_is_scaled_to_per_second() -> void:
	# CLaser fires every 0.1s for dmg * elapsed — "damage" is a per-second rate.
	var l := _laser({"damage": "100"})
	assert_almost_eq(l._damage, 100.0 * EnvBeam.DAMAGE_INTERVAL, 0.001,
		"the per-tick figure works out to `damage` per second")


func test_named_laser_starts_off_and_toggles() -> void:
	# The screen lasers have targetnames and no START_ON flag, so they wait for
	# their multi_manager. Each screenmm fires TOGGLE.
	var l := _laser()
	assert_false(l.visible, "a named laser with no Start On flag begins dark")
	l.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_true(l._game_visible, "first toggle lights it")
	l.trigger(null, TriggerSystem.Type.TOGGLE)
	assert_false(l._game_visible, "second toggle darkens it again")


func test_untargeted_laser_is_always_on() -> void:
	var l := _laser({"targetname": ""})
	assert_true(l.visible, "no targetname means nothing can switch it, so it burns constantly")
