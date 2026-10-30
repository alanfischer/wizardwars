extends "res://src/tests/test_base.gd"
## A corpse starts with what killed it, as in the original: the killing blow's DamageForce shove
## (CBaseMonster::TakeDamage), aimed away from whatever dealt it, and then CBasePlayer::Killed's
## hop for a body that isn't already rising.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const ARENA := Vector3(-300.0, 400.0, 300.0)  # clear of map geometry, and of the other suites'
const PER_POINT := 5.0 * GameConsts.SCALE_FACTOR
const HOP_MAX := 300.0 * GameConsts.SCALE_FACTOR


## Asks for the shove the way Player.take_damage does, from inside the blow.
class Victim extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var health := 100.0
	var push := Vector3.ZERO
	var velocity_at_death := Vector3.INF

	func take_damage(amount: float, _type: int, attacker: Node3D = null) -> void:
		push = Combat.damage_force(self, amount, attacker)
		health -= amount
		if health <= 0.0 and not is_dead:
			is_dead = true
			velocity_at_death = velocity


## Records the body a death leaves, read where RemotePlayer/LocalPlayer read it.
class DyingWizard extends Player:
	var corpse := Vector3.INF

	func _on_died(_attacker: Node3D, _type: int = GameConsts.DamageType.PHYSICAL,
			_damage: float = 0.0) -> void:
		corpse = corpse_velocity(velocity)


func _victim_at(pos: Vector3) -> Victim:
	return _damageable_at(Victim, pos) as Victim


func _attacker_at(pos: Vector3) -> Victim:
	var a := _victim_at(pos)
	a.team = GameConsts.Team.BLUE
	return a


func test_a_blow_shoves_away_from_whoever_dealt_it() -> void:
	var attacker := _attacker_at(ARENA)
	var victim := _victim_at(ARENA + Vector3(3.0, 0.0, 0.0))
	await _settle()
	Combat.damage_chain(victim, 20.0, GameConsts.DamageType.PHYSICAL, attacker)

	assert_gt(victim.push.x, 0.0, "thrown out along the line from the attacker")
	assert_gt(victim.push.y, 0.0, "and a little up: the inflictor is taken to sit 10 units low")
	assert_almost_eq(victim.push.length(), 20.0 * PER_POINT, 0.001, "5 u/s per point of damage")


func test_the_shove_is_capped_at_1000_units() -> void:
	var attacker := _attacker_at(ARENA)
	var victim := _victim_at(ARENA + Vector3(3.0, 0.0, 0.0))
	await _settle()

	assert_almost_eq(Combat.damage_force(victim, 500.0, attacker).length(),
		1000.0 * GameConsts.SCALE_FACTOR, 0.001, "DamageForce never passes 1000 u/s")


func test_a_projectile_shoves_from_where_it_struck_not_from_the_caster() -> void:
	var attacker := _attacker_at(ARENA)
	var victim := _victim_at(ARENA + Vector3(3.0, 0.0, 0.0))
	await _settle()
	var struck_at := SpatialQuery.collision_center(victim) + Vector3(0.0, 0.0, -1.0)
	Combat.damage_chain(victim, 20.0, GameConsts.DamageType.PHYSICAL, attacker, struck_at)

	assert_gt(victim.push.z, 0.0, "away from the projectile")
	assert_almost_eq(victim.push.x, 0.0, 0.001, "whatever side the caster stood on")


func test_a_blast_shoves_from_its_centre() -> void:
	var attacker := _attacker_at(ARENA)
	var victim := _victim_at(ARENA + Vector3(3.0, 0.0, 0.0))
	await _settle()
	var under := SpatialQuery.collision_center(victim) + Vector3(0.0, -1.5, 0.0)
	Combat.apply_aoe_damage(_root().get_world_3d().direct_space_state, under, 20.0, 3.0, {},
		GameConsts.DamageType.FIRE, attacker)

	assert_gt(victim.push.y, victim.push.length() * 0.99, "a blast underfoot throws straight up")


func test_the_inflictor_ends_with_its_blow() -> void:
	var attacker := _attacker_at(ARENA)
	var victim := _victim_at(ARENA + Vector3(3.0, 0.0, 0.0))
	await _settle()
	Combat.damage_chain(victim, 20.0, GameConsts.DamageType.PHYSICAL, attacker,
		SpatialQuery.collision_center(victim) + Vector3(0.0, 0.0, -1.0))
	Combat.damage_chain(victim, 20.0, GameConsts.DamageType.PHYSICAL, attacker)

	assert_gt(victim.push.x, 0.0, "the next blow is the attacker's again")
	assert_almost_eq(victim.push.z, 0.0, 0.001, "not the last projectile's")


func test_a_blow_from_nothing_shoves_nothing() -> void:
	var victim := _victim_at(ARENA)
	await _settle()
	Combat.damage_chain(victim, 20.0, GameConsts.DamageType.FIRE, null)

	assert_eq(victim.push, Vector3.ZERO, "lava, a fall and a burn have no inflictor")


func test_a_body_already_rising_gets_no_hop() -> void:
	var p := _wizard()
	assert_eq(p.corpse_velocity(Vector3(1.0, 5.0, 0.0)), Vector3(1.0, 5.0, 0.0),
		"Killed only tosses a body that isn't going up already")


func test_a_body_that_isnt_rising_is_tossed_up() -> void:
	var p := _wizard()
	var highest := 0.0
	for _i in 64:
		var v := p.corpse_velocity(Vector3(2.0, -1.0, 0.0))
		assert_eq(v.x, 2.0, "the hop is straight up")
		assert_true(v.y >= -1.0 and v.y <= -1.0 + HOP_MAX, "by 0-300 u/s")
		highest = maxf(highest, v.y)
	assert_gt(highest, 0.0, "and it does leave the ground")


func test_the_killing_blow_reaches_the_corpse() -> void:
	var attacker := _attacker_at(ARENA)
	var p := DyingWizard.new()
	_keep(p)
	var col := CollisionShape3D.new()
	col.shape = CapsuleShape3D.new()
	p.add_child(col)
	p.add_to_group("damageable")
	_root().add_child(p)
	p.global_position = ARENA + Vector3(3.0, 0.0, 0.0)
	await _settle()
	p.health = 10.0
	p.velocity = Vector3(0.0, 9.0, 0.0)  # rising, so the hop stays out of it
	p.take_damage(20.0, GameConsts.DamageType.PHYSICAL, attacker)

	assert_true(p.is_dead, "the blow killed")
	assert_gt(p.corpse.x, 0.0, "and the body is thrown away from the killer")
	assert_almost_eq(p.corpse.length(), (Vector3(0.0, 9.0, 0.0)
		+ Combat.damage_force(p, 20.0, attacker)).length(), 0.001, "by the blow, on its own speed")
	assert_eq(p.corpse_velocity(Vector3(0.0, 9.0, 0.0)), Vector3(0.0, 9.0, 0.0),
		"the shove is spent on that one body")


## The fireball pushes before it burns, or whoever the blast kills is skipped by the push.
func test_a_fireball_shoves_the_wizard_it_kills() -> void:
	var victim := _victim_at(ARENA + Vector3(2.0, 0.0, 0.0))
	victim.health = 1.0
	var ball: Fireball = Fireball.new()
	ball.setup({"position": ARENA, "direction": Vector3.FORWARD})
	_root().add_child(ball)
	ball.global_position = ARENA
	await _settle()
	ball._explode()

	assert_true(victim.is_dead, "the blast killed")
	assert_gt(victim.velocity_at_death.x, 0.0, "already thrown when it died")
