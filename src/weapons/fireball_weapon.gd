class_name FireballWeapon
extends Weapon

const COOLDOWN := 1.7
const MANA_COST := 20.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_sprite("sprites/animglow01.spr")
	AssetLoader.precache_sprite("sprites/zerogxplode.spr")
	SoundSystem.precache("spells/fireball_cast.wav")
	SoundSystem.precache("spells/fireball_ambience.wav")
	SoundSystem.precache("ambience/explode3.wav")
	AssetLoader.get_sprite_material_template()

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/fireball_cast.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		NetworkManager.spawn_projectile("res://src/projectiles/fireball.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
		}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
