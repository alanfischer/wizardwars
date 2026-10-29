class_name FlamelickWeapon
extends Weapon

## Flame Lick — short-range fire AOE: hitscan raycast + sphere damage at impact.
## Fast, spammable (0.5s cooldown), 15 damage to everything in radius.

const DAMAGE := 15.0
const AREA := 3.2           # 128 GS * 0.025
const RANGE := 205.0         # 8192 GS * 0.025


const COOLDOWN := 0.5
const MANA_COST := 5.0


func _init() -> void:
	auto_repeat = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_sprite("sprites/mushroom.spr")
	SoundSystem.precache("spells/flamelick_cast.wav")
	SoundSystem.precache("spells/flamelick_hit.wav")
	AssetLoader.get_sprite_material_template(BaseMaterial3D.BILLBOARD_FIXED_Y)

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/flamelick_cast.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var ray := Combat.raycast_world(attacker, aim.from, aim.aim_dir, RANGE, attacker.get_rid(),
		GameConsts.MASK_WORLD | GameConsts.MASK_ENTITY | GameConsts.MASK_PLAYER)

	if NetworkManager.is_authoritative_fire(attacker):
		Combat.apply_aoe_damage(ray.space, ray.impact_pos, DAMAGE, AREA, ray.result, GameConsts.DamageType.FIRE, attacker)

	if NetworkManager.is_authoritative_fire(attacker):
		var hit_normal = ray.result.get("normal", Vector3.UP)
		var effect := FlamelickEffect.spawn(attacker.get_tree().current_scene, ray.impact_pos + hit_normal * 0.15)
		NetworkManager.register_effect(effect, "res://src/effects/flamelick_effect.gd")

	_fire_tail(attacker)
	return true
