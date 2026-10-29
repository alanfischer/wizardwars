extends "res://src/tests/test_base.gd"
## Multiple cockleburrs on one victim must restore original speed_multiplier when the LAST one
## detaches, even if that isn't the burr that attached first (which is the one holding the cache).

const CockleburrScript = preload("res://src/monsters/cockleburr.gd")


class DummyVictim extends Node3D:
	var speed_multiplier := 1.0
	var team := 0
	var is_dead := false


func test_restore_when_first_attacher_detaches_first() -> void:
	var victim := DummyVictim.new()
	_root().add_child(victim)

	var b1: Cockleburr = CockleburrScript.new()
	b1.setup({"position": Vector3.ZERO}, true)
	_root().add_child(b1)
	var b2: Cockleburr = CockleburrScript.new()
	b2.setup({"position": Vector3.ZERO}, true)
	_root().add_child(b2)

	b1._attach_to(victim)
	b2._attach_to(victim)
	assert_almost_eq(victim.speed_multiplier, 0.5, 0.001,
		"both burrs attached: victim slowed once")

	# The FIRST attacher (holding the cached original speed) detaches first.
	b1._detach()
	assert_almost_eq(victim.speed_multiplier, 0.5, 0.001,
		"one burr remains attached: victim still slowed")

	# Last burr detaches — must restore speed even though it didn't cache it.
	b2._detach()
	assert_almost_eq(victim.speed_multiplier, 1.0, 0.001,
		"all burrs gone: original speed restored")

	b1.queue_free()
	b2.queue_free()
	victim.queue_free()
