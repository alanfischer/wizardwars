class_name DeathStaffWeapon
extends Staff

func _init() -> void:
	element = GameConsts.Element.DEATH
	staff_model_path = "models/staves/death.mdl"
	hand_model_path = "models/hands/death.mdl"
	hand_idle_anim = "staffidle"
	hand_attack_anims.assign(["staffmiss1", "staffmiss2", "staffmiss3"])
	hand_hit_anims.assign(["staffhit1", "staffhit2", "staffhit3"])
	player_attack_prefix = "staff"
	cooldown = 0.5
	auto_repeat = true
