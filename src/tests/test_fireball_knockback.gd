extends "res://src/tests/test_base.gd"
## What a fireball does to the people standing in it: shoved away from the blast, harder the
## closer they were, and the caster shoved along with everyone else — that is the rocket jump.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const MovementConfig = preload("res://addons/pmove/movement_config.gd")

const ARENA := Vector3(300.0, 400.0, 300.0)  # clear of map geometry, and of the other suites'
const FEET := Vector3(0.0, -0.9, 0.0)        # blast at the caster's feet, half a hull below centre


class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED


func _target_at(pos: Vector3, team := GameConsts.Team.RED) -> DummyTarget:
	var t := _damageable_at(DummyTarget, pos) as DummyTarget
	t.team = team
	return t


func _space() -> PhysicsDirectSpaceState3D:
	return (_root() as Window).get_world_3d().direct_space_state


func _blast(at: Vector3, attacker: Node3D = null) -> void:
	Combat.apply_aoe_knockback(_space(), at, Fireball.FIREBALL_KNOCKBACK, Fireball.FIREBALL_RADIUS, attacker)


func test_the_blast_throws_people_away_from_it() -> void:
	var victim := _target_at(ARENA + Vector3(2.0, 0.0, 0.0))
	await _tick(2)
	_blast(ARENA)

	assert_gt(victim.velocity.x, 0.0, "thrown along the line out of the blast")
	assert_almost_eq(victim.velocity.y, 0.0, 0.001, "and only along it — no upward bias")
	assert_almost_eq(victim.velocity.z, 0.0, 0.001, "nor sideways")
	# 2 m out of a 4 m radius is half strength.
	assert_almost_eq(victim.velocity.x, Fireball.FIREBALL_KNOCKBACK * 0.5, 0.01, "half strength at half the radius")


func test_the_shove_fades_with_distance() -> void:
	var near := _target_at(ARENA + Vector3(1.0, 0.0, 0.0))
	var far := _target_at(ARENA + Vector3(3.5, 0.0, 0.0))
	var outside := _target_at(ARENA + Vector3(4.5, 0.0, 0.0))
	await _tick(2)
	_blast(ARENA)

	assert_gt(near.velocity.x, far.velocity.x, "the closer one goes further")
	assert_gt(far.velocity.x, 0.0, "but the far one still moves")
	assert_eq(outside.velocity, Vector3.ZERO, "past the radius nothing reaches you")


## The whole point: your own fireball at your own feet has to launch you, and launch you
## harder than a jump, or there is no rocket jump in it.
func test_the_caster_is_thrown_too() -> void:
	var caster := _target_at(ARENA)
	await _tick(2)
	_blast(ARENA + FEET, caster)

	assert_gt(caster.velocity.y, MovementConfig.new().jump_speed, "launched higher than a jump")
	assert_almost_eq(caster.velocity.x, 0.0, 0.001, "straight up, since the blast was straight down")


func test_teammates_are_left_standing() -> void:
	var caster := _target_at(ARENA, GameConsts.Team.BLUE)
	var friend := _target_at(ARENA + Vector3(2.0, 0.0, 0.0), GameConsts.Team.BLUE)
	var enemy := _target_at(ARENA + Vector3(-2.0, 0.0, 0.0), GameConsts.Team.RED)
	await _tick(2)
	_blast(ARENA + FEET, caster)

	assert_eq(friend.velocity, Vector3.ZERO, "your own side is spared, same as the damage")
	assert_lt(enemy.velocity.x, 0.0, "theirs is not")
	assert_gt(caster.velocity.y, 0.0, "and being on your own team never spares you")


func test_a_wall_takes_the_shove_as_well_as_the_damage() -> void:
	var sheltered := _target_at(ARENA + Vector3(2.0, 0.0, 0.0))
	_wall_at(ARENA + Vector3(1.0, 0.0, 0.0), Vector3(0.5, 6.0, 6.0))
	await _tick(2)
	_blast(ARENA)

	assert_eq(sheltered.velocity, Vector3.ZERO, "cover stops the push, not just the damage")


## The wind satchel and updraft lean their push skyward rather than sideways.
func test_an_upward_bias_lifts_instead_of_shoving() -> void:
	var level := _target_at(ARENA + Vector3(2.0, 0.0, 0.0))
	await _tick(2)
	Combat.apply_aoe_knockback(_space(), ARENA, 10.0, 4.0, null, 1.0)

	assert_almost_eq(level.velocity.y, level.velocity.x, 0.01, "an equal lift is 45 degrees up")
	assert_gt(level.velocity.x, 0.0, "still carried out of the blast, not just up")


## Updraft repeats while the button is held; adding each cast would stack a victim into orbit,
## so the push sets the speed along its own axis instead.
func test_a_repeat_cast_does_not_stack_into_orbit() -> void:
	var victim := _target_at(ARENA + Vector3(2.0, 0.0, 0.0))
	await _tick(2)
	Combat.apply_aoe_knockback(_space(), ARENA, 10.0, 4.0, null, 0.0, true)
	var first := victim.velocity
	Combat.apply_aoe_knockback(_space(), ARENA, 10.0, 4.0, null, 0.0, true)

	assert_vec3_almost_eq(victim.velocity, first, 0.001, "the second cast lands them where the first did")


## The wind satchel scales its damage by the same falloff, off the returned factors.
func test_it_reports_the_falloff_it_used() -> void:
	var near := _target_at(ARENA + Vector3(1.0, 0.0, 0.0))
	var outside := _target_at(ARENA + Vector3(4.5, 0.0, 0.0))
	await _tick(2)
	var pushed := Combat.apply_aoe_knockback(_space(), ARENA, Fireball.FIREBALL_KNOCKBACK, Fireball.FIREBALL_RADIUS)

	assert_almost_eq(pushed.get(near, 0.0), 0.75, 0.001, "1 m into a 4 m radius is three quarters")
	assert_false(pushed.has(outside), "and nobody out of range is reported")
