class_name LightningWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.LIGHTNING
	player_model_path = "models/player/lightning.mdl"
	speed_multiplier = 0.75  # SPEED_MED
	max_health = 80.0
	weapons = [LightningStaffWeapon.new(), _make_lightningbolt(), _make_spotbolt()]


func _make_lightningbolt() -> Weapon:
	var w = LightningboltWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/lightning.mdl"
	w.hand_idle_anim = "lightningboltidle"
	w.hand_attack_anims.assign(["lightningboltshoot"])
	w.hand_hit_anims.assign(["lightningboltshoot"])
	w.player_attack_prefix = "zap"
	w.bot_range = 30.0  # ranged bolt
	return w


func _make_spotbolt() -> Weapon:
	var w = SpotboltWeapon.new()
	w.bot_range = 40.0  # long-range bolt (bots fire it uncharged for now)
	w.element = element
	w.hand_model_path = "models/hands/lightning.mdl"
	w.hand_idle_anim = "spotboltidle"
	w.hand_attack_anims.assign(["spotboltshoot"])
	w.hand_hit_anims.assign(["spotboltshoot"])
	w.player_attack_prefix = "spotbolt"
	return w
