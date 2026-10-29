extends "res://src/tests/test_base.gd"
## The spirit wizard: what /spawn will answer to, the field of view it hunts with, the stare
## that burns, the body it takes at the cost of a third of itself, and the fact it can be killed.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const SpiritWizScript = preload("res://src/monsters/spirit_wiz.gd")
const SpiritWizWeaponScript = preload("res://src/weapons/spirit_wiz_weapon.gd")

const ARENA := Vector3(300.0, 200.0, 300.0)  # clear of map geometry, and of the other suites'


class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var hits := 0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount
		hits += 1


class DummyAttacker extends Node3D:
	var team := GameConsts.Team.RED
	var peer_id := 0


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _spirit_at(pos: Vector3, facing := Vector3.FORWARD) -> SpiritWiz:
	var w: SpiritWiz = SpiritWizScript.new()
	w.setup({"position": pos, "direction": facing, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(w)
	_keep(w)
	return w


## Carries a hitbox Area3D as well as its body: the spirit's beam resolves its victim through
## MASK_HITBOX, so a target without one is never hit at all.
func _target_at(pos: Vector3) -> DummyTarget:
	var t := _damageable_at(DummyTarget, pos, 0.4, true) as DummyTarget
	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_HITBOX
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	var acs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 1.8, 0.8)
	acs.shape = box
	area.add_child(acs)
	t.add_child(area)
	return t


func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("spirit_wiz"), "the spirit is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("spirit_wiz_weapon"), "the spell that raises it")
	assert_false(SpawnRegistry.has_object("spirit_wiz_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("spirit_wiz_weapon")
	assert_true(w is SpiritWizWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")
	assert_eq(w.get_display_name(), "Spirit Wiz", "and named for what it makes")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("spirit_wiz_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is SpiritWizWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


## What separates it from every other summon here: a field of view. The plant and the tornado
## sense you through the back of their heads; this one has to be looking at you.
func test_it_only_sees_what_is_in_front_of_it() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)   # facing -Z
	var behind := _target_at(ARENA + Vector3(0.0, 0.0, 6.0))  # stood squarely behind it

	await _tick(12)
	assert_eq(spirit._target, null, "it does not know they are there")
	assert_eq(behind.damage_taken, 0.0, "and nothing has touched them")

	# Move them round in front and it picks them up at once.
	behind.global_position = ARENA + Vector3(0.0, 0.0, -6.0)
	await _tick(12)
	assert_eq(spirit._target, behind, "in front of it, it sees them")


## And the way you end up in front of one is by shooting it — being hurt turns it to face you,
## which for something that only burns what it faces is the same as pointing the stare at you.
func test_shooting_it_turns_it_on_you() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)  # facing -Z
	var shooter := DummyAttacker.new()
	_root().add_child(shooter)
	_keep(shooter)
	shooter.global_position = ARENA + Vector3(0.0, 0.0, 8.0)  # squarely behind it
	await _tick(1)

	spirit.take_damage(10.0, GameConsts.DamageType.PHYSICAL, shooter)
	var to_shooter := (shooter.global_position - spirit.global_position).normalized()

	# It comes round at TURN_RATE rather than snapping, so one frame in it is still facing away.
	await _tick(1)
	assert_lt((-spirit.global_transform.basis.z).dot(to_shooter), 0.0, "it does not snap round")

	# Half a second is 2 rad of the half turn it owes, so it is most of the way round by then.
	await _tick(30)
	var facing := -spirit.global_transform.basis.z
	assert_gt(facing.dot(to_shooter), 0.3, "it is coming round on whoever hit it")
	assert_almost_eq(spirit.health, SpiritWiz.MAX_HEALTH - 10.0, 0.01, "and took the hit")


func test_it_drifts_when_it_has_nothing_to_chase() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)
	var start := spirit.global_position

	await _tick(90)  # 1.5s — three of its half-second course changes

	var travelled := spirit.global_position.distance_to(start)
	assert_gt(travelled, 0.1, "it wanders rather than hanging still")
	assert_lt(travelled, SpiritWiz.SPEED * 1.5,
		"at its drift speed, not the charge (%.2f m in 1.5s)" % travelled)
	assert_almost_eq(spirit.global_position.y, start.y, 0.001, "and stays at the height it was left")


## 20 a think at whatever it is facing — 200 a second, which is what makes standing in front of
## one for even a moment a mistake.
func test_the_stare_burns_what_it_is_facing() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)
	var victim := _target_at(ARENA + Vector3(0.0, 0.0, -8.0))

	await _tick(30)  # half a second

	assert_gt(victim.hits, 0, "the stare is landing")
	assert_almost_eq(victim.damage_taken, victim.hits * SpiritWiz.LIT_DAMAGE, 0.01, "20 a time")
	assert_lt(victim.hits, 9, "on its think, not every frame (%d in half a second)" % victim.hits)


## The model arrives with 46 hitbox areas of its own and the beam leaves from inside them, so a
## trace that excludes only the body burns the spirit instead of whatever it is facing. That is
## exactly what happened when the model was swapped for the higher-detail netherspirit build.
func test_the_stare_never_lands_on_the_spirit_itself() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)
	await _tick(1)

	var ray: Dictionary = spirit._lit_ray()
	if not ray.result.is_empty():
		var hit = ray.result.collider
		while hit:
			assert_ne(hit, spirit, "the stare traced straight into the spirit's own hitboxes")
			hit = hit.get_parent() if hit.has_method("get_parent") else null

	await _tick(40)
	assert_almost_eq(spirit.health, SpiritWiz.MAX_HEALTH, 0.01,
		"and it is still at full health, having burned nothing but the air")


## Its other weapon and its clock. Catching a body kills them outright and burns 200 of its own
## 600 doing it, so three is the ceiling and it rarely gets that far.
func test_taking_a_body_costs_it_a_third_of_itself() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)
	var victim := _target_at(ARENA + Vector3(0.0, 0.0, -0.3))  # already inside its hull

	await _tick(2)

	assert_almost_eq(victim.damage_taken, SpiritWiz.TOUCH_DAMAGE, 0.01,
		"whatever it flies into is taken outright")
	assert_almost_eq(spirit.health, SpiritWiz.MAX_HEALTH - SpiritWiz.TOUCH_COST, 0.01,
		"and it spends a third of itself doing it")


## Alone among these summons it can be killed — no team discount, no armour, just 600 of it.
func test_it_can_be_killed_unlike_the_others() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)
	assert_true(spirit.is_in_group("damageable"), "it is a target like anything else")

	var foe := DummyAttacker.new()
	_root().add_child(foe)
	_keep(foe)
	foe.global_position = ARENA + Vector3(0.0, 0.0, -5.0)
	spirit.take_damage(100.0, GameConsts.DamageType.PHYSICAL, foe)
	assert_almost_eq(spirit.health, SpiritWiz.MAX_HEALTH - 100.0, 0.01,
		"full damage — unlike the giant plant there is no discount for anyone")

	spirit.take_damage(SpiritWiz.MAX_HEALTH, GameConsts.DamageType.PHYSICAL, foe)
	await _tick(2)
	assert_false(is_instance_valid(spirit), "and enough of it puts the spirit down")


func test_it_will_not_touch_its_own_side() -> void:
	var spirit := _spirit_at(ARENA, Vector3.FORWARD)  # team BLUE
	var ally := _target_at(ARENA + Vector3(0.0, 0.0, -0.3))
	ally.team = GameConsts.Team.BLUE

	await _tick(12)

	assert_eq(ally.damage_taken, 0.0, "a teammate inside it is unharmed")
	assert_almost_eq(spirit.health, SpiritWiz.MAX_HEALTH, 0.01, "and it spends nothing on them")
	assert_eq(spirit._target, null, "nor does it hunt them")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("spirit_wiz_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("spirit_wiz_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("spirit_wiz_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("spirit_wiz_weapon"), "another book grants it again")
	p.free()
