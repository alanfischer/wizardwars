extends "res://src/tests/test_base.gd"
## The ball lightning spell: the bolt half, the ball half, and the rule that ties the ball's
## life to having something in sight.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const BallLightningScript = preload("res://src/projectiles/ball_lightning.gd")
const BallLightningWeaponScript = preload("res://src/weapons/ball_lightning_weapon.gd")

const ARENA := Vector3(-200.0, 90.0, 0.0)  # clear of map geometry, and of the other suites'


## Damageable stand-in for a player, on the layer a hitscan can land on.
class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var last_type := -1

	func take_damage(amount: float, type: int, _attacker) -> void:
		damage_taken += amount
		last_type = type


## The bare surface Weapon.fire()/get_aim() reach for on a caster.
class DummyCaster extends CharacterBody3D:
	var team := GameConsts.Team.BLUE
	var peer_id := 0
	var is_dead := false

	func _active_camera() -> Camera3D:
		return null


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _ball_at(pos: Vector3, dir := Vector3.FORWARD) -> BallLightning:
	var ball: BallLightning = BallLightningScript.new()
	ball.setup({"position": pos, "direction": dir, "team": GameConsts.Team.BLUE}, true)
	_root().add_child(ball)
	_keep(ball)
	return ball


func _target_at(pos: Vector3) -> DummyTarget:
	return _damageable_at(DummyTarget, pos, 0.4, true) as DummyTarget


## A hitscan lands on the per-bone hitbox areas a model carries, never on the body capsule —
## so a target the bolt is meant to hit needs one, the way a wizard model does.
func _hitbox_on(target: Node3D) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = GameConsts.MASK_HITBOX
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	var acs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 1.8, 0.8)
	acs.shape = box
	acs.position.y = 0.9
	area.add_child(acs)
	target.add_child(area)
	return area


func _caster_at(pos: Vector3) -> DummyCaster:
	var c := DummyCaster.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	c.add_child(col)
	_root().add_child(c)
	c.global_position = pos
	_keep(c)
	return c


## Both halves come from the scripts themselves, and like the other combo spells it is a
## spellbook pickup rather than any class's spell.
func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("ball_lightning"), "the ball is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("ball_lightning_weapon"), "the spell that casts it")
	assert_false(SpawnRegistry.has_object("ball_lightning_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("ball_lightning_weapon")
	assert_true(w is BallLightningWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")
	assert_eq(w.get_display_name(), "Ball Lightning", "and named for what it makes")


func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("ball_lightning_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is BallLightningWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


## The bolt is instant and does its own damage before the ball ever exists — half the spell's
## output, and the part that can't be dodged.
func test_the_bolt_hits_what_the_caster_is_looking_at() -> void:
	var caster := _caster_at(ARENA)
	var victim := _target_at(ARENA + Vector3(0.0, 0.0, -8.0))
	_hitbox_on(victim)
	var weapon: BallLightningWeapon = BallLightningWeaponScript.new()
	await _tick(1)

	weapon.fire(caster, ARENA + Vector3(0.0, 0.9, 0.0), Vector3.FORWARD)

	assert_almost_eq(victim.damage_taken, BallLightningWeapon.DAMAGE, 0.01,
		"the bolt landed for its full 500")
	assert_eq(victim.last_type, GameConsts.DamageType.LIGHTNING, "as shock damage")


## And the ball is left standing in the crater, lifted clear of the surface so its first look
## isn't straight into the wall it hit.
func test_the_ball_is_left_where_the_bolt_landed() -> void:
	var caster := _caster_at(ARENA)
	var wall := _wall_at(ARENA + Vector3(0.0, 0.9, -6.0), Vector3(8.0, 6.0, 0.5))
	var weapon: BallLightningWeapon = BallLightningWeaponScript.new()
	await _tick(1)

	var from := ARENA + Vector3(0.0, 0.9, 0.0)
	var ray := Combat.hitscan(caster, from, Vector3.FORWARD, BallLightningWeapon.RANGE,
			RID(), GameConsts.MASK_HITSCAN, true, Combat.collect_hitscan_excludes(caster))
	assert_false(ray.result.is_empty(), "the bolt stopped against the wall")

	var spot := weapon._ball_spot(ray, Vector3.FORWARD)
	var wall_face: float = wall.global_position.z + 0.25
	assert_gt(spot.z, wall_face, "the ball is left on this side of what the bolt hit")
	assert_almost_eq(spot.z - wall_face, BallLightningWeapon.BALL_OFFSET, 0.01,
		"only just clear of it, not floated out into the room")

	# A bolt that hit nothing has no surface to back away from — it backs along the shot instead.
	var miss := Combat.hitscan(caster, from, Vector3.UP, BallLightningWeapon.RANGE,
			RID(), GameConsts.MASK_HITSCAN, true, Combat.collect_hitscan_excludes(caster))
	assert_true(miss.result.is_empty(), "nothing overhead")
	var miss_spot := weapon._ball_spot(miss, Vector3.UP)
	assert_almost_eq(miss_spot.distance_to(from), BallLightningWeapon.RANGE - BallLightningWeapon.BALL_OFFSET,
		0.01, "left at the far end of the shot, pulled back along it")


## The cast's own flourish. Nothing else exercises it — fire() reaches it through the entity
## spawner, which no test scene has — so a broken sprite or beam config would go unnoticed.
func test_the_strike_throws_its_arcs() -> void:
	var scene := (Engine.get_main_loop() as SceneTree).current_scene
	var before := _mesh_count(scene)

	var strike := BallLightningStrike.new()
	strike.setup({"position": ARENA})
	_root().add_child(strike)
	_keep(strike)
	await _tick(1)

	assert_eq(_mesh_count(scene) - before, BallLightningStrike.BOLTS,
		"one beam per arc, thrown into the scene")
	var kinds := {}
	for child in strike.get_children():
		kinds[child.get_class()] = true
	assert_true(kinds.has("Sprite3D"), "the burst sprite loaded")
	assert_true(kinds.has("OmniLight3D"), "with a flash behind it")
	assert_true(kinds.has("MeshInstance3D"), "and a shockwave ring under it")
	assert_ne(BallLightningStrike.BURST_SPRITE, BallLightning.SPRITE,
		"the burst is an explosion, not the ball's own sprite scaled up")


func _mesh_count(scene: Node) -> int:
	var n := 0
	for child in scene.get_children():
		if child is MeshInstance3D:
			n += 1
	return n


## An empty room doesn't put it out — with nobody to chase it goes looking, drifting off the
## crater at a wander rather than parking there waiting to be walked into.
func test_the_ball_wanders_when_nothing_is_in_sight() -> void:
	var ball := _ball_at(ARENA)
	await _tick(60)  # a second of drifting
	assert_true(is_instance_valid(ball), "still burning with nobody to chase")
	var travelled := ball.global_position.distance_to(ARENA)
	assert_gt(travelled, 0.5, "it left the crater under its own steam")
	assert_lt(travelled, BallLightning.WANDER_SPEED * 1.1,
		"at the idle drift, not the speed it charges prey at")
	assert_lt(absf(ball.global_position.y - ARENA.y), 1.0,
		"and stayed near the height it was left at rather than climbing away")

	# The heading turns rather than snapping, which is what makes the path read as a wander.
	var heading := ball.direction
	await _tick(6)
	assert_gt(ball.direction.dot(heading), 0.9, "one tenth of a second only bends it a little")


func test_the_ball_closes_on_an_enemy_and_kills_it() -> void:
	var ball := _ball_at(ARENA, Vector3.BACK)  # thrown away from the target on purpose
	var victim := _target_at(ARENA + Vector3(0.0, 0.9, -6.0))

	await _tick(10)  # the first think lands at 0.1s, after a little wandering the other way
	assert_true(is_instance_valid(ball), "it stays lit while it has something to chase")
	var to_victim := (SpatialQuery.collision_center(victim) - ball.global_position).normalized()
	assert_gt(ball.direction.dot(to_victim), 0.99, "and turns onto it")

	await _tick(90)  # 6.4 m/s covers the rest
	assert_almost_eq(victim.damage_taken, BallLightning.DAMAGE, 0.01,
		"contact is worth 600 — lethal to anything it lands on")
	assert_eq(victim.last_type, GameConsts.DamageType.FIRE,
		"burn damage, as the original wrote the ball's touch")
	assert_false(is_instance_valid(ball), "and it is spent")


## An ally in the way is passed straight through rather than spending the ball on someone it
## can't hurt — the reason it needs its own contact test instead of the shared one.
func test_the_ball_passes_through_its_own_side() -> void:
	var ball := _ball_at(ARENA)   # team BLUE
	var friend := _target_at(ARENA + Vector3(0.0, 0.9, -2.0))
	friend.team = GameConsts.Team.BLUE
	var foe := _target_at(ARENA + Vector3(0.0, 0.9, -6.0))

	await _tick(90)

	assert_eq(friend.damage_taken, 0.0, "the teammate standing in the way was untouched")
	assert_almost_eq(foe.damage_taken, BallLightning.DAMAGE, 0.01, "and the enemy behind took it")


## Line of sight, not distance, is what it hunts on — stepping behind cover drops it back to
## wandering its own side of the wall instead of letting it chase through.
func test_a_wall_between_them_stops_it_coming() -> void:
	var ball := _ball_at(ARENA)
	var victim := _target_at(ARENA + Vector3(0.0, 0.9, -8.0))
	await _tick(10)
	assert_true(is_instance_valid(ball), "on its way while it can see them")

	var wall := _wall_at(ARENA + Vector3(0.0, 0.9, -4.0), Vector3(8.0, 6.0, 0.5))
	var near_face: float = wall.global_position.z + 0.25
	await _tick(60)
	assert_true(is_instance_valid(ball), "cover doesn't put it out")
	assert_gt(ball.global_position.z, near_face,
		"it stays on its own side of what took them from it")
	assert_eq(victim.damage_taken, 0.0, "with the victim untouched")


## The 30s cap only matters to a ball that has been chasing someone the whole time; too long to
## sit through, so this ages it by hand and takes the last step for real.
func test_the_ball_blows_itself_out_eventually() -> void:
	var ball := _ball_at(ARENA)
	_target_at(ARENA + Vector3(0.0, 0.9, -20.0))  # in sight, but too far to reach
	ball._age = BallLightning.MAX_LIFETIME - 0.05
	await _tick(12)
	assert_false(is_instance_valid(ball), "it went out on its own clock")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("ball_lightning_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("ball_lightning_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("ball_lightning_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_true(p.add_granted_weapon("ball_lightning_weapon"), "another book grants it again")
	p.free()
