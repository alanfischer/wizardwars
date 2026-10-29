extends "res://src/tests/test_base.gd"
## The wombat: what /spawn will answer to, the bite for an enemy and the blessing for a
## teammate, the throw that carries before it starts hunting, and being made someone's by
## being shot.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const WombatScript = preload("res://src/monsters/wombat.gd")
const WombatWeaponScript = preload("res://src/weapons/wombat_weapon.gd")

const ARENA := Vector3(-300.0, 200.0, 300.0)  # clear of map geometry, and of the other suites'


class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var healed := 0.0
	var bites := 0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount
		bites += 1

	func heal(amount: float, _healer: Node3D = null, _overheal := false) -> void:
		healed += amount


class DummyAttacker extends Node3D:
	var team := GameConsts.Team.RED
	var peer_id := 0


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _wombat_at(pos: Vector3, vel := Vector3.ZERO) -> Wombat:
	var w: Wombat = WombatScript.new()
	w.setup({"position": pos, "velocity": vel, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(w)
	_keep(w)
	return w


func _target_at(pos: Vector3, team := GameConsts.Team.RED) -> DummyTarget:
	var t := _damageable_at(DummyTarget, pos) as DummyTarget
	t.team = team
	return t


func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("wombat"), "the wombat is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("wombat_weapon"), "the spell that throws it")
	assert_false(SpawnRegistry.has_object("wombat_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("wombat_weapon")
	assert_true(w is WombatWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")
	assert_eq(w.get_display_name(), "Wombat", "and named for what it throws")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("wombat_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is WombatWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


func test_it_bites_an_enemy_it_lands_on() -> void:
	var wombat := _wombat_at(ARENA)
	var foe := _target_at(ARENA + Vector3(0.0, -0.3, 0.0))  # under its feet

	await _tick(3)

	assert_almost_eq(foe.damage_taken, Wombat.BITE_DAMAGE, 0.01, "100 a bite")
	assert_eq(foe.healed, 0.0, "and nothing kind about it")


## The half of the spell nothing else in the set does: it is worth throwing into your own side.
func test_it_heals_a_teammate_it_lands_on() -> void:
	var wombat := _wombat_at(ARENA)
	var friend := _target_at(ARENA + Vector3(0.0, -0.3, 0.0), GameConsts.Team.BLUE)

	await _tick(3)

	assert_almost_eq(friend.healed, Wombat.BLESS_HEAL, 0.01, "200 for a teammate")
	assert_eq(friend.damage_taken, 0.0, "and it never bites them")


## The throw carries where it was aimed: the original held the first hunt off until the wombat
## had bounced off something, so it does not curve away in mid-air.
func test_it_waits_for_its_first_bounce_before_it_starts_hunting() -> void:
	var wombat := _wombat_at(ARENA, Vector3(0.0, 0.0, -Wombat.LAUNCH_SPEED))
	_target_at(ARENA + Vector3(8.0, 0.0, 0.0))  # off to one side, well inside its sight

	await _tick(150)  # 2.5s — more than a hunt interval, with nothing to bounce off yet
	assert_eq(wombat._target, null, "still nobody's, mid-flight")

	# Give it a floor to land on and it wakes up.
	_floor_at(wombat.global_position - Vector3(0.0, 1.0, 0.0))
	await _tick(60)
	assert_true(wombat._bounced, "it has hit something now")


## The whole point of the summon: put one down in a room with an enemy and it goes and gets
## them, rather than bouncing wherever it was thrown until its forty seconds run out.
func test_it_hunts_down_a_wizard_across_the_room() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.6, 0.0))
	var wombat := _wombat_at(ARENA, Vector3(0.0, 0.0, 0.5))  # dropped, not thrown at anyone
	var foe := _target_at(ARENA + Vector3(10.0, -0.2, 0.0))
	var start := wombat.global_position.distance_to(foe.global_position)

	await _tick(300)  # five seconds

	assert_true(is_instance_valid(wombat), "it is still on the clock")
	assert_lt(wombat.global_position.distance_to(foe.global_position), start * 0.5,
		"it crossed the room to them")
	assert_gt(foe.damage_taken, 0.0, "and got its teeth in")


## It is a four-footed thing, not a ball: hop spins any rigid body with an inertia tensor, and
## a wombat rolling end over end is what that looks like on screen.
func test_it_lands_on_its_feet() -> void:
	_floor_at(ARENA - Vector3(0.0, 1.6, 0.0))
	var wombat := _wombat_at(ARENA, Vector3(6.0, 0.0, 3.0))
	_target_at(ARENA + Vector3(8.0, -0.2, 4.0))
	var worst := 0.0

	for i in 300:
		await _tick(1)
		worst = maxf(worst, maxf(absf(wombat.rotation.x), absf(wombat.rotation.z)))

	assert_lt(worst, 0.01, "never tipped off its feet (%.2f rad)" % worst)


func test_shooting_it_makes_it_yours() -> void:
	var wombat := _wombat_at(ARENA)
	var shooter := DummyAttacker.new()
	_root().add_child(shooter)
	_keep(shooter)
	shooter.global_position = ARENA + Vector3(6.0, 0.0, 0.0)
	await _tick(1)

	wombat.take_damage(50.0, GameConsts.DamageType.PHYSICAL, shooter)

	assert_eq(wombat._target, shooter, "it drops what it was doing and comes for them")
	assert_almost_eq(wombat.health, Wombat.MAX_HEALTH - 50.0, 0.01, "and took the hit")


## Half a second between one bite and the next, so a wombat sitting on someone can't chew
## through them a frame at a time.
func test_a_bite_waits_out_its_cooldown() -> void:
	_wombat_at(ARENA)
	var foe := _target_at(ARENA + Vector3(0.0, -0.3, 0.0))

	await _tick(60)  # one second

	assert_gt(foe.bites, 0, "it bit what it was sitting on")
	assert_lt(foe.bites, 4, "but on its cooldown, not every frame (%d bites)" % foe.bites)


## Teamless — deathmatch, or a /spawn'd one — has no side to reason from, so the wizard who
## threw it is spared by name and counts as the friend it blesses.
func test_it_never_bites_the_wizard_who_threw_it() -> void:
	var wombat := _wombat_at(ARENA)
	wombat.team = GameConsts.Team.NONE
	var caster := _target_at(ARENA + Vector3(0.0, -0.3, 0.0), GameConsts.Team.NONE)
	wombat.owner_node = caster

	await _tick(3)

	assert_eq(caster.damage_taken, 0.0, "their own wombat will not turn on them")
	assert_almost_eq(caster.healed, Wombat.BLESS_HEAL, 0.01, "it looks after them instead")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("wombat_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("wombat_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("wombat_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("wombat_weapon"), "another book grants it again")
	p.free()
