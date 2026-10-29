class_name MeteorWeapon
extends Weapon

## Meteor spell — calls three meteors down on one wizard from 51 m out. It is the only combo
## spell that has to be aimed at a person rather than a place: it picks the nearest enemy the
## caster can actually see, inside a cone about where they are looking, and locks all three onto
## them. They land together, as one blow, however far the target runs in the meantime. Cast with
## nobody in view and the book is spent on nothing but the sound of a miss.
##
## The spellbook holds one cast. It costs no mana and spends itself instead — a miss included,
## which is the whole risk of the spell.

const SCALE := GameConsts.SCALE_FACTOR
const SEARCH_RANGE := 2048.0 * SCALE   # 51.2 m
## GoldSrc m_flFieldOfView 0.25 — a touch over 75 degrees either side of where the caster looks.
const SEARCH_FOV := 0.25
const METEOR_COUNT := 3
const COOLDOWN := 2.0
const CAST_SOUND := "spells/combos/meteor_cast.wav"
const MISS_SOUND := "spells/combos/meteor_miss.wav"


func _init() -> void:
	cooldown = COOLDOWN
	# No mana: the book itself is the cost, and it's gone after one cast (see fire).


func precache() -> void:
	AssetLoader.precache_sprite(Meteor.SPRITE)
	AssetLoader.get_additive_material()
	MeteorExplosionEffect.precache()
	for sound_path in [CAST_SOUND, MISS_SOUND]:
		SoundSystem.precache(sound_path)


func fire(attacker: Node3D, aim_from: Vector3 = Vector3.INF, aim_dir: Vector3 = Vector3.ZERO, _charge_percent: float = 0.0, secondary: bool = false) -> bool:
	if secondary:
		return false
	if not NetworkManager.is_authoritative_fire(attacker):
		_fire_tail(attacker)  # client plays the cast; the host owns the strike
		return true

	var aim := Combat.get_aim(attacker, aim_from, aim_dir)
	var target := Combat.find_homing_target(attacker, attacker, int(attacker.get("team")),
			SEARCH_RANGE, attacker.get_rid(), aim.from, aim.aim_dir, SEARCH_FOV)

	_spend(attacker)  # spent either way: a miss costs the book, as in the original

	if target == null:
		SoundSystem.play_3d(MISS_SOUND, aim.from)
		_fire_tail(attacker)
		return true

	# All three leave on this tick from the same distance out, which is what lets each one hold
	# itself to the same arrival — see Meteor. The first carries the deep boom for the landing.
	var target_pos: Vector3 = SpatialQuery.collision_center(target)
	for i in METEOR_COUNT:
		var meteor := NetworkManager.spawn_projectile("res://src/projectiles/meteor.gd", {
			"position": target_pos + _approach() * Meteor.SPAWN_DISTANCE,
			"target_pos": target_pos,
			"lead": i == 0,
		}, attacker) as Meteor
		if meteor:
			meteor.set_target(target)

	SoundSystem.play_3d(CAST_SOUND, aim.from)
	_fire_tail(attacker)
	return true


## Where one meteor comes in from. The original rolled each axis as a whole number — -1, 0 or 1
## sideways and 0 or 1 up — so a strike arrives down a handful of recognisable lines rather than
## from anywhere, and never from below. All three rolling zero is possible and normalises to
## nothing, so that falls back to straight overhead.
func _approach() -> Vector3:
	var dir := Vector3(randi_range(-1, 1), randi_range(0, 1), randi_range(-1, 1))
	return dir.normalized() if dir.length_squared() > 0.0 else Vector3.UP


func play_attack_sound(_attacker: Node3D) -> void:
	pass  # the cast and the miss are different sounds, played from fire() once it knows which


## Take the spell back out of the caster's loadout — one book, one strike. Deferred because the
## server is mid-fire: it still has to stamp last_fired_weapon_idx and broadcast the shot by slot
## index, and dropping a slot now would renumber the loadout under both.
func _spend(attacker: Node3D) -> void:
	if attacker.has_method("revoke_weapon"):
		attacker.call_deferred(&"revoke_weapon", SpawnRegistry.name_for(get_script()))


func cleanup(_attacker: Node3D) -> void:
	pass  # nothing to tear down: the meteors are the world's once called, not the loadout's
