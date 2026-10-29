class_name LightningCloudWeapon
extends Weapon

## Lightning cloud spell — sends a thundercloud drifting away from the caster in whatever
## direction they were looking. It never turns and never hunts: aiming it is the whole of
## casting it, and it holds the lane you sent it down until something runs into it.
##
## The spellbook holds one cast. It costs no mana and spends itself instead: a successful cast
## takes the spell back out of the loadout, so another cloud means finding another book.

const SCALE := GameConsts.SCALE_FACTOR
const CAST_DISTANCE := 48.0 * SCALE    # 1.2 m out of the caster's hands, as in the original
const COOLDOWN := 2.0
const CAST_SOUND := "spells/combos/lightningcloud_cast.wav"


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_sprite(LightningCloud.SPRITE)
	AssetLoader.precache_sprite(ExplosionEffect.DEFAULT_SPR)
	AssetLoader.get_additive_material()
	AssetLoader.get_spark_particle_material("lightning")
	for sound_path in [CAST_SOUND, LightningCloud.ZAP_SOUND, ExplosionEffect.DEFAULT_SOUND]:
		SoundSystem.precache(sound_path)


func play_attack_sound(attacker: Node3D) -> void:
	SoundSystem.spawn_on(attacker, CAST_SOUND, false, 30.0)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the cloud
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)

	_spend(attacker)

	NetworkManager.spawn_projectile("res://src/monsters/lightning_cloud.gd", {
		"sync_state": true,  # zap and burst are one-shot events, not convergent properties
		"position": aim.from + aim.aim_dir * CAST_DISTANCE,
		# Pitch and all: unlike the tornado or the ball, the original gave this one real angles,
		# so a cloud aimed up a stairwell goes up the stairwell.
		"direction": aim.aim_dir,
		"team": int(attacker.get("team")),
	}, attacker, attacker.get_rid())

	_fire_tail(attacker)
	return true


## Take the spell back out of the caster's loadout — one book, one cloud. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the cloud is the world's once cast, not the loadout's
