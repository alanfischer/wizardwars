class_name DoubleMissileWeapon
extends Weapon

## Double Magic Missile — alternating left/right missiles, 50 dmg direct hit, 0.3s between shots (ww_doublemissile.cpp).

const COOLDOWN := 0.3
const MANA_COST := 5.0
const LEFT_OFFSET := 0.3     # visible left/right alternation from each hand

var _fire_state := 0  # alternates 0/1 for left/right

## What the missiles this weapon fires hit for. PHYSICAL is the plain bolt every class gets; a
## class that sets something else (the necromancer's poison) colours the missile to match and
## leaves that status on what it hits.
var damage_type := GameConsts.DamageType.PHYSICAL


func _init() -> void:
	auto_repeat = true
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func stop_firing(attacker: Node3D, _secondary: bool = false) -> void:
	super.stop_firing(attacker)
	_fire_state = 0


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

		var right: Vector3 = GeomUtil.perpendicular_axes(aim.aim_dir)[0]
		if _fire_state:
			spawn_pos += right * LEFT_OFFSET
		else:
			spawn_pos -= right * LEFT_OFFSET

		_fire_projectile(attacker, "res://src/projectiles/magic_missile.gd", {
			"position": spawn_pos,
			"direction": aim.aim_dir,
			"damage_type": damage_type,
		})
		_fire_state = 1 - _fire_state
	_fire_tail(attacker)
	return true
