class_name WindWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.WIND
	player_model_path = "models/player/wind.mdl"
	speed_multiplier = 1.0  # SPEED_HIGH
	max_health = 80.0
	weapons = [WindStaffWeapon.new(), _make_mind_missile("models/hands/wind.mdl"), _make_updraft(), _make_levitate(), _make_clone()]


func _make_updraft() -> Weapon:
	var w = UpdraftWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/wind.mdl"
	w.hand_idle_anim = "updraftidle"
	w.hand_attack_anims.assign(["updraftshoot"])
	w.hand_hit_anims.assign(["updraftshoot"])
	w.player_attack_prefix = "updraft"
	return w


func _make_clone() -> Weapon:
	var w = CloneWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/wind.mdl"
	w.hand_idle_anim = "updraftidle"
	w.hand_attack_anims.assign(["updraftshoot"])
	w.hand_hit_anims.assign(["updraftshoot"])
	w.player_attack_prefix = "clone"
	return w


func _make_levitate() -> Weapon:
	var w = LevitateWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/wind.mdl"
	w.hand_idle_anim = "flyidle"
	w.hand_attack_anims.assign(["flyidle"])
	w.hand_hit_anims.assign(["flyidle"])
	w.player_attack_prefix = "levitate"
	return w
