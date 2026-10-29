class_name MindMissileWeapon
extends Weapon

## Mind Missile — Ice and Wind's opening spell. Half the magic missile's rate for twice its
## damage and twice its cost, and it presses what it hits (mindmisslespell.cpp).

const COOLDOWN := 1.2
const MANA_COST := 10.0
const LEFT_OFFSET := 0.3


func _init() -> void:
	auto_repeat = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_sprite(MindMissile.SPRITE)
	SoundSystem.precache("spells/mindmissile.wav")
	SoundSystem.precache(MindMissile.HIT_SOUND)
	AssetLoader.get_trail_material()
	AssetLoader.get_sprite_material_template()


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/mindmissile.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if NetworkManager.is_authoritative_fire(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		# Off the left hand, like the magic missile (vOrigin - v_right * 8).
		spawn_pos -= GeomUtil.perpendicular_axes(aim.aim_dir)[0] * LEFT_OFFSET

		NetworkManager.spawn_projectile("res://src/projectiles/mind_missile.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
		}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true
