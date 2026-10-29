class_name BirdWeapon
extends Weapon

const COOLDOWN := 1.5
const MANA_COST := 5.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_model("models/npc/bird.mdl")
	SoundSystem.precache("spells/birdspell.wav")
	for sound in TumblingCorpse.IMPACT_SOUNDS["models/npc/bird.mdl"]:
		SoundSystem.precache(sound)

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/birdspell.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		NetworkManager.spawn_projectile("res://src/projectiles/bird.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
			"team": attacker.team if "team" in attacker else 0,
		}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
