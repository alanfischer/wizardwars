extends "res://src/tests/test_base.gd"
## The meteor strike: what /spawn will answer to, the cone the caster has to have someone in,
## the lock that cannot be broken, and the wasted book when there is nobody to call it on.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const MeteorScript = preload("res://src/projectiles/meteor.gd")
const MeteorWeaponScript = preload("res://src/weapons/meteor_weapon.gd")

const METEOR_COUNT := MeteorWeaponScript.METEOR_COUNT

const ARENA := Vector3(-300.0, 200.0, -300.0)  # clear of map geometry, and of the other suites'


class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after, then the host-only lock.
func _meteor_at(pos: Vector3, target: Node3D) -> Meteor:
	var m: Meteor = MeteorScript.new()
	m.setup({"position": pos, "target_pos": SpatialQuery.collision_center(target)}, true)
	_root().add_child(m)
	m.set_target(target)
	_keep(m)
	return m


func _target_at(pos: Vector3) -> DummyTarget:
	return _damageable_at(DummyTarget, pos) as DummyTarget


func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("meteor"), "a meteor is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("meteor_weapon"), "the spell that calls them")
	assert_false(SpawnRegistry.has_object("meteor_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("meteor_weapon")
	assert_true(w is MeteorWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")
	assert_eq(w.get_display_name(), "Meteor", "and named for what it calls")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("meteor_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is MeteorWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


## The lock is the whole spell: it noclips the entire way in, so there is no cover, and it
## re-steers every frame, so there is no outrunning it either. Only leaving is an answer.
func test_it_rides_its_target_down_through_anything_in_the_way() -> void:
	var victim := _target_at(ARENA)
	_wall_at(ARENA + Vector3(0.0, 6.0, 0.0), Vector3(30.0, 1.0, 30.0))  # a roof over their head
	var meteor := _meteor_at(ARENA + Vector3(0.0, 20.0, 0.0), victim)
	var start := meteor.global_position.distance_to(victim.global_position)

	await _tick(30)
	assert_true(is_instance_valid(meteor), "the roof does not stop it")
	assert_lt(meteor.global_position.distance_to(victim.global_position), start - 4.0,
		"it has come through and is still closing")

	# And it follows them: stepping aside only bends the line it is falling down.
	victim.global_position = ARENA + Vector3(9.0, 0.0, 0.0)
	await _tick(12)
	var to_victim := (SpatialQuery.collision_center(victim) - meteor.global_position).normalized()
	assert_gt(meteor.direction.dot(to_victim), 0.99, "still pointed straight at them")


func test_it_bursts_when_it_arrives() -> void:
	var victim := _target_at(ARENA)
	var meteor := _meteor_at(ARENA + Vector3(0.0, 8.0, 0.0), victim)

	await _tick(60)  # 10 m/s covers the 8 m with room to spare

	assert_almost_eq(victim.damage_taken, Meteor.DAMAGE, 0.01, "600 where it lands")
	assert_false(is_instance_valid(meteor), "and the meteor is gone")


## The point of a strike is that it lands as one blow. Three meteors called on the same tick from
## three directions hold themselves to the same arrival, so a target who runs the whole way in
## takes all three at once rather than one, then another, then the last.
func test_all_three_land_together_on_a_running_target() -> void:
	var victim := _target_at(ARENA)
	var center := SpatialQuery.collision_center(victim)
	var meteors: Array = []
	for dir in [Vector3.UP, Vector3(1, 1, 0).normalized(), Vector3(-1, 1, 1).normalized()]:
		meteors.append(_meteor_at(center + dir * 24.0, victim))

	var tree := Engine.get_main_loop() as SceneTree
	var landed_on := -1
	for frame in 200:
		victim.global_position += Vector3(0.15, 0.0, 0.0)  # running flat out, about 9 m/s
		await tree.physics_frame
		if victim.damage_taken > 0.0:
			landed_on = frame
			break

	assert_gt(landed_on, 0, "the strike arrived")
	assert_almost_eq(victim.damage_taken, Meteor.DAMAGE * METEOR_COUNT, 0.01,
		"and all of it on the one tick")
	await _tick(8)
	for meteor in meteors:
		assert_false(is_instance_valid(meteor), "with nothing left hanging in the air")


## The rest of a strike is wasted on a target who dies before it lands — the others burst
## wherever they are, usually still in the air. That is the risk of calling three on one wizard.
func test_a_target_who_dies_first_wastes_the_rest_of_the_strike() -> void:
	var victim := _target_at(ARENA)
	var bystander := _target_at(ARENA + Vector3(0.0, 30.0, 0.0))  # up where the meteor still is
	var meteor := _meteor_at(ARENA + Vector3(0.0, 32.0, 0.0), victim)
	await _tick(6)

	victim.is_dead = true
	await _tick(6)

	assert_false(is_instance_valid(meteor), "it gives up the moment its target is down")
	assert_eq(victim.damage_taken, 0.0, "with nothing reaching the wizard it was called on")
	assert_gt(bystander.damage_taken, 0.0, "and the blast spent up in the air instead")


## Sideways from anywhere, but never from underneath — the original rolled the vertical axis as
## 0 or 1, so a strike always comes down on you.
func test_every_approach_comes_from_level_or_above() -> void:
	var weapon: MeteorWeapon = MeteorWeaponScript.new()
	var seen_up := false
	var seen_level := false
	var from_below := Vector3.ZERO
	var worst_length := 0.0
	for i in 200:  # the roll has few outcomes, so sample it properly rather than assert per draw
		var dir: Vector3 = weapon._approach()
		worst_length = maxf(worst_length, absf(dir.length() - 1.0))
		if dir.y < -0.001:
			from_below = dir
		elif dir.y > 0.001:
			seen_up = true
		else:
			seen_level = true
	assert_almost_eq(worst_length, 0.0, 0.001, "every roll is a direction, not a distance")
	assert_eq(from_below, Vector3.ZERO, "and none of them comes from below")
	assert_true(seen_up, "some come down on you")
	assert_true(seen_level, "and some come in flat")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("meteor_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("meteor_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("meteor_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("meteor_weapon"), "another book grants it again")
	p.free()
