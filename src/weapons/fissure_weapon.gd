class_name FissureWeapon
extends Weapon

## Fissure — pyromancer reality-tear spell: stops the caster 3s, floats a fissure in front
## that expands over 2s, then detonates for 500 damage in a 3m radius.

const COOLDOWN := 3.0
const MANA_COST := 90.0
const STOP_DURATION := 3.0
const SPAWN_DISTANCE := 1.5  # meters


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_model("models/fissure.mdl")
	SoundSystem.precache("spells/fissure_cast.wav")
	SoundSystem.precache("spells/fissure_boom.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	SoundSystem.play_3d("spells/fissure_cast.wav", attacker.global_position)
	_fire_tail(attacker)

	_freeze_caster(attacker)
	attacker.get_tree().create_timer(STOP_DURATION).timeout.connect(
		func(): _unfreeze_caster(attacker)
	)

	if not NetworkManager.is_authoritative_fire(attacker):
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var forward = aim.aim_dir.normalized()

	var spawn_pos = attacker.global_position + GameConsts.PLAYER_CENTER + forward * SPAWN_DISTANCE

	var team_val: int = attacker.get("team") if "team" in attacker else GameConsts.Team.NONE
	var peer_id: int = int(attacker.get("peer_id"))

	NetworkManager.spawn_projectile("res://src/monsters/fissure.gd", {
		"position": spawn_pos,
		"direction": forward,
		"owner_peer_id": peer_id,
		"team": team_val,
	}, attacker)
	return true


func _freeze_caster(attacker: Node3D) -> void:
	if "speed_multiplier" in attacker:
		attacker.set_meta("fissure_saved_speed", attacker.speed_multiplier)
		attacker.speed_multiplier = 0.0


func _unfreeze_caster(attacker: Node3D) -> void:
	if not is_instance_valid(attacker):
		return
	if "speed_multiplier" in attacker:
		var saved: float = attacker.get_meta("fissure_saved_speed", 1.0)
		attacker.speed_multiplier = saved
		if attacker.has_meta("fissure_saved_speed"):
			attacker.remove_meta("fissure_saved_speed")
