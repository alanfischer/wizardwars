class_name ArchmageWizard
extends Wizard

func _init() -> void:
	element = GameConsts.Element.ARCHMAGE
	player_model_path = "models/player/archmage.mdl"
	speed_multiplier = 0.55  # SPEED_LOW
	max_health = 60.0
	weapons = [ArchmageStaffWeapon.new(), _make_missile("models/hands/archmage.mdl"), _make_comet()]


func _make_comet() -> Weapon:
	var w = CometWeapon.new()
	w.bot_range = 40.0  # long-range AoE comet
	w.element = element
	w.hand_model_path = "models/hands/archmage.mdl"
	w.hand_idle_anim = "shieldidle"
	w.hand_attack_anims.assign(["shieldidle"])
	w.hand_hit_anims.assign(["shieldidle"])
	w.player_attack_prefix = "combo"
	return w
