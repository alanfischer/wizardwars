class_name LifeWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.LIFE
	player_model_path = "models/player/life.mdl"
	speed_multiplier = 1.0  # SPEED_HIGH
	max_health = 75.0
	weapons = [LifeStaffWeapon.new(), _make_double_missile(), _make_liferay(), _make_forceblast(), _make_sacrifice()]


func _make_double_missile() -> Weapon:
	var w = DoubleMissileWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/life.mdl"
	w.hand_idle_anim = "doublemagicmissileidle"
	w.hand_attack_anims.assign(["doublemagicmissileshoot"])
	w.hand_hit_anims.assign(["doublemagicmissileshoot"])
	w.player_attack_prefix = "dualmagicmissile"
	w.bot_range = 35.0  # ranged projectile
	w.bot_lead_speed = MagicMissile.MISSILE_SPEED
	return w


func _make_liferay() -> Weapon:
	var w = LifeRayWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/life.mdl"
	w.hand_idle_anim = "liferayidle"
	w.hand_attack_anims.assign(["liferayshoot"])
	w.hand_hit_anims.assign(["liferayshoot"])
	w.player_attack_prefix = "rayspell"
	return w


func _make_forceblast() -> Weapon:
	var w = ForceBlastWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/life.mdl"
	w.hand_idle_anim = "forceblastidle"
	w.hand_attack_anims.assign(["forceblastshoot"])
	w.hand_hit_anims.assign(["forceblastshoot"])
	w.player_attack_prefix = "forcespell"
	return w


func _make_sacrifice() -> Weapon:
	var w = SacrificeWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/life.mdl"
	w.hand_idle_anim = "forceblastidle"
	w.hand_attack_anims.assign(["forceblastshoot"])
	w.hand_hit_anims.assign(["forceblastshoot"])
	w.player_attack_prefix = "forcespell"
	return w
