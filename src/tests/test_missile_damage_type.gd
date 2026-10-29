extends "res://src/tests/test_base.gd"
## A magic missile carries the damage type of the weapon that fired it. Every class but the
## necromancer hands over nothing and fires the plain bolt; his is a poison missile, which is what
## lets him re-element his own skull mid-flight (see test_skull_element.gd).
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const MissileScript = preload("res://src/projectiles/magic_missile.gd")


## The single-missile weapon out of a class's real loadout, or null if it doesn't carry one.
func _missile_of(wizard: Wizard) -> MissileWeapon:
	for w in wizard.weapons:
		if w is MissileWeapon:
			return w
	return null


func test_a_missile_weapon_hands_over_nothing_by_default() -> void:
	assert_eq(MissileWeapon.new().damage_type, GameConsts.DamageType.PHYSICAL,
		"a plain bolt, with no status behind it")
	assert_eq(DoubleMissileWeapon.new().damage_type, GameConsts.DamageType.PHYSICAL,
		"and the double missile the same")


func test_the_necromancers_missile_is_a_poison_missile() -> void:
	var w := _missile_of(DeathWizard.new())
	assert_ne(w, null, "the death wizard carries a magic missile")
	assert_eq(w.damage_type, GameConsts.DamageType.DEATH, "and it poisons what it hits")


func test_no_other_class_poisons_with_its_missile() -> void:
	for elem in GameConsts.ELEMENT_NAMES:
		if elem == GameConsts.Element.DEATH:
			continue
		var w := _missile_of(Wizard.create(elem))
		if w == null:
			continue  # ice and wind throw a mind missile instead
		assert_eq(w.damage_type, GameConsts.DamageType.PHYSICAL,
			"the %s wizard fires the plain bolt" % GameConsts.ELEMENT_NAMES[elem])


func test_the_missile_carries_the_type_it_was_spawned_with() -> void:
	var m: MagicMissile = MissileScript.new()
	m.setup({"position": Vector3.ZERO, "direction": Vector3.FORWARD,
		"damage_type": GameConsts.DamageType.DEATH})
	assert_eq(m.damage_type, GameConsts.DamageType.DEATH, "it rides the spawn data, like speed does")
	m.free()


func test_a_missile_spawned_without_one_is_plain() -> void:
	var m: MagicMissile = MissileScript.new()
	m.setup({"position": Vector3.ZERO, "direction": Vector3.FORWARD})
	assert_eq(m.damage_type, GameConsts.DamageType.PHYSICAL, "no type asked for, none carried")
	m.free()


## A poison missile and the skull it poisons read their colour from the one table, so they are
## necessarily the same green — that shared table is the point, not the particular values.
func test_poison_is_green_for_everything_that_shows_it() -> void:
	var green: Color = GameConsts.DAMAGE_TYPE_COLORS[GameConsts.DamageType.DEATH]
	assert_gt(green.g, green.r, "green, not red")
	assert_gt(green.g, green.b, "green, not blue")
	assert_ne(green, MagicMissile.PLAIN_COLOR, "and not the plain bolt's blue")
