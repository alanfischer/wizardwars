extends "res://src/tests/test_base.gd"
## The lightning cloud: what /spawn will answer to, the drift that never turns, the half-second
## snap at whatever it can see, and the burst that ends it.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const LightningCloudScript = preload("res://src/monsters/lightning_cloud.gd")
const LightningCloudWeaponScript = preload("res://src/weapons/lightning_cloud_weapon.gd")

const ARENA := Vector3(0.0, 200.0, 300.0)  # clear of map geometry, and of the other suites'


class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var hits := 0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount
		hits += 1


class DummyCaster extends CharacterBody3D:
	var team := GameConsts.Team.BLUE
	var peer_id := 0
	var is_dead := false

	func _active_camera() -> Camera3D:
		return null


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _cloud_at(pos: Vector3, dir := Vector3.FORWARD) -> LightningCloud:
	var c: LightningCloud = LightningCloudScript.new()
	c.setup({"position": pos, "direction": dir, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(c)
	_keep(c)
	return c


func _target_at(pos: Vector3) -> DummyTarget:
	return _damageable_at(DummyTarget, pos, 0.4, true) as DummyTarget


func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("lightning_cloud"), "the cloud is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("lightning_cloud_weapon"), "the spell that sends it")
	assert_false(SpawnRegistry.has_object("lightning_cloud_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("lightning_cloud_weapon")
	assert_true(w is LightningCloudWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")
	assert_eq(w.get_display_name(), "Lightning Cloud", "and named for what it makes")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("lightning_cloud_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is LightningCloudWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


## The thing that separates it from the tornado and the ball: it is artillery, not a hunter.
## Aiming it is the whole of casting it — a target off to one side does not turn it a degree.
func test_it_drifts_where_it_was_aimed_and_never_turns() -> void:
	var aim := Vector3(0.0, 0.3, -1.0).normalized()  # pitched up, as the original allowed
	var cloud := _cloud_at(ARENA, aim)
	_target_at(ARENA + Vector3(8.0, 0.0, -4.0))  # well within its reach, far off its line

	var start := cloud.global_position
	await _tick(60)

	assert_vec3_almost_eq(cloud.direction, aim, 0.001, "still pointing exactly where it was sent")
	var travelled := cloud.global_position - start
	assert_gt(travelled.normalized().dot(aim), 0.999, "and it has gone straight down that line")
	assert_almost_eq(travelled.length(), LightningCloud.SPEED, 0.15,
		"one second of drift at its own slow speed")
	assert_gt(cloud.global_position.y, start.y, "carrying the pitch it was given")


## 80 a snap, on a half-second clock, after a second of building up to the first one.
func test_it_snaps_at_what_it_can_see_on_its_own_clock() -> void:
	var cloud := _cloud_at(ARENA, Vector3.UP)  # sent straight up, so it stays over the target
	var victim := _target_at(ARENA + Vector3(3.0, -1.0, 0.0))

	await _tick(50)  # 0.83s — inside the wind-up
	assert_eq(victim.hits, 0, "nothing for the first second")

	await _tick(70)  # out to 2.0s: the first snap plus one more
	assert_gt(victim.hits, 0, "then it starts snapping")
	assert_almost_eq(victim.damage_taken, victim.hits * LightningCloud.ZAP_DAMAGE, 0.01,
		"80 a snap")
	assert_lt(victim.hits, 4, "on its own clock, not every frame (%d snaps in 2s)" % victim.hits)


func test_it_will_not_snap_at_its_own_side() -> void:
	var cloud := _cloud_at(ARENA, Vector3.UP)  # team BLUE
	var ally := _target_at(ARENA + Vector3(3.0, -1.0, 0.0))
	ally.team = GameConsts.Team.BLUE

	await _tick(130)
	assert_eq(ally.damage_taken, 0.0, "a teammate in plain view is left alone")


## It needs to see you. Unlike the ball it does not die for want of a target — it just drifts on
## and waits, which is what makes it worth sending down a lane you expect people to cross.
func test_cover_is_the_answer_to_it() -> void:
	var cloud := _cloud_at(ARENA, Vector3.UP)
	var victim := _target_at(ARENA + Vector3(4.0, -1.0, 0.0))
	# Tall enough to stay between them as the cloud climbs — a 6 m wall it simply rises over.
	_wall_at(ARENA + Vector3(2.0, 8.0, 0.0), Vector3(0.5, 40.0, 8.0))

	await _tick(130)
	assert_eq(victim.damage_taken, 0.0, "the wall between them is the whole defence")
	assert_true(is_instance_valid(cloud), "and it waits rather than going out, unlike the ball")


## The only thing that stops one, and what it costs whoever stops it.
func test_running_into_it_ends_it() -> void:
	var cloud := _cloud_at(ARENA, Vector3.FORWARD)
	# Dropped by half a capsule so the body's centre — what contact is measured against — sits
	# on the line the cloud is drifting along.
	var victim := _target_at(ARENA + Vector3(0.0, -0.9, -2.0))

	await _tick(90)  # 3.2 m/s covers the 2 m
	assert_almost_eq(victim.damage_taken, LightningCloud.TOUCH_DAMAGE, 0.01,
		"whatever it runs into takes 600")
	assert_false(is_instance_valid(cloud), "and the cloud goes out with them")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("lightning_cloud_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("lightning_cloud_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("lightning_cloud_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("lightning_cloud_weapon"), "another book grants it again")
	p.free()
