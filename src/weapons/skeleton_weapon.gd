class_name SkeletonWeapon
extends Weapon

const COOLDOWN := 1.7
const MANA_COST := 2.0
const LAUNCH_SPEED := 20.0
const RATTLE_SOUND := "monster/skeleton/skgibs.wav"


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/raisedead_cast.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		NetworkManager.spawn_projectile("res://src/monsters/tumbling_corpse.gd", {
			"position": spawn_pos,
			"velocity": aim.aim_dir * LAUNCH_SPEED,
			"head_dir": aim.aim_dir,
			"sound": RATTLE_SOUND,
			"model": "models/combo/raisedead.mdl",
			"seed": randi(),
			"kind": TumblingCorpse.Kind.WIZARD,
			"sync_state": true,
		}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
