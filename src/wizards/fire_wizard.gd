class_name FireWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.FIRE
	player_model_path = "models/player/fire.mdl"
	speed_multiplier = 0.65  # SPEED_MEDLOW
	max_health = 100.0
	weapons = [FireStaffWeapon.new(), _make_missile("models/hands/fire.mdl"), _make_flamelick(), _make_fireball(), _make_fissure()]


func _make_fireball() -> Weapon:
	var w = FireballWeapon.new()
	w.bot_range = 30.0  # ranged AoE projectile
	w.bot_lead_speed = Fireball.FIREBALL_SPEED
	w.element = element
	w.hand_model_path = "models/hands/fire.mdl"
	w.hand_idle_anim = "fireballidle"
	w.hand_attack_anims.assign(["fireballcast"])
	w.hand_hit_anims.assign(["fireballcast"])
	w.player_attack_prefix = "fireball"
	return w


func _make_fissure() -> Weapon:
	var w = FissureWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/fire.mdl"
	w.hand_idle_anim = "fireballidle"
	w.hand_attack_anims.assign(["fireballcast"])
	w.hand_hit_anims.assign(["fireballcast"])
	w.player_attack_prefix = "fireball"
	return w


func _make_flamelick() -> Weapon:
	var w = FlamelickWeapon.new()
	w.bot_range = 8.0  # close-range flame
	w.element = element
	w.hand_model_path = "models/hands/fire.mdl"
	w.hand_idle_anim = "flamelickidle"
	w.hand_attack_anims.assign(["flamelickshoot"])
	w.hand_hit_anims.assign(["flamelickshoot"])
	w.player_attack_prefix = "flamelick"
	return w
