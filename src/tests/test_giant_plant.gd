extends "res://src/tests/test_base.gd"
## The giant plant summon: what /spawn will answer to, the plant's own hunt-and-bite loop,
## the ally damage discount, and the weapon's refusal to grow one where it doesn't fit.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const GiantPlantScript = preload("res://src/monsters/giant_plant.gd")
const GiantPlantWeaponScript = preload("res://src/weapons/giant_plant_weapon.gd")

const ARENA := Vector3(0.0, 90.0, 0.0)   # clear of any map geometry
const CHASE_FRAMES := 240                # 4s at 60Hz: enough to close ~5m at 2.5 m/s


## Damageable stand-in for a player, on the layer the plant's line of sight ignores.
class DummyTarget extends CharacterBody3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var damage_taken := 0.0
	var bites := 0
	## Summons carry the wizard who called them up; with no teams that is all there is to go on.
	var owner_node: Node3D = null

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount
		bites += 1


## Whoever is credited with a hit — take_damage passes it on to send_hit_confirmed_to, which wants
## a peer to send the crosshair confirm to.
class DummyAttacker extends Node3D:
	var team := GameConsts.Team.RED
	var peer_id := 0


## The bare surface Weapon.fire()/get_aim() reach for on a caster.
class DummyCaster extends CharacterBody3D:
	var team := GameConsts.Team.BLUE
	var peer_id := 0
	var is_dead := false

	func _active_camera() -> Camera3D:
		return null


## Mirrors main._spawn_dyn_entity: setup() first, add_child() after.
func _plant_at(pos: Vector3, owner_peer_id := 0) -> GiantPlant:
	var plant: GiantPlant = GiantPlantScript.new()
	plant.setup({"position": pos, "team": GameConsts.Team.BLUE,
		"owner_peer_id": owner_peer_id}, true)
	_root().add_child(plant)
	_keep(plant)
	return plant


func _target_at(pos: Vector3) -> DummyTarget:
	return _damageable_at(DummyTarget, pos, 0.4, true) as DummyTarget


## Both halves come from the scripts themselves. The spell is a spellbook pickup, not any
## class's spell, so it is grantable to every element and belongs to no starting loadout.
func test_the_registry_offers_both_halves_of_the_spell() -> void:
	assert_true(SpawnRegistry.has_object("giant_plant"), "the plant is a thing in the world")
	assert_true(SpawnRegistry.has_weapon("giant_plant_weapon"), "the spell that summons it")
	assert_false(SpawnRegistry.has_object("giant_plant_weapon"), "the spell is not itself an object")
	var w := SpawnRegistry.build_weapon("giant_plant_weapon")
	assert_true(w is GiantPlantWeapon, "right class")
	assert_eq(w.player_attack_prefix, "combo", "cast with the shared combo-spell animation")


## A found spellbook is cast with the hands of whoever picked it up, and no wizard starts
## the round holding one.
func test_the_spell_is_a_pickup_not_a_class_spell() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var w := SpawnRegistry.build_weapon("giant_plant_weapon", element)
		assert_ne(w, null, "every class can be handed the spell")
		assert_eq(w.hand_model_path, "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element],
			"cast with the %s wizard's own hands" % GameConsts.ELEMENT_NAMES[element])
		for carried in Wizard.create(element).weapons:
			assert_false(carried is GiantPlantWeapon,
				"no %s wizard spawns holding it" % GameConsts.ELEMENT_NAMES[element])


func test_the_plant_walks_at_an_enemy_and_bites_it() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var plant := _plant_at(ARENA)
	var target := _target_at(ARENA + Vector3(0.0, 0.0, 6.0))
	var start_dist := plant.global_position.distance_to(target.global_position)

	await _tick(CHASE_FRAMES)

	assert_lt(plant.global_position.distance_to(target.global_position), start_dist,
		"the plant closed on an enemy it could see")
	assert_gt(target.damage_taken, 0.0, "and bit it once in range")
	assert_true(target.damage_taken >= GiantPlant.BITE_DAMAGE,
		"a bite is lethal (%.0f damage)" % target.damage_taken)


## The bite is on a half-second timer, so a plant standing over its victim can't chew
## through it once per physics frame.
func test_a_bite_waits_out_its_cooldown() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var plant := _plant_at(ARENA)
	var target := _target_at(ARENA + Vector3(0.0, 0.0, 1.5))  # already inside bite range

	await _tick(60)  # one second

	assert_gt(target.bites, 0, "it bit what was standing on top of it")
	assert_lt(target.bites, 5, "but only on its cooldown, not every frame (%d bites)" % target.bites)


## Nothing else reclaims a plant — it outlives its caster by design — so without the lifetime
## every one ever cast would still be stalking at the end of the round. Its age is driven by hand
## rather than waited out; _age is the only clock it keeps.
func test_it_withers_when_its_time_runs_out() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var plant := _plant_at(ARENA)
	await _tick(2)
	plant._age = GiantPlantScript.LIFETIME
	await _tick(2)
	assert_false(is_instance_valid(plant), "withered away once its minute was up")


## And not a moment early: a plant a frame short of its time is still hunting.
func test_it_stands_its_full_time_out_first() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var plant := _plant_at(ARENA)
	var target := _target_at(ARENA + Vector3(0.0, 0.0, 1.5))
	await _tick(2)
	plant._age = GiantPlantScript.LIFETIME - 1.0
	await _tick(30)  # half a second, comfortably inside what's left
	assert_true(is_instance_valid(plant), "still standing")
	assert_false(plant.is_dead, "and still alive")
	assert_gt(target.bites, 0, "still biting what walks into it")


## The pool is what it says on the constant, with the regen unable to outpace a real fight.
func test_two_hundred_and_fifty_points_of_damage_fells_one() -> void:
	var plant := _plant_at(ARENA)
	assert_eq(plant.max_health, 250.0, "half of what it used to carry")
	var foe := DummyAttacker.new()
	foe.team = GameConsts.Team.RED
	_root().add_child(foe)
	_keep(foe)
	plant.take_damage(249.0, GameConsts.DamageType.PHYSICAL, foe)
	assert_false(plant.is_dead, "one point short leaves it standing")
	plant.take_damage(1.0, GameConsts.DamageType.PHYSICAL, foe)
	assert_true(plant.is_dead, "and the last point fells it")


func test_an_ally_can_only_chip_at_it() -> void:
	var plant := _plant_at(ARENA)  # team BLUE

	var foe := DummyAttacker.new()
	foe.team = GameConsts.Team.RED
	_root().add_child(foe)
	_keep(foe)
	var before := plant.health
	plant.take_damage(100.0, GameConsts.DamageType.PHYSICAL, foe)
	assert_almost_eq(plant.health, before - 100.0, 0.001, "an enemy does full damage")

	var friend := DummyAttacker.new()
	friend.team = GameConsts.Team.BLUE
	_root().add_child(friend)
	_keep(friend)
	before = plant.health
	plant.take_damage(100.0, GameConsts.DamageType.PHYSICAL, friend)
	assert_almost_eq(plant.health, before - 10.0, 0.001, "an ally chips at a tenth rate")


func test_the_book_holds_one_free_cast() -> void:
	var w := SpawnRegistry.build_weapon("giant_plant_weapon")
	assert_eq(w.mana_cost, 0.0, "the book is the cost, not mana")
	assert_eq(w.min_mana_to_fire(null), 0.0, "so an empty caster can still cast it")

	var p := _wizard()
	var base := p.weapons.size()
	assert_true(p.add_granted_weapon("giant_plant_weapon"), "picked the book up")
	assert_eq(p.weapons.size(), base + 1, "and it joined the loadout")
	assert_true(p.remove_granted_weapon("giant_plant_weapon"), "casting spends it")
	assert_eq(p.weapons.size(), base, "the spell is gone again")
	assert_true(p.granted_weapons.is_empty(), "and not replayed to a late joiner")
	assert_false(p.remove_granted_weapon("giant_plant_weapon"), "spending it twice is a no-op")
	# Gone means gone from the books too, so a second spellbook can be picked up.
	assert_true(p.add_granted_weapon("giant_plant_weapon"), "another book grants it again")
	p.free()


## Grants are appended, so spending one renumbers every slot after it. The stored indices have
## to move with it or the caster ends up holding — and observers replaying — the wrong weapon.
func test_spending_a_grant_keeps_the_other_slots_straight() -> void:
	var p := _wizard()
	var base := p.weapons.size()
	p.add_granted_weapon("giant_plant_weapon")
	p.add_granted_weapon("comet_weapon")
	assert_true(p.weapon_at(base) is GiantPlantWeapon, "book first")
	assert_true(p.weapon_at(base + 1) is CometWeapon, "second grant after it")

	# Holding the comet, one slot past the book that is about to vanish.
	p.current_weapon_idx = base + 1
	p.last_fired_weapon_idx = base + 1
	p.remove_granted_weapon("giant_plant_weapon")
	assert_true(p.weapon_at(base) is CometWeapon, "the later grant slid down into the gap")
	assert_eq(p.current_weapon_idx, base, "and the held slot followed it")
	assert_eq(p.last_fired_weapon_idx, base, "as did the slot observers replay shots against")
	assert_eq(p.granted_weapons, ["comet_weapon"] as Array[String], "only the spent grant left")

	# Standing on the slot that vanishes falls back rather than pointing off the end.
	p.current_weapon_idx = base
	p.remove_granted_weapon("comet_weapon")
	assert_eq(p.weapons.size(), base, "back to the bare loadout")
	assert_true(p.weapon_at(p.current_weapon_idx) != null, "the caster is holding something real")

	# A slot before the removed one is left alone.
	p.add_granted_weapon("comet_weapon")
	p.current_weapon_idx = 0
	p.remove_granted_weapon("comet_weapon")
	assert_eq(p.current_weapon_idx, 0, "an earlier slot does not move")
	p.free()


## A cast plant belongs to the world, not to the wizard, and casts don't know about each other:
## a wizard who finds a second spellbook ends up with two plants, not a replacement.
func test_it_is_not_the_casters_to_take_away() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var first := _plant_at(ARENA, 7)
	var second := _plant_at(ARENA + Vector3(10.0, 0.0, 0.0), 7)   # same caster, second book
	var theirs := _plant_at(ARENA + Vector3(20.0, 0.0, 0.0), 8)

	await _tick(3)
	assert_true(is_instance_valid(first), "casting again left the earlier plant standing")
	assert_true(is_instance_valid(second) and is_instance_valid(theirs), "and everyone else's")

	# The caster leaves entirely; the plant drops the stale reference and carries on.
	var caster := DummyCaster.new()
	_root().add_child(caster)
	first.owner_node = caster
	caster.free()
	await _tick(3)
	assert_true(is_instance_valid(first), "the plant outlives the wizard who cast it")
	assert_eq(first.owner_node, null, "with the freed owner cleared, not left dangling")


## The regression: the plant walked at its target with its head pointing the other way. The
## importer leaves the model yawed -90°, so the entity's forward and the plant's face were two
## different directions and every yaw was set against the wrong one.
func test_it_faces_what_it_is_walking_at() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var plant := _plant_at(ARENA)
	var target := _target_at(ARENA + Vector3(6.0, 0.0, 3.0))

	await _tick(30)
	assert_eq(target_of(plant), target, "it picked the target up")

	var to_target := target.global_position - plant.global_position
	to_target.y = 0.0
	to_target = to_target.normalized()

	# Node forward, which the model correction in _ready lines the plant's head up with.
	var facing := -plant.global_transform.basis.z
	assert_gt(facing.dot(to_target), 0.99, "the plant's front is turned toward what it chases")

	# And the head really is on that side of the body — the premise the correction rests on,
	# so a re-export that reorients the model fails here rather than in play.
	var skel: Skeleton3D = plant._model.find_child("Skeleton3D")
	var head := BoneAttachment3D.new()
	head.bone_idx = skel.find_bone("headtop")
	skel.add_child(head)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var head_dir := head.global_position - plant.global_position
	head_dir.y = 0.0
	assert_gt(head_dir.normalized().dot(to_target), 0.9, "and the head leads, not the tail")


## The regression: a plant spared its caster by identity, so it went on ignoring them after they
## joined the other team. With a team of its own the plant reasons from teams alone; only a
## teamless plant (deathmatch, or /spawn with no side) still spares whoever cast it.
func test_a_caster_who_changes_sides_becomes_food() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var plant := _plant_at(ARENA)  # team BLUE
	var caster := _target_at(ARENA + Vector3(0.0, 0.0, 6.0))
	caster.team = GameConsts.Team.BLUE
	plant.owner_node = caster

	await _tick(30)
	assert_eq(target_of(plant), null, "an ally who cast it is left alone")

	caster.team = GameConsts.Team.RED  # switched sides
	await _tick(30)
	assert_eq(target_of(plant), caster, "and is hunted once they are on the other side")

	# A teamless plant has no side to reason from, so it still spares its caster by name.
	var loose := _plant_at(ARENA + Vector3(0.0, 0.0, 14.0))
	loose.team = GameConsts.Team.NONE
	loose.owner_node = caster
	await _tick(30)
	assert_ne(target_of(loose), caster, "a teamless plant never turns on the wizard who cast it")


## With no teams in play there is nothing but the summoner to reason from, so everything one
## wizard called up counts as one side. The original tried to say this and could not: it asked
## after summons by classname, misspelled one, and assigned over its own argument doing it.
## Here it is a property every summon already carries, so nothing knows what anything else is.
func test_summons_of_one_wizard_leave_each_other_alone() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var wizard := _target_at(ARENA + Vector3(0.0, 0.0, 20.0))
	wizard.team = GameConsts.Team.NONE

	var plant := _plant_at(ARENA)
	plant.team = GameConsts.Team.NONE
	plant.owner_node = wizard

	# Another of the same wizard's summons, stood right next to it.
	var sibling := _target_at(ARENA + Vector3(0.0, 0.0, 4.0))
	sibling.team = GameConsts.Team.NONE
	sibling.owner_node = wizard

	await _tick(30)
	assert_ne(target_of(plant), sibling, "it will not turn on its own summoner's other summon")
	assert_eq(sibling.damage_taken, 0.0, "nor bite one that walks into it")

	# Someone else's summon, at the same distance, is fair game.
	var theirs := _target_at(ARENA + Vector3(4.0, 0.0, 0.0))
	theirs.team = GameConsts.Team.NONE
	theirs.owner_node = _target_at(ARENA + Vector3(0.0, 0.0, -20.0))
	await _tick(30)
	assert_eq(target_of(plant), theirs, "a summon of anyone else's is not spared")


func target_of(plant: GiantPlant) -> Node3D:
	return plant._target


## The plant's hull is 2.5m across; the cast is refused rather than growing one inside a wall.
func test_it_will_not_grow_where_it_does_not_fit() -> void:
	_floor_at(ARENA - Vector3(0.0, 0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	var caster := DummyCaster.new()
	_root().add_child(caster)
	_keep(caster)
	caster.global_position = ARENA
	var weapon: GiantPlantWeapon = GiantPlantWeaponScript.new()

	var open := Vector3.FORWARD  # -Z, over bare floor
	await _tick(1)
	assert_true(weapon.can_fire(caster, open), "open ground ahead takes a plant")

	# Fill the spot the cast would land in (PLACE_DISTANCE ahead) with solid world.
	_floor_at(ARENA + open * GiantPlantWeapon.PLACE_DISTANCE + Vector3(0.0, 1.0, 0.0),
		Vector3(3.0, 3.0, 3.0))
	await _tick(1)
	assert_false(weapon.can_fire(caster, open), "a wall in the way refuses the cast")
