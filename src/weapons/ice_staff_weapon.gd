class_name IceStaffWeapon
extends Staff

func _init() -> void:
	element = GameConsts.Element.ICE
	staff_model_path = "models/staves/ice.mdl"
	hand_model_path = "models/hands/ice.mdl"
	hand_idle_anim = "staffidle"
	hand_attack_anims.assign(["staffmiss1", "staffmiss2", "staffmiss3"])
	hand_hit_anims.assign(["staffhit1", "staffhit2", "staffhit3"])
	player_attack_prefix = "staff"
	cooldown = 0.5
	auto_repeat = true
