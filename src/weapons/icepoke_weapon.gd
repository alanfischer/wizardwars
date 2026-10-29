class_name IcePokeWeapon
extends Weapon

## Ice Poke — burst of 6 ice shard projectiles in a ring pattern.

const SHARD_SPEED := 25.0       # 1000 GS * 0.025
const SHARD_DAMAGE := 10.0
const SHARD_LIFETIME := 5.0
const SHARD_COUNT := 6
const RING_RADIUS := 0.4
const COOLDOWN := 0.9
const MANA_COST := 5.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_model("models/iceshard.mdl")
	SoundSystem.precache("spells/icepoke.wav")
	AssetLoader.get_trail_material()
	AssetLoader.get_spark_particle_material("iceshard")
	AssetLoader.get_spark_quad(Vector2(0.08, 0.08))

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/icepoke.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		var axes := GeomUtil.perpendicular_axes(aim.aim_dir)
		var right: Vector3 = axes[0]
		var up: Vector3 = axes[1]

		for i in SHARD_COUNT:
			var angle := (float(i) / SHARD_COUNT) * TAU
			var offset := (right * cos(angle) + up * sin(angle)) * RING_RADIUS
			var shard_pos := spawn_pos + offset

			NetworkManager.spawn_projectile("res://src/projectiles/ice_shard.gd", {
				"position": shard_pos,
				"direction": aim.aim_dir,
				"speed": SHARD_SPEED,
				"damage": SHARD_DAMAGE,
				"lifetime": SHARD_LIFETIME,
			}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
