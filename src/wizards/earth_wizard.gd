class_name EarthWizard
extends Wizard

const BEAR_SPEED := 0.50
const BEAR_MAX_HEALTH := 200.0

func _init() -> void:
	element = GameConsts.Element.EARTH
	player_model_path = "models/player/earth.mdl"
	speed_multiplier = 0.65  # SPEED_MEDLOW
	max_health = 100.0
	weapons = [EarthStaffWeapon.new(), _make_rollingstone(), _make_pebbleblast(), _make_bird(), _make_bear_spell()]


func _make_rollingstone() -> Weapon:
	var w = RollingStoneWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/earth.mdl"
	w.hand_idle_anim = "rollingstoneidle"
	w.hand_attack_anims.assign(["rollingstoneshoot"])
	w.hand_hit_anims.assign(["rollingstoneshoot"])
	w.player_attack_prefix = "rollingstone"
	w.bot_range = 22.0  # ranged rolling projectile
	w.bot_lead_speed = RollingStoneWeapon.STONE_SPEED
	return w


func _make_bird() -> Weapon:
	var w = BirdWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/earth.mdl"
	w.hand_idle_anim = "birdidle"
	w.hand_attack_anims.assign(["birdshoot"])
	w.hand_hit_anims.assign(["birdshoot"])
	w.player_attack_prefix = "birdspell"
	return w


func _make_pebbleblast() -> Weapon:
	var w = PebbleblastWeapon.new()
	w.bot_range = 12.0  # short-range shotgun spread
	w.element = element
	w.hand_model_path = "models/hands/earth.mdl"
	w.hand_idle_anim = "thornblastidle"
	w.hand_attack_anims.assign(["thornblastshoot"])
	w.hand_hit_anims.assign(["thornblastshoot"])
	w.player_attack_prefix = "thornblast"
	return w


func _make_bear_spell() -> Weapon:
	var w = BearSpellWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/earth.mdl"
	w.hand_idle_anim = "staffidle"
	w.mana_cost = 20.0
	return w


## Returns the two-weapon loadout active while the player is a bear.
func make_bear_loadout() -> Array[Weapon]:
	var bite := BearBiteWeapon.new()
	var spell := BearSpellWeapon.new()
	spell.element = element
	spell.hand_model_path = "models/hands/bear.mdl"
	spell.hand_idle_anim = "biteidle"
	spell.mana_cost = 0.0
	return [bite, spell]
