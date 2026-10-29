extends "res://src/tests/test_base.gd"
## Beam noise must match GoldSrc's R_DrawSegs: `(NoiseAmplitude/10) * max(length_in_units * 0.01, 0.5)`,
## perpendicular to the beam. We used to apply raw NoiseAmplitude as metres in all 3 axes, 1x-20x too much sway.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const EnvBeamScript = preload("res://src/entities/env_beam.gd")


func _beam(noise_amplitude: String) -> EnvBeam:
	var b: EnvBeam = EnvBeamScript.new()
	b.set_meta("entity", {
		"classname": "env_beam", "targetname": "b1",
		"LightningStart": "s", "LightningEnd": "e",
		"texture": "sprites/laserbeam.spr", "BoltWidth": "20",
		"NoiseAmplitude": noise_amplitude,
	})
	_root().add_child(b)
	_spawned.append(b)
	return b


## The GoldSrc figure, worked out independently of the implementation.
func _expected(noise_amplitude: float, length_units: float) -> float:
	return (noise_amplitude / 10.0) * maxf(length_units * 0.01, 0.5) * GameConsts.SCALE_FACTOR


func test_golem_smoke_matches_goldsrc() -> void:
	# ww_golem house3smoke: NoiseAmplitude 10 over a 120-unit column.
	var b := _beam("10")
	var got := b._noise_amplitude_for(120.0 * GameConsts.SCALE_FACTOR)
	assert_almost_eq(got, _expected(10.0, 120.0), 0.0001,
		"smoke sways by centimetres, not the 0.25 m it used to")
	# BoltWidth 80 makes that column 0.2 m across: the sway is a fraction of it, not double.
	assert_lt(got, 0.1, "and stays well inside the column's own width")


func test_shrinkspell_laser_matches_goldsrc() -> void:
	# The screen lasers: NoiseAmplitude 100 over ~479 units.
	var b := _beam("100")
	var got := b._noise_amplitude_for(479.0 * GameConsts.SCALE_FACTOR)
	assert_almost_eq(got, _expected(100.0, 479.0), 0.0001, "laser sway follows the same rule")
	var beam_len := 479.0 * GameConsts.SCALE_FACTOR
	assert_lt(got / beam_len, 0.15, "sway stays a modest fraction of the beam's length")


func test_sway_scales_with_beam_length() -> void:
	# The property we were missing entirely: a long beam sways more than a short one.
	var b := _beam("100")
	var short_beam := b._noise_amplitude_for(200.0 * GameConsts.SCALE_FACTOR)
	var long_beam := b._noise_amplitude_for(800.0 * GameConsts.SCALE_FACTOR)
	assert_gt(long_beam, short_beam * 3.0, "4x the length, ~4x the sway")


func test_very_short_beams_keep_a_floor_of_movement() -> void:
	# GoldSrc floors the length factor at 0.5 so stubby beams don't go rigid.
	var b := _beam("100")
	var stub := b._noise_amplitude_for(10.0 * GameConsts.SCALE_FACTOR)
	assert_almost_eq(stub, _expected(100.0, 10.0), 0.0001, "floored, not proportional")
	assert_gt(stub, 0.0, "and still moves")


func test_sway_is_perpendicular_to_the_beam() -> void:
	# Displacing along the beam just bunches segments; GoldSrc sways across it.
	var b := _beam("100")
	var from := Vector3.ZERO
	var to := Vector3(10, 0, 0)
	b._noise_amp = b._noise_amplitude_for(from.distance_to(to))
	b._update_noise_axes(from, to)
	var noise_fn := b._make_noise_fn()
	var dir := (to - from).normalized()
	for t in [0.25, 0.5, 0.75]:
		var offset: Vector3 = noise_fn.call(t)
		assert_lt(absf(offset.dot(dir)), 0.0001,
			"offset at t=%.2f has no component along the beam" % t)
		assert_gt(offset.length(), 0.0, "but it does move")


func test_zero_amplitude_means_no_noise() -> void:
	var b := _beam("0")
	assert_eq(b._noise_amplitude_for(10.0), 0.0, "NoiseAmplitude 0 leaves the beam straight")
	assert_eq(b._make_noise_fn().call(0.5), Vector3.ZERO, "and the noise function is inert")
