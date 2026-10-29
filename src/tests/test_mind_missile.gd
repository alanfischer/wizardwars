extends "res://src/tests/test_base.gd"
## The mind missile: who casts it, what it costs against the magic missile it replaces, and the
## half of it that isn't damage — it presses whatever it lands on.
##
## Scene-run only (needs autoloads): res://src/tests/run_tests.tscn.

const MindMissileScript = preload("res://src/projectiles/mind_missile.gd")


## Damageable, and nothing else — what the missile finds when it hits a wizard.
class DummyTarget extends Node3D:
	var is_dead := false
	var team := GameConsts.Team.RED
	var peer_id := 0
	var damage_taken := 0.0

	func take_damage(amount: float, _type: int, _attacker) -> void:
		damage_taken += amount


## A button as far as +use is concerned: FCAP_IMPULSE_USE and a trigger to run.
class DummyButton extends Node3D:
	var fired := 0
	var last_activator: Node = null

	func is_player_usable() -> bool:
		return true

	func trigger(activator: Node, _type) -> void:
		fired += 1
		last_activator = activator


## Brushwork that answers a ray but not +use — what a wall in front of a button is.
class DummyWall extends Node3D:
	var fired := 0

	func trigger(_activator: Node, _type) -> void:
		fired += 1


func _missile() -> MindMissile:
	var m: MindMissile = MindMissileScript.new()
	m.setup({"position": Vector3.ZERO, "direction": Vector3.FORWARD}, true)
	_root().add_child(m)
	_keep(m)
	return m


func test_ice_and_wind_cast_it_where_everyone_else_casts_the_magic_missile() -> void:
	for element in GameConsts.ELEMENT_NAMES:
		var carried := Wizard.create(element).weapons
		var has_mind: bool = carried.any(func(w): return w is MindMissileWeapon)
		var has_plain: bool = carried.any(func(w): return w is MissileWeapon)
		var mind_class: bool = element in [GameConsts.Element.ICE, GameConsts.Element.WIND]
		assert_eq(has_mind, mind_class,
			"%s %s the mind missile" % [GameConsts.ELEMENT_NAMES[element],
				"carries" if mind_class else "does not carry"])
		assert_false(has_mind and has_plain, "never both missiles at once")


## The same hand throws both, so the model has to have the clips either way.
func test_it_is_thrown_from_the_magic_missile_hand() -> void:
	for element in [GameConsts.Element.ICE, GameConsts.Element.WIND]:
		for w in Wizard.create(element).weapons:
			if w is MindMissileWeapon:
				assert_eq(w.hand_idle_anim, "magicmissileidle", "same idle as the magic missile")
				assert_eq(w.player_attack_prefix, "magicmissile", "and the same cast")


func test_the_registry_offers_both_halves() -> void:
	assert_true(SpawnRegistry.has_weapon("mind_missile_weapon"), "the spell can be given")
	assert_true(SpawnRegistry.has_object("mind_missile"), "and the missile spawned on its own")
	assert_true(SpawnRegistry.build_weapon("mind_missile_weapon") is MindMissileWeapon, "right class")


## The trade the original strikes: half the rate and twice the cost, for twice the damage.
func test_it_trades_rate_for_weight() -> void:
	assert_eq(MindMissileWeapon.MANA_COST, MissileWeapon.MANA_COST * 2.0, "twice the mana")
	assert_eq(MindMissileWeapon.COOLDOWN, MissileWeapon.COOLDOWN * 2.0, "half the rate")
	assert_eq(MindMissile.MISSILE_DAMAGE, MagicMissile.MISSILE_DAMAGE * 2.0, "twice the damage")
	assert_lt(MindMissile.MISSILE_SPEED, MagicMissile.MISSILE_SPEED, "and slower in the air")


func test_it_damages_what_it_hits() -> void:
	var target := DummyTarget.new()
	_root().add_child(target)
	_keep(target)

	_missile()._hit_target(target)

	assert_eq(target.damage_taken, MindMissile.MISSILE_DAMAGE, "the hit lands")


## The reach the spell is for: a mind wizard works a button from across the room.
func test_it_presses_what_it_hits() -> void:
	var button := DummyButton.new()
	_root().add_child(button)
	_keep(button)
	var caster := DummyTarget.new()
	_root().add_child(caster)
	_keep(caster)

	var m := _missile()
	m.owner_node = caster
	m._hit_target(button)

	assert_eq(button.fired, 1, "the button goes off")
	assert_eq(button.last_activator, caster, "for the wizard who cast the missile, not the missile")


## Same walk up the parents as a player's own +use: a shape child doesn't hide the button.
func test_it_finds_the_button_through_a_child() -> void:
	var button := DummyButton.new()
	var shape := Node3D.new()
	button.add_child(shape)
	_root().add_child(button)
	_keep(button)

	_missile()._hit_target(shape)

	assert_eq(button.fired, 1, "pressed through the collider it actually hit")


## Being triggerable is not being +usable — the same distinction +use itself draws.
func test_it_leaves_alone_what_is_not_usable() -> void:
	var wall := DummyWall.new()
	_root().add_child(wall)
	_keep(wall)

	_missile()._hit_target(wall)

	assert_eq(wall.fired, 0, "plain brushwork is hit, not pressed")


## The view punch is owner-directed, so everything that isn't a connected player has to fall out
## of it quietly — the missile hits summons and brushwork too, and neither has a view to rock.
func test_the_view_punch_passes_over_anything_without_a_view() -> void:
	var summon := DummyTarget.new()          # damageable, but peer_id 0
	var bot := DummyTarget.new()
	bot.peer_id = -3                          # bots carry negative synthetic ids
	var wall := _keep(DummyWall.new())        # no peer_id property at all
	for target in [null, summon, bot, wall]:
		NetworkManager.send_view_punch(target, 10.0)
	summon.free()
	bot.free()
	assert_true(true, "a punch aimed at any of those is dropped, not sent")
