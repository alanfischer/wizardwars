extends "res://src/tests/test_base.gd"
## A projectile is a bare Node3D — a trigger_hurt's Area3D has nothing to touch, so a skull shot
## through a fire jet used to fly out the far side untouched. Projectiles report themselves to the
## volume they enter instead, and the damage that comes back is ordinary damage: the skull's
## element rule reads it like any other hit and comes out the other side a fire skull.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const TriggerHurtScript = preload("res://src/entities/trigger_hurt.gd")
const SkullScript = preload("res://src/projectiles/skull.gd")
const ProjectileScript = preload("res://src/projectiles/projectile.gd")

const INSIDE := Vector3(0.0, 160.0, 0.0)   # the volume's centre, clear of map geometry
const OUTSIDE := Vector3(0.0, 160.0, 40.0) # well beyond a 128-unit box
const TRIGGER_DMG := 10.0
const DMG_BURN := 8  # Half-Life "damagetype" bitflag for fire


## Built the way main._spawn_dyn_entity builds one, so _ready runs for real — including the
## MASK_HAZARD layer and the back-pointer a point query reads.
func _fire_jet() -> Node3D:
	var node := AnimatableBody3D.new()
	node.set_script(TriggerHurtScript)
	node.sync_to_physics = false
	node.set_meta("_dyn_spawner_entity", true)
	node.set_meta("entity", {
		"classname": "trigger_hurt",
		"angles": "0 0 0",
		"dmg": str(TRIGGER_DMG),
		"damagetype": str(DMG_BURN),
	})
	GoldSrcEntity.build_brush_stand_in(node, 128.0)
	_root().add_child(node)
	node.global_position = INSIDE
	_spawned.append(node)
	return node


func _skull_at(pos: Vector3) -> Skull:
	var s: Skull = SkullScript.new()
	s.setup({"position": pos, "direction": Vector3.FORWARD, "team": 1})
	_root().add_child(s)
	s.global_position = pos
	_spawned.append(s)
	return s


func test_a_hurt_volume_is_findable_by_point() -> void:
	var jet := _fire_jet()
	await _settle()

	assert_eq(SpatialQuery.hurt_volume_at(jet, INSIDE), jet, "the volume answers for a point inside it")
	assert_eq(SpatialQuery.hurt_volume_at(jet, OUTSIDE), null, "and not for one outside")


func test_a_skull_flown_through_a_fire_jet_comes_out_a_fire_skull() -> void:
	var jet := _fire_jet()
	await _settle()
	var s := _skull_at(INSIDE)
	var hp: float = s._health.health

	s._check_hazards()

	assert_eq(s.damage_type, GameConsts.DamageType.FIRE,
		"the trigger's burn dresses it like any other fire damage")
	assert_eq(s._health.health, hp - TRIGGER_DMG, "and costs it the trigger's damage")
	assert_eq(s._hazard_volume, jet, "it knows which volume it is in")


func test_staying_inside_is_not_entering_again() -> void:
	_fire_jet()
	await _settle()
	var s := _skull_at(INSIDE)

	s._check_hazards()
	var hp: float = s._health.health
	s._check_hazards()
	s._check_hazards()

	assert_eq(s._health.health, hp, "one hit per crossing, not one per tick")


func test_leaving_and_coming_back_is_a_new_crossing() -> void:
	_fire_jet()
	await _settle()
	var s := _skull_at(INSIDE)

	s._check_hazards()
	var hp: float = s._health.health

	s.global_position = OUTSIDE
	s._check_hazards()
	assert_eq(s._hazard_volume, null, "out the far side, in nothing")

	s.global_position = INSIDE
	s._check_hazards()
	assert_eq(s._health.health, hp - TRIGGER_DMG, "a second pass burns it again")


func test_a_switched_off_trigger_does_nothing() -> void:
	var jet := _fire_jet()
	jet.trigger(null, TriggerSystem.Type.TOGGLE)  # START_OFF is a spawnflag; toggling is the same state
	await _settle()
	var s := _skull_at(INSIDE)
	var hp: float = s._health.health

	s._check_hazards()

	assert_eq(s._health.health, hp, "an inactive jet burns nothing")
	assert_eq(s.damage_type, GameConsts.DamageType.PHYSICAL, "and dresses nothing")


func test_a_projectile_that_cannot_be_damaged_never_asks() -> void:
	# Most projectiles (a fireball, a spore) have no take_damage at all. The check must cost them
	# a has_method and no query, and must not try to hurt something that cannot take it.
	_fire_jet()
	await _settle()
	var p: Projectile = ProjectileScript.new()
	_root().add_child(p)
	p.global_position = INSIDE
	_spawned.append(p)

	p._check_hazards()

	assert_eq(p._hazard_volume, null, "it never even looked")
