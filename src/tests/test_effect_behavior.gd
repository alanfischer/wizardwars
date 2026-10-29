extends "res://src/tests/test_base.gd"
## EffectBehavior is the shared lifecycle one-shot visual effects (sparks, explosions, flame
## bursts) run on: parts assemble inert, start() plays them, each light fades on its own clock,
## and `lifetime` frees the effect (0 hands that back to the host). Only pure-engine-object part
## builders are covered here; sprites/sounds need real game resources.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.


func _host() -> Node3D:
	var h := Node3D.new()
	h.name = "EffectHost"
	_root().add_child(h)
	_spawned.append(h)
	return h


## A host with a behavior already pointed at it — the shape every effect's _build() has.
func _effect(host: Node3D) -> EffectBehavior:
	var e := EffectBehavior.new()
	e.initialize(host)
	return e


func _children_of_type(host: Node3D, type) -> Array:
	return host.get_children().filter(func(c): return is_instance_of(c, type))


func test_add_flash_builds_a_configured_light() -> void:
	var host := _host()
	var e := _effect(host)
	var flash := e.add_flash(Color(0.4, 0.7, 1.0), 2.0, 2.5)

	assert_eq(_children_of_type(host, OmniLight3D).size(), 1, "the light is parented to the host")
	assert_eq(flash.light_color, Color(0.4, 0.7, 1.0), "color as asked")
	assert_almost_eq(flash.light_energy, 2.0, 0.0001, "energy as asked")
	assert_almost_eq(flash.omni_range, 2.5, 0.0001, "range as asked")
	assert_false(flash.shadow_enabled, "effect lights never cast shadows")
	assert_eq(flash.light_cull_mask, GameConsts.LIGHT_CULL_ALL, "and light everything")


func test_sparks_are_built_inert_and_only_burst_on_start() -> void:
	var host := _host()
	var e := _effect(host)
	e.lifetime = 0.0
	var sparks := e.add_sparks("iceshard", 12, 0.4, 0.08)

	assert_false(sparks.emitting, "a burst assembled before the effect is in the tree stays quiet")
	assert_true(sparks.one_shot, "one shot, not a looping emitter")
	assert_eq(sparks.amount, 12, "amount as asked")
	assert_almost_eq(sparks.lifetime, 0.4, 0.0001, "particle lifetime as asked")

	e.start()
	assert_true(sparks.emitting, "start() fires it")


func test_add_ring_builds_a_named_toroid() -> void:
	var host := _host()
	var e := _effect(host)
	var ring := e.add_ring(Color(0.4, 0.6, 1.0, 0.9))

	assert_eq(ring.name, &"Toroid", "named so the host can find it back")
	assert_eq(_children_of_type(host, MeshInstance3D).size(), 1, "parented to the host")
	assert_almost_eq(ring.material_override.albedo_color.a, 0.9, 0.0001, "keeps the alpha it was given")


func test_each_light_fades_on_its_own_clock() -> void:
	# The comet explosion pairs a slow orange flash with a white core that snaps out
	# faster. A single shared fade duration would flatten that.
	var host := _host()
	var e := _effect(host)
	e.lifetime = 0.0
	var slow := e.add_flash(Color.ORANGE, 4.0, 8.0, 0.5)
	var fast := e.add_flash(Color.WHITE, 4.0, 12.0, 0.1)

	e.start()
	await _tree().create_timer(0.07).timeout
	assert_lt(fast.light_energy, slow.light_energy, "the short fade is further along")
	assert_lt(fast.light_energy, 4.0, "and both have actually started fading")
	assert_lt(slow.light_energy, 4.0, "including the slow one")


func test_a_zero_fade_leaves_a_light_burning() -> void:
	# Persistent flames (fire spiral) hold their light until stop() dims it.
	var host := _host()
	var e := _effect(host)
	e.lifetime = 0.0
	var flash := e.add_flash(Color.ORANGE, 3.0, 3.2, 0.0)

	e.start()
	await _tree().create_timer(0.07).timeout
	assert_almost_eq(flash.light_energy, 3.0, 0.0001, "no fade was armed, so it stays lit")


func test_lifetime_frees_the_effect() -> void:
	var host := _host()
	var e := _effect(host)
	e.lifetime = 0.05
	e.start()

	assert_true(is_instance_valid(host), "still alive right after start")
	await _tree().create_timer(0.15).timeout
	assert_false(is_instance_valid(host), "freed once its lifetime ran out")


func test_zero_lifetime_hands_the_timing_to_the_host() -> void:
	# Stone dust frees itself when its alpha tween lands, not on a timer.
	var host := _host()
	var e := _effect(host)
	e.lifetime = 0.0
	e.start()

	await _tree().create_timer(0.15).timeout
	assert_true(is_instance_valid(host), "nothing armed a free")

	e.finish()
	await _tree().process_frame
	await _tree().process_frame
	assert_false(is_instance_valid(host), "finish() frees it on demand")


func test_finish_can_be_delayed() -> void:
	var host := _host()
	var e := _effect(host)
	e.lifetime = 0.0
	e.start()

	e.finish(0.05)
	assert_true(is_instance_valid(host), "not yet")
	await _tree().create_timer(0.15).timeout
	assert_false(is_instance_valid(host), "freed after the delay")


func test_fade_light_with_no_duration_is_a_no_op() -> void:
	# What start() relies on to leave a persistent flame's light alone.
	var host := _host()
	var e := _effect(host)
	var flash := e.add_flash(Color.WHITE, 2.0)

	e.fade_light(flash, 0.0)
	await _tree().create_timer(0.07).timeout
	assert_almost_eq(flash.light_energy, 2.0, 0.0001, "no tween was armed")
