class_name UpdraftWeapon
extends Weapon

## Updraft — hitscan AOE knockback. Low damage, strong upward push at impact.
## Launches enemies (and self) away from the impact point.

const DAMAGE := 5.0
const AREA := 3.2             # 128 GS * 0.025
const RANGE := 205.0           # 8192 GS * 0.025
const KNOCKBACK := 20.0        # 800 GS * 0.025 — push strength


const COOLDOWN := 0.8
const MANA_COST := 5.0


func _init() -> void:
	auto_repeat = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_sprite("sprites/effects/updraft.spr")
	SoundSystem.precache("spells/updraft_cast.wav")
	SoundSystem.precache("spells/updraft_hit.wav")
	AssetLoader.get_sprite_material_template(BaseMaterial3D.BILLBOARD_FIXED_Y)


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/updraft_cast.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var ray := Combat.raycast_world(attacker, aim.from, aim.aim_dir, RANGE, attacker.get_rid(),
		GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY)

	if NetworkManager.is_authoritative_fire(attacker):
		Combat.apply_aoe_damage(ray.space, ray.impact_pos, DAMAGE, AREA, ray.result, GameConsts.DamageType.PHYSICAL, attacker, null, true)
		# up_bias 1.0 launches rather than shoves; set_along keeps repeat casts from stacking.
		Combat.apply_aoe_knockback(ray.space, ray.impact_pos, KNOCKBACK, AREA, attacker, 1.0, true)

	if NetworkManager.is_authoritative_fire(attacker):
		var hit_normal = ray.result.get("normal", Vector3.UP)
		var effect := UpdraftEffect.spawn(attacker.get_tree().current_scene, ray.impact_pos + hit_normal * 0.15)
		NetworkManager.register_effect(effect, "res://src/effects/updraft_effect.gd")

	_fire_tail(attacker)
	return true
