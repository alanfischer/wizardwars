class_name IceWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.ICE
	player_model_path = "models/player/ice.mdl"
	speed_multiplier = 0.85  # SPEED_MEDHIGH
	max_health = 90.0
	weapons = [IceStaffWeapon.new(), _make_mind_missile("models/hands/ice.mdl"), _make_icepoke(), _make_freezeray(), _make_invisibility()]


func _make_icepoke() -> Weapon:
	var w = IcePokeWeapon.new()
	w.bot_range = 6.0  # close-range poke
	w.bot_lead_speed = IcePokeWeapon.SHARD_SPEED
	w.element = element
	w.hand_model_path = "models/hands/ice.mdl"
	w.hand_idle_anim = "icepokeidle"
	w.hand_attack_anims.assign(["icepokeshoot"])
	w.hand_hit_anims.assign(["icepokeshoot"])
	w.player_attack_prefix = "icepoke"
	return w


func _make_freezeray() -> Weapon:
	var w = FreezeRayWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/ice.mdl"
	w.hand_idle_anim = "icerayidle"
	w.hand_attack_anims.assign(["icerayshoot"])
	w.hand_hit_anims.assign(["icerayshoot"])
	w.player_attack_prefix = "rayspell"
	return w


func _make_invisibility() -> Weapon:
	var w = InvisibilityWeapon.new()
	w.element = element
	w.hand_model_path = "models/hands/ice.mdl"
	w.hand_idle_anim = "icerayidle"
	w.hand_attack_anims.assign(["icerayshoot"])
	w.hand_hit_anims.assign(["icerayshoot"])
	w.player_attack_prefix = "rayspell"
	return w
