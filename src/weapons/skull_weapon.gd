class_name SkullWeapon
extends Weapon

## Skull spell — fires a homing skull projectile that seeks enemies.
## Costs mana, 1.5s cooldown. Based on ww_skull.cpp.

const COOLDOWN := 1.3
const MANA_COST := 5.0


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_model("models/flyingskull.mdl")
	SoundSystem.precache("spells/flyingskull.wav")
	for sound in TumblingCorpse.IMPACT_SOUNDS["models/flyingskull.mdl"]:
		SoundSystem.precache(sound)
	AssetLoader.get_trail_material()


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	# Host only: spawn projectile (clients see it via dynamic entity replication)
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		NetworkManager.spawn_projectile("res://src/projectiles/skull.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
			"team": attacker.team if "team" in attacker else 0,
		}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
