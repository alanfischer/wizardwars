extends "res://src/tests/test_base.gd"
## A skull leaves the hand plain and takes its element from the ally who hits it: a flamelick
## makes a fire skull, a necromancer's satchel a poisoned one. Enemy fire still shoots it down.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const SkullScript = preload("res://src/projectiles/skull.gd")

const SKULL_TEAM := 1
const ORIGIN := Vector3(0.0, 120.0, 0.0)  # clear of map geometry


## Anything that deals damage: all the skull reads off an attacker is its team.
class Caster extends Node3D:
	var team := 0


func _caster(team: int) -> Caster:
	var c := Caster.new()
	c.team = team
	_root().add_child(c)
	c.global_position = ORIGIN
	_spawned.append(c)
	return c


func _skull(caster: Caster) -> Skull:
	var s: Skull = SkullScript.new()
	s.name = "ElementProbe"
	s.setup({"position": ORIGIN, "direction": Vector3.FORWARD, "team": SKULL_TEAM})
	s.owner_node = caster
	_root().add_child(s)
	_spawned.append(s)
	return s


func test_a_skull_leaves_the_hand_with_no_element() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	assert_eq(s.damage_type, GameConsts.DamageType.PHYSICAL,
		"a fresh skull hits for nothing in particular — no poison")


func test_an_allys_spell_re_elements_it_instead_of_hurting_it() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	var hp: float = s._health.health

	s.take_damage(20.0, GameConsts.DamageType.FIRE, _caster(SKULL_TEAM))

	assert_eq(s.damage_type, GameConsts.DamageType.FIRE, "a friendly flamelick makes a fire skull")
	assert_eq(s._health.health, hp, "and takes nothing off it")


func test_a_friendly_satchel_is_what_poisons_one() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	s.take_damage(30.0, GameConsts.DamageType.DEATH, _caster(SKULL_TEAM))
	assert_eq(s.damage_type, GameConsts.DamageType.DEATH, "the necromancer's own satchel poisons it")


func test_the_last_ally_to_hit_it_wins() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	var ally := _caster(SKULL_TEAM)
	s.take_damage(10.0, GameConsts.DamageType.FIRE, ally)
	s.take_damage(10.0, GameConsts.DamageType.ICE, ally)
	assert_eq(s.damage_type, GameConsts.DamageType.ICE, "it carries whatever hit it last")


func test_an_elementless_friendly_hit_leaves_it_alone() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	var hp: float = s._health.health

	s.take_damage(999.0, GameConsts.DamageType.PHYSICAL, _caster(SKULL_TEAM))

	assert_eq(s.damage_type, GameConsts.DamageType.PHYSICAL, "a teammate's rock hands over nothing")
	assert_eq(s._health.health, hp, "and cannot shoot down its own side's skull")


func test_enemy_fire_hurts_it_and_still_dresses_it() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	var hp: float = s._health.health

	s.take_damage(10.0, GameConsts.DamageType.FIRE, _caster(SKULL_TEAM + 1))

	assert_eq(s._health.health, hp - 10.0, "an enemy's flamelick takes its 10 off")
	assert_eq(s.damage_type, GameConsts.DamageType.FIRE,
		"and a skull carries whatever it survived, whoever threw it")


## The map is nobody's ally and nobody's enemy: a trigger_hurt passes no attacker at all.
func test_the_world_dresses_it_and_hurts_it() -> void:
	var s := _skull(_caster(SKULL_TEAM))
	var hp: float = s._health.health

	s.take_damage(10.0, GameConsts.DamageType.FIRE, null)

	assert_eq(s.damage_type, GameConsts.DamageType.FIRE, "a burning trigger_hurt makes a fire skull")
	assert_eq(s._health.health, hp - 10.0, "and burns it on the way through")


## With no teams at all (deathmatch) the skull has only its caster to reason from — the same
## fallback every summon uses.
func test_in_deathmatch_only_its_own_caster_can_re_element_it() -> void:
	var caster := _caster(GameConsts.Team.NONE)
	var s: Skull = SkullScript.new()
	s.setup({"position": ORIGIN, "direction": Vector3.FORWARD, "team": GameConsts.Team.NONE})
	s.owner_node = caster
	_root().add_child(s)
	_spawned.append(s)

	var hp: float = s._health.health
	s.take_damage(10.0, GameConsts.DamageType.ICE, _caster(GameConsts.Team.NONE))
	assert_eq(s._health.health, hp - 10.0, "a stranger is an enemy here, and shoots at it")

	s.take_damage(10.0, GameConsts.DamageType.ICE, caster)
	assert_eq(s._health.health, hp - 10.0, "its own caster cannot")
	assert_eq(s.damage_type, GameConsts.DamageType.ICE, "and dresses it instead")
