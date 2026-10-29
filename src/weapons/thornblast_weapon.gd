class_name ThornblastWeapon
extends Weapon

## Thorn Blast — shotgun-style hitscan burst. Fires 4 pellets with spread.
## 20 damage per pellet, 0.8s cooldown. Based on ww_thornblast.cpp.

const PELLET_DAMAGE := 10.0
const PELLET_COUNT := 4
const SPREAD := 0.08           # radians of random cone spread per pellet
const RANGE := 51.2            # 2048 GS * 0.025
const COOLDOWN := 0.8
const MANA_COST := 5.0
const BEAM_COLOR := Color(0.4, 0.8, 0.1, 1.0)


func _init() -> void:
	cooldown = COOLDOWN
	mana_cost = MANA_COST


func precache() -> void:
	SoundSystem.precache("spells/thornblast.wav")

func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, "spells/thornblast.wav")


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	_fire_shotgun_blast(attacker, aim_from, aim_dir, PELLET_COUNT, SPREAD, RANGE, PELLET_DAMAGE, BEAM_COLOR)
	return true
