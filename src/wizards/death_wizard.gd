class_name DeathWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.DEATH
	player_model_path = "models/player/death.mdl"
	speed_multiplier = 0.65  # SPEED_MEDLOW
	max_health = 120.0
	weapons = [DeathStaffWeapon.new(), _make_missile("models/hands/death.mdl", GameConsts.DamageType.DEATH), _make_deathray(), _make_skull(), _make_grimfeast()]


func _make_deathray() -> Weapon:
	var w = DeathRayWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/death.mdl"
	w.hand_idle_anim = "deathrayidle"
	w.hand_attack_anims.assign(["deathrayshoot"])
	w.hand_hit_anims.assign(["deathrayshoot"])
	w.player_attack_prefix = "rayspell"
	return w


func _make_skull() -> Weapon:
	var w = SkullWeapon.new()
	w.bot_range = 30.0  # ranged homing skull
	w.element = element
	w.hand_model_path = "models/hands/death.mdl"
	w.hand_idle_anim = "skullidle"
	w.hand_attack_anims.assign(["skullshoot"])
	w.hand_hit_anims.assign(["skullshoot"])
	w.player_attack_prefix = "flyingskull"
	return w


func _make_grimfeast() -> Weapon:
	var w = GrimfeastWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/death.mdl"
	w.hand_idle_anim = "staffidle"
	w.hand_attack_anims.assign(["staffmiss1", "staffmiss2", "staffmiss3"])
	w.hand_hit_anims.assign(["staffhit1", "staffhit2", "staffhit3"])
	w.player_attack_prefix = "staff"
	return w
