class_name RollingStoneWeapon
extends Weapon

## Rolling Stone — thrown boulder that bounces and deals 80 damage on direct hit.

const STONE_SPEED := 17.5      # 700 GS * 0.025
const STONE_LIFETIME := 2.0
const COOLDOWN := 1.0
const MANA_COST := 5.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.load_model("models/rollingstone.mdl")
	AssetLoader.precache_sprite("sprites/stmbal1.spr")
	SoundSystem.precache("spells/stone_cast.wav")
	SoundSystem.precache("spells/stone_bounce.wav")
	AssetLoader.get_sprite_material_template()


func play_attack_sound(_attacker: Node3D) -> void:
	pass  # Sound played by projectile on spawn


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		NetworkManager.spawn_projectile("res://src/projectiles/rolling_stone.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
			"speed": STONE_SPEED,
			"lifetime": STONE_LIFETIME,
		}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
