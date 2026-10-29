extends "res://src/tests/test_base.gd"
## A bird shot out of the air answers to the same rule every other death does: a blow over
## GameConsts.GIB_DAMAGE bursts it, anything smaller kills it the way it always did. The bird
## reads the blow that killed it (HealthBehavior.last_damage), not the overkill — a bird has
## 20 hp, so nothing would ever clear the bar if it were measured the other way.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const BirdScript = preload("res://src/projectiles/bird.gd")

const ARENA := Vector3(0.0, 160.0, 0.0)  # clear of map geometry


## Records the two halves of the death instead of running them: the burst is headless-guarded
## and leaves nothing to inspect, and the real _die would take the node with it.
class SpyBird:
	extends BirdScript
	var bursts := 0
	var deaths := 0
	func _burst() -> void:
		bursts += 1
	func _die() -> void:
		deaths += 1


func _bird() -> SpyBird:
	var b := SpyBird.new()
	b.setup({"position": ARENA, "direction": Vector3.FORWARD, "team": 1}, true)
	_root().add_child(b)
	b.global_position = ARENA
	_keep(b)
	return b


func test_a_big_enough_blow_bursts_it() -> void:
	var b := _bird()
	b.take_damage(GameConsts.GIB_DAMAGE + 1.0)
	assert_eq(b.bursts, 1, "over the bar the bird comes apart")
	assert_eq(b.deaths, 1, "and it is dead either way")


func test_a_lethal_blow_under_the_bar_leaves_it_whole() -> void:
	var b := _bird()
	b.take_damage(BirdScript.PROJECTILE_HP)  # kills it outright, and is still under the bar
	assert_eq(b.bursts, 0, "under the bar it dies the way it always did")
	assert_eq(b.deaths, 1, "dead all the same")


func test_the_last_blow_is_what_counts_not_the_total() -> void:
	# Two small hits kill a 20 hp bird between them, and neither one was a burst — the rule
	# reads the blow that landed, never what it had taken before.
	var b := _bird()
	b.take_damage(BirdScript.PROJECTILE_HP * 0.5)
	assert_eq(b.deaths, 0, "the first hit was not lethal")
	b.take_damage(BirdScript.PROJECTILE_HP * 0.5)
	assert_eq(b.bursts, 0, "and the second finished it without bursting it")
	assert_eq(b.deaths, 1, "dead on the second")


func test_a_bird_on_its_way_out_cannot_be_shot_down() -> void:
	# It spent itself and is climbing away as scenery; nothing touches it, so nothing can burst it.
	var b := _bird()
	b._begin_escape()
	b.take_damage(GameConsts.GIB_DAMAGE * 10.0)
	assert_eq(b.bursts, 0, "a bird already leaving takes no hit")
	assert_eq(b.deaths, 0, "and is not killed a second time")


## A bird is damageable only so it can be shot out of the air — never a thing to shoot at.
## Without "unhunted" another bird, a skull or a bot locks onto it mid-flight.
func test_a_bird_is_shootable_but_never_a_target() -> void:
	var b := _bird()
	assert_true(b.is_in_group("damageable"), "a shot can bring it down")
	assert_true(b.is_in_group("unhunted"), "and nothing hunts it while it flies")
