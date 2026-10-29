extends "res://src/tests/test_base.gd"
## trigger_hurt with a negative "dmg" heals instead of damaging (CTriggerHurt::HurtTouch).
## ww_shrinkspell's pool is dmg -5; routing that through take_damage made health climb
## without limit (apply_damage_raw has no upper bound) and flashed the screen red.

const PlayerScript = preload("res://src/player.gd")
const TriggerHurtScript = preload("res://src/entities/trigger_hurt.gd")


func _make_player() -> Node:
	var p: CharacterBody3D = PlayerScript.new()
	p.team = 1
	_root().add_child(p)
	return p


## Bare TriggerHurt, deliberately left out of the tree: _ready wants brush geometry
## for its Area3D (and would re-parse _dmg from an empty ent). _apply needs neither.
func _make_trigger(dmg: float) -> Node:
	var t: Node3D = TriggerHurtScript.new()
	t._dmg = dmg
	t._dmg_type = GameConsts.DamageType.PHYSICAL
	return t


func test_negative_dmg_heals() -> void:
	var p := _make_player()
	var t := _make_trigger(-5.0)
	p.health = 40.0
	t._apply(p)
	assert_eq(p.health, 45.0, "negative dmg adds health")
	t.free()
	p.free()


func test_heal_is_capped_at_max_health() -> void:
	var p := _make_player()
	var t := _make_trigger(-5.0)
	p.health = p.max_health
	for i in 20:
		t._apply(p)
	assert_eq(p.health, p.max_health, "healing stops at max_health — no unbounded overheal")
	t.free()
	p.free()


func test_positive_dmg_still_damages() -> void:
	var p := _make_player()
	var t := _make_trigger(10.0)
	t._apply(p)
	assert_eq(p.health, p.max_health - 10.0, "positive dmg still damages")
	t.free()
	p.free()


func test_negative_dmg_skips_bodies_that_cannot_heal() -> void:
	# Dragons are damageable but have no heal(); a heal trigger must leave them alone
	# rather than fall through to take_damage(-5) and inflate their health forever.
	var body := CharacterBody3D.new()
	_root().add_child(body)
	var t := _make_trigger(-5.0)
	assert_false(t._apply(body), "body without heal() is skipped")
	t.free()
	body.free()
