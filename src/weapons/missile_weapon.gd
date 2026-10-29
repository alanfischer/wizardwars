class_name MissileWeapon
extends Weapon

## Single Magic Missile — straight-line projectile, direct hit damage (ww_missile.cpp).

const COOLDOWN := 0.6
const MANA_COST := 5.0
const LEFT_OFFSET := 0.3

## What the missiles this weapon fires hit for. PHYSICAL is the plain bolt every class gets; a
## class that sets something else (the necromancer's poison) colours the missile to match and
## leaves that status on what it hits.
var damage_type := GameConsts.DamageType.PHYSICAL


func _init() -> void:
	auto_repeat = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	AssetLoader.precache_model("models/missile.mdl")
	SoundSystem.precache("spells/magicmissile.wav")
	SoundSystem.precache("weapons/xbow_hitbod1.wav")
	AssetLoader.precache_sprite("sprites/zerogxplode.spr")
	SoundSystem.precache("ambience/explode3.wav")
	AssetLoader.get_trail_material()
	AssetLoader.get_sprite_material_template()

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/magicmissile.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if _fires_projectile(attacker):
		var aim := Combat.get_aim(attacker, aim_from, aim_dir)
		var spawn_pos := Combat.get_spawn_pos(aim)

		# offset left like the original (vOrigin - v_right * 8)
		spawn_pos -= GeomUtil.perpendicular_axes(aim.aim_dir)[0] * LEFT_OFFSET

		_fire_projectile(attacker, "res://src/projectiles/magic_missile.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
			"damage_type": damage_type,
		})

	_fire_tail(attacker)
	return true
