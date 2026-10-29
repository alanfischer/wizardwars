class_name PebbleblastWeapon
extends Weapon

## Pebble Blast — shotgun-style hitscan burst, 8 pellets with spread. Earth wizard's version of thornblast.

const PELLET_DAMAGE := 6.0
const PELLET_COUNT := 8
const SPREAD := 0.1            # radians of random cone spread per pellet
const RANGE := 51.2            # 2048 GS * 0.025
const COOLDOWN := 1.0
const MANA_COST := 10.0
const BEAM_COLOR := Color(0.7, 0.5, 0.2, 1.0)


func _init() -> void:
	mana_cost = MANA_COST
	cooldown = COOLDOWN


func precache() -> void:
	SoundSystem.precache("spells/thornblast.wav")

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/thornblast.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	_fire_shotgun_blast(attacker, aim_from, aim_dir, PELLET_COUNT, SPREAD, RANGE, PELLET_DAMAGE, BEAM_COLOR)
	return true
