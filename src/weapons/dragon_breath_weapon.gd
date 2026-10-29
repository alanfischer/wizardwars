class_name DragonBreathWeapon
extends Weapon

## Dragon-mount breath weapon — keeps the rider flying (CMF_FLYING) and drains the
## dragon's flame resource on each shot.

const FIRE_SPREAD := 0.06


var _dragon: Node


func _init(dragon: Node = null, rider_element: int = GameConsts.Element.FIRE) -> void:
	_dragon = dragon
	auto_repeat = true
	sustained = false
	cooldown = 0.1
	weapon_name = "Dragon Breath"
	var element_name = GameConsts.ELEMENT_NAMES.get(rider_element, "fire")
	hand_model_path = "models/hands/%s.mdl" % element_name
	# no 1P dragonbreath hand anim exists; idle pose avoids a 10x/sec swing restart at this cooldown
	hand_idle_anim = "staffidle"
	player_attack_prefix = "dragonbreath"


func precache() -> void:
	SoundSystem.precache("spells/dragonfire.wav")


func contribute_input_flags(cmd) -> void:
	cmd.custom_flags |= GameConsts.CMF_FLYING


func can_fire(attacker: Node3D, _aim_dir: Vector3 = Vector3.ZERO) -> bool:
	if not NetworkManager.is_authoritative_fire(attacker):
		return true
	return is_instance_valid(_dragon) and _dragon.flame > 0


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO,
		_charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		if not is_instance_valid(_dragon) or _dragon.flame <= 0:
			return false
		_dragon.flame -= 1
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)
		if is_instance_valid(_dragon):
			spawn_pos = _dragon.get_mouth_position()
		var dir : Vector3 = aim.aim_dir
		if FIRE_SPREAD > 0.0:
			dir += Vector3(
				randf_range(-FIRE_SPREAD, FIRE_SPREAD),
				randf_range(-FIRE_SPREAD, FIRE_SPREAD),
				randf_range(-FIRE_SPREAD, FIRE_SPREAD)
			)
			dir = dir.normalized()
		NetworkManager.spawn_projectile("res://src/projectiles/dragon_fire.gd", {
			"position": spawn_pos,
			"direction": dir,
		}, attacker, attacker.get_rid())

	SoundSystem.spawn_on(attacker, "spells/dragonfire.wav")
	_fire_tail(attacker)
	return true
