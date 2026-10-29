class_name Wizard
extends RefCounted

var element: int
var player_model_path: String
var speed_multiplier := 1.0
var max_health := 100.0
var weapons: Array[Weapon] = []


func _make_missile(hand_model: String, damage_type := GameConsts.DamageType.PHYSICAL) -> Weapon:
	var w := MissileWeapon.new()
	w.damage_type = damage_type
	w.bot_lead_speed = MagicMissile.MISSILE_SPEED
	return _dress_missile(w, hand_model, 35.0)


## Ice and Wind cast this where every other class casts the magic missile. It is thrown from the
## same hand: the original gives both spells FPANIMS_MMIDLE/MMFIRE, so only the missile differs.
func _make_mind_missile(hand_model: String) -> Weapon:
	var w := MindMissileWeapon.new()
	w.bot_lead_speed = MindMissile.MISSILE_SPEED
	return _dress_missile(w, hand_model, 30.0)


func _dress_missile(w: Weapon, hand_model: String, range_hint: float) -> Weapon:
	w.element = element
	w.hand_model_path = hand_model
	w.hand_idle_anim = "magicmissileidle"
	w.hand_attack_anims.assign(["magicmissileshoot"])
	w.hand_hit_anims.assign(["magicmissileshoot"])
	w.player_attack_prefix = "magicmissile"
	w.bot_range = range_hint  # ranged projectile
	return w


## Spells no wizard is born with: the combo spells, earned by clashing staves with an ally
## (Staff._combo_swing) or found lying around as a spellbook. Any class can carry one, so they
## wear the holder's own hands and the shared "combo" cast animation rather than any one class's.
## Kept out of weapons[] — a wizard only ever gets one by earning or picking it up. The set is
## GameConsts.COMBO_RECIPES, so a new recipe brings its spell along with it.
func pickup_weapons() -> Array[Weapon]:
	var out: Array[Weapon] = []
	var seen := {}
	for key in GameConsts.COMBO_RECIPES.values():
		if key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		var script: GDScript = load("res://src/weapons/%s.gd" % key)
		if script == null:
			push_warning("wizard: no script for combo spell %s" % key)
			continue
		var w: Weapon = script.new()
		dress_pickup(w)
		out.append(w)
	return out


func dress_pickup(w: Weapon) -> void:
	w.element = element
	w.hand_model_path = "models/hands/%s.mdl" % GameConsts.ELEMENT_NAMES[element]
	w.hand_idle_anim = "shieldidle"
	w.hand_attack_anims.assign(["shieldidle"])
	w.hand_hit_anims.assign(["shieldidle"])
	w.player_attack_prefix = "combo"


static func create(elem: int) -> Wizard:
	match elem:
		GameConsts.Element.ARCHMAGE: return ArchmageWizard.new()
		GameConsts.Element.LIFE: return LifeWizard.new()
		GameConsts.Element.DEATH: return DeathWizard.new()
		GameConsts.Element.FIRE: return FireWizard.new()
		GameConsts.Element.ICE: return IceWizard.new()
		GameConsts.Element.LIGHTNING: return LightningWizard.new()
		GameConsts.Element.NATURE: return NatureWizard.new()
		GameConsts.Element.EARTH: return EarthWizard.new()
		GameConsts.Element.WIND: return WindWizard.new()
		_: return FireWizard.new()
