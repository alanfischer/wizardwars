class_name NatureWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.NATURE
	player_model_path = "models/player/nature.mdl"
	speed_multiplier = 0.85  # SPEED_MEDHIGH
	max_health = 90.0
	weapons = [NatureStaffWeapon.new(), _make_missile("models/hands/nature.mdl"), _make_thornblast(), _make_beanstalk(), _make_thornplant()]


func _make_thornblast() -> Weapon:
	var w = ThornblastWeapon.new()
	w.bot_range = 25.0  # ranged thorn projectile
	w.element = element
	w.hand_model_path = "models/hands/nature.mdl"
	w.hand_idle_anim = "thornblastidle"
	w.hand_attack_anims.assign(["thornblastshoot"])
	w.hand_hit_anims.assign(["thornblastshoot"])
	w.player_attack_prefix = "thornblast"
	return w


func _make_beanstalk() -> Weapon:
	var w = BeanstalkWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/nature.mdl"
	w.hand_idle_anim = "beanstalkidle"
	w.hand_attack_anims.assign(["beanstalkidle"])
	w.hand_hit_anims.assign(["beanstalkidle"])
	w.player_attack_prefix = "beanstalk"
	w.auto_repeat = true
	return w


func _make_thornplant() -> Weapon:
	var w = ThornplantWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/nature.mdl"
	w.hand_idle_anim = "beanstalkidle"
	w.hand_attack_anims.assign(["beanstalkidle"])
	w.hand_hit_anims.assign(["beanstalkidle"])
	w.player_attack_prefix = "beanstalk"
	return w
